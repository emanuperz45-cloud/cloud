class_name Mannequin
extends Node3D
## Personaje de la demo: cuerpo continuo con piel (tools/body_baker) sobre un
## esqueleto de 19 huesos, animado por código a partir del estado físico.
##
## Cómo se construye cada fotograma (60 Hz):
##  1. La postura se describe con CANALES en grados, sin bloqueo de ejes:
##     brazo = elevación (0 abajo, 90 horizontal, 180 arriba; negativa = hacia
##     atrás), azimut (hacia fuera), giro, codo y muñeca; pierna = flexión,
##     abducción, giro, rodilla y tobillo; tronco en 3 tramos (pelvis, lumbar,
##     pecho) + cuello y cabeza. Las posturas clave de cada movimiento se mezclan
##     por fase (Catmull-Rom) o por velocidad.
##  2. Cada articulación sigue su objetivo con un muelle casi crítico (transiciones
##     suaves, con peso).
##  3. IK de dos huesos para lo que debe TOCAR algo: pies en el suelo (generador de
##     pasos: el pie de apoyo no desliza, el talón sube y la rodilla avanza), pies y
##     manos en la pared (carrera vertical y gateo en diagonal), mano en la web al
##     balancearse, manos en la web colgado, en el slingshot, en el suelo al posarse
##     o al aterrizar y en el obstáculo del vault.
##  4. Encima, acrobacias (volteretas, tirabuzones...) con anticipación, forma y
##     apertura, y la cabeza que mira hacia donde se va.
## Los huesos se copian al Skeleton3D en _process interpolando entre los dos últimos
## pasos de física (fluido a cualquier tasa de refresco). Frente del modelo +Z,
## derecha -X.

const BODY_SHADER := preload("res://demo/body.gdshader")
const WING := preload("res://demo/wing.gdshader")

## Esqueleto (igual que tools/body_baker/bake_body.py): padre y desplazamiento.
const SKELETON := {
	"pelvis": ["", Vector3(0.0, 0.0, 0.0)],
	"spine": ["pelvis", Vector3(0.0, 0.06, 0.0)],
	"chest": ["spine", Vector3(0.0, 0.20, 0.0)],
	"neck": ["chest", Vector3(0.0, 0.30, 0.0)],
	"head": ["neck", Vector3(0.0, 0.10, 0.0)],
	"cl_l": ["chest", Vector3(0.03, 0.24, 0.0)],
	"sh_l": ["cl_l", Vector3(0.20, 0.03, 0.0)],
	"el_l": ["sh_l", Vector3(0.0, -0.30, 0.0)],
	"wr_l": ["el_l", Vector3(0.0, -0.27, 0.0)],
	"cl_r": ["chest", Vector3(-0.03, 0.24, 0.0)],
	"sh_r": ["cl_r", Vector3(-0.20, 0.03, 0.0)],
	"el_r": ["sh_r", Vector3(0.0, -0.30, 0.0)],
	"wr_r": ["el_r", Vector3(0.0, -0.27, 0.0)],
	"hip_l": ["pelvis", Vector3(0.095, -0.05, 0.0)],
	"kn_l": ["hip_l", Vector3(0.0, -0.43, 0.0)],
	"ank_l": ["kn_l", Vector3(0.0, -0.42, 0.0)],
	"hip_r": ["pelvis", Vector3(-0.095, -0.05, 0.0)],
	"kn_r": ["hip_r", Vector3(0.0, -0.43, 0.0)],
	"ank_r": ["kn_r", Vector3(0.0, -0.42, 0.0)],
}
const UPPER_ARM := 0.30
const FOREARM := 0.27
const THIGH := 0.43
const SHIN := 0.42
const ANKLE_H := 0.05          ## altura del tobillo sobre la suela
const WRIST_H := 0.035         ## altura de la muñeca con la palma apoyada
const GROUND := -0.9           ## suelo en coordenadas del cuerpo (centro de la cápsula)
const TORSO := ["pelvis", "spine", "chest", "neck", "head"]
const SIDES := {"r": -1.0, "l": 1.0}     ## lado -> signo de X

var controller: TraversalController
var hand_socket_left: Node3D
var hand_socket_right: Node3D
var foot_socket_left: Node3D
var foot_socket_right: Node3D

var _j := {}                   ## nombre -> Node3D (jerarquía lógica = huesos)
var _pelvis: Node3D
var _joint_vel := {}
var _root_vel := Vector3.ZERO
var _time := 0.0
var _gait := 0.0               ## fase del paso (0..1) en suelo y pared
var _crawl := 0.0              ## fase del gateo
var _climb := 0.0              ## fase de subir por la web
var _ik_w := {"arm_r": 0.0, "arm_l": 0.0, "leg_r": 0.0, "leg_l": 0.0}
var _ik_prev := {}             ## miembro -> último objetivo de IK (coordenadas del cuerpo)
var _ik_off := {}              ## miembro -> salto de objetivo pendiente de absorber
var _ik_f := {}                ## miembro -> estado [posición, velocidad] del filtro del objetivo
var _bend_mem := {}
var _prev_vel := Vector3.ZERO
var _acc_slow := Vector3.ZERO  ## aceleración lenta (gravedad, régimen estable) que se resta
var _feel := Vector3.ZERO      ## aceleración transitoria en coordenadas del cuerpo (x izq., y arriba, z delante)            ## hueso raíz -> última dirección de flexión (IK estable)
var _lean := 0.0
var _prev_heading := 0.0
var _turn_rate := 0.0
var _flip_t := 1.0
var _flip_axis := Vector3.RIGHT
var _flip_turns := 1.0
var _flip_time := 0.5
var _flip_style := "tuck"      ## tuck | layout | spread | pike
var _last_flip := -1
var _zip_target := Vector3.ZERO
var _wings_open := 0.0
var _wing_mesh := ImmediateMesh.new()
var _wing_mat := ShaderMaterial.new()
var _skeleton: Skeleton3D
var _bone_nodes: Array[Node3D] = []
var _bone_prev: Array[Quaternion] = []
var _bone_cur: Array[Quaternion] = []
var _root_prev := Vector3.ZERO
var _root_cur := Vector3.ZERO


func _ready() -> void:
	_build()
	var body := BodyMesh.load_file()
	if body:
		_build_skinned(body)
	else:
		push_error("Mannequin: no se pudo cargar demo/body/body_mesh.bin")
	controller.web_released.connect(_on_web_released)
	controller.web_fired.connect(func(_h: int, anchor: Vector3) -> void: _zip_target = anchor)
	controller.trick_started.connect(_on_trick)
	controller.landed.connect(_on_landed)
	controller.quick_recovered.connect(func() -> void: start_flip(Vector3.RIGHT, 1.0, 0.55, "tuck"))
	controller.corner_turned.connect(func(launched: bool) -> void:
		if launched:
			start_flip(Vector3.RIGHT, 1.0, 0.6, "tuck"))
	controller.point_launched.connect(func(perfect: bool) -> void:
		if perfect:
			start_flip(Vector3.RIGHT, 1.0, 0.6, "pike"))
	controller.slingshot_launched.connect(func(c: float) -> void:
		if c > 0.6:
			start_flip(Vector3.RIGHT, 1.0 if c < 0.95 else 2.0, 0.55 + c * 0.35, "tuck"))
	controller.wings_opened.connect(func(boosted: bool) -> void:
		if boosted:
			start_flip(Vector3.UP, 1.0, 0.45, "spread"))
	controller.spider_jumped.connect(func() -> void: start_flip(Vector3.LEFT, 1.0, 0.8, "layout"))
	controller.ledge_leaped.connect(func() -> void: start_flip(Vector3.RIGHT, 1.0, 0.7, "tuck"))
	controller.loop_boosted.connect(func() -> void: start_flip(Vector3(0.2, 1.0, 0.0), 1.0, 0.6, "layout"))
	_wing_mat.shader = WING
	var wings := MeshInstance3D.new()
	wings.name = "WebWings"
	wings.mesh = _wing_mesh
	wings.material_override = _wing_mat
	add_child(wings)


# ---------------------------------------------------------------------------
# Construcción
# ---------------------------------------------------------------------------
func _build() -> void:
	for bone_name: String in SKELETON:
		var n := Node3D.new()
		n.name = bone_name
		n.position = SKELETON[bone_name][1]
		var parent: String = SKELETON[bone_name][0]
		(self if parent == "" else _j[parent] as Node3D).add_child(n)
		_j[bone_name] = n
	_pelvis = _j["pelvis"]
	hand_socket_right = _socket("wr_r", Vector3(0.0, -0.07, 0.0))
	hand_socket_left = _socket("wr_l", Vector3(0.0, -0.07, 0.0))
	foot_socket_right = _socket("ank_r", Vector3(0.0, -0.03, 0.09))
	foot_socket_left = _socket("ank_l", Vector3(0.0, -0.03, 0.09))


