# MBFloodMapping — Manitoba Flood-Screening Tool

Reusable appraisal tool that screens a subject property against published Manitoba flood, regulatory, and waterway-corridor layers and produces (a) a copy-ready written paragraph for the appraisal narrative, (b) a screening table, and (c) an interactive Leaflet map.

Two front ends share the same authoritative data cache:

1. **R / Quarto report** (`property_flood_report.qmd`) — renders a self-contained HTML exhibit per job.
2. **Static web app** (`web/`) — Leaflet + Turf.js client-side tool deployed to Vercel ([mb-flood-mapping](https://vercel.com/) project). Address geocoding via Mapbox with Nominatim fallback.

## Deep-linking from another app

The web app accepts URL parameters so a sister tool (e.g. [manitoba-opendata-parcelsearch](https://github.com/jayschellenberg/manitoba-opendata-parcelsearch)) can hand a parcel off and have the screening run automatically.

| Param | Effect |
|---|---|
| `lat` + `lon` | Both required together. Sets the location and runs the screening at those coordinates. |
| `address` | Sets the location to a civic address and triggers geocoding. |
| `q` | Alias for `address`. |
| `label` | Sets the marker tooltip. Optional. |

Precedence: `lat`+`lon` > `address` > `q`. With no params, the app falls back to its default Winnipeg view.

**Example URLs:**

```
https://mb-flood-mapping.vercel.app/?lat=49.5602&lon=-97.1780&label=123%20Main%20St
https://mb-flood-mapping.vercel.app/?address=200%20Main%20St,%20Winnipeg,%20MB
```

**Snippet to drop into parcelsearch** (or any caller):

```js
// On parcel click — open flood screening in a new tab
const url = new URL("https://mb-flood-mapping.vercel.app/");
url.searchParams.set("lat", parcel.lat);
url.searchParams.set("lon", parcel.lon);
url.searchParams.set("label", parcel.address); // optional
window.open(url.toString(), "_blank", "noopener");
```

If you only have a civic address, swap the `lat`/`lon` calls for `url.searchParams.set("address", parcel.address)` — the app will geocode it via Mapbox (Nominatim fallback).

## What it screens against

| # | Layer | Source | Type |
|---|---|---|---|
| 1 | 1997 Red River Flood (historical extent) | Data MB (ArcGIS FeatureServer) | Observed |
| 2 | 2009 Red River Flood (historical extent) | Data MB | Observed |
| 3 | 2011 Red River / Assiniboine Flood | Data MB | Observed |
| 4 | Manitoba 1-in-200 Year Flood Extent (0.5% AEP) | Manitoba Infrastructure | Statistical |
| 5 | Designated Flood Area — Red River Valley DFA (`dfa_all`) | Manitoba Land Initiative — WRA Act s.17 | Statutory |
| 6 | Lower Red River Designated Flood Area | Manitoba Land Initiative — WRA Act s.17 | Statutory |
| 7 | Red River Valley Special Management Area | Manitoba Land Initiative — Planning Act | Planning overlay |
| 8 | NRCan Canada Flood Map Inventory (Manitoba) | Natural Resources Canada | Study-coverage index (info-only) |
| 9 | Winnipeg Waterway Corridor — Rivers (107 m) | Derived from OSM, Waterway By-law 5888/92 | Regulatory buffer |
| 10 | Winnipeg Waterway Corridor — Creeks (76 m) | Derived from OSM, Waterway By-law 5888/92 | Regulatory buffer |
| (aux) | City of Winnipeg boundary | OSM Nominatim | Used to fire DFFA footnote |

The waterway corridors are derived: river/creek centrelines from OpenStreetMap (Overpass), buffered by the by-law distances, and clipped to the Winnipeg boundary.

## Requirements

- R 4.3+ with packages: `sf`, `leaflet`, `dplyr`, `tibble`, `gt`, `htmltools`, `httr2`, `jsonlite`, `yaml`, `digest`, `rprojroot`, `quarto`, `optparse`, `knitr`, `rmapshaper` (web simplification), `webshot2` (PNG export, optional).
- Quarto 1.4+.
- Node + Vercel CLI (only if deploying the web app).

## First-time setup

```bash
# 1. Pull all eight authoritative source layers into data/
Rscript R/refresh_flood_data.R

# 2. Build the three Winnipeg-derived layers (waterway corridors + boundary)
Rscript R/fetch_winnipeg_waterway_corridors.R

# 3. (Optional) Build the simplified web payload from data/ -> web/data/
Rscript R/simplify_for_web.R
```

Step 1 takes ~5 minutes — the 1-in-200 layer is fetched per-OID with ~50 m geometry simplification and ArcGIS 429 rate-limit handling. Step 2 hits Overpass + Nominatim. Step 3 simplifies polygons aggressively (3–30 % vertex retention by layer) so the entire web payload fits in ~500 KB.

`data/layers.yml` is the manifest — source URL, native CRS, feature count, SHA-256, refresh timestamp — and is the single source of truth used by both the R analysis and the web app.

## Rendering an R/Quarto report

Edit the YAML header of `property_flood_report.qmd` and render, or use the CLI wrapper:

```bash
Rscript R/render_report.R \
  --lat 49.5602 --lon -97.1780 \
  --address "123 Main St, Ste. Agathe MB" \
  --job-id 2026-0420-Example \
  --out outputs/2026-0420-Example/
```

The rendered HTML contains:

1. Job header (ID, address, coordinates, render date).
2. **Screening conclusion table** — one row per layer with inside/outside, nearest-extent distance (metres), source, refresh date, note.
3. **Copy-ready appraisal paragraph** — composed in `R/analyze_subject.R` from the screening result. Adds conditional sentences for: DFA hits (WRA Act s.17 permit), RRV SMA (planning overlay), Winnipeg waterway corridor (Waterway Permit under By-law 5888/92), and properties inside Winnipeg (DFFA / Manitoba Reg. 266/91 footnote).
4. **Interactive Leaflet map** — toggleable layers over satellite/roads basemap, subject pin, legend, scale bar.
5. **Static PNG exhibit** (if `webshot2` is installed) written to `outputs/<job_id>/`.
6. **Sources & methodology footer** — pulled from `data/layers.yml`.

## Running the web app

```bash
# Local preview
python -m http.server 5173 --directory web
# open http://localhost:5173

# Deploy
cd web && vercel --prod
```

The web app uses identical screening logic in JS (Turf.js for spatial ops). Geocoding goes to Mapbox first (token in `web/app.js`, restricted to the production domain) and falls back to Nominatim.

## Project layout

```
MBFloodMapping/
├── property_flood_report.qmd            # Quarto template
├── R/
│   ├── fetch_arcgis_layer.R             # ArcGIS REST helper (pagination, retries, simplification)
│   ├── refresh_flood_data.R             # Pulls 8 authoritative layers into data/
│   ├── fetch_winnipeg_waterway_corridors.R  # OSM-derived waterway corridors + Wpg boundary
│   ├── simplify_for_web.R               # data/ -> web/data/ (rmapshaper)
│   ├── analyze_subject.R                # Spatial analysis + paragraph composition
│   └── render_report.R                  # CLI Quarto wrapper
├── data/                                # Authoritative GeoJSONs + layers.yml
├── web/                                 # Static Leaflet+Turf.js app (Vercel)
│   ├── index.html, app.js, style.css
│   ├── vercel.json
│   └── data/                            # Simplified GeoJSONs + layers.json
├── shiny_app/                           # Legacy Shiny prototype — superseded by web/
├── subjects/example_subjects.csv        # Sample subjects for testing
├── outputs/                             # Rendered HTML/PNG per job (gitignored)
└── PLAN.md                              # Original design doc (historical)
```

## Caveats

All paragraph variants include: *"This map is based on publicly available provincial and federal flood mapping … and is intended for appraisal context only; it is not a legal survey, engineering flood study, insurance determination, or site-specific flood protection level assessment."*

The 1-in-200 year layer is served simplified at ~50 m tolerance; subject determinations within ~50 m of any polygon edge should be verified against the authoritative source. The NRCan Canada Flood Map Inventory is a **study-coverage index**, not a flood extent — its absence from an area does not mean no mapping exists, and it is excluded from inside/outside conclusions (info-only on the map and table).

The Winnipeg waterway corridors are **derived** from OSM centrelines buffered by the by-law distances; they approximate the regulated area for screening but are not authoritative survey lines.

---

# Recreating this project from scratch

If the working directory is lost, the project is fully reproducible from the files in version control plus the public source endpoints. Order matters.

## 1. Restore the scaffold

```
MBFloodMapping/
├── MBFloodMapping.Rproj           # any RStudio project file
├── .gitignore                     # see contents below
├── README.md                      # this file
├── PLAN.md                        # original design (optional but useful context)
├── R/                             # six scripts listed in Project layout
├── property_flood_report.qmd
├── subjects/example_subjects.csv
└── web/                           # index.html, app.js, style.css, vercel.json
```

`.gitignore` contents:

```
.Rproj.user/
.Rhistory
.RData
.Ruserdata
*_files/
*_cache/
outputs/
!outputs/.gitkeep
property_flood_report.html
/.quarto/
**/*.quarto_ipynb
```

If only the README is left, the R scripts and QMD can be reconstructed from the descriptions in the **Code module summary** below — every external endpoint and every domain-specific constant (buffer distances, CRS choices, paragraph language) is documented.

## 2. Pull the data

```bash
Rscript R/refresh_flood_data.R                  # 8 authoritative layers -> data/
Rscript R/fetch_winnipeg_waterway_corridors.R   # 3 derived layers -> data/
Rscript R/simplify_for_web.R                    # web payload -> web/data/
```

## 3. Code module summary (for full rewrite)

- **`R/fetch_arcgis_layer.R`** — `fetch_arcgis_featureserver_layer(url, out_path, max_allowable_offset = NULL, per_oid = FALSE)`. Reads `?f=json` for `maxRecordCount` + native CRS, lists object IDs, fetches in pages or per-OID with optional `maxAllowableOffset` (degrees) for server-side simplification. Handles 429 with 65s sleep and 5 retries. Validates geometry, transforms to EPSG:4326, writes GeoJSON, returns metadata tibble (feature count, native CRS, SHA-256, ISO timestamp).

- **`R/refresh_flood_data.R`** — declarative `tribble()` of 8 layers with kind dispatch (`arcgis`, `mli_shp`, `cfm_mb`). The 1-in-200 layer uses `max_offset = 0.0005` and `per_oid = TRUE` — both are required to avoid ArcGIS rate limits and to keep the output file under 20 MB. NRCan layer is queried with the Manitoba bbox `xmin=-102.3, ymin=48.9, xmax=-88.5, ymax=60.1`. MLI shapefiles ship without a `.prj`; the script defaults missing CRS to EPSG:26914 (UTM 14N NAD83). Writes `data/layers.yml` as the source of truth.

  Endpoint URLs:
  - `https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/img_red_river_flood_1997/FeatureServer/0`
  - `https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Red_River_Flood_-_2009/FeatureServer/0`
  - `https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/img_red_river_flood_2011_metadata/FeatureServer/0`
  - `https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Manitoba_1_in_200_Flood_Layer_v2/FeatureServer/0`
  - `https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_des_flood_area_py_shp.zip`
  - `https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_lower_red_river_dfa_py_shp.zip`
  - `https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_rrvsma_py_shp.zip`
  - `https://maps-cartes.services.geo.ca/server_serveur/rest/services/NRCan/canada_flood_map_inventory_en/MapServer/0`

- **`R/fetch_winnipeg_waterway_corridors.R`** — fetches Winnipeg boundary from Nominatim (`q="Winnipeg, Manitoba, Canada", polygon_geojson=1`); fetches named river / creek centrelines from Overpass (with three endpoint fallbacks: overpass-api.de, overpass.kumi.systems, overpass.private.coffee); regex-filters to the four named rivers (Red, Assiniboine, Seine, La Salle) and four named creeks (Bunn's, Omand's, Truro, Sturgeon); buffers (107 m / 76 m) in EPSG:3347, clips to Winnipeg, transforms back to 4326, writes three GeoJSONs and updates `data/layers.yml`. Set `User-Agent: MBFloodMapping/1.0 (jason@jksconsultinginc.com)` for Nominatim and Overpass per their usage policies.

- **`R/analyze_subject.R`** — `analyze_subject(lat, lon, data_dir, proximity_threshold_m = 500)`. Reads `data/layers.yml`, runs `st_within` and `st_distance` in EPSG:3347 (Statistics Canada Lambert) for accurate metric distances over Manitoba. Returns a list with the screening table and a composed paragraph. Paragraph logic:
  - **Inside any primary layer** (excluding `rrv_special_management_area` and excluding NRCan): list the layers; if any DFA hit, append the WRA Act s.17 sentence.
  - **Outside but within proximity threshold**: name the nearest layer + distance with proximity wording.
  - **Outside, beyond threshold**: name nearest extent + distance.
  - **Append** if RRV SMA hit, if Winnipeg waterway corridor (river or creek) hit, and if the subject is inside the Winnipeg boundary (DFFA / Reg. 266/91 footnote).

- **`R/render_report.R`** — `optparse` CLI: `--lat`, `--lon`, `--address`, `--job-id`, `--zoom`, `--proximity-threshold-m`, `--out`. Calls `quarto::quarto_render(execute_params = …)` and copies the output HTML into `--out`.

- **`R/simplify_for_web.R`** — `rmapshaper::ms_simplify(keep = …, keep_shapes = TRUE)` per layer with per-layer `keep` ratios (0.03–0.30) and field allowlists. Writes simplified GeoJSONs to `web/data/` and a `web/data/layers.json` manifest (overlay layers only — boundary is copied through but not registered). The `nrcan_flood_studies` layer keeps its descriptive fields (`study_name`, `study_date`, `study_status_en`, etc.) so popups can render in the web app.

- **`property_flood_report.qmd`** — params: `lat`, `lon`, `address`, `job_id`, `zoom`, `proximity_threshold_m`. Sources `R/analyze_subject.R`, renders a `gt` table, the paragraph in a styled div, the Leaflet map, and (if `webshot2` is available) a PNG to `outputs/<job_id>/<slug>_<address>.png`. RRV SMA layer is registered but `hideGroup`'d on load.

- **`web/app.js`** — mirrors `analyze_subject.R` in JS using Turf.js (`booleanPointInPolygon`, `pointToLineDistance` / `pointToPolygonDistance`). `INFO_ONLY_LAYERS = {"nrcan_flood_studies"}`, `SECONDARY_LAYERS = {"rrv_special_management_area"}`, `HIDDEN_BY_DEFAULT = {"rrv_special_management_area"}`, `PROXIMITY_THRESHOLD_M = 500`. Mapbox token is restricted to the Vercel domain; if rotated, replace `MAPBOX_TOKEN` at the top of the file. Static PNG export uses `leaflet-simple-map-screenshoter`.

- **`web/vercel.json`** — `cleanUrls: true`; cache headers on `/data/*` (1 day max-age, 7 day stale-while-revalidate). Vercel project metadata is in `web/.vercel/project.json` (project name `mb-flood-mapping`).

## 4. Verification

After a fresh build, sanity-check with the sample subjects in `subjects/example_subjects.csv`:

- **Ste. Agathe** (49.5602, -97.1780) — inside 1997, 2011, 1-in-200, DFA, RRV SMA.
- **Brandon CBD** (49.8437, -99.9518) — outside everything; nearest extent should be a 1-in-200 polygon a long way off.
- **Winnipeg CBD** (49.8951, -97.1384) — DFFA footnote should appear; waterway corridor likely hit depending on coordinate precision.

Then grep the rendered HTML for `not a legal survey, engineering flood study, insurance determination` — the caveat must be present in every paragraph variant.
