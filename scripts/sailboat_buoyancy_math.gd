extends RefCounted
## Pure helpers used by the calm-water sailboat prototype and its offline tests.


static func equilibrium_spring_stiffness_n_per_m(
	mass_kg: float,
	gravity_mps2: float,
	rest_submergence_m: float,
	point_count: int,
	strength: float = 1.0
) -> float:
	if not _finite(mass_kg) or not _finite(gravity_mps2) or not _finite(rest_submergence_m) or not _finite(strength):
		return 0.0
	if mass_kg <= 0.0 or gravity_mps2 <= 0.0 or rest_submergence_m <= 0.0 or point_count <= 0:
		return 0.0
	return mass_kg * gravity_mps2 * clampf(strength, 0.0, 2.0) / (float(point_count) * rest_submergence_m)


static func critical_point_damping_n_s_per_m(
	stiffness_n_per_m: float,
	mass_kg: float,
	point_count: int,
	damping_ratio: float
) -> float:
	if not _finite(stiffness_n_per_m) or not _finite(mass_kg) or not _finite(damping_ratio):
		return 0.0
	if stiffness_n_per_m <= 0.0 or mass_kg <= 0.0 or point_count <= 0:
		return 0.0
	var effective_mass_kg := mass_kg / float(point_count)
	return 2.0 * clampf(damping_ratio, 0.0, 2.0) * sqrt(stiffness_n_per_m * effective_mass_kg)


static func max_point_force_n(mass_kg: float, gravity_mps2: float, point_count: int, safety_ratio: float) -> float:
	if not _finite(mass_kg) or not _finite(gravity_mps2) or not _finite(safety_ratio):
		return 0.0
	if mass_kg <= 0.0 or gravity_mps2 <= 0.0 or point_count <= 0:
		return 0.0
	return mass_kg * gravity_mps2 * clampf(safety_ratio, 1.0, 3.0) / float(point_count)


static func point_buoyancy_force_n(
	submergence_m: float,
	point_vertical_velocity_mps: float,
	stiffness_n_per_m: float,
	damping_n_s_per_m: float,
	maximum_force_n: float
) -> float:
	if not _finite(submergence_m) or not _finite(point_vertical_velocity_mps):
		return 0.0
	if not _finite(stiffness_n_per_m) or not _finite(damping_n_s_per_m) or not _finite(maximum_force_n):
		return 0.0
	# A dry point has no buoyancy or fluid damping. In particular, the damping term
	# must not pull an unimmersed point upward while it is moving down through air.
	if submergence_m <= 0.0 or stiffness_n_per_m <= 0.0 or maximum_force_n <= 0.0:
		return 0.0
	var spring_force_n := stiffness_n_per_m * submergence_m
	var damping_force_n := maxf(damping_n_s_per_m, 0.0) * point_vertical_velocity_mps
	return clampf(spring_force_n - damping_force_n, 0.0, maximum_force_n)


static func point_offset_world(body_basis: Basis, local_offset: Vector3) -> Vector3:
	return body_basis * local_offset


static func _finite(value: float) -> bool:
	return is_finite(value)
