class_name TraversalController
extends CharacterBody3D
## FSM del movimiento: swing, web zip, point launch, picada, pared y suelo, con
## el moveset del original (Marvel's Spider-Man, 2018) adaptado a teclado/mando.
##
## update_swinging_system() es la función por frame de la sección 6 del
## documento de diseño. La física del balanceo vive en RegulatedPendulum; este
## nodo decide transiciones, mueve el cuerpo con colisiones y emite señales que
## consumen el animador y el HUD. Acciones de InputMap: move_left, move_right,
## move_forward, move_back, swing, jump, web_zip, point_zip, dive, trick.
##
## Gatillo de balanceo (swing):
##  - en el aire: pulsar dispara; MANTENER = misma telaraña (péndulo), el arco se
##    amortigua hasta quedar colgado; W/S suben o bajan por la telaraña; soltar suelta.
##  - en el suelo: sprint/parkour (contra una fachada, sube corriendo); saltando
##    con el clic mantenido se dispara la telaraña en el aire.
##  - en una pared: mantener = correr por la pared; sin él, trepar (wall crawl).
## Salto (jump): en el swing lanza según la fase (fondo = adelante, final = arriba);
## en el aire es Web Zip (el segundo seguido es Quick Zip, sin perder altura); en el
## suelo, mantener carga el Charge Jump; justo al rodar tras aterrizar, Quick Recovery;
## al llegar a un perch, Point Launch; en la pared, tirón de telaraña hacia arriba
## (corriendo en vertical) o salto de pared.
## Picada (dive): en el aire, picada; corriendo por una pared hacia una esquina,
## web a la esquina para girarla sin perder velocidad.
## Truco (trick) + dirección: voltereta adelante/atrás, tirabuzón izq./der. o giro.
## Web Wings (glide) en el aire: planeo; stick adelante pica, atrás encabrita, a los
## lados alabea. Abrirlas en picada da un impulso. Túneles de viento y corrientes
## ascendentes (WindField) aceleran y elevan.
## Super Slingshot: mantener point_zip y pulsar salto tensa dos webs por delante;
## soltar el salto lanza. Truco mantenido en un swing rápido recoge cuerda y el arco
## da la vuelta completa (loop de loop).

signal state_changed(previous: int, current: int)
signal web_fired(hand: int, anchor: Vector3)
signal web_released(hand: int, perfect: bool)
signal wall_run_started(vertical: bool)
signal landed(impact_speed: float)
signal point_launched(perfect: bool)
signal trick_started()
signal jumped(charge: float)
signal quick_recovered()
signal corner_turned(launched: bool)
signal looped(count: int)
signal wings_opened(boosted: bool)
signal wings_closed()
signal slingshot_launched(charge: float)

enum State { GROUNDED, FALL, DIVE, SWING, WEB_ZIP, POINT_ZIP, PERCH, WALL_RUN, GLIDE, SLINGSHOT }
enum Trick { SPIN, FRONT_FLIP, BACK_FLIP, ROLL_LEFT, ROLL_RIGHT }

const HAND_LEFT := -1
const HAND_RIGHT := 1
const HAND_BOTH := 0
const TRICK_TIME := 0.6

@export var tuning: SwingTuning
@export var anchor_finder: AnchorFinder
## Corrientes de aire para el planeo (túneles y columnas ascendentes). Opcional.
var wind_field: WindField
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
var last_release_chained := false
var wall_normal := Vector3.ZERO
var wall_vertical := false
var wall_crawl := false           ## en la pared sin gatillo: trepando
var trick_timer := 0.0
var trick_index: Trick = Trick.SPIN
var jump_charge := 0.0            ## 0..1 mientras se carga el Charge Jump
var land_kind := ""               ## "soft" | "roll" | "hero"
var land_timer := 0.0
var sprinting := false
var wings: WebWings
var in_tunnel := 0.0              ## 0..1 dentro de un túnel de viento (planeo)
var in_updraft := 0.0             ## 0..1 dentro de una corriente ascendente
var slingshot_charge := 0.0       ## 0..1 tensando el Super Slingshot
var slingshot_aim := Vector3.FORWARD
var slingshot_anchors: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]   ## [izquierda, derecha]
## Lo pone la cámara: el jugador la está moviendo (planeando = timón hacia donde mira).
var camera_steer_active := false
var move_input := Vector2.ZERO
var cam_forward := Vector3.FORWARD
var cam_right := Vector3.RIGHT

