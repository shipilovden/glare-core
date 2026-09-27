

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
	vec4 cloud_settings_0; // (bottom_z, top_z, coverage, density)
	vec4 cloud_settings_1; // (shape_period, detail_period, wind_speed, max_march_dist)
	vec4 cloud_settings_2; // (legacy padding, edge_softness, horizon_fade, padding)
	vec4 cloud_settings_3; // (wind_dir_x, wind_dir_y, padding, padding)
	vec4 cloud_lighting_0; // (direct_sun_strength, sky_light_strength, sunset_response, ground_contribution)
	vec4 cloud_lighting_1; // (ground_albedo.r, ground_albedo.g, ground_albedo.b, phase_g)
	vec4 cloud_lighting_2; // (phase_blend, multi_scattering, underside_darkness, scattering_scale)
	vec4 water_reflection_settings; // (enabled, strength, samples, horizon_fade)
	vec4 water_surface_settings_0; // (amplitude, wavelength, steepness, speed)
	vec4 water_surface_settings_1; // (direction.x, direction.y, angular spread radians, secondary scale)
	vec4 water_surface_settings_2; // (surf enabled, surf strength, shoreline width, foam scale)
	vec4 water_surface_settings_3; // (foam speed, foam fade, padding, padding)
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


float surfNoise(vec2 p)
{
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec4 h = fract(sin(vec4(dot(i, vec2(127.1, 311.7)), dot(i + vec2(1,0), vec2(127.1,311.7)),
		dot(i + vec2(0,1), vec2(127.1,311.7)), dot(i + vec2(1,1), vec2(127.1,311.7)))) * 43758.5453);
	return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

// Cellular films between bubbles, with large eroded gaps instead of solid
// white value-noise blobs. Explicit footprint keeps this testable and stable
// when the individual bubbles become smaller than a screen pixel.
float surfFoamLace(vec2 p, float age, float footprint)
{
	vec2 warp = vec2(surfNoise(p*0.43), surfNoise(p*0.43+vec2(17.3,9.2)))-0.5;
	vec2 q = p + warp*1.6;
	float patches = surfNoise(q*0.62)*0.65 + surfNoise(q*1.51+vec2(3.2,7.1))*0.35;
	vec2 cell = floor(q*3.5), local = fract(q*3.5);
	float first = 8.0, second = 8.0;
	for(int y=-1; y<=1; ++y) for(int x=-1; x<=1; ++x)
	{
		vec2 offset = vec2(x,y), id = cell+offset;
		vec2 jitter = fract(sin(vec2(dot(id,vec2(127.1,311.7)),dot(id,vec2(269.5,183.3))))*43758.5453);
		float d = length(offset+0.15+0.7*jitter-local);
		if(d < first) { second=first; first=d; } else second=min(second,d);
	}
	float aa = clamp(footprint*3.5,0.015,0.3);
	float films = 1.0-smoothstep(0.035,0.11+aa,second-first);
	films = mix(films,0.3,smoothstep(0.15,0.5,footprint));
	float erosion = mix(0.24,0.57,clamp(age,0.0,1.0));
	float islands = smoothstep(erosion,erosion+0.2,patches);
	return islands * mix(0.2+0.5*(1.0-age),1.0,films);
}

// Distance zero is the ACTUAL water/ground intersection, never a second
// animated front. Width affects coverage behind the edge, not its position.
// Terrain draws only fading residue after inundation; the water owns the head.
vec2 coastalSurf(vec3 ground, float surface_z, bool residue_only)
{
	vec3 n = cross(dFdx(ground), dFdy(ground));
	float slope = clamp(length(n.xy) / max(abs(n.z), 1.0e-8), 0.04, 4.0);
	float width = max(0.1, water_surface_settings_2.z);
	float dist = (ground.z - surface_z) / slope;
	vec2 dir = normalize(water_surface_settings_1.xy);
	float scale = max(0.05, water_surface_settings_2.w);
	float drift = time * max(0.0, water_surface_settings_3.x) * max(0.0, water_surface_settings_0.w);
	vec4 coast = waterCoastData(ground.xy);
	float a = clamp(water_surface_settings_0.x, 0.0, 4.0) * 0.35;
	float k = 6.28318530718 / max(4.0, water_surface_settings_0.y);
	float phase = waterShorePhase(ground.xy, coast, dir, k,
		sqrt(9.8*k)*max(0.0,water_surface_settings_0.w), time);
	vec2 uphill = coast.yz / max(0.008, length(coast.yz));
	float excursion = a * waterSwash(phase) / max(0.04, length(coast.yz));
	vec2 transport = mix(dir * drift, uphill * excursion,
		waterShoreWeight(coast,a));
	vec2 uv = (ground.xy - transport) * scale;
	float aa = max(0.025, fwidth(dist));
	float head = waterContactFoam(dist, width, aa);
	float fade = clamp(water_surface_settings_3.y, 0.0, 1.0);
	float cycle = fract(-phase/6.28318530718);
	float retreat = smoothstep(0.24,0.8,cycle);
	float age = clamp(max(0.0,-dist)/width * 0.65 + retreat*0.35,0.0,1.0);
	// Changing shape is tied to the wave phase; pausing waves also pauses erosion.
	vec2 tangent = vec2(-uphill.y,uphill.x);
	uv += tangent * sin(phase) * min(1.0,water_surface_settings_3.x)*0.18;
	float footprint = length(fwidth(uv));
	// No cellular search over open sea; derivatives are evaluated before the branch.
	float bubbles = (dist > -width-aa && dist < aa) ? surfFoamLace(uv,age,footprint) : 0.0;
	float patch_width = width * mix(0.55,1.0,surfNoise(uv*0.7));
	float sheet = smoothstep(-patch_width,0.0,dist) * (1.0-smoothstep(0.0,aa,dist));
	float foam = bubbles * (head*0.55 + sheet*mix(0.28,0.48,fade));
	// Nothing is painted at the exact zero-thickness boundary. The porous
	// front appears just inside the water, without a cut-out white outline.
	foam *= smoothstep(0.0,max(0.06,aa),max(0.0,-dist));
	float wet = 1.0 - smoothstep(0.0, 0.025, ground.z - surface_z);
	if(residue_only)
	{
		// Sample the SAME waves a short time ago, so dry-sand foam requires
		// recent inundation. No bright independent line during run-up/retreat.
		float memory = 0.0;
		for(int i = 1; i <= 3; ++i)
		{
			float age = float(i) * mix(0.18, 0.6, fade);
			float previous_z = water_level_z + waterSurfaceHeight(ground.xy, water_surface_settings_0,
				water_surface_settings_1, mat_common_campos_ws.xy, time - age);
			float was_wet = 1.0 - smoothstep(-0.015, 0.015, ground.z - previous_z);
			memory = max(memory, was_wet * exp(-float(i) * 0.75));
		}
		float dry = smoothstep(0.005, 0.04, ground.z - surface_z);
		vec2 drainage_uv = vec2(dot(ground.xy-transport,tangent)*2.0,
			dot(ground.xy-transport,uphill)*0.65)*scale;
		float trails = surfFoamLace(drainage_uv,0.65+retreat*0.3,length(fwidth(drainage_uv)));
		foam = memory * dry * trails * 0.32;
		wet = max(wet, memory);
	}
	float energy = clamp(water_surface_settings_0.x * 2.0, 0.0, 1.0) * clamp(water_surface_settings_2.y, 0.0, 2.0);
	return clamp(vec2(foam, wet) * energy, 0.0, 1.0);
}

// mat_common_flags values
#define CLOUD_SHADOWS_FLAG					1
#define DO_SSAO_FLAG						2
#define DOING_SSAO_PREPASS_FLAG				4
#define VOLUMETRIC_CLOUDS_FLAG			8


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
