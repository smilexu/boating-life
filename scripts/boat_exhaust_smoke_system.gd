class_name BoatExhaustSmokeSystem
extends Node3D

## Speed-scaled, world-space exhaust puffs for the starter cargo boat.
## The socket follows the visual hull, while emitted particles remain behind
## in world space so movement naturally forms a short, dissipating trail.

@export_category("References")
@export_node_path("Node3D") var boat_motion_path := NodePath("../..")
@export_node_path("Marker3D") var exhaust_socket_path := NodePath("../BoatModelFrame/ExhaustSocket")

@export_category("Smoke")
@export_range(0.0, 2.0, 0.05) var stopped_speed_threshold_mps := 0.25
@export_range(1.0, 20.0, 0.5) var full_smoke_speed_mps := 12.0
@export_range(0.0, 0.25, 0.01) var outlet_clearance_m := 0.06
@export_range(16, 128, 8) var particle_budget := 64
@export_range(0.8, 5.0, 0.1) var particle_lifetime_seconds := 2.6
@export_range(0.1, 3.0, 0.1) var response_speed := 2.4

const SPEED_MIN_SCALE := Vector2(0.14, 0.25)
const SPEED_MAX_SCALE := Vector2(0.25, 0.43)
const SPEED_MIN_UPDRAFT := Vector2(0.35, 0.55)
const SPEED_MAX_UPDRAFT := Vector2(0.75, 1.15)
const EMISSION_RATIO_RANGE := Vector2(0.10, 0.74)

var _boat: BoatController
var _exhaust_socket: Marker3D
var _particles: GPUParticles3D
var _process_material: ParticleProcessMaterial
var _smoothed_speed_factor := 0.0
var _particle_system_live := false


func _ready() -> void:
	_boat = get_node_or_null(boat_motion_path) as BoatController
	_exhaust_socket = get_node_or_null(exhaust_socket_path) as Marker3D
	if _boat == null:
		push_error("BoatExhaustSmokeSystem could not find BoatController at %s." % boat_motion_path)
		set_process(false)
		return
	if _exhaust_socket == null:
		push_error("BoatExhaustSmokeSystem could not find exhaust socket at %s." % exhaust_socket_path)
		set_process(false)
		return
	_create_particles()


func _process(delta: float) -> void:
	if _boat == null or _exhaust_socket == null or _particles == null:
		return
	if _boat.is_port_docked or _boat.is_motion_paused or absf(_boat.speed_mps) <= stopped_speed_threshold_mps:
		_stop_and_clear_smoke()
		return

	var speed_mps := absf(_boat.speed_mps)
	var raw_speed_factor := clampf(
		(speed_mps - stopped_speed_threshold_mps)
		/ maxf(full_smoke_speed_mps - stopped_speed_threshold_mps, 0.1),
		0.0,
		1.0
	)
	var target_speed_factor := raw_speed_factor * raw_speed_factor * (3.0 - 2.0 * raw_speed_factor)
	_smoothed_speed_factor = lerpf(
		_smoothed_speed_factor,
		target_speed_factor,
		1.0 - exp(-response_speed * delta)
	)

	_update_particle_transform()
	_update_speed_response()
	if not _particle_system_live:
		_particles.restart()
		_particles.visible = true
		_particle_system_live = true
	_particles.emitting = true