var _zip_cooldown := 0.0
var _last_zip_time := -10.0
var _clock := 0.0
var _predict_timer := 0.0
var _avoid := Vector3.ZERO
var _perch_target := Vector3.ZERO
var _point_zip_timeout := 0.0
var _jump_buffer := 0.0
var _dive_buffer := 0.0
var _charging := false
var _wall_run_speed := 0.0
var _web_pull_timer := 0.0
var _wall_cooldown := 0.0         ## tras dejar una pared, no volver a pegarse al instante
var _last_loops := 0
var _sling_origin := Vector3.ZERO
var _sling_prev_state: State = State.GROUNDED
var _pz_hold := -1.0              ## en el suelo: point_zip mantenido (¿zip o slingshot?)
var _probe_shape := SphereShape3D.new()


func _ready() -> void:
	if tuning == null:
		tuning = SwingTuning.new()
	pendulum = RegulatedPendulum.new(tuning)
	wings = WebWings.new(tuning)
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
	_clock += delta
	state_time += delta
	_zip_cooldown = maxf(_zip_cooldown - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_dive_buffer = maxf(_dive_buffer - delta, 0.0)
	trick_timer = maxf(trick_timer - delta, 0.0)
	land_timer = maxf(land_timer - delta, 0.0)
	_wall_cooldown = maxf(_wall_cooldown - delta, 0.0)
	if _web_pull_timer > 0.0:
		_web_pull_timer -= delta
		if _web_pull_timer <= 0.0:
			web_released.emit(HAND_BOTH, false)
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
			_update_wall(delta)
		State.GLIDE:
			_update_glide(delta)
		State.SLINGSHOT:
			_update_slingshot(delta)


func _read_input() -> void:
	move_input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if camera:
		var b := camera.global_transform.basis
		cam_forward = RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(-b.z), Vector3.FORWARD)
		cam_right = RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(b.x), Vector3.RIGHT)
	if Input.is_action_just_pressed("jump"):
		_jump_buffer = 0.15
	if Input.is_action_just_pressed("dive"):
		_dive_buffer = tuning.corner_turn_buffer


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
	# Giro en el plano horizontal (slerp de Vector3 pierde precisión con vectores casi
	# paralelos y falla con opuestos).
	var ang := travel_dir.signed_angle_to(target, Vector3.UP)
	travel_dir = RegulatedPendulum.safe_normalized(
			RegulatedPendulum.flat(travel_dir.rotated(Vector3.UP, ang * (1.0 - exp(-4.0 * delta)))),
			target)


func _set_state(next: State) -> void:
	var prev := state
	state = next
	state_time = 0.0
	if prev == State.WALL_RUN and next != State.WALL_RUN:
		_wall_cooldown = 0.25
	if next != State.WALL_RUN:
		wall_crawl = false
	if next != State.GROUNDED:
		_charging = false
		jump_charge = 0.0
		sprinting = false
	if prev == State.GLIDE and next != State.GLIDE:
		in_tunnel = 0.0
		in_updraft = 0.0
		wings_closed.emit()
	state_changed.emit(prev, next)


