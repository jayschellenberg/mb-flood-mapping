# schedule_flood_check.ps1 -- register flood-staleness-check.ps1 as a DAILY
# Windows Task Scheduler entry (09:20 local, just after the parcel-search
# watchdogs so the three don't contend). Daily is intentional: the check is
# read-only and cheap, its dedupe stamp means at most ONE reminder a month, and
# a daily cadence still catches staleness if the machine was off on any day.
#
# WHY A WATCHDOG AND NOT AN AUTOMATED RE-FETCH: two of these layers (Designated
# Flood Areas, Red River Valley Special Management Area) are statutory
# boundaries, and the refresh scripts overwrite the files a rendered appraisal
# report cites. Silently replacing that data on a timer would mean a boundary
# could change under a report with nobody having looked. So the schedule's job
# is to make sure a human is TOLD when a re-pull is due; the re-pull itself
# stays a reviewed, three-command operation whose sha256 diffs show what moved.
#
# ---- 2026-08-12: this registers the task as S4U, not Interactive ------------
#
# A Windows Update reboot at 01:31 that day left this machine sitting at the
# logon screen. Every task in this project family was LogonType Interactive, so
# nothing ran for 9.3 h -- and because the watchdogs are themselves tasks, no
# local component was left alive to notice the outage or report it. A staleness
# watchdog has exactly the wrong failure mode here: the silence it produces
# while it is dead is indistinguishable from the silence that means "nothing is
# stale". All 14 tasks were converted to S4U ("run whether the user is logged
# on or not", no stored password) that day, and the block further down is what
# stops a re-run of this registrar from silently undoing that.
#
# THE CROSS-REPO DOT-SOURCE STILL RESOLVES UNDER S4U. flood-staleness-check.ps1
# carries no alert stack of its own on purpose -- it dot-sources
# mb-parcelsearch\alert-lib.ps1 out of the sibling repo, so there is one email
# config and one app password to rotate. A cross-repo dependency running under a
# different logon type is the kind of thing that looks suspect later, so: it is
# fine, and it is fine for a boring reason. $ParcelSearchRoot defaults to the
# plain absolute path D:\Dropbox\ClaudeCode\MBOpenData\mb-parcelsearch (override
# with -ParcelSearchRoot or $env:MB_PARCELSEARCH_ROOT), which depends on no
# mapped drive, no %USERPROFILE% expansion and no logged-on session -- exactly
# the three things an S4U token would have taken away. Verified by a real run
# under the new principal on 2026-08-12 at 17:31, which returned 0 with the
# alert stack loaded.
#
# Idempotent -- re-run to update; the existing task is replaced.
#
# Usage (normal user privileges, no admin needed):
#   powershell -ExecutionPolicy Bypass -File schedule_flood_check.ps1
#
# Manage:
#   Get-ScheduledTask -TaskName mbfloodmapping-staleness | Format-List *
#   Start-ScheduledTask  -TaskName mbfloodmapping-staleness                      # run now
#   Unregister-ScheduledTask -TaskName mbfloodmapping-staleness -Confirm:$false  # cancel

$ErrorActionPreference = "Continue"   # schtasks writes 'task not found' to stderr; don't let it throw
$TaskName  = "mbfloodmapping-staleness"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Checker   = Join-Path $ScriptDir "flood-staleness-check.ps1"

if (-not (Test-Path $Checker)) { Write-Error "Checker not found: $Checker"; exit 1 }

$existing = schtasks /Query /TN $TaskName 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Existing task '$TaskName' found - replacing it."
    schtasks /Delete /TN $TaskName /F | Out-Null
}

$taskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Checker`""

schtasks /Create `
    /SC DAILY `
    /ST 09:20 `
    /TN $TaskName `
    /TR $taskCmd `
    /RL LIMITED `
    /F | Out-Null

if ($LASTEXITCODE -ne 0) { Write-Error "schtasks /Create failed (exit $LASTEXITCODE)"; exit $LASTEXITCODE }

# Battery + catch-up flags (schtasks doesn't expose these).
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Set-ScheduledTask -TaskName $TaskName -Settings $settings | Out-Null

# ---- 2026-08-12: own the task PRINCIPAL, don't leave it Interactive ---------
# schtasks.exe (above) can only ever create an INTERACTIVE task, i.e. one that
# does not run unless Jason is logged on. That is what turned a 01:31 Windows
# Update reboot into 9.3 h of silence on 2026-08-12: the machine sat at the
# logon screen and every task in this family, watchdogs included, was skipped.
#
# For THIS task the stakes are the watchdog's own. Its entire job is to still be
# speaking when a re-pull was forgotten; Interactive stops it running in exactly
# the conditions it exists to report on, and its silence then reads as "no layer
# is stale, nothing has drifted".
#
# The conversion to S4U was done by hand, so without the block below a re-run of
# this registrar for some unrelated reason would quietly put the task back to
# Interactive and re-open the gap with no output saying so. The principal is the
# registrar's business now rather than a manual step somebody has to remember.
#
# Pasted rather than factored into a shared helper: these registrars are the
# bootstrap layer and are standalone on purpose (one that dot-sources a helper
# breaks when the helper moves), and the siblings carrying the identical block
# live in other repos -- mb-parcelsearch, mao-assembly, mao-scrape -- which a
# helper placed here could not reach anyway. Note the deliberate contrast with
# flood-staleness-check.ps1's cross-repo dot-source of alert-lib.ps1: that one
# buys a shared secret and a single place to rotate it, which is worth a
# dependency; this would buy about fifteen saved lines, which is not.
#
# NOT for mao-scrape's MAOSalesSearch / MAOSalesStaleness: those must STAY
# Interactive to read a DPAPI blob an S4U token cannot unlock - see their headers.
#
# Set-ScheduledTask -Principal requires ELEVATION; run unelevated it throws
# "Access is denied." That is caught rather than fatal -- the task is registered
# above and remains usable -- but it is reported loudly, because a task left on
# Interactive that nobody noticed is the whole failure mode described above.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType S4U -RunLevel Limited
try {
    Set-ScheduledTask -TaskName $TaskName -Principal $principal -ErrorAction Stop | Out-Null
} catch {
    Write-Host ""
    Write-Host "**************************************************************************"
    Write-Warning "COULD NOT SET THE S4U PRINCIPAL on '$TaskName'."
    Write-Warning "The task IS registered, but its logon type is still Interactive, so it"
    Write-Warning "will NOT run while you are logged off, nor at the logon screen after a"
    Write-Warning "reboot. That is exactly the 2026-08-12 outage (9.3 h of missed runs),"
    Write-Warning "and a watchdog that cannot run cannot tell you that it did not run."
    Write-Warning "FIX: re-run this registrar from an ELEVATED PowerShell prompt."
    Write-Warning "Underlying error: $($_.Exception.Message)"
    Write-Host "**************************************************************************"
    Write-Host ""
}

# Read the principal back and report what it ACTUALLY is below. Asserting "S4U"
# here would be a lie on precisely the unelevated run where it matters most.
$LogonTypeNow = (Get-ScheduledTask -TaskName $TaskName).Principal.LogonType

Write-Host ""
Write-Host "Scheduled task '$TaskName' registered:"
Write-Host "  Runs:        flood-staleness-check.ps1 daily at 09:20 local"
Write-Host "  Reminds:     once per month per alert kind, on either of two conditions --"
Write-Host "               STALE: the oldest layer in data/layers.yml is older than 365"
Write-Host "                      days (the project family's 12-month rule); or"
Write-Host "               DRIFT: web/data (what Vercel serves) no longer matches data/,"
Write-Host "                      i.e. R/simplify_for_web.R was skipped after a refresh"
Write-Host "  Channels:    email (mb-parcelsearch/alert-email.local.txt) + ntfy push (mbps-flood-refresh-jks)"
Write-Host "  LogonType:   $LogonTypeNow  (S4U = runs while logged off; Interactive = does NOT)"
Write-Host "  StartWhenAvailable enabled (catches up if the machine was off)"
Write-Host ""
Write-Host "Subscribe to the ntfy topic 'mbps-flood-refresh-jks' in the ntfy app to get pushes."
Write-Host ""
Write-Host "Test the alert path now:  powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1 -TestAlert"
Write-Host "Dry-run the decision:     powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1 -DryRun"
Write-Host "Cancel:                   Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
