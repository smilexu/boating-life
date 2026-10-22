extends Node3D
## Visual-only Nordic 28 cockpit helm. It samples the real cockpit floor once,
## then mirrors the body's actual rudder angle onto a low-poly teak wheel.

const WHEEL_SPOKE_COUNT := 6
const RIM_SEGMENTS := 40
const RIM_TUBE_SEGMENTS := 8
const WOOD_TEXTURE_SIZE := 256
const WOOD_TUBE_RADIUS_M := 0.019
const HUB_RADIUS_M := 0.064

@export_node_path("Node3D") var visual_anchors_path: NodePath = ^"../VisualRigAnchors"
@export_node_path("RigidBody3D") var boat_body_path: NodePath = ^"../.."

var _body: RigidBody3D
var _anchors: Node3D
var _profile: Resource
var _wheel_pivot: Node3D
var _wheel_degrees_per_rudder_degree := 180.0 / 35.0
var _wheel_rotation_sign := -1.0
var _pedestal_height_m := 0.72
var _pedestal_base_size_m := Vector2(0.48, 0.38)
var _pedestal_top_size_m := Vector2(0.32, 0.26)
var _wheel_outer_radius_m := 0.353
var _floor_y_local_m := NAN
var _configured := false
var _teak_texture: ImageTexture


func _ready() -> void:
	_body = get_node_or_null(boat_body_path) as RigidBody3D
	_anchors = get_node_or_null(visual_anchors_path) as Node3D
	if _anchors != null:
		_profile = _anchors.get("visual_profile") as Resource
	call_deferred("_configure_helm")


func _configure_helm() -> void:
	for _attempt in range(8):
		if _anchors != null and _anchors.has_method("is_configured") and bool(_anchors.call("is_configured")):
			break
		await get_tree().process_frame
	if _body == null or _anchors == null or _profile == null:
		push_warning("Nordic28HelmVisual could not find its body, visual anchors, or visual profile.")
		return
	var station: Vector3 = _profile.get("helm_station_local_m")
	_floor_y_local_m = float(_anchors.call("get_hull_surface_height_at", station.x, station.z))
	if not is_finite(_floor_y_local_m):
		push_warning("Nordic28HelmVisual could not sample the cockpit floor from the Nordic 28 hull triangles.")
		return
	_pedestal_height_m = float(_profile.get("helm_pedestal_height_m"))
	_pedestal_base_size_m = _profile.get("helm_pedestal_base_size_m")
	_pedestal_top_size_m = _profile.get("helm_pedestal_top_size_m")
	_wheel_outer_radius_m = float(_profile.get("helm_wheel_outer_radius_m"))
	_wheel_degrees_per_rudder_degree = float(_profile.get("helm_wheel_degrees_per_rudder_degree"))
	_wheel_rotation_sign = float(_profile.get("helm_wheel_rotation_sign"))
	position = Vector3(station.x, _floor_y_local_m, station.z)
	_build_pedestal()
	_build_wheel()
	_configured = true
	_update_wheel_rotation()


func _process(_delta: float) -> void:
	_update_wheel_rotation()


func _update_wheel_rotation() -> void:
	if _body == null or _wheel_pivot == null:
		return
	var rudder_angle_rad := float(_body.get("actual_rudder_angle_rad"))
	var wheel_angle_rad := rudder_angle_rad * _wheel_degrees_per_rudder_degree * _wheel_rotation_sign
	_wheel_pivot.rotation.z = wheel_angle_rad


