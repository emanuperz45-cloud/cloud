// Corrientes de aire visibles: rayas que fluyen a lo largo de un cilindro abierto
// (túnel de viento horizontal o columna ascendente). Aditivo, sin sombras.
// La coordenada axial sale del vértice (no de la UV del CylinderMesh) para que
// el sentido del flujo sea siempre de la base (-Y local) a la tapa (+Y local).
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 tint : source_color = vec3(0.35, 0.72, 1.0);
uniform float height_m = 100.0;       // altura del CylinderMesh (m)
uniform float speed = 20.0;           // m/s aparentes de las rayas
uniform float intensity = 0.55;
uniform float streaks = 26.0;         // columnas de rayas alrededor del cilindro
uniform float dash_m = 9.0;           // periodo de las rayas (m)

varying float along;
varying float around;

void vertex() {
	along = VERTEX.y / height_m + 0.5;
	around = atan(VERTEX.z, VERTEX.x) / 6.2831853 + 0.5;
}

float hash(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void fragment() {
	float cell = floor(around * streaks);
	float h = hash(cell);
	float phase = along * height_m / dash_m - TIME * speed / dash_m * (0.75 + h * 0.5) + h * 13.0;
	float f = fract(phase);
	float dash = smoothstep(0.0, 0.08, f) * (1.0 - smoothstep(0.3, 0.55, f));
	float lateral = 1.0 - abs(fract(around * streaks) - 0.5) * 2.0;
	dash *= smoothstep(0.35, 0.95, lateral) * step(0.4, h);
	float ends = smoothstep(0.0, 0.06, along) * (1.0 - smoothstep(0.94, 1.0, along));
	float rim = 1.0 - abs(dot(NORMAL, VIEW));
	// Se apaga con la distancia: de lejos solo se ven los anillos.
	float dist = length(VERTEX);
	float near_fade = 1.0 - smoothstep(90.0, 260.0, dist);
	ALBEDO = tint * dash * ends * intensity * (0.35 + rim) * near_fade;
}
