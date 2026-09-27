// Traje del personaje a partir de la referencia (esfera roja con telaraña negra):
// tela roja con microtextura hexagonal + líneas de telaraña negras, brillantes y en
// relieve. Tres modos de proyección del patrón:
//   0 = cilíndrico (UV de cápsulas/esferas: brazos, piernas, cuello, pies)
//   1 = radial (telaraña centrada en pecho/espalda o en la pelvis)
//   2 = imagen de referencia proyectada de frente (cabeza/máscara)
// El relieve se calcula con derivadas en pantalla (no necesita tangentes) y
// funciona igual en Forward+ y en Compatibility.
shader_type spatial;

uniform int mode = 0;
uniform vec3 pattern_scale = vec3(1.0);        // local -> metros
uniform vec2 uv_meters = vec2(0.35, 0.3);      // modo 0: perímetro y largo en metros
uniform vec2 radial_center = vec2(0.0, 0.0);   // modo 1: centro de la telaraña (metros)
uniform float spokes = 12.0;
uniform float ring_spacing = 0.065;
uniform float line_width = 0.014;
uniform float long_lines = 6.0;                // modo 0: líneas longitudinales
uniform float hex_size = 0.014;
uniform vec3 fabric : source_color = vec3(0.70, 0.06, 0.07);
uniform vec3 line_color : source_color = vec3(0.03, 0.025, 0.025);
uniform sampler2D reference : source_color, filter_linear_mipmap, repeat_disable;
uniform float ref_radius = 0.47;

varying vec3 opos;

void vertex() {
	opos = VERTEX;
}

float hex_edge(vec2 p) {
	const vec2 s = vec2(1.0, 1.7320508);
	vec4 hc = floor(vec4(p, p - vec2(0.5, 1.0)) / s.xyxy) + 0.5;
	vec4 h = vec4(p - hc.xy * s, p - (hc.zw + 0.5) * s);
	vec2 q = dot(h.xy, h.xy) < dot(h.zw, h.zw) ? h.xy : h.zw;
	q = abs(q);
	return 0.5 - max(dot(q, s * 0.5), q.x);          // 0 en el borde de la celda
}

void fragment() {
	vec3 pm = opos * pattern_scale;
	vec2 pc;
	float dist = 1.0;
	vec3 albedo;
	float line = 0.0;

	if (mode == 2) {
		// Máscara: la esfera de referencia vista de frente (el frente del modelo es +Z).
		vec3 d = normalize(opos);
		vec2 uv = vec2(0.5 - d.x * ref_radius, 0.5 - d.y * ref_radius);
		vec3 ref = texture(reference, uv).rgb;
		float lum = dot(ref, vec3(0.299, 0.587, 0.114));
		line = 1.0 - smoothstep(0.08, 0.2, lum);
		albedo = mix(ref * vec3(1.05, 0.9, 0.9), line_color, line * 0.6);
		pc = uv * 6.0;
	} else {
		if (mode == 0) {
			pc = UV * uv_meters;
			float du = fract(UV.x * long_lines);
			float d_long = min(du, 1.0 - du) * uv_meters.x / long_lines;
			float dv = fract(pc.y / ring_spacing);
			float d_ring = min(dv, 1.0 - dv) * ring_spacing;
			dist = min(d_long, d_ring);
		} else {
			vec2 q = pm.xy - radial_center;
			float r = length(q);
			float th = atan(q.y, q.x);
			float sector = TAU / spokes;
			float a = mod(th + sector * 0.5, sector) - sector * 0.5;
			float d_spoke = r * abs(sin(a));
			// Anillos poligonales ligeramente cóncavos entre radios, como la referencia.
			float a2 = mod(th, sector) - sector * 0.5;
			float rp = r * (cos(a2) + 0.18 * (1.0 - cos(a2 * 2.0)));
			float dv = fract(rp / ring_spacing);
			float d_ring = min(dv, 1.0 - dv) * ring_spacing;
			dist = min(d_spoke, d_ring);
			if (r < ring_spacing * 0.5) {
				dist = abs(r - ring_spacing * 0.5);         // anillo central
			}
			pc = pm.xy;
		}
		float aa = fwidth(dist) + 1e-5;
		float w = line_width * 0.5;
		line = 1.0 - smoothstep(w - aa, w + aa, dist);
		albedo = fabric;
	}

	// Microtextura hexagonal de la tela (se desvanece cuando es menor que un píxel).
	vec2 hp = pc / hex_size;
	float e = hex_edge(hp);
	float fw = length(fwidth(hp));
	float hex_fade = 1.0 - smoothstep(0.35, 0.8, fw);
	float hex_line = (1.0 - smoothstep(0.015, 0.06 + fw, e)) * hex_fade;
	if (mode != 2) {
		albedo = mix(albedo, albedo * 0.72, hex_line);
		albedo = mix(albedo, line_color, line);
	}

	// Relieve: líneas elevadas ~4 mm y celdas ~1 mm (bump por derivadas).
	float height = line * 0.004 + hex_line * 0.001;
	vec3 dpdx = dFdx(VERTEX);
	vec3 dpdy = dFdy(VERTEX);
	float dhdx = dFdx(height);
	float dhdy = dFdy(height);
	vec3 r1 = cross(dpdy, NORMAL);
	vec3 r2 = cross(NORMAL, dpdx);
	float det = dot(dpdx, r1);
	vec3 grad = sign(det) * (dhdx * r1 + dhdy * r2);
	NORMAL = normalize(abs(det) * NORMAL - grad);

	ALBEDO = albedo;
	ROUGHNESS = mix(0.58, 0.14, line);
	METALLIC = mix(0.0, 0.25, line);
	SPECULAR = mix(0.45, 0.7, line);
}
