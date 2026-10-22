extends Node3D
## Shared visual-only Nordic 28 cloth state and low-cost rigging. Reads the
## body's already-cached wind/aero state; it never queries wind or water.

const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const UPDATE_INTERVAL_S := 0.05
const MAST_LINE_RADIUS_M := 0.009

@export_node_path("Node3D") var visual_rig_anchors_path: NodePath = ^"../VisualRigAnchors"
@export_node_path("MeshInstance3D") var main_sail_path: NodePath = ^"../VisualBoomPivot/MainSailMesh"
@export_node_path("MeshInstance3D") var jib_sail_path: NodePath = ^"../HeadsailVisual"

var _body: RigidBody3D
var _anchors: Node3D
var _main_sail: MeshInstance3D
var _jib_sail: MeshInstance3D
var _rigging_root: Node3D
var _fixed_rigging_mesh: MeshInstance3D
var _rigging_material: StandardMaterial3D
var _rig_lines: Dictionary = {}
var _rigging_built := false
var _fixed_rigging_segment_count := 0
var _billow_enabled := true
var _wireframe_enabled := false
var _logo_enabled := true
var _rigging_enabled := true
var _elapsed := 0.0
var _visual_phase := 0.0
var _main_fill := 0.0
var _jib_fill := 0.0
var _main_side := "无有效视风"
var _headsail_is_enabled := true


func _ready() -> void:
	_body = get_parent().get_parent() as RigidBody3D if get_parent() != null and get_parent().get_parent() is RigidBody3D else null
	_anchors = get_node_or_null(visual_rig_anchors_path) as Node3D
	_main_sail = get_node_or_null(main_sail_path) as MeshInstance3D
	_jib_sail = get_node_or_null(jib_sail_path) as MeshInstance3D
	_rigging_root = Node3D.new()
	_rigging_root.name = "Nordic28Rigging"
	add_child(_rigging_root)
	_apply_visual_options()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < UPDATE_INTERVAL_S:
		return
	var step := _elapsed
	_elapsed = 0.0
	_visual_phase += step
	_update_cached_cloth_state()
	if not _rigging_built and _anchors != null and _anchors.has_method("is_configured") and bool(_anchors.call("is_configured")):
		_build_fixed_rigging()


func set_debug_options(billow_enabled: bool, wireframe_enabled: bool, logo_enabled: bool, rigging_enabled: bool) -> void:
	_billow_enabled = billow_enabled
	_wireframe_enabled = wireframe_enabled
	_logo_enabled = logo_enabled
	_rigging_enabled = rigging_enabled
	_apply_visual_options()


func get_visual_snapshot() -> Dictionary:
	var main_snapshot: Dictionary = _main_sail.call("get_visual_snapshot") if _main_sail != null and _main_sail.has_method("get_visual_snapshot") else {}
	var jib_snapshot: Dictionary = _jib_sail.call("get_visual_snapshot") if _jib_sail != null and _jib_sail.has_method("get_visual_snapshot") else {}
	return {
		"main_fill": _main_fill,
		"jib_fill": _jib_fill,
		"main_side": _main_side,
		"headsail_enabled": _headsail_is_enabled,
		"billow_enabled": _billow_enabled,
		"wireframe_enabled": _wireframe_enabled,
		"logo_enabled": _logo_enabled,
		"rigging_enabled": _rigging_enabled,
		"rigging_built": _rigging_built,
		"main_mesh": main_snapshot,
		"jib_mesh": jib_snapshot,
		"rigging_line_count": _fixed_rigging_segment_count + 2,
		"rigging_draw_call_count": 3 if _rigging_built else 0,
	}


