class_name TraversalAnimator
extends Node
## Traduce el estado físico del TraversalController a animación (sección 3):
## parámetros del AnimationTree, orientación procedural del cuerpo, pesos de IK,
## head tracking y la web visual. No modifica la física.
##
## Estructura esperada del AnimationTree (raíz AnimationNodeBlendTree):
##   Locomotion (StateMachine) -> GLoad (Add2) -> Lean (Add3) -> FireL (OneShot)
##   -> FireR (OneShot) -> Trick (OneShot) -> output
## Estados de Locomotion: Grounded, Fall, Dive, Swing_L, Swing_R, Release_Neutral,
##   Release_Flip, Release_Reach, WebZip, PointZip, Perch, WallRun_V, WallRun_H,
##   Land_Soft, Land_Roll, Land_Hero, Glide (BlendSpace2D cabeceo x alabeo),
##   Slingshot (BlendSpace1D por carga). Los tiempos de mezcla viven en las transiciones
##   (xfade_time), con los valores de la tabla de la sección 5.

const P_PLAYBACK := "parameters/Locomotion/playback"
const P_SWING_L := "parameters/Locomotion/Swing_L/blend_position"
const P_SWING_R := "parameters/Locomotion/Swing_R/blend_position"
const P_FALL := "parameters/Locomotion/Fall/blend_position"
const P_DIVE := "parameters/Locomotion/Dive/blend_position"
const P_WALL_H := "parameters/Locomotion/WallRun_H/blend_position"
const P_GLOAD := "parameters/GLoad/add_amount"
const P_LEAN := "parameters/Lean/add_amount"
const P_FIRE_L := "parameters/FireL/request"
const P_FIRE_R := "parameters/FireR/request"
const P_TRICK := "parameters/Trick/request"
const P_GLIDE := "parameters/Locomotion/Glide/blend_position"
const P_SLING := "parameters/Locomotion/Slingshot/blend_position"

const STATE_NODES := {
	TraversalController.State.GROUNDED: "Grounded",
	TraversalController.State.FALL: "Fall",
	TraversalController.State.DIVE: "Dive",
	TraversalController.State.WEB_ZIP: "WebZip",
	TraversalController.State.POINT_ZIP: "PointZip",
	TraversalController.State.PERCH: "Perch",
	TraversalController.State.GLIDE: "Glide",
	TraversalController.State.SLINGSHOT: "Slingshot",
	TraversalController.State.VAULT: "Vault",
}

@export var controller: TraversalController
@export var anim_tree: AnimationTree
## Raíz visual del personaje (hija del controller). Solo se rota, nunca se traslada.
@export var visual_root: Node3D
@export var web_line: WebLine
## Segunda web opcional: al encadenar, la anterior termina su caída mientras sale la nueva.
@export var web_line_alt: WebLine
## Webs extra para acciones con dos manos (Super Slingshot) sin reciclar las que caen.
@export var extra_web_lines: Array[WebLine] = []
@export var hand_socket_left: Node3D     ## BoneAttachment3D en la muñeca
@export var hand_socket_right: Node3D

@export_group("IK")
@export var hand_ik_left: TwoBoneIKModifier
@export var hand_ik_right: TwoBoneIKModifier
@export var foot_ik_left: TwoBoneIKModifier
@export var foot_ik_right: TwoBoneIKModifier
@export var look_at: LookAtChainModifier

@export_group("Calibración")
@export var g_force_max := 6.0
@export var aggressive_on_speed := 26.0
@export var aggressive_off_speed := 22.0
@export var fall_speed_ref := 40.0
@export var dive_speed_ref := 58.0
@export var orient_rate_swing := 14.0
@export var orient_rate_air := 6.0
@export var param_rate := 12.0
@export var release_anim_time := 0.45
@export var reach_anim_time := 0.25
@export var land_anim_time := 0.35

