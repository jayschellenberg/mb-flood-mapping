# Manitoba Flood-Screening Exhibit — Reusable Appraisal Tool

## Context

Reframed per Jason's direction: this is **not** just an interactive map, it's a **reusable appraisal flood-screening exhibit** that produces both (a) an interactive Leaflet map and (b) a defensible, source-backed written summary suitable for dropping into a commercial appraisal report.

The subject property is set via QMD YAML (lat/lon + address). On render, the tool performs spatial analysis against cached Manitoba flood layers, produces a conclusion table and a copy-ready paragraph, renders an interactive map, and exports a static PNG exhibit.

The `MBFloodMapping` project folder is empty — greenfield scaffold.

## Data sources (confirmed public, Manitoba)

| Layer | Type | Endpoint | Format | Status |
|---|---|---|---|---|
| Red River Flood 1997 | Historical extent | Data MB dataset `manitoba::red-river-flood-1997` | GeoJSON (Hub) | Confirmed |
| Red River Flood 2009 | Historical extent | Data MB dataset `red-river-flood-2009` | GeoJSON (Hub) | Confirmed |
| Red River Flood 2011 | Historical extent | Data MB dataset `red-river-flood-2011` | GeoJSON (Hub) | Confirmed |
| **Manitoba 1-in-200 Flood Extent** | Statistical (0.5% AEP) | `services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Manitoba_1_in_200_Flood_Layer_v2/FeatureServer/0` | ArcGIS REST → GeoJSON | **Confirmed public (Query capability), Manitoba.gov copyright** |
| Designated Flood Area (Red River Valley DFA) | Statutory (WRA Act s.17) | `mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_des_flood_area_py_shp.zip` | Shapefile ZIP | Confirmed |
| Lower Red River DFA | Statutory (WRA Act s.17) | `mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_lower_red_river_dfa_py_shp.zip` | Shapefile ZIP | Confirmed |

**Not on Manitoba open data:** 1950 Red River Flood polygon — out of scope (only narrative/PDF references exist).

## Deliverables

```
MBFloodMapping/
├── MBFloodMapping.Rproj
├── README.md
├── .gitignore
├── R/
│   ├── fetch_arcgis_layer.R        # defensive ArcGIS REST helper (pagination, geometry validation, CRS)
│   ├── refresh_flood_data.R        # orchestrator — pulls every layer, writes metadata sidecar
│   ├── analyze_subject.R           # st_contains / st_intersects / st_distance; returns tidy result df
│   └── render_report.R             # CLI wrapper: Rscript R/render_report.R --lat --lon --address --out
├── data/
│   ├── layers.yml                  # canonical source-of-truth: name, url, type, item_id, crs, refreshed, feature_count, sha256
│   ├── red_river_flood_1997.geojson
│   ├── red_river_flood_2009.geojson
│   ├── red_river_flood_2011.geojson
│   ├── mb_1in200_flood_extent.geojson
│   ├── dfa_red_river_valley.geojson
│   └── dfa_lower_red_river.geojson
├── subjects/
│   └── example_subjects.csv        # sample subjects for testing (lat,lon,address,expected)
├── outputs/                        # .gitignore'd — generated HTML/PNG/PDF per job
└── property_flood_report.qmd       # the template Jason edits per job
```

## The QMD template — design

### YAML header

```yaml
---
title: "Flood-Screening Exhibit — `r params$address`"
format:
  html:
    embed-resources: true
params:
  lat: 49.8951
  lon: -97.1384
  address: "123 Example Ave, Winnipeg, MB"
  job_id: "2026-0420-Example"
  zoom: 13
  nearest_distance_threshold_m: 500   # if nearest extent is within this, flag in conclusion
execute:
  echo: false
  warning: false
---
```

### Rendered sections (top-to-bottom)

1. **Header** — job id, address, subject coordinates, date rendered.

2. **Conclusion table** (produced by `analyze_subject()` — one row per layer):

   | Layer | Subject inside? | Nearest extent (m) | Source | Refreshed | Note |
   |---|---|---|---|---|---|
   | 1997 Red River Flood | No | 1,240 m | Data MB | 2026-04-20 | Historical extent |
   | 2009 Red River Flood | No | 1,180 m | Data MB | 2026-04-20 | Historical extent |
   | 2011 Red River/Assiniboine | No | — | Data MB | 2026-04-20 | Not applicable to area |
   | 1-in-200 Flood Extent | **Yes** | 0 | Manitoba (Infrastructure) | 2026-04-20 | Statistical 0.5% AEP |
   | Red River Valley DFA | **Yes** | 0 | MLI / WRA Act s.17 | 2026-04-20 | DFA permit likely required |
   | Lower Red River DFA | No | 18,400 m | MLI / WRA Act s.17 | 2026-04-20 | Outside this DFA |