func _build_pedestal() -> void:
	var fiberglass := StandardMaterial3D.new()
	fiberglass.albedo_color = Color("#F2F0E9")
	fiberglass.metallic = 0.03
	fiberglass.roughness = 0.40
	fiberglass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pedestal := MeshInstance3D.new()
	pedestal.name = "FiberglassPedestal"
	pedestal.mesh = _build_tapered_pedestal_mesh(
		_pedestal_base_size_m,
		_pedestal_top_size_m,
		_pedestal_height_m
	)
	pedestal.material_override = fiberglass
	pedestal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(pedestal)

	var stainless := _make_stainless_material()
	var dark_panel := StandardMaterial3D.new()
	dark_panel.albedo_color = Color("#303A3D")
	dark_panel.metallic = 0.20
	dark_panel.roughness = 0.43
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(0.28, 0.14, 0.038)
	var panel := MeshInstance3D.new()
	panel.name = "InstrumentPanel"
	panel.mesh = panel_mesh
	panel.material_override = dark_panel
	panel.position = Vector3(0.0, _pedestal_height_m - 0.065, -0.055)
	panel.rotation.x = deg_to_rad(-16.0)
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(panel)

	var wheel_center_height := _wheel_center_height_m()
	var support_height := maxf(wheel_center_height - _pedestal_height_m + 0.04, 0.10)
	var support_mesh := CylinderMesh.new()
	support_mesh.top_radius = 0.038
	support_mesh.bottom_radius = 0.046
	support_mesh.height = support_height
	support_mesh.radial_segments = 10
	var support := MeshInstance3D.new()
	support.name = "HelmSupportColumn"
	support.mesh = support_mesh
	support.material_override = stainless
	support.position = Vector3(0.0, _pedestal_height_m + support_height * 0.5 - 0.01, 0.105)
	support.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(support)


func _build_wheel() -> void:
	var wood_material := _make_teak_material()
	var stainless := _make_stainless_material()
	var wheel_center_height := _wheel_center_height_m()
	_wheel_pivot = Node3D.new()
	_wheel_pivot.name = "HelmWheelActualAnglePivot"
	_wheel_pivot.position = Vector3(0.0, wheel_center_height, 0.145)
	add_child(_wheel_pivot)

	var tube_radius := WOOD_TUBE_RADIUS_M
	var centerline_radius := _wheel_outer_radius_m - tube_radius
	var rim := MeshInstance3D.new()
	rim.name = "TeakWheelRim"
	rim.mesh = _build_wheel_rim_mesh(centerline_radius, tube_radius)
	rim.material_override = wood_material
	rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_wheel_pivot.add_child(rim)

	var spoke_length := centerline_radius - HUB_RADIUS_M - 0.012
	var spoke_mesh := CylinderMesh.new()
	spoke_mesh.top_radius = 0.014
	spoke_mesh.bottom_radius = 0.014
	spoke_mesh.height = spoke_length
	spoke_mesh.radial_segments = 8
	var spoke_batch := MultiMeshInstance3D.new()
	spoke_batch.name = "TeakWheelSpokes"
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = spoke_mesh
	multimesh.instance_count = WHEEL_SPOKE_COUNT
	var spoke_center_radius := HUB_RADIUS_M + spoke_length * 0.5
	for index in range(WHEEL_SPOKE_COUNT):
		var angle := TAU * float(index) / float(WHEEL_SPOKE_COUNT)
		var direction := Vector3(sin(angle), cos(angle), 0.0)
		var basis := Basis(Vector3.BACK, -angle)
		var transform := Transform3D(basis, direction * spoke_center_radius)
		multimesh.set_instance_transform(index, transform)
	spoke_batch.multimesh = multimesh
	spoke_batch.material_override = wood_material
	spoke_batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_wheel_pivot.add_child(spoke_batch)

	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = HUB_RADIUS_M
	hub_mesh.bottom_radius = HUB_RADIUS_M
	hub_mesh.height = 0.052
	hub_mesh.radial_segments = 16
	var hub := MeshInstance3D.new()
	hub.name = "StainlessWheelHub"
	hub.mesh = hub_mesh
	hub.material_override = stainless
	hub.rotation.x = PI * 0.5
	hub.position.z = 0.018
	hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wheel_pivot.add_child(hub)

	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.026
	cap_mesh.bottom_radius = 0.026
	cap_mesh.height = 0.060
	cap_mesh.radial_segments = 12
	var cap := MeshInstance3D.new()
	cap.name = "StainlessWheelCenterCap"
	cap.mesh = cap_mesh
	cap.material_override = stainless
	cap.rotation.x = PI * 0.5
	cap.position.z = 0.057
	cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wheel_pivot.add_child(cap)


func _wheel_center_height_m() -> float:
	return _pedestal_height_m + 0.25


