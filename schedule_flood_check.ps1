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

Write-Host ""
Write-Host "Scheduled task '$TaskName' registered:"
Write-Host "  Runs:        flood-staleness-check.ps1 daily at 09:20 local"
Write-Host "  Reminds:     once per month, only when the oldest layer in data/layers.yml"
Write-Host "               is older than 365 days (the project family's 12-month rule)"
Write-Host "  Channels:    email (mb-parcelsearch/alert-email.local.txt) + ntfy push (mbps-flood-refresh-jks)"
Write-Host "  StartWhenAvailable enabled (catches up if the machine was off)"
Write-Host ""
Write-Host "Subscribe to the ntfy topic 'mbps-flood-refresh-jks' in the ntfy app to get pushes."
Write-Host ""
Write-Host "Test the alert path now:  powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1 -TestAlert"
Write-Host "Dry-run the decision:     powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1 -DryRun"
Write-Host "Cancel:                   Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
