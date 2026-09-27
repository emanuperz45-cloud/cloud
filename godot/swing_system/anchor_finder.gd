class_name AnchorFinder
extends Node3D
## Detecta y valida puntos de enganche en la geometría real (nunca en el aire).
##
## Barre un abanico de rayos alrededor del punto ideal, amortizado en varios
## frames (rays_per_frame), y guarda los impactos en una caché con caducidad.
## Cada consulta re-puntúa la caché con la posición actual, así que el mejor
## anclaje está listo *antes* de que el jugador pulse el gatillo (latencia 0).
## La puntuación es la misma que swing_core.score_anchor en Python.

class Candidate:
	var point := Vector3.ZERO
	var normal := Vector3.UP
	var ground_y := 0.0
	var score := 0.0
	var stamp := 0.0
	var collider_id := 0

const FORWARD_OFFSETS := [-8.0, -2.0, 4.0, 10.0]
const UP_OFFSETS := [-8.0, 0.0, 8.0]
const LATERAL_MULTS := [0.6, 1.0, 1.6, 2.4, -1.0, -2.0]
const MAX_CANDIDATES := 48
const MERGE_DISTANCE := 1.5

@export var tuning: SwingTuning
## Capa "Swingable": solo geometría estática del mundo. Personajes, vehículos
## y props dinámicos quedan fuera de la máscara.
@export_flags_3d_physics var swingable_mask: int = 1
@export var rays_per_frame: int = 12
@export var candidate_lifetime: float = 0.3
@export var hand_height: float = 0.8
@export var ground_probe_depth: float = 400.0

var exclude: Array[RID] = []
var skyline := 80.0            ## EMA de la altura de los anclajes vistos
var ground_estimate := 0.0

var _candidates: Array[Candidate] = []
var _cursor := 0
var _clock := 0.0


func fan_size() -> int:
	return FORWARD_OFFSETS.size() * UP_OFFSETS.size() * LATERAL_MULTS.size() * 2


@warning_ignore("integer_division")
func scan(pos: Vector3, vel: Vector3, travel: Vector3, delta: float) -> void:
	_clock += delta
	var space := get_world_3d().direct_space_state
	var fwd := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(travel), Vector3.FORWARD)
	var right := fwd.cross(Vector3.UP).normalized()
	var origin := pos + Vector3.UP * hand_height
	var spd := vel.length()
	var total := fan_size()

	for i in rays_per_frame:
		var idx := (_cursor + i) % total
		var side := 1.0 if idx % 2 == 0 else -1.0
		var k := idx / 2
		var lat: float = LATERAL_MULTS[k % LATERAL_MULTS.size()]
		k /= LATERAL_MULTS.size()
		var up_off: float = UP_OFFSETS[k % UP_OFFSETS.size()]
		k /= UP_OFFSETS.size()
		var fwd_off: float = FORWARD_OFFSETS[k % FORWARD_OFFSETS.size()]

		var target := ideal_anchor_point(pos, fwd, side, spd) + fwd * fwd_off \
				+ Vector3.UP * up_off + right * (side * tuning.anchor_ideal_side * (lat - 1.0))
		var dir := (target - origin).normalized()
		var query := PhysicsRayQueryParameters3D.create(
				origin, origin + dir * tuning.anchor_max_distance, swingable_mask, exclude)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider: Object = hit.collider
		if collider is Node and (collider as Node).is_in_group("no_web"):
			continue
		_store(space, pos, hit.position, hit.normal, hit.collider_id)

	_cursor = (_cursor + rays_per_frame) % total
	_prune()


func _store(space: PhysicsDirectSpaceState3D, pos: Vector3, point: Vector3, normal: Vector3,
		collider_id: int) -> void:
	for c in _candidates:
		if c.point.distance_to(point) < MERGE_DISTANCE:
			c.point = point
			c.normal = normal
			c.stamp = _clock
			return
	var c := Candidate.new()
	c.point = point
	c.normal = normal
	c.stamp = _clock
	c.collider_id = collider_id
	c.ground_y = _probe_ground(space, pos, point, normal)
	_candidates.append(c)
	skyline = lerpf(skyline, point.y, 0.05)
	if _candidates.size() > MAX_CANDIDATES:
		_candidates.pop_front()


## Altura del suelo bajo la zona donde caerá el fondo del arco (entre el
## anclaje y el jugador). Si hay un tejado más bajo, cuenta como suelo.
func _probe_ground(space: PhysicsDirectSpaceState3D, pos: Vector3, point: Vector3,
		normal: Vector3) -> float:
	var toward := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(pos - point), Vector3.ZERO)
	var probe := point + toward * 3.0 + normal * 1.0
	var from := Vector3(probe.x, point.y - 0.5, probe.z)
	var q := PhysicsRayQueryParameters3D.create(
			from, from + Vector3.DOWN * ground_probe_depth, swingable_mask, exclude)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return ground_estimate
	ground_estimate = lerpf(ground_estimate, hit.position.y, 0.2)
	return hit.position.y


