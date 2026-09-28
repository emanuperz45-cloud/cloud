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
##    despliegan, alabeo y cabeceo según el stick; Super Slingshot: tensado hacia atrás;
##  - sueltas variadas como en el juego (voltereta agrupada, tirabuzón estirado,
##    pirueta abierta, rueda lateral, mortal atrás) con su postura; Spider-Dash en
##    "vuelo" con un brazo delante, Spider-Jump estirado, vault con una mano,
##    salto de borde con voltereta, "spidey squat" al posarse, idle con cambio de
##    peso y mirada, y la cabeza que mira hacia donde se va.
## Las articulaciones siguen la pose con muelles casi críticos (sin temblores): los
## cambios de pose llegan suaves y con peso. Nada oscila a más de ~3 Hz (a 60 fps
## una oscilación rápida se ve como vibración). En carrera: zancada con cadencia
## natural, rebote de cadera y contrarrotación de hombros; el cuerpo se inclina
## hacia dentro en las curvas y hacia delante con la velocidad.
## El frente del modelo es +Z y su derecha -X.
## Cuerpo: si existe demo/body/body_mesh.bin (tools/body_baker), una sola malla
## continua con piel sobre un Skeleton3D (body.gdshader); si no, el maniquí de
## piezas. Las poses se calculan en _physics_process sobre una jerarquía lógica de
## Node3D y se copian a los huesos en _process interpolando entre los dos últimos
## pasos de física (fluido a cualquier tasa de refresco).

const SUIT := preload("res://demo/suit.gdshader")
const BODY_SHADER := preload("res://demo/body.gdshader")
const BONE_PARENTS := {
	"pelvis": "", "spine": "pelvis", "head": "spine", "sh_l": "spine", "el_l": "sh_l",
	"sh_r": "spine", "el_r": "sh_r", "hip_l": "pelvis", "kn_l": "hip_l", "hip_r": "pelvis",
	"kn_r": "hip_r",
}
const WING := preload("res://demo/wing.gdshader")
const REFERENCE := preload("res://demo/textures/suit_reference.webp")
const WHITE := Color(0.96, 0.97, 1.0)
const BLACK := Color(0.02, 0.02, 0.025)

var controller: TraversalController
var hand_socket_left: Node3D
var hand_socket_right: Node3D
var foot_socket_left: Node3D
var foot_socket_right: Node3D

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
var _flip_style := "tuck"          ## tuck | layout | spread | pike
var _joint_vel := {}
var _wings_open := 0.0
var _wing_mesh := ImmediateMesh.new()
var _wing_mat := ShaderMaterial.new()
var _bob := 0.0
var _prev_heading := 0.0
var _turn_rate := 0.0
var _skinned := false
var _skeleton: Skeleton3D
var _bone_nodes: Array[Node3D] = []
var _bone_prev: Array[Quaternion] = []
var _bone_cur: Array[Quaternion] = []
var _root_prev := Vector3.ZERO
var _root_cur := Vector3.ZERO


func _ready() -> void:
	var body := BodyMesh.load_file()
	_skinned = body != null
	_build()
	if _skinned:
		_build_skinned(body)
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
			_start_flip(Vector3.UP, 1.0, 0.4, "spread"))
	controller.spider_jumped.connect(func() -> void: _start_flip(Vector3.LEFT, 1.0, 0.8, "layout"))
	controller.ledge_leaped.connect(func() -> void: _start_flip(Vector3.RIGHT, 1.0, 0.7, "tuck"))
	controller.loop_boosted.connect(func() -> void: _start_flip(Vector3(0.2, 1.0, 0.0), 1.0, 0.6, "layout"))
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
	if _skinned:
		return null                      # el cuerpo continuo sustituye a las piezas
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
		var foot := _pivot(knee, Vector3(0.0, -0.45, 0.08))
		if side > 0:
			foot_socket_right = foot
		else:
			foot_socket_left = foot


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


