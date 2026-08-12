#!/usr/bin/env Rscript
# Refresh all Manitoba flood layers into ./data and write ./data/layers.yml

# =============================================================================
# WARNING (recorded 2026-08-12): THE MLI SOURCE BELOW IS A FROZEN ARCHIVE.
# =============================================================================
# Three of the eight layers this script pulls -- dfa_all, dfa_lower_red_river
# and rrv_special_management_area -- come from mli.gov.mb.ca shapefile zips.
# The Manitoba Land Initiative homepage (https://mli.gov.mb.ca/, checked
# 2026-08-12) states verbatim:
#
#     "As of February 9, 2022, the datasets available on the Manitoba Land
#      Initiative will no longer be updated."
#
# and redirects users to DataMB (https://geoportal.gov.mb.ca/, contact
# ManitobaMaps@gov.mb.ca). The zips still download, so this script keeps
# succeeding -- it just re-fetches 2022-vintage bytes and stamps them with
# today's date in data/layers.yml. That is the dangerous failure mode: the
# annual re-pull LOOKS like a refresh, and the staleness watchdog goes green.
#
# It matters because two of those three are STATUTORY boundaries quoted in
# client-facing appraisal text -- the Designated Flood Areas (Water Resources
# Administration Act s.17) and the Red River Valley Special Management Area
# (Planning Act). If either is changed by regulation, the change will appear on
# DataMB and never on MLI.
#
# WHAT EXISTS ON DataMB TODAY (checked 2026-08-12; both public, Manitoba Open
# Data Licence, owner Manitoba_Government, and hosted on the SAME ArcGIS org
# this script already uses for the 1997 / 2009 / 2011 / 1-in-200 layers):
#
#   "Manitoba Designated Flood Areas"  --  NEWER THAN THE MLI COPY
#     https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/DFA_final/FeatureServer/0
#     portal item 0cd6ad6248894823b7578e4004d0d7d1
#     ONE layer holding BOTH DFAs as 2 polygons, separated by the field
#     Designated_Flood_Area_Zone -- not the two separate files MLI ships.
#     Item created 2024-08-13. Layer editingInfo: dataLastEditDate 2025-04-02,
#     lastEditDate 2026-03-03 -- edits that post-date the MLI freeze by years.
#
#   "Red River Valley Special Management Area"  --  NOT newer
#     https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Red_River_Valley_Special_Management_Area/FeatureServer/0
#     portal item 1a215a9ccfca4d7d815cabbf0fef3f71
#     1 polygon; fields FID, NAME, LEGISL, AREA_EN, AREA_FR. editingInfo
#     dataLastEditDate 2022-01-31, i.e. BEFORE the MLI freeze -- the same
#     vintage as the zip, just parked somewhere still maintained.
#
# Authoritative human cross-check (Manitoba Transportation and Infrastructure,
# the department that issues the DFA permits):
#   https://www.gov.mb.ca/mti/wms/permit/designated.html
#   https://www.gov.mb.ca/mti/wms/structures/pdf/rrvdfa_boundary.pdf
#   https://www.gov.mb.ca/mti/wms/structures/pdf/lower_rrvdfa_boundary.pdf
#
# CAVEAT ON THE EVIDENCE: an ArcGIS editingInfo date proves the layer was
# edited, not that the boundary polygon moved -- an attribute or schema touch
# bumps the same field. Confirming an actual boundary change needs a geometry
# diff of DFA_final against data/dfa_all.geojson and
# data/dfa_lower_red_river.geojson. That diff has NOT been run.
#
# DELIBERATELY NOT CHANGED: the three URLs below still point at MLI. Silently
# repointing a statutory boundary would change what client-facing appraisal
# text asserts, and the DFA repoint is not a URL swap -- it merges two layers
# into one and changes the schema, the feature count, and the source citation
# carried through data/layers.yml into the report footer. Jason decides.
# Until he does, treat any DFA / RRVSMA refresh from this script as a re-pull
# of 2022 data, NOT as evidence that the boundary is current.
# =============================================================================

