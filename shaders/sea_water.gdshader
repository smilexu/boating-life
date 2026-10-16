// Derived from Boujie Water Shader by Zach Bernal and contributors.
// Source commit: 25f3c2da458e0a4f65bdb5903dc068b050930c06 (MIT; see addon LICENSE.md).
// Local performance variant: refraction, depth fog, foam, shore foam, and Snell's window are disabled.

shader_type spatial;

render_mode blend_mix,depth_draw_always,cull_disabled,diffuse_burley,specular_schlick_ggx,world_vertex_coords;

#define WORLD_TRIPLANAR

#define ALBEDO_WAVE
#define VERTEX_WAVE
#define FRESNEL

// Fade out features with distance from camera
#define DISTANCE_FADE // fade ALPHA, then drop at 0
#define VERTEX_WAVE_FADE

uniform bool freeze_time = false; // Toki wo tomare.
uniform vec4 albedo: source_color;
uniform vec4 albedo_fresnel: source_color;
uniform sampler2D texture_albedo: source_color;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
// Fine surface texture only affects shading; it is not part of hull buoyancy.
uniform float ripple_scale : hint_range(0.02, 0.5) = 0.17;
uniform float ripple_speed : hint_range(0.0, 1.0) = 0.08;
uniform vec2 ripple_direction = vec2(0.87, 0.49);
// Shading-only normal blend; vertex displacement and CPU WaveSampler stay unchanged.
uniform float wave_normal_strength : hint_range(0.0, 1.0) = 0.45;
uniform float detail_wave_fade_start : hint_range(0.0, 5000.0) = 80.0;
uniform float detail_wave_fade_end : hint_range(0.0, 5000.0) = 850.0;
uniform float detail_normal_strength_near : hint_range(0.0, 5.0) = 0.8;
uniform float detail_normal_strength_far : hint_range(0.0, 1.0) = 0.0;
uniform float sun_glitter_intensity : hint_range(0.0, 2.0) = 0.72;
uniform float water_roughness_near : hint_range(0.0, 1.0) = 0.10;
uniform float water_roughness_far : hint_range(0.0, 1.0) = 0.34;
uniform float water_specular_near_multiplier : hint_range(0.0, 1.0) = 0.72;
uniform float water_specular_far_multiplier : hint_range(0.0, 1.0) = 0.62;
// Small night-only surface lift keeps deep water readable when the sky stops
// contributing daylight. It adds no pass or texture fetch and leaves daytime
// albedo/reflection unchanged at night_visual_weight = 0.
uniform float night_visual_weight : hint_range(0.0, 1.0) = 0.0;
uniform vec3 night_surface_lift = vec3(0.010, 0.024, 0.052);
uniform float night_specular_scale : hint_range(0.0, 1.0) = 0.68;
uniform float night_roughness_target : hint_range(0.05, 0.5) = 0.20;
uniform float albedo_detail_fade_start : hint_range(0.0, 5000.0) = 250.0;
uniform float albedo_detail_fade_end : hint_range(0.0, 5000.0) = 2200.0;

/* When ON - vertex waves rise along the mesh's normal
 * When OFF - vertex waves rise in the global up direction (+y)
 */
uniform bool vertex_displace_from_mesh_normal;
/* When ON - normal waves rise along the mesh's normal
 * When OFF - normal waves rise in the global up direction (+y)
 */
uniform bool normal_wave_from_mesh_normal;

group_uniforms Refraction;
uniform sampler2D texture_refraction;
uniform float refraction : hint_range(-2,2);
uniform vec4 refraction_texture_channel;
uniform float refraction_opacity : hint_range(0.0, 1.0);
group_uniforms;

group_uniforms Foam;
uniform sampler2D texture_foam: source_color;
uniform float shore_start_blend;
uniform float shore_end_blend;
group_uniforms;

group_uniforms DistanceFade;
uniform float distance_fade_min;
uniform float distance_fade_max;
group_uniforms;

group_uniforms FeatureFade;
uniform float near_fade_min;
uniform float near_fade_max;
uniform float foam_fade_min;
uniform float foam_fade_max;
uniform float shore_fade_min;
uniform float shore_fade_max;
uniform float vertex_wave_fade_min;
uniform float vertex_wave_fade_max; 
uniform float depth_fog_fade_min;
uniform float depth_fog_fade_max; 
uniform float refraction_scaling_distance_min; // no max - refraction falls off proportionally starting from this distance
group_uniforms;

group_uniforms WorldTriplanarUvs;
uniform float uv_blend_sharpness;
uniform vec3 uv_tri_scale;
uniform vec3 uv_tri_offset;
group_uniforms;

group_uniforms DepthFog;
uniform vec4 color_deep : source_color;
uniform vec4 color_shallow : source_color;
uniform float beers_law = 2.0;
uniform float depth_offset = -0.75;
group_uniforms;

