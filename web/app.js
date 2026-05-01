// --- Geocoding config ---
// Get a free Mapbox token at https://account.mapbox.com/access-tokens/
// In the Mapbox dashboard, restrict the token to your Vercel domain
// (URL restrictions) so it can't be abused if copied.
// Leave blank to use OpenStreetMap Nominatim only (weaker rural Canadian coverage).
const MAPBOX_TOKEN = "pk.eyJ1IjoianNjaGVsbGVuYmVyZyIsImEiOiJjbW9tNnUwZXAwc3JkMnNvbnN6cGJoNGExIn0.fT1ttIu31hjx5PHQnFA3gQ";

const LAYER_COLORS = {
  red_river_flood_1997:         "#d62728",
  red_river_flood_2009:         "#ff7f0e",
  red_river_flood_2011:         "#1f77b4",
  mb_1in200_flood_extent:       "#9467bd",
  dfa_all:                      "#2ca02c",
  dfa_lower_red_river:          "#17becf",
  rrv_special_management_area:  "#8a6d3b",
  wpg_waterway_river_corridor:  "#1e88e5",
  wpg_waterway_creek_corridor:  "#5ebadf",
  nrcan_flood_studies:          "#6c757d",
};

const LAYER_NOTES = {
  red_river_flood_1997:         "Observed overland flood boundary",
  red_river_flood_2009:         "Observed overland flood boundary",
  red_river_flood_2011:         "Observed overland flood boundary",
  mb_1in200_flood_extent:       "Statistical 0.5% annual-exceedance-probability extent",
  dfa_all:                      "Statutory DFA \u2014 permit may be required (WRA Act s.17)",
  dfa_lower_red_river:          "Statutory DFA \u2014 permit may be required (WRA Act s.17)",
  rrv_special_management_area:  "Provincial planning overlay (Red River Valley SMA)",
  wpg_waterway_river_corridor:  "City Waterway Permit may be required (By-law 5888/92, 107 m buffer)",
  wpg_waterway_creek_corridor:  "City Waterway Permit may be required (By-law 5888/92, 76 m buffer)",
  nrcan_flood_studies:          "Study-coverage index only (not a flood-extent boundary)",
};

// Info-only layers are shown in the table & map but do NOT count toward the
// "inside a mapped flood extent" determination.
const INFO_ONLY_LAYERS = new Set(["nrcan_flood_studies"]);

// Secondary layers contribute an additional sentence but are NOT the subject of
// the opening "located within..." sentence if they are the only hit.
const SECONDARY_LAYERS = new Set(["rrv_special_management_area"]);

// Layers that are registered in the layer-control but unchecked on load.
const HIDDEN_BY_DEFAULT = new Set(["rrv_special_management_area"]);

const PROXIMITY_THRESHOLD_M = 500;

const state = {
  layers: [],          // metadata from layers.json
  polygons: {},        // name -> GeoJSON FeatureCollection
  leafletLayers: {},   // name -> L.geoJSON layer
  winnipegBoundary: null, // loaded separately, used for DFFA footnote only
  map: null,
  subjectMarker: null,
};

function fmtDistance(m) {
  if (m <= 1000) return Math.round(m).toLocaleString() + " metres";
  if (m < 3000)  return (m / 1000).toFixed(2) + " kilometres";
  return Math.round(m / 1000).toLocaleString() + " kilometres";
}

function fmtDateLong(iso) {
  const d = new Date(iso + "T00:00:00Z");
  return d.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" });
}

async function loadData() {
  const res = await fetch("data/layers.json");
  state.layers = await res.json();
  await Promise.all(state.layers.map(async (L) => {
    const r = await fetch("data/" + L.file);
    state.polygons[L.name] = await r.json();
  }));
  try {
    const r = await fetch("data/winnipeg_boundary.geojson");
    if (r.ok) state.winnipegBoundary = await r.json();
  } catch (e) { /* boundary optional — DFFA footnote just won't fire */ }
}