suppressPackageStartupMessages({
  library(sf)
  library(httr2)
  library(yaml)
  library(tibble)
  library(digest)
})

here <- function(...) file.path(dirname(dirname(normalizePath(sys.frame(1)$ofile %||% "R/refresh_flood_data.R", mustWork = FALSE))), ...)
proj_root <- tryCatch(rprojroot::find_root(rprojroot::has_file("MBFloodMapping.Rproj")),
                      error = function(e) getwd())
setwd(proj_root)

source("R/fetch_arcgis_layer.R")

layers <- tribble(
  ~name,                     ~kind,         ~source_label,                              ~url,                                                                                                          ~max_offset, ~per_oid,
  "red_river_flood_1997",    "arcgis",      "Data MB (Manitoba Government)",            "https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/img_red_river_flood_1997/FeatureServer/0",    NA_real_,    FALSE,
  "red_river_flood_2009",    "arcgis",      "Data MB (Manitoba Government)",            "https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Red_River_Flood_-_2009/FeatureServer/0",    NA_real_,    FALSE,
  "red_river_flood_2011",    "arcgis",      "Data MB (Manitoba Government)",            "https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/img_red_river_flood_2011_metadata/FeatureServer/0", NA_real_, FALSE,
  "mb_1in200_flood_extent",  "arcgis",      "Manitoba Infrastructure",                  "https://services.arcgis.com/mMUesHYPkXjaFGfS/arcgis/rest/services/Manitoba_1_in_200_Flood_Layer_v2/FeatureServer/0", 0.0005, TRUE,
  "dfa_all",                 "mli_shp",     "Manitoba Land Initiative (WRA Act s.17)",  "https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_des_flood_area_py_shp.zip",                                  NA_real_,    FALSE,
  "dfa_lower_red_river",          "mli_shp",     "Manitoba Land Initiative (WRA Act s.17)",        "https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_lower_red_river_dfa_py_shp.zip",                             NA_real_,    FALSE,
  "rrv_special_management_area",  "mli_shp",     "Manitoba Land Initiative (Planning Act)",        "https://mli.gov.mb.ca/adminbnd/shp_zip_files/bdy_rrvsma_py_shp.zip",                                           NA_real_,    FALSE,
  "nrcan_flood_studies",          "cfm_mb",      "NRCan Canada Flood Map Inventory",               "https://maps-cartes.services.geo.ca/server_serveur/rest/services/NRCan/canada_flood_map_inventory_en/MapServer/0", NA_real_, FALSE
)

layer_labels <- c(
  red_river_flood_1997        = "1997 Red River Flood (historical extent)",
  red_river_flood_2009        = "2009 Red River Flood (historical extent)",
  red_river_flood_2011        = "2011 Red River / Assiniboine Flood (historical extent)",
  mb_1in200_flood_extent      = "Manitoba 1-in-200 Year Flood Extent (0.5% AEP)",
  dfa_all                     = "Designated Flood Area (Red River Valley DFA)",
  dfa_lower_red_river         = "Lower Red River Designated Flood Area",
  rrv_special_management_area = "Red River Valley Special Management Area",
  nrcan_flood_studies         = "NRCan Flood Study Coverage (Manitoba)"
)

dir.create("data", showWarnings = FALSE)