# ---------------------------------------------------------------------------
# Suelo: carrera/sprint, salto, Charge Jump y Quick Recovery
# ---------------------------------------------------------------------------
func _update_grounded(delta: float) -> void:
	var swing_held := Input.is_action_pressed("swing")
	sprinting = swing_held and move_input.length() > 0.2
	var top := tuning.sprint_speed if sprinting else tuning.run_speed
	var wish := _wish_dir() * top
	var accel := 40.0 if land_timer <= 0.0 or land_kind != "hero" else 8.0
	velocity.x = move_toward(velocity.x, wish.x, accel * delta)
	velocity.z = move_toward(velocity.z, wish.z, accel * delta)
	velocity.y -= tuning.g * delta
	move_and_slide()

	# Quick Recovery: salto durante la rodada del aterrizaje -> de vuelta al aire.
	if land_kind == "roll" and land_timer > 0.0 and _jump_buffer > 0.0:
		_jump_buffer = 0.0
		var fwd := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(velocity), travel_dir)
		velocity = fwd * maxf(RegulatedPendulum.flat(velocity).length(), 12.0) \
				+ Vector3.UP * tuning.quick_recovery_up
		quick_recovered.emit()
		_set_state(State.FALL)
		return
	if _ground_point_zip_or_slingshot(delta):
		return
	# Charge Jump: mantener salto carga, soltar salta (un toque = salto normal).
	if Input.is_action_just_pressed("jump"):
		_charging = true
		_jump_buffer = 0.0
	if _charging:
		jump_charge = minf(jump_charge + delta / tuning.charge_jump_time, 1.0)
		if not Input.is_action_pressed("jump"):
			var c := jump_charge
			velocity.y = lerpf(tuning.jump_speed, tuning.charge_jump_speed, c * c)
			velocity += RegulatedPendulum.flat(velocity).normalized() * c * 4.0
			jumped.emit(c)
			_set_state(State.FALL)
			return
	if swing_held and _try_wall_contact():
		return
	if not is_on_floor():
		_set_state(State.FALL)


# ---------------------------------------------------------------------------
# Aire: caída, picada, trucos, web zip / quick zip y disparo de telaraña
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
	if Input.is_action_just_pressed("trick") and not dive and trick_timer <= 0.0:
		_start_trick()
	if Input.is_action_pressed("dive") and not dive and velocity.y < 0.0:
		_set_state(State.DIVE)
	elif dive and not Input.is_action_pressed("dive"):
		_set_state(State.FALL)
	if Input.is_action_just_pressed("glide"):
		_start_glide(dive or velocity.y < -25.0)     # abrirlas cayendo rápido = impulso
		return
	# Salto en el aire = Web Zip (como X en el original); también su botón propio.
	var zip_pressed := Input.is_action_just_pressed("web_zip") or _jump_buffer > 0.0
	if zip_pressed and _zip_cooldown <= 0.0:
		_jump_buffer = 0.0
		_start_zip()
		return
	if Input.is_action_just_pressed("point_zip") and _start_point_zip():
		return
	var want := Input.is_action_just_pressed("swing") \
			or (Input.is_action_pressed("swing") and state_time > tuning.reattach_delay)
	if want:
		_try_attach()


func _start_trick() -> void:
	if move_input.y < -0.5:
		trick_index = Trick.FRONT_FLIP
	elif move_input.y > 0.5:
		trick_index = Trick.BACK_FLIP
	elif move_input.x < -0.5:
		trick_index = Trick.ROLL_LEFT
	elif move_input.x > 0.5:
		trick_index = Trick.ROLL_RIGHT
	else:
		trick_index = Trick.SPIN
	trick_timer = TRICK_TIME
	trick_started.emit()


func _land() -> void:
	var impact := -velocity.y
	var horiz := RegulatedPendulum.flat(velocity).length()
	if impact > 25.0:
		land_kind = "hero"              # aterrizaje de superhéroe: frena
		land_timer = 0.7
		velocity *= 0.2
	elif horiz > 8.0:
		land_kind = "roll"              # rodada: conserva inercia; salto = Quick Recovery
		land_timer = tuning.quick_recovery_window
	else:
		land_kind = "soft"
		land_timer = 0.25
	landed.emit(impact)
	_set_state(State.GROUNDED)


