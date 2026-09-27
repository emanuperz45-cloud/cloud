class_name Mannequin
extends Node3D
## Personaje procedural hecho de primitivas y animado por código a partir del
## estado físico (fase del arco, fuerza G, velocidad). En la demo sustituye al
## rig + AnimationTree de la sección 3 aplicando las mismas reglas:
##  - swing: pose indexada por la fase φ, brazo de agarre apuntando a la web,
##    brazo libre que anticipa el siguiente disparo, piernas que se recogen con G;
##  - suelta perfecta: voltereta; truco: tirabuzón; picada: cuerpo en flecha.
## El frente del modelo es +Z; su derecha es -X. Se actualiza en
## _physics_process para que la physics interpolation lo suavice.

const RED := Color(0.72, 0.07, 0.09)
const BLUE := Color(0.1, 0.17, 0.52)
const WHITE := Color(0.95, 0.95, 0.97)

var controller: TraversalController
var hand_socket_left: Node3D
var hand_socket_right: Node3D

var _pelvis: Node3D
var _spine: Node3D
var _joints := {}
var _mats := {}
var _time := 0.0
var _run_phase := 0.0
var _flip := 1.0
var _lean := 0.0


func _ready() -> void:
	_build()
	controller.web_released.connect(_on_web_released)


# ---------------------------------------------------------------------------
# Construcción
# ---------------------------------------------------------------------------
func _mat(c: Color) -> StandardMaterial3D:
	if not _mats.has(c):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.45
		_mats[c] = m
	return _mats[c]


func _pivot(parent: Node3D, pos: Vector3, key := "") -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	if key != "":
		_joints[key] = n
	return n


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _mat(color)
	parent.add_child(mi)


func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	m.radial_segments = 12
	m.rings = 4
	return m


func _sphere(r: float, h := -1.0) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0 if h < 0.0 else h
	m.radial_segments = 16
	m.rings = 8
	return m


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


static func _s(side: int) -> String:
	return "r" if side > 0 else "l"


func _build() -> void:
	_pelvis = _pivot(self, Vector3.ZERO, "pelvis")
	_part(_pelvis, _box(Vector3(0.3, 0.16, 0.19)), Vector3.ZERO, BLUE)
	_spine = _pivot(_pelvis, Vector3(0.0, 0.07, 0.0), "spine")
	_part(_spine, _capsule(0.16, 0.52), Vector3(0.0, 0.26, 0.0), RED)
	_part(_spine, _box(Vector3(0.36, 0.12, 0.2)), Vector3(0.0, 0.44, 0.0), RED)
	var head := _pivot(_spine, Vector3(0.0, 0.56, 0.0), "head")
	_part(head, _sphere(0.115), Vector3(0.0, 0.12, 0.0), RED)
	for ex in [-0.045, 0.045]:
		_part(head, _sphere(0.035, 0.05), Vector3(ex, 0.14, 0.095), WHITE)

	for side in [1, -1]:                  # +1 derecha (-X), -1 izquierda (+X)
		var sx := -float(side)
		var s := _s(side)
		var sh := _pivot(_spine, Vector3(sx * 0.22, 0.44, 0.0), "sh_" + s)
		_part(sh, _capsule(0.055, 0.32), Vector3(0.0, -0.15, 0.0), RED)
		var el := _pivot(sh, Vector3(0.0, -0.3, 0.0), "el_" + s)
		_part(el, _capsule(0.05, 0.3), Vector3(0.0, -0.14, 0.0), RED)
		var hand := _pivot(el, Vector3(0.0, -0.3, 0.0))
		_part(hand, _sphere(0.055), Vector3.ZERO, RED)
		if side > 0:
			hand_socket_right = hand
		else:
			hand_socket_left = hand
		var hip := _pivot(_pelvis, Vector3(sx * 0.1, -0.05, 0.0), "hip_" + s)
		_part(hip, _capsule(0.075, 0.46), Vector3(0.0, -0.215, 0.0), BLUE)
		var knee := _pivot(hip, Vector3(0.0, -0.43, 0.0), "kn_" + s)
		_part(knee, _capsule(0.065, 0.44), Vector3(0.0, -0.21, 0.0), BLUE)
		_part(knee, _box(Vector3(0.1, 0.07, 0.24)), Vector3(0.0, -0.44, 0.05), RED)


# ---------------------------------------------------------------------------
# Poses
# ---------------------------------------------------------------------------
static func _q(x_deg: float, z_deg := 0.0) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(x_deg), 0.0, deg_to_rad(z_deg)))


