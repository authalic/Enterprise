"""
Audit and convert UDOT_Regions/MapServer (ArcGISMapServiceLayer) to sublayer
ArcGISFeatureLayers (/MapServer/1 and /MapServer/0) across an ArcGIS Enterprise Portal.

Why:
- ArcGISMapServiceLayer (/MapServer) forces clients to call `/export` (single full-screen PNG),
  which has unique bbox/size parameters on every pan/zoom and cannot be cached.
- ArcGISFeatureLayer (/MapServer/1 and /MapServer/0) causes the ArcGIS Maps SDK for JavaScript
  to request quantized PBF vector tiles (`query?f=pbf&resultType=tile...`) on a fixed tile grid,
  which are cached by the browser (`cacheControlMaxAge = 2592000`).
"""

import copy
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from arcgis.gis import GIS, Item

# ==============================================================================
# CONFIGURATION
# ==============================================================================
PORTAL_URL = "https://central.udot.utah.gov/portal"
USERNAME = None  # Set to your Portal admin username, or leave None to use GIS("pro") / prompt
PASSWORD = None  # Set to your password, or leave None to be prompted

# Safety toggle:
#   True  -> Audit only (prints matching Web Maps and previews changes without saving)
#   False -> Backs up original Web Map JSON to ./webmap_backups/ and applies updates
DRY_RUN = True

# Optional: Filter to a single Web Map ID for testing first (e.g., "d6386ceb77354883a9e6cd8d5e4fe5f8")
# Set to None to scan all Web Maps in the Portal.
TARGET_WEBMAP_ID: Optional[str] = None

# Optional: Wrap the converted sublayers (/1 and /0) in a GroupLayer?
#   False (Recommended) -> Places the FeatureLayers directly in operationalLayers at the same
#                          drawing position (compatible with both 3.x Web AppBuilder & 4.x apps).
#   True                -> Wraps them in a GroupLayer titled after the original MapService layer.
WRAP_IN_GROUP_LAYER = False

# Target service identifiers
TARGET_SERVICE_REGEX = re.compile(
    r"https?://[^/]+/[^/]+/rest/services/UDOT/UDOT_Regions/MapServer/?$",
    re.IGNORECASE,
)
TARGET_ITEM_ID = "9d0de187fe56426d90110a2c94d2db60"
Canonical_SERVICE_URL = (
    "https://central.udot.utah.gov/central/rest/services/UDOT/UDOT_Regions/MapServer"
)

BACKUP_DIR = Path("./webmap_backups")

# Default sublayer metadata (used if a Web Map did not store sublayer overrides)
DEFAULT_SUBLAYERS = {
    0: {"name": "Office Locations"},
    1: {"name": "Regions Boundaries"},
}

# Fields that were removed/hidden from the service schema so we can clean them from old popups
REMOVED_FIELDS = {
    "SE_ANNO_CAD_DATA",
    "LAYER_ID",
    "ID",
    "GEOM_LENGTH",
    "GEOM_AREA",
    "SHAPE_Length",
    "SHAPE_Area",
    "InPoly_FID",
    "MaxSimpTol",
    "MinSimpTol",
}


def clean_removed_fields_from_popup(popup_info: Dict[str, Any]) -> Dict[str, Any]:
    """Remove references to deleted service fields from popupInfo so blank rows don't appear."""
    cleaned = copy.deepcopy(popup_info)
    if isinstance(cleaned.get("fieldInfos"), list):
        cleaned["fieldInfos"] = [
            fi
            for fi in cleaned["fieldInfos"]
            if fi.get("fieldName") not in REMOVED_FIELDS
        ]
    if isinstance(cleaned.get("popupElements"), list):
        for elem in cleaned["popupElements"]:
            if isinstance(elem, dict) and isinstance(elem.get("fieldInfos"), list):
                elem["fieldInfos"] = [
                    fi
                    for fi in elem["fieldInfos"]
                    if fi.get("fieldName") not in REMOVED_FIELDS
                ]
    return cleaned


def is_target_map_service_layer(layer: Dict[str, Any]) -> bool:
    """Return True if the layer is UDOT_Regions configured as an ArcGISMapServiceLayer."""
    if layer.get("layerType") != "ArcGISMapServiceLayer":
        return False
    url = (layer.get("url") or "").strip()
    item_id = (layer.get("itemId") or "").strip()
    return bool(TARGET_SERVICE_REGEX.match(url)) or item_id == TARGET_ITEM_ID