group_uniforms BathymetryColor;
uniform sampler2D bathymetry_depth_texture : filter_linear, repeat_disable;
uniform bool enable_depth_color = true;
uniform vec4 bathymetry_bounds_east_north = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 shallow_water_color : source_color = vec4(0.22, 0.62, 0.48, 1.0);
uniform vec4 mid_water_color : source_color = vec4(0.06, 0.42, 0.46, 1.0);
uniform vec4 blue_water_color : source_color = vec4(0.04, 0.30, 0.44, 1.0);
uniform float depth_color_strength : hint_range(0.0, 1.0) = 0.60;
uniform float valid_coverage_min : hint_range(0.0, 1.0) = 0.20;
uniform float valid_coverage_max : hint_range(0.0, 1.0) = 0.80;
uniform float shallow_depth_threshold : hint_range(0.0, 10.0) = 2.0;
uniform float mid_depth_threshold : hint_range(0.1, 15.0) = 5.0;
uniform float blue_depth_threshold : hint_range(0.2, 20.0) = 10.0;
uniform float deep_depth_threshold : hint_range(1.0, 80.0) = 20.0;
// 0=full, 1=flat base, 2=waves/no albedo pattern/no bathymetry,
// 3=waves/no albedo pattern/with bathymetry, 4=normal, 5=Fresnel,
// 6=depth validity, 7=diffuse/shadows only, 8=specular/reflection only,
// 9=diffuse with flat normal, 10=specular with flat normal, 11=full with flat normal,
// 12=flat color while preserving the configured alpha fades,
// 13=shallow-transmission weight (red) and valid bathymetry (green).
uniform int water_diagnostic_mode = 0;
group_uniforms;

group_uniforms ShallowTransparency;
// Kept off by the shader default as a safe fallback; the production material opts in.
uniform bool shallow_transparency_enabled = false;
uniform float shallow_max_depth : hint_range(0.0, 20.0) = 6.0;
uniform float shallow_fade_start : hint_range(0.0, 20.0) = 4.0;
uniform float shallow_min_alpha : hint_range(0.0, 1.0) = 0.62;
uniform float shallow_transmission_strength : hint_range(0.0, 1.0) = 0.60;
// Mildly attenuates bottom visibility along the estimated surface-to-bottom
// view path; grazing angles lengthen that path and preserve surface reflection.
uniform float shallow_absorption_per_meter : hint_range(0.0, 0.25) = 0.06;
// The bathymetry grid is measured below LAT; align its vertical path with the
// visual water plane used by ShallowSeabedManager.
uniform float shallow_surface_above_lat_m : hint_range(0.0, 2.0) = 0.5;
// Allows for chart datum, wave height and modest bottom relief without exposing
// objects that are clearly deeper than the local water column.
uniform float shallow_bottom_depth_padding : hint_range(0.0, 5.0) = 1.5;
group_uniforms;

group_uniforms SnellWindow;
uniform vec4 albedo_snell: source_color;
uniform vec3 snell_direction = vec3(0.0, 1.0, 0.0);
uniform float snell_tightness : hint_range(0.0, 1.0) = 0.7;
group_uniforms;

group_uniforms WaveParameters;
uniform int WaveCount : hint_range(0,8) = 0;
uniform float WaveSteepnesses[8];
uniform float WaveAmplitudes[8];
uniform float WaveDirectionsDegrees[8];
uniform float WaveFrequencies[8];
uniform float WaveSpeeds[8];
uniform float WavePhases[8];
uniform float WaveTime = 0.0;
group_uniforms;

group_uniforms FoamWaveParameters;
uniform int FoamWaveCount : hint_range(0,8) = 0;
uniform float FoamWaveSteepnesses[8];
uniform float FoamWaveAmplitudes[8];
uniform float FoamWaveDirectionsDegrees[8];
uniform float FoamWaveFrequencies[8];
uniform float FoamWaveSpeeds[8];
uniform float FoamWavePhases[8];
group_uniforms;

group_uniforms UVWaveParameters;
uniform int UVWaveCount : hint_range(0,8) = 0;
uniform float UVWaveSteepnesses[8];
uniform float UVWaveAmplitudes[8];
uniform float UVWaveDirectionsDegrees[8];
uniform float UVWaveFrequencies[8];
uniform float UVWaveSpeeds[8];
uniform float UVWavePhases[8];
group_uniforms;


uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying vec3	uv_tri;
varying vec2	refraction_uv;
varying vec3	refraction_uv_tri;
varying vec3	uv_power_normal;
varying float	foam_alpha;

varying vec3	world_coordinates;

float fresnel(float amount, vec3 normal, vec3 view)
{
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0 )), amount);
}

