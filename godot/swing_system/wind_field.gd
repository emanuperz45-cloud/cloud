class_name WindField
extends RefCounted
## Corrientes de aire para las Web Wings: túneles de viento (segmentos con
## empuje a lo largo del eje) y corrientes ascendentes (columnas verticales).
## La intensidad cae suavemente hacia el borde para que la entrada no sea brusca.

class Tunnel:
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	var radius := 8.0

class Updraft:
	var center := Vector3.ZERO     ## base de la columna (sobre la azotea)
	var height := 70.0
	var radius := 6.0

var tunnels: Array[Tunnel] = []
var updrafts: Array[Updraft] = []

var tunnel_dir := Vector3.ZERO     ## resultado de la última consulta
var tunnel_offset := Vector3.ZERO  ## de la posición al eje del túnel más fuerte
var tunnel := 0.0
var updraft := 0.0


func add_tunnel(a: Vector3, b: Vector3, radius: float) -> void:
	var t := Tunnel.new()
	t.a = a
	t.b = b
	t.radius = radius
	tunnels.append(t)


func add_updraft(base: Vector3, height: float, radius: float) -> void:
	var u := Updraft.new()
	u.center = base
	u.height = height
	u.radius = radius
	updrafts.append(u)


## Evalúa el viento en `pos` y deja el resultado en tunnel_dir / tunnel / updraft.
func sample(pos: Vector3) -> void:
	tunnel = 0.0
	tunnel_dir = Vector3.ZERO
	tunnel_offset = Vector3.ZERO
	updraft = 0.0
	for t in tunnels:
		var ab := t.b - t.a
		var u := clampf((pos - t.a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var closest := t.a + ab * u
		var d := pos.distance_to(closest)
		var k := 1.0 - smoothstep(t.radius * 0.6, t.radius, d)
		k *= smoothstep(0.0, 0.04, u) * (1.0 - smoothstep(0.96, 1.0, u))
		if k > tunnel:
			tunnel = k
			tunnel_dir = ab.normalized()
			tunnel_offset = closest - pos
	for c in updrafts:
		var dxz := Vector2(pos.x - c.center.x, pos.z - c.center.z).length()
		var above := pos.y - c.center.y
		if above < -2.0 or above > c.height:
			continue
		var k := (1.0 - smoothstep(c.radius * 0.5, c.radius, dxz)) * (1.0 - smoothstep(0.75, 1.0, above / c.height))
		updraft = maxf(updraft, k)
