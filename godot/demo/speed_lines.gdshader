// Líneas de velocidad radiales + viñeta. `intensity` 0..1 la pone DemoFx según la
// velocidad (y más dentro de un túnel de viento o al salir del slingshot).
shader_type canvas_item;

uniform float intensity = 0.0;
uniform float vignette = 0.0;
uniform vec3 tint : source_color = vec3(1.0);

float hash(float n) {
	return fract(sin(n * 91.345) * 47453.5453);
}

void fragment() {
	vec2 px = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = (UV - 0.5) * vec2(px.x / px.y, 1.0);
	float r = length(uv);
	float a = atan(uv.y, uv.x) / 6.2831853 + 0.5;
	float cells = 110.0;
	float cell = floor(a * cells);
	float h = hash(cell + floor(TIME * 3.0 + hash(cell) * 5.0) * 17.0);
	float w = abs(fract(a * cells) - 0.5) * 2.0;
	float thin = 1.0 - smoothstep(0.0, 0.35, w);
	float s = fract(r * 2.2 - TIME * (2.5 + h * 3.0) + h * 9.0);
	float dash = smoothstep(0.0, 0.15, s) * (1.0 - smoothstep(0.35, 0.75, s));
	float mask = smoothstep(0.28, 0.75, r) * step(0.62, h);
	float lines = thin * dash * mask * intensity;
	float vig = smoothstep(0.45, 1.0, r) * vignette;
	COLOR = vec4(mix(vec3(0.0), tint, lines / max(lines + vig, 1e-4)), clamp(lines * 0.55 + vig * 0.5, 0.0, 1.0));
}
