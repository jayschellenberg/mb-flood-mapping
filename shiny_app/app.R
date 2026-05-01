library(shiny)
library(bslib)
library(leaflet)
library(sf)
library(dplyr)
library(yaml)

STATS_CAN_LAMBERT <- 3347

layer_display <- c(
  red_river_flood_1997   = "1997 Red River Flood (historical extent)",
  red_river_flood_2009   = "2009 Red River Flood (historical extent)",
  red_river_flood_2011   = "2011 Red River / Assiniboine Flood (historical extent)",
  mb_1in200_flood_extent = "Manitoba 1-in-200 Year Flood Extent (0.5% AEP)",
  dfa_all                = "Red River Valley Designated Flood Area",
  dfa_lower_red_river    = "Lower Red River Designated Flood Area"
)

layer_note <- c(
  red_river_flood_1997   = "Observed overland flood boundary",
  red_river_flood_2009   = "Observed overland flood boundary",
  red_river_flood_2011   = "Observed overland flood boundary",
  mb_1in200_flood_extent = "Statistical 0.5% annual-exceedance-probability extent",
  dfa_all                = "Statutory DFA \u2014 permit may be required (WRA Act s.17)",
  dfa_lower_red_river    = "Statutory DFA \u2014 permit may be required (WRA Act s.17)"
)

layer_color <- c(
  red_river_flood_1997   = "#d62728",
  red_river_flood_2009   = "#ff7f0e",
  red_river_flood_2011   = "#1f77b4",
  mb_1in200_flood_extent = "#9467bd",
  dfa_all                = "#2ca02c",
  dfa_lower_red_river    = "#17becf"
)

# Load all layers once at startup
meta <- yaml::read_yaml("data/layers.yml")$layers
meta_by_name <- setNames(meta, vapply(meta, function(x) x$name, character(1)))

polys_4326 <- lapply(names(layer_display), function(nm) {
  p <- file.path("data", paste0(nm, ".geojson"))
  if (!file.exists(p)) return(NULL)
  read_sf(p, quiet = TRUE) |> st_transform(4326)
})
names(polys_4326) <- names(layer_display)

polys_proj <- lapply(polys_4326, function(x) if (is.null(x)) NULL else st_transform(x, STATS_CAN_LAMBERT))

format_distance <- function(m) {
  if (m <= 1000) paste0(format(round(m), big.mark = ","), " metres")
  else if (m < 3000) paste0(formatC(m / 1000, format = "f", digits = 2), " kilometres")
  else paste0(format(round(m / 1000), big.mark = ","), " kilometres")
}

analyze <- function(lat, lon, proximity_threshold_m = 500) {
  subject <- st_sfc(st_point(c(lon, lat)), crs = 4326)
  subject_proj <- st_transform(subject, STATS_CAN_LAMBERT)

  rows <- lapply(names(layer_display), function(nm) {
    meta_row <- meta_by_name[[nm]]
    poly <- polys_proj[[nm]]
    if (is.null(poly) || is.null(meta_row)) {
      return(tibble::tibble(layer = layer_display[[nm]], inside = NA, nearest_m = NA_real_,
                            source = NA_character_, refreshed = NA_character_,
                            note = "Data unavailable", layer_key = nm))
    }
    inside_any <- any(lengths(st_within(subject_proj, poly)) > 0)
    dist_m <- if (inside_any) 0 else as.numeric(min(st_distance(subject_proj, poly)))
    tibble::tibble(
      layer = layer_display[[nm]],
      inside = inside_any,
      nearest_m = dist_m,
      source = meta_row$source,
      refreshed = substr(meta_row$refreshed_iso, 1, 10),
      note = layer_note[[nm]],
      layer_key = nm
    )
  })
  tbl <- bind_rows(rows)
  any_inside <- any(tbl$inside, na.rm = TRUE)
  layers_inside <- tbl$layer[which(tbl$inside)]
  layers_inside <- layers_inside[!is.na(layers_inside)]
  in_dfa <- any(tbl$inside[tbl$layer_key %in% c("dfa_all", "dfa_lower_red_river")], na.rm = TRUE)
  valid <- tbl |> filter(!is.na(inside), !inside, !is.na(nearest_m))
  nearest_overall <- if (nrow(valid) > 0) valid |> arrange(nearest_m) |> slice(1) else NULL

  refreshed_date <- max(tbl$refreshed, na.rm = TRUE)
  refreshed_long <- format(as.Date(refreshed_date), "%B %d, %Y")

  caveat <- paste(
    "This map is based on publicly available provincial mapping as of", refreshed_long,
    "and is intended for appraisal context only; it is not a legal survey, engineering flood study, insurance determination, or site-specific flood protection level assessment."
  )

  paragraph <- if (any_inside) {
    dfa_sentence <- if (in_dfa) " A Designated Flood Area permit may be required for new permanent structures under Section 17 of The Water Resources Administration Act." else ""
    sprintf("The subject property is located within one or more mapped flood-risk layers reviewed for this appraisal, specifically: %s.%s The 1-in-200 year flood extent is a statistical (0.5%% annual exceedance probability) layer prepared by the Province of Manitoba for planning purposes; historical flood extents (1997/2009/2011) reflect the observed overland flooding boundaries of those events. %s",
            paste(layers_inside, collapse = "; "), dfa_sentence, caveat)
  } else if (!is.null(nearest_overall) && nearest_overall$nearest_m < proximity_threshold_m) {
    sprintf("The subject property is not located within the mapped flood extents reviewed for this appraisal (1997, 2009, and 2011 Red River overland flood extents; Manitoba 1-in-200 year flood extent; Red River Valley and Lower Red River Designated Flood Areas), but it is in close proximity: the nearest mapped flood extent (%s) is approximately %s from the subject. %s",
            nearest_overall$layer, format_distance(nearest_overall$nearest_m), caveat)
  } else if (!is.null(nearest_overall)) {
    sprintf("The subject property is not located within the mapped flood extents reviewed for this appraisal (1997, 2009, and 2011 Red River overland flood extents; Manitoba 1-in-200 year flood extent; Red River Valley and Lower Red River Designated Flood Areas). The nearest mapped flood extent (%s) is approximately %s from the subject. %s",
            nearest_overall$layer, format_distance(nearest_overall$nearest_m), caveat)
  } else {
    paste("The subject property could not be evaluated because no flood layers were loaded.", caveat)
  }

  list(table = tbl, any_inside = any_inside, paragraph = paragraph)
}

