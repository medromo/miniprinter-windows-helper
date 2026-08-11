<#
.SYNOPSIS
  Prints the POS deposit-order files (raw ESC/POS) on the station's TM-T20II.
.DESCRIPTION
  Run with -Watch to sit in the tray and offer to print each file as it is
  downloaded. Run with no arguments to print the most recent one now.
#>
[CmdletBinding()]
param(
  [switch]$Watch,
  [string]$Path,
  [string]$PrinterName,
  [switch]$ListPrinters,
  [switch]$SelfTest,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$FilePattern = '*-ordenes-deposito*.bin'
$MaxFileBytes = 1MB
$StaleAfterHours = 2

# ---------------------------------------------------------------- config ----

function Get-HelperConfig {
  $defaults = @{
    printerName          = ''
    downloadsPath        = ''
    archivePath          = ''
    archiveRetentionDays = 30
    pollSeconds          = 3
  }
  $file = Join-Path $PSScriptRoot 'config.json'
  if (Test-Path -LiteralPath $file) {
    $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in @($defaults.Keys)) {
      $value = $json.$key
      if ($null -ne $value -and "$value" -ne '') { $defaults[$key] = $value }
    }
  }
  if ($defaults.downloadsPath -eq '') {
    $defaults.downloadsPath = Join-Path $env:USERPROFILE 'Downloads'
  }
  # Deliberately not under Downloads: that folder gets emptied by the operator
  # and by Storage Sense, and this is a record worth keeping for a month.
  if ($defaults.archivePath -eq '') {
    $defaults.archivePath = Join-Path $PSScriptRoot 'ordenes-impresas'
  }
  return $defaults
}

function Write-Log {
  param([string]$Message)
  $dir = Join-Path $env:LOCALAPPDATA 'MascotasYMas\logs'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $file = Join-Path $dir 'print-orders.log'
  if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 1MB) {
    Move-Item -LiteralPath $file -Destination "$file.1" -Force
  }
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $file -Value $line -Encoding UTF8
}

# --------------------------------------------------------------- printer ----

function Get-InstalledPrinters {
  Get-CimInstance -ClassName Win32_Printer | Sort-Object Name
}

function Resolve-Printer {
  param([string]$Requested)
  $printers = Get-InstalledPrinters
  $installed = ($printers | ForEach-Object { '  - ' + $_.Name }) -join [Environment]::NewLine
  if ($Requested -ne '') {
    $match = $printers | Where-Object { $_.Name -eq $Requested }
    if (-not $match) {
      throw ("No existe una impresora llamada '{0}'. Instaladas:{1}{2}" -f $Requested, [Environment]::NewLine, $installed)
    }
    return $match.Name
  }
  $candidates = @($printers | Where-Object { $_.Name -match 'TM.?T20' })
  if ($candidates.Count -eq 1) { return $candidates[0].Name }
  if ($candidates.Count -eq 0) {
    throw ("No se encontro ninguna impresora TM-T20. Configura printerName en config.json. Instaladas:{0}{1}" -f [Environment]::NewLine, $installed)
  }
  $names = ($candidates | ForEach-Object { '  - ' + $_.Name }) -join [Environment]::NewLine
  throw ("Hay varias impresoras TM-T20. Configura printerName en config.json con una de estas:{0}{1}" -f [Environment]::NewLine, $names)
}

