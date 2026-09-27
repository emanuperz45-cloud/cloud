// Calles, aceras y líneas discontinuas a partir de la rejilla de la ciudad.
shader_type spatial;

uniform float pitch = 84.0;
uniform float street = 24.0;
uniform float sidewalk = 3.5;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 q = mod(wpos.xz + street * 0.5, pitch);
	bool street_x = q.x < street;
	bool street_z = q.y < street;
	vec3 asphalt = vec3(0.075, 0.078, 0.085);
	vec3 walk = vec3(0.36, 0.35, 0.33);
	vec3 col = walk;
	if (street_x || street_z) {
		col = asphalt;
		float line_z = step(abs(q.x - street * 0.5), 0.15) * step(fract(wpos.z / 6.0), 0.5);
		float line_x = step(abs(q.y - street * 0.5), 0.15) * step(fract(wpos.x / 6.0), 0.5);
		if (street_x && !street_z) col = mix(col, vec3(0.85, 0.7, 0.2), line_z);
		if (street_z && !street_x) col = mix(col, vec3(0.85, 0.7, 0.2), line_x);
	} else if (q.x < street + sidewalk || q.y < street + sidewalk
			|| q.x > pitch - sidewalk || q.y > pitch - sidewalk) {
		col = walk;
	} else {
		col = vec3(0.22, 0.24, 0.2);
	}
	ALBEDO = col;
	ROUGHNESS = 0.95;
}