func _make_stainless_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#ADB6B9")
	material.metallic = 0.78
	material.roughness = 0.32
	return material


func _make_teak_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = _make_teak_texture()
	material.albedo_color = Color.WHITE
	material.metallic = 0.0
	material.roughness = 0.38
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material


func _make_teak_texture() -> ImageTexture:
	if _teak_texture != null:
		return _teak_texture
	var image := Image.create(WOOD_TEXTURE_SIZE, WOOD_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(WOOD_TEXTURE_SIZE):
		var v := float(y) / float(WOOD_TEXTURE_SIZE)
		var warp := 0.012 * sin(TAU * v * 3.0) + 0.005 * sin(TAU * v * 7.0)
		for x in range(WOOD_TEXTURE_SIZE):
			var u := float(x) / float(WOOD_TEXTURE_SIZE)
			var phase := u + warp
			var broad_grain := sin(TAU * phase * 8.0)
			var fine_grain := sin(TAU * (phase * 27.0 + 0.025 * sin(TAU * v * 5.0)))
			var dark_fiber := pow(maxf(cos(TAU * (phase * 43.0 + 0.012 * sin(TAU * v * 4.0))), 0.0), 18.0)
			var variation := 0.92 + 0.055 * broad_grain + 0.024 * fine_grain - 0.12 * dark_fiber
			image.set_pixel(x, y, Color(
				clampf(0.60 * variation, 0.0, 1.0),
				clampf(0.34 * variation, 0.0, 1.0),
				clampf(0.18 * variation, 0.0, 1.0),
				1.0
			))
	image.generate_mipmaps()
	_teak_texture = ImageTexture.create_from_image(image)
	return _teak_texture


func _build_tapered_pedestal_mesh(base_size: Vector2, top_size: Vector2, height: float) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bottom := _beveled_rectangle(base_size, 0.035, 0.0)
	var top := _beveled_rectangle(top_size, 0.025, height)
	for index in range(bottom.size()):
		var next := (index + 1) % bottom.size()
		var a: Vector3 = bottom[index]
		var b: Vector3 = bottom[next]
		var c: Vector3 = top[next]
		var d: Vector3 = top[index]
		var face_center := (a + b + c + d) * 0.25
		var expected := Vector3(face_center.x, 0.0, face_center.z).normalized()
		var normal := (b - a).cross(c - a).normalized()
		if normal.dot(expected) < 0.0:
			var swap := b
			b = d
			d = swap
			normal = (b - a).cross(c - a).normalized()
		var u0 := float(index) / float(bottom.size())
		var u1 := float(index + 1) / float(bottom.size())
		_append_triangle(tool, a, b, c, normal, Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, 1.0))
		_append_triangle(tool, a, c, d, normal, Vector2(u0, 0.0), Vector2(u1, 1.0), Vector2(u0, 1.0))
	var top_center := Vector3(0.0, height, 0.0)
	for index in range(top.size()):
		var next := (index + 1) % top.size()
		var a: Vector3 = top[index]
		var b: Vector3 = top[next]
		if (b - a).cross(top_center - a).dot(Vector3.UP) < 0.0:
			var swap := a
			a = b
			b = swap
		_append_triangle(tool, a, b, top_center, Vector3.UP, Vector2.ZERO, Vector2.ONE, Vector2(0.5, 0.5))
	return tool.commit()


func _beveled_rectangle(size: Vector2, bevel: float, y: float) -> PackedVector3Array:
	var half_x := size.x * 0.5
	var half_z := size.y * 0.5
	var cut := minf(bevel, minf(half_x, half_z) * 0.4)
	return PackedVector3Array([
		Vector3(-half_x + cut, y, -half_z), Vector3(half_x - cut, y, -half_z),
		Vector3(half_x, y, -half_z + cut), Vector3(half_x, y, half_z - cut),
		Vector3(half_x - cut, y, half_z), Vector3(-half_x + cut, y, half_z),
		Vector3(-half_x, y, half_z - cut), Vector3(-half_x, y, -half_z + cut),
	])


