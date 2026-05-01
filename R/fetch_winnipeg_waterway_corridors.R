#!/usr/bin/env Rscript
# Build Winnipeg Waterway By-law 5888/92 regulated-area corridors from OSM.
# Buffers named river centrelines by 107 m and named creek centrelines by 76 m,
# clipped to the City of Winnipeg boundary. Writes three GeoJSONs into data/
# and updates data/layers.yml:
#   wpg_waterway_river_corridor.geojson   (107 m buffer, 4 named rivers)
#   wpg_waterway_creek_corridor.geojson   (76  m buffer, 4 named creeks)
#   winnipeg_boundary.geojson             (used for DFFA-footnote check)
#
# Winnipeg boundary is fetched from Nominatim (polygon_geojson).
# River/creek centrelines are fetched directly from Overpass via httr2 and
# parsed into sf without going through the osmdata package (which retries
# aggressively on transient rate limits).

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(httr2)
  library(jsonlite)
  library(digest)
  library(yaml)
})

proj_root <- tryCatch(rprojroot::find_root(rprojroot::has_file("MBFloodMapping.Rproj")),
                      error = function(e) getwd())
setwd(proj_root)

RIVER_BUFFER_M <- 107   # Winnipeg Waterway By-law 5888/92: 350 ft
CREEK_BUFFER_M <- 76    # Winnipeg Waterway By-law 5888/92: 250 ft
LAMBERT <- 3347

# Winnipeg bbox in Overpass order (south, west, north, east)
OVERPASS_BBOX <- "49.72,-97.40,50.05,-96.95"
OVERPASS_URLS <- c(
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.private.coffee/api/interpreter"
)
USER_AGENT <- "MBFloodMapping/1.0 (jason@jksconsultinginc.com)"

RIVER_NAMES_RX <- "^(Red|Assiniboine|Seine|La ?Salle) River$"
CREEK_NAMES_RX <- "^(Bunn'?s Creek|Omand'?s Creek|Truro Creek|Sturgeon Creek)$"

message("Fetching City of Winnipeg boundary via Nominatim...")
fetch_wpg_boundary_nominatim <- function() {
  resp <- request("https://nominatim.openstreetmap.org/search") |>
    req_url_query(q = "Winnipeg, Manitoba, Canada",
                  format = "json", limit = 1, polygon_geojson = 1) |>
    req_headers(`User-Agent` = USER_AGENT) |>
    req_timeout(60) |>
    req_perform()
  j <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
  if (length(j) == 0 || is.null(j[[1]]$geojson)) {
    stop("Nominatim returned no polygon for Winnipeg.")
  }
  geom_json <- toJSON(j[[1]]$geojson, auto_unbox = TRUE)
  fc_json <- paste0('{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":',
                    geom_json, '}]}')
  read_sf(I(fc_json), quiet = TRUE) |> st_make_valid()
}

wpg_poly_ll <- fetch_wpg_boundary_nominatim()
wpg_poly <- st_transform(wpg_poly_ll, LAMBERT)
message(sprintf("  Winnipeg boundary: %d feature(s), bbox %s",
                nrow(wpg_poly_ll),
                paste(round(as.numeric(st_bbox(wpg_poly_ll)), 3), collapse = ", ")))

# --- Direct Overpass call -----------------------------------------------------

overpass_query <- function(query) {
  last_err <- NULL
  for (url in OVERPASS_URLS) {
    message("  trying ", url)
    out <- tryCatch({
      resp <- request(url) |>
        req_body_form(data = query) |>
        req_headers(`User-Agent` = USER_AGENT) |>
        req_timeout(300) |>
        req_retry(max_tries = 2, backoff = \(i) 15 * i,
                  is_transient = \(r) resp_status(r) %in% c(429, 502, 503, 504)) |>
        req_perform()
      fromJSON(resp_body_string(resp), simplifyVector = FALSE)
    }, error = function(e) {
      message("    failed: ", conditionMessage(e))
      last_err <<- e
      NULL
    })
    if (!is.null(out)) return(out)
  }
  stop("All Overpass endpoints failed. Last error: ", conditionMessage(last_err))
}

# Parse Overpass JSON 'elements' array with `out geom` into an sf LINESTRING
# collection. Each way has .geometry list of {lat, lon} points.
ways_to_sf_lines <- function(elements) {
  ways <- Filter(function(e) identical(e$type, "way") && !is.null(e$geometry), elements)
  if (length(ways) == 0) return(NULL)
  geoms <- lapply(ways, function(w) {
    coords <- do.call(rbind, lapply(w$geometry, function(p) c(p$lon, p$lat)))
    st_linestring(coords)
  })
  names_vec <- vapply(ways, function(w) {
    nm <- w$tags$name
    if (is.null(nm)) NA_character_ else nm
  }, character(1))
  st_sf(name = names_vec, geometry = st_sfc(geoms, crs = 4326))
}

