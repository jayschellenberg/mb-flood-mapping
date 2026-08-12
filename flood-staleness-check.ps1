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
# refresh leaves behind (the refreshed_iso stamps in data/layers.yml, plus the
# copy of them that the web build mirrors into web/data/layers.json), so it
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
# 2026-08-12 -- NOW ALSO CHECKS THE DEPLOYED WEB PAYLOAD FOR DRIFT.
# Until this date the script read data\layers.yml and nothing else, so it was
# blind to the likeliest partial-refresh failure: somebody runs
# refresh_flood_data.R (which restamps layers.yml) and forgets
# R\simplify_for_web.R (which builds web\data\, the payload Vercel actually
# serves). data\ then moves forward, this watchdog stays green, and the live
# app keeps serving the OLD geometry -- while also printing the OLD
# "as of <date>" into the client-facing caveat that web\app.js composes from
# web\data\layers.json. That is the same appraisal-defensibility problem the
# 365-day rule exists to prevent, only quieter, so it gets its OWN alert with
# its OWN monthly dedupe stamp rather than being folded into the age alert.
#
# WHAT IS COMPARED, AND WHY THAT AND NOT SOMETHING ELSE:
#   * Compared: each layer's `refreshed` date in web\data\layers.json against
#     the first 10 characters of the matching `refreshed_iso` in
#     data\layers.yml. simplify_for_web.R writes that field as
#     substr(refreshed_iso, 1, 10) copied straight out of layers.yml at build
#     time, so the two agree if and only if the web payload was rebuilt after
#     the last data refresh. It is also the exact value web\app.js publishes to
#     the reader, so checking it checks what the app actually claims.
#   * NOT sha256. layers.yml stores the hash of the FULL-resolution
#     data\*.geojson; web\data\*.geojson are rmapshaper-simplified derivatives
#     (3-30 percent vertex retention), so those hashes can never match by
#     design, and layers.json carries no hash of the web payload at all.
#   * NOT file mtimes. This is a git working tree on a Dropbox path; a clone or
#     a resync rewrites mtimes wholesale, so mtime ordering would produce
#     confident nonsense.
#   * Also flagged: an overlay whose .geojson is missing or zero-length in
#     web\data, a layer served by the web app that layers.yml no longer knows
#     about, and a layer added to layers.yml that was never wired into the web
#     build (see $WebExcludedLayers for the one deliberate omission -- whose
#     .geojson is still checked for presence and non-zero size, because the app
#     fetches that file directly even though layers.json never lists it).
#
# KNOWN LIMIT: the date comparison has one-day resolution, so refreshing data\
# twice in one day with a simplify_for_web.R run in between would read as
# in-sync. Closing that would mean adding a source_sha256 field to layers.json
# in simplify_for_web.R -- not done here, because it changes the published web
# schema and would leave this check blind until the next web build.
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
$root           = Split-Path -Parent $MyInvocation.MyCommand.Path
$LayersYml      = Join-Path $root 'data\layers.yml'
$WebLayersJson  = Join-Path $root 'web\data\layers.json'
$WebDataDir     = Join-Path $root 'web\data'
$StampFile      = Join-Path $root 'logs\flood-alert-stamp.txt'
$DriftStampFile = Join-Path $root 'logs\flood-drift-stamp.txt'
$NtfyTopic      = 'mbps-flood-refresh-jks'

# Layers that live in data\layers.yml but are deliberately NOT registered as
# overlays in web\data\layers.json. This must mirror the COMPLEMENT of the
# `overlay_layers` vector in R\simplify_for_web.R -- that is, the names in that
# script's `plan` list (11 today) that `overlay_layers` (10 today) leaves out.
# The difference is winnipeg_boundary alone: simplify_for_web.R still simplifies
# it into web\data, and web\app.js fetches web\data\winnipeg_boundary.geojson
# directly to fire the DFFA footnote, but it is never drawn as a toggleable
# overlay, so layers.json omits it. Do NOT copy overlay_layers here: that is the
# inverse set and would exempt every real overlay from the drift check.
# Anything in layers.yml that is neither an overlay nor listed here is treated
# as a layer somebody forgot to wire into the web build. Names listed here are
# exempt only from the layers.json REGISTRATION check -- their web\data
# .geojson is still checked for presence and non-zero size further down.
$WebExcludedLayers = @('winnipeg_boundary')

