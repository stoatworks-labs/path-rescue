# path-rescue

Recover a Windows **system PATH** that an installer replaced instead of appended to.

## What went wrong

Stoatworks Windows installers built before 2026-09-02 added their install directory
to the machine PATH by reading the current value and writing `<old>;<new>` back —
without checking that the read had succeeded.

NSIS's `ReadRegStr` returns an **empty string** (and sets its error flag) when the
value is longer than `NSIS_MAX_STRLEN`, which is 1024 characters in the stock NSIS
build. A real Windows system PATH very often exceeds that. When it did, the append
became `;C:\Program Files\<product>` written over the entire value — `System32`
included, so `ping` and most other commands stopped resolving.

Measured, not assumed:

| registry value | length | `ReadRegStr` returned | error flag |
|---|---|---|---|
| short | 100 chars | 100 chars | no |
| long | 1500 chars | **0 chars** | **yes** |

The trigger is therefore *your PATH was already over 1024 characters*. A build
machine's PATH is short, which is why this was never seen before release.

This is fixed at the source: the PATH write is now guarded, and plugins — which
never needed a PATH entry at all — no longer touch it. Releases from 2026-09-02
onward are clean.

## Using the script

Run it from an **Administrator** PowerShell. It is read-only by default.

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-SystemPath.ps1
```

It reports the current PATH, says whether it looks damaged, and — if it is — hunts
for a pre-damage copy in your Volume Shadow Copies, `RegBack`, and the other control
sets in the registry. Nothing is written.

When you are happy with what it proposes:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-SystemPath.ps1 -Apply
```

`-Apply` saves a backup of the damaged value to your desktop first, writes the
recovered PATH preserving the value's original type, reads it back to confirm, and
broadcasts the change so a new terminal picks it up without a reboot.

## If it finds nothing

Your **user** PATH is untouched — only the machine-wide one was affected — so
per-user entries should still be intact.

1. **System Restore** to a point before the install. Highest fidelity, keeps files.
2. Rebuild the minimum from an Administrator prompt:

   ```
   setx /M Path "%SystemRoot%\system32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0\;%SystemRoot%\System32\OpenSSH\"
   ```

   then re-add anything else you had.

> [!WARNING]
> `setx` truncates at 1024 characters — the same limit that caused this bug. It is
> safe for the short default above, but never use `setx` to restore a long PATH.
> Use the Environment Variables editor (`sysdm.cpl` → Advanced) or
> `Set-ItemProperty`, neither of which truncates.

`C:\Windows\System32\config\RegBack` is worth checking but is usually zero bytes —
Windows stopped populating it by default in Windows 10 1803.

## Reporting

Originally reported as [nib#2](https://github.com/stoatworks-labs/nib/issues/2).
