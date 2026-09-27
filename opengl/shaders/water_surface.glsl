// Terrain bathymetry is independent of actor/rock screen depth.
uniform sampler2D water_coast_tex;

vec4 waterCoastData(vec2 xy)
{
	ivec2 size = textureSize(water_coast_tex, 0);
	if(size.x < 2 || size.y < 3) return vec4(-10000.0, 0.0, 0.0, 0.0);
	vec4 rect = texelFetch(water_coast_tex, ivec2(0), 0);
	vec2 uv = (xy - rect.xy) * rect.z;
	if(rect.z <= 0.0 || any(lessThan(uv, vec2(0))) || any(greaterThan(uv, vec2(1))))
		return vec4(-10000.0, 0.0, 0.0, 0.0);
	vec2 p = uv * vec2(size.x-1, size.y-2);
	ivec2 i = min(ivec2(floor(p)), ivec2(size.x-2, size.y-3)) + ivec2(0,1);
	vec2 f = p - vec2(i - ivec2(0,1));
	// Manual filtering works without the WebGL float-linear extension.
	vec4 value = mix(mix(texelFetch(water_coast_tex,i,0), texelFetch(water_coast_tex,i+ivec2(1,0),0),f.x),
		mix(texelFetch(water_coast_tex,i+ivec2(0,1),0),texelFetch(water_coast_tex,i+ivec2(1,1),0),f.x),f.y);
	value.x -= rect.w;
	return value;
}

// Fast incoming bore and a longer gravity-driven return.
float waterSwash(float phase)
{
	float c = fract(-phase / 6.28318530718);
	return -0.25 + 1.25 * smoothstep(0.0, 0.24, c) * (1.0 - smoothstep(0.24, 1.0, c));
}

float waterShoreWeight(vec4 coast, float amplitude)
{
	return coast.w * smoothstep(0.008, 0.035, length(coast.yz)) *
		(1.0 - smoothstep(max(0.2, amplitude*1.5), max(0.8, amplitude*6.0), max(0.0,-coast.x)));
}

float waterShorePhase(vec2 p, vec4 coast, vec2 dir, float k, float omega, float t)
{
	vec2 uphill = coast.yz / max(0.008, length(coast.yz));
	float distance = clamp(coast.x / max(0.008, length(coast.yz)), -60.0, 60.0);
	vec2 shoreline = p - uphill * distance;
	// Pin phase along the coast normal: no isolated wave strips on dry sand.
	return dot(shoreline, dir) * k - t * omega;
}

vec3 waterWaveDisplacement(vec2 p, vec4 waves, vec4 directions, vec2 camera, float t)
{
	float a = clamp(waves.x, 0.0, 4.0) * 0.35;
	float k = 6.28318530718 / max(4.0, waves.y);
	float speed = max(0.0, waves.w);
	vec2 dir = normalize(directions.xy);
	float spread = clamp(directions.z, 0.0, 1.4);
	vec2 dir2 = vec2(dir.x * cos(spread) - dir.y * sin(spread),
		dir.x * sin(spread) + dir.y * cos(spread));
	float p1 = dot(p, dir) * k - t * sqrt(9.8 * k) * speed;
	float p2 = dot(p, dir2) * k * 1.73 - t * sqrt(9.8 * k * 1.73) * speed * 1.21 + 1.7;
	float secondary = clamp(directions.w, 0.0, 1.0);
	float steepness = clamp(waves.z, 0.0, 1.0);
	vec2 lateral = a * steepness * (dir * cos(p1) * 0.34 + dir2 * secondary * cos(p2) * 0.14);
	float height = a * (sin(p1) + secondary * sin(p2) * 0.45);
	vec4 coast = waterCoastData(p);
	float shore = waterShoreWeight(coast, a);
	float shore_phase = waterShorePhase(p, coast, dir, k, sqrt(9.8*k)*speed, t);
	height = mix(height, a * waterSwash(shore_phase), shore);
	lateral *= 1.0 - shore;
	float weight = 1.0 - smoothstep(80.0, 110.0, length(p - camera));
	return vec3(lateral, height) * weight;
}

float waterSurfaceHeight(vec2 xy, vec4 waves, vec4 directions, vec2 camera, float t)
{
	// Invert lateral displacement: the terrain supplies displaced world XY,
	// whereas the vertex shader evaluates waves at the original mesh position.
	vec2 p = xy;
	for(int i = 0; i < 4; ++i)
		p = xy - waterWaveDisplacement(p, waves, directions, camera, t).xy;
	return waterWaveDisplacement(p, waves, directions, camera, t).z;
}

float waterContactFoam(float signed_distance, float width, float aa)
{
	// The maximum must remain at distance zero for every width and time.
	return 1.0 - smoothstep(0.0, max(width * 0.12, aa) + aa, abs(signed_distance));
}

float waterSeabedFoamVisibility(float opaque_z, float terrain_z)
{
	return 1.0 - smoothstep(0.06, 0.18, opaque_z - terrain_z);
}

// Thin swash film transitions continuously into wet sand at depth zero.
float waterShoreCoverage(float depth, float slope, float width, float noise_value)
{
	float film_depth = clamp(slope*min(width*0.22,0.6),0.025,0.10);
	return smoothstep(0.0,film_depth*mix(0.65,1.35,noise_value),max(0.0,depth));
}