# The alert stack lives in the parcel-search repo; this project has no copy of
# its own on purpose (one email config, one place to rotate an app password).
$AlertLib = Join-Path $ParcelSearchRoot 'alert-lib.ps1'
if (-not (Test-Path $AlertLib)) {
  Write-Error "alert-lib.ps1 not found at $AlertLib -- pass -ParcelSearchRoot or set MB_PARCELSEARCH_ROOT."
  exit 1
}
. $AlertLib

# One reminder per calendar month PER KIND of alert. Each kind owns its own
# stamp file so an age reminder never suppresses a drift reminder (they have
# different causes and different fixes). Returns $true when the alert either
# went out or was legitimately deduped, $false only when no channel worked.
function Send-MonthlyAlert([string]$stampPath, [string]$title, [string]$body) {
  $stampVal = (Get-Date).ToString('yyyy-MM')
  if ((Test-Path $stampPath) -and ((Get-Content $stampPath -Raw).Trim() -eq $stampVal)) {
    Write-Host "Already reminded this month ($stampVal): $title -- skipping."
    return $true
  }
  if (Send-FailureAlert $ParcelSearchRoot $NtfyTopic $title $body) {
    New-Item -ItemType Directory -Force -Path (Split-Path $stampPath) | Out-Null
    Set-Content -Path $stampPath -Value $stampVal
    Write-Host "Alert sent: $title"
    return $true
  }
  Write-Warning "Alert NOT sent ($title) -- no channel succeeded."
  return $false
}

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

# Each name is paired with the refreshed_iso from ITS OWN block, by carrying the
# current block's name forward, rather than positionally by $names[$stamps.Count]
# as this loop originally did. The positional form was correct only while every
# single name: line was followed by a parsable refreshed_iso: -- which today's
# refresh_flood_data.R generator does guarantee, so this was never reachable in
# practice. But one block with a missing or unparsable stamp (a truncated write,
# a hand-edit, a future generator that adds a layer before it is first fetched)
# shifted EVERY later pairing by one, and each mis-paired name then reads as both
# "served by the web app but ABSENT from data\layers.yml" and "in data\layers.yml
# but never registered in the web build" -- a cascade of confident nonsense in the
# alert email. Carrying the name makes a malformed block cost exactly one finding.
# $unstamped collects the names that reached the end of their block with no
# parsable stamp, so the condition is reported plainly instead of inferred.
$stamps    = @()
$unstamped = @()
$curName   = $null
foreach ($line in Get-Content $LayersYml) {
  $n = [regex]::Match($line, '^\s*-?\s*name:\s*(\S+)\s*$')
  if ($n.Success) {
    # A new name: line before the previous block produced a stamp means the
    # previous block had none. (Also catches a duplicate name: within a block.)
    if ($null -ne $curName) { $unstamped += $curName }
    $curName = $n.Groups[1].Value
    continue
  }
  $r = [regex]::Match($line, '^\s*refreshed_iso:\s*(\S+)\s*$')
  if ($r.Success) {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($r.Groups[1].Value, [ref]$parsed)) {
      $raw10 = $r.Groups[1].Value
      $stamps += [pscustomobject]@{
        Name = if ($null -ne $curName) { $curName } else { '(unnamed)' }
        When = $parsed
        # The literal first 10 chars, NOT a reformatted date: this is compared
        # against layers.json, which holds substr(refreshed_iso, 1, 10) verbatim.
        Iso10 = $raw10.Substring(0, [Math]::Min(10, $raw10.Length))
      }
      # Consumed: a second refreshed_iso: in the same block would otherwise
      # claim the same name twice.
      $curName = $null
    }
  }
}
# The final block never sees a following name: line to close it.
if ($null -ne $curName) { $unstamped += $curName }

if ($stamps.Count -eq 0) {
  Write-Error "No parsable refreshed_iso stamps in $LayersYml -- cannot judge staleness."
  exit 1
}

$oldest    = $stamps | Sort-Object When | Select-Object -First 1
$newest    = $stamps | Sort-Object When -Descending | Select-Object -First 1
$oldestAge = [int]($now.Date - $oldest.When.Date).TotalDays
$newestAge = [int]($now.Date - $newest.When.Date).TotalDays

