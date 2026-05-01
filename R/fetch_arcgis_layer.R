suppressPackageStartupMessages({
  library(sf)
  library(httr2)
  library(jsonlite)
  library(digest)
})

fetch_arcgis_featureserver_layer <- function(layer_url,
                                             out_path,
                                             max_allowable_offset = NULL,
                                             per_oid = FALSE,
                                             timeout_s = 300L) {
  meta <- request(paste0(layer_url, "?f=json")) |>
    req_timeout(timeout_s) |>
    req_perform() |>
    resp_body_json()

  page_size <- min(meta$maxRecordCount %||% 1000L, 2000L)

  ids <- request(paste0(layer_url, "/query")) |>
    req_url_query(where = "1=1", returnIdsOnly = "true", f = "json") |>
    req_timeout(timeout_s) |>
    req_perform() |>
    resp_body_json()

  object_ids <- unlist(ids$objectIds)
  if (length(object_ids) == 0) stop("No features in ", layer_url)

  if (per_oid) {
    pages <- as.list(object_ids)
  } else {
    pages <- split(object_ids, ceiling(seq_along(object_ids) / page_size))
  }

  fetch_page <- function(page_ids) {
    qs <- list(
      objectIds = paste(page_ids, collapse = ","),
      outFields = "*",
      outSR = "4326",
      f = "geojson"
    )
    if (!is.null(max_allowable_offset)) {
      qs$maxAllowableOffset <- format(max_allowable_offset, scientific = FALSE)
    }
    for (attempt in 1:5) {
      resp <- do.call(req_url_query, c(list(request(paste0(layer_url, "/query"))), qs)) |>
        req_timeout(timeout_s) |>
        req_error(is_error = function(r) FALSE) |>
        req_perform()
      body <- resp_body_string(resp)
      if (grepl('"error"\\s*:', substr(body, 1, 200))) {
        parsed <- tryCatch(jsonlite::fromJSON(body), error = function(e) NULL)
        if (!is.null(parsed$error) && parsed$error$code == 429) {
          wait <- 65
          message("  rate limited (429), sleeping ", wait, "s then retrying (attempt ", attempt, ")")
          Sys.sleep(wait)
          next
        }
        stop("ArcGIS error: ", substr(body, 1, 300))
      }
      return(read_sf(I(body), quiet = TRUE))
    }
    stop("Exhausted retries for page")
  }

  sf_pages <- lapply(seq_along(pages), function(i) {
    if (length(pages) > 1) cat(sprintf("  page %d/%d\n", i, length(pages)))
    res <- fetch_page(pages[[i]])
    if (per_oid && i < length(pages)) Sys.sleep(1.1)
    res
  })

  combined <- do.call(rbind, sf_pages)

  if (any(!st_is_valid(combined))) {
    combined <- st_make_valid(combined)
  }
  combined <- st_transform(combined, 4326)

  write_sf(combined, out_path, delete_dsn = TRUE, quiet = TRUE)

  list(
    feature_count = nrow(combined),
    native_crs = paste0("EPSG:", meta$extent$spatialReference$wkid),
    sha256 = digest(file = out_path, algo = "sha256"),
    refreshed_iso = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
}
