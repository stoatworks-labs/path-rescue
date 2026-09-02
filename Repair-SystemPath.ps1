<#
.SYNOPSIS
Diagnose and repair a Windows system PATH that an installer replaced instead of
appended to.

.DESCRIPTION
Some stoatworks Windows installers built before 2026-09-02 wrote the machine
PATH without checking that they had read it first. NSIS's ReadRegStr returns an
EMPTY string and sets its error flag when the value is longer than
NSIS_MAX_STRLEN (1024 in the stock build), so on a machine whose PATH exceeded
1024 characters the installer's "append" wrote only ";<install dir>" --
replacing the entire system PATH, System32 included.

This script never guesses silently. It reports what it found and, only with
-Apply, writes a recovered value -- always after saving a backup.

Read-only by default. Run it, read the report, then re-run with -Apply.

.PARAMETER Apply
Actually write the recovered PATH. Without this the script only reports.

.PARAMETER PathKey
Registry key holding the value. Overridable so the tool can be exercised
against a scratch key instead of the live one.

.PARAMETER BackupDir
Where to write backups. Defaults to the user's desktop, falling back to TEMP.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Repair-SystemPath.ps1
  powershell -ExecutionPolicy Bypass -File .\Repair-SystemPath.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$PathKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    [string]$ValueName = 'Path',
    [string]$BackupDir
)

$ErrorActionPreference = 'Continue'

function Write-Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Ok  ($t) { Write-Host "   $t" -ForegroundColor Green }
function Write-Bad ($t) { Write-Host "   $t" -ForegroundColor Red }
function Write-Inf ($t) { Write-Host "   $t" }

# --- reading -----------------------------------------------------------------
# Read the RAW value. Get-ItemProperty and [Environment]::GetEnvironmentVariable
# both expand %SystemRoot%, and writing an expanded value back is its own kind of
# damage -- the tokens are meant to survive.
function Get-RawValue {
    param($Key, $Name)
    try {
        $k = Get-Item -LiteralPath $Key -ErrorAction Stop
        return $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    } catch { return $null }
}

# The value's type matters and is NOT always REG_EXPAND_SZ. A machine whose PATH
# was ever written by `setx /M` or [Environment]::SetEnvironmentVariable holds a
# plain REG_SZ with %SystemRoot% already expanded -- that is a normal state, not
# damage. Restore whatever kind the recovered value actually had rather than
# imposing one, so repairing does not quietly change the type as a side effect.
function Get-ValueKind {
    param($Key, $Name)
    try {
        $k = Get-Item -LiteralPath $Key -ErrorAction Stop
        return $k.GetValueKind($Name)
    } catch { return $null }
}

function Split-PathValue { param([string]$v)
    if ([string]::IsNullOrEmpty($v)) { return @() }
    return @($v -split ';' | Where-Object { $_ -ne '' })
}

# A PATH is "sane" if it can still find the things Windows itself needs.
function Test-SanePath { param([string]$v)
    $entries = Split-PathValue $v
    if ($entries.Count -eq 0) { return $false }
    $joined = ($entries -join ';')
    return ($joined -match '(?i)(%SystemRoot%|C:\\Windows)\\system32')
}

