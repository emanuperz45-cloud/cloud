class_name TraversalController
extends CharacterBody3D
## FSM del movimiento aéreo: swing, web zip, point launch, picada y wall run.
##
## update_swinging_system() es la función por frame de la sección 6 del
## documento de diseño. La física del balanceo vive en RegulatedPendulum; este
## nodo decide transiciones, mueve el cuerpo con colisiones y emite señales que
## consume TraversalAnimator. Acciones de InputMap esperadas: move_left,
## move_right, move_forward, move_back, swing, jump, web_zip, point_zip, dive, trick.

signal state_changed(previous: int, current: int)
signal web_fired(hand: int, anchor: Vector3)
signal web_released(hand: int, perfect: bool)
signal wall_run_started(vertical: bool)
signal landed(impact_speed: float)
signal point_launched(perfect: bool)
signal trick_started()

enum State { GROUNDED, FALL, DIVE, SWING, WEB_ZIP, POINT_ZIP, PERCH, WALL_RUN }

const HAND_LEFT := -1
const HAND_RIGHT := 1
const HAND_BOTH := 0

@export var tuning: SwingTuning
@export var anchor_finder: AnchorFinder
@export var camera: Camera3D
## Origen de la web respecto al centro del cuerpo (aprox. la mano en pose de disparo).
@export var hand_offset := Vector3(0.0, 0.8, 0.0)
@export var probe_radius := 0.5

var state: State = State.FALL
var state_time := 0.0
var pendulum: RegulatedPendulum
var travel_dir := Vector3.FORWARD
var hand := HAND_RIGHT
var last_release_perfect := false
var wall_normal := Vector3.ZERO
var wall_vertical := false
var trick_timer := 0.0
var move_input := Vector2.ZERO
var cam_forward := Vector3.FORWARD
var cam_right := Vector3.RIGHT

var _zip_cooldown := 0.0
var _predict_timer := 0.0
var _avoid := Vector3.ZERO
var _perch_target := Vector3.ZERO
var _jump_buffer := 0.0
var _wall_run_speed := 0.0
var _probe_shape := SphereShape3D.new()


func _ready() -> void:
	if tuning == null:
		tuning = SwingTuning.new()
	pendulum = RegulatedPendulum.new(tuning)
	_probe_shape.radius = probe_radius
	if anchor_finder:
		if anchor_finder.tuning == null:
			anchor_finder.tuning = tuning
		anchor_finder.exclude = [get_rid()]


func _physics_process(delta: float) -> void:
	update_swinging_system(delta)


# ---------------------------------------------------------------------------
# Bucle principal (sección 6 del documento)
# ---------------------------------------------------------------------------
func update_swinging_system(delta: float) -> void:
	state_time += delta
	_zip_cooldown = maxf(_zip_cooldown - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	trick_timer = maxf(trick_timer - delta, 0.0)
	_read_input()
	_update_travel_dir(delta)
	if anchor_finder:
		anchor_finder.scan(global_position, velocity, travel_dir, delta)

	match state:
		State.GROUNDED:
			_update_grounded(delta)
		State.FALL, State.DIVE:
			_update_air(delta)
		State.SWING:
			_update_swing(delta)
		State.WEB_ZIP:
			_update_zip(delta)
		State.POINT_ZIP:
			_update_point_zip(delta)
		State.PERCH:
			_update_perch()
		State.WALL_RUN:
			_update_wall_run(delta)


func _read_input() -> void:
	move_input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if camera:
		var b := camera.global_transform.basis
		cam_forward = RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(-b.z), Vector3.FORWARD)
		cam_right = RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(b.x), Vector3.RIGHT)
	if Input.is_action_just_pressed("jump"):
		_jump_buffer = 0.15


func _wish_dir() -> Vector3:
	return cam_forward * -move_input.y + cam_right * move_input.x


func _update_travel_dir(delta: float) -> void:
	var target := Vector3.ZERO
	var wish := _wish_dir()
	var flat_v := RegulatedPendulum.flat(velocity)
	if wish.length_squared() > 0.04:
		target = wish.normalized()
	elif flat_v.length() > 2.0:
		target = flat_v.normalized()
	else:
		return
	travel_dir = travel_dir.slerp(target, 1.0 - exp(-4.0 * delta)).normalized()


func _set_state(next: State) -> void:
	var prev := state
	state = next
	state_time = 0.0
	state_changed.emit(prev, next)