func _create_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "WorldSpaceExhaustPuffs"
	_particles.amount = particle_budget
	_particles.amount_ratio = 0.0
	_particles.lifetime = particle_lifetime_seconds
	_particles.one_shot = false
	_particles.local_coords = false
	_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.visibility_aabb = AABB(Vector3(-32.0, -3.0, -32.0), Vector3(64.0, 20.0, 64.0))
	_particles.emitting = false
	_particles.visible = false
	add_child(_particles)

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_particles.draw_pass_1 = quad

	var smoke_material := StandardMaterial3D.new()
	smoke_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	smoke_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	smoke_material.roughness = 1.0
	# The ocean is alpha blended too; draw smoke after its transparent pass so
	# the water layer does not cut away puffs that are above the surface.
	smoke_material.render_priority = 14
	smoke_material.albedo_texture = _make_soft_smoke_texture()
	quad.material = smoke_material

	_process_material = ParticleProcessMaterial.new()
	_process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_process_material.emission_box_extents = Vector3(0.045, 0.025, 0.045)
	_process_material.direction = Vector3.UP
	_process_material.spread = 13.0
	_process_material.initial_velocity_min = SPEED_MIN_UPDRAFT.x
	_process_material.initial_velocity_max = SPEED_MAX_UPDRAFT.x
	_process_material.gravity = Vector3(0.0, 0.13, 0.0)
	_process_material.linear_accel_min = -0.06
	_process_material.linear_accel_max = 0.12
	_process_material.inherit_velocity_ratio = 0.0
	_process_material.lifetime_randomness = 0.24
	_process_material.scale_min = SPEED_MIN_SCALE.x
	_process_material.scale_max = SPEED_MAX_SCALE.x
	_process_material.scale_curve = _make_scale_curve()
	_process_material.color_ramp = _make_color_ramp()
	_particles.process_material = _process_material
	_particles.global_transform = Transform3D(
		Basis.IDENTITY,
		_exhaust_socket.global_position + Vector3.UP * outlet_clearance_m
	)


func _update_particle_transform() -> void:
	# Keep the source above the exhaust outlet but make the plume rise in world-up,
	# independent of the boat's pitch, roll, or reverse heading.
	_particles.global_transform = Transform3D(
		Basis.IDENTITY,
		_exhaust_socket.global_position + Vector3.UP * outlet_clearance_m
	)


func _update_speed_response() -> void:
	var factor := clampf(_smoothed_speed_factor, 0.0, 1.0)
	_particles.amount_ratio = lerpf(EMISSION_RATIO_RANGE.x, EMISSION_RATIO_RANGE.y, factor)
	_process_material.scale_min = lerpf(SPEED_MIN_SCALE.x, SPEED_MIN_SCALE.y, factor)
	_process_material.scale_max = lerpf(SPEED_MAX_SCALE.x, SPEED_MAX_SCALE.y, factor)
	_process_material.initial_velocity_min = lerpf(SPEED_MIN_UPDRAFT.x, SPEED_MIN_UPDRAFT.y, factor)
	_process_material.initial_velocity_max = lerpf(SPEED_MAX_UPDRAFT.x, SPEED_MAX_UPDRAFT.y, factor)


func _stop_and_clear_smoke() -> void:
	if _particles == null or not _particle_system_live:
		return
	_particles.emitting = false
	_particles.amount_ratio = 0.0
	# The boat stops without leaving a lingering plume around it.
	_particles.restart()
	_particles.visible = false
	_particle_system_live = false
	_smoothed_speed_factor = 0.0


func _make_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.48))
	curve.add_point(Vector2(0.18, 0.78))
	curve.add_point(Vector2(0.62, 1.0))
	curve.add_point(Vector2(1.0, 1.35))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


func _make_color_ramp() -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.66, 0.68, 0.70, 0.04))
	gradient.add_point(0.05, Color(0.66, 0.68, 0.70, 0.12))
	gradient.add_point(0.56, Color(0.71, 0.73, 0.75, 0.10))
	gradient.set_color(gradient.get_point_count() - 1, Color(0.75, 0.77, 0.79, 0.0))
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


func _make_soft_smoke_texture() -> ImageTexture:
	const TEXTURE_SIZE := 48
	var image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(TEXTURE_SIZE):
		for x in range(TEXTURE_SIZE):
			var uv := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(TEXTURE_SIZE)
			var centered := (uv - Vector2(0.5, 0.5)) * 2.0
			var radius := centered.length()
			var soft_edge := 1.0 - smoothstep(0.28, 1.0, radius)
			var lobes := 0.90 + 0.10 * sin(uv.x * 17.0 + uv.y * 11.0) * sin(uv.y * 15.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(soft_edge * lobes, 0.0, 1.0)))
	return ImageTexture.create_from_image(image)