# --- compare the DEPLOYED web payload against data\ --------------------------
# See the header for why the refreshed date is the comparison and sha256 is not.
$driftNotes = @()
$ymlByName  = @{}
foreach ($s in $stamps) { if ($s.Name -ne '(unnamed)') { $ymlByName[$s.Name] = $s } }

# A named layer with no parsable refreshed_iso: cannot be aged and cannot be
# compared against the web copy. layers.yml is generated, so this means the file
# or the generator is damaged -- say that outright rather than let it surface as
# a misleading "ABSENT from data\layers.yml" line below.
foreach ($u in $unstamped) {
  $driftNotes += "$($u): named in data\layers.yml with no parsable refreshed_iso: -- its freshness cannot be judged (layers.yml is generated; suspect a truncated write or a hand-edit)."
}

if (-not (Test-Path $WebLayersJson)) {
  $driftNotes += 'web\data\layers.json is MISSING -- the deployed app has no layer manifest to load.'
} else {
  $webLayers = @()
  $webOk     = $false
  try {
    # Read as UTF-8 explicitly. layers.json carries em dashes in two labels, and
    # Get-Content's encoding guess under Windows PowerShell 5.1 mangles them.
    $webRaw    = [System.IO.File]::ReadAllText($WebLayersJson, [System.Text.Encoding]::UTF8)
    $webParsed = $webRaw | ConvertFrom-Json
    # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE
    # Object[], so @( ) around it yields a single-element array holding the
    # array instead of unrolling it -- and then $w.name silently member-enumerates
    # into every name at once. Normalize explicitly. (Caught 2026-08-12 when the
    # first dry run reported all ten layers as one bogus finding.)
    if ($null -eq $webParsed)              { $webLayers = @() }
    elseif ($webParsed -is [System.Array]) { $webLayers = $webParsed }
    else                                   { $webLayers = @($webParsed) }
    $webOk = $true
  } catch {
    $driftNotes += "web\data\layers.json is UNPARSABLE ($($_.Exception.Message)) -- the deployed app cannot load it."
  }

  if ($webOk) {
    if ($webLayers.Count -eq 0) {
      $driftNotes += 'web\data\layers.json lists ZERO layers -- the deployed app would draw no overlays.'
    }
    $webNames = @()
    foreach ($w in $webLayers) {
      $webNames += $w.name
      if (-not $ymlByName.ContainsKey($w.name)) {
        # An unstamped name IS in layers.yml, just unreadable; it already has its
        # own finding above, and calling it ABSENT here would be a second, wronger
        # line about the same damage.
        if ($unstamped -notcontains $w.name) {
          $driftNotes += "$($w.name): served by the web app but ABSENT from data\layers.yml."
        }
        continue
      }
      $ymlDate = $ymlByName[$w.name].Iso10
      if ($w.refreshed -ne $ymlDate) {
        $driftNotes += "$($w.name): web says $($w.refreshed), data\layers.yml says $ymlDate."
      }
      $geo = Join-Path $WebDataDir $w.file
      if (-not (Test-Path $geo)) {
        $driftNotes += "$($w.name): web\data\$($w.file) is MISSING."
      } elseif ((Get-Item $geo).Length -eq 0) {
        $driftNotes += "$($w.name): web\data\$($w.file) is ZERO BYTES."
      }
    }
    # Only meaningful when the manifest actually listed something. An empty or
    # truncated layers.json makes EVERY layer look forgotten, so the correct
    # "lists ZERO layers" finding above used to arrive with ten bogus "never
    # registered in the web build" lines behind it -- which land verbatim in the
    # alert email and mis-diagnose one damaged file as ten unrelated mistakes.
    if ($webLayers.Count -gt 0) {
      foreach ($s in $stamps) {
        if ($s.Name -eq '(unnamed)') { continue }
        if (($webNames -notcontains $s.Name) -and ($WebExcludedLayers -notcontains $s.Name)) {
          $driftNotes += "$($s.Name): in data\layers.yml but never registered in the web build."
        }
      }
    }
  }
}