# ---------------------------------------------------------------------------
# Suelo (mínimo: la locomoción terrestre queda fuera del alcance)
# ---------------------------------------------------------------------------
func _update_grounded(delta: float) -> void:
	var wish := _wish_dir() * 9.0
	velocity.x = move_toward(velocity.x, wish.x, 40.0 * delta)
	velocity.z = move_toward(velocity.z, wish.z, 40.0 * delta)
	velocity.y -= tuning.g * delta
	move_and_slide()
	if _jump_buffer > 0.0:
		_jump_buffer = 0.0
		velocity.y = 9.0
		_set_state(State.FALL)
	elif not is_on_floor():
		_set_state(State.FALL)


# ---------------------------------------------------------------------------
# Caída libre / picada
# ---------------------------------------------------------------------------
func _air_accel(v: Vector3, dive: bool, zip: bool, control: Vector3) -> Vector3:
	var g_scale := tuning.gravity_scale_fall
	if zip:
		g_scale = tuning.gravity_scale_zip
	elif dive:
		g_scale = tuning.gravity_scale_dive
	var k := tuning.dive_drag if dive else tuning.fall_drag
	var a := Vector3(0.0, -tuning.g * g_scale, 0.0)
	a.y -= k * absf(v.y) * v.y                    # arrastre cuadrático vertical
	a -= RegulatedPendulum.flat(v) * tuning.air_horizontal_damping
	a += RegulatedPendulum.flat(control) * tuning.air_control_accel
	if dive:
		a += travel_dir * tuning.dive_forward_accel
	return a


func _update_air(delta: float) -> void:
	var dive := state == State.DIVE
	velocity += _air_accel(velocity, dive, false, _wish_dir()) * delta
	move_and_slide()

	if is_on_floor():
		_land()
		return
	if _try_wall_contact():
		return
	if Input.is_action_just_pressed("trick") and not dive:
		trick_timer = 0.6
		trick_started.emit()
	if Input.is_action_pressed("dive") and not dive and velocity.y < 0.0:
		_set_state(State.DIVE)
	elif dive and not Input.is_action_pressed("dive"):
		_set_state(State.FALL)
	if Input.is_action_just_pressed("web_zip") and _zip_cooldown <= 0.0:
		_start_zip()
		return
	if Input.is_action_just_pressed("point_zip") and _start_point_zip():
		return
	# Gatillo pulsado = disparo inmediato; mantenido = encadenado automático.
	var want := Input.is_action_just_pressed("swing") \
			or (Input.is_action_pressed("swing") and state_time > tuning.reattach_delay)
	if want:
		_try_attach()


func _land() -> void:
	landed.emit(-velocity.y)
	_set_state(State.GROUNDED)


# ---------------------------------------------------------------------------
# Balanceo
# ---------------------------------------------------------------------------
func _try_attach() -> bool:
	if anchor_finder == null:
		return false
	var cand := anchor_finder.best_for(float(hand), global_position, velocity, travel_dir)
	if cand == null:
		cand = anchor_finder.best_for(float(-hand), global_position, velocity, travel_dir)
		if cand == null:
			return false             # sin geometría válida: no hay swing (nada de anclajes en el aire)
		hand = -hand
	if not anchor_finder.validate(cand, global_position + hand_offset):
		return false
	pendulum.attach(global_position, velocity, cand.point, travel_dir, cand.ground_y,
			anchor_finder.cruise_y())
	_predict_timer = 0.0
	_avoid = Vector3.ZERO
	_set_state(State.SWING)
	web_fired.emit(hand, cand.point)
	return true


func _update_swing(delta: float) -> void:
	_predict_timer -= delta
	if _predict_timer <= 0.0:
		_predict_timer = tuning.predict_interval
		_avoid = _predict_avoidance()

	var hold := Input.is_action_pressed("swing")
	var steps := maxi(1, ceili(delta / tuning.substep))
	var h := delta / steps
	for i in steps:
		pendulum.step(h, move_input.x, cam_right, hold, _avoid)

	# El solver propone; move_and_slide dispone (colisiones reales del mundo).
	velocity = (pendulum.pos - global_position) / delta
	move_and_slide()
	if get_slide_collision_count() > 0:
		var n := get_slide_collision(0).get_normal()
		if _enter_wall_run(n, pendulum.vel):
			return
		pendulum.pos = global_position
		pendulum.vel = RegulatedPendulum.project_on_plane(pendulum.vel, n)
	velocity = pendulum.vel

	if _jump_buffer > 0.0:
		_jump_buffer = 0.0
		_release(true)
	elif Input.is_action_just_released("swing"):
		_release(false)
	elif hold and pendulum.swing_angle_deg >= tuning.chain_release_angle_deg:
		_release(false)              # encadenado: suelta sola y re-dispara en FALL
	elif pendulum.should_auto_release():
		_release(false)
	elif is_on_floor():
		pendulum.active = false
		web_released.emit(hand, false)
		_land()