func _socket(bone: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	(_j[bone] as Node3D).add_child(n)
	return n


func _build_skinned(body: BodyMesh) -> void:
	_skeleton = Skeleton3D.new()
	_skeleton.name = "Skeleton"
	add_child(_skeleton)
	for bone_name in body.bone_names:
		var node: Node3D = _j[bone_name]
		var i := _skeleton.add_bone(bone_name)
		var parent: String = SKELETON[bone_name][0]
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


# ---------------------------------------------------------------------------
# Canales -> rotaciones
# ---------------------------------------------------------------------------
static func _rx(deg: float) -> Quaternion:
	return Quaternion(Vector3.RIGHT, deg_to_rad(deg))


static func _ry(deg: float) -> Quaternion:
	return Quaternion(Vector3.UP, deg_to_rad(deg))


static func _rz(deg: float) -> Quaternion:
	return Quaternion(Vector3.BACK, deg_to_rad(deg))


## Tronco: p > 0 se inclina hacia delante, r > 0 hacia la derecha, y > 0 gira a la izquierda.
static func _torso_q(p: float, r: float, y: float) -> Quaternion:
	return _ry(y) * _rx(p) * _rz(r)


func _targets(pose: Dictionary) -> Dictionary:
	var t := {}
	var g := func(k: String) -> float: return pose.get(k, 0.0)
	t["pelvis"] = _torso_q(g.call("pel_p"), g.call("pel_r"), g.call("pel_y"))
	t["spine"] = _torso_q(g.call("sp_p"), g.call("sp_r"), g.call("sp_y"))
	t["chest"] = _torso_q(g.call("ch_p"), g.call("ch_r"), g.call("ch_y"))
	t["neck"] = _torso_q(g.call("nk_p"), 0.0, g.call("nk_y"))
	t["head"] = _torso_q(g.call("hd_p"), g.call("hd_r"), g.call("hd_y"))
	for s: String in SIDES:
		var sx: float = SIDES[s]
		var el: float = g.call("ae_" + s)
		# La clavícula sube sola al levantar el brazo por encima del hombro.
		var shrug: float = g.call("sg_" + s) + clampf((el - 75.0) * 0.28, 0.0, 26.0)
		t["cl_" + s] = _rz(sx * shrug)
		t["sh_" + s] = _ry(sx * g.call("aa_" + s)) * _rx(-el) * _ry(sx * g.call("at_" + s))
		t["el_" + s] = _rx(-g.call("eb_" + s))
		t["wr_" + s] = _rz(-sx * g.call("wf_" + s)) * _rx(-g.call("wx_" + s))
		t["hip_" + s] = _rx(-g.call("lf_" + s)) * _rz(sx * g.call("la_" + s)) * _ry(sx * g.call("lt_" + s))
		t["kn_" + s] = _rx(g.call("kf_" + s))
		t["ank_" + s] = _rx(-g.call("af_" + s))
	return t


# ---------------------------------------------------------------------------
# Utilidades de posturas (diccionarios de canales)
# ---------------------------------------------------------------------------
const _MIRROR_NEG := ["pel_r", "pel_y", "sp_r", "sp_y", "ch_r", "ch_y", "nk_y", "hd_r", "hd_y", "hip_x"]


## Intercambia derecha e izquierda (los canales de brazos/piernas ya son relativos al lado).
static func mirror(p: Dictionary) -> Dictionary:
	var m := {}
	for k: String in p:
		var v: float = p[k]
		if k.ends_with("_r"):
			m[k.substr(0, k.length() - 1) + "l"] = v
		elif k.ends_with("_l"):
			m[k.substr(0, k.length() - 1) + "r"] = v
		elif k in _MIRROR_NEG:
			m[k] = -v
		else:
			m[k] = v
	return m


static func blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := a.duplicate()
	for k: String in b:
		out[k] = lerpf(a.get(k, 0.0), b[k], t)
	for k: String in a:
		if not b.has(k):
			out[k] = lerpf(a[k], 0.0, t)
	return out


static func add(a: Dictionary, b: Dictionary, w: float = 1.0) -> Dictionary:
	var out := a.duplicate()
	for k: String in b:
		out[k] = a.get(k, 0.0) + b[k] * w
	return out


## Interpolación Catmull-Rom entre posturas clave equiespaciadas; x en [0, 1].
static func spline(keys: Array, x: float) -> Dictionary:
	var n := keys.size()
	var f := clampf(x, 0.0, 1.0) * (n - 1)
	var i := mini(int(f), n - 2)
	var t := f - i
	var p0: Dictionary = keys[maxi(i - 1, 0)]
	var p1: Dictionary = keys[i]
	var p2: Dictionary = keys[i + 1]
	var p3: Dictionary = keys[mini(i + 2, n - 1)]
	var out := {}
	var names := {}
	for d: Dictionary in [p0, p1, p2, p3]:
		for k: String in d:
			names[k] = true
	var t2 := t * t
	var t3 := t2 * t
	for k: String in names:
		var a: float = p0.get(k, 0.0)
		var b: float = p1.get(k, 0.0)
		var c: float = p2.get(k, 0.0)
		var d: float = p3.get(k, 0.0)
		out[k] = 0.5 * (2.0 * b + (c - a) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
				+ (3.0 * b - a - 3.0 * c + d) * t3)
	return out


## Punto del cuerpo (coordenadas locales del personaje) en el mundo.
func _w(local: Vector3) -> Vector3:
	return global_transform * local


func _wdir(local: Vector3) -> Vector3:
	return (global_transform.basis * local).normalized()


# ---------------------------------------------------------------------------
# Posturas clave
# ---------------------------------------------------------------------------
const STAND := {
	"hip_y": 0.03, "sp_p": 2.0, "ch_p": 1.0, "hd_p": -2.0,
	"ae_r": 10.0, "aa_r": 75.0, "at_r": 10.0, "eb_r": 14.0, "wf_r": 12.0,
	"ae_l": 10.0, "aa_l": 75.0, "at_l": 10.0, "eb_l": 14.0, "wf_l": 12.0,
}
# Balanceo con la mano derecha en la web: fases -1 (enganche atrás y arriba),
# -0,5, 0 (fondo, máxima tensión), 0,5 y 1 (ápice delante). El brazo derecho lo
# pone la IK sobre la web; aquí se mueven piernas, tronco y brazo libre.
const SWING_KEYS := [
	# -1: recién enganchado, cuerpo detrás de la vertical -> se lanza como un dardo
	{"sp_p": -6.0, "ch_p": -8.0, "hd_p": -16.0,
		"lf_r": -14.0, "kf_r": 22.0, "af_r": -35.0, "lf_l": 4.0, "kf_l": 46.0, "af_l": -38.0,
		"ae_l": 40.0, "aa_l": 40.0, "eb_l": 30.0, "wf_l": 10.0},
	# -0,5: bajando, piernas estiradas hacia atrás, brazo libre adelante
	{"sp_p": -4.0, "ch_p": -6.0, "hd_p": -20.0,
		"lf_r": 6.0, "kf_r": 30.0, "af_r": -40.0, "lf_l": -6.0, "kf_l": 48.0, "af_l": -40.0,
		"ae_l": 70.0, "aa_l": 30.0, "eb_l": 34.0, "wf_l": 10.0},
	# 0: fondo del arco, máxima extensión (dardo), cabeza arriba mirando al frente
	{"sp_p": -3.0, "ch_p": -4.0, "hd_p": -26.0, "pel_p": 0.0,
		"lf_r": 10.0, "kf_r": 26.0, "af_r": -45.0, "lf_l": -4.0, "kf_l": 40.0, "af_l": -45.0,
		"ae_l": -22.0, "aa_l": 24.0, "eb_l": 10.0, "wf_l": 5.0},
	# 0,5: subiendo, las rodillas vienen hacia delante y el brazo libre se abre
	{"sp_p": 2.0, "ch_p": -6.0, "hd_p": -20.0,
		"lf_r": 66.0, "kf_r": 58.0, "af_r": -30.0, "lf_l": 46.0, "kf_l": 84.0, "af_l": -35.0,
		"ae_l": 78.0, "aa_l": 44.0, "eb_l": 44.0, "wf_l": 5.0},
	# 1: ápice, piernas adelante casi rectas (en L), brazo libre abierto
	{"sp_p": -10.0, "ch_p": -14.0, "hd_p": -22.0,
		"lf_r": 70.0, "kf_r": 14.0, "af_r": -45.0, "lf_l": 56.0, "kf_l": 24.0, "af_l": -45.0,
		"la_r": 6.0, "la_l": 10.0,
		"ae_l": 105.0, "aa_l": 58.0, "eb_l": 28.0, "wf_l": 5.0},
]
# Swing rápido: piernas en tijera y brazo libre atrás para equilibrar (aditivo).
const SWING_AGGRESSIVE := {
	"lf_r": 22.0, "kf_r": -20.0, "lf_l": -40.0, "kf_l": 25.0,
	"ae_l": -25.0, "aa_l": 30.0, "eb_l": -30.0,
}
# Compresión por fuerza G en el fondo del arco (aditivo).
const SWING_G := {"lf_r": 6.0, "kf_r": 10.0, "lf_l": 6.0, "kf_l": 10.0, "sp_p": 3.0, "ch_p": 2.0}
# Aire: impulso tras la suelta (subiendo), flotando en el ápice, cayendo (paracaidista).
const AIR_RISE := {
	"ch_p": -10.0, "sp_p": -4.0, "hd_p": -16.0,
	"lf_r": 88.0, "kf_r": 115.0, "af_r": -35.0, "lf_l": -18.0, "kf_l": 35.0, "af_l": -40.0,
	"ae_r": -30.0, "aa_r": 25.0, "eb_r": 25.0, "ae_l": 105.0, "aa_l": 25.0, "eb_l": 30.0,
}
const AIR_APEX := {
	"ch_p": 6.0, "sp_p": 4.0, "hd_p": -10.0,
	"lf_r": 52.0, "la_r": 6.0, "kf_r": 84.0, "af_r": -25.0,
	"lf_l": 14.0, "la_l": 9.0, "kf_l": 46.0, "af_l": -35.0,
	"ae_r": 62.0, "aa_r": 26.0, "eb_r": 66.0, "ae_l": 40.0, "aa_l": 34.0, "eb_l": 52.0,
}
const AIR_FALL := {
	"ch_p": -14.0, "sp_p": -6.0, "hd_p": -38.0,
	"lf_r": -8.0, "la_r": 14.0, "kf_r": 70.0, "af_r": -35.0,
	"lf_l": -12.0, "la_l": 14.0, "kf_l": 60.0, "af_l": -35.0,
	"ae_r": 100.0, "aa_r": 72.0, "at_r": -50.0, "eb_r": 70.0,
	"ae_l": 100.0, "aa_l": 72.0, "at_l": -50.0, "eb_l": 70.0,
}
const DIVE := {
	"ch_p": -6.0, "hd_p": -40.0,
	"lf_r": 0.0, "la_r": 3.0, "kf_r": 6.0, "af_r": -45.0,
	"lf_l": 0.0, "la_l": 3.0, "kf_l": 6.0, "af_l": -45.0,
	"ae_r": -14.0, "aa_r": 15.0, "eb_r": 6.0, "wf_r": 10.0,
	"ae_l": -14.0, "aa_l": 15.0, "eb_l": 6.0, "wf_l": 10.0,
}
const DASH := {
	"ch_p": -8.0, "hd_p": -45.0,
	"ae_r": 176.0, "aa_r": 6.0, "eb_r": 0.0, "wf_r": -10.0,
	"ae_l": -10.0, "aa_l": 12.0, "eb_l": 12.0,
	"lf_r": 0.0, "kf_r": 6.0, "af_r": -45.0, "lf_l": -6.0, "kf_l": 40.0, "af_l": -40.0,
}
const GLIDE := {
	"ch_p": -8.0, "sp_p": -2.0, "hd_p": -42.0,
	"ae_r": 90.0, "aa_r": 90.0, "eb_r": 3.0, "ae_l": 90.0, "aa_l": 90.0, "eb_l": 3.0,
	"lf_r": -3.0, "la_r": 5.0, "kf_r": 5.0, "af_r": -45.0,
	"lf_l": -3.0, "la_l": 5.0, "kf_l": 5.0, "af_l": -45.0,
}
const ZIP := {
	"ch_p": -6.0, "hd_p": -12.0,
	"lf_r": -22.0, "kf_r": 70.0, "af_r": -40.0, "lf_l": -8.0, "kf_l": 40.0, "af_l": -40.0,
}
# Acrobacias: forma durante el giro (se mezcla con anticipación y apertura).
const FLIP_SHAPES := {
	"tuck": {"sp_p": 26.0, "ch_p": 22.0, "hd_p": 20.0,
		"lf_r": 118.0, "kf_r": 135.0, "af_r": -35.0, "lf_l": 118.0, "kf_l": 135.0, "af_l": -35.0,
		"ae_r": 62.0, "aa_r": -12.0, "eb_r": 105.0, "ae_l": 62.0, "aa_l": -12.0, "eb_l": 105.0},
	"layout": {"ch_p": -8.0, "hd_p": -6.0,
		"lf_r": 0.0, "kf_r": 3.0, "af_r": -45.0, "lf_l": 0.0, "kf_l": 3.0, "af_l": -45.0,
		"ae_r": 40.0, "aa_r": -70.0, "eb_r": 135.0, "ae_l": 40.0, "aa_l": -70.0, "eb_l": 135.0},
	"spread": {"ch_p": -6.0, "hd_p": -8.0,
		"lf_r": 6.0, "la_r": 28.0, "kf_r": 5.0, "af_r": -40.0, "lf_l": 6.0, "la_l": 28.0, "kf_l": 5.0, "af_l": -40.0,
		"ae_r": 95.0, "aa_r": 90.0, "eb_r": 5.0, "ae_l": 95.0, "aa_l": 90.0, "eb_l": 5.0},
	"pike": {"sp_p": 30.0, "ch_p": 26.0, "hd_p": 20.0,
		"lf_r": 112.0, "kf_r": 4.0, "af_r": -45.0, "lf_l": 112.0, "kf_l": 4.0, "af_l": -45.0,
		"ae_r": 95.0, "aa_r": 8.0, "eb_r": 6.0, "ae_l": 95.0, "aa_l": 8.0, "eb_l": 6.0},
}
const FLIP_ANTICIPATION := {"ch_p": -10.0, "hd_p": -12.0, "ae_r": 150.0, "aa_r": 20.0, "eb_r": 15.0,
		"ae_l": 150.0, "aa_l": 20.0, "eb_l": 15.0, "lf_r": 10.0, "kf_r": 20.0, "lf_l": 10.0, "kf_l": 20.0}


# ---------------------------------------------------------------------------
# Estados -> postura + peticiones de IK
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if controller == null:
		return
	_time += delta
	var c := controller
	var pose := {}
	var ik := {}
	var rate := 14.0
	match c.state:
		TraversalController.State.SWING:
			if c.pendulum.sustain and c.pendulum.speed < 6.0:
				pose = _hang(ik, delta)
			else:
				pose = _swing(ik)
			rate = 18.0
		TraversalController.State.DIVE:
			pose = DIVE.duplicate()
			pose["ae_r"] = DIVE["ae_r"] + sin(_time * 2.6) * 3.0
			pose["ae_l"] = DIVE["ae_l"] - sin(_time * 2.6) * 3.0
		TraversalController.State.GLIDE:
			pose = _glide()
			rate = 10.0
		TraversalController.State.VAULT:
			pose = _vault(ik)
			rate = 24.0
		TraversalController.State.SLINGSHOT:
			pose = _slingshot(ik)
			rate = 16.0
		TraversalController.State.WEB_ZIP, TraversalController.State.POINT_ZIP:
			pose = _zip(ik)
			rate = 18.0
		TraversalController.State.PERCH:
			pose = _perch(ik)
		TraversalController.State.WALL_RUN:
			if c.wall_crawl:
				pose = _crawl_pose(ik, delta)
				rate = 30.0
			elif c.wall_vertical:
				pose = _wall_climb_run(ik, delta, maxf(c.velocity.length(), 6.0))
				rate = 45.0
			else:
				pose = _run(ik, delta, maxf(c.velocity.length(), 6.0), true, true)
				rate = 45.0                     # los muelles no deben filtrar el braceo
		TraversalController.State.GROUNDED:
			pose = _grounded(ik, delta)
			rate = lerpf(16.0, 45.0, smoothstep(0.6, 2.5, RegulatedPendulum.flat(c.velocity).length()))
		_:
			pose = _air(ik)
			rate = 12.0
	if _flip_t < 1.0 or c.trick_timer > 0.0:
		pose = _flip_pose(pose)
		rate = maxf(rate, 16.0)
	_update_feel(delta)
	pose = _feel_pose(pose)
	_head_look(pose)
	_apply_pose(pose, rate, delta)
	_apply_acro(delta)
	_apply_ik(ik, delta)
	_update_wings(delta)
	_capture_bones()


func _grounded(ik: Dictionary, delta: float) -> Dictionary:
	var c := controller
	var hspeed := RegulatedPendulum.flat(c.velocity).length()
	if c.land_timer > 0.0 and c.land_kind == "hero":
		return _hero_landing(ik)
	var pose: Dictionary
	var run_w := smoothstep(0.6, 2.5, hspeed)
	var idle := _idle(ik)
	if run_w > 0.0:
		var run_ik := {}
		var run := _run(run_ik, delta, hspeed, c.sprinting, false)
		pose = blend(idle, run, run_w)
		for limb: String in run_ik:
			var a: Dictionary = ik.get(limb, run_ik[limb])
			var b: Dictionary = run_ik[limb]
			ik[limb] = {"t": (a["t"] as Vector3).lerp(b["t"], run_w), "pole": b["pole"],
					"end": b.get("end"), "w": 1.0}
	else:
		_gait = 0.0
		pose = idle
	# Flexión de piernas: carga del Charge Jump y amortiguación de aterrizajes.
	var dip := 0.0
	if c.jump_charge > 0.0:
		dip = c.jump_charge
		pose = add(pose, {"pel_p": 22.0, "sp_p": 8.0, "ch_p": 8.0, "hd_p": -22.0,
				"ae_r": -35.0, "aa_r": -40.0, "eb_r": 20.0, "ae_l": -35.0, "aa_l": -40.0, "eb_l": 20.0}, dip)
		pose["hip_y"] = pose.get("hip_y", 0.0) - 0.42 * dip
	elif c.land_timer > 0.0 and c.land_kind == "soft":
		dip = c.land_timer / 0.25
		pose = add(pose, {"pel_p": 12.0, "hd_p": -10.0, "ae_r": 25.0, "ae_l": 25.0}, dip)
		pose["hip_y"] = pose.get("hip_y", 0.0) - 0.2 * dip
	elif c.land_timer > 0.0 and c.land_kind == "roll":
		pose = add(pose, FLIP_SHAPES["tuck"], 0.6)
	# Curvas: el cuerpo se inclina hacia dentro (aceleración centrípeta real).
	pose["pel_r"] = pose.get("pel_r", 0.0) - rad_to_deg(atan(_turn_rate * hspeed / 9.81)) * 0.6
	return pose


func _idle(ik: Dictionary) -> Dictionary:
	# Respira, pasa el peso de una pierna a otra y mira alrededor despacio.
	var breathe := sin(_time * 2.0)
	var shift := sin(_time * 0.9)
	var pose := STAND.duplicate()
	pose["hip_x"] = -0.03 * shift
	pose["pel_r"] = 2.5 * shift
	pose["ch_r"] = -2.0 * shift
	pose["ch_p"] = 1.0 + breathe * 1.2
	pose["sg_r"] = 1.5 + breathe
	pose["sg_l"] = 1.5 + breathe
	pose["hd_y"] = sin(_time * 0.37) * 25.0 + sin(_time * 1.1) * 4.0
	pose["nk_y"] = sin(_time * 0.37) * 10.0
	for s: String in SIDES:
		var sx: float = SIDES[s]
		var z := 0.03 if s == "r" else -0.03
		_plant_foot(ik, s, Vector3(sx * 0.12, GROUND + ANKLE_H, z), 12.0)
	return pose


## Pie plantado en el suelo del cuerpo (suela plana, punta algo hacia fuera).
func _plant_foot(ik: Dictionary, s: String, local: Vector3, toe_out_deg: float,
		lift_deg: float = 0.0) -> void:
	var sx: float = SIDES[s]
	var fwd_l := Vector3(sx * sin(deg_to_rad(toe_out_deg)), 0.0, cos(deg_to_rad(toe_out_deg)))
	var up := _wdir(Vector3.UP)
	var fwd := _wdir(fwd_l)
	var end := _foot_basis(fwd, up, lift_deg)
	ik["leg_" + s] = {"t": _w(local), "pole": _wdir(Vector3(sx * 0.15, 0.0, 1.0)), "end": end, "w": 1.0}


static func _foot_basis(fwd: Vector3, up: Vector3, lift_deg: float) -> Basis:
	var z := RegulatedPendulum.project_on_plane(fwd, up).normalized()
	var x := up.cross(z).normalized()
	var b := Basis(x, up, z)
	if lift_deg != 0.0:
		b = b * Basis(Vector3.RIGHT, deg_to_rad(lift_deg))      # talón arriba / punta abajo
	return b


## Trayectoria continua de un pie a lo largo de un ciclo de paso: apoyo (t < duty, el pie
## recorre el suelo de zf a zb) y vuelo. Posición Y VELOCIDAD son continuas en los dos
## cambios de fase (el vuelo sale y llega con la velocidad del apoyo, como un pie real:
## coz atrás al despegar, garra atrás antes de pisar); la altura es una campana con
## pendiente cero en los extremos. Devuelve (z, altura, inclinación en grados; + = talón arriba).
static func _foot_cycle(t: float, duty: float, zf: float, zb: float, lift: float, toe: float,
		skew: float, flex: float) -> Vector3:
	if t < duty:
		var u := t / duty
		return Vector3(lerpf(zf, zb, u), 0.0, lerpf(-7.0, toe, smoothstep(0.3, 1.0, u)))
	var ts := 1.0 - duty
	var u := (t - duty) / ts
	var m := (zb - zf) / duty * ts               # dz/du con la velocidad del apoyo
	var u2 := u * u
	var u3 := u2 * u
	var z := (2.0 * u3 - 3.0 * u2 + 1.0) * zb + (u3 - 2.0 * u2 + u) * m \
			+ (-2.0 * u3 + 3.0 * u2) * zf + (u3 - u2) * m
	var y := lift * pow(sin(PI * pow(u, skew)), 2.0)
	var pitch := lerpf(toe, -7.0, smoothstep(0.0, 1.0, u)) + flex * pow(sin(PI * u), 2.0)
	return Vector3(z, y, pitch)


## Generador de pasos (suelo o pared). Pie de apoyo quieto respecto al suelo, talón
## al glúteo al esprintar, rodilla que sube; brazos opuestos a las piernas. Los pies
## siguen curvas C1 (_foot_cycle): sin tirones de velocidad en ningún cambio de fase.
func _run(ik: Dictionary, delta: float, speed: float, sprint: bool, on_wall: bool) -> Dictionary:
	var run01 := clampf(speed / 18.0, 0.0, 1.0)
	var freq := lerpf(1.1, 2.7, run01)
	var duty := lerpf(0.62, 0.3, smoothstep(0.1, 0.75, run01))
	var stance := clampf(speed * duty / freq, 0.3, 0.82)
	_gait = fmod(_gait + freq * delta, 1.0)
	var lift_h := lerpf(0.10, 0.44, smoothstep(0.05, 0.9, run01))
	var toe := lerpf(12.0, 38.0, run01)
	var flex := lerpf(14.0, 30.0, run01)
	var pose := {}
	for s: String in SIDES:
		var sx: float = SIDES[s]
		var ph := fmod(_gait + (0.0 if s == "r" else 0.5), 1.0)
		var f := _foot_cycle(ph, duty, stance * 0.5, -stance * 0.5, lift_h, toe, 0.85, flex)
		var local := Vector3(sx * lerpf(0.12, 0.09, run01), GROUND + ANKLE_H + f.y, f.x + 0.04 * run01)
		var up := _wdir(Vector3.UP)
		var end := _foot_basis(_wdir(Vector3.BACK), up, f.z)
		ik["leg_" + s] = {"t": _w(local), "pole": _wdir(Vector3(sx * 0.1, 0.35, 1.0)), "end": end, "w": 1.0}
		# Brazo opuesto a la pierna del mismo lado (atrás cuando la pierna va delante).
		var wave := cos(TAU * ph)
		pose["ae_" + s] = lerpf(8.0, 12.0, run01) - wave * lerpf(18.0, 55.0, run01)
		pose["aa_" + s] = -8.0 + 14.0 * (1.0 - run01)
		pose["eb_" + s] = lerpf(30.0, 92.0, run01) + maxf(-wave, 0.0) * 15.0
		pose["wf_" + s] = 10.0
	var wave_r := cos(TAU * _gait)
	var bob := -cos(TAU * 2.0 * (_gait - duty * 0.5)) * lerpf(0.012, 0.045, run01)
	pose["hip_y"] = lerpf(0.02, -0.11, run01) + bob
	pose["pel_y"] = 7.0 * run01 * wave_r
	pose["ch_y"] = -11.0 * run01 * wave_r
	pose["nk_y"] = 5.0 * run01 * wave_r
	var lean := lerpf(3.0, 16.0, run01) if not sprint else lerpf(6.0, 24.0, run01)
	pose["pel_p"] = lean * 0.4
	pose["sp_p"] = lean * 0.6
	pose["ch_p"] = lean * 0.5
	pose["hd_p"] = -lean * 1.1
	if on_wall:
		pose["hd_p"] = pose["hd_p"] - 10.0
	return pose


func _swing(ik: Dictionary) -> Dictionary:
	var c := controller
	var p := c.pendulum
	var grip := "r" if c.hand == TraversalController.HAND_RIGHT else "l"
	var pose := spline(SWING_KEYS, (p.phase + 1.0) * 0.5)
	var aggr := smoothstep(24.0, 32.0, c.velocity.length())
	pose = add(pose, SWING_AGGRESSIVE, aggr * smoothstep(-0.6, 0.0, p.phase) * (1.0 - smoothstep(0.4, 0.9, p.phase)))
	pose = add(pose, SWING_G, clampf((p.g_force - 1.5) / 4.0, 0.0, 1.0))
	pose["pel_r"] = c.move_input.x * 12.0
	pose["ch_r"] = c.move_input.x * 6.0
	pose["hd_r"] = -c.move_input.x * 6.0
	if grip == "l":
		pose = mirror(pose)
	# Brazo de la web: IK hacia el anclaje (recto con tensión; al engancharse tira
	# con el codo doblado y se estira en 0,18 s).
	var sh := (_j["sh_" + grip] as Node3D).global_position
	var to_anchor := (p.anchor - sh).normalized()
	var reach := UPPER_ARM + FOREARM
	var pull := 1.0 - smoothstep(0.0, 0.18, c.state_time)
	var target := sh + to_anchor * reach * lerpf(0.97, 0.72, pull)
	var sx: float = SIDES[grip]
	ik["arm_" + grip] = {"t": target, "pole": _wdir(Vector3(sx * 0.7, -0.3, -0.6)),
			"end": null, "w": 1.0, "shrug": 22.0}
	pose["wf_" + grip] = -15.0
	return pose


func _hang(ik: Dictionary, delta: float) -> Dictionary:
	var c := controller
	var p := c.pendulum
	var grip := "r" if c.hand == TraversalController.HAND_RIGHT else "l"
	var other := "l" if grip == "r" else "r"
	var climbing := absf(c.move_input.y) > 0.3
	if climbing:
		_climb += delta * 1.6
	# Las dos manos en la web, una sobre otra; al subir, mano sobre mano.
	var web_dir := RegulatedPendulum.safe_normalized(p.anchor - global_position, _wdir(Vector3.UP))
	var neck := (_j["neck"] as Node3D).global_position
	var a := sin(_climb * TAU) * 0.12 if climbing else 0.0
	var top := neck + web_dir * 0.62
	for s: String in [grip, other]:
		var offset := (0.0 if s == grip else -0.2) + (a if s == grip else -a)
		var sx: float = SIDES[s]
		ik["arm_" + s] = {"t": top + web_dir * offset, "pole": _wdir(Vector3(sx * 0.8, -0.2, -0.5)),
				"end": null, "w": 1.0, "shrug": 20.0}
	# Piernas colgando con inercia; al subir, pedalean.
	var lv := global_transform.basis.orthonormalized().inverse() * c.velocity
	var lag := clampf(-lv.z * 3.0, -30.0, 30.0)
	var kick := sin(_climb * TAU) * 20.0 if climbing else sin(_time * 1.3) * 4.0
	return {"sp_p": 4.0 + lag * 0.2, "hd_p": -12.0, "ch_p": -4.0,
		"lf_r": 18.0 + lag + kick, "kf_r": 38.0 + maxf(kick, 0.0), "af_r": -30.0,
		"lf_l": 6.0 + lag - kick, "kf_l": 20.0 + maxf(-kick, 0.0), "af_l": -35.0,
		"la_r": 8.0, "la_l": 6.0, "lt_r": 8.0, "lt_l": 8.0}


func _air(ik: Dictionary) -> Dictionary:
	var c := controller
	if c.dash_timer > 0.0:
		return DASH.duplicate()
	var vy := c.velocity.y
	var rise := smoothstep(2.0, 10.0, vy)
	var fall := smoothstep(-4.0, -20.0, vy)
	var apex := 1.0 - maxf(rise, fall)
	var leap := AIR_RISE if c.hand == TraversalController.HAND_RIGHT else mirror(AIR_RISE)
	var pose := blend(AIR_APEX, leap, rise / maxf(rise + apex, 1e-3))
	pose = blend(pose, AIR_FALL, fall)
	# Vaivén lento de las extremidades con el aire (no más de ~2 Hz).
	var sway := sin(_time * 2.1) * 4.0 * fall
	pose["ae_r"] = pose.get("ae_r", 0.0) + sway
	pose["ae_l"] = pose.get("ae_l", 0.0) - sway
	pose["lf_r"] = pose.get("lf_r", 0.0) + sin(_time * 1.7) * 6.0 * fall
	pose["lf_l"] = pose.get("lf_l", 0.0) - sin(_time * 1.7) * 6.0 * fall
	return pose


func _glide() -> Dictionary:
	var c := controller
	var pitch_in := -c.move_input.y            # +1 picar, -1 encabritar
	var bank := c.wings.bank / deg_to_rad(c.tuning.glide_max_bank_deg)
	var pose := GLIDE.duplicate()
	var dive := maxf(pitch_in, 0.0)
	var flare := maxf(-pitch_in, 0.0)
	for s: String in SIDES:
		var sx: float = SIDES[s]
		# Tumbado: la elevación barre el brazo hacia la cabeza (encabritar) o hacia los
		# pies (picar); el azimut lo baja hacia el pecho (el ala del lado del giro).
		pose["ae_" + s] = 90.0 + flare * 22.0 - dive * 20.0 + sin(_time * 2.2 + sx) * 1.5
		pose["aa_" + s] = 90.0 + sx * 14.0 * bank
		pose["kf_" + s] = 5.0 + flare * 30.0
		pose["lf_" + s] = -3.0 - flare * 8.0
	pose["ch_p"] = -8.0 - flare * 8.0
	if c.wings.stalled:
		pose["ch_r"] = sin(_time * 4.0) * 6.0
	return pose


func _zip(ik: Dictionary) -> Dictionary:
	var c := controller
	var target := _perch_or_zip_target()
	var pose := ZIP.duplicate()
	for s: String in SIDES:
		var sx: float = SIDES[s]
		var sh := (_j["sh_" + s] as Node3D).global_position
		var d := RegulatedPendulum.safe_normalized(target - sh, _wdir(Vector3.BACK))
		ik["arm_" + s] = {"t": sh + d * (UPPER_ARM + FOREARM) * (0.93 if s == "r" else 0.8),
				"pole": _wdir(Vector3(sx * 0.8, -0.5, -0.3)), "end": null, "w": 1.0, "shrug": 14.0}
	if c.state == TraversalController.State.POINT_ZIP:
		pose = add(pose, {"lf_r": 40.0, "kf_r": 30.0, "lf_l": 40.0, "kf_l": 40.0, "sp_p": 8.0}, 1.0)
	return pose


func _perch_or_zip_target() -> Vector3:
	var c := controller
	if c.state == TraversalController.State.POINT_ZIP:
		return c._perch_target
	return _zip_target if _zip_target != Vector3.ZERO else _w(Vector3(0.0, 0.5, 5.0))


func _perch(ik: Dictionary) -> Dictionary:
	# "Spidey squat": pies muy abiertos, rodillas fuera, mano derecha apoyada entre
	# los pies, antebrazo izquierdo sobre la rodilla y la mirada al frente.
	var breathe := sin(_time * 1.8)
	var g := GROUND - 0.05
	_plant_foot(ik, "r", Vector3(-0.25, g + ANKLE_H, 0.05), 28.0)
	_plant_foot(ik, "l", Vector3(0.25, g + ANKLE_H, 0.02), 28.0)
	for s: String in SIDES:
		var sx: float = SIDES[s]
		(ik["leg_" + s] as Dictionary)["pole"] = _wdir(Vector3(sx * 1.0, 0.0, 0.7))
	var hand := _w(Vector3(-0.06, g + WRIST_H, 0.36))
	ik["arm_r"] = {"t": hand, "pole": _wdir(Vector3(-0.8, 0.2, -0.3)),
			"end": _hand_flat_basis("r"), "w": 1.0}
	return {"hip_y": -0.5, "pel_p": 30.0, "sp_p": 14.0 + breathe, "ch_p": 8.0, "nk_p": -18.0, "hd_p": -40.0,
		"ae_l": 42.0, "aa_l": 35.0, "eb_l": 95.0, "at_l": -20.0, "wf_l": 15.0,
		"hd_y": sin(_time * 0.45) * 18.0}


## Mano con la palma apoyada en el suelo del cuerpo, dedos hacia delante.
func _hand_flat_basis(s: String) -> Basis:
	var sx: float = SIDES[s]
	var up := _wdir(Vector3.UP)
	var fwd := _wdir(Vector3.BACK)
	var y := -fwd                               # los dedos van por -Y local
	var x := up * sx                            # la palma (±X local) mira al suelo
	return Basis(x, y, x.cross(y)).orthonormalized()


func _hero_landing(ik: Dictionary) -> Dictionary:
	# Aterrizaje de superhéroe: rodilla derecha al suelo, pie izquierdo delante,
	# puño derecho apoyado y brazo izquierdo abierto atrás.
	var c := controller
	var k := clampf(c.land_timer / 0.7, 0.0, 1.0)
	var g := GROUND
	_plant_foot(ik, "l", Vector3(0.16, g + ANKLE_H, 0.3), 10.0)
	_plant_foot(ik, "r", Vector3(-0.14, g + ANKLE_H + 0.03, -0.42), 5.0, 55.0)
	(ik["leg_r"] as Dictionary)["pole"] = _wdir(Vector3(-0.1, -1.0, 0.5))
	ik["arm_r"] = {"t": _w(Vector3(-0.2, g + WRIST_H + 0.02, 0.32)), "pole": _wdir(Vector3(-1.0, 0.3, -0.2)),
			"end": _hand_flat_basis("r"), "w": 1.0}
	return {"hip_y": lerpf(-0.36, -0.5, k), "pel_p": 26.0, "sp_p": 12.0, "ch_p": 12.0,
		"nk_p": -12.0, "hd_p": -38.0,
		"ae_l": 55.0, "aa_l": 120.0, "eb_l": 25.0, "at_l": 30.0}


## Carrera vertical por la fachada: el cuerpo casi paralelo a la pared y de cara a
## ella; los pies la pisan (apoyo bajando respecto al cuerpo, que sube) y se separan
## para volver arriba; los brazos bracean con los codos doblados.
func _wall_climb_run(ik: Dictionary, delta: float, speed: float) -> Dictionary:
	var c := controller
	var run01 := clampf(speed / 18.0, 0.0, 1.0)
	var freq := lerpf(1.6, 2.6, run01)
	var duty := 0.45
	var stroke := clampf(speed * duty / freq, 0.3, 0.6)
	_gait = fmod(_gait + freq * delta, 1.0)
	var center := -0.32 - stroke * 0.5
	# Plano de la pared en coordenadas del cuerpo: n·p = -0,4 (la cápsula está a 0,4 m).
	var n_l := (global_transform.basis.orthonormalized().inverse() * c.wall_normal).normalized()
	var pose := {}
	for s: String in SIDES:
		var sx: float = SIDES[s]
		var ph := fmod(_gait + (0.0 if s == "r" else 0.5), 1.0)
		# Mismo ciclo C1 que la carrera: "delante" = arriba por la pared, la altura del
		# vuelo = separación de la fachada.
		var f := _foot_cycle(ph, duty, stroke * 0.5, -stroke * 0.5, 0.16, 8.0, 0.9, 10.0)
		var y := center + f.x
		var x := sx * 0.13
		var z := (-0.4 - ANKLE_H - f.y - n_l.x * x - n_l.y * y) / minf(n_l.z, -0.2)
		var end := _foot_basis(_wdir(Vector3.UP), c.wall_normal, f.z * 0.6)
		ik["leg_" + s] = {"t": _w(Vector3(x, y, z)), "pole": _wdir(Vector3(sx * 0.3, 0.6, 1.0)),
				"end": end, "w": 1.0}
		var wave := cos(TAU * ph)
		pose["ae_" + s] = 20.0 + wave * 35.0
		pose["aa_" + s] = 20.0
		pose["eb_" + s] = 95.0
	pose["ch_p"] = 8.0
	pose["hd_p"] = -32.0
	pose["hip_y"] = -cos(TAU * 2.0 * _gait) * 0.02
	return pose


func _crawl_pose(ik: Dictionary, delta: float) -> Dictionary:
	# Gateo: pies y manos en la pared (diagonales alternas), codos y rodillas fuera.
	var c := controller
	var inv := global_transform.basis.orthonormalized().inverse()
	var lv := inv * c.velocity
	var mv := Vector2(lv.x, lv.y)
	var speed := mv.length()
	var dir := mv / speed if speed > 0.2 else Vector2.ZERO
	var step := 0.34
	var freq := clampf(speed / (step * 1.6), 0.0, 2.6)
	_crawl = fmod(_crawl + freq * delta, 1.0)
	var wall := 0.2                             # la pared está a +Z (el pecho mira a la fachada)
	# Como una araña: manos altas (por encima de la cabeza, brazos casi estirados) y pies
	# bajos y abiertos con las rodillas hacia fuera.
	var limbs := {"arm_r": [Vector2(-0.36, 0.95), 0.0], "arm_l": [Vector2(0.36, 0.95), 0.5],
			"leg_r": [Vector2(-0.38, -0.72), 0.5], "leg_l": [Vector2(0.38, -0.72), 0.0]}
	for limb: String in limbs:
		var base: Vector2 = limbs[limb][0]
		var ph := fmod(_crawl + float(limbs[limb][1]), 1.0)
		var off := Vector2.ZERO
		var lift := 0.0
		if speed > 0.2:
			if ph < 0.7:
				off = -dir * (step * 0.5 - step * ph / 0.7)
			else:
				var u := (ph - 0.7) / 0.3
				off = dir * (-step * 0.5 + step * u)
				lift = sin(u * PI) * 0.1
		var s := limb.substr(limb.length() - 1)
		var sx: float = SIDES[s]
		var is_arm := limb.begins_with("arm")
		var local := Vector3(base.x + off.x, base.y + off.y, wall - (WRIST_H if is_arm else ANKLE_H) - lift)
		var pole := Vector3(sx * 1.0, -0.4, -0.6) if is_arm else Vector3(sx * 1.0, 0.3, -0.5)
		var entry := {"t": _w(local), "pole": _wdir(pole), "w": 1.0, "end": null}
		if not is_arm:
			# Planta del pie contra la pared, punta hacia arriba.
			entry["end"] = _foot_basis(_wdir(Vector3.UP), _wdir(Vector3.FORWARD), 0.0)
		ik[limb] = entry
	var breathe := sin(_time * 1.9)
	return {"hip_z": 0.0, "ch_p": -4.0 + breathe, "nk_p": -10.0, "hd_p": -28.0,
		"pel_r": dir.x * 6.0, "ch_r": -dir.x * 4.0}


func _slingshot(ik: Dictionary) -> Dictionary:
	var c := controller
	var ch := c.slingshot_charge
	for s: String in SIDES:
		var sx: float = SIDES[s]
		_plant_foot(ik, s, Vector3(sx * 0.2, GROUND + ANKLE_H, 0.14 if s == "l" else -0.12), 15.0)
		var anchor: Vector3 = c.slingshot_anchors[1 if s == "r" else 0]
		var sh := (_j["sh_" + s] as Node3D).global_position
		var d := RegulatedPendulum.safe_normalized(anchor - sh, _wdir(Vector3.BACK))
		ik["arm_" + s] = {"t": sh + d * (UPPER_ARM + FOREARM) * lerpf(0.8, 0.97, ch),
				"pole": _wdir(Vector3(sx * 0.7, -0.6, -0.2)), "end": null, "w": 1.0}
	var shake := sin(_time * 9.0) * ch * ch * 1.5
	return {"hip_y": -0.34 * ch - 0.05, "hip_z": -0.22 * ch, "pel_p": -8.0 * ch + 10.0,
		"sp_p": -8.0 * ch, "ch_p": -10.0 * ch + shake, "hd_p": 6.0 * ch - 8.0}


func _vault(ik: Dictionary) -> Dictionary:
	# Vault: la mano derecha apoyada en el obstáculo, piernas recogidas hacia la
	# izquierda, el brazo izquierdo abierto para equilibrar.
	var c := controller
	var t := clampf(c.state_time / maxf(c._vault_time, 0.01), 0.0, 1.0)
	if t < 0.65:
		ik["arm_r"] = {"t": c.vault_hand_point + Vector3.UP * WRIST_H,
				"pole": _wdir(Vector3(-1.0, 0.2, -0.3)), "end": _hand_flat_basis("r"), "w": 1.0}
	return {"pel_r": 16.0, "pel_p": 14.0, "ch_p": 12.0, "ch_r": -10.0, "hd_p": -18.0,
		"lf_r": 86.0, "la_r": -22.0, "kf_r": 112.0, "af_r": -30.0,
		"lf_l": 72.0, "la_l": 32.0, "kf_l": 100.0, "af_l": -30.0,
		"ae_l": 70.0, "aa_l": 95.0, "eb_l": 20.0}


func _flip_pose(base: Dictionary) -> Dictionary:
	var c := controller
	var style := _flip_style
	var t := _flip_t
	if c.trick_timer > 0.0 and _flip_t >= 1.0:
		t = 1.0 - c.trick_timer / TraversalController.TRICK_TIME
	if c.trick_timer > 0.0 and c.trick_index in [TraversalController.Trick.ROLL_LEFT,
			TraversalController.Trick.ROLL_RIGHT]:
		style = "spread"
	# Anticipación (0-15 %), forma (hasta el 75 %) y apertura a la caída.
	var shape: Dictionary = FLIP_SHAPES.get(style, FLIP_SHAPES["tuck"])
	var pre := smoothstep(0.0, 0.06, t) * (1.0 - smoothstep(0.08, 0.2, t))
	var hold := smoothstep(0.08, 0.26, t) * (1.0 - smoothstep(0.78, 1.0, t))
	var pose := blend(base, FLIP_ANTICIPATION, pre * 0.6)
	return blend(pose, shape, hold)


## Aceleración transitoria del cuerpo (filtro paso alto de la aceleración): lo que "se
## siente" al despegar, al frenar, al aterrizar o al enganchar la web. La gravedad y los
## regímenes estables se quedan en el filtro lento y no cuentan.
func _update_feel(delta: float) -> void:
	var c := controller
	var a := (c.velocity - _prev_vel) / maxf(delta, 1e-4)
	_prev_vel = c.velocity
	a = a.limit_length(400.0)
	_acc_slow = _acc_slow.lerp(a, 1.0 - exp(-delta / 0.45))
	var local := global_transform.basis.orthonormalized().inverse() * (a - _acc_slow)
	_feel = _feel.lerp(local.limit_length(90.0), 1.0 - exp(-14.0 * delta))


## Acción secundaria: el cuerpo reacciona a lo que le pasa. Acelerar echa el pecho
## adelante y arrastra piernas, brazos y cabeza; un frenazo los adelanta; un golpe hacia
## arriba (aterrizaje, fondo del arco) comprime cadera y rodillas y lanza los brazos; una
## aceleración lateral inclina el tronco hacia dentro.
func _feel_pose(pose: Dictionary) -> Dictionary:
	var c := controller
	if c.state in [TraversalController.State.SLINGSHOT, TraversalController.State.PERCH,
			TraversalController.State.VAULT, TraversalController.State.WALL_RUN]:
		return pose
	var az := signf(_feel.z) * maxf(absf(_feel.z) - 1.5, 0.0)
	var ax := signf(_feel.x) * maxf(absf(_feel.x) - 1.5, 0.0)
	var ay := signf(_feel.y) * maxf(absf(_feel.y) - 1.5, 0.0)
	var k := 1.0 if c.state != TraversalController.State.GLIDE else 0.4
	var out := pose.duplicate()
	var add_ch := func(key: String, v: float) -> void: out[key] = out.get(key, 0.0) + v * k
	add_ch.call("ch_p", clampf(az * 0.22, -8.0, 8.0))
	add_ch.call("sp_p", clampf(az * 0.14, -5.0, 5.0))
	add_ch.call("hd_p", clampf(-az * 0.2, -7.0, 7.0))
	add_ch.call("ch_r", clampf(-ax * 0.22, -8.0, 8.0))
	add_ch.call("pel_r", clampf(-ax * 0.16, -6.0, 6.0))
	add_ch.call("hd_r", clampf(ax * 0.1, -4.0, 4.0))
	for s: String in SIDES:
		add_ch.call("lf_" + s, clampf(-az * 0.32 + ay * 0.22, -16.0, 22.0))
		add_ch.call("kf_" + s, clampf(ay * 0.5, -8.0, 45.0))
		add_ch.call("ae_" + s, clampf(-az * 0.36 + ay * 0.32, -16.0, 24.0))
	if c.state == TraversalController.State.GROUNDED:
		add_ch.call("hip_y", clampf(-ay * 0.005, -0.22, 0.04))
	return out


## La cabeza mira hacia donde se va (el cuello se lleva un 40 %).
func _head_look(pose: Dictionary) -> void:
	var c := controller
	var v := c.velocity
	if v.length() < 2.0 or c.state in [TraversalController.State.GLIDE, TraversalController.State.DIVE,
			TraversalController.State.WALL_RUN, TraversalController.State.PERCH]:
		return
	if _flip_t < 1.0:
		return
	var look := v.normalized()
	if c.aim_anchor != null and c.state in [TraversalController.State.FALL, TraversalController.State.SWING]:
		var to_aim := (c.aim_anchor.point - (_j["head"] as Node3D).global_position).normalized()
		look = (look * 0.55 + to_aim * 0.45).normalized()
	var local := (_j["chest"] as Node3D).global_transform.basis.orthonormalized().inverse() * look
	var yaw := clampf(rad_to_deg(atan2(local.x, local.z)), -60.0, 60.0)
	var pitch := clampf(-rad_to_deg(atan2(local.y, Vector2(local.x, local.z).length())), -35.0, 35.0)
	var w := 0.6 if c.state == TraversalController.State.GROUNDED else 0.45
	pose["nk_y"] = pose.get("nk_y", 0.0) + yaw * 0.4 * w
	pose["hd_y"] = pose.get("hd_y", 0.0) + yaw * 0.6 * w
	pose["hd_p"] = pose.get("hd_p", 0.0) + pitch * 0.4 * w


# ---------------------------------------------------------------------------
# Muelles, acrobacias e IK
# ---------------------------------------------------------------------------
func _apply_pose(pose: Dictionary, rate: float, delta: float) -> void:
	var targets := _targets(pose)
	for key: String in targets:
		_spring_joint(key, targets[key], rate, delta)
	var root := Vector3(pose.get("hip_x", 0.0), pose.get("hip_y", 0.0), pose.get("hip_z", 0.0))
	# Muelle crítico para la altura de la cadera.
	var omega := maxf(rate, 16.0)
	_root_vel += ((root - _pelvis.position) * omega * omega - _root_vel * 2.0 * omega) * delta
	_pelvis.position += _root_vel * delta


## Muelle amortiguado por articulación (semi-implícito); ζ ≈ 0,85 en extremidades.
func _spring_joint(key: String, target: Quaternion, rate: float, delta: float) -> void:
	var node: Node3D = _j[key]
	# La pelvis guarda su postura aparte: encima se le suman las acrobacias.
	var cur: Quaternion = node.get_meta("pose_q", node.quaternion) if key == "pelvis" else node.quaternion
	var dq := target * cur.inverse()
	if dq.w < 0.0:
		dq = -dq
	var s := sqrt(maxf(1.0 - dq.w * dq.w, 0.0))
	var axis_angle := Vector3(dq.x, dq.y, dq.z) * 2.0
	if s > 1e-4:
		axis_angle = Vector3(dq.x, dq.y, dq.z) / s * (2.0 * acos(clampf(dq.w, -1.0, 1.0)))
	var zeta := 1.0 if key in TORSO else 0.7
	var w: Vector3 = _joint_vel.get(key, Vector3.ZERO)
	w += (axis_angle * rate * rate - w * 2.0 * zeta * rate) * delta
	w = w.limit_length(40.0)
	_joint_vel[key] = w
	var ang := w.length() * delta
	var q := cur
	if ang > 1e-6:
		q = (Quaternion(w / w.length(), ang) * cur).normalized()
	if key == "pelvis":
		node.set_meta("pose_q", q)
	else:
		node.quaternion = q


func _apply_acro(delta: float) -> void:
	var c := controller
	# Inclinación en las curvas del swing (stick) y de la carrera (en la postura).
	var hv := RegulatedPendulum.flat(c.velocity)
	var heading := atan2(hv.x, hv.z)
	if hv.length() > 1.0:
		var raw := wrapf(heading - _prev_heading, -PI, PI) / maxf(delta, 1e-4)
		_turn_rate = lerpf(_turn_rate, clampf(raw, -4.0, 4.0), 1.0 - exp(-8.0 * delta))
	else:
		_turn_rate = lerpf(_turn_rate, 0.0, 1.0 - exp(-8.0 * delta))
	_prev_heading = heading
	var acro := Quaternion.IDENTITY
	if _flip_t < 1.0:
		_flip_t = minf(_flip_t + delta / _flip_time, 1.0)
		# El giro arranca tras la anticipación, es más rápido agrupado (en el medio) y
		# llega suave para abrirse a la caída (smootherstep).
		var u := clampf((_flip_t - 0.06) / 0.88, 0.0, 1.0)
		var e := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
		acro = Quaternion(_flip_axis, TAU * _flip_turns * e)
	var pose_q: Quaternion = _pelvis.get_meta("pose_q", Quaternion.IDENTITY)
	_pelvis.quaternion = acro * pose_q


func _apply_ik(ik: Dictionary, delta: float) -> void:
	for limb: String in _ik_w:
		var want := 1.0 if ik.has(limb) else 0.0
		var cur: float = _ik_w[limb]
		cur = move_toward(cur, want, delta * (9.0 if want > cur else 6.0))
		_ik_w[limb] = cur
		if cur <= 0.001 or not ik.has(limb):
			_ik_prev.erase(limb)
			_ik_off.erase(limb)
			_ik_f.erase(limb)
			continue
		var req: Dictionary = ik[limb]
		var s := limb.substr(limb.length() - 1)
		var w := cur * float(req.get("w", 1.0))
		req = req.duplicate()
		req["t"] = _absorb_jump(limb, req["t"], delta)
		if limb.begins_with("arm"):
			if req.has("shrug"):
				var cl: Node3D = _j["cl_" + s]
				cl.quaternion = cl.quaternion.slerp(_rz(SIDES[s] * float(req["shrug"])), w)
			_two_bone(_j["sh_" + s], _j["el_" + s], UPPER_ARM, FOREARM, req["t"], req["pole"], -1.0, w)
			if req.get("end") != null:
				_set_global_basis(_j["wr_" + s], req["end"], w)
		else:
			_two_bone(_j["hip_" + s], _j["kn_" + s], THIGH, SHIN, req["t"], req["pole"], 1.0, w)
			if req.get("end") != null:
				_set_global_basis(_j["ank_" + s], req["end"], w)


## Suaviza el objetivo de la IK de cada miembro en dos pasos, siempre en coordenadas del
## cuerpo (así el avance del cuerpo, 20-50 m/s, no cuenta como movimiento del objetivo):
##  1. Filtro crítico de 2.º orden con compensación de retardo (sale x + v·2/ω): un objetivo
##     que se mueve a velocidad constante lo sigue SIN retraso (el pie de apoyo no patina),
##     pero un cambio brusco de velocidad (cambio de fase del paso) se reparte en unos
##     30 ms en vez de ser un golpe de aceleración.
##  2. Inercialización: si el objetivo salta (cambio de estado, agarre nuevo...) el salto se
##     absorbe con un decaimiento rápido en vez de aparecer de golpe.
func _absorb_jump(limb: String, target: Vector3, delta: float) -> Vector3:
	const OMEGA := 70.0
	var raw := to_local(target)
	var off: Vector3 = _ik_off.get(limb, Vector3.ZERO)
	var f: Array = _ik_f.get(limb, [raw, Vector3.ZERO])
	if _ik_prev.has(limb):
		var d := raw - (_ik_prev[limb] as Vector3)
		if d.length() > 0.28:
			off -= d
			f[0] = (f[0] as Vector3) + d
	_ik_prev[limb] = raw
	var x: Vector3 = f[0]
	var v: Vector3 = f[1]
	# Solución exacta del muelle crítico (estable a cualquier paso, a diferencia de Euler).
	var rel := x - raw
	var e := exp(-OMEGA * delta)
	var tmp := (v + rel * OMEGA) * delta
	x = raw + (rel + tmp) * e
	v = (v - tmp * OMEGA) * e
	_ik_f[limb] = [x, v]
	off *= exp(-delta / 0.07)
	_ik_off[limb] = off
	return to_global(x + v * (2.0 / OMEGA) + off)


## IK analítica de dos huesos. La raíz y el medio tienen el hueso a lo largo de -Y;
## hinge +1: la bisagra dobla hacia -Z (rodilla), -1: hacia +Z (codo).
func _two_bone(root: Node3D, mid: Node3D, l1: float, l2: float, target: Vector3, pole: Vector3,
		hinge: float, weight: float) -> void:
	var r := root.global_position
	var d := target - r
	var reach := l1 + l2 - 0.002
	var dist := maxf(d.length(), absf(l1 - l2) + 0.01)
	if dist > reach * 0.88:
		# Saturación suave cerca de la extensión total: sin ella el ángulo de la rodilla
		# (un arccos) pasa de doblada a recta en un solo paso.
		dist = reach * 0.88 + reach * 0.12 * tanh((dist - reach * 0.88) / (reach * 0.12))
	var dn := d.normalized() if d.length_squared() > 1e-8 else Vector3.DOWN
	# Dirección de la flexión = polo proyectado sobre el plano normal al hueso. Cuando el
	# polo casi coincide con la dirección del miembro esa proyección es inestable (la
	# rodilla "da la vuelta" de un paso a otro): se mezcla con la flexión del paso anterior.
	var key := String(root.name)
	var b := pole - dn * dn.dot(pole)
	var bl := b.length()
	var mem: Vector3 = _bend_mem.get(key, Vector3.ZERO)
	mem = mem - dn * dn.dot(mem)
	if bl < 0.4 and mem.length_squared() > 1e-4:
		var k := bl / 0.4
		b = (b.normalized() if bl > 1e-4 else Vector3.ZERO) * k + mem.normalized() * (1.0 - k)
	if b.length_squared() < 1e-6:
		b = dn.cross(Vector3.RIGHT if absf(dn.x) < 0.9 else Vector3.BACK)
	b = b.normalized()
	_bend_mem[key] = b
	var h := b.cross(dn)
	var a := acos(clampf((l1 * l1 + dist * dist - l2 * l2) / (2.0 * l1 * dist), -1.0, 1.0))
	var mid_p := r + dn * (l1 * cos(a)) + b * (l1 * sin(a))
	var end_p := r + dn * dist
	var u := (mid_p - r) / l1
	var wv := (end_p - mid_p) / l2
	var x := h * hinge
	var y := -u
	var basis := Basis(x, y, x.cross(y)).orthonormalized()
	var parent_basis := (root.get_parent() as Node3D).global_transform.basis.orthonormalized()
	var q_root := Quaternion((parent_basis.inverse() * basis).orthonormalized())
	var bend := acos(clampf(u.dot(wv), -1.0, 1.0))
	root.quaternion = root.quaternion.slerp(q_root, weight)
	mid.quaternion = mid.quaternion.slerp(Quaternion(Vector3.RIGHT, hinge * bend), weight)


func _set_global_basis(node: Node3D, basis: Basis, weight: float) -> void:
	var parent_basis := (node.get_parent() as Node3D).global_transform.basis.orthonormalized()
	var q := Quaternion((parent_basis.inverse() * basis).orthonormalized())
	node.quaternion = node.quaternion.slerp(q, weight)


# ---------------------------------------------------------------------------
# Eventos -> acrobacias
# ---------------------------------------------------------------------------
## Sueltas como en el juego: cada una elige una acrobacia distinta (no se repite
## la anterior); la perfecta es doble o con giro y medio.
const RELEASE_FLIPS := [
	[Vector3.RIGHT, 1.0, 0.62, "tuck"],                # voltereta adelante agrupada
	[Vector3(0.25, 1.0, 0.0), 1.0, 0.62, "layout"],    # tirabuzón estirado
	[Vector3.UP, 1.0, 0.55, "spread"],                 # pirueta abierta
	[Vector3.FORWARD, 1.0, 0.62, "spread"],            # rueda lateral
	[Vector3.LEFT, 1.0, 0.68, "layout"],               # mortal atrás estirado
	[Vector3.RIGHT, 1.0, 0.62, "pike"],                # voltereta carpada
]


func start_flip(axis: Vector3, turns: float, duration: float, style := "tuck") -> void:
	if _flip_t < 0.75:
		return                       # ya girando: otro giro encima haría saltar el cuerpo
	_flip_axis = axis.normalized()
	_flip_turns = turns
	_flip_time = duration
	_flip_style = style
	_flip_t = 0.0


func _on_web_released(_hand: int, perfect: bool) -> void:
	if controller.state != TraversalController.State.FALL:
		return
	if controller.velocity.length() < 18.0 and not perfect:
		return
	var i := randi() % RELEASE_FLIPS.size()
	if i == _last_flip:
		i = (i + 1) % RELEASE_FLIPS.size()
	_last_flip = i
	var f: Array = RELEASE_FLIPS[i]
	if perfect:
		start_flip(f[0], 2.0, float(f[2]) * 1.35, f[3])
	else:
		start_flip(f[0], f[1], f[2], f[3])


func _on_trick() -> void:
	var tt := TraversalController.TRICK_TIME
	match controller.trick_index:
		TraversalController.Trick.FRONT_FLIP:
			start_flip(Vector3.RIGHT, 1.0, tt, "tuck")
		TraversalController.Trick.BACK_FLIP:
			start_flip(Vector3.LEFT, 1.0, tt, "layout")
		TraversalController.Trick.ROLL_LEFT:
			start_flip(Vector3.FORWARD, 1.0, tt, "spread")
		TraversalController.Trick.ROLL_RIGHT:
			start_flip(Vector3.BACK, 1.0, tt, "spread")
		_:
			start_flip(Vector3.UP, 2.0, tt, "layout")


func _on_landed(_impact: float) -> void:
	if controller.land_kind == "roll":
		start_flip(Vector3.RIGHT, 1.0, controller.tuning.quick_recovery_window, "tuck")


# ---------------------------------------------------------------------------
# Huesos del Skeleton3D (interpolados entre pasos de física)
# ---------------------------------------------------------------------------
func _capture_bones() -> void:
	if _skeleton == null:
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
	if _skeleton == null or _bone_cur.is_empty():
		return
	var f := Engine.get_physics_interpolation_fraction()
	for i in _bone_cur.size():
		_skeleton.set_bone_pose_rotation(i, _bone_prev[i].slerp(_bone_cur[i], f))
	_skeleton.set_bone_pose_position(0, _root_prev.lerp(_root_cur, f))


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
	for s: String in SIDES:
		var sign: float = -float(SIDES[s])      # +1 derecha (como antes)
		var sh := to_local((_j["sh_" + s] as Node3D).global_position)
		var el := to_local((_j["el_" + s] as Node3D).global_position)
		var wr := to_local((hand_socket_right if s == "r" else hand_socket_left).global_position)
		var hip := to_local((_j["hip_" + s] as Node3D).global_position)
		var knee := to_local((_j["kn_" + s] as Node3D).global_position)
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
					_wing_mesh.surface_set_normal(n * sign)
					_wing_mesh.surface_set_uv(Vector2(float(q.x) / NU, float(q.y) / NV))
					_wing_mesh.surface_add_vertex(grid[q.x][q.y])
	_wing_mesh.surface_end()
