// Traje sobre el cuerpo continuo (BodyMesh). Todo el dibujo se calcula en la
// posición de enlace del vértice (UV = xy, UV2.x = z; brazos abiertos, frente +Z,
// derecha -X), así la telaraña va pegada a la piel aunque el esqueleto se mueva.
//  - Torso: telaraña radial con centro en el esternón (y otra en la espalda).
//  - Brazos y piernas: líneas longitudinales + anillos combados entre ellas.
//  - Cabeza: telaraña radial que nace entre los ojos + lentes blancas con marco.
//  - Araña negra en el pecho y otra grande en la espalda.
// Las zonas se mezclan con pesos suaves (sin costuras duras), las líneas llevan
// relieve por derivadas y la tela una microtextura hexagonal.
shader_type spatial;

uniform vec3 fabric : source_color = vec3(0.74, 0.05, 0.06);
uniform vec3 fabric_dark : source_color = vec3(0.40, 0.02, 0.03);
uniform vec3 line_color : source_color = vec3(0.02, 0.02, 0.025);
uniform vec3 lens_color : source_color = vec3(0.96, 0.97, 1.0);
uniform float line_width = 0.0048;
uniform float hex_size = 0.011;

// Esqueleto en la pose de enlace (bake_body.py).
const vec3 SH_R = vec3(-0.23, 0.53, 0.0);
const vec3 SH_L = vec3(0.23, 0.53, 0.0);
const vec3 ARM_R = vec3(-0.98481, -0.17365, 0.0);
const vec3 ARM_L = vec3(0.98481, -0.17365, 0.0);
const vec3 HIP_R = vec3(-0.095, -0.05, 0.0);
const vec3 HIP_L = vec3(0.095, -0.05, 0.0);
const vec3 LEG_R = vec3(-0.13917, -0.99027, 0.0);
const vec3 LEG_L = vec3(0.13917, -0.99027, 0.0);

varying vec3 bp;

void vertex() {
	bp = vec3(UV.x, UV.y, UV2.x);
}

float hex_edge(vec2 p) {
	const vec2 s = vec2(1.0, 1.7320508);
	vec4 hc = floor(vec4(p, p - vec2(0.5, 1.0)) / s.xyxy) + 0.5;
	vec4 h = vec4(p - hc.xy * s, p - (hc.zw + 0.5) * s);
	vec2 q = dot(h.xy, h.xy) < dot(h.zw, h.zw) ? h.xy : h.zw;
	q = abs(q);
	return 0.5 - max(dot(q, s * 0.5), q.x);
}

// Distancia (m) a la telaraña radial en el plano; anillos poligonales combados.
float web_radial(vec2 q, float spokes, float spacing) {
	float r = length(q);
	float th = atan(q.y, q.x);
	float sector = TAU / spokes;
	float a = mod(th + sector * 0.5, sector) - sector * 0.5;
	float d_spoke = r * abs(sin(a));
	float a2 = mod(th, sector) - sector * 0.5;
	float rp = r * (cos(a2) + 0.18 * (1.0 - cos(a2 * 2.0)));
	float dv = fract(rp / spacing);
	float d = min(d_spoke, min(dv, 1.0 - dv) * spacing);
	if (r < spacing * 0.5) {
		d = abs(r - spacing * 0.5);
	}
	return d;
}

// Telaraña de extremidad: líneas a lo largo del hueso y anillos combados entre ellas.
float web_limb(vec3 p, vec3 o, vec3 dir, float n_lines, float spacing, out vec2 pc) {
	vec3 v = p - o;
	float a = dot(v, dir);
	vec3 rv = v - dir * a;
	vec3 e1 = normalize(vec3(0.0, 0.0, 1.0) - dir * dir.z);
	vec3 e2 = cross(dir, e1);
	float psi = atan(dot(rv, e2), dot(rv, e1));
	float rad = length(rv);
	float sector = TAU / n_lines;
	float s = mod(psi + sector * 0.5, sector) - sector * 0.5;
	float d_long = rad * abs(s);
	float sag = 0.012 * abs(sin(psi * n_lines * 0.5));
	float av = fract((a - sag) / spacing);
	pc = vec2(psi * rad, a);
	return min(d_long, min(av, 1.0 - av) * spacing);
}

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

float sd_ellipse(vec2 p, vec2 r) {
	return (length(p / r) - 1.0) * min(r.x, r.y);
}

// Araña del emblema (simétrica), en metros con escala 1 = araña del pecho.
float spider(vec2 p) {
	vec2 q = vec2(abs(p.x), p.y);
	float d = sd_ellipse(p - vec2(0.0, -0.012), vec2(0.011, 0.021));
	d = min(d, sd_ellipse(p - vec2(0.0, 0.015), vec2(0.009, 0.011)));
	d = min(d, length(p - vec2(0.0, 0.029)) - 0.006);
	float w = 0.0026;
	d = min(d, min(sd_segment(q, vec2(0.006, 0.018), vec2(0.024, 0.036)), sd_segment(q, vec2(0.024, 0.036), vec2(0.03, 0.06))) - w);
	d = min(d, min(sd_segment(q, vec2(0.007, 0.012), vec2(0.03, 0.022)), sd_segment(q, vec2(0.03, 0.022), vec2(0.043, 0.042))) - w);
	d = min(d, min(sd_segment(q, vec2(0.007, 0.006), vec2(0.03, -0.004)), sd_segment(q, vec2(0.03, -0.004), vec2(0.043, -0.026))) - w);
	d = min(d, min(sd_segment(q, vec2(0.006, 0.0), vec2(0.024, -0.022)), sd_segment(q, vec2(0.024, -0.022), vec2(0.03, -0.048))) - w);
	return d;
}