func _update_cached_cloth_state() -> void:
	if _body == null:
		return
	var body_basis: Basis = _body.global_basis
	var main_apparent_body: Vector3 = _body.get("_last_apparent_wind_local_mps")
	var jib_apparent_body: Vector3 = _body.get("_last_headsail_apparent_wind_local_mps")
	var main_apparent_speed := float(_body.get("_last_apparent_wind_speed_mps"))
	var jib_apparent_speed := float(_body.get("_last_headsail_apparent_wind_speed_mps"))
	var main_efficiency := float(_body.get("_last_sail_sheet_efficiency_scale"))
	var jib_efficiency := float(_body.get("_last_headsail_luffing_scale")) * float(_body.get("_last_headsail_wrong_side_lift_scale"))
	var main_angle := float(_body.get("actual_sail_angle_rad"))
	var jib_angle := float(_body.get("actual_headsail_angle_rad"))
	_headsail_is_enabled = bool(_body.get("_headsail_enabled"))
	var main_world := body_basis * main_apparent_body
	var jib_world := body_basis * jib_apparent_body
	if _main_sail != null and _main_sail.has_method("set_cloth_state"):
		var main_air_local := _main_sail.global_basis.inverse() * main_world
		_main_sail.call("set_cloth_state", main_air_local, main_apparent_speed, main_efficiency, _visual_phase)
		if _main_sail.has_method("set_visual_options"):
			_main_sail.call("set_visual_options", _billow_enabled, _wireframe_enabled, _logo_enabled)
	_main_fill = _air_fill(main_apparent_speed, main_efficiency)
	if _jib_sail != null and _jib_sail.has_method("set_cloth_state"):
		var jib_air_local := _jib_sail.global_basis.inverse() * jib_world
		_jib_sail.call("set_cloth_state", jib_air_local, jib_apparent_speed, jib_efficiency, _visual_phase)
		if _jib_sail.has_method("set_visual_options"):
			_jib_sail.call("set_visual_options", _billow_enabled, _wireframe_enabled, false)
	_jib_fill = _air_fill(jib_apparent_speed, jib_efficiency) if _headsail_is_enabled else 0.0
	_main_side = str(_body.get("_last_windward_side"))
	_update_running_rigging(main_angle, jib_angle)


func _air_fill(speed_mps: float, efficiency: float) -> float:
	if not is_finite(speed_mps) or not is_finite(efficiency):
		return 0.0
	return smoothstep(0.5, 5.0, maxf(speed_mps, 0.0)) * clampf(efficiency, 0.0, 1.0)


func _apply_visual_options() -> void:
	if _main_sail != null and _main_sail.has_method("set_visual_options"):
		_main_sail.call("set_visual_options", _billow_enabled, _wireframe_enabled, _logo_enabled)
	if _jib_sail != null and _jib_sail.has_method("set_visual_options"):
		_jib_sail.call("set_visual_options", _billow_enabled, _wireframe_enabled, false)
	if _rigging_root != null:
		_rigging_root.visible = _rigging_enabled


func _build_fixed_rigging() -> void:
	var profile: Resource = _anchors.get("visual_profile")
	if profile == null:
		return
	var mast_base: Vector3 = profile.get("mast_base_local_m")
	var mast_top := mast_base + Vector3.UP * float(profile.get("mast_length_m"))
	var jib_head: Vector3 = profile.get("jib_head_local_m")
	var jib_tack: Vector3 = profile.get("jib_tack_local_m")
	var mast_station_z := mast_base.z
	var forestay_end_y := _hull_surface_y(jib_tack.x, jib_tack.z, jib_tack.y)
	var stern_z := 3.35
	var stern_y := _hull_surface_y(0.0, stern_z, 0.92)
	var chainplate_z := -0.50
	var port_chainplate := Vector3(-1.02, _hull_surface_y(-1.02, chainplate_z, 0.92), chainplate_z)
	var starboard_chainplate := Vector3(1.02, _hull_surface_y(1.02, chainplate_z, 0.92), chainplate_z)
	var shroud_top := mast_base + Vector3.UP * (float(profile.get("mast_length_m")) * 0.78)
	var spreader_height := mast_base.y + float(profile.get("mast_length_m")) * 0.56
	var spreader_half_width := 0.46
	var fixed_segments: Array = [
		[jib_head, Vector3(jib_tack.x, forestay_end_y, jib_tack.z), 0.010],
		[mast_top, Vector3(0.0, stern_y, stern_z), 0.009],
		[shroud_top, port_chainplate, 0.011],
		[shroud_top, starboard_chainplate, 0.011],
	]
	_fixed_rigging_segment_count = 6
	_create_rig_line("MainSheet", 0.008)
	_create_rig_line("JibSheet", 0.007)
	var spreader_center := Vector3(0.0, spreader_height, mast_station_z)
	fixed_segments.append([spreader_center, spreader_center + Vector3(-spreader_half_width, 0.0, 0.0), 0.018])
	fixed_segments.append([spreader_center, spreader_center + Vector3(spreader_half_width, 0.0, 0.0), 0.018])
	_build_fixed_rigging_mesh(fixed_segments)
	_rigging_built = true


func _hull_surface_y(local_x: float, local_z: float, fallback_y: float) -> float:
	if _anchors != null and _anchors.has_method("get_hull_surface_height_at"):
		var height := float(_anchors.call("get_hull_surface_height_at", local_x, local_z))
		if is_finite(height):
			return height + 0.08
	return fallback_y