float snell(float amount, vec3 normal, vec3 view)
{
	return step(amount, clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0 ));
}

// An offset at a point on a Gerstner Wave
/*
 * x & z: wave position
 * t: time
 * Steepness: physical height of the wave. Up and down particle motion.
 * Amplitude: also height, but affects the normal more. Fore and aft particle motion.
 * Direction, Frequency, Speed: self explanatory
 */
vec3 P_DEG(float x, float z, float t, float Steepness, float Amplitude, float DirectionDegrees, float Frequency, float Speed, float PhaseDegrees) {
	vec2 Direction = vec2( sin(DirectionDegrees * TAU / 360.0), cos(DirectionDegrees * TAU / 360.0 ));
	float p = PhaseDegrees * TAU / 360.0;
	vec3 result;
	result.x = ((Steepness * Amplitude) * Direction.x * cos(TAU * dot(Frequency * Direction, vec2(x, z)) + (Speed * (t+p))));
	result.y = Steepness * sin(TAU * dot(Frequency * Direction, vec2(x, z)) + (Speed * (t+p)));
	result.z = ((Steepness * Amplitude) * Direction.y * cos(TAU * dot(Frequency * Direction, vec2(x, z)) + (Speed * (t+p))));
	
	return result;
}

vec3 N_DEG(float x, float z, float t, float Steepness, float Amplitude, float DirectionDegrees, float Frequency, float Speed, float PhaseDegrees) {
	vec2 Direction = vec2( sin(DirectionDegrees * TAU / 360.0), cos(DirectionDegrees * TAU / 360.0 ));
	float p = PhaseDegrees * TAU / 360.0;
	vec3 result;
	result.x = (-1.0) * (Direction.x * Frequency * Amplitude * (cos((Frequency * TAU * dot(Direction, vec2(x, z))) + Speed * (t+p))));
	result.y = 1.0 - (Steepness * Frequency * Amplitude * sin((Frequency * TAU * dot(Direction, vec2(x, z))) + Speed * (t+p)));
	result.z = (-1.0) * (Direction.y * Frequency * Amplitude * (cos((Frequency * TAU * dot(Direction, vec2(x, z))) + Speed * (t+p))));
	
	return result;
}

// Rotate a vector from vec3(0,1,0) to the normal, rotation about the z and y axes.
vec3 rotate_to_normal(vec3 point, vec3 normal)
{
	float theta = atan(normal.z, normal.x);
	if (abs(normal.z) < 0.0001 && abs(normal.x) < 0.0001) {
		theta = 0.0;
	}
	float phi = acos(normal.y);
	float ct = cos(theta);
	float st = sin(theta);
	float cp = cos(phi);
	float sp = sin(phi);
	// column major. okay, deep breaths. I got this.
//	mat3 rot = mat3( vec3(cp*ct, sp*ct,-st), vec3(-sp,cp,0), vec3(cp*st,sp*st,ct));
	// huh. let's try row major instead. okay I guess that works?
	mat3 rot = mat3( vec3(cp*ct, -sp, cp*st), vec3(sp*ct, cp, sp*st), vec3(-st, 0, ct));
	vec3 newpoint = rot*point;
	return newpoint;
}

