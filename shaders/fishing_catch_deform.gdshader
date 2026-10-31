shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_albedo_texture = false;
uniform bool use_vertex_color = false;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);

uniform float metallic = 0.0;
uniform sampler2D metallic_texture : filter_linear_mipmap, repeat_enable;
uniform bool has_metallic_texture = false;
uniform int metallic_texture_channel : hint_range(0, 3, 1) = 0;
uniform float roughness = 0.7;
uniform sampler2D roughness_texture : filter_linear_mipmap, repeat_enable;
uniform bool has_roughness_texture = false;
uniform int roughness_texture_channel : hint_range(0, 3, 1) = 0;
uniform float metallic_specular = 0.5;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal_texture = false;
uniform float normal_scale = 1.0;

uniform float body_min_x = 0.0;
uniform float body_range_x = 1.0;
uniform float body_center_y = 0.0;
uniform float body_center_z = 0.0;
uniform bool head_at_max_x = true;
uniform vec3 lateral_axis_mesh = vec3(0.0, 0.0, 1.0);
uniform float spine_bend_angle = 0.0;
uniform float tail_whip_angle = 0.0;
uniform float tail_wave_phase = 0.0;
uniform float curl_sign = 1.0;
uniform float bend_power = 1.0;
uniform float hook_u = 0.95;
uniform float tail_u = 0.05;

const int SPINE_INTEGRATION_STEPS = 16;
const float MAX_SPINE_ANGLE = 2.757620218;


float sample_channel(vec4 value, int channel) {
	if (channel == 0) {
		return value.r;
	}
	if (channel == 1) {
		return value.g;
	}
	if (channel == 2) {
		return value.b;
	}
	return value.a;
}


float body_u_from_x(float x) {
	float along_x = clamp((x - body_min_x) / max(body_range_x, 0.0001), 0.0, 1.0);
	return head_at_max_x ? along_x : 1.0 - along_x;
}


float spine_angle_at(float q) {
	float along = clamp(q, 0.0, 1.0);
	float body_ramp = pow(smoothstep(0.18, 0.82, along), max(bend_power, 0.6));
	float tail_ramp = smoothstep(0.72, 0.97, along);
	float tail_strike = sin(tail_wave_phase);
	float angle = curl_sign * (spine_bend_angle * body_ramp + tail_whip_angle * tail_ramp * tail_strike);
	return clamp(angle, -MAX_SPINE_ANGLE, MAX_SPINE_ANGLE);
}


vec3 spine_centerline(float q, float spine_length, vec3 body_axis, vec3 lateral_axis) {
	float step_size = clamp(q, 0.0, 1.0) / float(SPINE_INTEGRATION_STEPS);
	vec3 centerline = vec3(0.0);
	for (int index = 0; index < SPINE_INTEGRATION_STEPS; index++) {
		float sample_q = (float(index) + 0.5) * step_size;
		float angle = spine_angle_at(sample_q);
		vec3 tangent = body_axis * cos(angle) + lateral_axis * sin(angle);
		centerline += tangent * (spine_length * step_size);
	}
	return centerline;
}


void vertex() {
	vec3 body_axis = head_at_max_x ? vec3(-1.0, 0.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 lateral_axis = normalize(lateral_axis_mesh - body_axis * dot(lateral_axis_mesh, body_axis));
	vec3 normal_axis = normalize(cross(body_axis, lateral_axis));
	float body_u = body_u_from_x(VERTEX.x);
	float q = clamp((hook_u - body_u) / max(hook_u - tail_u, 0.0001), 0.0, 1.0);
	float spine_length = body_range_x * abs(hook_u - tail_u);
	float head_x_fraction = head_at_max_x ? hook_u : 1.0 - hook_u;
	vec3 head_origin = vec3(body_min_x + head_x_fraction * body_range_x, body_center_y, body_center_z);
	vec3 source_center = head_origin + body_axis * (spine_length * q);
	vec3 section_offset = VERTEX - source_center;
	float section_lateral = dot(section_offset, lateral_axis);
	float section_normal = dot(section_offset, normal_axis);
	float residual_axial = dot(section_offset, body_axis);
	float bend_angle = spine_angle_at(q);
	vec3 tangent = normalize(body_axis * cos(bend_angle) + lateral_axis * sin(bend_angle));
	vec3 section_axis = normalize(-body_axis * sin(bend_angle) + lateral_axis * cos(bend_angle));
	vec3 bent_center = head_origin + spine_centerline(q, spine_length, body_axis, lateral_axis);
	VERTEX = bent_center + tangent * residual_axial + section_axis * section_lateral + normal_axis * section_normal;

	// Rotate each cross-section with its local spine frame. This preserves the
	// imported thickness instead of translating sections through one another.
	vec3 source_normal = NORMAL;
	vec3 source_tangent = TANGENT;
	NORMAL = normalize(tangent * dot(source_normal, body_axis) + section_axis * dot(source_normal, lateral_axis) + normal_axis * dot(source_normal, normal_axis));
	TANGENT = normalize(tangent * dot(source_tangent, body_axis) + section_axis * dot(source_tangent, lateral_axis) + normal_axis * dot(source_tangent, normal_axis));
}


void fragment() {
	vec2 uv = UV * uv_scale + uv_offset;
	vec4 albedo = albedo_color;
	if (has_albedo_texture) {
		albedo *= texture(albedo_texture, uv);
	}
	if (use_vertex_color) {
		albedo *= COLOR;
	}
	ALBEDO = albedo.rgb;
	METALLIC = metallic;
	if (has_metallic_texture) {
		METALLIC *= sample_channel(texture(metallic_texture, uv), metallic_texture_channel);
	}
	ROUGHNESS = roughness;
	if (has_roughness_texture) {
		ROUGHNESS *= sample_channel(texture(roughness_texture, uv), roughness_texture_channel);
	}
	SPECULAR = metallic_specular;
	if (has_normal_texture) {
		NORMAL_MAP = texture(normal_texture, uv).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
}
