extends RefCounted

## Builds the shared, lightweight meshes used by both Øresund wind farms.

static func build_meshes(hub_height_m: float, rotor_radius_m: float, foundation_depth_m: float) -> Dictionary:
	var base_material := StandardMaterial3D.new()
	base_material.albedo_color = Color("#F4F5F3")
	base_material.vertex_color_use_as_albedo = true
	base_material.roughness = 0.74
	base_material.metallic = 0.03
	base_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var rotor_material := StandardMaterial3D.new()
	rotor_material.albedo_color = Color("#F4F5F3")
	rotor_material.vertex_color_use_as_albedo = true
	rotor_material.roughness = 0.68
	rotor_material.metallic = 0.03
	rotor_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var near_base_tool := SurfaceTool.new()
	near_base_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_cylinder_y(near_base_tool, foundation_depth_m, -0.85, 3.0, 3.0, 16, Color("#687276"))
	_append_cylinder_y(near_base_tool, -0.85, 0.65, 3.035, 3.035, 16, Color("#3C4548"))
	_append_frustum_y(near_base_tool, 0.55, 3.5, 3.1, 2.2, 16, Color("#C7AD67"))
	_append_weathering_streaks(near_base_tool)
	_append_frustum_y(near_base_tool, 2.8, hub_height_m, 2.25, 1.25, 16, Color("#DDE2DF"))
	_append_maintenance_platform(near_base_tool)
	_append_box(near_base_tool, Vector3(0.0, 7.0, 2.08), Vector3(1.35, 2.0, 0.12), Color("#566064"))
	_append_box(near_base_tool, Vector3(0.48, 7.0, 2.16), Vector3(0.08, 0.42, 0.06), Color("#D1B363"))
	_append_ladder(near_base_tool)
	_append_box(near_base_tool, Vector3(0.0, hub_height_m, -2.1), Vector3(8.0, 3.6, 5.6), Color("#D5DBD8"))
	_append_box(near_base_tool, Vector3(0.0, hub_height_m + 1.85, -2.3), Vector3(5.5, 0.25, 4.0), Color("#E3E7E4"))
	_append_box(near_base_tool, Vector3(4.08, hub_height_m - 0.05, -2.15), Vector3(0.12, 2.2, 2.5), Color("#707A7D"))
	_append_box(near_base_tool, Vector3(-4.08, hub_height_m - 0.05, -2.15), Vector3(0.12, 2.2, 2.5), Color("#707A7D"))
	_append_box(near_base_tool, Vector3(-1.4, hub_height_m + 2.02, -2.0), Vector3(1.4, 0.3, 1.0), Color("#6F797B"))
	_append_cylinder_z(near_base_tool, Vector3(0.0, hub_height_m, 1.2), 1.8, 2.4, 12, Color("#CDD3D1"))
	var near_base_mesh := near_base_tool.commit()

	var near_rotor_tool := SurfaceTool.new()
	near_rotor_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_rotor(near_rotor_tool, rotor_radius_m, true)
	var near_rotor_mesh := near_rotor_tool.commit()

	var far_base_tool := SurfaceTool.new()
	far_base_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_cylinder_y(far_base_tool, foundation_depth_m, -0.85, 2.5, 2.5, 8, Color("#687276"))
	_append_cylinder_y(far_base_tool, -0.85, 0.65, 2.535, 2.535, 8, Color("#3C4548"))
	_append_frustum_y(far_base_tool, 0.55, 3.1, 2.65, 1.9, 8, Color("#C7AD67"))
	_append_frustum_y(far_base_tool, 2.6, hub_height_m, 1.95, 1.25, 8, Color("#DDE2DF"))
	_append_box(far_base_tool, Vector3(0.0, hub_height_m, -1.8), Vector3(6.8, 3.2, 5.0), Color("#D5DBD8"))
	_append_box(far_base_tool, Vector3(3.48, hub_height_m, -1.8), Vector3(0.12, 1.8, 2.0), Color("#707A7D"))
	_append_box(far_base_tool, Vector3(-3.48, hub_height_m, -1.8), Vector3(0.12, 1.8, 2.0), Color("#707A7D"))
	_append_cylinder_z(far_base_tool, Vector3(0.0, hub_height_m, 1.0), 1.55, 2.2, 8, Color("#CDD3D1"))
	var far_base_mesh := far_base_tool.commit()

	var far_rotor_tool := SurfaceTool.new()
	far_rotor_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_rotor(far_rotor_tool, rotor_radius_m, false)
	var far_rotor_mesh := far_rotor_tool.commit()

	var beacon_mesh := SphereMesh.new()
	beacon_mesh.radius = 1.1
	beacon_mesh.height = 2.2
	beacon_mesh.radial_segments = 8
	beacon_mesh.rings = 4
	var beacon_material := StandardMaterial3D.new()
	beacon_material.albedo_color = Color("#6C3433")
	beacon_material.roughness = 0.45
	beacon_material.emission_enabled = true
	beacon_material.emission = Color("#E6514A")
	beacon_material.emission_energy_multiplier = 0.0

	var platform_light_mesh := SphereMesh.new()
	platform_light_mesh.radius = 0.4
	platform_light_mesh.height = 0.8
	platform_light_mesh.radial_segments = 8
	platform_light_mesh.rings = 4
	var platform_light_material := StandardMaterial3D.new()
	platform_light_material.albedo_color = Color("#8C6133")
	platform_light_material.roughness = 0.6
	platform_light_material.emission_enabled = true
	platform_light_material.emission = Color("#E8B76B")
	platform_light_material.emission_energy_multiplier = 0.0

	return {
		"base_near": near_base_mesh,
		"rotor_near": near_rotor_mesh,
		"base_far": far_base_mesh,
		"rotor_far": far_rotor_mesh,
		"beacon": beacon_mesh,
		"platform_light": platform_light_mesh,
		"base_material": base_material,
		"rotor_material": rotor_material,
		"beacon_material": beacon_material,
		"platform_light_material": platform_light_material,
	}