void vertex() {
	float time = WaveTime * float(!freeze_time);
	
	
	// UV will be assigned based on xz world coords
	// Zach, VERTEX is in world coords now! world_vertex_coords render mode!
	world_coordinates = VERTEX;
	// Keep UV based on world XZ around as inputs to various wave functions
	vec2 wave_coords = world_coordinates.xz;
	// Need camera pos for distance testing
 	vec3 world_camera_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float distance_from_camera = distance(world_coordinates, world_camera_pos);
	
	
#ifdef WORLD_TRIPLANAR
	// Define triplanar UV
	uv_power_normal=pow(abs(NORMAL),vec3(uv_blend_sharpness));
	uv_power_normal/=dot(uv_power_normal,vec3(1.0));
	uv_tri = (world_coordinates).xyz / uv_tri_scale + uv_tri_offset;
	uv_tri *= vec3(1.0,-1.0, 1.0);
	UV = uv_tri.xz;
#endif

	// Apply some wavey movement to the general UV coords
#ifdef ALBEDO_WAVE
	vec3 uvwave = vec3(0,0,0);
	for (int i = 0; i < UVWaveCount; i++) {
		uvwave += P_DEG(UV.x, UV.y, time, UVWaveSteepnesses[i], UVWaveAmplitudes[i], UVWaveDirectionsDegrees[i], UVWaveFrequencies[i], UVWaveSpeeds[i], UVWavePhases[i]);
	}
	uv_tri += uvwave;

	UV += uvwave.xz;
#endif
	
	
	// Apply some constant movement 
#ifdef WORLD_TRIPLANAR
	refraction_uv_tri = uv_tri;
	refraction_uv_tri += vec3(0.1, -0.2, -0.15) * time;
	uv_tri += vec3(0.1) * time;
#else
	refraction_uv = UV;
	refraction_uv += vec2(0.1, 0.2) * time;
#endif
	UV += vec2(0.1)* time;
	
	// Calculate foam alpha in vertex where it's cheaper
#ifdef FOAM
	vec3 foamVertexWave = vec3(0,0,0);
	for (int i = 0; i < FoamWaveCount; i++) {
		foamVertexWave += P_DEG(wave_coords.x, wave_coords.y, time, FoamWaveSteepnesses[i], FoamWaveAmplitudes[i], FoamWaveDirectionsDegrees[i], FoamWaveFrequencies[i], FoamWaveSpeeds[i], FoamWavePhases[i]);
	}
	foamVertexWave = foamVertexWave / float(FoamWaveCount);
	foam_alpha = foamVertexWave.y;
#else
	foam_alpha = 0.0;
#endif
	
	float vertex_fade_alpha = 1.0;
#ifdef VERTEX_WAVE_FADE
	vertex_fade_alpha = smoothstep(vertex_wave_fade_max, vertex_wave_fade_min, distance_from_camera);
#endif
	
	// Calculate offset for every wave, take average
#ifdef VERTEX_WAVE
	vec3 vertexWave = vec3(0,0,0);
	for (int i = 0; i < WaveCount; i++) {
		vertexWave += P_DEG(wave_coords.x, wave_coords.y, time, WaveSteepnesses[i], WaveAmplitudes[i], WaveDirectionsDegrees[i], WaveFrequencies[i], WaveSpeeds[i], WavePhases[i]);
	}
	vertexWave = vertexWave / float(WaveCount);
	if (vertex_displace_from_mesh_normal) {
		vertexWave = rotate_to_normal(vertexWave, NORMAL);
	}
	vertexWave *= vertex_fade_alpha;
	if (WaveCount > 0) {
		VERTEX += vertexWave;
	}
	
	// Calculate normal for each wave, take average
	vec3 normalWave = vec3(0,0,0);
	for (int i = 0; i < WaveCount; i++) {
		normalWave += N_DEG(wave_coords.x, wave_coords.y, time, WaveSteepnesses[i], WaveAmplitudes[i], WaveDirectionsDegrees[i], WaveFrequencies[i], WaveSpeeds[i], WavePhases[i]);
	}
	normalWave = normalize(normalWave / float(WaveCount));
	if (normal_wave_from_mesh_normal) {
		normalWave = rotate_to_normal(normalWave, NORMAL);
	}
	normalWave = mix(NORMAL, normalWave, vertex_fade_alpha);
	if (WaveCount > 0) {
		NORMAL = normalize(normalWave);
	}
#endif

	// DEBUG: increase vertex height based on distance from center
	//VERTEX.y += 0.1 * (wave_coords.x + wave_coords.y);
	
	// refresh world_coordinates with updated position
	world_coordinates = VERTEX;
}

vec4 triplanar_texture(sampler2D p_sampler,vec3 p_weights,vec3 p_triplanar_pos) {
	vec4 samp=vec4(0.0);
	samp+= texture(p_sampler,p_triplanar_pos.xy) * p_weights.z;
	samp+= texture(p_sampler,p_triplanar_pos.xz) * p_weights.y;
	samp+= texture(p_sampler,p_triplanar_pos.zy * vec2(-1.0,1.0)) * p_weights.x;
	return samp;
}

float water_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Non-periodic value noise plus its analytic X/Y gradient. The quintic
// interpolation keeps cell boundaries smooth without a tiled normal texture.
vec3 water_value_noise_gradient(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f - 1.0) * (f - 1.0);

	float n00 = water_hash(cell);
	float n10 = water_hash(cell + vec2(1.0, 0.0));
	float n01 = water_hash(cell + vec2(0.0, 1.0));
	float n11 = water_hash(cell + vec2(1.0, 1.0));
	float row0 = mix(n00, n10, u.x);
	float row1 = mix(n01, n11, u.x);
	float value = mix(row0, row1, u.y);
	float gradient_x = mix((n10 - n00) * du.x, (n11 - n01) * du.x, u.y);
	float gradient_y = (row1 - row0) * du.y;
	return vec3(value, gradient_x, gradient_y);
}

vec3 water_detail_fbm(vec2 p) {
	vec3 layer_a = water_value_noise_gradient(p);
	vec3 layer_b = water_value_noise_gradient(p * 2.03 + vec2(17.1, 9.2));
	vec3 layer_c = water_value_noise_gradient(p * 4.11 + vec2(37.7, 23.4));
	float value = (layer_a.x - 0.5) * 0.62 + (layer_b.x - 0.5) * 0.27 + (layer_c.x - 0.5) * 0.11;
	vec2 gradient = layer_a.yz * 0.62 + layer_b.yz * (0.27 * 2.03) + layer_c.yz * (0.11 * 4.11);
	return vec3(value, gradient);
}

