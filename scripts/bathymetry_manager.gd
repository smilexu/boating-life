class_name BathymetryManager
extends Node

## Reads the compact, offline EMODnet grid. Invalid/land cells are never
## converted to zero or treated as navigable water.

@export var georeference: GeoReference
@export var water_material: ShaderMaterial
@export var enable_depth_color := true
@export_enum("D - Full", "A - Flat Base", "B - Waves No Color Texture No Depth", "C - Waves Plus Depth No Color Texture", "Normal", "Fresnel", "Depth Validity", "Diffuse Shadows Only", "Specular Reflection Only", "Diffuse Flat Normal", "Specular Flat Normal", "Full Flat Normal") var water_diagnostic_mode := 0
@export_file("*.json") var grid_metadata_path := "res://assets/geodata/processed/bathymetry/grid_metadata.json"
@export_file("*.rg8") var depth_texture_path := "res://assets/geodata/processed/bathymetry/depth_texture.rg8"
@export_file("*.json") var manifest_path := "res://assets/geodata/processed/bathymetry/manifest.json"
@export_file("*.json") var features_path := "res://assets/geodata/processed/bathymetry/chart_features.json"
@export_file("*.png") var land_mask_path := "res://assets/geodata/processed/bathymetry/land_mask.png"

const INVALID_DEPTH_DM := -32768
const SOURCE_NAME := "EMODnet DTM 2024 · LAT"
const WATER_DIAGNOSTIC_NAMES := [
	"D - Full",
	"A - Flat Base",
	"B - Waves No Color Texture No Depth",
	"C - Waves Plus Depth No Color Texture",
	"Wave Normal",
	"Fresnel",
	"Depth Validity",
	"Diffuse Shadows Only",
	"Specular Reflection Only",
	"Diffuse Flat Normal",
	"Specular Flat Normal",
	"Full Flat Normal",
]

var data_available := false
var source_description := SOURCE_NAME
var coastlines: Array[PackedVector2Array] = []
var coastline_bounds: Array[Rect2] = []
var contours_by_depth: Dictionary = {}
var contour_bounds_by_depth: Dictionary = {}

var _grid_data := PackedByteArray()
var _depth_texture: ImageTexture
var _depth_texture_bounds := Vector4.ZERO
var _land_mask: Image
var _land_mask_meta: Dictionary = {}
var _rows := 0
var _columns := 0
var _south_latitude := 0.0
var _west_longitude := 0.0
var _latitude_step := 0.0
var _longitude_step := 0.0


func _ready() -> void:
	_load_features()
	_load_land_mask()
	_load_grid()
	_apply_depth_color_state()
	_apply_water_diagnostic_mode()


func set_depth_color_enabled(enabled: bool) -> void:
	enable_depth_color = enabled
	_apply_depth_color_state()
	print("Bathymetry sea tint: %s" % ("ON" if enabled else "OFF"))


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_B:
		set_depth_color_enabled(not enable_depth_color)
	elif event.physical_keycode == KEY_F10:
		water_diagnostic_mode = (water_diagnostic_mode + 1) % WATER_DIAGNOSTIC_NAMES.size()
		_apply_water_diagnostic_mode()
		print("Water diagnostic: %s" % WATER_DIAGNOSTIC_NAMES[water_diagnostic_mode])
	elif event.physical_keycode == KEY_F9:
		if water_material != null:
			var frozen := not bool(water_material.get_shader_parameter("freeze_time"))
			water_material.set_shader_parameter("freeze_time", frozen)
			print("Wave time frozen: %s" % frozen)


func get_depth_at_world_position(world_position: Vector3) -> Dictionary:
	if georeference == null:
		return _invalid_result("GeoReference is not assigned")
	# Ignore wave-driven Y: the DTM depth is chart datum (LAT), not wave height.
	var calm_plane_position := Vector3(world_position.x, 0.0, world_position.z)
	var geodetic := georeference.world_to_geodetic(calm_plane_position)
	return get_depth_at_geodetic(geodetic.x, geodetic.y)


