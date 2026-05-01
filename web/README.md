# Manitoba Flood Zone Screening — Static Web App

Client-side flood screening tool: Leaflet map + Turf.js spatial ops. Zero backend. Total payload ≈ 500 KB.

## Files

| File | Purpose |
|---|---|
| `index.html` | Shell + CDN imports (Leaflet, Awesome Markers, Turf.js, Font Awesome) |
| `app.js` | Loads GeoJSONs, runs screening, builds the map, renders table + paragraph |
| `style.css` | Layout |
| `data/layers.json` | Layer metadata (label, source, refreshed date) |
| `data/*.geojson` | Six simplified flood-layer polygons (~50 m tolerance) |
| `vercel.json` | CDN cache headers for `/data/*` |

## Local dev

```bash
# From project root:
python -m http.server 5173 --directory web
# open http://localhost:5173
```

## Deploy to Vercel

```bash
# One-time:
npm i -g vercel

# From this web/ directory:
vercel --prod
```

Or connect the repo on vercel.com and set **Root Directory** to `web/`.

## Refreshing the data

Polygons are pre-simplified via `../R/simplify_for_web.R` from the authoritative cache in `../data/`. To refresh:

```bash
# From project root, re-pull source data, then re-simplify:
Rscript R/refresh_flood_data.R
Rscript R/simplify_for_web.R
```

Both steps are idempotent.

## Caveats

Simplification tolerance is ~50 m on boundary edges; subject determinations within ~50 m of an extent edge should be verified against the authoritative source. All paragraph variants include the standard appraisal caveat.