vec2 rotate_water_vector(vec2 value, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(c * value.x - s * value.y, s * value.x + c * value.y);
}

// Texture RG channels store 0–64 m depth and valid-water coverage. The texture
// is baked into the same local east/north frame as GeoReference and does not
// follow the camera-snapped ocean mesh.
vec2 sample_bathymetry(vec2 world_east_north) {
	vec2 extent = bathymetry_bounds_east_north.zw - bathymetry_bounds_east_north.xy;
	if (extent.x <= 0.0 || extent.y <= 0.0) {
		return vec2(64.0, 0.0);
	}
	vec2 uv = vec2(
		(world_east_north.x - bathymetry_bounds_east_north.x) / extent.x,
		(bathymetry_bounds_east_north.w - world_east_north.y) / extent.y
	);
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec2(64.0, 0.0);
	}
	vec2 encoded = textureLod(bathymetry_depth_texture, uv, 0.0).rg;
	return vec2(encoded.r * 64.0, encoded.g);
}

vec3 bathymetry_tint(float depth_m, vec3 base_color) {
	vec3 shallow_to_mid = mix(
		shallow_water_color.rgb,
		mid_water_color.rgb,
		smoothstep(shallow_depth_threshold, mid_depth_threshold, depth_m)
	);
	vec3 mid_to_blue = mix(
		shallow_to_mid,
		blue_water_color.rgb,
		smoothstep(mid_depth_threshold, blue_depth_threshold, depth_m)
	);
	return mix(
		mid_to_blue,
		base_color,
		smoothstep(blue_depth_threshold, deep_depth_threshold, depth_m)
	);
}

// Calculate depth of solid object beneath the water by reading the depth texture
float depth_from_water_to_object(vec2 screen_uv, mat4 inv_projection_matrix, vec3 vertex) {
	float depth_raw = textureLod(depth_texture, screen_uv, 0.0).r;
	// https://www.reddit.com/r/godot/comments/wb0jw7/godot_4_alpha_12_depth_texture_not_working/ii4awtb/
	// In Godot 4 Vulcan, depth_raw goes from 0 to 1 and doesn't need to be normalzied anymore!!! Holy smokes.
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, depth_raw); 
	vec4 view = inv_projection_matrix * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float z_depth = -view.z;
	float z_pos = -vertex.z;
	return z_depth - z_pos;
}


	/* Refraction
	 * How this works: we get the normal and multiply it by the refraction value & texture. More refraction means light is bent more away from normal's direction.
	 * we then grab the part of the screen texture (via it's UV coords) by shifting the regular Screen UV by our "enhanced" refraction normal.
	 * Refraction amount is how much light we are emitting from the other side. This is proportional to albedo opacity, and gated by refraction_opacity.
	 * Finally we do a lookup for the light value from the screen, taking surface roughness into account (lower roughness means higher detail)
	 * The light we get from the screen gets multiplied by the refraction amount, and then we emit it in EMISSION. It's a nice way to fake opacity.
	 * Albedo is darkened to compensate for the extra light coming from the screen behind this material.
	 */

