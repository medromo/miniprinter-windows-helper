# Instala o actualiza miniprinter-windows-helper en esta estación (sin admin, sin dependencias).
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1
#
# Volver a ejecutarlo actualiza a lo más nuevo del repo: reemplaza los scripts
# (este incluido, que se queda en la carpeta de instalación para eso), agrega a
# config.json los campos nuevos sin tocar los que ya tiene, y reinicia el watcher.
$ErrorActionPreference = 'Stop'
$Dest = 'C:\mascotasymas\print-helper'
$Repo = 'https://github.com/medromo/miniprinter-windows-helper/archive/HEAD.zip'
$TaskName = 'Ordenes de deposito - watcher'
$Scripts = 'Print-DepositOrders.ps1', 'print-orders.cmd', 'install-helper.ps1'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)

$isUpdate = Test-Path -LiteralPath "$Dest\Print-DepositOrders.ps1"
if ($isUpdate) { Write-Host "Actualizando la instalación en $Dest" -ForegroundColor Cyan }
else { Write-Host "Instalando en $Dest" -ForegroundColor Cyan }

# 1. Descargar el repo y validarlo ANTES de tocar la instalación
$tmp = Join-Path $env:TEMP ("mph-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $Repo -OutFile "$tmp\repo.zip" -UseBasicParsing
    Expand-Archive "$tmp\repo.zip" $tmp
    $src = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName

    $bom = ([IO.File]::ReadAllBytes("$src\Print-DepositOrders.ps1")[0..2]) -join ','
    if ($bom -ne '239,187,191') { throw "El .ps1 del repo no tiene BOM ($bom). No se instaló nada." }
    $null = [IO.File]::ReadAllText("$src\config.json", $Utf8NoBom) | ConvertFrom-Json

    # 2. Detener el watcher que esté corriendo, sin cortar una impresión a medias.
    #    El helper toma este mutex desde que abre el diálogo hasta que termina de
    #    imprimir; si lo tenemos nosotros, no hay nada en curso.
    if ($isUpdate) {
        $mutex = New-Object System.Threading.Mutex($false, 'MascotasYMas.DepositOrders.Print')
        $held = $false
        try { $held = $mutex.WaitOne(60000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) {
            $mutex.Dispose()
            throw 'Hay un diálogo de impresión abierto o una impresión en curso. Ciérralo y vuelve a ejecutar.'
        }
        try {
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                Stop-ScheduledTask -TaskName $TaskName
            }
            # También uno lanzado a mano con -Watch, que la tarea no conoce.
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
                Where-Object { $_.CommandLine -like '*Print-DepositOrders.ps1*-Watch*' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        finally {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        Write-Host "Watcher detenido" -ForegroundColor Green
    }

    # 3. Copiar los scripts (como archivos, preservando el BOM). Sobrescribir este
    #    mismo script mientras corre es seguro: PowerShell ya lo leyó completo.
    New-Item -ItemType Directory $Dest -Force | Out-Null
    foreach ($f in $Scripts) { Copy-Item "$src\$f" $Dest -Force }

    # 4. config.json: nuevo si no existe; si existe, solo se le agregan los campos
    #    que trae el repo y le faltan (p. ej. filePatterns). Lo que ya tiene no se
    #    toca, y se edita como texto para no reformatearlo con ConvertTo-Json.
    $cfgPath = "$Dest\config.json"
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Copy-Item "$src\config.json" $Dest
    }
    else {
        $repoText = [IO.File]::ReadAllText("$src\config.json", $Utf8NoBom)
        $text = [IO.File]::ReadAllText($cfgPath, $Utf8NoBom)
        $have = @(($text | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name })
        $added = @()
        $names = @()
        foreach ($prop in ($repoText | ConvertFrom-Json).PSObject.Properties) {
            if ($have -contains $prop.Name) { continue }
            # El config del repo tiene un campo por línea; se copia el valor tal cual.
            $m = [regex]::Match($repoText, '(?m)^\s*"' + [regex]::Escape($prop.Name) + '"\s*:\s*(.+?),?\s*$')
            if (-not $m.Success) { continue }
            $added += ('  "{0}": {1}' -f $prop.Name, $m.Groups[1].Value)
            $names += $prop.Name
        }
        if ($added.Count -gt 0) {
            $body = $text.Substring(0, $text.LastIndexOf('}')).TrimEnd()
            $sep = if ($body.EndsWith('{')) { "`r`n" } else { ",`r`n" }
            $text = $body + $sep + ($added -join ",`r`n") + "`r`n}`r`n"
            $null = $text | ConvertFrom-Json   # que siga siendo JSON válido antes de escribir
            [IO.File]::WriteAllText($cfgPath, $text, $Utf8NoBom)
            Write-Host ("config.json: se agregó {0}" -f ($names -join ', ')) -ForegroundColor Green
        }
    }
}
finally {
    # Con un usuario con espacio ("CAJA 1"), %TEMP% viene en forma corta 8.3
    # (C:\Users\CAJA1~1\...) y Remove-Item -Recurse de PS 5.1 truena con ella
    # aun con SilentlyContinue. Borrar una carpeta temporal nunca debe abortar
    # la instalación, así que se hace con .NET y se ignora cualquier fallo.
    try { [IO.Directory]::Delete($tmp, $true) } catch { }
}
Set-Location $Dest
Write-Host "Archivos en $Dest" -ForegroundColor Green

# 5. Impresora y prueba: solo en la primera instalación; al actualizar se
#    conserva la impresora configurada.
if (-not $isUpdate) {
    & .\print-orders.cmd -ListPrinters
    $name = Read-Host "Nombre EXACTO de la impresora (Enter = autodetectar TM-T20)"
    if ($name) {
        # Solo se reemplaza el valor de printerName; el resto del archivo queda tal cual.
        $text = [IO.File]::ReadAllText($cfgPath, $Utf8NoBom)
        $escaped = $name.Replace('\', '\\').Replace('"', '\"')
        $re = [regex]'"printerName"\s*:\s*"(?:[^"\\]|\\.)*"'
        if (-not $re.IsMatch($text)) { throw 'config.json no tiene el campo printerName.' }
        $text = $re.Replace($text, { param($m) '"printerName": "' + $escaped + '"' }, 1)
        $null = $text | ConvertFrom-Json
        [IO.File]::WriteAllText($cfgPath, $text, $Utf8NoBom)
        Write-Host "config.json actualizado" -ForegroundColor Green
    }

    if ((Read-Host "¿Imprimir prueba ahora? (s/n)") -eq 's') {
        & .\print-orders.cmd -SelfTest
        Write-Host "Revisa: acentos correctos, monto grande en negrita, papel cortado."
    }
}

# 6. Acceso directo en el escritorio (one-shot / respaldo). Se recrea siempre.
#    Ya no solo imprime órdenes de depósito (también tickets), así que el nombre
#    anterior se borra para no dejar dos accesos directos.
$desktop = [Environment]::GetFolderPath('Desktop')
$oldLnk  = Join-Path $desktop 'Imprimir órdenes de depósito.lnk'
if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force -ErrorAction SilentlyContinue }
$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $desktop 'Imprimir tickets y órdenes.lnk'))
$lnk.TargetPath       = "$Dest\print-orders.cmd"
$lnk.WorkingDirectory = $Dest
$lnk.IconLocation     = "$env:SystemRoot\System32\imageres.dll,0"   # cámbialo por el de impresora en Propiedades
$lnk.WindowStyle      = 1   # Ventana normal
$lnk.Save()
Write-Host "Acceso directo listo" -ForegroundColor Green

