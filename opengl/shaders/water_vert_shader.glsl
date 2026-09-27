
in vec3 position_in;
in vec3 normal_in;
in vec2 texture_coords_0_in;
#if INSTANCE_MATRICES
in mat4 instance_matrix_in;
#endif

out vec3 normal_ws; // world space
out vec3 pos_cs;
#if GENERATE_PLANAR_UVS
out vec3 pos_os;
#endif
out vec3 pos_ws;
//out vec2 texture_coords;
out vec3 cam_to_pos_ws;

#if OB_AND_MAT_DATA_GPU_RESIDENT
flat out int material_index;
#endif


// The water vertex shader used to render a perfectly flat plane.  The fragment
// shader could animate normals and foam, but the shoreline intersection itself
// could never move.  Keep this block in sync with common_frag_structures.glsl
// so the same artist-facing water controls drive the geometric wave as well.
layout (std140) uniform MaterialCommonUniforms
{
	mat4 frag_view_matrix;
	vec4 sundir_cs;
	vec4 sundir_ws;
	vec4 sun_spec_rad_times_solid_angle;
	vec4 sun_and_sky_av_spec_rad;
	vec4 air_scattering_coeffs;
	vec4 fog_settings;
	vec4 cloud_settings_0;
	vec4 cloud_settings_1;
	vec4 cloud_settings_2;
	vec4 cloud_settings_3;
	vec4 cloud_lighting_0;
	vec4 cloud_lighting_1;
	vec4 cloud_lighting_2;
	vec4 water_reflection_settings;
	vec4 water_surface_settings_0; // (amplitude, wavelength, steepness, speed)
	vec4 water_surface_settings_1; // (direction.x, direction.y, spread radians, secondary scale)
	vec4 water_surface_settings_2;
	vec4 water_surface_settings_3;
	vec4 mat_common_campos_ws;
	float near_clip_dist;
	float far_clip_dist;
	float time;
	float l_over_w;
	float l_over_h;
	float env_phi;
	float water_level_z;
	int camera_type;
	int mat_common_flags;
	float shadow_map_samples_xy_scale;
	float padding_a1;
	float padding_a2;
	mat4 frag_shadow_texture_matrix[5];
};


//----------------------------------------------------------------------------------------------------------------------------
#if OB_AND_MAT_DATA_GPU_RESIDENT

layout(std430) buffer PerObjectVertUniforms
{
	PerObjectVertUniformsStruct per_object_data[];
};


#if USE_MULTIDRAW_ELEMENTS_INDIRECT
	// If using MDEI, then the object and mat indices are fetched from indexing into ob_and_mat_indices with gl_DrawID.
	layout (std430) buffer ObAndMatIndicesStorage
	{
		int ob_and_mat_indices[];
	};
#else // else if !USE_MULTIDRAW_ELEMENTS_INDIRECT
	// If not using MDEI, the object and mat indices are passed to the shader in this uniform.
	layout (std140) uniform ObJointAndMatIndices
	{
		ObJointAndMatIndicesStruct ob_joint_and_mat_indices;
	};
#endif

//----------------------------------------------------------------------------------------------------------------------------
#else // else if !OB_AND_MAT_DATA_GPU_RESIDENT:

layout (std140) uniform PerObjectVertUniforms
{
	PerObjectVertUniformsStruct per_object_data;
};

#endif // !OB_AND_MAT_DATA_GPU_RESIDENT
//----------------------------------------------------------------------------------------------------------------------------


vec3 displaceWaterVertex(vec3 pos_ws)
{
	return pos_ws + waterWaveDisplacement(pos_ws.xy, water_surface_settings_0,
		water_surface_settings_1, mat_common_campos_ws.xy, time);
}


void main()
{
#if OB_AND_MAT_DATA_GPU_RESIDENT
	#if USE_MULTIDRAW_ELEMENTS_INDIRECT
	// Compute from gl_DrawID
	int per_ob_data_index = ob_and_mat_indices[gl_DrawID * OB_AND_MAT_INDICES_STRIDE + 0];
	material_index        = ob_and_mat_indices[gl_DrawID * OB_AND_MAT_INDICES_STRIDE + 2];
	#else
	// Get from ob_joint_and_mat_indices uniform
	int per_ob_data_index = ob_joint_and_mat_indices.per_ob_data_index;
	material_index        = ob_joint_and_mat_indices.material_index;
	#endif

	mat4 model_matrix  = per_object_data[per_ob_data_index].model_matrix;
	mat4 normal_matrix = per_object_data[per_ob_data_index].normal_matrix;
#else
	mat4 model_matrix  = per_object_data.model_matrix;
	mat4 normal_matrix = per_object_data.normal_matrix;
#endif

#if INSTANCE_MATRICES //-------------------------
	vec3 displaced_pos_ws = displaceWaterVertex((instance_matrix_in * vec4(position_in, 1.0)).xyz);
	gl_Position = proj_matrix * (view_matrix * vec4(displaced_pos_ws, 1.0));

#if GENERATE_PLANAR_UVS
	pos_os = position_in;
#endif

	pos_ws = displaced_pos_ws;
	cam_to_pos_ws = pos_ws - campos_ws;
	pos_cs = (view_matrix * vec4(displaced_pos_ws, 1.0)).xyz;

	normal_ws = (instance_matrix_in * vec4(normal_in, 0.0)).xyz;
#else //-------- else if !INSTANCE_MATRICES:
	vec3 displaced_pos_ws = displaceWaterVertex((model_matrix * vec4(position_in, 1.0)).xyz);
	gl_Position = proj_matrix * (view_matrix * vec4(displaced_pos_ws, 1.0));

#if GENERATE_PLANAR_UVS
	pos_os = position_in;
#endif

	pos_ws = displaced_pos_ws;
	cam_to_pos_ws = pos_ws - campos_ws.xyz;
	pos_cs = (view_matrix * vec4(displaced_pos_ws, 1.0)).xyz;

	normal_ws = (normal_matrix * vec4(normal_in, 0.0)).xyz;
#endif //-------------------------

	//texture_coords = texture_coords_0_in;
}