function Initialize-RawPrinterType {
  if ('MascotasYMas.RawPrinter' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MascotasYMas
{
  public static class RawPrinter
  {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private class DOCINFOW
    {
      [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
      [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
      [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
    }

    [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool OpenPrinter(string name, out IntPtr handle, IntPtr defaults);

    [DllImport("winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr handle);

    [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool StartDocPrinter(IntPtr handle, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFOW info);

    [DllImport("winspool.drv", EntryPoint = "EndDocPrinter", SetLastError = true)]
    private static extern bool EndDocPrinter(IntPtr handle);

    [DllImport("winspool.drv", EntryPoint = "StartPagePrinter", SetLastError = true)]
    private static extern bool StartPagePrinter(IntPtr handle);

    [DllImport("winspool.drv", EntryPoint = "EndPagePrinter", SetLastError = true)]
    private static extern bool EndPagePrinter(IntPtr handle);

    [DllImport("winspool.drv", EntryPoint = "WritePrinter", SetLastError = true)]
    private static extern bool WritePrinter(IntPtr handle, IntPtr bytes, int count, out int written);

    private static void Check(bool ok, string call)
    {
      if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), call + " fallo");
    }

    public static void Send(string printerName, string documentName, byte[] payload)
    {
      IntPtr printer;
      Check(OpenPrinter(printerName, out printer, IntPtr.Zero), "OpenPrinter");
      try
      {
        DOCINFOW info = new DOCINFOW();
        info.pDocName = documentName;
        info.pDataType = "RAW";
        Check(StartDocPrinter(printer, 1, info), "StartDocPrinter");
        try
        {
          Check(StartPagePrinter(printer), "StartPagePrinter");
          IntPtr buffer = Marshal.AllocCoTaskMem(payload.Length);
          try
          {
            Marshal.Copy(payload, 0, buffer, payload.Length);
            int written;
            Check(WritePrinter(printer, buffer, payload.Length, out written), "WritePrinter");
            if (written != payload.Length)
              throw new Exception("WritePrinter escribio " + written + " de " + payload.Length + " bytes.");
          }
          finally { Marshal.FreeCoTaskMem(buffer); }
          EndPagePrinter(printer);
        }
        finally { EndDocPrinter(printer); }
      }
      finally { ClosePrinter(printer); }
    }
  }
}
'@
}

function Send-RawBytes {
  param([string]$Printer, [string]$DocumentName, [byte[]]$Payload)
  Initialize-RawPrinterType
  [MascotasYMas.RawPrinter]::Send($Printer, $DocumentName, $Payload)
}

# ---------------------------------------------------------------- decode ----

# The six sequences depositOrders.ts emits, all fixed length. Anything else
# means the format moved and this preview can no longer be trusted, so the
# decode gives up rather than rendering a control byte as text.
function ConvertFrom-EscPos {
  param([byte[]]$Bytes)
  $out = New-Object System.Collections.Generic.List[byte]
  $i = 0
  while ($i -lt $Bytes.Length) {
    $b = $Bytes[$i]
    if ($b -ne 0x1B -and $b -ne 0x1D) {
      $out.Add($b); $i++; continue
    }
    if ($i + 1 -ge $Bytes.Length) { return $null }
    $len = 0
    if ($b -eq 0x1B) {
      switch ($Bytes[$i + 1]) {
        0x40 { $len = 2 }  # ESC @  init
        0x74 { $len = 3 }  # ESC t  code page
        0x45 { $len = 3 }  # ESC E  bold
        0x61 { $len = 3 }  # ESC a  align
      }
    }
    else {
      switch ($Bytes[$i + 1]) {
        0x21 { $len = 3 }                    # GS !  character size
        0x56 { $len = 4; $out.Add(0x0C) }    # GS V  cut -> order separator
      }
    }
    if ($len -eq 0 -or ($i + $len) -gt $Bytes.Length) { return $null }
    $i += $len
  }
  return [Text.Encoding]::GetEncoding(437).GetString($out.ToArray())
}

# The producer appends a recap after the orders — every day with its invoices
# and the grand total. It is the one ticket in the file that is not an order,
# and this heading is how it says so.
$SummaryHeading = 'RESUMEN DE DEPOSITOS'

function Test-HasSummaryTicket {
  param([string]$Text)
  if (-not $Text) { return $false }
  return $Text -match ('(?m)^{0}\s*$' -f [regex]::Escape($SummaryHeading))
}

function Get-OrderSummary {
  param([string]$Text)
  if (-not $Text) { return $null }
  $orders = @()
  foreach ($chunk in ($Text -split "`f")) {
    if ($chunk.Trim() -eq '') { continue }
    # Skipped by name, not by "it didn't parse": a chunk that should have been
    # an order and wasn't still has to abort the whole preview.
    if (Test-HasSummaryTicket -Text $chunk) { continue }
    $lines = $chunk -split "`n"
    $date = $null
    $amount = $null
    for ($n = 0; $n -lt $lines.Length; $n++) {
      $line = $lines[$n].TrimEnd()
      if (-not $date -and $line -match '^Dia de ventas:\s+(.+)$') {
        $date = $Matches[1].Trim()
      }
      if (-not $amount -and $line -match '^Monto a depositar:') {
        for ($m = $n + 1; $m -lt $lines.Length; $m++) {
          $candidate = $lines[$m].Trim()
          if ($candidate -match '^-?\$[\d,]+\.\d{2}$') { $amount = $candidate; break }
        }
      }
    }
    if (-not $date -or -not $amount) { return $null }
    $orders += [PSCustomObject]@{ Date = $date; Amount = $amount }
  }
  if ($orders.Count -eq 0) { return $null }
  return $orders
}

function Measure-CutCount {
  param([byte[]]$Bytes)
  $count = 0
  for ($i = 0; $i -lt $Bytes.Length - 3; $i++) {
    if ($Bytes[$i] -eq 0x1D -and $Bytes[$i + 1] -eq 0x56 -and $Bytes[$i + 2] -eq 0x42) { $count++ }
  }
  return $count
}

function ConvertTo-Decimal {
  param([string]$Money)
  return [decimal]($Money -replace '[^\d\.\-]', '')
}

# ---------------------------------------------------------------- dialog ----

function Show-PrintConfirmation {
  param(
    [System.IO.FileInfo]$File,
    [byte[]]$Bytes,
    [string]$Printer
  )
  $text = ConvertFrom-EscPos -Bytes $Bytes
  $orders = Get-OrderSummary -Text $text
  $lines = New-Object System.Collections.Generic.List[string]

  if ($orders) {
    $count = @($orders).Count
    $noun = if ($count -eq 1) { 'orden' } else { 'órdenes' }
    $verb = if ($count -eq 1) { 'Se imprimirá' } else { 'Se imprimirán' }
    $lines.Add(('{0} {1} {2} de depósito:' -f $verb, $count, $noun))
    $lines.Add('')
    foreach ($order in $orders) {
      $lines.Add(('   {0} — {1}' -f $order.Date, $order.Amount))
    }
    if ($count -gt 1) {
      $total = 0
      foreach ($order in $orders) { $total += ConvertTo-Decimal $order.Amount }
      $lines.Add('')
      $lines.Add(('   Total: ${0}' -f $total.ToString('N2', [Globalization.CultureInfo]::InvariantCulture)))
    }
  }
  else {
    # "tickets", not "órdenes": with no detail there is no way to tell whether
    # one of those cuts belongs to the summary.
    $cuts = Measure-CutCount -Bytes $Bytes
    $lines.Add(('{0} tickets de depósito — no se pudo leer el detalle.' -f $cuts))
  }

  if (Test-HasSummaryTicket -Text $text) {
    $lines.Add('')
    $lines.Add('Incluye un resumen de la corrida.')
  }

  $generated = $null
  if ($text -and $text -match 'Generado:\s*(.+)') { $generated = $Matches[1].Trim() }

  $lines.Add('')
  $lines.Add(('Archivo:   {0}' -f $File.Name))
  if ($generated) { $lines.Add(('Generado:  {0}' -f $generated)) }
  $lines.Add(('Impresora: {0}' -f $Printer))

  $icon = [System.Windows.Forms.MessageBoxIcon]::Question
  if ($File.LastWriteTime -lt (Get-Date).AddHours(-$StaleAfterHours)) {
    $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    $lines.Add('')
    $lines.Add(('ATENCIÓN: este archivo se descargó el {0}.' -f $File.LastWriteTime.ToString('dd/MM/yyyy HH:mm')))
  }
  $lines.Add('')
  $lines.Add('¿Imprimir?')

  # A plain MessageBox opens behind the browser the operator just used, so it
  # gets a topmost owner rather than a topmost style of its own.
  $owner = New-Object System.Windows.Forms.Form
  $owner.TopMost = $true
  $owner.ShowInTaskbar = $false
  $owner.FormBorderStyle = 'None'
  $owner.Size = New-Object System.Drawing.Size(1, 1)
  $owner.StartPosition = 'CenterScreen'
  $owner.Opacity = 0
  try {
    $owner.Show()
    $owner.Activate()
    $answer = [System.Windows.Forms.MessageBox]::Show(
      $owner,
      ($lines -join [Environment]::NewLine),
      'Órdenes de depósito',
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      $icon)
  }
  finally {
    $owner.Close()
    $owner.Dispose()
  }
  return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ----------------------------------------------------------------- files ----

function Wait-FileStable {
  param([string]$FilePath, [int]$TimeoutSeconds = 30)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $previous = -1
  while ((Get-Date) -lt $deadline) {
    try { $length = (Get-Item -LiteralPath $FilePath).Length }
    catch { Start-Sleep -Milliseconds 300; continue }
    if ($length -gt 0 -and $length -eq $previous) {
      try {
        $stream = [IO.File]::Open($FilePath, 'Open', 'Read', 'None')
        $stream.Close()
        return $true
      }
      catch { }
    }
    $previous = $length
    Start-Sleep -Milliseconds 400
  }
  return $false
}

function Find-LatestOrderFile {
  param([string]$Folder)
  Get-ChildItem -LiteralPath $Folder -Filter $FilePattern -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Move-ToArchive {
  param([System.IO.FileInfo]$File, $Config)
  $archive = $Config.archivePath
  if (-not (Test-Path -LiteralPath $archive)) {
    New-Item -ItemType Directory -Path $archive -Force | Out-Null
  }
  $archiveFull = (Get-Item -LiteralPath $archive).FullName

  # Reprinting something out of the archive must not re-archive it, or the
  # timestamp prefixes stack up on every reprint.
  if ((Split-Path -Parent $File.FullName) -ne $archiveFull) {
    $stamped = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $File.Name
    Move-Item -LiteralPath $File.FullName -Destination (Join-Path $archiveFull $stamped) -Force
  }

  # Only our own files: archivePath is configurable, and a prune that deletes
  # everything older than N days in whatever folder it was pointed at is a
  # footgun waiting for a typo.
  $cutoff = (Get-Date).AddDays(-[int]$Config.archiveRetentionDays)
  Get-ChildItem -LiteralPath $archiveFull -Filter $FilePattern -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------- job ----

# 'printed' | 'cancelled' | 'busy' | 'error'
function Invoke-PrintJob {
  param([System.IO.FileInfo]$File, $Config, [string]$Printer, [switch]$NoPrompt)

  $mutex = New-Object System.Threading.Mutex($false, 'MascotasYMas.DepositOrders.Print')
  if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return 'busy' }
  try {
    if (-not (Wait-FileStable -FilePath $File.FullName)) {
      throw ('El archivo {0} sigue cambiando; la descarga no terminó.' -f $File.Name)
    }
    $File.Refresh()

    if ($File.Length -eq 0) { throw ('{0} está vacío.' -f $File.Name) }
    if ($File.Length -gt $MaxFileBytes) {
      throw ('{0} pesa {1:N0} bytes; no parece un archivo de órdenes.' -f $File.Name, $File.Length)
    }

    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x1B -or $bytes[1] -ne 0x40) {
      throw ('{0} no empieza con ESC @; no es un archivo de órdenes.' -f $File.Name)
    }

    if (-not $NoPrompt) {
      if (-not (Show-PrintConfirmation -File $File -Bytes $bytes -Printer $Printer)) {
        Write-Log ('CANCELADO  {0}' -f $File.Name)
        return 'cancelled'
      }
    }

    Send-RawBytes -Printer $Printer -DocumentName $File.BaseName -Payload $bytes
    Move-ToArchive -File $File -Config $Config
    Write-Log ('IMPRESO    {0}  {1:N0} bytes  -> {2}' -f $File.Name, $bytes.Length, $Printer)
    return 'printed'
  }
  finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
  }
}

# ------------------------------------------------------------- self test ----

function Invoke-SelfTest {
  param([string]$Printer)
  $cp437 = [Text.Encoding]::GetEncoding(437)
  $bytes = New-Object System.Collections.Generic.List[byte]
  $add = { param([byte[]]$b) foreach ($x in $b) { $bytes.Add($x) } }
  $line = { param([string]$s) & $add $cp437.GetBytes($s); $bytes.Add(0x0A) }

  & $add ([byte[]](0x1B, 0x40))              # init
  & $add ([byte[]](0x1B, 0x74, 0x00))        # CP437
  & $add ([byte[]](0x1B, 0x61, 0x01))        # center
  & $add ([byte[]](0x1B, 0x45, 0x01))        # bold on
  & $line 'PRUEBA DE IMPRESORA'
  & $add ([byte[]](0x1B, 0x45, 0x00))        # bold off
  & $add ([byte[]](0x1B, 0x61, 0x00))        # left
  & $line ('-' * 42)
  & $line 'Acentos: Depósito niño años ñ á é í ó ú ü'
  & $line 'Signos:  ¿Cuánto? ¡Listo! 42° C'
  & $line ('-' * 42)
  & $line 'Monto a depositar:'
  & $add ([byte[]](0x1B, 0x61, 0x01))        # center
  & $add ([byte[]](0x1D, 0x21, 0x22))        # triple size
  & $add ([byte[]](0x1B, 0x45, 0x01))        # bold on
  & $line '$1,234.56'
  & $add ([byte[]](0x1B, 0x45, 0x00))
  & $add ([byte[]](0x1D, 0x21, 0x00))
  & $add ([byte[]](0x1B, 0x61, 0x00))
  & $line ('-' * 42)
  & $line ('Generado: ' + (Get-Date -Format 'dd/MM/yyyy HH:mm'))
  & $add ([byte[]](0x1D, 0x56, 0x42, 0x03))  # feed and partial cut

  Send-RawBytes -Printer $Printer -DocumentName 'Prueba de impresora' -Payload $bytes.ToArray()
  Write-Log ('PRUEBA     {0} bytes -> {1}' -f $bytes.Count, $Printer)
}

# ----------------------------------------------------------------- watch ----

function Start-WatchMode {
  param($Config, [string]$Printer)

  $script:Running = $true
  $script:Declined = @{}

  $script:Notify = New-Object System.Windows.Forms.NotifyIcon
  $script:Notify.Icon = [System.Drawing.SystemIcons]::Information
  $script:Notify.Text = 'Órdenes de depósito'
  $menu = New-Object System.Windows.Forms.ContextMenuStrip

  # Clearing the whole set is the point: "imprimir el más reciente" has to
  # override a previous decline, and the keys carry a timestamp so removing one
  # by path wouldn't match.
  $itemPrint = $menu.Items.Add('Imprimir el archivo más reciente')
  $itemPrint.add_Click({
      if (-not (Find-LatestOrderFile -Folder $script:Config.downloadsPath)) {
        $script:Notify.ShowBalloonTip(4000, 'Nada que imprimir',
          'No hay órdenes en Descargas. Descárgalas desde el POS.',
          [System.Windows.Forms.ToolTipIcon]::Info)
        return
      }
      $script:Declined.Clear()
      Invoke-Poll
    })

  $itemLog = $menu.Items.Add('Ver bitácora')
  $itemLog.add_Click({
      $log = Join-Path $env:LOCALAPPDATA 'MascotasYMas\logs\print-orders.log'
      if (Test-Path -LiteralPath $log) { Start-Process notepad.exe $log }
    })

  $menu.Items.Add('-') | Out-Null
  $itemExit = $menu.Items.Add('Salir')
  $itemExit.add_Click({ $script:Running = $false })

  $script:Notify.ContextMenuStrip = $menu
  $script:Notify.Visible = $true

  Write-Log ('WATCH      iniciado  carpeta={0}  impresora={1}' -f $Config.downloadsPath, $Printer)
  $script:Notify.ShowBalloonTip(3000, 'Órdenes de depósito',
    'Listo. Descarga las órdenes desde el POS y te preguntaré antes de imprimir.',
    [System.Windows.Forms.ToolTipIcon]::Info)

  $nextPoll = Get-Date
  while ($script:Running) {
    [System.Windows.Forms.Application]::DoEvents()
    if ((Get-Date) -ge $nextPoll) {
      Invoke-Poll
      $nextPoll = (Get-Date).AddSeconds([int]$Config.pollSeconds)
    }
    Start-Sleep -Milliseconds 200
  }

  $script:Notify.Visible = $false
  $script:Notify.Dispose()
  Write-Log 'WATCH      detenido'
}

function Invoke-Poll {
  $file = Find-LatestOrderFile -Folder $script:Config.downloadsPath
  if (-not $file) { return }
  # Keyed by write time too, so re-downloading a file you declined asks again.
  $key = '{0}|{1}' -f $file.FullName, $file.LastWriteTimeUtc.Ticks
  if ($script:Declined.ContainsKey($key)) { return }
  try {
    $result = Invoke-PrintJob -File $file -Config $script:Config -Printer $script:Printer
    switch ($result) {
      'printed' {
        $script:Notify.ShowBalloonTip(3000, 'Impreso',
          $file.Name, [System.Windows.Forms.ToolTipIcon]::Info)
      }
      'cancelled' { $script:Declined[$key] = $true }
      'busy' { }
    }
  }
  catch {
    $script:Declined[$key] = $true
    Write-Log ('ERROR      {0}: {1}' -f $file.Name, $_.Exception.Message)
    $script:Notify.ShowBalloonTip(8000, 'No se pudo imprimir',
      $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
  }
}

# ------------------------------------------------------------------ main ----

try {
  $script:Config = Get-HelperConfig
  if ($PrinterName -ne '') { $script:Config.printerName = $PrinterName }

  if ($ListPrinters) {
    Get-InstalledPrinters | Select-Object Name, Default, WorkOffline | Format-Table -AutoSize
    exit 0
  }

  $script:Printer = Resolve-Printer -Requested $script:Config.printerName

  if ($SelfTest) {
    Write-Host ('Enviando ticket de prueba a "{0}"...' -f $script:Printer)
    Invoke-SelfTest -Printer $script:Printer
    Write-Host 'Listo. Revisa el papel: acentos, monto grande y corte.' -ForegroundColor Green
    exit 0
  }

  if ($Watch) {
    Start-WatchMode -Config $script:Config -Printer $script:Printer
    exit 0
  }

  if ($Path -ne '') {
    if (-not (Test-Path -LiteralPath $Path)) { throw ('No existe el archivo {0}' -f $Path) }
    $file = Get-Item -LiteralPath $Path
  }
  else {
    $file = Find-LatestOrderFile -Folder $script:Config.downloadsPath
  }

  if (-not $file) {
    Write-Host 'No hay órdenes por imprimir. Descárgalas desde el POS.' -ForegroundColor Yellow
    exit 2
  }

  $result = Invoke-PrintJob -File $file -Config $script:Config -Printer $script:Printer -NoPrompt:$Force
  switch ($result) {
    'printed' { Write-Host ('Impreso: {0}' -f $file.Name) -ForegroundColor Green; exit 0 }
    'cancelled' { Write-Host 'Cancelado.' -ForegroundColor Yellow; exit 3 }
    'busy' { Write-Host 'Ya hay una impresión en curso.' -ForegroundColor Yellow; exit 3 }
  }
  exit 0
}
catch {
  Write-Host ''
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Log ('ERROR      {0}' -f $_.Exception.Message)
  exit 1
}