ui <- page_sidebar(
  title = "Manitoba Flood Zone Screening",
  sidebar = sidebar(
    width = 320,
    textInput("address", "Address / label", value = "Cobalt Road"),
    numericInput("lat", "Latitude", value = 49.8834, step = 0.0001),
    numericInput("lon", "Longitude", value = -96.9313, step = 0.0001),
    numericInput("zoom", "Map zoom", value = 11, min = 6, max = 18),
    actionButton("screen", "Screen Subject", class = "btn-primary w-100"),
    tags$hr(),
    tags$small(tags$em("Initial load takes ~30\u201390 s while the browser downloads the R runtime and cached flood layers."))
  ),
  layout_columns(
    col_widths = c(12, 12),
    card(
      card_header("Screening Conclusion"),
      uiOutput("conclusion_ui"),
      tags$div(style = "border:1px solid #bbb; padding:12px 16px; background:#f8f8f8; border-radius:6px; font-family:Georgia,serif; line-height:1.5;",
               textOutput("paragraph", inline = TRUE))
    ),
    card(
      card_header("Interactive Map"),
      full_screen = TRUE,
      leafletOutput("map", height = "600px")
    )
  )
)

server <- function(input, output, session) {
  result <- eventReactive(input$screen, {
    req(input$lat, input$lon)
    analyze(input$lat, input$lon)
  }, ignoreNULL = FALSE)

  output$conclusion_ui <- renderUI({
    r <- result()
    tbl <- r$table
    rows <- lapply(seq_len(nrow(tbl)), function(i) {
      row <- tbl[i, ]
      bg <- if (!is.na(row$inside) && row$inside) "background:#ffe5e5; font-weight:bold;" else ""
      inside_str <- if (is.na(row$inside)) "\u2014" else if (row$inside) "Yes" else "No"
      dist_str <- if (is.na(row$nearest_m)) "\u2014"
        else if (row$nearest_m == 0) "0 (within)"
        else format(round(row$nearest_m), big.mark = ",")
      tags$tr(
        tags$td(row$layer),
        tags$td(style = bg, inside_str),
        tags$td(dist_str),
        tags$td(tags$small(row$source)),
        tags$td(tags$small(row$refreshed))
      )
    })
    tags$table(class = "table table-sm",
               tags$thead(tags$tr(tags$th("Layer"), tags$th("Inside?"),
                                  tags$th("Nearest (m)"), tags$th("Source"), tags$th("Refreshed"))),
               tags$tbody(rows))
  })

  output$paragraph <- renderText({ result()$paragraph })

  output$map <- renderLeaflet({
    m <- leaflet() |>
      addProviderTiles(providers$CartoDB.Positron, group = "Roads") |>
      addProviderTiles(providers$Esri.WorldImagery, group = "Satellite") |>
      setView(lng = input$lon, lat = input$lat, zoom = input$zoom) |>
      addScaleBar(position = "bottomleft")

    for (nm in names(polys_4326)) {
      poly <- polys_4326[[nm]]
      if (is.null(poly)) next
      m <- addPolygons(m, data = poly,
                       color = layer_color[[nm]], weight = 1.5, opacity = 0.9,
                       fillColor = layer_color[[nm]], fillOpacity = 0.30,
                       group = layer_display[[nm]], label = layer_display[[nm]])
    }

    m |>
      addAwesomeMarkers(lng = input$lon, lat = input$lat,
                        icon = awesomeIcons(icon = "home", library = "fa",
                                            markerColor = "red", iconColor = "white"),
                        popup = sprintf("<b>%s</b><br/>%.5f, %.5f",
                                        input$address, input$lat, input$lon),
                        label = input$address,
                        labelOptions = labelOptions(permanent = TRUE, direction = "top",
                                                    offset = c(0, -40),
                                                    style = list("font-weight" = "bold"))) |>
      addLayersControl(baseGroups = c("Roads", "Satellite"),
                       overlayGroups = unname(layer_display),
                       options = layersControlOptions(collapsed = FALSE)) |>
      addLegend(position = "bottomright",
                colors = unname(layer_color),
                labels = unname(layer_display),
                opacity = 0.7, title = "Flood layers")
  })

  observeEvent(input$screen, {
    leafletProxy("map") |>
      setView(lng = input$lon, lat = input$lat, zoom = input$zoom) |>
      clearMarkers() |>
      addAwesomeMarkers(lng = input$lon, lat = input$lat,
                        icon = awesomeIcons(icon = "home", library = "fa",
                                            markerColor = "red", iconColor = "white"),
                        popup = sprintf("<b>%s</b><br/>%.5f, %.5f",
                                        input$address, input$lat, input$lon),
                        label = input$address,
                        labelOptions = labelOptions(permanent = TRUE, direction = "top",
                                                    offset = c(0, -40),
                                                    style = list("font-weight" = "bold")))
  })
}

shinyApp(ui, server)
