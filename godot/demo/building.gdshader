// Fachadas procedurales: rejilla de ventanas en espacio mundo (sin texturas).
shader_type spatial;

uniform vec2 window_size = vec2(3.2, 3.6);
uniform vec3 glass_dark : source_color = vec3(0.10, 0.14, 0.20);
uniform vec3 glass_light : source_color = vec3(0.42, 0.55, 0.68);

varying vec3 wpos;
varying vec3 wnorm;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 wall = COLOR.rgb;
	float is_roof = step(0.5, abs(wnorm.y));
	vec2 facade = abs(wnorm.x) > 0.5 ? wpos.zy : wpos.xy;
	vec2 cell = facade / window_size;
	vec2 f = fract(cell);
	float win = step(0.16, f.x) * step(f.x, 0.84) * step(0.22, f.y) * step(f.y, 0.86);
	win *= (1.0 - is_roof) * step(4.5, wpos.y);          // planta baja sin ventanas
	float rnd = hash(floor(cell) + floor(wpos.xz * 0.01));
	vec3 glass = mix(glass_dark, glass_light, rnd * 0.7);
	vec3 col = mix(wall, glass, win);
	col = mix(col, wall * 0.55, is_roof);
	col *= mix(0.55, 1.0, clamp(wpos.y / 25.0, 0.0, 1.0)); // oclusión barata a pie de calle
	ALBEDO = col;
	ROUGHNESS = mix(0.9, 0.12, win);
	METALLIC = mix(0.0, 0.35, win);
}