3. **Copy-ready appraisal paragraph** — rendered inside a bordered `<div>` with a "copy" visual cue. Three conditional templates in `analyze_subject.R`, picked by result:

   - **Inside any mapped extent:**
     > "The subject property at `{address}` (lat `{lat}`, lon `{lon}`) is located within one or more mapped flood-risk layers reviewed for this appraisal, specifically: `{layers_inside}`. `{if in DFA: A Designated Flood Area permit may be required for new permanent structures under Section 17 of The Water Resources Administration Act.}` The 1-in-200 year flood extent is a statistical (0.5% annual exceedance probability) layer prepared by the Province of Manitoba for planning purposes. Historical flood extents (1997/2009/2011) reflect the observed overland flooding boundaries of those events. This exhibit is based on publicly available provincial mapping as of `{refreshed_date}` and is intended for appraisal context only; it is not a legal survey, engineering flood study, insurance determination, or site-specific flood protection level assessment. Current river conditions and forecasts are available from Manitoba's Hydrologic Forecast Centre at manitoba.ca/floodinfo."

   - **Outside all mapped extents (clean):**
     > "The subject property at `{address}` (lat `{lat}`, lon `{lon}`) is not located within the mapped flood extents reviewed for this appraisal (1997, 2009, and 2011 Red River overland flood extents; Manitoba 1-in-200 year flood extent; Red River Valley and Lower Red River Designated Flood Areas). The nearest mapped flood extent is approximately `{nearest_m}` metres from the subject coordinates (`{nearest_layer}`). This exhibit is based on publicly available provincial mapping as of `{refreshed_date}` and is intended for appraisal context only; it is not a legal survey, engineering flood study, insurance determination, or site-specific flood protection level assessment."

   - **Outside but within proximity threshold** (e.g. nearest extent < 500 m): same as "outside" with an added sentence flagging proximity.

   - **Data unavailable / layer not loaded:** a neutral sentence naming which layer is unavailable and directing the reader to the source portal; no claim either way for that layer.

4. **Interactive Leaflet map** (same basic design as original plan) — six overlay groups (1997, 2009, 2011, 1-in-200, RR Valley DFA, Lower Red DFA), each independently toggleable; `Esri.WorldImagery` + `CartoDB.Positron` base groups; subject pin with address popup; `setView()` to subject with zoom from YAML; `addLayersControl()` expanded; `addLegend()` color-keyed; `addScaleBar()`.

5. **Static PNG exhibit** — a second deliverable generated with `mapview::mapshot()` (or `webshot2`) saving to `outputs/{job_id}/flood_exhibit.png` at a report-friendly aspect ratio, with:
   - north arrow + scale bar (via ggspatial-equivalent for mapview, or a pre-composed ggplot2+sf static alternative rendered alongside)
   - subject marker
   - legend
   - source/date caption baked in
   - (decision at build time: if `mapview` static export is awkward, fall back to `ggplot2 + geom_sf + ggspatial::annotation_scale + annotation_north_arrow` — produces a clean PNG suitable for dropping directly into a Word report)

6. **Sources & methodology footer** — each layer's source URL, refresh date, CRS, feature count, SHA-256 (pulled from `data/layers.yml`).

## Helper modules

### `R/fetch_arcgis_layer.R`

Exports `fetch_arcgis_featureserver_layer(url, out_path)` — handles the realities of ArcGIS REST:

- Queries `/0?f=json` first to read `maxRecordCount`, `supportsPagination`, `objectIdField`, and source CRS.
- Pulls objectIDs via `/0/query?where=1=1&returnIdsOnly=true&f=json`, chunks into pages, and issues `/0/query?objectIds=...&outFields=*&outSR=4326&f=geojson` per page.
- `rbind`s pages via `sf::rbind.sf` and writes a single GeoJSON.
- Validates geometries (`sf::st_is_valid` → `sf::st_make_valid` where needed).
- Transforms to EPSG:4326 explicitly (the 1-in-200 layer is Web Mercator natively).
- Returns a one-row tibble with feature_count, crs, sha256, refreshed timestamp.

### `R/refresh_flood_data.R`

Orchestrator. Reads a declarative list:

```r
layers <- tribble(
  ~name,                     ~kind,      ~url,                                                                                                         ~optional,
  "red_river_flood_1997",   "hub",      "https://opendata.arcgis.com/api/v3/datasets/<item_id>/downloads/data?format=geojson&spatialRefId=4326",       FALSE,
  "red_river_flood_2009",   "hub",      "<...>",                                                                                                       FALSE,
  "red_river_flood_2011",   "hub",      "<...>",                                                                                                       FALSE,
  "mb_1in200_flood_extent", "arcgis",   "https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Manitoba_1_in_200_Flood_Layer_v2/FeatureServer/0",  FALSE,
  "dfa_red_river_valley",   "mli_shp",  "https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_des_flood_area_py_shp.zip",                                  FALSE,
  "dfa_lower_red_river",    "mli_shp",  "https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_lower_red_river_dfa_py_shp.zip",                             FALSE,
)
```

