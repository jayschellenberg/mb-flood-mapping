# flood-staleness-check.ps1 -- staleness watchdog for the Manitoba flood layers
# (email + ntfy push when the newest data/layers.yml refresh is overdue).
#
# Context: unlike its sibling projects, MBFloodMapping had NO automation at all
# -- no scheduled refresh, no watchdog, no documented cadence. Every layer was
# fetched once on 2026-04-21 by hand and nothing has moved since. That matters
# more here than elsewhere because the rendered report prints the refresh date
# into client-facing narrative text ("publicly available provincial mapping as
# of <date>"), and because two of the layers -- the Designated Flood Areas and
# the Red River Valley Special Management Area -- are STATUTORY boundaries under
# the Water Resources Administration Act / Planning Act. A stale answer there is
# an appraisal-defensibility problem, not a cosmetic one.
#
# This check is deliberately the cheap half of the fix: it reads only what a
# refresh leaves behind (the refreshed_iso stamps in data/layers.yml), so it
# notices staleness no matter WHY the refresh didn't happen -- including the
# most likely reason, which is that nobody remembered.
#
# Threshold: 365 days by default, matching the project family's standing
# 12-month freshness rule. The historical flood extents (1997/2009/2011) never
# change, but the 1-in-200 extent and the statutory boundaries do, and there is
# no upstream change feed to watch -- so an annual re-pull is the honest cadence.
#
# Robustness:
#   * A stamp file (logs\flood-alert-stamp.txt) dedupes to at most ONE reminder
#     per calendar month, even though the task runs daily.
#   * Reuses the shared alert stack from the mb-parcelsearch repo (alert-lib.ps1
#     + the gitignored alert-email.local.txt), so there is no second email
#     config to maintain. Its own ntfy topic keeps flood reminders separable
#     from parcel ones.
#   * Parses layers.yml with a line regex rather than a YAML module: the file is
#     machine-generated with one flat `refreshed_iso:` per layer, and this way
#     the watchdog has no package dependency that could rot independently.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1             # real check
#   powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1 -DryRun     # decide + print, never send
#   powershell -ExecutionPolicy Bypass -File flood-staleness-check.ps1 -TestAlert  # send a test alert and exit
#   ... -MaxAgeDays 365 -ParcelSearchRoot "<path>"                                 # overrides
#
# Scheduled via schedule_flood_check.ps1 (daily; stamp keeps it to one reminder
# per month). ASCII-only on purpose so Windows PowerShell 5.1 parses it without
# a BOM.

param(
  [int]$MaxAgeDays = 365,
  [string]$ParcelSearchRoot = $(if ($env:MB_PARCELSEARCH_ROOT) { $env:MB_PARCELSEARCH_ROOT }
                               else { 'D:\Dropbox\ClaudeCode\MBOpenData\mb-parcelsearch' }),
  [switch]$TestAlert,
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$LayersYml = Join-Path $root 'data\layers.yml'
$StampFile = Join-Path $root 'logs\flood-alert-stamp.txt'
$NtfyTopic = 'mbps-flood-refresh-jks'

# The alert stack lives in the parcel-search repo; this project has no copy of
# its own on purpose (one email config, one place to rotate an app password).
$AlertLib = Join-Path $ParcelSearchRoot 'alert-lib.ps1'
if (-not (Test-Path $AlertLib)) {
  Write-Error "alert-lib.ps1 not found at $AlertLib -- pass -ParcelSearchRoot or set MB_PARCELSEARCH_ROOT."
  exit 1
}
. $AlertLib

if ($TestAlert) {
  $ok = Send-FailureAlert $ParcelSearchRoot $NtfyTopic 'TEST - MB flood data staleness watchdog' `
    ("Test alert from flood-staleness-check.ps1 on $env:COMPUTERNAME at $(Get-Date -Format s).`n" +
     'If this reached you, the flood-layer staleness watchdog is wired up.')
  if ($ok) { exit 0 } else { exit 1 }
}

