// Membrana de las Web Wings: tela roja translúcida con telaraña negra que nace
// en el hombro (UV.x = envergadura 0 cuerpo -> 1 muñeca, UV.y = cuerda 0 brazo ->
// 1 borde de salida). Doble cara; el reverso es más oscuro.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 fabric : source_color = vec3(0.62, 0.05, 0.06);
uniform vec3 line_color : source_color = vec3(0.02, 0.02, 0.025);
uniform float spokes = 7.0;
uniform float rings = 6.0;
uniform float line_width = 0.05;

void fragment() {
	vec2 p = vec2(UV.x, UV.y * 0.8);
	float r = length(p);
	float a = atan(p.y, p.x);
	float spoke = abs(fract(a / 1.5707963 * spokes) - 0.5) * 2.0;
	float ring = abs(fract(r * rings) - 0.5) * 2.0;
	float web = max(1.0 - smoothstep(0.0, line_width * 3.0 / max(r, 0.2), 1.0 - spoke),
			1.0 - smoothstep(0.0, line_width * 2.0, 1.0 - ring));
	float edge = 1.0 - smoothstep(0.0, 0.05, 1.0 - UV.y);   // ribete oscuro en el borde
	web = max(web, edge);
	vec3 col = mix(fabric, line_color, web);
	ALBEDO = FRONT_FACING ? col : col * 0.55;
	ROUGHNESS = mix(0.55, 0.25, web);
	SPECULAR = 0.4;
}
