#!/usr/bin/env Rscript
# Produce web/data/*.geojson: aggressively simplified polygons for the JS app.

suppressPackageStartupMessages({
  library(sf)
  library(rmapshaper)
  library(jsonlite)
  library(yaml)
})

proj_root <- tryCatch(rprojroot::find_root(rprojroot::has_file("MBFloodMapping.Rproj")),
                      error = function(e) getwd())
setwd(proj_root)

# keep: fraction of vertices to retain. Lower = smaller file, rougher boundaries.
plan <- list(
  red_river_flood_1997         = list(keep = 0.05, fields = c("NAME")),
  red_river_flood_2009         = list(keep = 0.05, fields = c("NAME")),
  red_river_flood_2011         = list(keep = 0.05, fields = c("NAME")),
  mb_1in200_flood_extent       = list(keep = 0.03, fields = c("Name")),
  dfa_all                      = list(keep = 0.10, fields = character(0)),
  dfa_lower_red_river          = list(keep = 0.10, fields = character(0)),
  rrv_special_management_area  = list(keep = 0.10, fields = character(0)),
  wpg_waterway_river_corridor  = list(keep = 0.20, fields = character(0)),
  wpg_waterway_creek_corridor  = list(keep = 0.20, fields = character(0)),
  winnipeg_boundary            = list(keep = 0.05, fields = character(0)),
  nrcan_flood_studies          = list(keep = 0.30, fields = c("study_name","study_date","study_status_en","data_owner_en","public_link","availability_status_en_1"))
)

# Layers that are rendered as overlays in the UI. Other layers (e.g. boundary)
# are copied to web/data but excluded from layers.json.
overlay_layers <- c(
  "red_river_flood_1997", "red_river_flood_2009", "red_river_flood_2011",
  "mb_1in200_flood_extent",
  "dfa_all", "dfa_lower_red_river", "rrv_special_management_area",
  "wpg_waterway_river_corridor", "wpg_waterway_creek_corridor",
  "nrcan_flood_studies"
)

dir.create("web/data", showWarnings = FALSE, recursive = TRUE)

for (nm in names(plan)) {
  src <- file.path("data", paste0(nm, ".geojson"))
  dst <- file.path("web/data", paste0(nm, ".geojson"))
  if (!file.exists(src)) {
    cat(sprintf("%-32s (missing source, skipping)\n", nm))
    next
  }
  x <- read_sf(src, quiet = TRUE) |> st_transform(4326)
  simp <- ms_simplify(x, keep = plan[[nm]]$keep, keep_shapes = TRUE)
  keep_fields <- intersect(plan[[nm]]$fields, names(simp))
  simp <- simp[, keep_fields]
  write_sf(simp, dst, delete_dsn = TRUE, quiet = TRUE)
  cat(sprintf("%-32s %8.1f KB -> %8.1f KB (keep=%.2f)\n",
              nm,
              file.info(src)$size / 1024,
              file.info(dst)$size / 1024,
              plan[[nm]]$keep))
}

# Write layers.json metadata for the JS app (overlay layers only)
meta <- yaml::read_yaml("data/layers.yml")$layers
meta <- Filter(function(x) x$name %in% overlay_layers, meta)
ordered <- lapply(overlay_layers, function(n) Filter(function(m) m$name == n, meta)[[1]])
ordered <- Filter(Negate(is.null), ordered)

layers_json <- lapply(ordered, function(x) list(
  name = x$name,
  label = x$label,
  source = x$source,
  url = x$url,
  refreshed = substr(x$refreshed_iso, 1, 10),
  file = paste0(x$name, ".geojson")
))
write(jsonlite::toJSON(layers_json, auto_unbox = TRUE, pretty = TRUE),
      file = "web/data/layers.json")

cat("\nDone. Total size of web/data/:\n")
fs <- list.files("web/data", full.names = TRUE)
cat(sprintf("  %d files, %.1f KB total\n", length(fs), sum(file.info(fs)$size) / 1024))