func _build_wheel_rim_mesh(centerline_radius: float, tube_radius: float) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for segment in range(RIM_SEGMENTS):
		var theta0 := TAU * float(segment) / float(RIM_SEGMENTS)
		var theta1 := TAU * float(segment + 1) / float(RIM_SEGMENTS)
		for tube_segment in range(RIM_TUBE_SEGMENTS):
			var phi0 := TAU * float(tube_segment) / float(RIM_TUBE_SEGMENTS)
			var phi1 := TAU * float(tube_segment + 1) / float(RIM_TUBE_SEGMENTS)
			var p00 := _wheel_rim_point(theta0, phi0, centerline_radius, tube_radius)
			var p10 := _wheel_rim_point(theta1, phi0, centerline_radius, tube_radius)
			var p11 := _wheel_rim_point(theta1, phi1, centerline_radius, tube_radius)
			var p01 := _wheel_rim_point(theta0, phi1, centerline_radius, tube_radius)
			var n00 := _wheel_rim_normal(theta0, phi0)
			var n10 := _wheel_rim_normal(theta1, phi0)
			var n11 := _wheel_rim_normal(theta1, phi1)
			var n01 := _wheel_rim_normal(theta0, phi1)
			var uv00 := Vector2(float(tube_segment) / float(RIM_TUBE_SEGMENTS), float(segment) / float(RIM_SEGMENTS))
			var uv10 := Vector2(float(tube_segment) / float(RIM_TUBE_SEGMENTS), float(segment + 1) / float(RIM_SEGMENTS))
			var uv11 := Vector2(float(tube_segment + 1) / float(RIM_TUBE_SEGMENTS), float(segment + 1) / float(RIM_SEGMENTS))
			var uv01 := Vector2(float(tube_segment + 1) / float(RIM_TUBE_SEGMENTS), float(segment) / float(RIM_SEGMENTS))
			_append_triangle(tool, p00, p10, p11, n00, uv00, uv10, uv11)
			_append_triangle(tool, p00, p11, p01, n00, uv00, uv11, uv01)
	return tool.commit()


func _wheel_rim_point(theta: float, phi: float, centerline_radius: float, tube_radius: float) -> Vector3:
	var radial := Vector3(cos(theta), sin(theta), 0.0)
	return radial * (centerline_radius + tube_radius * cos(phi)) + Vector3.BACK * tube_radius * sin(phi)


func _wheel_rim_normal(theta: float, phi: float) -> Vector3:
	return Vector3(cos(theta) * cos(phi), sin(theta) * cos(phi), -sin(phi)).normalized()


func _append_triangle(
	tool: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal: Vector3,
	uv_a: Vector2,
	uv_b: Vector2,
	uv_c: Vector2
) -> void:
	tool.set_normal(normal)
	tool.set_uv(uv_a)
	tool.add_vertex(a)
	tool.set_normal(normal)
	tool.set_uv(uv_b)
	tool.add_vertex(b)
	tool.set_normal(normal)
	tool.set_uv(uv_c)
	tool.add_vertex(c)


func get_helm_snapshot() -> Dictionary:
	var rudder_angle := float(_body.get("actual_rudder_angle_rad")) if _body != null else 0.0
	var wheel_angle := _wheel_pivot.rotation.z if _wheel_pivot != null else 0.0
	return {
		"configured": _configured,
		"station_local_m": position,
		"cockpit_floor_y_local_m": _floor_y_local_m,
		"pedestal_height_m": _pedestal_height_m,
		"pedestal_base_size_m": _pedestal_base_size_m,
		"pedestal_top_size_m": _pedestal_top_size_m,
		"wheel_outer_diameter_m": _wheel_outer_radius_m * 2.0,
		"wheel_center_visual_root_y_m": _wheel_center_height_m(),
		"wheel_degrees_per_rudder_degree": _wheel_degrees_per_rudder_degree,
		"wheel_rotation_sign": _wheel_rotation_sign,
		"rudder_actual_angle_rad": rudder_angle,
		"wheel_rotation_rad": wheel_angle,
		"teak_texture_size": WOOD_TEXTURE_SIZE,
		"spoke_count": WHEEL_SPOKE_COUNT,
	}
