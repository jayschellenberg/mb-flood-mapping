suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(tibble)
  library(yaml)
})

STATS_CAN_LAMBERT <- 3347

layer_display <- c(
  red_river_flood_1997         = "1997 Red River Flood (historical extent)",
  red_river_flood_2009         = "2009 Red River Flood (historical extent)",
  red_river_flood_2011         = "2011 Red River / Assiniboine Flood (historical extent)",
  mb_1in200_flood_extent       = "Manitoba 1-in-200 Year Flood Extent (0.5% AEP)",
  dfa_all                      = "Red River Valley Designated Flood Area",
  dfa_lower_red_river          = "Lower Red River Designated Flood Area",
  rrv_special_management_area  = "Red River Valley Special Management Area",
  wpg_waterway_river_corridor  = "Winnipeg Waterway Corridor \u2014 Rivers (107 m)",
  wpg_waterway_creek_corridor  = "Winnipeg Waterway Corridor \u2014 Creeks (76 m)"
)

layer_note <- c(
  red_river_flood_1997         = "Observed overland flood boundary",
  red_river_flood_2009         = "Observed overland flood boundary",
  red_river_flood_2011         = "Observed overland flood boundary",
  mb_1in200_flood_extent       = "Statistical 0.5% annual-exceedance-probability extent",
  dfa_all                      = "Statutory DFA \u2014 permit may be required (WRA Act s.17)",
  dfa_lower_red_river          = "Statutory DFA \u2014 permit may be required (WRA Act s.17)",
  rrv_special_management_area  = "Provincial planning overlay (Red River Valley SMA)",
  wpg_waterway_river_corridor  = "City Waterway Permit may be required (By-law 5888/92)",
  wpg_waterway_creek_corridor  = "City Waterway Permit may be required (By-law 5888/92)"
)