func _prune() -> void:
	var i := _candidates.size() - 1
	while i >= 0:
		if _clock - _candidates[i].stamp > candidate_lifetime:
			_candidates.remove_at(i)
		i -= 1


func cruise_y() -> float:
	return ground_estimate + tuning.cruise_skyline_fraction * (skyline - ground_estimate)


func anchor_speed_scale(speed: float) -> float:
	return clampf(speed / tuning.target_bottom_speed,
			tuning.anchor_speed_scale_min, tuning.anchor_speed_scale_max)


func ideal_anchor_point(pos: Vector3, fwd: Vector3, side: float, speed: float) -> Vector3:
	var right := fwd.cross(Vector3.UP).normalized()
	var k := anchor_speed_scale(speed)
	return pos + fwd * (tuning.anchor_ideal_forward * k) + Vector3.UP * (tuning.anchor_ideal_up * k) \
			+ right * (side * tuning.anchor_ideal_side)


## Puntuación [0..1] o -1 si es inválido. side: +1 mano derecha, -1 izquierda.
func score(c: Candidate, pos: Vector3, travel: Vector3, side: float, speed: float) -> float:
	var rel := c.point - pos
	var height := rel.y
	var dist := rel.length()
	if height < tuning.anchor_min_height:
		return -1.0
	if dist < tuning.rope_min or dist > tuning.anchor_max_distance:
		return -1.0
	var fwd := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(travel), Vector3.FORWARD)
	var right := fwd.cross(Vector3.UP).normalized()
	var horiz := RegulatedPendulum.flat(rel)
	if horiz.dot(fwd) < -2.0:
		return -1.0                        # detrás del jugador
	if c.point.y - (c.ground_y + tuning.ground_clearance) < tuning.rope_min:
		return -1.0                        # el arco no cabe sobre el suelo
	if c.normal.y < -0.5:
		return -1.0                        # cara inferior de un voladizo

	var ideal := ideal_anchor_point(pos, fwd, side, speed)
	var ideal_up := ideal.y - pos.y
	var s_dist := 1.0 - clampf(c.point.distance_to(ideal) / tuning.anchor_ideal_radius, 0.0, 1.0)
	var s_dir := pow((horiz.normalized().dot(fwd) + 1.0) * 0.5, 2.0)
	var s_height := 1.0 - clampf(absf(height - ideal_up) / ideal_up, 0.0, 1.0)
	var s_side := 1.0 if rel.dot(right) * side > 0.0 else 0.4
	return 0.40 * s_dist + 0.25 * s_dir + 0.20 * s_height + 0.15 * s_side


func best_for(side: float, pos: Vector3, vel: Vector3, travel: Vector3) -> Candidate:
	var best: Candidate = null
	var spd := vel.length()
	for c in _candidates:
		c.score = score(c, pos, travel, side, spd)
		if c.score > 0.0 and (best == null or c.score > best.score):
			best = c
	return best


## Revalida en el frame del disparo: línea de visión real desde la mano.
func validate(c: Candidate, hand_pos: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var dir := (c.point - hand_pos).normalized()
	var q := PhysicsRayQueryParameters3D.create(hand_pos, c.point + dir * 0.5, swingable_mask, exclude)
	var hit := space.intersect_ray(q)
	return not hit.is_empty() and hit.position.distance_to(c.point) < 0.75


## Point launch: puntos de posado marcados (Node3D en el grupo "perch_points"),
## p. ej. generados offline sobre esquinas de azoteas, antenas y farolas.
func find_perch(pos: Vector3, aim: Vector3, max_distance: float) -> Variant:
	var space := get_world_3d().direct_space_state
	var best: Variant = null
	var best_score := -INF
	for node in get_tree().get_nodes_in_group("perch_points"):
		var p: Vector3 = (node as Node3D).global_position
		var to := p - pos
		var d := to.length()
		if d < 3.0 or d > max_distance:
			continue
		var facing := to.normalized().dot(aim.normalized())
		if facing < 0.85:
			continue
		var s := facing * 2.0 - d / max_distance
		if s <= best_score:
			continue
		var q := PhysicsRayQueryParameters3D.create(pos, p + Vector3.UP * 0.5, swingable_mask, exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or hit.position.distance_to(p) < 1.5:
			best = p
			best_score = s
	return best
