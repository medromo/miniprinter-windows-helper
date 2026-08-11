# miniprinter-windows-helper

Sends raw ESC/POS files to a receipt printer on a Windows station, with a
confirmation dialog that shows what is about to print.

It was built for one job: a web app produces deposit orders as a raw byte stream
and hands them to the browser as a download; this helper picks the file up and
puts it on paper on an **Epson TM-T20II**. Nothing about it is specific to that
app beyond the preview decoder, so it works for any ESC/POS stream that opens
with `ESC @`.

Three files, no dependencies, no installer. Everything it uses ships with
Windows.

| File | What it is |
| --- | --- |
| `Print-DepositOrders.ps1` | The whole helper. UTF-8 **with BOM**, CRLF. |
| `print-orders.cmd` | The launcher. **The way everything is run.** |
| `config.json` | Overrides for the defaults. Plain UTF-8, **no** BOM. |

## Why raw spooling and not a shared printer

The obvious approach is to share the printer and `copy /b file \\PC\TICKET`. It
works, but it needs File and Printer Sharing turned on, a share name that
survives every rename, and it reports failure as a generic "the network path was
not found". The `/b` is also load-bearing in a way nobody remembers six months
later: without it, `copy` stops at the first `0x1A` byte in the stream.

This opens the printer by its **local** name instead and writes the bytes to the
spooler with datatype `RAW`, through `winspool.drv` (`OpenPrinter` →
`StartDocPrinter` → `WritePrinter`). No share, no network, and every call returns
a real Win32 error code. It is the same path the printer vendor's own utilities
use.

## What it does

Two modes, one script, sharing the whole core:

- **Watch** (`-Watch`) — the normal path. Sits in the system tray, polls the
  Downloads folder, and the moment a matching file lands it shows the
  confirmation dialog. Confirm, paper comes out, file is archived.
- **One-shot** (no arguments) — a desktop shortcut that prints the most recent
  file. This is the **fallback**, not a redundancy: it is what you use when the
  watcher isn't running, and with `-Path` it reprints something out of the
  archive.

Both go through the same sequence:

1. **Resolve the printer** against `Win32_Printer`. If `printerName` isn't
   configured, it auto-picks when exactly one installed printer matches
   `TM-T20`; otherwise it lists what's installed and stops. It never prints to a
   guess.
2. **Validate the file before spending paper** — non-empty, under 1 MB, and
   starts with `1B 40` (`ESC @`). That magic check is what stops an unrelated
   `.bin` from being pushed at the printer as if it were ours.
3. **Decode the preview** (see below) and show it for confirmation.
4. **Print RAW**, with the file name as the spooler document name so the job is
   identifiable in the queue.
5. **Archive** the file with a timestamp prefix and prune anything older than the
   retention window. Moved, not deleted: it can't be reprinted by accident and
   there's a trail.

   Deliberately **not** left under Downloads. That folder is the operator's
   scratch space — they clear it, and Storage Sense clears it for them — which is
   no place for a record meant to survive a month.
6. **Log** the outcome to `%LOCALAPPDATA%\MascotasYMas\logs\print-orders.log`.

### The confirmation dialog

`System.Windows.Forms` ships with the .NET Framework that is already on every
Windows install, so the dialog costs nothing to add and needs no dependency.

It shows what is actually about to print, not just a file name:

```
Se imprimirán 3 órdenes de depósito:

  09 ago 2026 — $12,450.00
  10 ago 2026 — $8,320.50
  11 ago 2026 — $15,000.00

  Total: $35,770.50

Archivo:   2026-08-11-ordenes-deposito.bin
Generado:  11/08/2026 14:32
Impresora: EPSON TM-T20II Receipt

¿Imprimir?
```

Those figures are read out of the file itself. The stream is CP437 text with six
control sequences, all of them fixed length (`ESC @`, `ESC t`, `ESC E`, `ESC a`,
`GS !`, `GS V`), so stripping them and decoding with code page 437 reconstructs
exactly what the paper will say. The cut sequence becomes a form feed, which is
what separates one order from the next.

**On anything it doesn't recognise it degrades instead of guessing.** An unknown
escape sequence aborts the decode and the dialog falls back to
`N órdenes — no se pudo leer el detalle`, still offering to print. The count in
that fallback is a byte scan for cut sequences, which can't be wrong.

Showing the `Generado` timestamp is also what replaces a separate "this file is
old" guard: a file from yesterday is self-evident once the date is on screen. The
dialog still switches to a warning icon and adds a line when the file is more
than two hours old.

### Why polling instead of FileSystemWatcher

`FileSystemWatcher` is the obvious tool and the wrong one here. It drops events
when its internal buffer overflows, behaves differently on network paths, and
fires on the browser's partial-download files (`.crdownload`, `.tmp`) which are
then renamed. Listing one folder every three seconds has none of those cases and
costs nothing measurable.

Either way the file has to be **stable** before it's read — unchanged size plus
an exclusive open that succeeds — because a download in progress is a truncated
ESC/POS stream, and a truncated stream still prints.

