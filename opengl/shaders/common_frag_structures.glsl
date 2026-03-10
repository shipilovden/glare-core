

// Data that is shared between all objects, and is updated once per frame.
// Should be the same layout as in OpenGLEngine.h
layout (std140) uniform MaterialCommonUniforms
{
	mat4 frag_view_matrix; // World space to camera space matrix
	vec4 sundir_cs; // Dir to sun.
	vec4 sundir_ws; // Dir to sun.
	vec4 sun_spec_rad_times_solid_angle;
	vec4 sun_and_sky_av_spec_rad;
	vec4 air_scattering_coeffs;
	vec4 fog_settings; // (layer_0_A, layer_0_B, layer_1_A, layer_1_B)
	vec4 mat_common_campos_ws;
	float near_clip_dist;
	float far_clip_dist;
	float time;
	float l_over_w; // lens_sensor_dist / sensor width
	float l_over_h; // lens_sensor_dist / sensor height
	float env_phi;
	float water_level_z;
	int camera_type; // OpenGLScene::CameraType

	int mat_common_flags;
	float shadow_map_samples_xy_scale;
	float padding_a1;
	float padding_a2;

	mat4 frag_shadow_texture_matrix[5];
};


// mat_common_flags values
#define CLOUD_SHADOWS_FLAG					1
#define DO_SSAO_FLAG						2
#define DOING_SSAO_PREPASS_FLAG				4


float fogLayerDensityIntegral(float cam_z, float frag_z, float dist, float A, float B)
{
	if(A <= 0.0 || dist <= 0.0)
		return 0.0;

	if(abs(B) < 1.0e-8)
		return A * dist;

	float dz = (frag_z - cam_z) / dist;
	if(abs(dz) < 1.0e-6)
		return A * exp(-B * cam_z) * dist;

	return A * (exp(-B * cam_z) - exp(-B * frag_z)) / (B * dz);
}


float getFogDensityIntegral(vec3 frag_pos_ws)
{
	// Use height relative to the camera instead of absolute world Z, otherwise fog becomes unintuitively weak
	// in worlds whose terrain happens to live at a large absolute elevation.
	float cam_z = 0.0;
	float frag_z = frag_pos_ws.z - mat_common_campos_ws.z;
	vec3 cam_to_frag_ws = frag_pos_ws - mat_common_campos_ws.xyz;
	float dist = length(cam_to_frag_ws);

	return
		fogLayerDensityIntegral(cam_z, frag_z, dist, fog_settings.x, fog_settings.y) +
		fogLayerDensityIntegral(cam_z, frag_z, dist, fog_settings.z, fog_settings.w);
}


float getFogOpticalDepth(vec3 frag_pos_ws)
{
	// The world-settings fog UI is tuned for artist-facing values in roughly "per kilometre" units,
	// while the original atmospheric depth fog uses physical air_scattering_coeffs on the order of 1e-5.
	// Convert the integrated fog density to a practical optical depth directly so the UI has a clearly visible effect
	// on medium and long distances in typical Metasiberia world scales.
	const float fog_extinction_scale = 0.01;
	return max(0.0, getFogDensityIntegral(frag_pos_ws) * fog_extinction_scale);
}


vec3 getFogTransmission(vec3 frag_pos_ws)
{
	return vec3(exp(-getFogOpticalDepth(frag_pos_ws)));
}


// MaterialData flag values
#define HAVE_SHADING_NORMALS_FLAG			1
#define HAVE_TEXTURE_FLAG					2
#define HAVE_METALLIC_ROUGHNESS_TEX_FLAG	4
#define HAVE_EMISSION_TEX_FLAG				8
#define IS_HOLOGRAM_FLAG					16 // e.g. no light scattering, just emission
#define IMPOSTER_TEX_HAS_MULTIPLE_ANGLES	32
#define HAVE_NORMAL_MAP_FLAG				64
#define SIMPLE_DOUBLE_SIDED_FLAG			128
#define SWIZZLE_ALBEDO_TEX_R_TO_RGB_FLAG	256
#define CONVERT_ALBEDO_FROM_SRGB_FLAG		512


#define CameraType_Identity					0
#define CameraType_Perspective				1
#define CameraType_Orthographic				2
#define CameraType_DiagonalOrthographic		3


// Data that is specific to a single object.
// Should match PhongUniforms in OpenGLEngine.h
struct MaterialData
{
	vec4 diffuse_colour; // Alpha is stored in diffuse_colour.w
	float transmission_colour_r; // Avoid padding rules for vec3
	float transmission_colour_g;
	float transmission_colour_b;
	float emission_colour_r;
	float emission_colour_g;
	float emission_colour_b;
	vec2 texture_upper_left_matrix_col0;
	vec2 texture_upper_left_matrix_col1;
	vec2 texture_matrix_translation;

#if USE_BINDLESS_TEXTURES
	sampler2D diffuse_tex;
	sampler2D metallic_roughness_tex;
	sampler2D lightmap_tex;
	sampler2D emission_tex;
	sampler2D backface_albedo_tex;
	sampler2D transmission_tex;
	sampler2D normal_map;
	sampler2DArray combined_array_tex;
#else
	float padding0;
	float padding1;
	float padding2;
	float padding3;
	float padding4;
	float padding5;
	float padding6;
	float padding7;
	float padding8;
	float padding9;
	float padding10;
	float padding11;
	float padding12;
	float padding13;
	float padding14;
	float padding15;
#endif

	int flags;
	float roughness;
	float fresnel_scale;
	float metallic_frac;
	float begin_fade_out_distance;
	float end_fade_out_distance;

	float materialise_lower_z; // For imposters: begin_fade_in_distance.
	float materialise_upper_z; // For imposters: end_fade_in_distance.
	float materialise_start_time; // For participating media and decals which use dopacity_dt: spawn time

	float dopacity_dt; // dopacity/dt

	float padding_b0;
	float padding_b1;
};


// Should match LightData struct in OpenGLEngine.h
struct LightData
{
	vec4 pos;
	vec4 dir;
	vec4 col;
	int light_type; // 0 = point light, 1 = spotlight
	float cone_min_cos_angle;
	float cone_max_cos_angle;

	float padding_l0;
};
