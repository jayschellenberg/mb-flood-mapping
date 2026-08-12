# Should the statutory flood layers be repointed from MLI to DataMB?

**Date:** 2026-08-12 · **Status:** decision pending on RRVSMA; DFA cleared to repoint

`R/refresh_flood_data.R` pulls three statutory boundaries from `mli.gov.mb.ca`.
The Manitoba Land Initiative has stated since **2022-02-09** that its datasets
"will no longer be updated", redirecting to DataMB (`geoportal.gov.mb.ca`). So
the annual re-pull re-downloads 2022-vintage data forever. This is the geometry
comparison that question deserved before anything was repointed — these
boundaries are cited in client-facing appraisal text.

**Method.** Compared the full local cache (`data/*.geojson`, fetched 2026-04-21
from MLI) against the live DataMB services. All area and distance in
**EPSG:26914** (UTM 14N, metres), `s2` off. Feature completeness confirmed
against `returnCountOnly` and `returnIdsOnly` before comparing. Every number
below was measured twice by independent scripts; the second measurement was
written without reading the first.

---

## Designated Flood Areas — same polygons, but repoint anyway

`DFA_final/FeatureServer/0` · WRA Act s.17 · 2 features

| | Red River Valley | Lower Red River | Total |
|---|---|---|---|
| Local (MLI) | 2,103.842141 km² | 326.329317 km² | 243,017.15 ha |
| Remote (DataMB) | 2,103.842627 km² | 326.329390 km² | 243,017.20 ha |
| Symmetric difference | 0.2636 km² (0.0125% of union) | 0.1774 km² (0.0544%) | 0.4411 km² |
| Max displacement | 1.158 m | 1.164 m | — |
| Vertices | 2479 / **2479** | 1490 / **1490** | — |

**These are the same polygons.** Vertex counts match exactly — a
re-delineation essentially never reproduces that. The difference is a rigid
translation of ~1.16 m on bearing ~321° (NW): every vertex moves the same
distance and direction (dx sd 1.2 mm, dy sd 1.9 mm), and after subtracting that
single vector the geometries coincide to **millimetres** (median residual
1.5 mm). The difference ribbons tile 100% of the perimeter — summed ribbon
length 324,290.8 m against a perimeter of 324,291 m — with no localised
concentration anywhere. Total designated area agrees to **0.056 ha out of
243,017 ha**.

Practically: no parcel-level in/out call changes unless a parcel boundary sits
within ~1.2 m of the line, which is ambiguous against either dataset and below
the positional accuracy of the underlying statutory mapping.

**Recommendation: repoint — not for today's geometry, but for tomorrow's.**
`DFA_final` is actively maintained: item created 2024-08-13, `dataLastEditDate`
2025-04-02, item modified 2026-03-05 — all *after* the MLI freeze. Any future
s.17 amendment appears there and never on MLI. DataMB also carries a
`Designated_Flood_Area_Zone` name field; the local files are distinguishable
only by filename. Zero present-day cost, real prospective gain.

**Caveat before switching:** repointing introduces that 1.16 m shift relative
to whatever the DFA is currently overlaid on. Which copy registers better
against Manitoba's NAD83 parcel fabric is **undetermined** — PROJ applies a
null NAD83↔WGS84 transform at this location, so the tempting "it's just a datum
difference" explanation is plausible but unproven. Immaterial at appraisal
scale; worth knowing before anyone reads significance into a 1 m shift.

---

## RRV Special Management Area — real disagreement, no currency gain

`Red_River_Valley_Special_Management_Area/FeatureServer/0` · Planning Act · 1 feature

| | Local (MLI) | Remote (DataMB) |
|---|---|---|
| Area | 11,573.70 km² (1,157,370.08 ha) | 11,578.62 km² (1,157,862.35 ha) |
| Vertices | 427 | 3,826 |
| `dataLastEditDate` | (MLI, frozen 2022-02-09) | 2022-01-31 |

Symmetric difference **20.642 km² = 0.178% of union** · IoU 0.9982 ·
only-in-local 7.860 km² / only-in-remote 12.782 km² (218 pieces each).

**Two findings, and the non-geometric one decides it.**

**1. There is nothing newer to get.** The remote `dataLastEditDate` is
**2022-01-31 — nine days *before* the MLI freeze.** It is exactly as old as the
copy already shipped, and it is the only such service in the org. Repointing
this layer buys currency it does not have.

**2. The northern terminus is a genuine disagreement, not noise.** Over ~97% of
the perimeter the two lines never diverge by more than 60 m (93% within 25 m) —
ordinary re-encoding. But above 50.30°N, at the **Netley–Libau marsh** where the
Red River enters Lake Winnipeg, sits **14.86 km² — 72% of all difference** — in
four *compact* lobes 207–659 m wide (Polsby-Popper compactness 0.14–0.28, versus
~0.003 for the sliver population elsewhere).

Resolution does not explain it. Simplifying the remote polygon down to the
local's vertex budget **does not reduce the symmetric difference at all**
(99–100% of baseline). The two files genuinely disagree about where the
boundary runs across that marsh.

Exposure, stated in the direction that matters: a parcel sitting on the
**shipped** boundary is at most **~750 m** from the live boundary (median 10.7 m).
The 3.06 km Hausdorff figure is the opposite direction and overstates the risk.

**Recommendation: do not repoint blind.** Point-in-polygon over ~14.9 km² of the
Netley/Libau delta returns different answers from the two files, and nothing in
either dataset says which line the Planning Act designation actually follows.
That needs the regulation text, not a geometry comparison. Since there is no
freshness gain either way, the safe default is to keep the current source and
resolve the authority question only if a subject property ever falls in that
window — which the report should flag rather than silently answer.

---

## What changed as a result

Nothing was repointed. `R/refresh_flood_data.R` carries the MLI-freeze warning
so the next annual refresh cannot miss the question; this file is the evidence
behind it.

Reproduce with the scripts under
`scratchpad/floodgeo/` (comparison + independent cross-check), or re-derive from
the sources above — everything here is measured, not asserted.