var aggressive := false
var _g_load := 0.0
var _lean := 0.0
var _aggr_blend := 0.0
var _phase := 0.0
var _ik_weight := 0.0
var _offhand_weight := 0.0
var _one_shot_state := ""
var _one_shot_timer := 0.0
var _playback: AnimationNodeStateMachinePlayback
var _current_node := ""
var _active_webs: Array[WebLine] = []


func _ready() -> void:
	if anim_tree:
		_playback = anim_tree.get(P_PLAYBACK)
	controller.web_fired.connect(_on_web_fired)
	controller.web_missed.connect(_on_web_missed)
	controller.web_released.connect(_on_web_released)
	controller.landed.connect(_on_landed)
	controller.trick_started.connect(_on_trick)
	for ik in [hand_ik_left, hand_ik_right, foot_ik_left, foot_ik_right]:
		if ik:
			ik.influence = 0.0


func _physics_process(delta: float) -> void:
	var k := 1.0 - exp(-param_rate * delta)
	var p := controller.pendulum
	var spd := controller.velocity.length()

	# Agresividad con histéresis (evita parpadeo entre sets de animación).
	if aggressive and spd < aggressive_off_speed:
		aggressive = false
	elif not aggressive and spd > aggressive_on_speed:
		aggressive = true
	_aggr_blend = lerpf(_aggr_blend, 1.0 if aggressive else 0.0, k * 0.5)

	var swinging := controller.state == TraversalController.State.SWING
	var g_target := clampf((p.g_force - 1.0) / (g_force_max - 1.0), 0.0, 1.0) if swinging else 0.0
	_g_load = lerpf(_g_load, g_target, k)
	_lean = lerpf(_lean, controller.move_input.x if swinging else 0.0, k)
	if swinging:
		_phase = lerpf(_phase, p.phase, 1.0 - exp(-30.0 * delta))

	_update_state_machine(delta)
	_update_blend_params(spd)
	_update_orientation(delta)
	_update_ik(delta)


# ---------------------------------------------------------------------------
# Selección de estado de animación
# ---------------------------------------------------------------------------
func _update_state_machine(delta: float) -> void:
	_one_shot_timer = maxf(_one_shot_timer - delta, 0.0)
	var node := _node_for_state()
	if _one_shot_timer > 0.0 and controller.state in [TraversalController.State.FALL,
			TraversalController.State.GROUNDED]:
		node = _one_shot_state      # suelta / aterrizaje en curso
	if node != _current_node and _playback:
		_playback.travel(node)
		_current_node = node


func _node_for_state() -> String:
	var c := controller
	match c.state:
		TraversalController.State.SWING:
			return "Swing_R" if c.hand == TraversalController.HAND_RIGHT else "Swing_L"
		TraversalController.State.WALL_RUN:
			return "WallRun_V" if c.wall_vertical else "WallRun_H"
	return STATE_NODES.get(c.state, "Fall")


func _update_blend_params(spd: float) -> void:
	if anim_tree == null:
		return
	# Swing: X = fase del arco (-1 atrás .. 0 fondo .. 1 ápice), Y = agresividad.
	var swing_bp := Vector2(_phase, _aggr_blend)
	anim_tree.set(P_SWING_L, swing_bp)
	anim_tree.set(P_SWING_R, swing_bp)
	var v := controller.velocity
	var horiz := RegulatedPendulum.flat(v).length()
	anim_tree.set(P_FALL, Vector2(clampf(horiz / fall_speed_ref, 0.0, 1.0),
			clampf(v.y / fall_speed_ref, -1.0, 1.0)))
	anim_tree.set(P_DIVE, clampf(spd / dive_speed_ref, 0.0, 1.0))
	var side := 0.0
	if controller.state == TraversalController.State.WALL_RUN and not controller.wall_vertical:
		side = signf(controller.wall_normal.cross(Vector3.UP).dot(v))
	anim_tree.set(P_WALL_H, side)
	anim_tree.set(P_GLOAD, _g_load)
	anim_tree.set(P_LEAN, _lean)
	var w := controller.wings
	anim_tree.set(P_GLIDE, Vector2(-controller.move_input.y,
			w.bank / deg_to_rad(controller.tuning.glide_max_bank_deg)))
	anim_tree.set(P_SLING, controller.slingshot_charge)