# ---------------------------------------------------------------------------
# Balanceo: mantener = misma telaraña (péndulo que se apaga hasta quedar colgado)
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
	_last_loops = 0
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
	var reel := -move_input.y            # W = subir por la telaraña (solo colgado)
	var tighten := Input.is_action_pressed("trick")   # cerrar el arco -> loop
	var steps := maxi(1, ceili(delta / tuning.substep))
	var h := delta / steps
	for i in steps:
		pendulum.step(h, move_input.x, cam_right, hold, _avoid, reel, tighten)
	if pendulum.loops > _last_loops:
		_last_loops = pendulum.loops
		looped.emit(_last_loops)

	# El solver propone; move_and_slide dispone (colisiones reales del mundo).
	velocity = (pendulum.pos - global_position) / delta
	move_and_slide()
	if get_slide_collision_count() > 0:
		var n := get_slide_collision(0).get_normal()
		if _enter_wall(n, pendulum.vel, true):
			return
		pendulum.pos = global_position
		pendulum.vel = RegulatedPendulum.project_on_plane(pendulum.vel, n)
	velocity = pendulum.vel

	# Sin suelta automática: solo el jugador (o chocar/aterrizar) suelta la telaraña.
	if Input.is_action_just_pressed("glide"):
		_release(false)
		_start_glide(false)
	elif _jump_buffer > 0.0:
		_jump_buffer = 0.0
		_release(true)
	elif not hold:
		_release(false)
	elif is_on_floor():
		pendulum.active = false
		web_released.emit(hand, false)
		_land()


func _release(swing_jump: bool) -> void:
	var ang := pendulum.swing_angle_deg
	var hanging := pendulum.sustain and pendulum.speed < 4.0
	var v := pendulum.release()
	last_release_perfect = pendulum.last_release_perfect
	last_release_chained = false
	if swing_jump:
		var bonus := 1.0 + (tuning.release_perfect_bonus if last_release_perfect else 0.0)
		if hanging:
			v += Vector3.UP * tuning.hang_jump_up + travel_dir * 3.0
		else:
			# Como en el original: saltar en el fondo del arco lanza hacia delante,
			# al final del arco catapulta hacia arriba.
			var t := smoothstep(5.0, 45.0, ang)
			var fwd := RegulatedPendulum.safe_normalized(RegulatedPendulum.flat(v), travel_dir)
			v += fwd * lerpf(tuning.swing_jump_forward, 2.0, t) * bonus \
					+ Vector3.UP * lerpf(3.0, tuning.swing_jump_up, t) * bonus
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
# Web zip / Quick Zip / point launch
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
	var up := maxf(velocity.y * 0.2, tuning.zip_up_speed)
	if _clock - _last_zip_time < tuning.quick_zip_window:
		up = maxf(up, maxf(velocity.y, 0.0) + tuning.zip_up_speed)   # Quick Zip: no pierde altura
	velocity = aim * along + lateral + Vector3.UP * up
	_zip_cooldown = tuning.zip_cooldown
	_last_zip_time = _clock
	_set_state(State.WEB_ZIP)
	if not hit.is_empty():
		web_fired.emit(HAND_BOTH, hit.position)


func _update_zip(delta: float) -> void:
	velocity += _air_accel(velocity, false, true, _wish_dir()) * delta
	move_and_slide()
	if _try_wall_contact():
		return
	if Input.is_action_just_pressed("glide"):
		web_released.emit(HAND_BOTH, false)
		_start_glide(false)
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
	_point_zip_timeout = global_position.distance_to(_perch_target) / tuning.point_zip_speed + 0.6
	_set_state(State.POINT_ZIP)
	web_fired.emit(HAND_BOTH, _perch_target)
	return true


