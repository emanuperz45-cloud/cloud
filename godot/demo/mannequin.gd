class_name Mannequin
extends Node3D
## Personaje procedural con el traje de la referencia (suit.gdshader) animado por
## código a partir del estado físico. Sustituye al rig + AnimationTree de la
## sección 3 aplicando las mismas reglas:
##  - swing: pose indexada por la fase φ, brazo de agarre sobre la web, brazo libre
##    que anticipa el siguiente disparo, piernas que se recogen con la fuerza G;
##  - colgado: las dos manos en la telaraña, piernas colgando con inercia; al subir
##    por la web, mano sobre mano;
##  - pared: carrera (pies en la pared) o gateo (pegado a la fachada);
##  - suelo: carrera/sprint, agachado al cargar el salto, aterrizaje de superhéroe,
##    rodada;
##  - acrobacias: volteretas y tirabuzones en sueltas, trucos, Quick Recovery, esquinas;
##  - Web Wings: brazos y piernas abiertos, membranas muñeca-hombro-cadera que se
##    despliegan, alabeo y cabeceo según el stick; Super Slingshot: tensado hacia atrás.
## Las articulaciones siguen la pose con muelles amortiguados (ζ < 1): los brazos y
## las piernas llegan con un pequeño rebote, que da peso a los cambios de pose.
## El frente del modelo es +Z y su derecha -X. Se actualiza en _physics_process
## para que la physics interpolation lo suavice.

const SUIT := preload("res://demo/suit.gdshader")
const WING := preload("res://demo/wing.gdshader")
const REFERENCE := preload("res://demo/textures/suit_reference.webp")
const WHITE := Color(0.96, 0.97, 1.0)
const BLACK := Color(0.02, 0.02, 0.025)

var controller: TraversalController
var hand_socket_left: Node3D
var hand_socket_right: Node3D

var _pelvis: Node3D
var _spine: Node3D
var _joints := {}
var _time := 0.0
var _cycle := 0.0
var _lean := 0.0
var _flip_t := 1.0
var _flip_axis := Vector3.RIGHT
var _flip_turns := 1.0
var _flip_time := 0.5
var _joint_vel := {}
var _wings_open := 0.0
var _wing_mesh := ImmediateMesh.new()
var _wing_mat := ShaderMaterial.new()
var _loop_spin := 0.0


func _ready() -> void:
	_build()
	controller.web_released.connect(_on_web_released)
	controller.trick_started.connect(_on_trick)
	controller.landed.connect(_on_landed)
	controller.quick_recovered.connect(func() -> void: _start_flip(Vector3.RIGHT, 1.0, 0.55))
	controller.corner_turned.connect(func(launched: bool) -> void:
		if launched:
			_start_flip(Vector3.RIGHT, 1.0, 0.6))
	controller.point_launched.connect(func(perfect: bool) -> void:
		if perfect:
			_start_flip(Vector3.RIGHT, 1.0, 0.6))
	controller.slingshot_launched.connect(func(c: float) -> void:
		if c > 0.6:
			_start_flip(Vector3.RIGHT, 1.0 if c < 0.95 else 2.0, 0.5 + c * 0.35))
	controller.wings_opened.connect(func(boosted: bool) -> void:
		if boosted:
			_start_flip(Vector3.UP, 1.0, 0.4))
	_wing_mat.shader = WING
	var wings := MeshInstance3D.new()
	wings.name = "WebWings"
	wings.mesh = _wing_mesh
	wings.material_override = _wing_mat
	add_child(wings)