void fragment() {
	ALPHA = 1.0;

	// Calculate distance from the camera to the water
#if defined(DISTANCE_FADE) || defined(FOAM_FADE) || defined (SHORE_FADE) || defined(DEPTH_FOG_FADE)
	float distance_from_camera = distance(CAMERA_POSITION_WORLD, world_coordinates);
#endif

	// Calculate new screen_uv from refraction texture and amount, which will be used by any screen reading code.
	vec2 screen_uv = SCREEN_UV;
#ifdef REFRACTION
	vec4 ref_tex;
#ifdef WORLD_TRIPLANAR
	ref_tex = triplanar_texture(texture_refraction, uv_power_normal, refraction_uv_tri);
#else
	ref_tex = texture(texture_refraction,refraction_uv);
#endif
	float r_final = refraction;
#ifdef REFRACTION_SCALING
	r_final *= clamp(refraction_scaling_distance_min / distance_from_camera, 0.0, 1.0);
#endif
	float ref_sample = dot(ref_tex, refraction_texture_channel);
	vec2 ref_uv_offset = (NORMAL.xy * ref_sample + ref_sample - 0.5) * r_final;
	screen_uv = SCREEN_UV - ref_uv_offset;
#endif

	// Some feature fades
	float foam_fade_alpha = 1.0;
	float shore_fade_alpha = 1.0;
#ifdef DISTANCE_FADE
	ALPHA *= smoothstep(distance_fade_max, distance_fade_min, distance_from_camera);
	ALPHA *= smoothstep(near_fade_min, near_fade_max, distance_from_camera);
#endif
#ifdef FOAM_FADE
	foam_fade_alpha = smoothstep(foam_fade_max, foam_fade_min, distance_from_camera);
#endif
#ifdef SHORE_FADE
	shore_fade_alpha = smoothstep(shore_fade_max, shore_fade_min, distance_from_camera);
#endif
	
	if (ALPHA <= 0.0) {
		discard;
	}
	METALLIC = metallic;
	float reflection_distance_fade = smoothstep(500.0, 2600.0, distance_from_camera);
	SPECULAR = specular * mix(water_specular_near_multiplier, water_specular_far_multiplier, reflection_distance_fade);
	ROUGHNESS = mix(water_roughness_near, water_roughness_far, reflection_distance_fade);
	SPECULAR *= mix(1.0, night_specular_scale, night_visual_weight);
	ROUGHNESS = mix(ROUGHNESS, max(ROUGHNESS, night_roughness_target), night_visual_weight);
	// NORMAL is in view space in fragment(). Blend toward world-up in the same
	// space so this changes lighting/reflection response only, not wave geometry.
	vec3 flat_water_normal_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	NORMAL = normalize(mix(flat_water_normal_view, NORMAL, wave_normal_strength));
	float detail_time = WaveTime * float(!freeze_time);
	vec2 detail_position = world_coordinates.xz;
	float detail_distance_fade = smoothstep(detail_wave_fade_start, detail_wave_fade_end, distance_from_camera);
	float detail_strength = mix(detail_normal_strength_near, detail_normal_strength_far, detail_distance_fade);
	vec2 drift_direction = normalize(ripple_direction + vec2(0.0001, 0.0));
	vec2 cross_direction = vec2(-drift_direction.y, drift_direction.x);
	vec2 drift_a = drift_direction * detail_time * ripple_speed;
	vec2 drift_b = cross_direction * detail_time * ripple_speed * 0.73;
	float rotation_a = 0.39;
	float rotation_b = -0.71;
	vec2 position_a = rotate_water_vector(detail_position + drift_a, rotation_a) * ripple_scale;
	vec2 position_b = rotate_water_vector(detail_position - drift_b, rotation_b) * (ripple_scale * 0.79) + vec2(31.7, 12.4);
	vec3 detail_a = water_detail_fbm(position_a);
	vec3 detail_b = water_detail_fbm(position_b);
	vec2 gradient_a = rotate_water_vector(detail_a.yz, -rotation_a) * ripple_scale;
	vec2 gradient_b = rotate_water_vector(detail_b.yz, -rotation_b) * (ripple_scale * 0.79);
	vec2 micro_slope = gradient_a * 0.64 + gradient_b * 0.36;
	vec3 micro_normal_offset_world = vec3(-micro_slope.x, 0.0, -micro_slope.y) * detail_strength * sun_glitter_intensity;
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(micro_normal_offset_world, 0.0)).xyz);
	
	vec4 albedo_tex;
#ifdef WORLD_TRIPLANAR
	albedo_tex = triplanar_texture(texture_albedo, uv_power_normal, uv_tri);
#else
	albedo_tex = texture(texture_albedo, UV);
#endif
	float albedo_detail_fade = 1.0 - smoothstep(albedo_detail_fade_start, albedo_detail_fade_end, distance_from_camera);
	vec3 albedo_detail = mix(vec3(1.0), albedo_tex.rgb, albedo_detail_fade);
	if (water_diagnostic_mode == 2 || water_diagnostic_mode == 3) {
		albedo_detail = vec3(1.0);
	}

	float final_refraction_opacity = refraction_opacity;
#ifdef FRESNEL
	float fresnel_factor = fresnel(3.0, NORMAL, VIEW);
	vec4 surface_color = mix(albedo, albedo_fresnel, fresnel_factor);
#else
	vec4 surface_color = albedo;
#endif

#ifdef SNELLS_WINDOW
	vec2 snell_offset = ref_uv_offset * 2.0;
	vec3 snell_normal = vec3(NORMAL.x - snell_offset.x, NORMAL.y - snell_offset.y, NORMAL.z);
	float snell_factor = snell(snell_tightness, snell_normal, VIEW);
	if (FRONT_FACING) {
		snell_factor = 1.0;
	}
	final_refraction_opacity *= snell_factor;
	final_refraction_opacity = clamp(final_refraction_opacity, 0.0, 1.0);
	surface_color = mix(albedo_snell, surface_color, snell_factor);