fetch_cfm_mb <- function(layer_url, out_path) {
  # NRCan Canada Flood Map Inventory: fetch polygons intersecting Manitoba's bounding box.
  mb_bbox <- list(xmin = -102.3, ymin = 48.9, xmax = -88.5, ymax = 60.1)
  q <- list(
    where = "1=1",
    geometry = jsonlite::toJSON(c(mb_bbox, list(spatialReference = list(wkid = 4326))), auto_unbox = TRUE),
    geometryType = "esriGeometryEnvelope",
    spatialRel = "esriSpatialRelIntersects",
    inSR = "4326",
    outFields = "*",
    outSR = "4326",
    f = "geojson"
  )
  resp <- do.call(req_url_query, c(list(request(paste0(layer_url, "/query"))), q)) |>
    req_timeout(180) |>
    req_perform()
  sf_obj <- read_sf(I(resp_body_string(resp)), quiet = TRUE)
  if (any(!st_is_valid(sf_obj))) sf_obj <- st_make_valid(sf_obj)
  sf_obj <- st_transform(sf_obj, 4326)
  write_sf(sf_obj, out_path, delete_dsn = TRUE, quiet = TRUE)
  list(
    feature_count = nrow(sf_obj),
    native_crs = "EPSG:4326",
    sha256 = digest(file = out_path, algo = "sha256"),
    refreshed_iso = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
}

fetch_mli_shp <- function(zip_url, out_path) {
  tmp_zip <- tempfile(fileext = ".zip")
  tmp_dir <- tempfile()
  dir.create(tmp_dir)
  download.file(zip_url, tmp_zip, mode = "wb", quiet = TRUE)
  unzip(tmp_zip, exdir = tmp_dir)
  shp <- list.files(tmp_dir, pattern = "\\.shp$", recursive = TRUE, full.names = TRUE)[1]
  if (is.na(shp)) stop("No .shp found in ", zip_url)
  sf_obj <- read_sf(shp, quiet = TRUE)
  # Some older MLI shapefiles ship without a .prj — default to UTM 14N NAD83
  # (EPSG:26914), which is MLI's standard projection for Manitoba layers.
  if (is.na(st_crs(sf_obj)$epsg) && is.na(st_crs(sf_obj)$wkt)) {
    st_crs(sf_obj) <- 26914
  }
  native_crs_wkid <- st_crs(sf_obj)$epsg
  sf_obj <- st_transform(sf_obj, 4326)
  if (any(!st_is_valid(sf_obj))) sf_obj <- st_make_valid(sf_obj)
  write_sf(sf_obj, out_path, delete_dsn = TRUE, quiet = TRUE)
  list(
    feature_count = nrow(sf_obj),
    native_crs = if (!is.null(native_crs_wkid) && !is.na(native_crs_wkid)) paste0("EPSG:", native_crs_wkid) else "unknown",
    sha256 = digest(file = out_path, algo = "sha256"),
    refreshed_iso = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
}

results <- list()

for (i in seq_len(nrow(layers))) {
  row <- layers[i, ]
  out_path <- file.path("data", paste0(row$name, ".geojson"))
  cat(sprintf("[%d/%d] %s ... ", i, nrow(layers), row$name))

  res <- tryCatch({
    if (row$kind == "arcgis") {
      fetch_arcgis_featureserver_layer(
        row$url, out_path,
        max_allowable_offset = if (is.na(row$max_offset)) NULL else row$max_offset,
        per_oid = isTRUE(row$per_oid)
      )
    } else if (row$kind == "mli_shp") {
      fetch_mli_shp(row$url, out_path)
    } else if (row$kind == "cfm_mb") {
      fetch_cfm_mb(row$url, out_path)
    } else {
      stop("Unknown kind: ", row$kind)
    }
  }, error = function(e) {
    cat("FAILED:", conditionMessage(e), "\n")
    NULL
  })

  if (!is.null(res)) {
    cat(sprintf("OK (%d features, %s)\n", res$feature_count, res$native_crs))
    results[[row$name]] <- list(
      name = row$name,
      label = unname(layer_labels[row$name]),
      kind = row$kind,
      source = row$source_label,
      url = row$url,
      native_crs = res$native_crs,
      feature_count = as.integer(res$feature_count),
      sha256 = res$sha256,
      refreshed_iso = res$refreshed_iso,
      file = out_path
    )
  }
}

yaml::write_yaml(list(layers = unname(results)), "data/layers.yml")
cat("\nWrote", length(results), "layers to data/ and data/layers.yml\n")