### Why there's a tray icon

A background process that died is worse than no background process: the operator
downloads, nothing happens, and there is no way to tell whether the helper is
dead or slow. So they stand there waiting for paper that is never coming.

`NotifyIcon` comes from the same assembly the dialog already loads and takes its
image from `[System.Drawing.SystemIcons]`, so it adds no files. It answers "is
this thing alive" at a glance, and its menu carries the manual escape hatches.

**Accept the operational cost knowingly**: this is a resident process on a
machine nobody administers. It dies on a Windows update, someone closes it from
the tray, a profile change stops it from starting. The tray icon and the one-shot
shortcut exist precisely so that is detectable and recoverable.

## Configuration

Every field in `config.json` is optional; the file exists only to override a
default.

```json
{
  "printerName": "EPSON TM-T20II Receipt",
  "downloadsPath": "",
  "archivePath": "",
  "archiveRetentionDays": 30,
  "pollSeconds": 3
}
```

Leave `printerName` as `""` to let it auto-detect, `downloadsPath` as `""` for
`%USERPROFILE%\Downloads`, and `archivePath` as `""` for an `ordenes-impresas`
folder beside the script.

Point `archivePath` at an absolute path outside the install folder if you ever
expect to replace that folder wholesale — otherwise the archive goes with it.

Save `config.json` as plain UTF-8 **without** BOM. Unlike the `.ps1`, a BOM here
is what breaks a strict JSON parser.

## Installing

> **Always go through `print-orders.cmd`, never the `.ps1` directly.** A default
> Windows install refuses to run an unsigned `.ps1`
> (`la ejecución de scripts está deshabilitada en este sistema`), and the
> launcher carries `-ExecutionPolicy Bypass` for its own invocation — which is
> the whole reason it exists. It takes the same arguments and works identically
> from PowerShell or the Command Prompt.
>
> Do **not** loosen the machine's execution policy to work around this. Every
> entry point (launcher, shortcut, scheduled task) already bypasses it, so there
> is nothing to fix.

1. **Copy the three files** to the station — `C:\mascotasymas\print-helper\` is
   the path the rest of this document assumes.

   Copy them **as files**. Pasting the script's text into Notepad on the station
   is what loses the BOM.

2. **Verify the BOM.** This one is a PowerShell expression rather than a call to
   the launcher, so run it **from PowerShell**, not from `cmd`:

   ```powershell
   (Get-Content .\Print-DepositOrders.ps1 -Encoding Byte -TotalCount 3) -join ','
   ```

   It must print `239,187,191`. Anything else means the BOM was lost — re-save
   it, accents will be broken otherwise.

   The BOM is three bytes (`EF BB BF`) at the start of the file declaring "this
   is UTF-8". Windows PowerShell 5.1 predates UTF-8 being the default, so without
   them it reads the `.ps1` as ANSI and every accented character in its messages
   turns to mojibake (`Órdenes` → `Ã"rdenes`). To restore it after a bad save:

   ```powershell
   $path = 'C:\mascotasymas\print-helper\Print-DepositOrders.ps1'
   $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
   [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
   ```

   That only rescues a file saved as UTF-8 *without* BOM. Saved as **ANSI**, the
   accents were already destroyed on write — copy the file again.

   (`-Encoding Byte` is Windows PowerShell 5.1 syntax. In PowerShell 7 the same
   check is `Get-Content … -AsByteStream -TotalCount 3`. From `cmd`, wrap it:
   `powershell -NoProfile -Command "(Get-Content .\Print-DepositOrders.ps1 -Encoding Byte -TotalCount 3) -join ','"`.)

3. **Find the printer name** and put it in `config.json`:

   ```
   .\print-orders.cmd -ListPrinters
   ```

   The name has to match **exactly** — the script compares with `-eq`, not
   loosely.

   Auto-detection handles the common case, but pinning the name means a second
   TM-T20 appearing on the machine can't silently change where paper comes out.

4. **Run the self test** and check the paper:

   ```
   .\print-orders.cmd -SelfTest
   ```

   Look for three things: the accented line reads correctly (CP437 is right), the
   amount is large and bold (`GS ! 0x22` is right), and the paper is cut
   (`GS V 66 3` is right). Those are exactly the three the real file depends on.

5. **Create the desktop shortcut.** Right-click `print-orders.cmd` → *Mostrar más
   opciones* on Windows 11 (or Shift + right-click to skip that) → *Enviar a* →
   *Escritorio (crear acceso directo)*, then rename it *Imprimir órdenes de
   depósito*.

   In its Properties, set an icon — *Cambiar icono* →
   `%SystemRoot%\System32\imageres.dll` → pick the printer. A `.cmd` shortcut
   otherwise inherits the black-console icon, which tells the operator nothing.

   Leave *Ejecutar* on **Ventana normal**. The window flashes and closes on
   success, but stays open with the message on failure; minimized, that failure
   is invisible.

   This is the fallback path — it stays useful even once the watcher is running.