fetch_overpass_lines <- function(tag_key, tag_values) {
  vals <- paste0('"', tag_values, '"', collapse = "|")
  # Only ways with a "name" tag; filter more strictly in R afterward.
  query <- sprintf('[out:json][timeout:180];
(
  way["%s"~"^(%s)$"]["name"](%s);
);
out geom tags;', tag_key, paste(tag_values, collapse = "|"), OVERPASS_BBOX)
  j <- overpass_query(query)
  ways_to_sf_lines(j$elements)
}

message("Fetching river centrelines from Overpass...")
rivers <- fetch_overpass_lines("waterway", c("river"))
if (!is.null(rivers) && nrow(rivers) > 0) {
  rivers <- rivers[!is.na(rivers$name) & grepl(RIVER_NAMES_RX, rivers$name), ]
}
message(sprintf("  %d named river segments matched.",
                if (is.null(rivers)) 0L else nrow(rivers)))

message("Fetching creek centrelines from Overpass...")
creeks <- fetch_overpass_lines("waterway", c("stream", "creek"))
if (!is.null(creeks) && nrow(creeks) > 0) {
  creeks <- creeks[!is.na(creeks$name) & grepl(CREEK_NAMES_RX, creeks$name), ]
}
message(sprintf("  %d named creek segments matched.",
                if (is.null(creeks)) 0L else nrow(creeks)))

# --- Buffer + clip ------------------------------------------------------------

buffer_and_clip <- function(lines_sf, dist_m) {
  if (is.null(lines_sf) || nrow(lines_sf) == 0) return(NULL)
  lines_proj <- st_transform(lines_sf, LAMBERT)
  buf <- st_buffer(lines_proj, dist_m) |> st_union() |> st_make_valid()
  clipped <- st_intersection(buf, wpg_poly) |> st_make_valid()
  st_sf(geometry = st_sfc(clipped, crs = LAMBERT)) |> st_transform(4326)
}

rivers_corr <- buffer_and_clip(rivers, RIVER_BUFFER_M)
creeks_corr <- buffer_and_clip(creeks, CREEK_BUFFER_M)
wpg_bnd_out <- st_transform(wpg_poly, 4326) |> st_make_valid() |>
  (\(g) st_sf(geometry = st_geometry(g), crs = 4326))()

dir.create("data", showWarnings = FALSE)

write_layer <- function(sf_obj, name) {
  path <- file.path("data", paste0(name, ".geojson"))
  if (is.null(sf_obj) || nrow(sf_obj) == 0) {
    message("  !! ", name, ": no features \u2014 writing empty FeatureCollection")
    cat('{"type":"FeatureCollection","features":[]}', file = path)
  } else {
    write_sf(sf_obj, path, delete_dsn = TRUE, quiet = TRUE)
  }
  list(
    feature_count = if (is.null(sf_obj)) 0L else nrow(sf_obj),
    native_crs = "EPSG:4326",
    sha256 = digest(file = path, algo = "sha256"),
    refreshed_iso = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    file = path
  )
}

r_meta   <- write_layer(rivers_corr, "wpg_waterway_river_corridor")
c_meta   <- write_layer(creeks_corr, "wpg_waterway_creek_corridor")
wpg_meta <- write_layer(wpg_bnd_out, "winnipeg_boundary")

layers_file <- "data/layers.yml"
existing <- if (file.exists(layers_file)) yaml::read_yaml(layers_file)$layers else list()
by_name <- setNames(existing, vapply(existing, function(x) x$name, character(1)))

by_name[["wpg_waterway_river_corridor"]] <- list(
  name = "wpg_waterway_river_corridor",
  label = "Winnipeg Waterway Corridor \u2014 Rivers (107 m regulated area)",
  kind = "derived_osm_buffer",
  source = "Derived from OpenStreetMap (City of Winnipeg Waterway By-law 5888/92)",
  url = "https://legacy.winnipeg.ca/ppd/CityPlanning/Riverbank/WaterwayPermitApplications.stm",
  native_crs = r_meta$native_crs,
  feature_count = as.integer(r_meta$feature_count),
  sha256 = r_meta$sha256,
  refreshed_iso = r_meta$refreshed_iso,
  file = r_meta$file
)
by_name[["wpg_waterway_creek_corridor"]] <- list(
  name = "wpg_waterway_creek_corridor",
  label = "Winnipeg Waterway Corridor \u2014 Creeks (76 m regulated area)",
  kind = "derived_osm_buffer",
  source = "Derived from OpenStreetMap (City of Winnipeg Waterway By-law 5888/92)",
  url = "https://legacy.winnipeg.ca/ppd/CityPlanning/Riverbank/WaterwayPermitApplications.stm",
  native_crs = c_meta$native_crs,
  feature_count = as.integer(c_meta$feature_count),
  sha256 = c_meta$sha256,
  refreshed_iso = c_meta$refreshed_iso,
  file = c_meta$file
)
by_name[["winnipeg_boundary"]] <- list(
  name = "winnipeg_boundary",
  label = "City of Winnipeg boundary",
  kind = "nominatim",
  source = "OpenStreetMap Nominatim (administrative boundary)",
  url = "https://nominatim.openstreetmap.org/",
  native_crs = wpg_meta$native_crs,
  feature_count = as.integer(wpg_meta$feature_count),
  sha256 = wpg_meta$sha256,
  refreshed_iso = wpg_meta$refreshed_iso,
  file = wpg_meta$file
)

yaml::write_yaml(list(layers = unname(by_name)), layers_file)
cat("\nDone. Waterway corridors and Winnipeg boundary written into data/ and data/layers.yml\n")