func _start_flip(axis: Vector3, turns: float, duration: float, style := "tuck") -> void:
	_flip_axis = axis.normalized()
	_flip_turns = turns
	_flip_time = duration
	_flip_style = style
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
	if c.state_time < 0.18:
		# Enganche: el brazo tira de la web (codo doblado) y se estira al tensarse.
		pose["el_" + _s(grip)] = _q(-75.0 * (1.0 - c.state_time / 0.18))
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
	if controller.dash_timer > 0.0:
		# Spider-Dash: "vuelo" con el brazo derecho delante y el izquierdo pegado.
		_arm(pose, 1, 175.0, 6.0, 0.0)
		_arm(pose, -1, -10.0, 12.0, 10.0)
		_leg(pose, 1, -6.0, 3.0, 6.0)
		_leg(pose, -1, 4.0, 3.0, 30.0)
		pose["spine"] = _q(-6.0)
		pose["head"] = _q(-50.0)
		return
	if controller.trick_timer > 0.0 or _flip_t < 1.0:
		var style := _flip_style
		if controller.trick_timer > 0.0 and controller.trick_index in [
				TraversalController.Trick.ROLL_LEFT, TraversalController.Trick.ROLL_RIGHT]:
			style = "spread"
		# La postura se abre al final de la acrobacia (aterriza en la caída normal).
		var open := smoothstep(0.75, 1.0, _flip_t)
		match style:
			"layout":                         # estirado, brazos pegados: tirabuzón
				_arm(pose, 1, lerpf(10.0, 25.0, open), lerpf(14.0, 60.0, open), 6.0)
				_arm(pose, -1, lerpf(10.0, 25.0, open), lerpf(14.0, 60.0, open), 6.0)
				_leg(pose, 1, 0.0, 3.0, 4.0)
				_leg(pose, -1, 0.0, 3.0, 4.0)
				pose["spine"] = _q(-8.0)
				pose["head"] = _q(-6.0)
			"spread":                         # en X: pirueta / rueda
				_arm(pose, 1, 8.0, 100.0, 8.0)
				_arm(pose, -1, 8.0, 100.0, 8.0)
				_leg(pose, 1, 4.0, 26.0, 8.0)
				_leg(pose, -1, 4.0, 26.0, 8.0)
				pose["spine"] = _q(-4.0)
				pose["head"] = _q(-8.0)
			"pike":                           # carpado: piernas rectas delante, manos a los pies
				_arm(pose, 1, 95.0, 12.0, 10.0)
				_arm(pose, -1, 95.0, 12.0, 10.0)
				_leg(pose, 1, 100.0, 6.0, 6.0)
				_leg(pose, -1, 100.0, 6.0, 6.0)
				pose["spine"] = _q(34.0)
				pose["head"] = _q(18.0)
			_:                                # agrupado: rodillas al pecho
				_arm(pose, 1, 60.0, 20.0, 95.0)
				_arm(pose, -1, 60.0, 20.0, 95.0)
				_leg(pose, 1, lerpf(110.0, 40.0, open), 10.0, lerpf(130.0, 50.0, open))
				_leg(pose, -1, lerpf(110.0, 40.0, open), 10.0, lerpf(130.0, 50.0, open))
				pose["spine"] = _q(30.0)
				pose["head"] = _q(10.0)
		return
	# Caída: silueta de paracaidista limpia; al subir se recoge, al caer se abre.
	var rising := clampf(v.y / 15.0, -1.0, 1.0)
	var falling := clampf(-v.y / 35.0, 0.0, 1.0)
	var sway := sin(_time * 2.2) * 4.0 * falling          # balanceo lento con el aire
	_arm(pose, 1, lerpf(35.0, 10.0, falling) + sway, lerpf(55.0, 80.0, falling), lerpf(35.0, 15.0, falling))
	_arm(pose, -1, lerpf(35.0, 10.0, falling) - sway, lerpf(55.0, 80.0, falling), lerpf(35.0, 15.0, falling))
	_leg(pose, 1, 15.0 + rising * 25.0 - falling * 10.0, 8.0 + falling * 6.0, 25.0 + rising * 40.0)
	_leg(pose, -1, 35.0 + rising * 20.0 - falling * 20.0, 8.0 + falling * 6.0, 60.0 - falling * 25.0)
	pose["spine"] = _q(8.0 + rising * 10.0 - falling * 8.0)
	pose["head"] = _q(-10.0 - falling * 15.0)