function analyzeSubject(lat, lon) {
  const pt = turf.point([lon, lat]);
  const rows = state.layers.map((L) => {
    const fc = state.polygons[L.name];
    if (!fc || !fc.features || fc.features.length === 0) {
      return { layer: L.label, inside: null, nearest_m: null, source: L.source, refreshed: L.refreshed, note: "Data unavailable", layer_key: L.name };
    }
    let inside = false;
    let hitFeature = null;
    let nearestM = Infinity;
    outer: for (const feat of fc.features) {
      if (turf.booleanPointInPolygon(pt, feat)) { inside = true; hitFeature = feat; nearestM = 0; break outer; }
      const lineFc = turf.polygonToLine(feat);
      const lineFeatures = lineFc.type === "FeatureCollection" ? lineFc.features : [lineFc];
      for (const lf of lineFeatures) {
        if (lf.geometry.type === "MultiLineString") {
          for (const coords of lf.geometry.coordinates) {
            const ls = turf.lineString(coords);
            const dM = turf.pointToLineDistance(pt, ls, { units: "kilometers" }) * 1000;
            if (dM < nearestM) nearestM = dM;
          }
        } else {
          const dM = turf.pointToLineDistance(pt, lf, { units: "kilometers" }) * 1000;
          if (dM < nearestM) nearestM = dM;
        }
      }
    }
    return {
      layer: L.label,
      inside,
      nearest_m: inside ? 0 : nearestM,
      source: L.source,
      refreshed: L.refreshed,
      note: LAYER_NOTES[L.name] || "",
      layer_key: L.name,
      hit_props: hitFeature ? hitFeature.properties : null,
    };
  });

  // Split extent vs. info-only rows for the inside/outside determination
  const extentRows = rows.filter((r) => !INFO_ONLY_LAYERS.has(r.layer_key));
  const infoRows   = rows.filter((r) =>  INFO_ONLY_LAYERS.has(r.layer_key));

  const primaryInsideRows = extentRows.filter((r) => r.inside === true && !SECONDARY_LAYERS.has(r.layer_key));
  const secondaryInsideRows = extentRows.filter((r) => r.inside === true && SECONDARY_LAYERS.has(r.layer_key));
  const anyPrimaryInside = primaryInsideRows.length > 0;
  const layersInside = primaryInsideRows.map((r) => r.layer);
  const anyInside = anyPrimaryInside; // retained for backwards-compat in the return
  const inDFA = primaryInsideRows.some((r) => r.layer_key === "dfa_all" || r.layer_key === "dfa_lower_red_river");
  const inWpgRiverCorr = primaryInsideRows.some((r) => r.layer_key === "wpg_waterway_river_corridor");
  const inWpgCreekCorr = primaryInsideRows.some((r) => r.layer_key === "wpg_waterway_creek_corridor");
  const validOutside = extentRows.filter((r) => r.inside === false && isFinite(r.nearest_m));
  const nearestOverall = validOutside.length > 0 ? validOutside.reduce((a, b) => a.nearest_m < b.nearest_m ? a : b) : null;
  const cfmHits = infoRows.filter((r) => r.inside === true);

  let inWinnipeg = false;
  if (state.winnipegBoundary && state.winnipegBoundary.features) {
    inWinnipeg = state.winnipegBoundary.features.some((f) => turf.booleanPointInPolygon(pt, f));
  }

  const refreshedDate = rows.map((r) => r.refreshed).filter(Boolean).sort().slice(-1)[0];
  const refreshedLong = refreshedDate ? fmtDateLong(refreshedDate) : "(unknown)";
  const caveat = `This map is based on publicly available provincial (Manitoba Government, Manitoba Land Initiative) and federal (Natural Resources Canada) flood mapping as of ${refreshedLong} and is intended for appraisal context only; it is not a legal survey, engineering flood study, insurance determination, or site-specific flood protection level assessment.`;

  let paragraph;
  if (anyPrimaryInside) {
    const dfaSentence = inDFA ? " A Designated Flood Area permit may be required for new permanent structures under Section 17 of The Water Resources Administration Act." : "";
    paragraph = `The subject property is located within one or more mapped flood-risk or regulatory overlays reviewed for this appraisal, specifically: ${layersInside.join("; ")}.${dfaSentence} ${caveat}`;
  } else if (nearestOverall && nearestOverall.nearest_m < PROXIMITY_THRESHOLD_M) {
    paragraph = `The subject property is not located within any of the mapped flood-risk or regulatory overlays reviewed for this appraisal, but it is in close proximity: the nearest mapped extent (${nearestOverall.layer}) is approximately ${fmtDistance(nearestOverall.nearest_m)} from the subject. ${caveat}`;
  } else if (nearestOverall) {
    paragraph = `The subject property is not located within any of the mapped flood-risk or regulatory overlays reviewed for this appraisal. The nearest mapped extent (${nearestOverall.layer}) is approximately ${fmtDistance(nearestOverall.nearest_m)} from the subject. ${caveat}`;
  } else {
    paragraph = "The subject property could not be evaluated because no flood layers were loaded. " + caveat;
  }

  if (secondaryInsideRows.length > 0) {
    const secList = secondaryInsideRows.map((r) => r.layer).join(", ");
    paragraph += ` The subject also falls within the ${secList}, a provincial planning overlay under Manitoba's Planning Act governing development coordination in the Red River Valley; specific implications should be confirmed with the applicable planning district.`;
  }

  if (inWpgRiverCorr || inWpgCreekCorr) {
    const which = (inWpgRiverCorr && inWpgCreekCorr)
      ? "the City of Winnipeg's Waterway regulated area along both a river and a creek"
      : inWpgRiverCorr
        ? "the City of Winnipeg's Waterway regulated area along one of the named rivers (107 m from the Red, Assiniboine, Seine, or La Salle River)"
        : "the City of Winnipeg's Waterway regulated area along one of the named creeks (76 m from Bunn's, Omand's, Truro, or Sturgeon Creek)";
    paragraph += ` The subject falls within ${which}; a Waterway Permit under the City of Winnipeg Waterway By-law 5888/92 may be required for building, riverbank stabilization, fill, grading, decks, pools, or docks.`;
  }

  if (inWinnipeg) {
    paragraph += ` Winnipeg properties located outside the City's primary dike system are subject to the Designated Floodway Fringe Area Regulation (Manitoba Regulation 266/91), which requires new structures to be floodproofed to the applicable Flood Protection Level (raised grade, elevated main floor, no openings below the FPL, and backwater valves). Applicability and the site-specific FPL should be confirmed with the City of Winnipeg Planning, Property and Development department.`;
  }

  if (cfmHits.length > 0 && cfmHits[0].hit_props) {
    const p = cfmHits[0].hit_props;
    const bits = [p.study_name].filter(Boolean);
    if (p.study_date) bits.push(p.study_date);
    if (p.data_owner_en) bits.push(p.data_owner_en);
    const status = p.availability_status_en_1 || p.study_status_en || "";
    paragraph += ` The area is listed in Natural Resources Canada's Canada Flood Map Inventory under the study \u201C${bits.join(", ")}\u201D${status ? " (" + status.trim() + ")" : ""}; this is a coverage index and does not itself define a flood extent, but indicates that a hydrodynamic or flood-hazard study has been completed or is in progress for the area, and that more detailed mapping may become publicly available.`;
  }

  return { rows, anyInside, paragraph };
}

