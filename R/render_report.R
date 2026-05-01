#!/usr/bin/env Rscript
# CLI wrapper: render property_flood_report.qmd for a given subject.
# Usage:
#   Rscript R/render_report.R --lat 49.5602 --lon -97.1780 \
#     --address "123 Main St, Ste. Agathe MB" \
#     --job-id 2026-0420-Example \
#     --out outputs/2026-0420-Example/

suppressPackageStartupMessages({
  library(optparse)
  library(quarto)
})

opts <- OptionParser(option_list = list(
  make_option("--lat",      type = "double"),
  make_option("--lon",      type = "double"),
  make_option("--address",  type = "character", default = ""),
  make_option("--job-id",   type = "character", default = format(Sys.Date(), "%Y-%m-%d")),
  make_option("--zoom",     type = "integer",   default = 12L),
  make_option("--proximity-threshold-m", type = "integer", default = 500L),
  make_option("--out",      type = "character", default = NULL,
              help = "Directory to copy the rendered HTML into")
)) |> parse_args()

proj_root <- tryCatch(rprojroot::find_root(rprojroot::has_file("MBFloodMapping.Rproj")),
                      error = function(e) getwd())
setwd(proj_root)

if (is.null(opts$lat) || is.null(opts$lon)) stop("--lat and --lon are required")

job_id  <- opts$`job-id`
address <- if (nzchar(opts$address)) opts$address else sprintf("Subject at %.5f, %.5f", opts$lat, opts$lon)

quarto::quarto_render(
  input = "property_flood_report.qmd",
  execute_params = list(
    lat = opts$lat,
    lon = opts$lon,
    address = address,
    job_id = job_id,
    zoom = opts$zoom,
    proximity_threshold_m = opts$`proximity-threshold-m`
  )
)

if (!is.null(opts$out)) {
  dir.create(opts$out, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(opts$out, sprintf("flood_exhibit_%s.html", job_id))
  file.copy("property_flood_report.html", dest, overwrite = TRUE)
  cat("\nWrote:", normalizePath(dest), "\n")
}