func _pose_dive(pose: Dictionary) -> void:
	# Picada: flecha. Brazos pegados, piernas juntas y rectas; solo un vaivén lento.
	var sway := sin(_time * 3.0) * clampf(controller.velocity.length() / 58.0, 0.0, 1.0) * 2.0
	_arm(pose, 1, 0.0, 8.0 + sway, 4.0)
	_arm(pose, -1, 0.0, 8.0 - sway, 4.0)
	_leg(pose, 1, sway * 0.5, 2.0, 4.0)
	_leg(pose, -1, -sway * 0.5, 2.0, 4.0)
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
	# Silueta limpia: brazos en línea recta, piernas juntas y estiradas. Solo un
	# vaivén lento con el aire (en pérdida, un bamboleo algo mayor).
	var sway := sin(_time * 2.4) * 1.5
	if c.wings.stalled:
		sway = sin(_time * 4.5) * 6.0
	for side in [1, -1]:
		# Alabeo: el ala del lado del giro baja (hacia el pecho) y la otra sube.
		var roll := bank * float(side) * 18.0
		var out := lerpf(90.0, 62.0, dive) + flare * 16.0 + sway * float(side)
		_arm(pose, side, -4.0 + roll + flare * 16.0, out, 2.0 + dive * 10.0)
		_leg(pose, side, -2.0 - flare * 10.0 + roll * 0.3, 5.0 + flare * 5.0 - dive * 3.0,
				4.0 + flare * 26.0)
	pose["spine"] = _q(-8.0 - flare * 8.0 + dive * 4.0)
	pose["head"] = _q(-45.0 + dive * 12.0)


func _pose_slingshot(pose: Dictionary) -> void:
	var ch := controller.slingshot_charge
	var shake := sin(_time * 9.0) * ch * ch * 2.0         # tensión (lenta: sin vibración)
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
	# Cadencia natural: la velocidad sale sobre todo de la amplitud de la zancada,
	# no de mover las piernas más rápido (de 1,1 a 1,7 ciclos/s).
	var run01 := clampf(speed / 18.0, 0.0, 1.0)
	_cycle += delta * lerpf(7.0, 10.5, run01)
	var s := sin(_cycle)
	var c := cos(_cycle)
	var stride := lerpf(30.0, 62.0, run01)
	# Pierna de apoyo casi recta; la que vuelve se recoge (talón al glúteo al esprintar).
	_leg(pose, 1, s * stride + 8.0 * run01, 3.0, 12.0 + maxf(0.0, -c) * lerpf(50.0, 105.0, run01))
	_leg(pose, -1, -s * stride + 8.0 * run01, 3.0, 12.0 + maxf(0.0, c) * lerpf(50.0, 105.0, run01))
	var arm_swing := lerpf(25.0, 55.0, run01)
	_arm(pose, 1, -s * arm_swing + 10.0, 8.0, lerpf(60.0, 90.0, run01))
	_arm(pose, -1, s * arm_swing + 10.0, 8.0, lerpf(60.0, 90.0, run01))
	# Inclinación hacia delante con la velocidad y contrarrotación de hombros.
	var twist := Quaternion(Vector3.UP, s * deg_to_rad(10.0) * run01)
	pose["spine"] = _q(lerpf(6.0, 26.0, run01) if sprint else lerpf(4.0, 14.0, run01)) * twist
	pose["head"] = _q(-lerpf(4.0, 18.0, run01)) * twist.inverse()
	# Rebote de cadera: dos por ciclo (uno por pisada), mínimo en el apoyo.
	_bob = absf(c) * lerpf(0.03, 0.07, run01) - 0.03


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
	# "Spidey squat": rodillas muy abiertas, la mano derecha apoyada entre los pies,
	# la izquierda sobre la rodilla y la cabeza alta vigilando.
	var breathe := sin(_time * 1.8) * 1.5
	_leg(pose, 1, 105.0, 38.0, 135.0)
	_leg(pose, -1, 100.0, 42.0, 130.0)
	_arm(pose, 1, 38.0, 4.0, 6.0)
	_arm(pose, -1, 62.0, 30.0, 70.0 + breathe)
	pose["spine"] = _q(38.0 + breathe)
	pose["head"] = _q(-48.0) * Quaternion(Vector3.UP, sin(_time * 0.4) * 0.35)