func _update_point_zip(delta: float) -> void:
	var to := _perch_target - global_position
	var dist := to.length()
	var spd := tuning.point_zip_speed * smoothstep(0.0, 0.12, state_time + delta)
	if dist <= spd * delta or dist < 0.3 or state_time > _point_zip_timeout:
		global_position = _perch_target
		velocity = Vector3.ZERO
		web_released.emit(HAND_BOTH, false)
		_set_state(State.PERCH)
		return
	# Trayectoria guiada por la web: no se detiene en aristas de cornisas.
	velocity = to / dist * spd
	global_position += velocity * delta


func _update_perch() -> void:
	velocity = Vector3.ZERO
	if Input.is_action_pressed("point_zip") and Input.is_action_just_pressed("jump"):
		_jump_buffer = 0.0
		_start_slingshot()
		return
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
	elif move_input.length() > 0.5:
		_set_state(State.GROUNDED)    # bajarse del posado caminando


# ---------------------------------------------------------------------------
# Pared: wall run con el gatillo, wall crawl sin él, esquinas y tirón de web
# ---------------------------------------------------------------------------
func _try_wall_contact() -> bool:
	if _wall_cooldown > 0.0:
		return false
	for i in get_slide_collision_count():
		if _enter_wall(get_slide_collision(i).get_normal(), velocity, false):
			return true
	return false


func _enter_wall(n: Vector3, v: Vector3, from_swing: bool) -> bool:
	if absf(n.y) > 0.3:
		return false                 # no es una pared
	var spd := v.length()
	var run := Input.is_action_pressed("swing") and spd >= tuning.wall_run_min_speed * 0.5
	if from_swing and (not run or pendulum.sustain):
		return false                 # péndulo sostenido: roza la pared sin soltar la telaraña
	var approach := rad_to_deg(acos(clampf(-v.dot(n) / maxf(spd, 0.001), -1.0, 1.0)))
	wall_normal = n
	wall_vertical = approach < tuning.wall_run_vertical_angle_deg
	if run:
		if wall_vertical:
			_wall_run_speed = maxf(spd * tuning.wall_run_speed_retention, tuning.wall_run_min_speed)
			velocity = Vector3.UP * _wall_run_speed
		else:
			var tangent := RegulatedPendulum.flat(RegulatedPendulum.project_on_plane(v, n)).normalized()
			_wall_run_speed = maxf(RegulatedPendulum.flat(v).dot(tangent) * tuning.wall_run_speed_retention,
					tuning.wall_run_min_speed)
			velocity = tangent * _wall_run_speed + Vector3.UP * maxf(v.y, 0.0) * 0.5
	else:
		velocity = Vector3.ZERO        # se pega a la pared (wall crawl)
	if state == State.SWING:
		pendulum.active = false
		web_released.emit(hand, false)
	elif state == State.WEB_ZIP:
		web_released.emit(HAND_BOTH, false)   # la web del zip no puede quedarse colgando
	_set_state(State.WALL_RUN)
	wall_crawl = not run
	wall_run_started.emit(wall_vertical and run)
	return true


func _wall_ray(from: Vector3, n: Vector3, length := 1.5) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from - n * length, collision_mask, [get_rid()])
	return space.intersect_ray(q)