static func _append_rotor(tool: SurfaceTool, rotor_radius_m: float, detailed: bool) -> void:
	var sections: Array[Dictionary]
	if detailed:
		sections = [
			{"radius": 1.7, "chord": 4.3, "sweep": 0.0, "thickness": 0.54},
			{"radius": rotor_radius_m * 0.24, "chord": 4.0, "sweep": -0.9, "thickness": 0.42},
			{"radius": rotor_radius_m * 0.48, "chord": 3.1, "sweep": -2.2, "thickness": 0.30},
			{"radius": rotor_radius_m * 0.72, "chord": 2.2, "sweep": -3.4, "thickness": 0.20},
			{"radius": rotor_radius_m * 0.9, "chord": 1.35, "sweep": -4.0, "thickness": 0.12},
			{"radius": rotor_radius_m, "chord": 0.65, "sweep": -4.2, "thickness": 0.08},
		]
	else:
		sections = [
			{"radius": 1.7, "chord": 1.55, "sweep": 0.0, "thickness": 0.2},
			{"radius": rotor_radius_m * 0.88, "chord": 0.32, "sweep": -1.9, "thickness": 0.09},
			{"radius": rotor_radius_m, "chord": 0.25, "sweep": -2.0, "thickness": 0.08},
		]
	var blade_color := Color("#E1E5E2") if detailed else Color("#C7CECB")
	var blade_tip_color := Color("#eb0555")
	for blade_index in range(3):
		var angle := deg_to_rad(120.0 * float(blade_index))
		for section_index in range(sections.size() - 1):
			var inner: Dictionary = sections[section_index]
			var outer: Dictionary = sections[section_index + 1]
			var i_front_left := _blade_point(inner, -1.0, -1.0, angle)
			var i_front_right := _blade_point(inner, 1.0, -1.0, angle)
			var i_back_left := _blade_point(inner, -1.0, 1.0, angle)
			var i_back_right := _blade_point(inner, 1.0, 1.0, angle)
			var o_front_left := _blade_point(outer, -1.0, -1.0, angle)
			var o_front_right := _blade_point(outer, 1.0, -1.0, angle)
			var o_back_left := _blade_point(outer, -1.0, 1.0, angle)
			var o_back_right := _blade_point(outer, 1.0, 1.0, angle)
			var segment_color := blade_tip_color if float(inner["radius"]) >= rotor_radius_m * 0.86 else blade_color
			_add_quad(tool, i_front_left, o_front_left, o_front_right, i_front_right, segment_color, Vector3.BACK)
			_add_quad(tool, i_back_left, i_back_right, o_back_right, o_back_left, segment_color, Vector3.FORWARD)
			var left_normal := Vector3.LEFT.rotated(Vector3.BACK, angle)
			var right_normal := Vector3.RIGHT.rotated(Vector3.BACK, angle)
			_add_quad(tool, i_front_left, i_back_left, o_back_left, o_front_left, segment_color, left_normal)
			_add_quad(tool, i_front_right, o_front_right, o_back_right, i_back_right, segment_color, right_normal)
			if section_index == 0:
				var start_normal := Vector3.DOWN.rotated(Vector3.BACK, angle)
				_add_quad(tool, i_front_left, i_front_right, i_back_right, i_back_left, blade_color, start_normal)
			if section_index == sections.size() - 2:
				var end_normal := Vector3.UP.rotated(Vector3.BACK, angle)
				_add_quad(tool, o_front_left, o_back_left, o_back_right, o_front_right, segment_color, end_normal)


