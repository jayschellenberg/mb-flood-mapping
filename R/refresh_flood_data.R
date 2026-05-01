#!/usr/bin/env Rscript
# Refresh all Manitoba flood layers into ./data and write ./data/layers.yml

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