#endif

	bool use_depth_color = enable_depth_color;
	float bathymetry_depth_m = 64.0;
	float bathymetry_validity = 0.0;
	float shallow_transmission_weight = 0.0;
	float shallow_surface_alpha = 1.0;
	bool needs_bathymetry = enable_depth_color || shallow_transparency_enabled || water_diagnostic_mode == 6 || water_diagnostic_mode == 13;
	if (needs_bathymetry) {
		vec2 bathymetry = sample_bathymetry(vec2(world_coordinates.x, -world_coordinates.z));
		bathymetry_depth_m = bathymetry.x;
		bathymetry_validity = smoothstep(valid_coverage_min, valid_coverage_max, bathymetry.y);
	}
	if (water_diagnostic_mode == 1 || water_diagnostic_mode == 2) {
		use_depth_color = false;
	} else if (water_diagnostic_mode == 3) {
		use_depth_color = true;
	}
	if (use_depth_color && bathymetry_validity > 0.0) {
		vec3 depth_color = bathymetry_tint(bathymetry_depth_m, surface_color.rgb);
		surface_color.rgb = mix(surface_color.rgb, depth_color, depth_color_strength * bathymetry_validity);
	}

	// Shallow transmission is object-gated: valid 0–6 m water only becomes
	// translucent where the opaque depth buffer contains geometry within the
	// local water column. This preserves the original surface over open water.
	if (shallow_transparency_enabled && bathymetry_validity > 0.0 && bathymetry_depth_m < shallow_max_depth) {
		float depth_fade = 1.0 - smoothstep(shallow_fade_start, shallow_max_depth, bathymetry_depth_m);
		float view_incidence = max(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.20);
		float vertical_bottom_gap = max(bathymetry_depth_m + shallow_surface_above_lat_m - world_coordinates.y, 0.0);
		float expected_bottom_gap = vertical_bottom_gap / view_incidence;
		float path_transmission = exp(-shallow_absorption_per_meter * expected_bottom_gap);
		float object_gap = depth_from_water_to_object(SCREEN_UV, INV_PROJECTION_MATRIX, VERTEX);
		float object_is_below_surface = smoothstep(0.02, 0.18, object_gap);
		float bottom_limit_start = expected_bottom_gap + shallow_bottom_depth_padding;
		float bottom_limit_end = bottom_limit_start + max(shallow_bottom_depth_padding, 0.25);
		float object_is_near_bottom = 1.0 - smoothstep(bottom_limit_start, bottom_limit_end, object_gap);
		shallow_transmission_weight = clamp(
			depth_fade * shallow_transmission_strength * path_transmission * bathymetry_validity * object_is_below_surface * object_is_near_bottom,
			0.0,
			1.0
		);
		shallow_surface_alpha = mix(1.0, shallow_min_alpha, shallow_transmission_weight);
	}

	// Screen-reading shader features
	float screen_lod = 0.0;
	float screen_read_blend_amount = (1.0 - surface_color.a * albedo_tex.a);
#ifdef DEPTH_FOG
	float z_diff_refracted = depth_from_water_to_object(screen_uv, INV_PROJECTION_MATRIX, VERTEX);
	float depth_blend = exp((z_diff_refracted + depth_offset) * -beers_law);
	depth_blend = clamp(1.0 - depth_blend, 0.0, 1.0);
	float depth_blend_power = clamp(pow(depth_blend, 2.5), 0.0, 1.0);
#ifdef DEPTH_FOG_FADE
	depth_blend_power += smoothstep(depth_fog_fade_min, depth_fog_fade_max, distance_from_camera);
	depth_blend_power = clamp(depth_blend_power, 0.0, 1.0);
#endif	
	screen_lod += depth_blend_power * 2.5;
#endif

#ifdef REFRACTION
	screen_read_blend_amount *= final_refraction_opacity;
	screen_lod += ROUGHNESS * 8.0;
#endif

	// Read the screen for screen-reading shader features
#if defined(REFRACTION) || defined(DEPTH_FOG)
	vec3 screen_color = textureLod(screen_texture, screen_uv, screen_lod).rgb;
#endif

	// Blend the screen color with depth fade
#ifdef DEPTH_FOG
	vec3 shallow_screen_color = mix(screen_color, color_shallow.rgb, color_shallow.a);
	vec3 deep_screen_color = mix(screen_color, color_deep.rgb, color_deep.a);
	if (FRONT_FACING) {
		screen_color = mix(shallow_screen_color, deep_screen_color, depth_blend_power);
	}
#endif

	// Finally write color to the screen. Screen-reading shaders use EMISSION to simulate ALPHA.
#if defined(REFRACTION) || defined(DEPTH_FOG)
	ALBEDO = surface_color.rgb * albedo_detail;
	EMISSION += screen_color * screen_read_blend_amount;
	ALBEDO *= 1.0 - screen_read_blend_amount;
	// don't set ALPHA here