def build_feature_sublayer(
    parent_layer: Dict[str, Any],
    sublayer_id: int,
    sublayer_override: Optional[Dict[str, Any]],
    default_popup_by_id: Dict[int, Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Convert a single sublayer (0 or 1) of an ArcGISMapServiceLayer into a standalone
    ArcGISFeatureLayer JSON definition that preserves visibility, opacity, renderer,
    labels, definitionExpression, scale ranges, and popups.
    """
    base_url = (parent_layer.get("url") or Canonical_SERVICE_URL).rstrip("/")
    parent_id = parent_layer.get("id", "UDOT_Regions")
    parent_title = parent_layer.get("title", "UDOT Regions")
    parent_vis = parent_layer.get("visibility", True)
    parent_opacity = float(parent_layer.get("opacity", 1.0))

    sub_name = (
        (sublayer_override or {}).get("name")
        or DEFAULT_SUBLAYERS.get(sublayer_id, {}).get("name")
        or f"Layer {sublayer_id}"
    )

    # Determine effective visibility for this sublayer
    visible_layers = parent_layer.get("visibleLayers")
    if isinstance(visible_layers, list):
        sub_vis = sublayer_id in visible_layers
    elif sublayer_override and "defaultVisibility" in sublayer_override:
        sub_vis = bool(sublayer_override["defaultVisibility"])
    else:
        sub_vis = True

    effective_visibility = bool(parent_vis and sub_vis)

    # Extract layerDefinition and calculate effective opacity from drawingInfo.transparency
    layer_def = copy.deepcopy((sublayer_override or {}).get("layerDefinition") or {})
    # Remove MapServer dynamicLayer 'source' property so JS SDK treats it as a pure FeatureLayer
    layer_def.pop("source", None)

    sub_transparency = 0
    drawing_info = layer_def.get("drawingInfo")
    if isinstance(drawing_info, dict) and "transparency" in drawing_info:
        try:
            sub_transparency = float(drawing_info.get("transparency") or 0)
        except (TypeError, ValueError):
            sub_transparency = 0
        # Convert sublayer transparency (0-100) to top-level FeatureLayer opacity (0.0-1.0)
        drawing_info["transparency"] = 0

    effective_opacity = round(parent_opacity * (1.0 - (sub_transparency / 100.0)), 2)

    # Title: keep clean and identifiable in Layer List
    if sublayer_id == 1 and parent_title:
        title = f"{parent_title} - {sub_name}" if not WRAP_IN_GROUP_LAYER else sub_name
    else:
        title = f"{parent_title} - {sub_name}" if not WRAP_IN_GROUP_LAYER else sub_name

    feature_layer: Dict[str, Any] = {
        "id": f"{parent_id}-sublayer-{sublayer_id}",
        "layerType": "ArcGISFeatureLayer",
        "url": f"{base_url}/{sublayer_id}",
        "title": title,
        "visibility": effective_visibility,
        "opacity": effective_opacity,
    }

    # Preserve scale ranges, legend, popup flags, and Map Viewer 4.x effects/settings
    for prop in (
        "minScale",
        "maxScale",
        "showLegend",
        "disablePopup",
        "blendMode",
        "effect",
        "featureEffect",
        "refreshInterval",
        "listMode",
        "displayFilterInfo",
        "attributeTableInfo",
    ):
        if sublayer_override and prop in sublayer_override:
            feature_layer[prop] = copy.deepcopy(sublayer_override[prop])
        elif prop in parent_layer:
            feature_layer[prop] = copy.deepcopy(parent_layer[prop])

    # Clean removed fields from layerDefinition.fieldConfigurations if present
    if isinstance(layer_def.get("fieldConfigurations"), list):
        layer_def["fieldConfigurations"] = [
            fc
            for fc in layer_def["fieldConfigurations"]
            if fc.get("name") not in REMOVED_FIELDS
        ]

    if layer_def:
        feature_layer["layerDefinition"] = layer_def

    # Preserve popupInfo (or fall back to the Portal Item's default popupInfo),
    # stripping out any fields that were removed from the service schema
    if sublayer_override and "popupInfo" in sublayer_override:
        feature_layer["popupInfo"] = clean_removed_fields_from_popup(
            sublayer_override["popupInfo"]
        )
    elif sublayer_id in default_popup_by_id:
        feature_layer["popupInfo"] = clean_removed_fields_from_popup(
            default_popup_by_id[sublayer_id]
        )

    return feature_layer


def convert_map_service_layer_entry(
    parent_layer: Dict[str, Any],
    default_popup_by_id: Dict[int, Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """
    Replace an ArcGISMapServiceLayer entry with ArcGISFeatureLayer entries for sublayers 1 and 0.
    Note on drawing order in Web Map operationalLayers:
      - Lower index draws first (bottom); higher index draws last (top).
      - Sublayer 1 (Regions Boundaries polygons) goes first (bottom).
      - Sublayer 0 (Office Locations points) goes second (top).
    """
    sublayers_list = parent_layer.get("layers") or []
    overrides_by_id: Dict[int, Dict[str, Any]] = {}
    for sub in sublayers_list:
        if isinstance(sub, dict) and "id" in sub:
            overrides_by_id[int(sub["id"])] = sub

    # Build Polygon layer (1) first (bottom), then Point layer (0) second (top)
    fl_polygons = build_feature_sublayer(
        parent_layer, 1, overrides_by_id.get(1), default_popup_by_id
    )
    fl_points = build_feature_sublayer(
        parent_layer, 0, overrides_by_id.get(0), default_popup_by_id
    )
    converted_layers = [fl_polygons, fl_points]

    if WRAP_IN_GROUP_LAYER:
        return [
            {
                "id": parent_layer.get("id", "UDOT_Regions_Group"),
                "layerType": "GroupLayer",
                "title": parent_layer.get("title", "UDOT Regions"),
                "visibility": parent_layer.get("visibility", True),
                "opacity": parent_layer.get("opacity", 1.0),
                "layers": converted_layers,
            }
        ]

    return converted_layers


def process_layer_array(
    layers_array: List[Dict[str, Any]],
    default_popup_by_id: Dict[int, Dict[str, Any]],
) -> Tuple[List[Dict[str, Any]], int]:
    """
    Recursively scan an operationalLayers (or GroupLayer.layers) list and replace any
    UDOT_Regions ArcGISMapServiceLayer entries in-place.
    """
    new_array: List[Dict[str, Any]] = []
    converted_count = 0

    for layer in layers_array:
        if is_target_map_service_layer(layer):
            replacement_layers = convert_map_service_layer_entry(
                layer, default_popup_by_id
            )
            new_array.extend(replacement_layers)
            converted_count += 1
        else:
            # If this is a GroupLayer, recursively inspect its child layers
            if layer.get("layerType") == "GroupLayer" and isinstance(
                layer.get("layers"), list
            ):
                updated_children, child_count = process_layer_array(
                    layer["layers"], default_popup_by_id
                )
                if child_count > 0:
                    layer = copy.deepcopy(layer)
                    layer["layers"] = updated_children
                    converted_count += child_count
            new_array.append(layer)

    return new_array, converted_count


def load_default_popups(gis: GIS) -> Dict[int, Dict[str, Any]]:
    """Fetch default popupInfo from the UDOT_Regions Portal Item if available."""
    popups: Dict[int, Dict[str, Any]] = {}
    try:
        service_item = gis.content.get(TARGET_ITEM_ID)
        if service_item:
            item_data = service_item.get_data() or {}
            for lyr in item_data.get("layers", []):
                if "id" in lyr and "popupInfo" in lyr:
                    popups[int(lyr["id"])] = lyr["popupInfo"]
    except Exception as exc:
        print(f"[Note] Could not load default popups from item {TARGET_ITEM_ID}: {exc}")
    return popups


def backup_webmap_json(item: Item, webmap_data: Dict[str, Any]) -> Path:
    """Save a timestamped backup of the original Web Map JSON before updating."""
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = BACKUP_DIR / f"{item.id}_{timestamp}.json"
    backup_path.write_text(json.dumps(webmap_data, indent=2), encoding="utf-8")
    return backup_path


def main() -> None:
    print(f"Connecting to Portal: {PORTAL_URL} ...")
    if USERNAME:
        gis = GIS(PORTAL_URL, username=USERNAME, password=PASSWORD)
    else:
        # Uses active ArcGIS Pro sign-in or prompts if needed
        gis = GIS("pro")

    print(f"Connected as: {gis.users.me.username if gis.users.me else 'Anonymous'}")
    print(f"Mode: {'DRY RUN (no changes will be saved)' if DRY_RUN else 'LIVE UPDATE'}\n")

    default_popups = load_default_popups(gis)

    if TARGET_WEBMAP_ID:
        single_item = gis.content.get(TARGET_WEBMAP_ID)
        webmaps = [single_item] if single_item else []
    else:
        # Search ALL Web Maps in the Portal (Portal search only indexes item metadata,
        # not the internal operationalLayers JSON, so we inspect every Web Map's JSON).
        webmaps = gis.content.search(
            query='type:"Web Map"', item_type="Web Map", max_items=10000
        )

    total_maps = len(webmaps)
    print(f"Scanning {total_maps} Web Map(s)...\n")

    matched_maps = 0
    updated_maps = 0

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

            updated_layers, count = process_layer_array(op_layers, default_popups)
            if count == 0:
                continue

            matched_maps += 1
            print(f"[MATCH] Web Map: '{item.title}' (ID: {item.id}, Owner: {item.owner})")
            print(f"        Found {count} UDOT_Regions ArcGISMapServiceLayer entry/entries.")

            if DRY_RUN:
                print("        [DRY RUN] Would convert to ArcGISFeatureLayer (/1 and /0).\n")
                continue

            # Save local backup before modifying
            backup_file = backup_webmap_json(item, webmap_data)
            print(f"        Backed up original JSON to: {backup_file}")

            # Apply update in-place
            webmap_data["operationalLayers"] = updated_layers
            success = item.update(data=json.dumps(webmap_data))
            if success:
                updated_maps += 1
                print("        [SUCCESS] Updated Web Map JSON in-place.\n")
            else:
                print("        [WARNING] item.update() returned False.\n")

        except Exception as exc:
            print(f"[ERROR] Failed processing Web Map {item.id} ('{item.title}'): {exc}\n")

    print("=" * 70)
    print(f"Scan complete. Matched Web Maps: {matched_maps}")
    if DRY_RUN:
        print("DRY_RUN is True. Set DRY_RUN = False to apply updates.")
    else:
        print(f"Successfully updated Web Maps: {updated_maps}/{matched_maps}")


if __name__ == "__main__":
    main()