func _update_wall(delta: float) -> void:
	var held := Input.is_action_pressed("swing")
	var body_hit := _wall_ray(global_position, wall_normal)
	if body_hit.is_empty():
		_leave_wall_at_corner()
		return
	wall_normal = body_hit.normal

	# Cornisa: el pecho ya no ve pared al subir -> vault sobre la azotea.
	var going_up := velocity.y > 0.5
	if going_up and _wall_ray(global_position + Vector3.UP * 1.2, wall_normal).is_empty():
		_vault()
		return

	var up_on_wall := RegulatedPendulum.project_on_plane(Vector3.UP, wall_normal).normalized()
	var side_on_wall := RegulatedPendulum.safe_normalized(
			RegulatedPendulum.project_on_plane(cam_right, wall_normal), wall_normal.cross(Vector3.UP))

	if held and wall_crawl:
		# Del gateo a la carrera: hacia donde apunte el stick (arriba por defecto).
		wall_crawl = false
		wall_vertical = absf(move_input.x) < 0.5
		_wall_run_speed = tuning.wall_run_min_speed
		velocity = side_on_wall * signf(move_input.x) * _wall_run_speed if not wall_vertical \
				else up_on_wall * _wall_run_speed
	elif not held and not wall_crawl:
		wall_crawl = true            # soltar el gatillo en la pared = trepar

	if wall_crawl:
		var dir := up_on_wall * -move_input.y + side_on_wall * move_input.x
		velocity = dir * tuning.wall_crawl_speed - wall_normal * 1.0
	elif wall_vertical:
		# Mantener el gatillo sostiene la carrera vertical (decae hasta el mínimo).
		_wall_run_speed = maxf(_wall_run_speed - tuning.g * tuning.wall_run_gravity_scale * delta,
				tuning.wall_run_min_speed)
		velocity = up_on_wall * _wall_run_speed - wall_normal * 2.0
	else:
		var tangent := RegulatedPendulum.flat(RegulatedPendulum.project_on_plane(velocity, wall_normal))
		tangent = RegulatedPendulum.safe_normalized(tangent, side_on_wall)
		_wall_run_speed = maxf(_wall_run_speed - 2.0 * delta, tuning.wall_run_min_speed)
		var vy := move_toward(velocity.y, 0.0, tuning.g * delta)
		velocity = tangent * _wall_run_speed + Vector3.UP * vy - wall_normal * 2.0
	move_and_slide()
	_check_inner_corner()

	if wall_crawl and Input.is_action_pressed("point_zip") and Input.is_action_just_pressed("jump"):
		_jump_buffer = 0.0
		_start_slingshot()
		return
	if _jump_buffer > 0.0:
		_jump_buffer = 0.0
		if not wall_crawl and wall_vertical:
			# Tirón de telaraña hacia arriba por la fachada.
			_wall_run_speed = minf(_wall_run_speed + tuning.wall_web_pull, tuning.wall_run_max_speed)
			web_fired.emit(HAND_BOTH, global_position + up_on_wall * 18.0 - wall_normal * 0.5)
			_web_pull_timer = 0.3
		else:
			var along := RegulatedPendulum.flat(velocity) * 0.6
			velocity = wall_normal * tuning.wall_jump_out + Vector3.UP * tuning.wall_jump_up + along
			_set_state(State.FALL)
	elif wall_crawl and Input.is_action_just_pressed("dive"):
		velocity = wall_normal * 3.0
		_set_state(State.FALL)
	elif is_on_floor() and velocity.y <= 0.1:
		_land()


## Cornisa: sube por encima del borde y queda de pie sobre la azotea.
func _vault() -> void:
	var space := get_world_3d().direct_space_state
	var over := global_position - wall_normal * 0.9 + Vector3.UP * 3.0
	var q := PhysicsRayQueryParameters3D.create(over, over + Vector3.DOWN * 4.5, collision_mask,
			[get_rid()])
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.normal.y > 0.7:
		global_position = hit.position + Vector3.UP * 0.95
		velocity = -wall_normal * 4.0 + Vector3.UP * 2.0
	else:
		velocity = Vector3.UP * 7.0 - wall_normal * 3.0
	_set_state(State.FALL)