6. **Install the watcher** as a scheduled task, so it starts with the session and
   has no console window.

   This is the one place that calls `powershell.exe` directly instead of the
   launcher, and passes the bypass itself: going through the `.cmd` would open a
   Command Prompt window on top of the PowerShell one, and there would be no way
   to hide it.

   Task Scheduler → **Create Task** (not "Basic Task"), then:

   - **General** — give it a name (*Órdenes de depósito — watcher*). *Run only
     when user is logged on*. Tick **Hidden**. Leave *Run with highest
     privileges* unticked; it needs no elevation. Set **Configure for: Windows
     10** — the dialog defaults to *Windows Vista / Server 2008*, an old
     compatibility level that quietly disables newer scheduler behaviour.
   - **Triggers** — *At log on*, **Specific user**, the station's account. With
     "Any user" the task fires on every logon but can only run in its own
     account's session, so other logons just produce failed attempts. Optionally
     *Delay task for 30 seconds*: logon is the busiest moment of the boot, and
     the tray icon appearing once the desktop has settled is more reliable.
   - **Actions** — Start a program
     - Program: `powershell.exe`
     - Arguments:
       `-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\mascotasymas\print-helper\Print-DepositOrders.ps1" -Watch`
     - *Start in*: `C:\mascotasymas\print-helper`. Not required — the script
       resolves `config.json` and the archive from `$PSScriptRoot`, not the
       working directory — but left empty the task runs out of `System32`.
   - **Conditions** — untick *Start the task only if the computer is on AC
     power*, or the watcher won't start on battery.
   - **Settings** — untick *Stop the task if it runs longer than…*; left on, it
     kills the watcher after three days with no indication why. Leave *If the
     task is already running: Do not start a new instance*, so two watchers can't
     compete. Optionally tick *If the task fails, restart every 1 minute, up to 3
     times*.

   There is still a brief console flash at logon. If that bothers you, point the
   action at a one-line `.vbs` shim that runs the same command with
   `WScript.Shell.Run(cmd, 0, False)` instead.

7. **Accept the install** in three steps, in this order — each one proves
   something the previous cannot:

   - Right-click the task → **Run**. The tray icon and its balloon appear. This
     proves the arguments and the script itself are right.
   - **Restart the machine.** The icon comes back on its own. This proves the
     trigger fires, which running it on demand never exercises.
   - **Drop a `.bin` into Downloads** and confirm the dialog appears with the
     right days and amounts. Any file from `ordenes-impresas\` will do — you
     don't need a live run. This proves the polling, the stability check and the
     decoder.

   Stopping after the first step is the common mistake: a task that runs
   perfectly on demand and never fires at logon looks identical until the morning
   nobody's deposit orders print.

## Day to day

Download the orders from the app. Within a few seconds the dialog appears with
the days and amounts; confirm and the printer cuts one order per day. The file
moves to `ordenes-impresas\` and stays there for a month.

To reprint one, point the launcher at the archived file:

```
.\print-orders.cmd -Path ".\ordenes-impresas\20260811-143210-2026-08-11-ordenes-deposito.bin"
```

Reprinting from the archive leaves the file where it is — it doesn't collect a
second timestamp prefix.

Exit codes: `0` printed, `1` error, `2` nothing to print, `3` cancelled or busy.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `la ejecución de scripts está deshabilitada en este sistema` | The `.ps1` was called directly. Use `print-orders.cmd` instead — don't change the execution policy. |
| Nothing happens after downloading | The watcher isn't running — no tray icon. Use the shortcut, then check the scheduled task. |
| `No existe una impresora llamada '…'` | The printer was renamed or reinstalled. The message lists what's installed; update `config.json`. |
| Dialog says *no se pudo leer el detalle* | The producer emits a control sequence the decoder doesn't know. Printing still works; see the format note below. |
| `OpenPrinter falló` | Printer offline, unplugged, or a driver that's gone. Check it in Windows first. |
| Job appears in the queue and stalls | Spooler wedged. `Restart-Service Spooler`, clear the queue, retry. |
| Accents print as garbage | The printer was left on another code page by other software, or the `.ps1` was saved without the BOM. `ESC t 0` is sent per job, so suspect the BOM first. |
| Everything prints on one long strip | The cut command isn't reaching the printer — usually a driver installed as "Generic / Text Only" rather than the Epson driver. RAW needs the real driver. |

## The file format it expects

The helper depends on the byte format in exactly two places, and both fail
safely:

- **The magic check** (`ESC @` as the first two bytes) — every ESC/POS stream
  opens with it, and moving it would break real printers too.
- **The preview decoder** — it knows six fixed-length control sequences: `ESC @`
  (2), `ESC t` (3), `ESC E` (3), `ESC a` (3), `GS !` (3), `GS V` (4). Add a
  seventh — underline, a barcode, a logo — and the decode aborts, the dialog
  drops to the order count, and printing carries on unaffected. If you add one,
  add its length to `ConvertFrom-EscPos`.

Nothing else is shared with whatever produced the file. The helper never parses
folios, branches, or anything the bank teller shouldn't be shown anyway.