# 7. Tarea programada del watcher. Se vuelve a registrar siempre, así una
#    actualización también trae cambios en su configuración.
$user     = "$env:USERDOMAIN\$env:USERNAME"
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $Dest `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dest\Print-DepositOrders.ps1`" -Watch"
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT30S'
# Repetir cada 5 minutos mientras dure la sesión: con MultipleInstances
# IgnoreNew, si el watcher sigue vivo no pasa nada; si murió (falló al iniciar
# sesión, lo cerraron desde la bandeja, lo tumbó una actualización) vuelve solo.
# El reinicio por fallo de la tarea no cubre esto: no reacciona a un exit code.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
$settings = New-ScheduledTaskSettingsSet -Hidden -Compatibility Win8 `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# Una instalación hecha a mano con el README tiene su propia tarea con otro
# nombre ("Órdenes de depósito — watcher"). Si se queda, al iniciar sesión
# arrancan dos watchers y el mismo archivo puede preguntar dos veces.
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -ne $TaskName -and
        (@($_.Actions | ForEach-Object { $_.Arguments }) -join ' ') -like '*Print-DepositOrders.ps1*-Watch*' } |
    ForEach-Object {
        $old = $_
        try {
            Unregister-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -Confirm:$false
            Write-Host ("Se quitó la tarea anterior '{0}'" -f $old.TaskName) -ForegroundColor Green
        }
        catch {
            Write-Host ("No se pudo quitar la tarea anterior '{0}'. Bórrala a mano en el Programador de tareas." -f $old.TaskName) -ForegroundColor Yellow
        }
    }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

if ($isUpdate) {
    Write-Host "Actualizado. El watcher se reinició con la versión nueva; debe aparecer el icono en la bandeja." -ForegroundColor Green
}
else {
    Write-Host "Watcher instalado y arrancado. Debe aparecer el icono en la bandeja." -ForegroundColor Green
    Write-Host "Falta: reiniciar y confirmar que el icono vuelve solo; luego soltar un .bin en Descargas."
}
