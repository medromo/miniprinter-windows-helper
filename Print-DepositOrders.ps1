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
# Font A on the TM-T20II. Also correct in 48-column mode, only narrower.
$SummaryColumns = 42

# ---------------------------------------------------------------- config ----

function Get-HelperConfig {
  $defaults = @{
    printerName          = ''
    downloadsPath        = ''
    archivePath          = ''
    archiveRetentionDays = 30
    pollSeconds          = 3
    printSummary         = $true
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

function Get-OrderSummary {
  param([string]$Text)
  if (-not $Text) { return $null }
  $orders = @()
  foreach ($chunk in ($Text -split "`f")) {
    if ($chunk.Trim() -eq '') { continue }
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

# The account block, read from the same decoded text. Each field degrades on
# its own: a producer that renames one label loses that line from the summary
# and nothing else.
function Get-AccountSummary {
  param([string]$Text)
  if (-not $Text) { return $null }
  $bank = $null
  $number = $null
  $holder = $null
  foreach ($raw in ($Text -split "`n")) {
    $line = $raw.TrimEnd()
    if (-not $bank -and $line -match '^Deposito en:\s+(.+)$') { $bank = $Matches[1].Trim() }
    if (-not $number -and $line -match '^Cuenta:\s+(.+)$') { $number = $Matches[1].Trim() }
    if (-not $holder -and $line -match '^Titular:\s+(.+)$') { $holder = $Matches[1].Trim() }
  }
  if (-not $bank -and -not $number -and -not $holder) { return $null }
  return [PSCustomObject]@{ Bank = $bank; Number = $number; Holder = $holder }
}

function Get-GeneratedStamp {
  param([string]$Text)
  if ($Text -and $Text -match 'Generado:\s*(.+)') { return $Matches[1].Trim() }
  return $null
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

function Measure-OrderTotal {
  param($Orders)
  $total = [decimal]0
  foreach ($order in $Orders) { $total += ConvertTo-Decimal $order.Amount }
  return $total
}

# InvariantCulture on purpose: the amounts on the paper come from the producer
# formatted as $1,234.56, and a station left on a comma-decimal locale would
# print a total that doesn't match the orders it adds up.
function Format-Money {
  param([decimal]$Amount)
  return '$' + $Amount.ToString('N2', [Globalization.CultureInfo]::InvariantCulture)
}

# --------------------------------------------------------------- summary ----

function Format-TwoCol {
  param([string]$Left, [string]$Right)
  $gap = $SummaryColumns - $Left.Length - $Right.Length
  if ($gap -gt 0) { return $Left + (' ' * $gap) + $Right }
  return "$Left $Right"
}

# One extra ticket listing every day in the batch and the grand total, built
# from the same figures the dialog shows. It is the operator's control sheet:
# the orders go to the teller one at a time, and this is the only piece of
# paper that says what the whole trip to the bank adds up to.
function New-SummaryTicket {
  param($Orders, $Account, [string]$Generated)
  $cp437 = [Text.Encoding]::GetEncoding(437)
  $bytes = New-Object System.Collections.Generic.List[byte]
  $add = { param([byte[]]$b) foreach ($x in $b) { $bytes.Add($x) } }
  $line = { param([string]$s) & $add $cp437.GetBytes($s); $bytes.Add(0x0A) }
  $divider = '-' * $SummaryColumns

  & $add ([byte[]](0x1B, 0x40))              # init
  & $add ([byte[]](0x1B, 0x74, 0x00))        # CP437
  & $add ([byte[]](0x1B, 0x61, 0x01))        # center
  & $add ([byte[]](0x1B, 0x45, 0x01))        # bold on
  if ($Account -and $Account.Holder) { & $line $Account.Holder }
  # CP437 has no accented capitals, so every heading here stays unaccented.
  & $line 'RESUMEN DE DEPOSITOS'
  & $add ([byte[]](0x1B, 0x45, 0x00))        # bold off
  & $add ([byte[]](0x1B, 0x61, 0x00))        # left
  & $line $divider

  foreach ($order in $Orders) {
    & $line (Format-TwoCol $order.Date $order.Amount)
  }

  & $line $divider
  & $line (Format-TwoCol 'Ordenes:' ([string]@($Orders).Count))
  & $line 'TOTAL A DEPOSITAR:'
  & $add ([byte[]](0x1B, 0x61, 0x01))        # center
  & $add ([byte[]](0x1D, 0x21, 0x22))        # triple size
  & $add ([byte[]](0x1B, 0x45, 0x01))        # bold on
  & $line (Format-Money (Measure-OrderTotal -Orders $Orders))
  & $add ([byte[]](0x1B, 0x45, 0x00))
  & $add ([byte[]](0x1D, 0x21, 0x00))
  & $add ([byte[]](0x1B, 0x61, 0x00))
  $bytes.Add(0x0A)
  & $line $divider

  if ($Account -and $Account.Bank) { & $line (Format-TwoCol 'Deposito en:' $Account.Bank) }
  if ($Account -and $Account.Number) { & $line (Format-TwoCol 'Cuenta:' $Account.Number) }
  if ($Generated) { & $line (Format-TwoCol 'Generado:' $Generated) }
  & $line (Format-TwoCol 'Impreso:' (Get-Date -Format 'dd/MM/yyyy HH:mm'))
  & $line $divider
  & $line 'Control interno. Este resumen no se'
  & $line 'entrega en el banco.'
  & $add ([byte[]](0x1D, 0x56, 0x42, 0x03))  # feed and partial cut

  return $bytes.ToArray()
}

# ---------------------------------------------------------------- dialog ----

function Show-PrintConfirmation {
  param(
    [System.IO.FileInfo]$File,
    [byte[]]$Bytes,
    [string]$Printer,
    [string]$Text,
    $Orders,
    [switch]$WithSummary
  )
  $lines = New-Object System.Collections.Generic.List[string]

  if ($Orders) {
    $count = @($Orders).Count
    $noun = if ($count -eq 1) { 'orden' } else { 'órdenes' }
    $verb = if ($count -eq 1) { 'Se imprimirá' } else { 'Se imprimirán' }
    $lines.Add(('{0} {1} {2} de depósito:' -f $verb, $count, $noun))
    $lines.Add('')
    foreach ($order in $Orders) {
      $lines.Add(('   {0} — {1}' -f $order.Date, $order.Amount))
    }
    if ($count -gt 1) {
      $lines.Add('')
      $lines.Add(('   Total: {0}' -f (Format-Money (Measure-OrderTotal -Orders $Orders))))
    }
  }
  else {
    $cuts = Measure-CutCount -Bytes $Bytes
    $lines.Add(('{0} órdenes de depósito — no se pudo leer el detalle.' -f $cuts))
  }

  if ($WithSummary) {
    $lines.Add('')
    $lines.Add('Se añadirá un resumen para control interno.')
  }

  $generated = Get-GeneratedStamp -Text $Text

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

    $text = ConvertFrom-EscPos -Bytes $bytes
    $orders = Get-OrderSummary -Text $text

    # A single order already carries its own total in triple size; there is
    # nothing to summarise, and the extra ticket would just be a second copy.
    $summary = $null
    if ($Config.printSummary -and $orders -and @($orders).Count -gt 1) {
      $summary = New-SummaryTicket -Orders @($orders) `
        -Account (Get-AccountSummary -Text $text) `
        -Generated (Get-GeneratedStamp -Text $text)
    }

    if (-not $NoPrompt) {
      $confirmed = Show-PrintConfirmation -File $File -Bytes $bytes -Printer $Printer `
        -Text $text -Orders $orders -WithSummary:($null -ne $summary)
      if (-not $confirmed) {
        Write-Log ('CANCELADO  {0}' -f $File.Name)
        return 'cancelled'
      }
    }

    # Appended to the same job rather than sent as a second one: the summary
    # prints last, so it comes off the stack on top of the orders it covers,
    # and nothing else can slip into the spooler between them.
    $payload = if ($summary) { $bytes + $summary } else { $bytes }
    Send-RawBytes -Printer $Printer -DocumentName $File.BaseName -Payload $payload
    Move-ToArchive -File $File -Config $Config
    $note = if ($summary) { ' +resumen' } else { '' }
    Write-Log ('IMPRESO    {0}  {1:N0} bytes{2}  -> {3}' -f $File.Name, $payload.Length, $note, $Printer)
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
