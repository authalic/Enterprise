"""
Scan an ArcGIS Enterprise Portal and list all Web Maps that consume the UDOT_Regions
sublayers (/MapServer/0 or /MapServer/1) as ArcGISFeatureLayer items instead of the
parent ArcGISMapServiceLayer.

Features:
- Recursively inspects operationalLayers (including nested GroupLayers).
- Reports which sublayers (/0 Office Locations, /1 Regions Boundaries) each Web Map uses,
  along with visibility, opacity, definitionExpression, and custom renderer status.
- Optionally exports the results to a CSV file for easy auditing/filtering.
"""

import csv
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from arcgis.gis import GIS

# ==============================================================================
# CONFIGURATION
# ==============================================================================
PORTAL_URL = "https://central.udot.utah.gov/portal"
USERNAME = None  # Set to your Portal admin username, or leave None to use GIS("pro")
PASSWORD = None  # Set to your password, or leave None to be prompted

# Optional: Filter to a single Web Map ID for testing (e.g., "49a88e0927b8444ba37dd301d30e2844")
# Set to None to scan all Web Maps in the Portal.
TARGET_WEBMAP_ID: Optional[str] = None

# Optional: Set a path to export matching Web Maps to CSV, or None to skip CSV export
CSV_OUTPUT_PATH: Optional[Path] = Path("./udot_regions_sublayer_webmaps.csv")

# Matches .../rest/services/UDOT/UDOT_Regions/MapServer/<sublayer_id>
SUBLAYER_URL_REGEX = re.compile(
    r"https?://[^/]+/[^/]+/rest/services/UDOT/UDOT_Regions/MapServer/(\d+)/?$",
    re.IGNORECASE,
)

# Also check if the Web Map still has the parent MapServer layer alongside sublayers
MAPSERVER_URL_REGEX = re.compile(
    r"https?://[^/]+/[^/]+/rest/services/UDOT/UDOT_Regions/MapServer/?$",
    re.IGNORECASE,
)

SUBLAYER_NAMES = {
    0: "Office Locations (0)",
    1: "Regions Boundaries (1)",
}


def find_sublayers_in_array(
    layers_array: List[Dict[str, Any]],
    group_path: str = "",
) -> List[Dict[str, Any]]:
    """
    Recursively inspect an operationalLayers array (and any nested GroupLayers)
    and return details for every UDOT_Regions sublayer entry found.
    """
    matches: List[Dict[str, Any]] = []

    for layer in layers_array:
        layer_type = layer.get("layerType", "")
        url = (layer.get("url") or "").strip()
        title = layer.get("title") or layer.get("id") or "Untitled Layer"
        current_path = f"{group_path} / {title}" if group_path else title

        m = SUBLAYER_URL_REGEX.match(url)
        if m:
            sublayer_idx = int(m.group(1))
            layer_def = layer.get("layerDefinition") or {}
            drawing_info = layer_def.get("drawingInfo") or {}
            def_expr = layer_def.get("definitionExpression")

            matches.append(
                {
                    "layer_id": layer.get("id", ""),
                    "title": title,
                    "group_path": group_path or "(Top Level)",
                    "layer_type": layer_type,
                    "sublayer_index": sublayer_idx,
                    "sublayer_label": SUBLAYER_NAMES.get(
                        sublayer_idx, f"Sublayer ({sublayer_idx})"
                    ),
                    "url": url,
                    "visibility": layer.get("visibility", True),
                    "opacity": layer.get("opacity", 1.0),
                    "has_custom_renderer": "renderer" in drawing_info,
                    "definition_expression": def_expr or "",
                }
            )

        # Recurse into GroupLayers
        if layer_type == "GroupLayer" and isinstance(layer.get("layers"), list):
            matches.extend(
                find_sublayers_in_array(layer["layers"], group_path=current_path)
            )

    return matches


def has_parent_map_service_layer(layers_array: List[Dict[str, Any]]) -> bool:
    """Return True if the Web Map also contains the parent ArcGISMapServiceLayer."""
    for layer in layers_array:
        url = (layer.get("url") or "").strip()
        if (
            layer.get("layerType") == "ArcGISMapServiceLayer"
            and MAPSERVER_URL_REGEX.match(url)
        ):
            return True
        if layer.get("layerType") == "GroupLayer" and isinstance(
            layer.get("layers"), list
        ):
            if has_parent_map_service_layer(layer["layers"]):
                return True
    return False