// Lente de la máscara: almendra inclinada (extremo exterior hacia arriba), más
// ancha por fuera. Devuelve la SDF (m) respecto al borde exterior del marco.
float lens(vec2 p, float side) {
	vec2 c = vec2(side * 0.046, 0.806);
	float ang = radians(24.0);
	vec2 u = normalize(vec2(side * cos(ang), sin(ang)));
	vec2 v = vec2(-u.y, u.x);
	vec2 l = vec2(dot(p - c, u), dot(p - c, v));
	float widen = 0.78 + 0.38 * clamp(l.x / 0.04 * 0.5 + 0.5, 0.0, 1.0);
	return sd_ellipse(l, vec2(0.043, 0.027 * widen));
}

void fragment() {
	// --- Pesos de zona -------------------------------------------------------
	float right = step(bp.x, 0.0);
	vec3 sh = mix(SH_L, SH_R, right);
	vec3 arm_dir = mix(ARM_L, ARM_R, right);
	vec3 hip = mix(HIP_L, HIP_R, right);
	vec3 leg_dir = mix(LEG_L, LEG_R, right);
	float w_arm = smoothstep(0.03, 0.08, dot(bp - sh, arm_dir)) * step(0.15, bp.y);
	float w_leg = smoothstep(0.1, 0.17, dot(bp - hip, leg_dir)) * (1.0 - w_arm);
	float w_head = smoothstep(0.615, 0.645, bp.y) * (1.0 - w_arm);
	float w_torso = clamp(1.0 - w_arm - w_leg - w_head, 0.0, 1.0);

	// --- Telaraña por zona ---------------------------------------------------
	float front = step(0.0, bp.z);
	vec2 torso_q = vec2(bp.x, bp.y - mix(0.37, 0.36, front));
	float d_torso = web_radial(torso_q, 14.0, 0.068);
	vec2 pc_arm;
	vec2 pc_leg;
	float d_arm = web_limb(bp, sh, arm_dir, 8.0, 0.062, pc_arm);
	float d_leg = web_limb(bp, hip, leg_dir, 10.0, 0.07, pc_leg);
	vec3 hv = normalize(bp - vec3(0.0, 0.80, 0.0));
	float th = acos(clamp(hv.z, -1.0, 1.0));
	vec2 head_q = th * 0.11 * normalize(hv.xy + vec2(1e-5));
	float d_head = web_radial(head_q, 16.0, 0.036);

	float line = 0.0;
	float w = line_width * 0.5;
	float aa;
	aa = fwidth(d_torso) + 1e-5;
	line += w_torso * (1.0 - smoothstep(w - aa, w + aa, d_torso));
	aa = fwidth(d_arm) + 1e-5;
	line += w_arm * (1.0 - smoothstep(w - aa, w + aa, d_arm));
	aa = fwidth(d_leg) + 1e-5;
	line += w_leg * (1.0 - smoothstep(w - aa, w + aa, d_leg));
	aa = fwidth(d_head) + 1e-5;
	line += w_head * (1.0 - smoothstep(w * 0.85 - aa, w * 0.85 + aa, d_head));

	// --- Araña: pecho (delante) y grande en la espalda ------------------------
	float d_sp = bp.z > 0.0 ? spider(bp.xy - vec2(0.0, 0.405)) : spider((bp.xy - vec2(0.0, 0.36)) / 2.1) * 2.1;
	aa = fwidth(d_sp) + 1e-5;
	float emblem = (1.0 - smoothstep(-aa, aa, d_sp)) * w_torso;
	line = max(line, emblem);

	// --- Tela: microtextura y volumen (costados más oscuros) ------------------
	vec2 pc = w_arm > 0.5 ? pc_arm : (w_leg > 0.5 ? pc_leg : bp.xy + vec2(bp.z * 0.7, 0.0));
	vec2 hp = pc / hex_size;
	float fw = length(fwidth(hp));
	float hex_line = (1.0 - smoothstep(0.015, 0.06 + fw, hex_edge(hp))) * (1.0 - smoothstep(0.35, 0.8, fw));
	float sides = w_torso * smoothstep(0.11, 0.19, abs(bp.x)) * (1.0 - smoothstep(0.02, 0.09, abs(bp.z)));
	vec3 albedo = mix(fabric, fabric_dark, sides * 0.55);
	albedo = mix(albedo, albedo * 0.74, hex_line);
	albedo = mix(albedo, line_color, clamp(line, 0.0, 1.0));

	// --- Lentes (solo en la cara) -----------------------------------------------
	float lens_mask = 0.0;
	float frame = 0.0;
	if (bp.y > 0.72 && bp.z > 0.02) {
		float d_lens = min(lens(bp.xy, 1.0), lens(bp.xy, -1.0));
		aa = fwidth(d_lens) + 1e-5;
		frame = 1.0 - smoothstep(-aa, aa, d_lens);
		lens_mask = 1.0 - smoothstep(-0.0055 - aa, -0.0055 + aa, d_lens);
		albedo = mix(albedo, line_color, frame);
		albedo = mix(albedo, lens_color, lens_mask);
	}

	// --- Relieve de las líneas (bump por derivadas) ------------------------------
	float height = clamp(line, 0.0, 1.0) * 0.003 + hex_line * 0.0008 + frame * 0.002;
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
	ROUGHNESS = mix(mix(0.56, 0.2, clamp(line, 0.0, 1.0)), 0.06, lens_mask);
	METALLIC = mix(0.0, 0.2, clamp(line, 0.0, 1.0));
	SPECULAR = mix(0.45, 0.7, max(clamp(line, 0.0, 1.0), lens_mask));
	EMISSION = lens_color * lens_mask * 0.08;
}