function renderTable(rows) {
  const container = document.getElementById("result-table-wrap");
  container.innerHTML = "";
  const half = Math.ceil(rows.length / 2);
  const groups = [rows.slice(0, half), rows.slice(half)];
  for (const group of groups) {
    const table = document.createElement("table");
    table.className = "compact-table";
    table.innerHTML = "<thead><tr><th>Layer</th><th>Inside?</th><th>Nearest</th></tr></thead><tbody></tbody>";
    const tbody = table.querySelector("tbody");
    for (const r of group) {
      const tr = document.createElement("tr");
      if (r.inside === true) tr.classList.add("inside");
      const nearestStr = r.nearest_m == null ? "\u2014"
        : r.nearest_m === 0 ? "0 (within)"
        : Math.round(r.nearest_m).toLocaleString() + " m";
      const insideStr = r.inside == null ? "\u2014" : (r.inside ? "Yes" : "No");
      const meta = [r.source, r.refreshed].filter(Boolean).join(" \u00b7 ");
      tr.innerHTML = `
        <td>
          <div class="layer-name">${r.layer}</div>
          ${meta ? `<small class="layer-meta">${meta}</small>` : ""}
        </td>
        <td class="inside-cell">${insideStr}</td>
        <td class="nearest-cell">${nearestStr}</td>`;
      tbody.appendChild(tr);
    }
    container.appendChild(table);
  }
}

