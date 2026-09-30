class_name WebLine
extends MeshInstance3D
## Web visual: cinta orientada a cámara entre la mano y el anclaje real.
##
## SHOOTING: la punta viaja de la mano al anclaje (shoot_time) con un leve
##   latigazo lateral que se amortigua.
## ATTACHED: Verlet con extremos fijos; `tension01` (lo escribe el animador o
##   el controller) controla la holgura: tensa = recta, floja = catenaria.
## RELEASED: la mano se suelta, la web cae colgando del anclaje y se desvanece.
## Fallo (fire_miss): la punta viaja hacia el vacío, no engancha y la cinta cae libre.
## La cinta se afina hacia el anclaje y allí queda una estrella de impacto (splat).
## El material debe usar vertex color como albedo y transparencia alpha.

enum Phase { HIDDEN, SHOOTING, ATTACHED, RELEASED }

@export var segments := 16
@export var width := 0.05
@export var tip_width := 0.025       ## ancho en el anclaje
@export var splat_radius := 0.55
@export var splat_spokes := 7
@export var shoot_time := 0.09
@export var fade_time := 0.6
@export var gravity := 9.81
@export var solver_iterations := 8
@export var material: Material

var phase := Phase.HIDDEN
var tension01 := 1.0

var _hand: Node3D
var _anchor := Vector3.ZERO
var _points := PackedVector3Array()
var _prev := PackedVector3Array()
var _rest_total := 0.0
var _t := 0.0
var _whip_axis := Vector3.RIGHT
var _miss := false                 ## web que no engancha: al llegar la punta se suelta por los dos extremos
var _imesh := ImmediateMesh.new()


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	global_transform = Transform3D.IDENTITY
	mesh = _imesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func fire(hand: Node3D, anchor: Vector3) -> void:
	_hand = hand
	_anchor = anchor
	_miss = false
	_t = 0.0
	phase = Phase.SHOOTING
	var start := _hand_pos()
	_points.resize(segments + 1)
	_prev.resize(segments + 1)
	for i in _points.size():
		_points[i] = start
		_prev[i] = start
	var dir := (anchor - start).normalized()
	_whip_axis = RegulatedPendulum.safe_normalized(dir.cross(Vector3.UP), Vector3.RIGHT)


## Web lanzada al vacío: sale hacia `tip`, no engancha y cae libre.
func fire_miss(hand: Node3D, tip: Vector3) -> void:
	fire(hand, tip)
	_miss = true


func release() -> void:
	if phase == Phase.HIDDEN:
		return
	_rest_total = _anchor.distance_to(_points[0])
	phase = Phase.RELEASED
	_t = 0.0


func _hand_pos() -> Vector3:
	if is_instance_valid(_hand):
		# Posición interpolada: con physics interpolation la mano renderizada va
		# por delante de global_position y la web se vería despegada.
		return _hand.get_global_transform_interpolated().origin
	return _points[0] if not _points.is_empty() else _anchor


func _process(delta: float) -> void:
	if phase == Phase.HIDDEN:
		return
	_t += delta
	var n := _points.size()
	match phase:
		Phase.SHOOTING:
			var k := clampf(_t / shoot_time, 0.0, 1.0)
			var hand := _hand_pos()
			var tip := hand.lerp(_anchor, ease(k, 0.4))
			for i in n:
				var u := float(i) / float(n - 1)
				var whip := sin(u * PI) * (1.0 - k) * 0.6
				_points[i] = hand.lerp(tip, u) + _whip_axis * whip
				_prev[i] = _points[i]
			if k >= 1.0:
				phase = Phase.ATTACHED
				if _miss:
					release()
		Phase.ATTACHED:
			var hand := _hand_pos()
			var slack := lerpf(1.06, 1.0, tension01)
			_simulate(delta, hand, _anchor.distance_to(hand) * slack)
		Phase.RELEASED:
			_simulate(delta, Vector3.INF, _rest_total)
			if _t >= (fade_time * 0.5 if _miss else fade_time):
				phase = Phase.HIDDEN
				_imesh.clear_surfaces()
				return
	_rebuild_mesh()


## Verlet con restricciones de distancia. hand = Vector3.INF deja libre la mano.
func _simulate(delta: float, hand: Vector3, total_length: float) -> void:
	var n := _points.size()
	var pin_hand := hand != Vector3.INF
	var gdt := Vector3.DOWN * gravity * delta * delta
	var first := 1 if pin_hand else 0
	for i in range(first, n if _miss else n - 1):
		var p := _points[i]
		var v := (p - _prev[i]) * 0.98
		_prev[i] = p
		_points[i] = p + v + gdt
	var rest := total_length / float(n - 1)
	for _it in solver_iterations:
		if not _miss:
			_points[n - 1] = _anchor
		if pin_hand:
			_points[0] = hand
		for i in n - 1:
			var d := _points[i + 1] - _points[i]
			var seg_len := d.length()
			if seg_len < 1e-6:
				continue
			var corr := d * (0.5 * (seg_len - rest) / seg_len)
			if i > 0 or not pin_hand:
				_points[i] += corr
			if i + 1 < n - 1 or _miss:
				_points[i + 1] -= corr


func _rebuild_mesh() -> void:
	_imesh.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	var n := _points.size()
	if cam == null or n < 2:
		return
	var alpha := 1.0
	if phase == Phase.RELEASED:
		alpha = 1.0 - clampf(_t / (fade_time * 0.5 if _miss else fade_time), 0.0, 1.0)
	var col := Color(1.0, 1.0, 1.0, alpha)
	_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, material)
	for i in n:
		var p := _points[i]
		var tangent := (_points[mini(i + 1, n - 1)] - _points[maxi(i - 1, 0)]).normalized()
		var to_cam := (cam.global_position - p).normalized()
		var u := float(i) / float(n - 1)
		var side := tangent.cross(to_cam).normalized() * (lerpf(width, tip_width, u) * 0.5)
		_imesh.surface_set_color(col)
		_imesh.surface_set_uv(Vector2(u, 0.0))
		_imesh.surface_add_vertex(p - side)
		_imesh.surface_set_color(col)
		_imesh.surface_set_uv(Vector2(u, 1.0))
		_imesh.surface_add_vertex(p + side)
	_imesh.surface_end()
	if phase != Phase.SHOOTING and not _miss:
		_add_splat(cam, col)


## Estrella de impacto en el anclaje: radios finos en el plano que mira a la cámara.
func _add_splat(cam: Camera3D, col: Color) -> void:
	var to_cam := (cam.global_position - _anchor).normalized()
	var a := RegulatedPendulum.safe_normalized(to_cam.cross(Vector3.UP), Vector3.RIGHT)
	var b := to_cam.cross(a).normalized()
	var center := _anchor + to_cam * 0.05
	var grow := clampf(_t / 0.12, 0.0, 1.0) if phase == Phase.ATTACHED else 1.0
	var r := splat_radius * grow
	_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for i in splat_spokes:
		var ang := TAU * float(i) / splat_spokes + 0.3
		var dir := a * cos(ang) + b * sin(ang)
		var perp := a * -sin(ang) + b * cos(ang)
		var len := r * (0.75 + 0.25 * sin(float(i) * 2.7))
		for v: Vector3 in [center + perp * 0.025, center - perp * 0.025, center + dir * len]:
			_imesh.surface_set_color(col)
			_imesh.surface_set_uv(Vector2.ZERO)
			_imesh.surface_add_vertex(v)
	_imesh.surface_end()