#else
	ALBEDO = surface_color.rgb * albedo_detail;
	ALPHA *= surface_color.a * albedo_tex.a;
#endif
	if (shallow_transparency_enabled && water_diagnostic_mode == 0) {
		ALPHA *= shallow_surface_alpha;
	}

	/* Sea Foam
	 * override refraction and add to albedo
	 * scale foam opacity based on a given set of waves. 
	 */

#if defined(FOAM) || defined(SHORE_FOAM)
	vec4 foam_tex;
#ifdef WORLD_TRIPLANAR
	foam_tex = triplanar_texture(texture_foam, uv_power_normal, uv_tri);
#else
	foam_tex = texture(texture_foam, UV);
#endif
#endif

#ifdef FOAM
	float final_foam_alpha = foam_alpha * foam_tex.a * foam_fade_alpha;
	float foam_alpha_threshold = 0.0;
	final_foam_alpha = smoothstep(foam_alpha_threshold, foam_alpha_threshold + 1.0, final_foam_alpha);
	EMISSION *= (1.0-final_foam_alpha); // block emission
	ALBEDO = mix(ALBEDO, foam_tex.rgb, final_foam_alpha);
#endif
	
#ifdef SHORE_FOAM
	float z_diff = depth_from_water_to_object(SCREEN_UV, INV_PROJECTION_MATRIX, VERTEX);
	float shore_alpha = 0.0;
	shore_alpha = 1.0 - smoothstep(shore_start_blend, shore_end_blend, z_diff); // TODO: thresholds should be a parameter, something like shore_foam_depth_cutoff
	shore_alpha = clamp(shore_alpha, 0.0, 1.0);
	shore_alpha = foam_tex.a * shore_alpha; // disable this line when you have an all-white foam texture
	shore_alpha = shore_fade_alpha * shore_alpha;
	
	EMISSION *= (1.0-shore_alpha); // block emission
	ALBEDO = mix(ALBEDO, foam_tex.rgb, shore_alpha);
#endif

	// Water appearance diagnostics are output-only: no vertex wave inputs,
	// phase, amplitude, boat motion, or WaveSampler values are changed.
	if (water_diagnostic_mode == 0) {
		EMISSION += night_surface_lift * night_visual_weight;
	}
	if (water_diagnostic_mode == 1) {
		ALBEDO = vec3(0.0);
		EMISSION = albedo.rgb;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 4) {
		ALBEDO = vec3(0.0);
		EMISSION = normalize(NORMAL) * 0.5 + 0.5;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 5) {
		float fresnel_debug = fresnel(3.0, NORMAL, VIEW);
		ALBEDO = vec3(0.0);
		EMISSION = vec3(fresnel_debug);
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 6) {
		vec2 bathymetry_debug = sample_bathymetry(vec2(world_coordinates.x, -world_coordinates.z));
		float valid_debug = smoothstep(valid_coverage_min, valid_coverage_max, bathymetry_debug.y);
		float depth_debug = smoothstep(0.0, deep_depth_threshold, bathymetry_debug.x);
		ALBEDO = vec3(0.0);
		EMISSION = vec3(depth_debug, valid_debug, 1.0 - valid_debug);
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 7) {
		// Keep direct diffuse lighting (including cast shadows), suppress Fresnel,
		// color texture, bathymetry, and specular/environment reflection.
		ALBEDO = albedo.rgb;
		EMISSION = vec3(0.0);
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 8) {
		// Keep the material specular response while removing diffuse base color.
		ALBEDO = vec3(0.0);
		EMISSION = vec3(0.0);
		METALLIC = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 9) {
		// Isolate diffuse lighting from Gerstner and detail-normal modulation.
		NORMAL = flat_water_normal_view;
		ALBEDO = albedo.rgb;
		EMISSION = vec3(0.0);
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 10) {
		// Isolate specular/environment lighting from wave normal modulation.
		NORMAL = flat_water_normal_view;
		ALBEDO = vec3(0.0);
		EMISSION = vec3(0.0);
		METALLIC = 0.0;
		ALPHA = 1.0;
	} else if (water_diagnostic_mode == 11) {
		// Compare full shading with a constant upward surface normal.
		NORMAL = flat_water_normal_view;
	} else if (water_diagnostic_mode == 12) {
		// Isolate the ocean silhouette while preserving its configured distance
		// and near fades. Mode 1 intentionally forces alpha to 1 for geometry tests.
		ALBEDO = vec3(0.0);
		EMISSION = albedo.rgb;
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (water_diagnostic_mode == 13) {
		// Visual validation for depth and depth-buffer gating; no scene color changes.
		ALBEDO = vec3(0.0);
		EMISSION = vec3(shallow_transmission_weight, bathymetry_validity, 1.0 - shallow_transmission_weight);
		METALLIC = 0.0;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	}

}