func get_depth_at_geodetic(latitude_deg: float, longitude_deg: float, check_osm_land_mask: bool = true) -> Dictionary:
	if not data_available:
		return _invalid_result("Local bathymetry cache is unavailable")
	if check_osm_land_mask:
		if georeference == null:
			return _invalid_result("GeoReference is not assigned")
		var world_position := georeference.geodetic_to_world(latitude_deg, longitude_deg)
		if is_land_at_east_north(world_position.x, -world_position.z):
			return _invalid_result("Land according to the OSM coastline mask")
	var fx := (longitude_deg - _west_longitude) / _longitude_step
	var fy := (latitude_deg - _south_latitude) / _latitude_step
	if fx < 0.0 or fy < 0.0 or fx > float(_columns - 1) or fy > float(_rows - 1):
		return _invalid_result("Outside EMODnet grid coverage")
	var x0 := mini(int(floor(fx)), _columns - 2)
	var y0 := mini(int(floor(fy)), _rows - 2)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var cells := [
		_read_cell(x0, y0),
		_read_cell(x0 + 1, y0),
		_read_cell(x0 + 1, y0 + 1),
		_read_cell(x0, y0 + 1),
	]
	for cell in cells:
		if not bool(cell["valid"]):
			return _invalid_result("Land or no-data cell in interpolation neighbourhood")
	var south_depth := lerpf(float(cells[0]["depth_m"]), float(cells[1]["depth_m"]), tx)
	var north_depth := lerpf(float(cells[3]["depth_m"]), float(cells[2]["depth_m"]), tx)
	var interpolated := false
	var quality_values: Array[float] = []
	for cell in cells:
		interpolated = interpolated or bool(cell["interpolated"])
		if int(cell["value_count"]) >= 0:
			quality_values.append(float(cell["value_count"]))
	var quality: float = -1.0
	if quality_values.size() == 4:
		quality = minf(minf(quality_values[0], quality_values[1]), minf(quality_values[2], quality_values[3]))
	return {
		"depth_m": lerpf(south_depth, north_depth, ty),
		"valid": true,
		"source": SOURCE_NAME,
		"quality": quality,
		"interpolated": interpolated,
		"vertical_datum": "LAT",
	}


func get_source_metadata_at(latitude_deg: float = 55.7) -> Dictionary:
	var metres_per_degree_latitude := 111132.0
	var metres_per_degree_longitude := 111320.0 * maxf(absf(cos(deg_to_rad(latitude_deg))), 0.000001)
	return {
		"source": source_description,
		"vertical_datum": "LAT",
		"coordinate_system": "WGS84 longitude/latitude (EPSG:4326)",
		"rows": _rows,
		"columns": _columns,
		"latitude_step_deg": _latitude_step,
		"longitude_step_deg": _longitude_step,
		"resolution_north_m": _latitude_step * metres_per_degree_latitude,
		"resolution_east_m": _longitude_step * metres_per_degree_longitude,
		"navigation_grade": false,
		"quality_class": "Coarse regional DTM reference; not for navigation or safety",
	}


func is_land_at_east_north(east_m: float, north_m: float) -> bool:
	if _land_mask == null or _land_mask_meta.is_empty():
		return false
	var bounds: Array = _land_mask_meta.get("bounds_east_north_m", [])
	if bounds.size() != 4:
		return false
	var min_east := float(bounds[0])
	var min_north := float(bounds[1])
	var max_east := float(bounds[2])
	var max_north := float(bounds[3])
	if east_m < min_east or east_m >= max_east or north_m < min_north or north_m >= max_north:
		return false
	var cell_size := float(_land_mask_meta.get("cell_size_m", 30.0))
	var x := clampi(int((east_m - min_east) / cell_size), 0, _land_mask.get_width() - 1)
	var y := clampi(int((max_north - north_m) / cell_size), 0, _land_mask.get_height() - 1)
	return _land_mask.get_pixel(x, y).r > 0.5