static func _append_maintenance_platform(tool: SurfaceTool) -> void:
	var deck_color := Color("#626D70")
	var rail_color := Color("#A6AEAC")
	var safety_color := Color("#D0B45F")
	_append_box(tool, Vector3(0.0, 4.0, 0.0), Vector3(7.0, 0.3, 6.0), deck_color)
	_append_box(tool, Vector3(0.0, 4.18, 2.88), Vector3(6.5, 0.08, 0.16), safety_color)
	for side_x in [-3.18, 3.18]:
		for post_z in [-2.45, 0.0, 2.35]:
			_append_box(tool, Vector3(side_x, 5.1, post_z), Vector3(0.13, 2.0, 0.13), rail_color)
		_append_box(tool, Vector3(side_x, 5.82, -0.05), Vector3(0.13, 0.13, 5.05), rail_color)
		_append_box(tool, Vector3(side_x, 4.95, -0.05), Vector3(0.1, 0.1, 5.05), rail_color)
	for post_x in [-3.18, 0.0, 3.18]:
		_append_box(tool, Vector3(post_x, 5.1, -2.78), Vector3(0.13, 2.0, 0.13), rail_color)
	_append_box(tool, Vector3(0.0, 5.82, -2.78), Vector3(6.5, 0.13, 0.13), rail_color)
	_append_box(tool, Vector3(0.0, 4.95, -2.78), Vector3(6.5, 0.1, 0.1), rail_color)
	_append_box(tool, Vector3(-2.45, 4.38, 0.0), Vector3(0.4, 0.08, 5.5), safety_color)
	_append_box(tool, Vector3(2.45, 4.38, 0.0), Vector3(0.4, 0.08, 5.5), safety_color)


static func _append_ladder(tool: SurfaceTool) -> void:
	var ladder_color := Color("#AAB1AE")
	var rail_color := Color("#C6A952")
	for rail_x in [-0.55, 0.55]:
		_append_box(tool, Vector3(rail_x, 2.45, 3.04), Vector3(0.1, 4.2, 0.12), rail_color)
	for rung_index in range(9):
		var rung_y := 0.55 + float(rung_index) * 0.48
		_append_box(tool, Vector3(0.0, rung_y, 3.08), Vector3(1.05, 0.09, 0.12), ladder_color)


static func _append_weathering_streaks(tool: SurfaceTool) -> void:
	var streak_color := Color("#A89362")
	var streak_count := 8
	for index in range(streak_count):
		var angle := TAU * (float(index) + 0.35) / float(streak_count)
		var radius_bottom := 3.11
		var radius_top := 2.52
		var angle_half := 0.018
		var bottom_a := Vector3(cos(angle - angle_half) * radius_bottom, 0.62, sin(angle - angle_half) * radius_bottom)
		var bottom_b := Vector3(cos(angle + angle_half) * radius_bottom, 0.62, sin(angle + angle_half) * radius_bottom)
		var top_a := Vector3(cos(angle - angle_half) * radius_top, 2.55, sin(angle - angle_half) * radius_top)
		var top_b := Vector3(cos(angle + angle_half) * radius_top, 2.55, sin(angle + angle_half) * radius_top)
		var normal := Vector3(cos(angle), 0.0, sin(angle))
		_add_quad(tool, bottom_a, top_a, top_b, bottom_b, streak_color, normal)


static func _blade_point(section: Dictionary, chord_sign: float, depth_sign: float, angle: float) -> Vector3:
	var radius := float(section["radius"])
	var chord := float(section["chord"])
	var sweep := float(section["sweep"])
	var thickness := float(section["thickness"])
	var point := Vector3(sweep + chord * 0.5 * chord_sign, radius, thickness * 0.5 * depth_sign)
	return point.rotated(Vector3.BACK, angle)