function initMap() {
  const tileOpts = { crossOrigin: "anonymous" };
  const roads = L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", { ...tileOpts, attribution: "© OpenStreetMap contributors © CARTO", maxZoom: 19 });
  const sat   = L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", { ...tileOpts, attribution: "Tiles © Esri" });

  state.map = L.map("map", { layers: [roads], preferCanvas: false }).setView([49.8872, -97.1308], 12);
  L.control.scale({ position: "bottomleft", imperial: false }).addTo(state.map);

  const overlays = {};
  for (const L2 of state.layers) {
    const color = LAYER_COLORS[L2.name] || "#666";
    const isInfo = INFO_ONLY_LAYERS.has(L2.name);
    const style = isInfo
      ? { color, weight: 2, opacity: 0.85, dashArray: "6 4", fillOpacity: 0 }
      : { color, weight: 1.5, opacity: 0.9, fillColor: color, fillOpacity: 0.30 };
    const lyr = L.geoJSON(state.polygons[L2.name], {
      style,
      onEachFeature: (feat, layer) => {
        let tip = L2.label;
        if (isInfo && feat.properties) {
          const p = feat.properties;
          const extras = [p.study_name, p.study_date, p.data_owner_en].filter(Boolean).join(" \u2014 ");
          if (extras) tip = `${L2.label}<br><small>${extras}</small>`;
        }
        layer.bindTooltip(tip, { sticky: true, direction: "top" });
      }
    });
    state.leafletLayers[L2.name] = lyr;
    if (!HIDDEN_BY_DEFAULT.has(L2.name)) lyr.addTo(state.map);
    overlays[L2.label] = lyr;
  }

  state.screenshoter = L.simpleMapScreenshoter({
    hidden: true,
    preventDownload: true,
    mimeType: "image/png",
    hideElementsWithSelectors: [".leaflet-control-zoom", ".leaflet-control-layers", ".leaflet-control-attribution"],
  }).addTo(state.map);

  L.control.layers({ "Roads": roads, "Satellite": sat }, overlays, { collapsed: true }).addTo(state.map);

  // Legend
  const legend = L.control({ position: "bottomright" });
  legend.onAdd = function () {
    const div = L.DomUtil.create("div", "legend");
    div.style.background = "white";
    div.style.padding = "6px 10px";
    div.style.fontSize = "12px";
    div.style.border = "1px solid #ccc";
    div.style.borderRadius = "4px";
    div.innerHTML = "<b>Flood layers</b><br>" + state.layers.map((L2) => {
      const c = LAYER_COLORS[L2.name] || "#666";
      const isInfo = INFO_ONLY_LAYERS.has(L2.name);
      const swatch = isInfo
        ? `<span style="display:inline-block;width:12px;height:12px;border:2px dashed ${c};box-sizing:border-box;margin-right:6px;vertical-align:middle;"></span>`
        : `<span style="display:inline-block;width:12px;height:12px;background:${c};margin-right:6px;vertical-align:middle;"></span>`;
      return swatch + L2.label;
    }).join("<br>");
    return div;
  };
  legend.addTo(state.map);
}