func _on_web_fired(hand: int, anchor: Vector3) -> void:
	if anim_tree:
		if hand <= TraversalController.HAND_BOTH:
			anim_tree.set(P_FIRE_L, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		if hand >= TraversalController.HAND_BOTH:
			anim_tree.set(P_FIRE_R, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	var web := _pick_web()
	if web:
		web.fire(_socket(hand), anchor)
		_active_webs.append(web)


## Clic sin objetivo: el brazo lanza y la web sale hacia el vacío, sin enganchar.
func _on_web_missed(hand: int, tip: Vector3) -> void:
	if anim_tree:
		anim_tree.set(P_FIRE_R if hand >= TraversalController.HAND_BOTH else P_FIRE_L,
				AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	var web := _pick_web()
	if web:
		web.fire_miss(_socket(hand), tip)


## Usa una web libre; si no hay, recicla una que ya se está soltando.
func _pick_web() -> WebLine:
	var pool: Array[WebLine] = [web_line]
	if web_line_alt:
		pool.append(web_line_alt)
	pool.append_array(extra_web_lines)
	for w in pool:
		if w.phase == WebLine.Phase.HIDDEN:
			return w
	for w in pool:
		if w.phase == WebLine.Phase.RELEASED:
			return w
	return pool[0]


func _on_web_released(_hand: int, perfect: bool) -> void:
	for web in _active_webs:
		web.release()
	_active_webs.clear()
	if controller.last_release_chained:
		# Swing encadenado: el brazo ya busca la siguiente web.
		_one_shot_state = "Release_Reach"
		_one_shot_timer = reach_anim_time
		return
	var fast := controller.velocity.length() > aggressive_on_speed
	_one_shot_state = "Release_Flip" if (perfect or fast) else "Release_Neutral"
	_one_shot_timer = release_anim_time


func _on_landed(impact_speed: float) -> void:
	var horiz := RegulatedPendulum.flat(controller.velocity).length()
	if impact_speed > 30.0:
		_one_shot_state = "Land_Hero"          # aterrizaje de 3 apoyos
	elif horiz > 10.0:
		_one_shot_state = "Land_Roll"          # conserva la inercia horizontal
	else:
		_one_shot_state = "Land_Soft"
	_one_shot_timer = land_anim_time


func _on_trick() -> void:
	if anim_tree:
		anim_tree.set(P_TRICK, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func _socket(hand: int) -> Node3D:
	return hand_socket_left if hand == TraversalController.HAND_LEFT else hand_socket_right


# ---------------------------------------------------------------------------
# Orientación procedural del cuerpo
# ---------------------------------------------------------------------------
static func basis_from(forward: Vector3, up: Vector3) -> Basis:
	var y := up.normalized()
	var z := RegulatedPendulum.project_on_plane(forward, y)
	if z.length_squared() < 1e-6:
		z = RegulatedPendulum.project_on_plane(Vector3.FORWARD, y)
	z = z.normalized()
	var x := y.cross(z).normalized()
	z = x.cross(y).normalized()   # re-ortogonaliza (con up y forward casi paralelos z sale impreciso)
	return Basis(x, y, z)      # frente del modelo = +Z (convención glTF/Godot)


func _update_orientation(delta: float) -> void:
	if visual_root == null:
		return
	var c := controller
	var v := c.velocity
	var fwd := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(v), c.travel_dir)
	var up := Vector3.UP
	var rate := orient_rate_air
	match c.state:
		TraversalController.State.SWING:
			# El eje del cuerpo sigue la web visual (mano -> anclaje real).
			up = RegulatedPendulum.safe_normalized(c.pendulum.anchor - c.global_position, Vector3.UP)
			fwd = RegulatedPendulum.safe_normalized(v, fwd)
			# Se echa hacia delante como un dardo a mucha velocidad (cabeza en la dirección
			# del avance); casi parado, cuelga recto de la web.
			var ahead := RegulatedPendulum.project_on_plane(fwd, up)
			if ahead.length_squared() > 1e-4:
				var lean := lerpf(0.1, 0.95, smoothstep(6.0, 34.0, v.length()))
				up = (up + ahead.normalized() * lean).normalized()
			rate = orient_rate_swing
		TraversalController.State.DIVE:
			# Cabeza hacia la velocidad; pecho hacia el suelo.
			up = RegulatedPendulum.safe_normalized(v, Vector3.DOWN)
			fwd = RegulatedPendulum.project_on_plane(Vector3.DOWN, up)
			if fwd.length_squared() < 1e-4:
				fwd = c.travel_dir
		TraversalController.State.WALL_RUN:
			if c.wall_crawl:
				# Gateando: pegado a la fachada, cabeza arriba, pecho contra la pared.
				up = RegulatedPendulum.project_on_plane(Vector3.UP, c.wall_normal).normalized()
				fwd = -c.wall_normal
			elif c.wall_vertical:
				# Subiendo por la fachada: casi paralelo a ella (echado 17° hacia fuera),
				# de cara a la pared, pisándola.
				up = (Vector3.UP + c.wall_normal * 0.3).normalized()
				fwd = -c.wall_normal
			else:
				# Corriendo en horizontal: la pared es el "suelo" y el ciclo de carrera se rota.
				up = c.wall_normal
				fwd = RegulatedPendulum.safe_normalized(
						RegulatedPendulum.project_on_plane(v, c.wall_normal), fwd)
			rate = orient_rate_swing
		TraversalController.State.GLIDE:
			# Planeo: cabeza hacia la velocidad, pecho al suelo, alabeo con el viraje.
			up = RegulatedPendulum.safe_normalized(v, c.travel_dir)
			fwd = RegulatedPendulum.project_on_plane(Vector3.DOWN, up)
			if fwd.length_squared() < 1e-4:
				fwd = c.travel_dir
			fwd = fwd.normalized().rotated(up, -c.wings.bank)
			rate = 10.0
		TraversalController.State.SLINGSHOT:
			# Tensado: de cara al lanzamiento (el cuerpo se echa atrás en la postura,
			# con los pies plantados).
			fwd = c.slingshot_aim
			rate = 12.0
		TraversalController.State.FALL, TraversalController.State.WEB_ZIP:
			if c.dash_timer > 0.0:
				# Spider-Dash: en horizontal, cabeza hacia la velocidad y pecho abajo.
				up = RegulatedPendulum.safe_normalized(v, c.travel_dir)
				fwd = RegulatedPendulum.project_on_plane(Vector3.DOWN, up)
				if fwd.length_squared() < 1e-4:
					fwd = c.travel_dir
				rate = orient_rate_swing
			else:
				# Inclinación hacia la aceleración percibida y, al caer rápido, boca abajo
				# como un paracaidista (la postura AIR_FALL está pensada para eso).
				up = (Vector3.UP + RegulatedPendulum.flat(v) * 0.015).normalized()
				var prone := smoothstep(12.0, 32.0, -v.y) * 0.8
				if prone > 0.0 and c.state == TraversalController.State.FALL:
					var head := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(v), c.travel_dir)
					up = up.lerp(head, prone).normalized()
					fwd = fwd.lerp(Vector3.DOWN, prone)
	# Al entrar en un estado el cuerpo tarda un momento en reorientarse (sin latigazo).
	rate *= lerpf(0.4, 1.0, smoothstep(0.0, 0.3, c.state_time))
	var target := Quaternion(basis_from(fwd, up))
	var gt := visual_root.global_transform
	var current := Quaternion(gt.basis.orthonormalized())
	gt.basis = Basis(current.slerp(target, 1.0 - exp(-rate * delta)))
	visual_root.global_transform = gt
	# Desplazamiento visual en la pared: la cápsula queda a 0,4 m de la fachada;
	# corriendo, los pies deben tocarla (cadera a 0,9 m) y gateando, el pecho (0,2 m).
	var offset := Vector3.ZERO
	if c.state == TraversalController.State.WALL_RUN:
		if c.wall_crawl:
			offset = -c.wall_normal * 0.2
		elif not c.wall_vertical:
			offset = c.wall_normal * 0.5
	visual_root.position = visual_root.position.lerp(offset, 1.0 - exp(-12.0 * delta))


# ---------------------------------------------------------------------------
# IK: manos a la web, mano libre en swing agresivo, pies en la pared, mirada
# ---------------------------------------------------------------------------
func _update_ik(delta: float) -> void:
	var c := controller
	var k := 1.0 - exp(-10.0 * delta)
	var swinging := c.state == TraversalController.State.SWING
	var p := c.pendulum
	var tension_w := clampf(p.g_force / 1.5, 0.0, 1.0) if (swinging and p.taut) else 0.0
	_ik_weight = lerpf(_ik_weight, tension_w, k)
	_offhand_weight = lerpf(_offhand_weight, _aggr_blend * 0.8 if swinging else 0.0, k)

	var grip := hand_ik_right if c.hand == TraversalController.HAND_RIGHT else hand_ik_left
	var off_hand := hand_ik_left if grip == hand_ik_right else hand_ik_right
	if grip and grip.target:
		var shoulder := grip.chain_root_world()
		var web_dir := RegulatedPendulum.safe_normalized(p.anchor - shoulder, Vector3.UP)
		# Bajo tensión el brazo queda recto sobre la línea de la web.
		grip.target.global_position = shoulder + web_dir * grip.chain_length() * 0.98
		grip.influence = _ik_weight
		if off_hand and off_hand.target:
			off_hand.target.global_position = grip.target.global_position - web_dir * 0.28
			off_hand.influence = _offhand_weight

	var on_wall := c.state == TraversalController.State.WALL_RUN
	for foot in [foot_ik_left, foot_ik_right]:
		if foot == null or foot.target == null:
			continue
		var w := 0.0
		if on_wall:
			var hip := (foot as TwoBoneIKModifier).chain_root_world()
			var space := c.get_world_3d().direct_space_state
			var q := PhysicsRayQueryParameters3D.create(hip, hip - c.wall_normal * 1.6,
					c.collision_mask, [c.get_rid()])
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				foot.target.global_position = hit.position + c.wall_normal * 0.05
				w = 1.0
		foot.influence = lerpf(foot.influence, w, k)

	if look_at and look_at.target:
		look_at.target.global_position = _look_point()


## Anticipación: durante la subida del arco la cabeza ya busca el próximo anclaje.
func _look_point() -> Vector3:
	var c := controller
	var ahead := c.global_position + RegulatedPendulum.safe_normalized(c.velocity, c.travel_dir) * 8.0
	if c.anchor_finder == null:
		return ahead
	match c.state:
		TraversalController.State.SWING:
			if _phase < 0.2:
				return c.pendulum.anchor
		TraversalController.State.DIVE:
			return c.global_position + c.velocity * 0.8
	if c.aim_anchor:
		return c.aim_anchor.point            # la cabeza mira hacia donde apuntas la siguiente web
	var next := c.anchor_finder.best_for(float(-c.hand) if c.state == TraversalController.State.SWING
			else float(c.hand), c.global_position, c.velocity, c.travel_dir)
	return next.point if next else ahead