## Esquina exterior: gateando se rodea sola; corriendo, con la picada (web a la
## esquina) se rodea sin perder velocidad; si no, sale disparado (corner launch).
func _leave_wall_at_corner() -> void:
	var t := RegulatedPendulum.flat(velocity)
	if t.length() < 0.5 or (wall_vertical and not wall_crawl):
		_set_state(State.FALL)
		return
	t = t.normalized()
	if wall_crawl or _dive_buffer > 0.0 or Input.is_action_pressed("dive"):
		var space := get_world_3d().direct_space_state
		var from := global_position - wall_normal * 1.0
		var q := PhysicsRayQueryParameters3D.create(from, from - t * 3.0, collision_mask, [get_rid()])
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and absf(hit.normal.y) < 0.3:
			var old_normal := wall_normal
			wall_normal = hit.normal
			global_position = Vector3(hit.position.x, global_position.y, hit.position.z) \
					+ wall_normal * 0.45
			velocity = -old_normal * maxf(_wall_run_speed, tuning.wall_crawl_speed) \
					+ Vector3.UP * velocity.y
			_dive_buffer = 0.0
			if not wall_crawl:
				web_fired.emit(HAND_BOTH, hit.position - t * 0.3)
				_web_pull_timer = 0.25
			corner_turned.emit(false)
			return
	# Corner launch: sale despedido de la esquina con impulso.
	var boost := tuning.corner_launch_boost
	velocity = t * (_wall_run_speed + boost) + Vector3.UP * boost
	corner_turned.emit(true)
	_set_state(State.FALL)


## Esquina interior: al chocar corriendo con la pared contigua, se pasa a ella.
func _check_inner_corner() -> void:
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if absf(n.y) < 0.3 and n.dot(wall_normal) < 0.5:
			var old := wall_normal
			wall_normal = n
			if not wall_crawl and not wall_vertical:
				velocity = old * _wall_run_speed + Vector3.UP * velocity.y
			return


# ---------------------------------------------------------------------------
# Web Wings: planeo con túneles de viento y corrientes ascendentes
# ---------------------------------------------------------------------------
func _start_glide(from_dive: bool) -> void:
	wings.open(velocity, from_dive)
	_set_state(State.GLIDE)
	wings_opened.emit(wings.boosted)


func _update_glide(delta: float) -> void:
	var tdir := Vector3.ZERO
	var toff := Vector3.ZERO
	in_tunnel = 0.0
	in_updraft = 0.0
	if wind_field:
		wind_field.sample(global_position)
		tdir = wind_field.tunnel_dir
		toff = wind_field.tunnel_offset
		in_tunnel = wind_field.tunnel
		in_updraft = wind_field.updraft
	# Stick adelante (move_forward, y < 0) = picar, como en el original. El alabeo
	# suma el stick y el timón de cámara: vira hacia donde mira la cámara.
	var roll := clampf(move_input.x + _glide_camera_steer(), -1.0, 1.0)
	velocity = wings.step(delta, -move_input.y, roll, tdir, in_tunnel, in_updraft, toff)
	move_and_slide()

	if is_on_floor():
		_land()
		return
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if absf(n.y) <= 0.3 and _wall_cooldown <= 0.0 and _enter_wall(n, velocity, false):
			return
	if get_slide_collision_count() > 0:
		# Roce: la velocidad real manda (sin perder el estado de las alas).
		var real := get_real_velocity()
		wings.speed = maxf(real.length(), 2.0)

	# El mismo botón cierra las alas (no en los primeros instantes: evita que la
	# misma pulsación que las abrió las cierre).
	if Input.is_action_just_pressed("glide") and state_time > 0.15:
		_set_state(State.FALL)
	elif Input.is_action_just_pressed("dive"):
		_set_state(State.DIVE)
	elif Input.is_action_just_pressed("swing"):
		_try_attach()                    # si no hay anclaje, sigue planeando
	elif _jump_buffer > 0.0 and _zip_cooldown <= 0.0:
		_jump_buffer = 0.0
		_start_zip()
	elif Input.is_action_just_pressed("point_zip"):
		_start_point_zip()