function Describe { param([string]$label, [string]$v)
    $e = Split-PathValue $v
    "{0,-22} {1,5} chars, {2,3} entries, System32: {3}" -f `
        $label, $v.Length, $e.Count, $(if (Test-SanePath $v) { 'yes' } else { 'NO' })
}

# --- recovery sources --------------------------------------------------------
# Each returns a candidate PATH string, or $null.

# 1. Other control sets in the live hive. Cheapest, sometimes holds the
#    pre-damage value because CurrentControlSet is only one of them.
function Get-FromControlSets {
    $out = @()
    Get-ChildItem 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        ForEach-Object {
            $p = "HKLM:\SYSTEM\$($_.PSChildName)\Control\Session Manager\Environment"
            $v = Get-RawValue $p $ValueName
            if ($v) { $out += [pscustomobject]@{ Source = "live $($_.PSChildName)"; Value = $v; Kind = (Get-ValueKind $p $ValueName) } }
        }
    return $out
}

# 2. RegBack. Note: Windows stopped populating this by default in 10 1803, so
#    the files are usually present but zero bytes. Checked, never relied on.
function Get-FromRegBack {
    $f = "$env:SystemRoot\System32\config\RegBack\SYSTEM"
    if (-not (Test-Path $f)) { return @() }
    if ((Get-Item $f).Length -eq 0) {
        Write-Inf "RegBack\SYSTEM exists but is 0 bytes (disabled by default since Windows 10 1803)"
        return @()
    }
    return Read-HiveCandidates -HiveFile $f -Label 'RegBack'
}

# 3. Volume Shadow Copies / System Restore points. Highest fidelity: a real
#    snapshot of the hive from before the installer ran.
function Get-FromShadows {
    $out = @()
    $raw = & vssadmin list shadows 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { Write-Inf "no shadow copies available (vssadmin returned nothing)"; return $out }
    $vols = $raw | Select-String 'Shadow Copy Volume: (.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    foreach ($v in $vols) {
        $hive = Join-Path $v 'Windows\System32\config\SYSTEM'
        $out += Read-HiveCandidates -HiveFile $hive -Label "shadow $($v.Split('\')[-1])"
    }
    return $out
}

# Load an offline SYSTEM hive and read every control set's PATH out of it.
function Read-HiveCandidates {
    param([string]$HiveFile, [string]$Label)
    $out = @()
    $mount = 'StoatworksPathRepair'
    & reg load "HKLM\$mount" "$HiveFile" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $out }
    try {
        Get-ChildItem "HKLM:\$mount" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
            ForEach-Object {
                $p = "HKLM:\$mount\$($_.PSChildName)\Control\Session Manager\Environment"
                $v = Get-RawValue $p $ValueName
                if ($v) { $out += [pscustomobject]@{ Source = "$Label $($_.PSChildName)"; Value = $v; Kind = (Get-ValueKind $p $ValueName) } }
            }
    } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg unload "HKLM\$mount" 2>$null | Out-Null
    }
    return $out
}

# --- main --------------------------------------------------------------------
Write-Head "Current system PATH"
$current = Get-RawValue $PathKey $ValueName
if ($null -eq $current) { Write-Bad "could not read $PathKey\$ValueName -- run this as Administrator."; exit 1 }
Write-Inf (Describe 'current' $current)

if (Test-SanePath $current) {
    Write-Ok "This PATH still resolves System32. Nothing here needs repairing."
    Write-Inf "If something else is wrong, this tool is not the right one -- stop here."
    exit 0
}

Write-Bad "DAMAGED: the system PATH no longer contains System32."
Write-Inf "Value: $current"

Write-Head "Looking for a pre-damage copy"
$cands = @()
$cands += Get-FromControlSets
$cands += Get-FromRegBack
$cands += Get-FromShadows

$good = @($cands | Where-Object { Test-SanePath $_.Value } |
          Sort-Object { (Split-PathValue $_.Value).Count } -Descending)

if ($good.Count -eq 0) {
    Write-Bad "No usable copy of the old PATH was found."
    Write-Inf ""
    Write-Inf "Recover by hand instead:"
    Write-Inf "  * System Restore to a point before the install (keeps your files), or"
    Write-Inf "  * rebuild the minimum by running this in an ADMIN prompt:"
    Write-Inf ""
    Write-Inf '    setx /M Path "%SystemRoot%\system32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0\;%SystemRoot%\System32\OpenSSH\"'
    Write-Inf ""
    Write-Inf "    NOTE: setx itself truncates at 1024 characters -- the very limit that"
    Write-Inf "    caused this bug. It is safe for the short default above, but do NOT use"
    Write-Inf "    setx to restore a long PATH. Use the Environment Variables editor"
    Write-Inf "    (sysdm.cpl -> Advanced) or Set-ItemProperty, neither of which truncates."
    Write-Inf ""
    Write-Inf "  then re-add anything else you had. Your USER PATH was not touched,"
    Write-Inf "  so per-user tool entries should still be intact."
    exit 2
}

foreach ($c in $good) { Write-Ok (Describe $c.Source $c.Value) }
$best = $good[0]

Write-Head "Proposed repair"
Write-Inf "source : $($best.Source)"
Write-Inf "value  : $($best.Value)"
$missing = @(Split-PathValue $best.Value | Where-Object { (Split-PathValue $current) -notcontains $_ })
Write-Inf "restores $($missing.Count) entries that the current PATH has lost"

if (-not $Apply) {
    Write-Head "Dry run"
    Write-Inf "Nothing was changed. Re-run with -Apply to write this value."
    exit 0
}

# --- apply -------------------------------------------------------------------
if (-not $BackupDir) {
    $desk = [Environment]::GetFolderPath('Desktop')
    $BackupDir = if ($desk -and (Test-Path $desk)) { $desk } else { $env:TEMP }
}
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupDir "system-path-backup-$stamp.txt"
$current | Set-Content -LiteralPath $backup -Encoding UTF8
Write-Head "Applying"
Write-Ok "backed up the damaged value to $backup"

# Write as REG_EXPAND_SZ so %SystemRoot% keeps working. Set-ItemProperty with an
# explicit type is correct here; [Environment]::SetEnvironmentVariable is not --
# it can rewrite the value as a plain string with the tokens already expanded.
$kind = if ($best.Kind) { $best.Kind } elseif ($best.Value -match '%') { 'ExpandString' } else { 'String' }
Write-Inf "writing as $kind (the type the recovered value already had)"
Set-ItemProperty -LiteralPath $PathKey -Name $ValueName -Value $best.Value -Type $kind
$after = Get-RawValue $PathKey $ValueName
if ($after -eq $best.Value) { Write-Ok "PATH written and read back identical." }
else { Write-Bad "read-back did NOT match -- inspect manually before rebooting."; exit 3 }

# Tell the running session, so a new console picks it up without a reboot.
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
try {
    $r = [UIntPtr]::Zero
    [Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r) | Out-Null
    Write-Ok "broadcast WM_SETTINGCHANGE"
} catch { Write-Inf "could not broadcast the change; a reboot will apply it" }

Write-Head "Done"
Write-Inf "Open a NEW terminal and check: where.exe ping"
