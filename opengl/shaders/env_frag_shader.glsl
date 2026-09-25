
in vec3 pos_cs;
in vec2 texture_coords;
in vec3 dir_ws;

uniform vec4 diffuse_colour;
uniform int have_texture;
uniform sampler2D diffuse_tex;
//uniform sampler2D noise_tex;
uniform sampler2D blue_noise_tex;
uniform sampler2D fbm_tex;
uniform sampler2D cirrus_tex;
uniform mat3 texture_matrix;
uniform vec3 env_campos_ws;
uniform sampler2D aurora_tex;


out vec4 colour_out;




// https://www.shadertoy.com/view/MdcfDj
// LICENSE: http://unlicense.org/
#define M1 1597334677U     //1719413*929
#define M2 3812015801U     //140473*2467*11
float hash( uvec2 q )
{
	q *= uvec2(M1, M2); 

	uint n = (q.x ^ q.y) * M1;

	return float(n) * (1.0/float(0xffffffffU));
}


#define HASH_VALUE_THRESHOLD 0.97

float innerEvalSlightlyJittered(vec2 p, uint seed)
{
    ivec2 cell_coords = ivec2(floor(p));
    float h = hash(uvec2(ivec2(10000000) + cell_coords) + uvec2(seed));
    
    float v = 0.0;
    if(h >= HASH_VALUE_THRESHOLD)
    {
         vec2 star_centre = vec2(cell_coords) + vec2(0.25) + 
             vec2(
                 hash(uvec2(cell_coords) + uvec2(0, 134324)),
                 hash(uvec2(cell_coords) + uvec2(73454, 234324))
             ) * 0.5;
         float d = length(p - star_centre);
         v = pow(max(0.0, 1.0 - d*2.0), 4.0);
    }
    return v;
}


float evalStarfield(vec2 p, uint seed)
{
    vec2 dcoords_dx = dFdx(p);
    vec2 dcoords_dy = dFdy(p);

    float rxf = clamp(length(dcoords_dx) * 3.0, 1.0, 8.0);
    float ryf = clamp(length(dcoords_dy) * 3.0, 1.0, 8.0);

    int rx = int(ceil(rxf));
    int ry = int(ceil(ryf));

    float v = 0.0;
    for(int x=0; x<rx; ++x)
    for(int y=0; y<ry; ++y)
    {
        vec2 coords = p +
            (dcoords_dx * float(x)) / float(rx) + 
            (dcoords_dy * float(y)) / float(ry);
            
        v += innerEvalSlightlyJittered(coords, seed);
    }
    v /= float(rx*ry);

    return v;
}


#if VOLUMETRIC_CLOUDS
// A compact 2.5D density field.  The existing FBM texture is sampled at two
// different world-space frequencies and with a height-dependent erosion term,
// which gives the sky ray a genuinely volumetric result without allocating a
// second render pass or a 3D noise texture.
float sampleVolumetricCloudDensity(vec3 p, float height01)
{
	float shape_period = max(100.0, cloud_settings_1.x);
	float detail_period = max(50.0, cloud_settings_1.y);
	float wind_offset = time * cloud_settings_1.z;
	vec2 wind_dir = cloud_settings_3.xy;
	wind_dir /= max(length(wind_dir), 0.001);
	vec2 wind_perp = vec2(-wind_dir.y, wind_dir.x);

	vec2 shape_uv = (p.xy + wind_offset * wind_dir) / shape_period;
	shape_uv += vec2(2.3453, 1.4354);
	float shape = fbmMix(shape_uv, fbm_tex) * 0.5 + 0.5;

	vec2 detail_uv = (p.xy + wind_offset * (1.7 * wind_dir - 0.8 * wind_perp)) / detail_period;
	detail_uv += vec2(p.z / detail_period * 0.35);
	float detail = fbmMix(detail_uv, fbm_tex) * 0.5 + 0.5;

	// Cumulus clouds are soft at the base and break up towards the top.  The
	// edge control affects both the height profile and the density threshold,
	// keeping the cloud silhouette rounded instead of cut out by noise.
	float edge_softness = clamp(cloud_settings_2.y, 0.0, 1.0);
	float base_fade = mix(0.06, 0.22, edge_softness);
	float top_fade_start = mix(0.76, 0.58, edge_softness);
	float vertical_shape = smoothstep(0.0, base_fade, height01) * (1.0 - smoothstep(top_fade_start, 1.0, height01));
	float coverage = clamp(cloud_settings_0.z, 0.02, 0.98);
	float weather = shape + (detail - 0.5) * 0.30;
	float edge_width = mix(0.035, 0.20, edge_softness);
	float cloud = smoothstep(coverage - edge_width * 0.65, coverage + edge_width, weather);
	return cloud * vertical_shape;
}