## Alabeo que lleva el rumbo del planeo hacia el de la cámara (+1 = derecha).
func _glide_camera_steer() -> float:
	if camera == null or tuning.glide_camera_steer <= 0.0 or not camera_steer_active \
			or absf(move_input.x) > 0.2:
		return 0.0
	var heading := Vector3(sin(wings.psi), 0.0, cos(wings.psi))
	var ang := heading.signed_angle_to(cam_forward, Vector3.UP)    # + = cámara a la izquierda
	return -clampf(ang / deg_to_rad(tuning.glide_camera_steer_deg), -1.0, 1.0) \
			* tuning.glide_camera_steer


# ---------------------------------------------------------------------------
# Super Slingshot: dos webs por delante, tensar hacia atrás y salir disparado
# ---------------------------------------------------------------------------
## En el suelo, point_zip mantenido + salto = slingshot; un toque corto = point zip.
func _ground_point_zip_or_slingshot(delta: float) -> bool:
	if Input.is_action_just_pressed("point_zip"):
		_pz_hold = 0.0
	if _pz_hold < 0.0:
		return false
	if Input.is_action_pressed("point_zip"):
		_pz_hold += delta
		if Input.is_action_just_pressed("jump"):
			_pz_hold = -1.0
			_jump_buffer = 0.0
			_start_slingshot()
			return true
		return false
	var was_tap := _pz_hold < 0.3
	_pz_hold = -1.0
	return was_tap and _start_point_zip()


func _start_slingshot() -> void:
	var aim := RegulatedPendulum.safe_normalized(cam_forward, travel_dir)
	if state == State.WALL_RUN:
		# Desde la pared: siempre hacia fuera de la fachada.
		var n := RegulatedPendulum.flat(wall_normal)
		aim = RegulatedPendulum.safe_normalized(aim - n * minf(aim.dot(n), 0.0) + n * 0.6, n)
	var right := aim.cross(Vector3.UP).normalized()
	var space := get_world_3d().direct_space_state
	var from := global_position + hand_offset
	var anchors: Array[Vector3] = []
	for side: float in [-1.0, 1.0]:
		var dir := (aim * cos(deg_to_rad(35.0)) + right * side * sin(deg_to_rad(35.0)) \
				+ Vector3.UP * 0.35).normalized()
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				from, from + dir * 40.0, collision_mask, [get_rid()]))
		if hit.is_empty():
			# Sin fachada delante: la web se clava en el suelo por delante (nunca en el aire).
			var ahead := from + dir * 12.0
			hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(
					ahead, ahead + Vector3.DOWN * 60.0, collision_mask, [get_rid()]))
		anchors.append(hit.position if not hit.is_empty() else from + dir * 12.0)
	slingshot_aim = aim
	slingshot_anchors = anchors
	slingshot_charge = 0.0
	_sling_origin = global_position
	_sling_prev_state = state if state != State.WALL_RUN else State.GROUNDED
	_set_state(State.SLINGSHOT)
	web_fired.emit(HAND_LEFT, anchors[0])
	web_fired.emit(HAND_RIGHT, anchors[1])


func _update_slingshot(delta: float) -> void:
	slingshot_charge = minf(slingshot_charge + delta / tuning.slingshot_charge_time, 1.0)
	# Se echa hacia atrás tensando las webs (en horizontal: no cae de la cornisa).
	var back := _sling_origin - slingshot_aim * tuning.slingshot_pull_back * sin(slingshot_charge * PI * 0.5)
	velocity = RegulatedPendulum.flat(back - global_position) / delta * 0.25
	move_and_slide()
	if not Input.is_action_pressed("jump"):
		var c := slingshot_charge
		var dir := (slingshot_aim + Vector3.UP * tuning.slingshot_lift).normalized()
		velocity = dir * lerpf(tuning.slingshot_min_speed, tuning.slingshot_max_speed, c * c)
		web_released.emit(HAND_BOTH, false)
		slingshot_launched.emit(c)
		_set_state(State.FALL)
	elif not Input.is_action_pressed("point_zip"):
		web_released.emit(HAND_BOTH, false)          # cancelado
		_set_state(_sling_prev_state)