# ---------------------------------------------------------------------------
# Construcción del cuerpo
# ---------------------------------------------------------------------------
func _suit(mode: int, params := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SUIT
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("reference", REFERENCE)
	for key: String in params:
		m.set_shader_parameter(key, params[key])
	return m


func _limb_mat(radius: float, length: float) -> ShaderMaterial:
	return _suit(0, {"uv_meters": Vector2(TAU * radius, length)})


func _flat(color: Color, rough := 0.2) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


func _pivot(parent: Node3D, pos: Vector3, key := "") -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	if key != "":
		_joints[key] = n
	return n


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, scl := Vector3.ONE,
		rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.scale = scl
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	m.radial_segments = 16
	m.rings = 6
	return m


func _sphere(r: float, h := -1.0) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0 if h < 0.0 else h
	m.radial_segments = 24
	m.rings = 12
	return m


func _cylinder(r_top: float, r_bottom: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bottom
	m.height = h
	m.radial_segments = 16
	m.rings = 2
	return m


static func _s(side: int) -> String:
	return "r" if side > 0 else "l"


func _build() -> void:
	_pelvis = _pivot(self, Vector3.ZERO, "pelvis")
	_part(_pelvis, _sphere(1.0), Vector3.ZERO,
			_suit(1, {"pattern_scale": Vector3(0.17, 0.12, 0.12), "radial_center": Vector2(0.0, -0.1),
				"spokes": 10.0}), Vector3(0.17, 0.12, 0.12))
	_spine = _pivot(_pelvis, Vector3(0.0, 0.06, 0.0), "spine")
	_part(_spine, _cylinder(0.15, 0.14, 0.26), Vector3(0.0, 0.12, 0.0), _limb_mat(0.15, 0.26))
	# Pecho: telaraña radial centrada en el esternón (y en la espalda).
	_part(_spine, _sphere(1.0), Vector3(0.0, 0.38, 0.0),
			_suit(1, {"pattern_scale": Vector3(0.21, 0.2, 0.135), "radial_center": Vector2(0.0, 0.02)}),
			Vector3(0.21, 0.2, 0.135))
	_part(_spine, _cylinder(0.05, 0.055, 0.1), Vector3(0.0, 0.58, 0.0), _limb_mat(0.05, 0.1))
	var head := _pivot(_spine, Vector3(0.0, 0.6, 0.0), "head")
	_part(head, _sphere(0.115, 0.26), Vector3(0.0, 0.12, 0.0), _suit(2))
	for side in [1, -1]:
		# Lentes blancas con marco negro, inclinadas hacia fuera como en la máscara.
		var ex := -float(side) * 0.047
		var tilt := Vector3(0.0, -float(side) * 18.0, -float(side) * 22.0)
		_part(head, _sphere(1.0), Vector3(ex, 0.14, 0.094), _flat(BLACK, 0.3),
				Vector3(0.05, 0.036, 0.02), tilt)
		_part(head, _sphere(1.0), Vector3(ex * 1.02, 0.141, 0.1), _flat(WHITE, 0.1),
				Vector3(0.042, 0.029, 0.018), tilt)

	for side in [1, -1]:                  # +1 derecha (-X), -1 izquierda (+X)
		var sx := -float(side)
		var s := _s(side)
		var sh := _pivot(_spine, Vector3(sx * 0.23, 0.47, 0.0), "sh_" + s)
		_part(sh, _sphere(0.072), Vector3.ZERO, _limb_mat(0.072, 0.14))
		_part(sh, _capsule(0.055, 0.33), Vector3(0.0, -0.15, 0.0), _limb_mat(0.055, 0.33))
		var el := _pivot(sh, Vector3(0.0, -0.3, 0.0), "el_" + s)
		_part(el, _capsule(0.047, 0.3), Vector3(0.0, -0.14, 0.0), _limb_mat(0.047, 0.3))
		var hand := _pivot(el, Vector3(0.0, -0.3, 0.0))
		_part(hand, _sphere(0.05, 0.12), Vector3(0.0, -0.02, 0.0), _limb_mat(0.05, 0.12))
		if side > 0:
			hand_socket_right = hand
		else:
			hand_socket_left = hand
		var hip := _pivot(_pelvis, Vector3(sx * 0.095, -0.05, 0.0), "hip_" + s)
		_part(hip, _capsule(0.08, 0.47), Vector3(0.0, -0.215, 0.0), _limb_mat(0.08, 0.47))
		var knee := _pivot(hip, Vector3(0.0, -0.43, 0.0), "kn_" + s)
		_part(knee, _capsule(0.063, 0.45), Vector3(0.0, -0.21, 0.0), _limb_mat(0.063, 0.45))
		_part(knee, _capsule(0.052, 0.25), Vector3(0.0, -0.44, 0.06), _limb_mat(0.052, 0.25),
				Vector3.ONE, Vector3(90.0, 0.0, 0.0))


# ---------------------------------------------------------------------------
# Utilidades de pose
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


func _local_velocity() -> Vector3:
	return global_transform.basis.orthonormalized().inverse() * controller.velocity


func _start_flip(axis: Vector3, turns: float, duration: float) -> void:
	_flip_axis = axis
	_flip_turns = turns
	_flip_time = duration
	_flip_t = 0.0


# ---------------------------------------------------------------------------
# Poses por estado
# ---------------------------------------------------------------------------
func _pose_swing(pose: Dictionary) -> void:
	var c := controller
	var p := c.pendulum
	var ph := p.phase
	var t01 := (ph + 1.0) * 0.5
	var g := clampf((p.g_force - 1.0) / 5.0, 0.0, 1.0)
	var aggr := clampf((c.velocity.length() - 22.0) / 6.0, 0.0, 1.0)
	var grip := c.hand if c.hand != 0 else 1
	pose["sh_" + _s(grip)] = _aim_arm(grip, p.anchor)
	pose["el_" + _s(grip)] = _q(-(1.0 - clampf(p.g_force / 1.5, 0.0, 1.0)) * 35.0)
	var reach := smoothstep(0.1, 0.7, ph)
	_arm(pose, -grip, lerpf(-25.0, 150.0, reach), lerpf(60.0, 25.0, reach), lerpf(40.0, 10.0, reach))
	# Piernas: de atrás hacia delante con la fase; se recogen con la fuerza G.
	var thigh := lerpf(-25.0, 75.0, t01) + g * 35.0
	var knee := lerpf(45.0, 10.0, clampf(ph, 0.0, 1.0)) + g * 70.0
	var split := aggr * 32.0
	_leg(pose, 1, thigh + split, 6.0, knee)
	_leg(pose, -1, thigh - split, 6.0, knee + aggr * 30.0)
	pose["spine"] = _q(lerpf(-16.0, 14.0, t01) - g * 8.0)
	pose["head"] = _q(-18.0)


func _pose_hang(pose: Dictionary, delta: float) -> void:
	var c := controller
	var p := c.pendulum
	var grip := c.hand if c.hand != 0 else 1
	var web_dir := (p.anchor - global_position).normalized()
	var climbing := absf(c.move_input.y) > 0.3
	if climbing:
		_cycle += delta * 7.0
	# Las dos manos en la telaraña; al subir o bajar, mano sobre mano.
	var lift := sin(_cycle) * 0.22 if climbing else 0.0
	var top := global_position + web_dir * 1.3
	pose["sh_" + _s(grip)] = _aim_arm(grip, top + web_dir * lift)
	pose["el_" + _s(grip)] = _q(-10.0 - maxf(-lift, 0.0) * 150.0)
	pose["sh_" + _s(-grip)] = _aim_arm(-grip, top - web_dir * (0.3 + lift))
	pose["el_" + _s(-grip)] = _q(-35.0 - maxf(lift, 0.0) * 150.0)
	# Piernas colgando con inercia: se quedan atrás respecto a la velocidad.
	var lv := _local_velocity()
	var swing_lag := clampf(-lv.z * 3.0, -35.0, 35.0)
	var side_lag := clampf(lv.x * 3.0, -20.0, 20.0)
	var kick := sin(_time * 1.7) * 4.0
	var climb_r := sin(_cycle) * 25.0 if climbing else 0.0
	var climb_l := cos(_cycle) * 25.0 if climbing else 0.0
	_leg(pose, 1, 8.0 + swing_lag + kick, 5.0 + side_lag, 22.0 + climb_r)
	_leg(pose, -1, 14.0 + swing_lag - kick, 5.0 - side_lag, 35.0 + climb_l)
	pose["spine"] = _q(-6.0 + swing_lag * 0.2)
	pose["head"] = _q(-5.0)


func _pose_fall(pose: Dictionary) -> void:
	var v := controller.velocity
	if controller.trick_timer > 0.0 or _flip_t < 1.0:
		_arm(pose, 1, 60.0, 20.0, 95.0)
		_arm(pose, -1, 60.0, 20.0, 95.0)
		_leg(pose, 1, 100.0, 10.0, 125.0)
		_leg(pose, -1, 100.0, 10.0, 125.0)
		pose["spine"] = _q(30.0)
		pose["head"] = _q(10.0)
		if controller.trick_timer > 0.0 and controller.trick_index in [
				TraversalController.Trick.ROLL_LEFT, TraversalController.Trick.ROLL_RIGHT]:
			_arm(pose, 1, 10.0, 95.0, 5.0)      # tirabuzón: brazos abiertos en cruz
			_arm(pose, -1, 10.0, 95.0, 5.0)
			_leg(pose, 1, 0.0, 12.0, 5.0)
			_leg(pose, -1, 0.0, 12.0, 5.0)
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


func _pose_glide(pose: Dictionary) -> void:
	var c := controller
	var pitch_in := -c.move_input.y            # +1 picar, -1 encabritar (flare)
	var bank := c.wings.bank / deg_to_rad(c.tuning.glide_max_bank_deg)
	var dive := maxf(pitch_in, 0.0)
	var flare := maxf(-pitch_in, 0.0)
	var buffet := sin(_time * 23.0) * clampf(c.wings.speed / 45.0, 0.0, 1.0) * 2.5
	if c.wings.stalled:
		buffet += sin(_time * 11.0) * 8.0
	for side in [1, -1]:
		# Alabeo: el ala del lado del giro baja (hacia el pecho) y la otra sube.
		var roll := bank * float(side) * 22.0
		var out := lerpf(88.0, 58.0, dive) + flare * 18.0 + buffet * float(side)
		_arm(pose, side, -6.0 + roll + flare * 18.0, out, 6.0 + dive * 14.0)
		_leg(pose, side, -4.0 - flare * 10.0 + roll * 0.4, 9.0 + flare * 6.0 - dive * 5.0,
				8.0 + flare * 30.0)
	pose["spine"] = _q(-10.0 - flare * 8.0 + dive * 4.0)
	pose["head"] = _q(-42.0 + dive * 12.0)


func _pose_slingshot(pose: Dictionary) -> void:
	var ch := controller.slingshot_charge
	var shake := sin(_time * 40.0) * ch * ch * 3.0
	# Cada mano agarra su web (hacia su anclaje); el cuerpo se sienta hacia atrás.
	for side in [1, -1]:
		var anchor: Vector3 = controller.slingshot_anchors[1 if side > 0 else 0]
		pose["sh_" + _s(side)] = _aim_arm(side, anchor)
		pose["el_" + _s(side)] = _q(-lerpf(30.0, 8.0, ch) + shake)
		_leg(pose, side, lerpf(55.0, 95.0, ch), 14.0, lerpf(75.0, 125.0, ch))
	pose["spine"] = _q(lerpf(5.0, -22.0, ch))
	pose["head"] = _q(lerpf(-10.0, 12.0, ch))


func _pose_crouch(pose: Dictionary, amount: float) -> void:
	_arm(pose, 1, lerpf(5.0, -35.0, amount), 15.0, lerpf(12.0, 40.0, amount))
	_arm(pose, -1, lerpf(5.0, -35.0, amount), 15.0, lerpf(12.0, 40.0, amount))
	_leg(pose, 1, 100.0 * amount, 12.0, 125.0 * amount)
	_leg(pose, -1, 100.0 * amount, 12.0, 125.0 * amount)
	pose["spine"] = _q(40.0 * amount)
	pose["head"] = _q(-35.0 * amount)


func _pose_hero_landing(pose: Dictionary) -> void:
	# Aterrizaje de superhéroe: rodilla derecha al suelo, puño derecho apoyado.
	_arm(pose, 1, 35.0, 25.0, 15.0)
	_arm(pose, -1, -40.0, 55.0, 30.0)
	_leg(pose, 1, 25.0, 12.0, 120.0)
	_leg(pose, -1, 95.0, 10.0, 105.0)
	pose["spine"] = _q(38.0)
	pose["head"] = _q(-40.0)


func _pose_run(pose: Dictionary, delta: float, speed: float, sprint: bool) -> void:
	_cycle += delta * clampf(speed, 2.0, 25.0) * 0.9
	var s := sin(_cycle)
	var c := cos(_cycle)
	var stride := 60.0 if sprint else 50.0
	_leg(pose, 1, s * stride, 4.0, 20.0 + maxf(0.0, -c) * 85.0)
	_leg(pose, -1, -s * stride, 4.0, 20.0 + maxf(0.0, c) * 85.0)
	_arm(pose, 1, -s * 45.0, 10.0, 75.0)
	_arm(pose, -1, s * 45.0, 10.0, 75.0)
	pose["spine"] = _q(24.0 if sprint else 12.0)
	pose["head"] = _q(-14.0 if sprint else -8.0)


func _pose_crawl(pose: Dictionary, delta: float) -> void:
	# Pegado a la fachada: extremidades abiertas; al moverse, diagonales alternas.
	var speed := controller.velocity.length()
	_cycle += delta * speed * 2.2
	var s := sin(_cycle) * clampf(speed / 3.0, 0.0, 1.0)
	_arm(pose, 1, 70.0 + s * 25.0, 55.0, 80.0 - s * 30.0)
	_arm(pose, -1, 70.0 - s * 25.0, 55.0, 80.0 + s * 30.0)
	_leg(pose, 1, 45.0 - s * 25.0, 38.0, 95.0 + s * 20.0)
	_leg(pose, -1, 45.0 + s * 25.0, 38.0, 95.0 - s * 20.0)
	pose["spine"] = _q(12.0)
	pose["head"] = _q(-30.0)


func _pose_perch(pose: Dictionary) -> void:
	_pose_crouch(pose, 1.0)
	_arm(pose, 1, 35.0, 15.0, 70.0)
	_arm(pose, -1, 35.0, 15.0, 70.0)


func _pose_idle(pose: Dictionary) -> void:
	var breathe := sin(_time * 2.0) * 2.0
	_arm(pose, 1, 5.0, 8.0 + breathe, 12.0)
	_arm(pose, -1, 5.0, 8.0 + breathe, 12.0)
	_leg(pose, 1, 0.0, 4.0, 3.0)
	_leg(pose, -1, 0.0, 4.0, 3.0)
	pose["spine"] = _q(2.0)
	pose["head"] = _q(0.0)


# ---------------------------------------------------------------------------
# Eventos -> acrobacias
# ---------------------------------------------------------------------------
func _on_web_released(_hand: int, perfect: bool) -> void:
	if controller.state != TraversalController.State.FALL:
		return
	var spd := controller.velocity.length()
	if perfect:
		_start_flip(Vector3(0.3, 1.0, 0.0).normalized(), 1.0, 0.6)   # tirabuzón con voltereta
	elif spd > 20.0:
		_start_flip(Vector3.RIGHT, 1.0, 0.55)


func _on_trick() -> void:
	match controller.trick_index:
		TraversalController.Trick.FRONT_FLIP:
			_start_flip(Vector3.RIGHT, 1.0, TraversalController.TRICK_TIME)
		TraversalController.Trick.BACK_FLIP:
			_start_flip(Vector3.LEFT, 1.0, TraversalController.TRICK_TIME)
		TraversalController.Trick.ROLL_LEFT:
			_start_flip(Vector3.FORWARD, 1.0, TraversalController.TRICK_TIME)
		TraversalController.Trick.ROLL_RIGHT:
			_start_flip(Vector3.BACK, 1.0, TraversalController.TRICK_TIME)
		_:
			_start_flip(Vector3.UP, 2.0, TraversalController.TRICK_TIME)


func _on_landed(_impact: float) -> void:
	if controller.land_kind == "roll":
		_start_flip(Vector3.RIGHT, 1.0, controller.tuning.quick_recovery_window)


# ---------------------------------------------------------------------------
# Bucle
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if controller == null:
		return
	_time += delta
	var c := controller
	var pose := {}
	var rate := 16.0
	var crouch := 0.0
	match c.state:
		TraversalController.State.SWING:
			if c.pendulum.sustain and c.pendulum.speed < 6.0:
				_pose_hang(pose, delta)
			else:
				_pose_swing(pose)
			rate = 24.0
		TraversalController.State.DIVE:
			_pose_dive(pose)
		TraversalController.State.GLIDE:
			_pose_glide(pose)
			rate = 12.0
		TraversalController.State.SLINGSHOT:
			_pose_slingshot(pose)
			crouch = 0.1 + controller.slingshot_charge * 0.35
			rate = 20.0
		TraversalController.State.WEB_ZIP, TraversalController.State.POINT_ZIP:
			_pose_zip(pose)
		TraversalController.State.PERCH:
			_pose_perch(pose)
			crouch = 0.32
		TraversalController.State.WALL_RUN:
			if c.wall_crawl:
				_pose_crawl(pose, delta)
			else:
				_pose_run(pose, delta, c.velocity.length(), true)
		TraversalController.State.GROUNDED:
			var hspeed := RegulatedPendulum.flat(c.velocity).length()
			if c.land_timer > 0.0 and c.land_kind == "hero":
				_pose_hero_landing(pose)
				crouch = 0.45
				rate = 30.0
			elif c.land_timer > 0.0 and c.land_kind == "roll":
				_pose_crouch(pose, 1.0)
			elif c.jump_charge > 0.0:
				_pose_crouch(pose, c.jump_charge)
				crouch = 0.35 * c.jump_charge
			elif hspeed > 1.0:
				_pose_run(pose, delta, hspeed, c.sprinting)
			else:
				_pose_idle(pose)
		_:
			_pose_fall(pose)

	var k := 1.0 - exp(-rate * delta)
	for key: String in pose:
		_spring_joint(key, pose[key], rate, delta)

	# Pelvis: inclinación al girar + acrobacias (voltereta / tirabuzón / giro).
	var steer := c.move_input.x if c.state == TraversalController.State.SWING else 0.0
	_lean = lerpf(_lean, -steer * deg_to_rad(22.0), k)
	var acro := Quaternion.IDENTITY
	if _flip_t < 1.0:
		_flip_t = minf(_flip_t + delta / _flip_time, 1.0)
		acro = Quaternion(_flip_axis, TAU * _flip_turns * smoothstep(0.0, 1.0, _flip_t))
	# Loop de loop: el cuerpo da la vuelta completa con la web (ya lo orienta el
	# animador); aquí solo se añade el giro del tronco durante la vuelta.
	_pelvis.quaternion = acro * Quaternion(Vector3.BACK, _lean)
	_pelvis.position.y = lerpf(_pelvis.position.y, -crouch, k)
	_update_wings(delta)


## Muelle amortiguado por articulación (semi-implícito): ω = rate, ζ < 1 en las
## extremidades para que lleguen con algo de rebote (overlap), ζ ≈ 1 en el tronco.
func _spring_joint(key: String, target: Quaternion, rate: float, delta: float) -> void:
	var node: Node3D = _joints[key]
	var cur := node.quaternion
	var dq := target * cur.inverse()
	if dq.w < 0.0:
		dq = -dq
	var s := sqrt(maxf(1.0 - dq.w * dq.w, 0.0))
	var axis_angle := Vector3(dq.x, dq.y, dq.z) * 2.0
	if s > 1e-4:
		axis_angle = Vector3(dq.x, dq.y, dq.z) / s * (2.0 * acos(clampf(dq.w, -1.0, 1.0)))
	var zeta := 0.9 if key in ["spine", "head", "pelvis"] else 0.62
	var omega := rate * 1.1
	var w: Vector3 = _joint_vel.get(key, Vector3.ZERO)
	w += (axis_angle * omega * omega - w * 2.0 * zeta * omega) * delta
	w = w.limit_length(40.0)
	_joint_vel[key] = w
	var ang := w.length() * delta
	if ang > 1e-6:
		node.quaternion = (Quaternion(w / w.length(), ang) * cur).normalized()


# ---------------------------------------------------------------------------
# Membranas de las Web Wings (muñeca - codo - hombro - cadera)
# ---------------------------------------------------------------------------
func _update_wings(delta: float) -> void:
	var gliding := controller.state == TraversalController.State.GLIDE
	_wings_open = move_toward(_wings_open, 1.0 if gliding else 0.0, delta * (4.0 if gliding else 7.0))
	_wing_mesh.clear_surfaces()
	if _wings_open < 0.02:
		return
	var open := smoothstep(0.0, 1.0, _wings_open)
	var back := Vector3.BACK * -1.0            # la espalda (-Z local) mira al cielo al planear
	var flutter := sin(_time * 31.0) * 0.012 * clampf(controller.velocity.length() / 40.0, 0.0, 1.0)
	_wing_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [1, -1]:
		var s := _s(side)
		var sh := to_local((_joints["sh_" + s] as Node3D).global_position)
		var el := to_local((_joints["el_" + s] as Node3D).global_position)
		var wr := to_local((hand_socket_right if side > 0 else hand_socket_left).global_position)
		var hip := to_local((_joints["hip_" + s] as Node3D).global_position)
		var knee := to_local((_joints["kn_" + s] as Node3D).global_position)
		var tail := hip.lerp(knee, 0.35)
		const NU := 6
		const NV := 4
		var grid: Array[PackedVector3Array] = []
		for i in NU + 1:
			var u := float(i) / NU
			var lead := sh.lerp(el, u * 2.0) if u < 0.5 else el.lerp(wr, u * 2.0 - 1.0)
			var trail := tail.lerp(wr, pow(u, 0.85))
			trail = trail.lerp(lead, 0.16 * sin(u * PI))          # borde festoneado
			trail = lead.lerp(trail, open)                        # despliegue
			var row := PackedVector3Array()
			for j in NV + 1:
				var v := float(j) / NV
				var billow := sin(u * PI) * sin(v * PI) * (0.07 + flutter) * open
				row.append(lead.lerp(trail, v) + back * billow)
			grid.append(row)
		for i in NU:
			for j in NV:
				var quad := [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]
				for idx in [0, 1, 2, 0, 2, 3]:
					var q: Vector2i = quad[idx]
					var n := (grid[mini(q.x + 1, NU)][q.y] - grid[maxi(q.x - 1, 0)][q.y]).cross(
							grid[q.x][mini(q.y + 1, NV)] - grid[q.x][maxi(q.y - 1, 0)]).normalized()
					_wing_mesh.surface_set_normal(n * float(side))
					_wing_mesh.surface_set_uv(Vector2(float(q.x) / NU, float(q.y) / NV))
					_wing_mesh.surface_add_vertex(grid[q.x][q.y])
	_wing_mesh.surface_end()