func _create_rig_line(line_name: String, radius: float) -> void:
	var line := MeshInstance3D.new()
	line.name = line_name
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = 1.0
	cylinder.radial_segments = 5
	line.mesh = cylinder
	line.material_override = _get_rigging_material()
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rigging_root.add_child(line)
	_rig_lines[line_name] = line


func _get_rigging_material() -> StandardMaterial3D:
	if _rigging_material != null:
		return _rigging_material
	_rigging_material = StandardMaterial3D.new()
	_rigging_material.albedo_color = Color("#727c80")
	_rigging_material.metallic = 0.42
	_rigging_material.roughness = 0.78
	_rigging_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _rigging_material


func _build_fixed_rigging_mesh(segments: Array) -> void:
	const SIDES := 5
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for segment_variant in segments:
		var segment: Array = segment_variant
		var start: Vector3 = segment[0]
		var end: Vector3 = segment[1]
		var radius := float(segment[2])
		var direction := end - start
		if direction.length_squared() < 0.000001:
			continue
		direction = direction.normalized()
		var reference := Vector3.RIGHT if absf(direction.dot(Vector3.RIGHT)) < 0.90 else Vector3.FORWARD
		var axis_a := direction.cross(reference).normalized()
		var axis_b := direction.cross(axis_a).normalized()
		var base_index := vertices.size()
		for side_index in range(SIDES):
			var angle := TAU * float(side_index) / float(SIDES)
			var radial := (axis_a * cos(angle) + axis_b * sin(angle)).normalized()
			vertices.append(start + radial * radius)
			vertices.append(end + radial * radius)
			normals.append(radial)
			normals.append(radial)
		for side_index in range(SIDES):
			var next_side := (side_index + 1) % SIDES
			var a := base_index + side_index * 2
			var b := a + 1
			var c := base_index + next_side * 2
			var d := c + 1
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var combined_mesh := ArrayMesh.new()
	combined_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_fixed_rigging_mesh = MeshInstance3D.new()
	_fixed_rigging_mesh.name = "FixedRigging"
	_fixed_rigging_mesh.mesh = combined_mesh
	_fixed_rigging_mesh.material_override = _get_rigging_material()
	_fixed_rigging_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rigging_root.add_child(_fixed_rigging_mesh)


func _set_rig_line(line_name: String, start: Vector3, end: Vector3) -> void:
	var line := _rig_lines.get(line_name) as MeshInstance3D
	if line == null or not line.mesh is CylinderMesh:
		return
	var direction := end - start
	var length := direction.length()
	if length < 0.001:
		line.visible = false
		return
	var cylinder := line.mesh as CylinderMesh
	line.position = (start + end) * 0.5
	line.basis = Basis(Quaternion(Vector3.UP, direction / length)).scaled(Vector3(1.0, length, 1.0))
	line.visible = true


func _update_running_rigging(main_angle_rad: float = 0.0, jib_angle_rad: float = 0.0) -> void:
	if not _rigging_built or _anchors == null:
		return
	var profile: Resource = _anchors.get("visual_profile")
	if profile == null:
		return
	var boom_pivot: Vector3 = profile.get("boom_pivot_local_m")
	var boom_length := float(profile.get("boom_length_m"))
	var boom_basis := Basis(Vector3.UP, main_angle_rad)
	var sheet_attachment := boom_pivot + boom_basis * Vector3(0.0, 0.0, boom_length * 0.70)
	var main_sheet_z := 1.20
	var main_sheet_y := _hull_surface_y(0.0, main_sheet_z, 0.95)
	_set_rig_line("MainSheet", sheet_attachment, Vector3(0.0, main_sheet_y, main_sheet_z))
	var jib_tack: Vector3 = profile.get("jib_tack_local_m")
	var neutral_clew: Vector3 = profile.get("jib_clew_local_m")
	var jib_clew := AERO_MATH.headsail_clew_from_sheet(jib_tack, neutral_clew, jib_angle_rad)
	var active_side := signf(jib_clew.x)
	if is_zero_approx(active_side):
		active_side = signf(jib_angle_rad)
	if is_zero_approx(active_side):
		active_side = 1.0
	var fairlead_x := -0.92 if active_side < 0.0 else 0.92
	var jib_fairlead := Vector3(fairlead_x, _hull_surface_y(fairlead_x, -0.10, 0.92), -0.10)
	_set_rig_line("JibSheet", jib_clew, jib_fairlead)
	var jib_sheet := _rig_lines.get("JibSheet") as MeshInstance3D
	if jib_sheet != null:
		jib_sheet.visible = _rigging_enabled and _headsail_is_enabled