def main() -> None:
    print(f"Connecting to Portal: {PORTAL_URL} ...")
    if USERNAME:
        gis = GIS(PORTAL_URL, username=USERNAME, password=PASSWORD)
    else:
        # Uses active ArcGIS Pro sign-in or prompts if needed
        gis = GIS("pro")

    print(f"Connected as: {gis.users.me.username if gis.users.me else 'Anonymous'}\n")

    if TARGET_WEBMAP_ID:
        single_item = gis.content.get(TARGET_WEBMAP_ID)
        webmaps = [single_item] if single_item else []
    else:
        webmaps = gis.content.search(
            query='type:"Web Map"', item_type="Web Map", max_items=10000
        )

    total_maps = len(webmaps)
    print(f"Scanning {total_maps} Web Map(s) for UDOT_Regions sublayers (/0, /1)...\n")

    matched_webmaps_count = 0
    total_sublayer_refs = 0
    csv_rows: List[Dict[str, Any]] = []

    for idx, item in enumerate(webmaps, start=1):
        if idx % 100 == 0:
            print(f"  ... checked {idx}/{total_maps} Web Maps ...")

        try:
            webmap_data = item.get_data()
            if not isinstance(webmap_data, dict):
                continue

            op_layers = webmap_data.get("operationalLayers")
            if not isinstance(op_layers, list):
                continue

            sublayer_matches = find_sublayers_in_array(op_layers)
            if not sublayer_matches:
                continue

            also_has_mapservice = has_parent_map_service_layer(op_layers)
            matched_webmaps_count += 1
            total_sublayer_refs += len(sublayer_matches)

            modified_dt = (
                datetime.fromtimestamp(item.modified / 1000).strftime("%Y-%m-%d")
                if getattr(item, "modified", None)
                else "Unknown"
            )

            print(
                f"[{matched_webmaps_count}] Web Map: '{item.title}' "
                f"(ID: {item.id}, Owner: {item.owner}, Access: {item.access}, Modified: {modified_dt})"
            )
            if also_has_mapservice:
                print(
                    "    [NOTE] This Web Map ALSO contains the parent UDOT_Regions ArcGISMapServiceLayer!"
                )

            for sub in sublayer_matches:
                vis_str = "Visible" if sub["visibility"] else "Hidden"
                rend_str = "Custom Renderer" if sub["has_custom_renderer"] else "Default Renderer"
                filter_str = (
                    f", Filter: \"{sub['definition_expression']}\""
                    if sub["definition_expression"]
                    else ""
                )
                print(
                    f"    -> {sub['sublayer_label']} | Title: '{sub['title']}' | "
                    f"Type: {sub['layer_type']} | {vis_str} (opacity={sub['opacity']}) | "
                    f"{rend_str}{filter_str}"
                )
                print(f"       URL: {sub['url']}")

                csv_rows.append(
                    {
                        "webmap_id": item.id,
                        "webmap_title": item.title,
                        "owner": item.owner,
                        "access": item.access,
                        "modified_date": modified_dt,
                        "sublayer_index": sub["sublayer_index"],
                        "sublayer_label": sub["sublayer_label"],
                        "layer_title": sub["title"],
                        "group_path": sub["group_path"],
                        "layer_type": sub["layer_type"],
                        "visibility": sub["visibility"],
                        "opacity": sub["opacity"],
                        "has_custom_renderer": sub["has_custom_renderer"],
                        "definition_expression": sub["definition_expression"],
                        "also_has_parent_mapservice": also_has_mapservice,
                        "url": sub["url"],
                    }
                )
            print()

        except Exception as exc:
            print(f"[ERROR] Failed inspecting Web Map {item.id} ('{item.title}'): {exc}\n")

    print("=" * 75)
    print(f"Scan complete. Checked {total_maps} Web Map(s).")
    print(
        f"Found {matched_webmaps_count} Web Map(s) with {total_sublayer_refs} "
        f"UDOT_Regions sublayer reference(s) (/MapServer/0 or /MapServer/1)."
    )

    if CSV_OUTPUT_PATH and csv_rows:
        CSV_OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
        with CSV_OUTPUT_PATH.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(csv_rows[0].keys()))
            writer.writeheader()
            writer.writerows(csv_rows)
        print(f"Exported detailed CSV report to: {CSV_OUTPUT_PATH.resolve()}")


if __name__ == "__main__":
    main()