func _release(swing_jump: bool) -> void:
	var v := pendulum.release()
	last_release_perfect = pendulum.last_release_perfect
	if swing_jump:
		var bonus := tuning.release_perfect_bonus if last_release_perfect else 0.0
		v += Vector3.UP * tuning.swing_jump_up * (1.0 + bonus)
	velocity = v
	web_released.emit(hand, last_release_perfect)
	hand = -hand                     # alterna manos como en el original
	_set_state(State.FALL)


## Predicción del arco: simula el péndulo ~1 s hacia delante y barre una esfera
## entre muestras. Devuelve una aceleración lateral de evitación (o cero).
func _predict_avoidance() -> Vector3:
	var sim := pendulum.duplicate_state()
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _probe_shape
	params.collision_mask = collision_mask
	params.exclude = [get_rid()]
	var h := 1.0 / 30.0
	var steps := int(tuning.predict_horizon / h)
	var prev := sim.pos
	for i in steps:
		sim.step(h, move_input.x, cam_right, true)
		var motion := sim.pos - prev
		params.transform = Transform3D(Basis.IDENTITY, prev)
		params.motion = motion
		var frac := space.cast_motion(params)
		if frac.size() == 2 and frac[1] < 1.0:
			var t_hit := (i + frac[1]) * h
			var ray := PhysicsRayQueryParameters3D.create(
					prev, prev + motion * 1.5 + motion.normalized() * probe_radius,
					collision_mask, [get_rid()])
			var hit := space.intersect_ray(ray)
			if hit.is_empty():
				return Vector3.ZERO
			return _avoidance_from_hit(hit.normal, hit.position, t_hit)
		prev = sim.pos
	return Vector3.ZERO


func _avoidance_from_hit(n: Vector3, point: Vector3, t_hit: float) -> Vector3:
	var urgency := 1.0 - clampf(t_hit / tuning.predict_horizon, 0.0, 1.0)
	if n.y > 0.6:
		# Suelo o tejado bajo el arco: el regulador de longitud recoge cuerda.
		pendulum.ground_y = maxf(pendulum.ground_y, point.y)
		return Vector3.ZERO
	var frontal := -n.dot(pendulum.vel.normalized())
	if frontal > 0.8 and t_hit < 0.35:
		return Vector3.ZERO          # impacto frontal inminente: se convertirá en wall run
	return RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(n), Vector3.ZERO) \
			* tuning.avoid_accel * urgency


# ---------------------------------------------------------------------------
# Web zip / point launch
# ---------------------------------------------------------------------------
func _start_zip() -> void:
	var aim := cam_forward
	# La web del zip también necesita geometría real; sin ella es un "dash" débil.
	var space := get_world_3d().direct_space_state
	var from := global_position + hand_offset
	var to := from + (aim + Vector3.UP * 0.25).normalized() * 45.0
	var mask := anchor_finder.swingable_mask if anchor_finder else collision_mask
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, [get_rid()])
	var hit := space.intersect_ray(q)
	var strength := 1.0 if not hit.is_empty() else 0.6
	var along := maxf(velocity.dot(aim), tuning.zip_speed * strength)
	var lateral := RegulatedPendulum.project_on_plane(RegulatedPendulum.flat(velocity), aim) * 0.3
	velocity = aim * along + lateral + Vector3.UP * maxf(velocity.y * 0.2, tuning.zip_up_speed)
	_zip_cooldown = tuning.zip_cooldown
	_set_state(State.WEB_ZIP)
	if not hit.is_empty():
		web_fired.emit(HAND_BOTH, hit.position)


func _update_zip(delta: float) -> void:
	velocity += _air_accel(velocity, false, true, _wish_dir()) * delta
	move_and_slide()
	if _try_wall_contact():
		return
	if state_time >= tuning.zip_duration:
		web_released.emit(HAND_BOTH, false)
		_set_state(State.FALL)


func _start_point_zip() -> bool:
	if anchor_finder == null or camera == null:
		return false
	var aim := -camera.global_transform.basis.z
	var target: Variant = anchor_finder.find_perch(global_position, aim, 45.0)
	if target == null:
		return false
	_perch_target = target
	_set_state(State.POINT_ZIP)
	web_fired.emit(HAND_BOTH, _perch_target)
	return true


func _update_point_zip(delta: float) -> void:
	var to := _perch_target - global_position
	var dist := to.length()
	var spd := tuning.point_zip_speed * smoothstep(0.0, 0.12, state_time + delta)
	if dist <= spd * delta or dist < 0.3:
		global_position = _perch_target
		velocity = Vector3.ZERO
		web_released.emit(HAND_BOTH, false)
		_set_state(State.PERCH)
		return
	velocity = to / dist * spd
	move_and_slide()