float henyeyGreensteinPhase(float cos_theta, float g)
{
	float g2 = g * g;
	float denominator = pow(max(0.001, 1.0 + g2 - 2.0 * g * cos_theta), 1.5);
	return (1.0 - g2) / (4.0 * 3.14159265 * denominator);
}


float cloudLightTransmittance(vec3 p, vec3 sun_dir, float bottom_z, float top_z, float density_scale)
{
	if(sun_dir.z <= 0.001)
		return 0.18;

	float distance_to_top = max(0.0, (top_z - p.z) / sun_dir.z);
	if(distance_to_top <= 0.0)
		return 1.0;

	// A short secondary march captures self-shadowing and silver lining while
	// keeping the cost bounded.  The main view march remains the expensive path.
	const int LIGHT_STEPS = 4;
	float light_step_len = min(2500.0, max(80.0, distance_to_top / float(LIGHT_STEPS)));
	float light_transmittance = 1.0;
	for(int i = 0; i < LIGHT_STEPS; ++i)
	{
		vec3 light_p = p + sun_dir * (float(i) + 0.5) * light_step_len;
		if(light_p.z > top_z)
			break;
		float light_height01 = clamp((light_p.z - bottom_z) / (top_z - bottom_z), 0.0, 1.0);
		float light_density = sampleVolumetricCloudDensity(light_p, light_height01) * density_scale;
		light_transmittance *= exp(-light_density * light_step_len * 1.1);
		if(light_transmittance < 0.02)
			return light_transmittance;
	}
	return light_transmittance;
}


vec4 raymarchVolumetricClouds(vec3 campos_ws, vec3 ray_dir_ws, vec4 sky_col)
{
	// The layer is above the world.  Looking down or exactly along the horizon
	// must leave the ordinary sky path untouched.
	if(ray_dir_ws.z <= 0.001)
		return sky_col;

	float bottom_z = min(cloud_settings_0.x, cloud_settings_0.y - 1.0);
	float top_z = max(cloud_settings_0.y, bottom_z + 1.0);
	float ray_start = max(0.0, (bottom_z - campos_ws.z) / ray_dir_ws.z);
	float ray_end = (top_z - campos_ws.z) / ray_dir_ws.z;
	float max_dist = max(100.0, cloud_settings_1.w);
	if(ray_end <= ray_start)
		return sky_col;
	ray_end = min(ray_end, ray_start + max_dist);

	const int NUM_STEPS = 40;
	float step_len = (ray_end - ray_start) / float(NUM_STEPS);
	float blue_noise = texture(blue_noise_tex, gl_FragCoord.xy * (1.0 / 64.0)).x;
	float ray_t = ray_start + blue_noise * step_len;
	float transmittance = 1.0;
	vec3 scattered = vec3(0.0);
	float density_scale = max(0.0, cloud_settings_0.w);
	float view_sun = dot(normalize(ray_dir_ws), normalize(sundir_ws.xyz));
	float horizon_fade = clamp(cloud_settings_2.z, 0.0, 1.0);
	float scattering_scale = max(0.0, cloud_lighting_2.w);
	float bottom_darkness = clamp(cloud_lighting_2.z, 0.0, 1.0);
	float sun_above_horizon = smoothstep(-0.12, 0.12, sundir_ws.z);
	vec3 sky_light = max(vec3(0.0), sun_and_sky_av_spec_rad.xyz) * max(0.0, cloud_lighting_0.y);
	float sky_luminance = max(0.001, dot(sky_light, vec3(0.2126, 0.7152, 0.0722)));
	vec3 direct_sun_radiance = max(vec3(0.0), sun_spec_rad_times_solid_angle.xyz / 0.00006780608);
	float direct_sun_luminance = max(0.001, dot(direct_sun_radiance, vec3(0.2126, 0.7152, 0.0722)));
	vec3 direct_sun_colour = direct_sun_radiance / direct_sun_luminance;
	float sunset_factor = pow(1.0 - smoothstep(0.04, 0.65, max(0.0, sundir_ws.z)), 1.35) * max(0.0, cloud_lighting_0.z);
	vec3 direct_sun_light = direct_sun_colour * sky_luminance *
		(0.55 + 1.35 * sunset_factor) * max(0.0, cloud_lighting_0.x) * sun_above_horizon;
	float phase_g = clamp(cloud_lighting_1.w, -0.85, 0.85);
	float phase_blend = clamp(cloud_lighting_2.x, 0.0, 1.0);
	float phase = mix(
		henyeyGreensteinPhase(view_sun, phase_g),
		henyeyGreensteinPhase(view_sun, -phase_g * 0.35),
		phase_blend);
	float horizon_angle = radians(12.0);
	float horizon_view_factor = smoothstep(0.0, max(0.001, sin(horizon_angle)), ray_dir_ws.z);
	float horizon_visibility = mix(1.0, horizon_view_factor, horizon_fade);

	for(int i = 0; i < NUM_STEPS; ++i)
	{
		vec3 p = campos_ws + ray_dir_ws * ray_t;
		float height01 = clamp((p.z - bottom_z) / (top_z - bottom_z), 0.0, 1.0);
		float density = sampleVolumetricCloudDensity(p, height01) * density_scale;

		if(density > 0.00001)
		{
			float optical_depth = density * step_len;
			float segment_transmittance = exp(-optical_depth);
			float segment_alpha = 1.0 - segment_transmittance;
			float light_transmittance = cloudLightTransmittance(p, normalize(sundir_ws.xyz), bottom_z, top_z, density_scale);
			float underside_shadow = mix(1.0 - bottom_darkness * 0.78, 1.0, smoothstep(0.05, 0.55, height01));
			float lower_cloud_factor = (1.0 - height01) * (1.0 - height01);
			vec3 ground_albedo = clamp(cloud_lighting_1.xyz, vec3(0.0), vec3(1.0));
			vec3 ground_light = ground_albedo * sky_luminance * max(0.0, cloud_lighting_0.w) * lower_cloud_factor;
			float multi_scattering = 1.0 + clamp(cloud_lighting_2.y, 0.0, 1.0) * (1.0 - light_transmittance) * 0.8;
			vec3 cloud_light = sky_light * (0.55 + 0.45 * height01) +
				direct_sun_light * phase * 4.0 * light_transmittance + ground_light;
			cloud_light *= multi_scattering * underside_shadow * scattering_scale;
			scattered += transmittance * segment_alpha * cloud_light;
			transmittance *= segment_transmittance;
			if(transmittance < 0.01)
				break;
		}

		ray_t += step_len;
	}

	vec3 cloud_result = sky_col.rgb * transmittance + scattered;
	return vec4(mix(sky_col.rgb, cloud_result, horizon_visibility), sky_col.a);
}
#endif