func get_contour_levels() -> Array[String]:
	var levels: Array[String] = []
	for level in contours_by_depth.keys():
		levels.append(str(level))
	levels.sort_custom(func(a: String, b: String) -> bool: return float(a) < float(b))
	return levels


func _read_cell(column: int, row: int) -> Dictionary:
	var byte_offset := (row * _columns + column) * 4
	var depth_dm := _grid_data.decode_s16(byte_offset)
	if depth_dm == INVALID_DEPTH_DM:
		return {"valid": false}
	var interpolation_flag := _grid_data.decode_u8(byte_offset + 2)
	var value_count := _grid_data.decode_u8(byte_offset + 3)
	return {
		"valid": true,
		"depth_m": float(depth_dm) * 0.1,
		"interpolated": interpolation_flag == 1,
		"value_count": int(value_count) if value_count != 255 else -1,
	}


func _load_grid() -> void:
	if not FileAccess.file_exists(grid_metadata_path):
		push_warning("Bathymetry is unavailable; no EMODnet cache has been generated. Run tools/terrain/fetch_bathymetry.py, then tools/terrain/build_bathymetry.py.")
		return
	var metadata_file := FileAccess.open(grid_metadata_path, FileAccess.READ)
	if metadata_file == null:
		push_error("Could not read bathymetry grid metadata: %s" % grid_metadata_path)
		return
	var metadata: Variant = JSON.parse_string(metadata_file.get_as_text())
	if not metadata is Dictionary or int(metadata.get("schema_version", -1)) != 1:
		push_error("Bathymetry grid metadata is invalid or unsupported.")
		return
	_rows = int(metadata.get("rows", 0))
	_columns = int(metadata.get("columns", 0))
	_south_latitude = float(metadata.get("south_latitude_deg", 0.0))
	_west_longitude = float(metadata.get("west_longitude_deg", 0.0))
	_latitude_step = float(metadata.get("latitude_step_deg", 0.0))
	_longitude_step = float(metadata.get("longitude_step_deg", 0.0))
	if _rows < 2 or _columns < 2 or _latitude_step <= 0.0 or _longitude_step <= 0.0:
		push_error("Bathymetry grid metadata has invalid dimensions or spacing.")
		return
	var binary_path := grid_metadata_path.get_base_dir().path_join(str(metadata.get("binary_file", "depth_grid.bin")))
	if not FileAccess.file_exists(binary_path):
		push_error("Bathymetry grid binary is missing: %s" % binary_path)
		return
	_grid_data = FileAccess.get_file_as_bytes(binary_path)
	if _grid_data.size() != _rows * _columns * 4:
		push_error("Bathymetry grid binary length does not match its metadata.")
		_grid_data.clear()
		return
	source_description = str(metadata.get("source", SOURCE_NAME))
	data_available = true
	_load_depth_texture(metadata)
	print("Bathymetry loaded: %d×%d cells · %s" % [_columns, _rows, source_description])


func _load_depth_texture(metadata: Dictionary) -> void:
	var texture_metadata: Variant = metadata.get("gpu_depth_texture", {})
	if not texture_metadata is Dictionary:
		push_warning("Bathymetry depth-color texture metadata is missing; sea tint stays disabled.")
		return
	var width := int(texture_metadata.get("width", 0))
	var height := int(texture_metadata.get("height", 0))
	if width < 2 or height < 2:
		push_warning("Bathymetry depth-color texture has invalid dimensions; sea tint stays disabled.")
		return
	if not FileAccess.file_exists(depth_texture_path):
		push_warning("Bathymetry depth-color texture is missing: %s" % depth_texture_path)
		return
	var raw_data := FileAccess.get_file_as_bytes(depth_texture_path)
	if raw_data.size() != width * height * 2:
		push_warning("Bathymetry depth-color texture has an unexpected byte length; sea tint stays disabled.")
		return
	var bounds: Array = texture_metadata.get("bounds_east_north_m", [])
	if bounds.size() != 4:
		push_warning("Bathymetry depth-color texture has invalid world bounds; sea tint stays disabled.")
		return
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RG8, raw_data)
	if image.is_empty():
		push_warning("Could not create the bathymetry depth-color image; sea tint stays disabled.")
		return
	_depth_texture = ImageTexture.create_from_image(image)
	_depth_texture_bounds = Vector4(float(bounds[0]), float(bounds[1]), float(bounds[2]), float(bounds[3]))
	if water_material != null:
		water_material.set_shader_parameter("bathymetry_depth_texture", _depth_texture)
		water_material.set_shader_parameter("bathymetry_bounds_east_north", _depth_texture_bounds)
		print("Bathymetry tint texture loaded: %d×%d RG8" % [width, height])
	else:
		push_warning("BathymetryManager has no ShaderMaterial reference; sea tint stays disabled.")