func _pose_idle(pose: Dictionary) -> void:
	# Idle vivo: respiración, cambio de peso de una pierna a otra cada ~5 s y la
	# cabeza que mira alrededor despacio.
	var breathe := sin(_time * 2.0)
	var shift := sin(_time * 1.25) * 0.5 + 0.5                 # 0 = peso a la derecha
	_arm(pose, 1, 4.0 + breathe * 1.5, 9.0 + breathe * 1.5, 14.0)
	_arm(pose, -1, 4.0 + breathe * 1.5, 9.0 + breathe * 1.5, 14.0)
	_leg(pose, 1, lerpf(0.0, 8.0, shift), 5.0, lerpf(2.0, 16.0, shift))
	_leg(pose, -1, lerpf(8.0, 0.0, shift), 5.0, lerpf(16.0, 2.0, shift))
	pose["spine"] = _q(2.0 + breathe * 1.2, (shift - 0.5) * 4.0)
	var look := sin(_time * 0.35) * 0.45 + sin(_time * 0.9) * 0.08
	pose["head"] = _q(-2.0) * Quaternion(Vector3.UP, look)


func _pose_vault(pose: Dictionary) -> void:
	# Vault: la mano derecha apoyada en el obstáculo, piernas recogidas hacia el
	# lado izquierdo, la otra mano abierta para equilibrar.
	_arm(pose, 1, 35.0, 6.0, 0.0)
	_arm(pose, -1, 20.0, 70.0, 20.0)
	_leg(pose, 1, 75.0, -20.0, 110.0)
	_leg(pose, -1, 60.0, -30.0, 95.0)
	pose["spine"] = _q(24.0, -10.0)
	pose["head"] = _q(-20.0)


# ---------------------------------------------------------------------------
# Eventos -> acrobacias
# ---------------------------------------------------------------------------
## Sueltas como en el juego: cada una elige una acrobacia distinta (no se repite
## la anterior); la perfecta es doble o con giro y medio.
const RELEASE_FLIPS := [
	[Vector3.RIGHT, 1.0, 0.6, "tuck"],                 # voltereta adelante agrupada
	[Vector3(0.25, 1.0, 0.0), 1.0, 0.6, "layout"],     # tirabuzón estirado
	[Vector3.UP, 1.0, 0.55, "spread"],                 # pirueta abierta
	[Vector3.FORWARD, 1.0, 0.6, "spread"],             # rueda lateral
	[Vector3.LEFT, 1.0, 0.65, "layout"],               # mortal atrás estirado
	[Vector3.RIGHT, 1.0, 0.6, "pike"],                 # voltereta carpada
]
var _last_flip := -1


func _on_web_released(_hand: int, perfect: bool) -> void:
	if controller.state != TraversalController.State.FALL:
		return
	var spd := controller.velocity.length()
	if spd < 18.0 and not perfect:
		return
	var i := randi() % RELEASE_FLIPS.size()
	if i == _last_flip:
		i = (i + 1) % RELEASE_FLIPS.size()
	_last_flip = i
	var f: Array = RELEASE_FLIPS[i]
	if perfect:
		_start_flip(f[0], 2.0 if f[3] == "tuck" else 1.5, float(f[2]) * 1.35, f[3])
	else:
		_start_flip(f[0], f[1], f[2], f[3])


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
	_bob = 0.0
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
		TraversalController.State.VAULT:
			_pose_vault(pose)
			rate = 26.0
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
			elif c.land_timer > 0.0 and c.land_kind == "soft":
				var dip := c.land_timer / 0.25          # flexión que amortigua el aterrizaje
				_pose_crouch(pose, 0.45 * dip)
				crouch = 0.12 * dip
			elif c.jump_charge > 0.0:
				_pose_crouch(pose, c.jump_charge)
				crouch = 0.35 * c.jump_charge
			elif hspeed > 1.0:
				_pose_run(pose, delta, hspeed, c.sprinting)
			else:
				_pose_idle(pose)
		_:
			_pose_fall(pose)

	# La cabeza mira hacia donde se va (sin girar el cuerpo).
	match c.state:
		TraversalController.State.GROUNDED:
			_head_look(pose, 0.6)
		TraversalController.State.SWING:
			_head_look(pose, 0.5)
		TraversalController.State.FALL:
			if _flip_t >= 1.0 and c.trick_timer <= 0.0:
				_head_look(pose, 0.7)

	var k := 1.0 - exp(-rate * delta)
	for key: String in pose:
		_spring_joint(key, pose[key], rate, delta)

	# Pelvis: inclinación hacia dentro de la curva + acrobacias. En el swing manda el
	# stick; corriendo (suelo o pared) la aceleración centrípeta real ω·v.
	var hv := RegulatedPendulum.flat(c.velocity)
	var heading := atan2(hv.x, hv.z)
	if hv.length() > 1.0:
		var raw := wrapf(heading - _prev_heading, -PI, PI) / maxf(delta, 1e-4)
		_turn_rate = lerpf(_turn_rate, clampf(raw, -4.0, 4.0), 1.0 - exp(-8.0 * delta))
	else:
		_turn_rate = lerpf(_turn_rate, 0.0, k)
	_prev_heading = heading
	var lean_target := 0.0
	match c.state:
		TraversalController.State.SWING:
			lean_target = c.move_input.x * deg_to_rad(18.0)
		TraversalController.State.GROUNDED:
			lean_target = -atan(_turn_rate * hv.length() / 9.81) * 0.7
	_lean = lerpf(_lean, clampf(lean_target, -0.5, 0.5), 1.0 - exp(-6.0 * delta))
	var acro := Quaternion.IDENTITY
	if _flip_t < 1.0:
		_flip_t = minf(_flip_t + delta / _flip_time, 1.0)
		acro = Quaternion(_flip_axis, TAU * _flip_turns * smoothstep(0.0, 1.0, _flip_t))
	# Loop de loop: el cuerpo da la vuelta completa con la web (ya lo orienta el
	# animador); aquí solo se añade el giro del tronco durante la vuelta.
	_pelvis.quaternion = acro * Quaternion(Vector3.BACK, _lean)
	_pelvis.position.y = lerpf(_pelvis.position.y, -crouch + _bob, 1.0 - exp(-maxf(rate, 20.0) * delta))
	_update_wings(delta)
	_capture_bones()