## fwd > 0 adelanta el brazo, out > 0 lo abre hacia fuera, elbow > 0 lo flexiona.
static func _arm(pose: Dictionary, side: int, fwd: float, out: float, elbow: float) -> void:
	pose["sh_" + _s(side)] = _q(-fwd, -side * out)
	pose["el_" + _s(side)] = _q(-elbow)


## fwd > 0 adelanta el muslo, knee > 0 flexiona la rodilla hacia atrás.
static func _leg(pose: Dictionary, side: int, fwd: float, out: float, knee: float) -> void:
	pose["hip_" + _s(side)] = _q(-fwd, -side * out)
	pose["kn_" + _s(side)] = _q(knee)


## Rotación local del hombro para que el brazo (eje -Y) apunte a un punto del mundo.
func _aim_arm(side: int, world_target: Vector3) -> Quaternion:
	var sh: Node3D = _joints["sh_" + _s(side)]
	var d := (world_target - sh.global_position).normalized()
	var local_d := (_spine.global_transform.basis.orthonormalized().inverse() * d).normalized()
	var y := -local_d
	var ref := Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.BACK
	var x := (ref - y * y.dot(ref)).normalized()
	return Quaternion(Basis(x, y, x.cross(y)).orthonormalized())


func _pose_swing(pose: Dictionary) -> void:
	var c := controller
	var p := c.pendulum
	var ph := p.phase
	var t01 := (ph + 1.0) * 0.5
	var g := clampf((p.g_force - 1.0) / 5.0, 0.0, 1.0)
	var aggr := clampf((c.velocity.length() - 22.0) / 6.0, 0.0, 1.0)
	var grip := c.hand if c.hand != 0 else 1
	# Brazo de agarre: recto sobre la web cuando hay tensión (IK de la sección 3.3).
	pose["sh_" + _s(grip)] = _aim_arm(grip, p.anchor)
	pose["el_" + _s(grip)] = _q(-(1.0 - clampf(p.g_force / 1.5, 0.0, 1.0)) * 35.0)
	# Brazo libre: atrás en la caída, buscando el siguiente anclaje en la subida.
	var reach := smoothstep(0.1, 0.7, ph)
	_arm(pose, -grip, lerpf(-20.0, 150.0, reach), lerpf(55.0, 25.0, reach), lerpf(35.0, 10.0, reach))
	# Piernas: de atrás hacia delante con la fase; se recogen con la fuerza G.
	var thigh := lerpf(-20.0, 70.0, t01) + g * 35.0
	var knee := lerpf(40.0, 12.0, clampf(ph, 0.0, 1.0)) + g * 70.0
	var split := aggr * 30.0
	_leg(pose, 1, thigh + split, 6.0, knee)
	_leg(pose, -1, thigh - split, 6.0, knee + aggr * 25.0)
	pose["spine"] = _q(lerpf(-14.0, 14.0, t01) - g * 8.0)
	pose["head"] = _q(-18.0)


func _pose_fall(pose: Dictionary) -> void:
	var v := controller.velocity
	if controller.trick_timer > 0.0:
		_arm(pose, 1, 60.0, 20.0, 95.0)
		_arm(pose, -1, 60.0, 20.0, 95.0)
		_leg(pose, 1, 100.0, 10.0, 125.0)
		_leg(pose, -1, 100.0, 10.0, 125.0)
		pose["spine"] = _q(30.0)
		pose["head"] = _q(10.0)
		return
	var rising := clampf(v.y / 15.0, -1.0, 1.0)
	var flutter := sin(_time * 9.0) * clampf(-v.y / 40.0, 0.0, 1.0) * 10.0
	_arm(pose, 1, 25.0 + flutter, 70.0, 25.0)
	_arm(pose, -1, 25.0 - flutter, 70.0, 25.0)
	_leg(pose, 1, 15.0 + rising * 25.0, 8.0, 25.0 + rising * 40.0)
	_leg(pose, -1, 35.0 + rising * 20.0, 8.0, 60.0)
	pose["spine"] = _q(8.0 + rising * 10.0)
	pose["head"] = _q(-10.0)


func _pose_dive(pose: Dictionary) -> void:
	var flutter := sin(_time * 16.0) * clampf(controller.velocity.length() / 58.0, 0.0, 1.0) * 4.0
	_arm(pose, 1, 0.0, 10.0 + flutter, 5.0)
	_arm(pose, -1, 0.0, 10.0 - flutter, 5.0)
	_leg(pose, 1, flutter, 3.0, 5.0)
	_leg(pose, -1, -flutter, 3.0, 5.0)
	pose["spine"] = _q(0.0)
	pose["head"] = _q(-35.0)