analyze_subject <- function(lat, lon, data_dir = "data", proximity_threshold_m = 500) {
  layers_meta <- yaml::read_yaml(file.path(data_dir, "layers.yml"))$layers
  meta_by_name <- setNames(layers_meta, vapply(layers_meta, function(x) x$name, character(1)))

  subject <- st_sfc(st_point(c(lon, lat)), crs = 4326)
  subject_proj <- st_transform(subject, STATS_CAN_LAMBERT)

  rows <- lapply(names(layer_display), function(nm) {
    meta <- meta_by_name[[nm]]
    path <- file.path(data_dir, paste0(nm, ".geojson"))

    if (is.null(meta) || !file.exists(path)) {
      return(tibble(
        layer = layer_display[[nm]],
        inside = NA,
        nearest_m = NA_real_,
        source = NA_character_,
        refreshed = NA_character_,
        note = "Data unavailable \u2014 layer not loaded",
        layer_key = nm
      ))
    }

    poly <- read_sf(path, quiet = TRUE)
    if (nrow(poly) == 0) {
      return(tibble(
        layer = layer_display[[nm]],
        inside = FALSE,
        nearest_m = NA_real_,
        source = meta$source,
        refreshed = substr(meta$refreshed_iso, 1, 10),
        note = layer_note[[nm]],
        layer_key = nm
      ))
    }
    poly <- st_transform(poly, STATS_CAN_LAMBERT)
    inside_any <- any(lengths(st_within(subject_proj, poly)) > 0)
    dist_m <- if (inside_any) 0 else as.numeric(min(st_distance(subject_proj, poly)))

    tibble(
      layer = layer_display[[nm]],
      inside = inside_any,
      nearest_m = dist_m,
      source = meta$source,
      refreshed = substr(meta$refreshed_iso, 1, 10),
      note = layer_note[[nm]],
      layer_key = nm
    )
  })

  result_tbl <- bind_rows(rows)

  SECONDARY_LAYERS <- c("rrv_special_management_area")

  primary_inside_idx <- which(result_tbl$inside & !(result_tbl$layer_key %in% SECONDARY_LAYERS))
  secondary_inside_idx <- which(result_tbl$inside & result_tbl$layer_key %in% SECONDARY_LAYERS)

  any_primary_inside <- length(primary_inside_idx) > 0
  any_inside <- any(result_tbl$inside, na.rm = TRUE)  # kept for backwards-compat in return list
  layers_inside <- result_tbl$layer[primary_inside_idx]
  layers_inside <- layers_inside[!is.na(layers_inside)]
  secondary_inside_layers <- result_tbl$layer[secondary_inside_idx]
  secondary_inside_layers <- secondary_inside_layers[!is.na(secondary_inside_layers)]

  valid <- result_tbl |> filter(!is.na(inside), !inside, !is.na(nearest_m))
  nearest_overall <- if (nrow(valid) > 0) {
    valid |> arrange(nearest_m) |> slice(1)
  } else NULL

  in_dfa <- any(result_tbl$inside[result_tbl$layer_key %in% c("dfa_all", "dfa_lower_red_river")], na.rm = TRUE)
  in_wpg_river_corr <- isTRUE(result_tbl$inside[result_tbl$layer_key == "wpg_waterway_river_corridor"][1])
  in_wpg_creek_corr <- isTRUE(result_tbl$inside[result_tbl$layer_key == "wpg_waterway_creek_corridor"][1])

  # Subject-inside-Winnipeg check for DFFA footnote
  in_winnipeg <- FALSE
  wpg_path <- file.path(data_dir, "winnipeg_boundary.geojson")
  if (file.exists(wpg_path)) {
    wpg <- tryCatch(read_sf(wpg_path, quiet = TRUE), error = function(e) NULL)
    if (!is.null(wpg) && nrow(wpg) > 0) {
      wpg_proj <- st_transform(wpg, STATS_CAN_LAMBERT)
      in_winnipeg <- any(lengths(st_within(subject_proj, wpg_proj)) > 0)
    }
  }

  refreshed_date <- max(result_tbl$refreshed, na.rm = TRUE)
  refreshed_long <- format(as.Date(refreshed_date), "%B %d, %Y")

  format_distance <- function(m) {
    if (m <= 1000) {
      paste0(format(round(m), big.mark = ","), " metres")
    } else if (m < 3000) {
      paste0(formatC(m / 1000, format = "f", digits = 2), " kilometres")
    } else {
      paste0(format(round(m / 1000), big.mark = ","), " kilometres")
    }
  }

  caveat <- paste(
    "This map is based on publicly available provincial and federal flood mapping as of",
    refreshed_long,
    "and is intended for appraisal context only; it is not a legal survey, engineering flood study, insurance determination, or site-specific flood protection level assessment."
  )

  paragraph <- if (any_primary_inside) {
    dfa_sentence <- if (in_dfa) " A Designated Flood Area permit may be required for new permanent structures under Section 17 of The Water Resources Administration Act." else ""
    sprintf(
      "The subject property is located within one or more mapped flood-risk or regulatory overlays reviewed for this appraisal, specifically: %s.%s %s",
      paste(layers_inside, collapse = "; "),
      dfa_sentence,
      caveat
    )
  } else if (!is.null(nearest_overall) && nearest_overall$nearest_m < proximity_threshold_m) {
    sprintf(
      "The subject property is not located within any of the mapped flood-risk or regulatory overlays reviewed for this appraisal, but it is in close proximity: the nearest mapped extent (%s) is approximately %s from the subject. %s",
      nearest_overall$layer, format_distance(nearest_overall$nearest_m), caveat
    )
  } else if (!is.null(nearest_overall)) {
    sprintf(
      "The subject property is not located within any of the mapped flood-risk or regulatory overlays reviewed for this appraisal. The nearest mapped extent (%s) is approximately %s from the subject. %s",
      nearest_overall$layer, format_distance(nearest_overall$nearest_m), caveat
    )
  } else {
    sprintf("The subject property could not be evaluated because no flood layers were loaded. %s", caveat)
  }

  if (length(secondary_inside_layers) > 0) {
    paragraph <- paste0(paragraph, sprintf(
      " The subject also falls within the %s, a provincial planning overlay under Manitoba's Planning Act governing development coordination in the Red River Valley; specific implications should be confirmed with the applicable planning district.",
      paste(secondary_inside_layers, collapse = ", ")
    ))
  }

  if (isTRUE(in_wpg_river_corr) || isTRUE(in_wpg_creek_corr)) {
    which_txt <- if (isTRUE(in_wpg_river_corr) && isTRUE(in_wpg_creek_corr)) {
      "the City of Winnipeg's Waterway regulated area along both a river and a creek"
    } else if (isTRUE(in_wpg_river_corr)) {
      "the City of Winnipeg's Waterway regulated area along one of the named rivers (107 m from the Red, Assiniboine, Seine, or La Salle River)"
    } else {
      "the City of Winnipeg's Waterway regulated area along one of the named creeks (76 m from Bunn's, Omand's, Truro, or Sturgeon Creek)"
    }
    paragraph <- paste0(paragraph, sprintf(
      " The subject falls within %s; a Waterway Permit under the City of Winnipeg Waterway By-law 5888/92 may be required for building, riverbank stabilization, fill, grading, decks, pools, or docks.",
      which_txt
    ))
  }

  if (isTRUE(in_winnipeg)) {
    paragraph <- paste0(paragraph,
      " Winnipeg properties located outside the City's primary dike system are subject to the Designated Floodway Fringe Area Regulation (Manitoba Regulation 266/91), which requires new structures to be floodproofed to the applicable Flood Protection Level (raised grade, elevated main floor, no openings below the FPL, and backwater valves). Applicability and FPL for the subject address should be confirmed with the City of Winnipeg Planning, Property and Development department."
    )
  }

  list(
    table = result_tbl,
    any_inside = any_inside,
    layers_inside = layers_inside,
    nearest_overall = nearest_overall,
    in_dfa = in_dfa,
    in_wpg_river_corridor = isTRUE(in_wpg_river_corr),
    in_wpg_creek_corridor = isTRUE(in_wpg_creek_corr),
    in_winnipeg = isTRUE(in_winnipeg),
    refreshed_date = refreshed_date,
    paragraph = paragraph
  )
}