func _head_look(pose: Dictionary, weight: float) -> void:
	var v := controller.velocity
	if v.length() < 2.0 or not pose.has("head"):
		return
	var local := _spine.global_transform.basis.orthonormalized().inverse() * v.normalized()
	var yaw := clampf(atan2(local.x, local.z), -0.9, 0.9) * weight
	var pitch := clampf(-atan2(local.y, Vector2(local.x, local.z).length()), -0.6, 0.6) * weight * 0.5
	pose["head"] = Quaternion.from_euler(Vector3(pitch, yaw, 0.0)) * (pose["head"] as Quaternion)


# ---------------------------------------------------------------------------
# Cuerpo continuo: esqueleto con piel que copia la jerarquía lógica
# ---------------------------------------------------------------------------
func _build_skinned(body: BodyMesh) -> void:
	_skeleton = Skeleton3D.new()
	_skeleton.name = "Skeleton"
	add_child(_skeleton)
	for bone_name in body.bone_names:
		var node: Node3D = _joints[bone_name]
		var i := _skeleton.add_bone(bone_name)
		var parent: String = BONE_PARENTS[bone_name]
		if parent != "":
			_skeleton.set_bone_parent(i, _skeleton.find_bone(parent))
		_skeleton.set_bone_rest(i, Transform3D(Basis.IDENTITY, node.position))
		_skeleton.set_bone_pose_position(i, node.position)
		_bone_nodes.append(node)
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = body.mesh
	mi.skin = body.skin
	var mat := ShaderMaterial.new()
	mat.shader = BODY_SHADER
	mi.material_override = mat
	mi.skeleton = NodePath("..")          # (en 4.7 la ruta viene vacía por defecto)
	_skeleton.add_child(mi)
	_capture_bones()
	_capture_bones()


func _capture_bones() -> void:
	if not _skinned:
		return
	_bone_prev = _bone_cur.duplicate()
	_root_prev = _root_cur
	_bone_cur.clear()
	for node in _bone_nodes:
		_bone_cur.append(node.quaternion)
	_root_cur = _pelvis.position
	if _bone_prev.size() != _bone_cur.size():
		_bone_prev = _bone_cur.duplicate()
		_root_prev = _root_cur


func _process(_delta: float) -> void:
	if not _skinned or _bone_cur.is_empty():
		return
	var f := Engine.get_physics_interpolation_fraction()
	for i in _bone_cur.size():
		_skeleton.set_bone_pose_rotation(i, _bone_prev[i].slerp(_bone_cur[i], f))
	_skeleton.set_bone_pose_position(0, _root_prev.lerp(_root_cur, f))


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
	var zeta := 1.0 if key in ["spine", "head", "pelvis"] else 0.85
	var omega := rate
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
	var flutter := sin(_time * 5.0) * 0.012 * clampf(controller.velocity.length() / 40.0, 0.0, 1.0)
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