func _apply_depth_color_state() -> void:
	if water_material == null:
		return
	water_material.set_shader_parameter("enable_depth_color", enable_depth_color and _depth_texture != null)


func _apply_water_diagnostic_mode() -> void:
	if water_material == null:
		return
	water_material.set_shader_parameter("water_diagnostic_mode", water_diagnostic_mode)


func _load_land_mask() -> void:
	if not FileAccess.file_exists(manifest_path):
		return
	var manifest_file := FileAccess.open(manifest_path, FileAccess.READ)
	if manifest_file == null:
		return
	var manifest: Variant = JSON.parse_string(manifest_file.get_as_text())
	if not manifest is Dictionary:
		return
	_land_mask_meta = manifest.get("land_mask", {})
	if not _land_mask_meta is Dictionary or not FileAccess.file_exists(land_mask_path):
		_land_mask_meta = {}
		return
	var mask_texture := ResourceLoader.load(land_mask_path) as Texture2D
	if mask_texture == null:
		_land_mask = null
		_land_mask_meta = {}
		push_warning("Could not load the OSM land mask for the depth chart.")
		return
	_land_mask = mask_texture.get_image()


func _load_features() -> void:
	if not FileAccess.file_exists(features_path):
		return
	var file := FileAccess.open(features_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		push_warning("Bathymetry chart features are missing or unsupported.")
		return
	for line_data in parsed.get("coastlines_east_north_m", []):
		var line := PackedVector2Array()
		for point in line_data:
			if point is Array and point.size() >= 2:
				line.append(Vector2(float(point[0]), float(point[1])))
		if line.size() >= 2:
			coastlines.append(line)
			coastline_bounds.append(_bounds_for_line(line))
	var contour_data: Dictionary = parsed.get("contour_levels_m", {})
	for level in contour_data:
		var lines: Array[PackedVector2Array] = []
		var line_bounds: Array[Rect2] = []
		for line_data in contour_data[level]:
			var line := PackedVector2Array()
			for point in line_data:
				if point is Array and point.size() >= 2:
					line.append(Vector2(float(point[0]), float(point[1])))
			if line.size() >= 2:
				lines.append(line)
				line_bounds.append(_bounds_for_line(line))
		contours_by_depth[str(level)] = lines
		contour_bounds_by_depth[str(level)] = line_bounds


func _bounds_for_line(line: PackedVector2Array) -> Rect2:
	var min_east := INF
	var min_north := INF
	var max_east := -INF
	var max_north := -INF
	for point in line:
		min_east = minf(min_east, point.x)
		min_north = minf(min_north, point.y)
		max_east = maxf(max_east, point.x)
		max_north = maxf(max_north, point.y)
	return Rect2(Vector2(min_east, min_north), Vector2(max_east - min_east, max_north - min_north))


func _invalid_result(reason: String) -> Dictionary:
	return {
		"depth_m": 0.0,
		"valid": false,
		"source": SOURCE_NAME,
		"quality": -1.0,
		"interpolated": false,
		"reason": reason,
		"vertical_datum": "LAT",
	}