# --- files of the deliberately-unregistered layers ---------------------------
# $WebExcludedLayers is exempt from the REGISTRATION check only. The loop above
# walks the entries of layers.json, and these layers are absent from layers.json
# by design, so their .geojson would otherwise never be looked at by anything --
# yet web\app.js fetches web\data\winnipeg_boundary.geojson directly, and a
# missing or empty file there silently kills the DFFA footnote. Checked out here
# rather than inside the else-branch so it still runs when layers.json is itself
# missing or unparsable. The filename is <name>.geojson because that is what
# simplify_for_web.R writes (dst = file.path("web/data", paste0(nm, ".geojson"))).
foreach ($x in $WebExcludedLayers) {
  $xFile = "$x.geojson"
  $xPath = Join-Path $WebDataDir $xFile
  if (-not (Test-Path $xPath)) {
    $driftNotes += "$($x): web\data\$xFile is MISSING (not listed in layers.json by design, but web\app.js fetches it directly)."
  } elseif ((Get-Item $xPath).Length -eq 0) {
    $driftNotes += "$($x): web\data\$xFile is ZERO BYTES (not listed in layers.json by design, but web\app.js fetches it directly)."
  }
}

# --- decide ------------------------------------------------------------------
# The two conditions are independent and can both fire in one run: data\ can be
# a year stale AND the web copy can be out of sync with it at the same time.
$isStale = ($oldestAge -gt $MaxAgeDays)
$isDrift = ($driftNotes.Count -gt 0)

if ($isStale) {
  Write-Host "STALE: oldest $($oldest.Name) at $oldestAge days exceeds the $MaxAgeDays-day threshold ($($stamps.Count) layers checked)."
} else {
  Write-Host "Flood layers current: oldest $($oldest.Name) $oldestAge days, newest $newestAge days; threshold $MaxAgeDays."
}
if ($isDrift) {
  Write-Host "DRIFT: web\data is out of sync with data\ -- $($driftNotes.Count) finding(s):"
  foreach ($d in $driftNotes) { Write-Host "  - $d" }
} else {
  Write-Host "Web payload in sync with data\layers.yml."
}

if (-not $isStale -and -not $isDrift) { exit 0 }

if ($DryRun) {
  Write-Host 'DRYRUN - no alert sent.'
  exit 0
}

$failed = $false

if ($isStale) {
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

Step 3 is not optional: skipping it leaves the deployed app on the old geometry
and triggers this script's separate DRIFT alert.

Then review the layers.yml sha256 diffs to see which sources actually changed,
and redeploy the web app if data\ or web\data\ moved.

Checked $($now.ToString('s')) on $env:COMPUTERNAME by flood-staleness-check.ps1.
Stop these reminders:  Unregister-ScheduledTask -TaskName mbfloodmapping-staleness -Confirm:`$false
"@
  if (-not (Send-MonthlyAlert $StampFile $title $body)) { $failed = $true }
}

if ($isDrift) {
$driftList = ($driftNotes | ForEach-Object { "  * $_" }) -join "`n"
# Assignments deliberately unindented: a here-string terminator must sit at
# column 0, so indenting the block would be a parse error.
$title = 'DRIFT - MB flood web payload out of sync with data'
$body  = @"
The Vercel-deployed flood app (web\data\) does not match the authoritative
layers in data\. The usual cause is a PARTIAL refresh: refresh_flood_data.R or
fetch_winnipeg_waterway_corridors.R was run and R\simplify_for_web.R was not,
so data\layers.yml moved forward while the live site kept serving the older
simplified geometry -- and kept printing the older "as of <date>" line into the
client-facing caveat web\app.js builds from web\data\layers.json.

Findings ($($driftNotes.Count)):
$driftList

  Manifest : $LayersYml
  Web copy : $WebLayersJson

To resolve:

  1. Rscript "$root\R\simplify_for_web.R"
  2. cd "$root\web"  then  vercel --prod

If the WEB copy is instead the correct one, re-run the data refresh. Do not
hand-edit either manifest -- both are generated files.

Checked $($now.ToString('s')) on $env:COMPUTERNAME by flood-staleness-check.ps1.
Stop these reminders:  Unregister-ScheduledTask -TaskName mbfloodmapping-staleness -Confirm:`$false
"@
  if (-not (Send-MonthlyAlert $DriftStampFile $title $body)) { $failed = $true }
}

if ($failed) { exit 1 }
exit 0
