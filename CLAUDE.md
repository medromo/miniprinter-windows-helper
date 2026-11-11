# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows-only helper that sends raw ESC/POS files (deposit orders downloaded from the POS web app) to an Epson TM-T20II via the spooler, after a WinForms confirmation dialog that previews what will print. Target runtime is **Windows PowerShell 5.1** with nothing installed beyond stock Windows. `README.md` is the operator/install manual and explains the design rationale at length — read it before changing behaviour.

Three files: `Print-DepositOrders.ps1` (everything), `print-orders.cmd` (launcher that adds `-ExecutionPolicy Bypass`; the only supported entry point), `config.json` (optional overrides, including `filePatterns`, the file-name wildcards the watcher picks up). `install-helper.ps1` installs and, when run again, updates: it downloads the repo from GitHub (so it installs what is pushed), stops the watcher while holding the helper's print mutex, replaces the scripts (itself included), adds new `config.json` fields without touching existing ones, and restarts the scheduled task. It must also be UTF-8 with BOM + CRLF.

## Development constraints

- Development happens on macOS; there is no `pwsh` here, no build, no test suite, no linter. The script can only really be exercised on the Windows station. Verification on a real machine is: `print-orders.cmd -SelfTest`, then drop an archived `.bin` into Downloads with the watcher running.
- **Encoding is load-bearing** (enforced by `.gitattributes` `* -text`):
  - `Print-DepositOrders.ps1` must stay **UTF-8 with BOM + CRLF**. PS 5.1 reads BOM-less files as ANSI and every accented user-facing string turns to mojibake. Check after editing: `head -c 3 Print-DepositOrders.ps1 | xxd` → `efbb bf`; `file Print-DepositOrders.ps1` → "with CRLF line terminators".
  - `config.json` must be UTF-8 **without** BOM, otherwise the JSON parse fails.
- Stick to PS 5.1 / .NET Framework APIs (e.g. `Get-Content -Encoding Byte`, not `-AsByteStream`); no modules, no external dependencies.
- User-facing strings (dialog, console, tray) are in Spanish; code and comments are in English.

## Architecture (`Print-DepositOrders.ps1`, sections marked by `# ---- name ----` banners)

Flow for both modes (`-Watch` tray poller, or one-shot printing the latest file / `-Path`), converging on `Invoke-PrintJob`:

1. `Resolve-Printer` — exact `-eq` match against `Win32_Printer`; with no configured name, auto-picks only if exactly one printer matches `TM-T20`. Never guesses.
2. Validate: non-empty, < 1 MB, first two bytes `1B 40` (`ESC @`).
3. Preview: `ConvertFrom-EscPos` → `Get-OrderSummary` → `Show-PrintConfirmation`. Only files named `*-ordenes-deposito*.bin` (`$DepositOrderPattern`) get per-day detail, or the "no se pudo leer el detalle" warning when it doesn't parse; other `filePatterns` matches (tickets) only show a ticket count.
4. `Send-RawBytes` — P/Invoke into `winspool.drv` (`OpenPrinter`/`StartDocPrinter`/`WritePrinter`, datatype `RAW`), type compiled via `Add-Type` in `Initialize-RawPrinterType`. Deliberately not a shared printer + `copy /b`.
5. `Move-ToArchive` — timestamp prefix, into `ordenes-impresas\` beside the script (not Downloads), prune past retention. Reprints from the archive are not re-moved.
6. `Write-Log` to `%LOCALAPPDATA%\MascotasYMas\logs\print-orders.log`.

Exit codes: `0` printed, `1` error, `2` nothing to print, `3` cancelled/busy (the `.cmd` pauses on anything but 0 and 3).

Watch mode polls the folder every `pollSeconds` instead of using `FileSystemWatcher` (by design — see README), and requires `Wait-FileStable` (unchanged size + exclusive open) before reading.

### Coupling to the producer's format (`depositOrders.ts` in the POS app)

The **only** contract with the producer, and every point must fail safe (preview degrades, printing still works byte-for-byte; the helper never rewrites the stream):

- `ConvertFrom-EscPos` knows exactly six fixed-length sequences: `ESC @`(2), `ESC t`(3), `ESC E`(3), `ESC a`(3), `GS !`(3), `GS V`(4, becomes `\f` as order separator). Any unknown sequence returns `$null` → dialog falls back to a count from `Measure-CutCount` (byte scan for `GS V B`). If the producer adds a sequence, add its length here.
- Text is decoded as CP437. `Get-OrderSummary` reads labels `Dia de ventas:`, `Monto a depositar:` (amount on a following line), and `Generado:`.
- The trailing recap ticket headed `RESUMEN DE DEPOSITOS` is produced by the POS app, not this helper (a helper-side summary was added and reverted). It is skipped **by its heading only** (`Test-HasSummaryTicket`); any other chunk that fails to parse must abort the whole preview rather than be silently skipped.

When changing the format contract, keep the README's "The file format it expects" section in sync.