static func _append_frustum_y(tool: SurfaceTool, bottom_y: float, top_y: float, bottom_radius: float, top_radius: float, segments: int, color: Color) -> void:
	for index in range(segments):
		var angle_a := TAU * float(index) / float(segments)
		var angle_b := TAU * float(index + 1) / float(segments)
		var bottom_a := Vector3(cos(angle_a) * bottom_radius, bottom_y, sin(angle_a) * bottom_radius)
		var bottom_b := Vector3(cos(angle_b) * bottom_radius, bottom_y, sin(angle_b) * bottom_radius)
		var top_a := Vector3(cos(angle_a) * top_radius, top_y, sin(angle_a) * top_radius)
		var top_b := Vector3(cos(angle_b) * top_radius, top_y, sin(angle_b) * top_radius)
		_add_quad(tool, bottom_a, top_a, top_b, bottom_b, color, Vector3(cos((angle_a + angle_b) * 0.5), 0.0, sin((angle_a + angle_b) * 0.5)))
	var top_center := Vector3(0.0, top_y, 0.0)
	var bottom_center := Vector3(0.0, bottom_y, 0.0)
	for index in range(segments):
		var angle_a := TAU * float(index) / float(segments)
		var angle_b := TAU * float(index + 1) / float(segments)
		var top_a := Vector3(cos(angle_a) * top_radius, top_y, sin(angle_a) * top_radius)
		var top_b := Vector3(cos(angle_b) * top_radius, top_y, sin(angle_b) * top_radius)
		var bottom_a := Vector3(cos(angle_a) * bottom_radius, bottom_y, sin(angle_a) * bottom_radius)
		var bottom_b := Vector3(cos(angle_b) * bottom_radius, bottom_y, sin(angle_b) * bottom_radius)
		_add_triangle(tool, top_center, top_b, top_a, color, Vector3.UP)
		_add_triangle(tool, bottom_center, bottom_a, bottom_b, color, Vector3.DOWN)


static func _append_cylinder_y(tool: SurfaceTool, bottom_y: float, top_y: float, radius_bottom: float, radius_top: float, segments: int, color: Color) -> void:
	_append_frustum_y(tool, bottom_y, top_y, radius_bottom, radius_top, segments, color)


static func _append_cylinder_z(tool: SurfaceTool, center: Vector3, radius: float, length: float, segments: int, color: Color) -> void:
	var z_min := center.z - length * 0.5
	var z_max := center.z + length * 0.5
	for index in range(segments):
		var angle_a := TAU * float(index) / float(segments)
		var angle_b := TAU * float(index + 1) / float(segments)
		var a := Vector3(center.x + cos(angle_a) * radius, center.y + sin(angle_a) * radius, z_min)
		var b := Vector3(center.x + cos(angle_a) * radius, center.y + sin(angle_a) * radius, z_max)
		var c := Vector3(center.x + cos(angle_b) * radius, center.y + sin(angle_b) * radius, z_max)
		var d := Vector3(center.x + cos(angle_b) * radius, center.y + sin(angle_b) * radius, z_min)
		_add_quad(tool, a, d, c, b, color, Vector3(cos((angle_a + angle_b) * 0.5), sin((angle_a + angle_b) * 0.5), 0.0))


static func _append_box(tool: SurfaceTool, center: Vector3, size: Vector3, color: Color) -> void:
	var half := size * 0.5
	var p000 := center + Vector3(-half.x, -half.y, -half.z)
	var p001 := center + Vector3(-half.x, -half.y, half.z)
	var p010 := center + Vector3(-half.x, half.y, -half.z)
	var p011 := center + Vector3(-half.x, half.y, half.z)
	var p100 := center + Vector3(half.x, -half.y, -half.z)
	var p101 := center + Vector3(half.x, -half.y, half.z)
	var p110 := center + Vector3(half.x, half.y, -half.z)
	var p111 := center + Vector3(half.x, half.y, half.z)
	_add_quad(tool, p100, p110, p111, p101, color, Vector3.RIGHT)
	_add_quad(tool, p000, p001, p011, p010, color, Vector3.LEFT)
	_add_quad(tool, p010, p011, p111, p110, color, Vector3.UP)
	_add_quad(tool, p000, p100, p101, p001, color, Vector3.DOWN)
	_add_quad(tool, p001, p101, p111, p011, color, Vector3.BACK)
	_add_quad(tool, p000, p010, p110, p100, color, Vector3.FORWARD)


static func _add_quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color, expected_normal: Vector3) -> void:
	var actual_normal := (b - a).cross(c - a)
	if actual_normal.length_squared() > 0.000001 and actual_normal.dot(expected_normal) < 0.0:
		_add_triangle(tool, a, d, c, color, expected_normal)
		_add_triangle(tool, a, c, b, color, expected_normal)
	else:
		_add_triangle(tool, a, b, c, color, expected_normal)
		_add_triangle(tool, a, c, d, color, expected_normal)


static func _add_triangle(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color, expected_normal: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	if expected_normal.length_squared() > 0.0 and normal.dot(expected_normal) < 0.0:
		normal = -normal
	tool.set_color(color)
	tool.set_normal(normal)
	tool.add_vertex(a)
	tool.set_color(color)
	tool.set_normal(normal)
	tool.add_vertex(b)
	tool.set_color(color)
	tool.set_normal(normal)
	tool.add_vertex(c)