func _pose_zip(pose: Dictionary) -> void:
	_arm(pose, 1, 88.0, 8.0, 5.0)
	_arm(pose, -1, 88.0, 8.0, 5.0)
	_leg(pose, 1, -15.0, 5.0, 35.0)
	_leg(pose, -1, -5.0, 5.0, 55.0)
	pose["spine"] = _q(-5.0)
	pose["head"] = _q(-10.0)


func _pose_perch(pose: Dictionary) -> void:
	_arm(pose, 1, 35.0, 15.0, 70.0)
	_arm(pose, -1, 35.0, 15.0, 70.0)
	_leg(pose, 1, 100.0, 14.0, 125.0)
	_leg(pose, -1, 100.0, 14.0, 125.0)
	pose["spine"] = _q(40.0)
	pose["head"] = _q(-35.0)


func _pose_run(pose: Dictionary, delta: float, speed: float) -> void:
	_run_phase += delta * clampf(speed, 2.0, 25.0) * 0.9
	var s := sin(_run_phase)
	var c := cos(_run_phase)
	_leg(pose, 1, s * 50.0, 4.0, 20.0 + maxf(0.0, -c) * 80.0)
	_leg(pose, -1, -s * 50.0, 4.0, 20.0 + maxf(0.0, c) * 80.0)
	_arm(pose, 1, -s * 45.0, 10.0, 70.0)
	_arm(pose, -1, s * 45.0, 10.0, 70.0)
	pose["spine"] = _q(12.0)
	pose["head"] = _q(-8.0)


func _pose_idle(pose: Dictionary) -> void:
	var breathe := sin(_time * 2.0) * 2.0
	_arm(pose, 1, 5.0, 8.0 + breathe, 12.0)
	_arm(pose, -1, 5.0, 8.0 + breathe, 12.0)
	_leg(pose, 1, 0.0, 4.0, 3.0)
	_leg(pose, -1, 0.0, 4.0, 3.0)
	pose["spine"] = _q(2.0)
	pose["head"] = _q(0.0)


func _on_web_released(_hand: int, perfect: bool) -> void:
	if perfect and not controller.last_release_chained:
		_flip = 0.0                         # voltereta de suelta perfecta


func _physics_process(delta: float) -> void:
	if controller == null:
		return
	_time += delta
	var c := controller
	var pose := {}
	var rate := 16.0
	match c.state:
		TraversalController.State.SWING:
			_pose_swing(pose)
			rate = 24.0
		TraversalController.State.DIVE:
			_pose_dive(pose)
		TraversalController.State.WEB_ZIP, TraversalController.State.POINT_ZIP:
			_pose_zip(pose)
		TraversalController.State.PERCH:
			_pose_perch(pose)
		TraversalController.State.WALL_RUN:
			_pose_run(pose, delta, c.velocity.length())
		TraversalController.State.GROUNDED:
			if RegulatedPendulum.flat(c.velocity).length() > 1.0:
				_pose_run(pose, delta, RegulatedPendulum.flat(c.velocity).length())
			else:
				_pose_idle(pose)
		_:
			_pose_fall(pose)

	var k := 1.0 - exp(-rate * delta)
	for key: String in pose:
		var node: Node3D = _joints[key]
		node.quaternion = node.quaternion.slerp(pose[key], k)

	# Pelvis: inclinación al girar, voltereta de suelta perfecta, tirabuzón de truco.
	var steer := c.move_input.x if c.state == TraversalController.State.SWING else 0.0
	_lean = lerpf(_lean, -steer * deg_to_rad(22.0), k)
	_flip = minf(_flip + delta / 0.5, 1.0)
	var flip_angle := TAU * smoothstep(0.0, 1.0, _flip) if _flip < 1.0 else 0.0
	var spin := 0.0
	if c.trick_timer > 0.0:
		spin = TAU * 2.0 * smoothstep(0.0, 1.0, 1.0 - c.trick_timer / 0.6)
	_pelvis.quaternion = Quaternion(Vector3.UP, spin) * Quaternion(Vector3.RIGHT, flip_angle) \
			* Quaternion(Vector3.BACK, _lean)
	var crouch := -0.32 if c.state == TraversalController.State.PERCH else 0.0
	_pelvis.position.y = lerpf(_pelvis.position.y, crouch, k)