const PIN_SVG = `
<svg xmlns="http://www.w3.org/2000/svg" width="28" height="40" viewBox="0 0 28 40">
  <path d="M14 0 C6.3 0 0 6.3 0 14 C0 24 14 40 14 40 C14 40 28 24 28 14 C28 6.3 21.7 0 14 0 Z"
        fill="#d9281a" stroke="white" stroke-width="1.5"/>
  <path d="M9 14 L9 20 L12 20 L12 16 L16 16 L16 20 L19 20 L19 14 L14 9 Z"
        fill="white"/>
</svg>`;

const subjectIcon = L.divIcon({
  html: PIN_SVG,
  className: "subject-pin",
  iconSize: [28, 40],
  iconAnchor: [14, 40],
  popupAnchor: [0, -38],
  tooltipAnchor: [0, -40],
});

function setSubjectMarker(lat, lon, address) {
  if (state.subjectMarker) state.map.removeLayer(state.subjectMarker);
  state.subjectMarker = L.marker([lat, lon], { icon: subjectIcon, zIndexOffset: 1000 })
    .bindPopup(`<b>${address}</b><br/>${lat.toFixed(5)}, ${lon.toFixed(5)}`)
    .bindTooltip(address, { permanent: true, direction: "top", offset: [0, -40], className: "subject-tip" })
    .addTo(state.map);
}