$now = Get-Date

# --- read every layer's refresh stamp ---------------------------------------
if (-not (Test-Path $LayersYml)) {
  Write-Error "layers.yml not found at $LayersYml -- has the flood data ever been fetched?"
  exit 1
}

$names = @()
$stamps = @()
foreach ($line in Get-Content $LayersYml) {
  $n = [regex]::Match($line, '^\s*-?\s*name:\s*(\S+)\s*$')
  if ($n.Success) { $names += $n.Groups[1].Value; continue }
  $r = [regex]::Match($line, '^\s*refreshed_iso:\s*(\S+)\s*$')
  if ($r.Success) {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($r.Groups[1].Value, [ref]$parsed)) {
      $stamps += [pscustomobject]@{
        Name = if ($names.Count -ge ($stamps.Count + 1)) { $names[$stamps.Count] } else { '(unnamed)' }
        When = $parsed
      }
    }
  }
}

if ($stamps.Count -eq 0) {
  Write-Error "No parsable refreshed_iso stamps in $LayersYml -- cannot judge staleness."
  exit 1
}

$oldest    = $stamps | Sort-Object When | Select-Object -First 1
$newest    = $stamps | Sort-Object When -Descending | Select-Object -First 1
$oldestAge = [int]($now.Date - $oldest.When.Date).TotalDays
$newestAge = [int]($now.Date - $newest.When.Date).TotalDays

if ($oldestAge -le $MaxAgeDays) {
  Write-Host "Flood layers current: oldest $($oldest.Name) $oldestAge days, newest $newestAge days; threshold $MaxAgeDays. No reminder."
  exit 0
}

if ($DryRun) {
  Write-Host "DRYRUN - STALE detected (threshold $MaxAgeDays days). Oldest: $($oldest.Name) at $oldestAge days. $($stamps.Count) layers checked. No alert sent."
  exit 0
}

# Dedupe -- one reminder per calendar month.
$stampVal = $now.ToString('yyyy-MM')
if ((Test-Path $StampFile) -and ((Get-Content $StampFile -Raw).Trim() -eq $stampVal)) {
  Write-Host "Already reminded this month ($stampVal) -- skipping."
  exit 0
}

$title = 'STALE - MB flood layers overdue for refresh'
$body  = @"
The Manitoba flood layers are past the $MaxAgeDays-day freshness rule.

  Oldest layer  : $($oldest.Name) -- $oldestAge days old ($($oldest.When.ToString('yyyy-MM-dd')))
  Newest layer  : $($newest.Name) -- $newestAge days old ($($newest.When.ToString('yyyy-MM-dd')))
  Layers checked: $($stamps.Count)
  Manifest      : $LayersYml

This matters more than a normal staleness nudge: the Designated Flood Area and
Red River Valley Special Management Area layers are STATUTORY boundaries, and
the rendered flood report prints the refresh date into client-facing text.

To refresh (all three steps, in order):

  1. Rscript "$root\R\refresh_flood_data.R"
  2. Rscript "$root\R\fetch_winnipeg_waterway_corridors.R"
  3. Rscript "$root\R\simplify_for_web.R"

Then review the layers.yml sha256 diffs to see which sources actually changed,
and redeploy the web app if data\ or web\data\ moved.

Checked $($now.ToString('s')) on $env:COMPUTERNAME by flood-staleness-check.ps1.
Stop these reminders:  Unregister-ScheduledTask -TaskName mbfloodmapping-staleness -Confirm:`$false
"@

if (Send-FailureAlert $ParcelSearchRoot $NtfyTopic $title $body) {
  New-Item -ItemType Directory -Force -Path (Split-Path $StampFile) | Out-Null
  Set-Content -Path $StampFile -Value $stampVal
  Write-Host "Reminder sent (oldest: $($oldest.Name) at $oldestAge days)."
  exit 0
} else {
  Write-Warning 'Reminder NOT sent -- no channel succeeded.'
  exit 1
}