void main()
{
	// Col = spectral radiance * 1.0e-9
	vec4 col;
	if(have_texture != 0)
		// Multiply x coord by 2 since we just have one half of the sphere encoded in the env map.
		col = texture(diffuse_tex, (texture_matrix * vec3(texture_coords.x * 2.0, texture_coords.y, 1.0)).xy);
	else
		col = diffuse_colour * 1.0e-9f;

#if RENDER_SUN_AND_SKY
	// Render sun
	
	// NOTE: actual cos(sun_angle) is 0.999989208346.
	// Using the smoothstep for the sun results in a larger visible sun, so a scale of about 0.4 compensates for that (eyeballed).
	// Reduce the scale even more because the sun glare is kind of annoying.
	float sunscale = 0.15;
	const float sun_solid_angle = 0.00006780608; // See SkyModel2Generator::makeSkyEnvMap();
	vec4 suncol = sun_spec_rad_times_solid_angle * (1.0 / sun_solid_angle) * sunscale;
	float d = dot(sundir_cs.xyz, normalize(pos_cs));
	col = mix(col, suncol, smoothstep(0.99997, 0.9999892083461507, d));



#if DRAW_AURORA
	const float MAX_AURORA_SUNDIR_Z = 0.1;
	if(sundir_ws.z < MAX_AURORA_SUNDIR_Z)
	{
		float aurora_factor = 1.0 - smoothstep(0.0, MAX_AURORA_SUNDIR_Z, sundir_ws.z);

		// NOTE: code duplicated in water_frag_shader
		float min_aurora_z = 1000.0;
		float max_aurora_z = 8000.0;
		float aurora_start_ray_t = rayPlaneIntersect(env_campos_ws, dir_ws, min_aurora_z);
		float aurora_end_ray_t = rayPlaneIntersect(env_campos_ws, dir_ws, max_aurora_z);

		int num_steps = 32;
		float t_step = min(600.0, (aurora_end_ray_t - aurora_start_ray_t) / float(num_steps));
		float pixel_hash = texture(blue_noise_tex, gl_FragCoord.xy * (1.0 / 64.f)).x;
		float t_offset = pixel_hash * t_step;

		vec3 aurora_up = normalize(vec3(0.3, 0.0, 1.0));
		vec3 aurora_forw = normalize(cross(aurora_up, vec3(0,0,1))); // vector along aurora surface
		vec3 aurora_right = cross(aurora_up, aurora_forw);

	
		vec4 green_col = vec4(0, pow(0.79, 2.2), pow(0.47, 2.2), 0);
		vec4 blue_col  = vec4(0, pow(0.1, 2.2),  pow(0.6, 2.2), 0);

		for(int i=0; i<num_steps; ++i)
		{
			float ray_t = aurora_start_ray_t + t_offset + t_step * float(i);
			vec3 p = env_campos_ws + dir_ws * ray_t;

			vec3 p_as = vec3(500.0 + dot(p, aurora_right), dot(p, aurora_forw), dot(p, aurora_up));

			vec2 st = p_as.xy * 0.0001;
			if(st.x > -1.0 && st.x <= 1.0 && st.y >= -1.0 && st.y <= 1.0)
			{
				vec4 aurora_val = texture(aurora_tex, st);

				float aurora_start_z = 1000.0 + aurora_val.y * 1000.0;
				if(p_as.z >= aurora_start_z)
				{
					// Smoothly start aurora above aurora_start_z
					float z_factor = smoothstep(aurora_start_z, aurora_start_z + 600.0, p_as.z);
				
					// Smoothly decrease intensity as z increases
					float z_ramp_intensity_factor = exp(-(p_as.z - 1200.0) * 0.001);
					float high_freq_intensity_factor = 1.0 + 3.0 * z_ramp_intensity_factor * (aurora_val.y - 0.5);//(1.0 + aurora_val.y * 2.0 * ramp_intensity_factor*ramp_intensity_factor);
					//float ramp_intensity_factor = max(0.0, 1000 / (p_as.z - 1100) - p_as.z * 0.001);
				
					vec4 col_for_height = mix(green_col, blue_col, min(1.0, (p_as.z - aurora_start_z) * (1.0 / 2000.0)));
				
					col += 0.001 * t_step * col_for_height * aurora_val.r * z_ramp_intensity_factor * high_freq_intensity_factor * z_factor * aurora_factor;
				}
			}
		}
	}

	// Draw starfield
	//float star = evalStarfield(dir_ws.yz * 200.0, 1) * max(0.f, texture(fbm_tex, dir_ws.yz * 20.0).x);
	//col += vec4(star * 0.4);
#endif


	vec2 cloudfrac_cumulus_edge = getCloudFrac(env_campos_ws, dir_ws, time, fbm_tex, cirrus_tex);
	float cloudfrac    = cloudfrac_cumulus_edge.x;
	float cumulus_edge = cloudfrac_cumulus_edge.y;
	vec4 cloudcol = sun_and_sky_av_spec_rad;
#if VOLUMETRIC_CLOUDS
	if((mat_common_flags & VOLUMETRIC_CLOUDS_FLAG) != 0)
		col = raymarchVolumetricClouds(env_campos_ws, normalize(dir_ws), col);
	else
#endif
	{
		col = mix(col, cloudcol, max(0.f, cloudfrac));
		vec4 suncloudcol = cloudcol * 2.5;
		float blend = max(0.f, cumulus_edge) * pow(max(0.0, d), 32.0);// smoothstep(0.9, 0.9999892083461507, d);
		col = mix(col, suncloudcol, blend);
	}

	//col = mix(col, cumulus_col, cumulus_alpha);


#if DEPTH_FOG
	// Blend lower hemisphere into a colour that matches fogged ground quad in Substrata
	vec4 lower_hemis_col = sun_and_sky_av_spec_rad * 0.9;
	
	float fog_presence = 1.0 - exp(-6.0 * max(0.0, fog_settings.x + fog_settings.z));
	float lower_hemis_factor = smoothstep(1.52, 1.6, texture_coords.y) * fog_presence;
	col = mix(col, lower_hemis_col, lower_hemis_factor);
#endif

#endif // RENDER_SUN_AND_SKY

#if DO_POST_PROCESSING
	colour_out = vec4(col.xyz, 1);
#else
	colour_out = vec4(toneMapToNonLinear(col.xyz), 1.0);
#endif
}