async function run() {
  const paragraphEl = document.getElementById("paragraph");
  paragraphEl.classList.add("empty");
  paragraphEl.textContent = "Loading flood layers…";

  try {
    await loadData();
    initMap();

    const statusEl = document.getElementById("status");
    const setStatus = (msg, isError = false) => {
      statusEl.textContent = msg;
      statusEl.className = "tip" + (isError ? " status err" : "");
    };

    const COORD_RE = /^\s*(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)\s*$/;

    async function geocodeMapbox(raw) {
      if (!MAPBOX_TOKEN) return null;
      // Bias results toward Manitoba (lon,lat of Winnipeg) to tiebreak common street names.
      const url = `https://api.mapbox.com/search/geocode/v6/forward?q=${encodeURIComponent(raw)}`
        + `&country=ca&limit=1&proximity=-97.1384,49.8951&access_token=${MAPBOX_TOKEN}`;
      const resp = await fetch(url);
      if (!resp.ok) return null;
      const data = await resp.json();
      const f = data.features && data.features[0];
      if (!f) return null;
      const [lon, lat] = f.geometry.coordinates;
      const display = (f.properties && (f.properties.full_address || f.properties.place_formatted || f.properties.name))
        || f.place_name || raw;
      return { lat, lon, resolvedAs: "address", display, provider: "mapbox" };
    }

    async function geocodeNominatim(raw) {
      const url = `https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=ca&q=${encodeURIComponent(raw)}`;
      const resp = await fetch(url, { headers: { "Accept-Language": "en" } });
      if (!resp.ok) throw new Error("Geocoder error: HTTP " + resp.status);
      const data = await resp.json();
      if (!data.length) return null;
      return {
        lat: parseFloat(data[0].lat),
        lon: parseFloat(data[0].lon),
        resolvedAs: "address",
        display: data[0].display_name,
        provider: "nominatim",
      };
    }

    async function resolveLocation(raw) {
      const m = raw.match(COORD_RE);
      if (m) {
        const lat = parseFloat(m[1]);
        const lon = parseFloat(m[2]);
        return { lat, lon, resolvedAs: "coords", display: `${lat.toFixed(5)}, ${lon.toFixed(5)}` };
      }
      setStatus("Geocoding address\u2026");
      const mb = await geocodeMapbox(raw);
      if (mb) return mb;
      const nm = await geocodeNominatim(raw);
      if (nm) return nm;
      throw new Error("Address not found \u2014 try including city + province, or paste coordinates");
    }

    const DEFAULT_ZOOM = 12;

    const staticImg = document.getElementById("static-img");
    const staticStatus = document.getElementById("static-status");
    const setStaticStatus = (msg, isError = false) => {
      staticStatus.textContent = msg;
      staticStatus.className = "tip" + (isError ? " status err" : "");
    };

    const slugify = (s) => (s || "subject").trim().replace(/[^A-Za-z0-9]+/g, "_").replace(/_+/g, "_").replace(/^_|_$/g, "");

    const waitForTiles = () => new Promise((resolve) => {
      // Wait for any pending tile requests on the currently-visible base layer
      let pending = 0;
      state.map.eachLayer((lyr) => {
        if (lyr instanceof L.TileLayer && state.map.hasLayer(lyr)) {
          const container = lyr.getContainer();
          if (!container) return;
          container.querySelectorAll("img.leaflet-tile").forEach((img) => {
            if (!img.complete) {
              pending++;
              const done = () => { pending--; if (pending === 0) resolve(); };
              img.addEventListener("load", done, { once: true });
              img.addEventListener("error", done, { once: true });
            }
          });
        }
      });
      if (pending === 0) resolve();
    });

    const generateStatic = async (labelForFile) => {
      if (!state.screenshoter) return;
      setStaticStatus("Generating static image\u2026");
      try {
        await waitForTiles();
        await new Promise((r) => setTimeout(r, 400)); // buffer for SVG overlays + marker
        const dataUrl = await state.screenshoter.takeScreen("image");
        staticImg.src = dataUrl;
        staticImg.setAttribute("download", `flood_exhibit_${slugify(labelForFile)}.png`);
        setStaticStatus("Right-click \u2192 Save Image As\u2026 to export. Click \u201CGenerate Static Map\u201D again if you change the map view.");
      } catch (err) {
        setStaticStatus("Static image failed: " + err.message + " (basemap tiles may be blocking CORS export).", true);
      }
    };

    document.getElementById("refresh-png").addEventListener("click", () => {
      const userLabel = document.getElementById("label").value.trim() || "subject";
      generateStatic(userLabel);
    });

    const screen = async () => {
      const raw = document.getElementById("location").value.trim();
      const userLabel = document.getElementById("label").value.trim();
      if (!raw) { setStatus("Enter an address or coordinates", true); return; }

      try {
        const { lat, lon, resolvedAs, display } = await resolveLocation(raw);
        const address = userLabel || (resolvedAs === "address" ? display : display);
        setStatus(resolvedAs === "address"
          ? `Geocoded to ${display} (${lat.toFixed(5)}, ${lon.toFixed(5)})`
          : `Using coordinates ${lat.toFixed(5)}, ${lon.toFixed(5)}`);
        const { rows, paragraph } = analyzeSubject(lat, lon);
        renderTable(rows);
        paragraphEl.classList.remove("empty");
        paragraphEl.textContent = paragraph;
        setSubjectMarker(lat, lon, address);
        state.map.setView([lat, lon], DEFAULT_ZOOM);
      } catch (err) {
        setStatus(err.message, true);
      }
    };

    document.getElementById("screen").addEventListener("click", screen);
    document.getElementById("location").addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); screen(); }
    });

    // Deep-link support: ?lat=&lon=, ?address=, ?q= (alias), ?label=
    const params = new URLSearchParams(window.location.search);
    const qLat = params.get("lat");
    const qLon = params.get("lon");
    const qAddress = params.get("address") || params.get("q");
    const qLabel = params.get("label");
    if (qLat && qLon) {
      document.getElementById("location").value = `${qLat}, ${qLon}`;
    } else if (qAddress) {
      document.getElementById("location").value = qAddress;
    }
    if (qLabel) {
      document.getElementById("label").value = qLabel;
    }

    screen(); // run once on load
  } catch (err) {
    paragraphEl.className = "paragraph";
    paragraphEl.innerHTML = `<span class="status err">Load failed: ${err.message}</span>`;
  }
}

run();