Dispatches to handler by `kind`:
- `hub` → direct `download.file` of GeoJSON (Data MB Hub endpoints return a complete file).
- `arcgis` → `fetch_arcgis_featureserver_layer()`.
- `mli_shp` → download ZIP → `unzip()` to a temp dir → `sf::st_read()` → `sf::st_transform(4326)` → write GeoJSON.

Each successful layer appends a row to `data/layers.yml` with: `name, url, kind, item_id, native_crs, refreshed_iso, feature_count, sha256`. Runs are idempotent and `--force` re-downloads.

### `R/analyze_subject.R`

Exports `analyze_subject(lat, lon, data_dir = "data")`:

- Returns a tibble: `layer`, `inside` (logical), `nearest_m` (numeric, NA if inside), `source`, `refreshed`, `note`.
- Uses `sf::st_within()` for inside test, `sf::st_distance()` for nearest (projected to EPSG:3347 Statistics Canada Lambert so distances are metric and accurate across Manitoba).
- Reads `data/layers.yml` for source/refreshed metadata — single source of truth.
- Returns a second element: a list with `any_inside` (logical), `layers_inside` (chr), `nearest_overall` (list), plus the three paragraph variants pre-rendered as strings.

### `R/render_report.R`

CLI wrapper so appraisal jobs can be rendered without opening RStudio:

```
Rscript R/render_report.R --lat 49.8951 --lon -97.1384 \
  --address "123 Example Ave, Winnipeg" \
  --job-id 2026-0420-Example \
  --out outputs/2026-0420-Example/
```

Uses `optparse` or `argparser`; shells `quarto::quarto_render()` with `execute_params = list(...)`. Also copies the exported PNG out of the render directory into `--out`.

## Verification (golden path + edge cases)

1. **Refresh script round-trip:** `Rscript R/refresh_flood_data.R` pulls all six layers; each appears in `data/` with non-zero size; `data/layers.yml` has six rows with non-NA `feature_count` and `sha256`. Re-run is idempotent (hashes stable).

2. **Inside-the-1997-extent subject:** a Ste. Agathe or Morris address in `subjects/example_subjects.csv`. Render: table shows `inside = Yes` for 1997 and (likely) 1-in-200 and Red River Valley DFA; paragraph is the "inside" variant; map pin sits visibly inside the red polygon; PNG exports with all elements.

3. **Clean rural subject:** a Brandon CBD address. Render: all rows `inside = No`; nearest distances populated; paragraph is the "outside" variant.

4. **Proximity edge case:** subject within 500 m of 1997 extent. Paragraph adds the proximity flag sentence.

5. **Missing layer resilience:** rename `data/mb_1in200_flood_extent.geojson` to simulate outage. Render: that row says "data unavailable"; paragraph uses the unavailable variant for that layer only; no failure.

6. **CRS sanity:** programmatic check — subject lat/lon treated as EPSG:4326 throughout, distance calculations done in EPSG:3347, no silent degree-distance bugs.

7. **CLI render:** `Rscript R/render_report.R --lat ... --out outputs/test/` produces HTML + PNG in `outputs/test/`.

8. **Caveat language present:** grep the rendered HTML for "not a legal survey, engineering flood study, insurance determination" — must be present in every paragraph variant.

## Open items for implementation time

- Resolve the exact item IDs / download URLs for the three Data MB Red River Flood Hub datasets. The Hub URL pattern is known; item IDs need inspection of each dataset page (network tab grabs the JSON config with the item ID).
- Confirm the MLI shapefile inside the `bdy_des_flood_area_py_shp.zip` contains the Red River Valley DFA polygon distinctly from any other designated flood areas (the MLI catalog lists "Designated Flood Area" — likely province-wide and may already include Lower Red River). If the DFA ZIP already contains both, collapse to a single layer with an attribute filter instead of fetching two URLs.
- Decide static-export path: `mapview::mapshot()` (keeps the Leaflet styling but flaky with `webshot2`) vs. a parallel `ggplot2 + geom_sf + ggspatial` static exhibit (more predictable, better for Word/PDF inclusion). Recommendation: build the `ggplot2` static exhibit — it's what appraisers actually paste into reports.
- Final color palette for six overlays — suggest: 1997 = `#d62728` (red), 2009 = `#ff7f0e` (orange), 2011 = `#1f77b4` (blue), 1-in-200 = `#9467bd` (purple, hatched), RRV DFA = `#2ca02c` dashed outline, Lower Red DFA = `#17becf` dashed outline. Jason to tweak.

## Critical files to create

- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\property_flood_report.qmd`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\R\fetch_arcgis_layer.R`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\R\refresh_flood_data.R`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\R\analyze_subject.R`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\R\render_report.R`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\data\layers.yml`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\subjects\example_subjects.csv`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\README.md`
- `D:\Dropbox\ClaudeCode\$Projects in Progress\MBFloodMapping\.gitignore` (ignores `outputs/`, `_files/`, `.Rproj.user/`)