func _update_perch() -> void:
	velocity = Vector3.ZERO
	# El buffer de salto (0.15 s) cuenta pulsaciones hechas justo antes de llegar.
	if _jump_buffer > 0.0:
		_jump_buffer = 0.0
		var perfect := state_time <= tuning.point_launch_window
		var m := tuning.point_launch_perfect_mult if perfect else 1.0
		velocity = travel_dir * tuning.point_launch_forward * m + Vector3.UP * tuning.point_launch_up * m
		point_launched.emit(perfect)
		_set_state(State.FALL)
	elif Input.is_action_just_pressed("swing"):
		velocity = travel_dir * 6.0 + Vector3.UP * 4.0
		_set_state(State.FALL)
		_try_attach()


# ---------------------------------------------------------------------------
# Wall run
# ---------------------------------------------------------------------------
func _try_wall_contact() -> bool:
	for i in get_slide_collision_count():
		if _enter_wall_run(get_slide_collision(i).get_normal(), velocity):
			return true
	return false


func _enter_wall_run(n: Vector3, v: Vector3) -> bool:
	if absf(n.y) > 0.3:
		return false                 # no es una pared
	var spd := v.length()
	if spd < tuning.wall_run_min_speed * 0.5:
		return false
	var approach := rad_to_deg(acos(clampf(-v.dot(n) / spd, -1.0, 1.0)))   # 0 = de frente
	var was_swinging := state == State.SWING
	wall_normal = n
	wall_vertical = approach < tuning.wall_run_vertical_angle_deg
	if wall_vertical:
		_wall_run_speed = maxf(spd * tuning.wall_run_speed_retention, tuning.wall_run_min_speed)
		velocity = Vector3.UP * _wall_run_speed
	else:
		var tangent := RegulatedPendulum.flat(RegulatedPendulum.project_on_plane(v, n)).normalized()
		_wall_run_speed = maxf(RegulatedPendulum.flat(v).dot(tangent) * tuning.wall_run_speed_retention,
				tuning.wall_run_min_speed)
		velocity = tangent * _wall_run_speed + Vector3.UP * maxf(v.y, 0.0) * 0.5
	if was_swinging:
		pendulum.active = false
		web_released.emit(hand, false)
	_set_state(State.WALL_RUN)
	wall_run_started.emit(wall_vertical)
	return true


func _update_wall_run(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var body_ray := PhysicsRayQueryParameters3D.create(
			global_position, global_position - wall_normal * 1.5, collision_mask, [get_rid()])
	var body_hit := space.intersect_ray(body_ray)
	if body_hit.is_empty():
		_set_state(State.FALL)       # perdió la pared (esquina exterior o borde lateral)
		return
	wall_normal = body_hit.normal

	var g_wall := tuning.g * tuning.wall_run_gravity_scale
	if wall_vertical:
		_wall_run_speed -= g_wall * delta
		velocity = Vector3.UP * _wall_run_speed - wall_normal * 2.0
		# Cornisa: el pecho ya no ve pared -> vault sobre la azotea.
		var chest := global_position + Vector3.UP * 1.2
		var chest_ray := PhysicsRayQueryParameters3D.create(
				chest, chest - wall_normal * 1.5, collision_mask, [get_rid()])
		if space.intersect_ray(chest_ray).is_empty():
			velocity = Vector3.UP * 7.0 - wall_normal * 5.0
			_set_state(State.FALL)
			return
		if _wall_run_speed < 2.0:
			velocity = wall_normal * 3.0
			_set_state(State.FALL)
			return
	else:
		var tangent := RegulatedPendulum.flat(RegulatedPendulum.project_on_plane(velocity, wall_normal))
		tangent = RegulatedPendulum.safe_normalized(tangent, wall_normal.cross(Vector3.UP))
		var vy := velocity.y - g_wall * delta
		velocity = tangent * _wall_run_speed + Vector3.UP * vy \
				- wall_normal * tuning.wall_run_stick_accel * delta
	move_and_slide()

	if _jump_buffer > 0.0:
		_jump_buffer = 0.0
		var along := RegulatedPendulum.flat(velocity) * 0.6
		velocity = wall_normal * tuning.wall_jump_out + Vector3.UP * tuning.wall_jump_up + along
		_set_state(State.FALL)
	elif Input.is_action_just_pressed("swing"):
		velocity += wall_normal * 4.0
		_set_state(State.FALL)
		_try_attach()
	elif state_time > tuning.wall_run_max_time:
		_set_state(State.FALL)
	elif is_on_floor():
		_land()
