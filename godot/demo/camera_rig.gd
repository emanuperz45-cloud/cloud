class_name CameraRig
extends Node3D
## Cámara orbital en tercera persona: ratón / stick derecho, se recoloca sola
## detrás de la velocidad, se aleja y abre el FOV con la velocidad y tiembla
## ligeramente en el pico de tensión del balanceo.
## Sensación de velocidad: mira por delante de la trayectoria (look-ahead), se
## inclina en los virajes (roll), "punch" de FOV en impulsos (suelta perfecta,
## zip, slingshot, alas en picada) y sacudida en aterrizajes fuertes.

@export var target: TraversalController
@export var mouse_sensitivity := 0.0025
@export var stick_speed := 2.6

var yaw := 0.0         # 0 = mirando hacia -Z
var pitch := -0.22
var camera: Camera3D
var spring: SpringArm3D

var distance_override := -1.0   ## > 0 fija la distancia (capturas de cerca)
var _idle := 10.0
var _shake := 0.0
var _punch := 0.0              ## grados de FOV extra que decaen
var _roll := 0.0
var _lookahead := Vector3.ZERO
var _punch_now := 0.0
var _base_fov := 70.0


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	spring = SpringArm3D.new()
	spring.spring_length = 5.0
	spring.collision_mask = 1
	spring.margin = 0.3
	add_child(spring)
	spring.add_excluded_object(target.get_rid())
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.far = 4000.0
	spring.add_child(camera)
	camera.make_current()
	snap()
	target.web_released.connect(func(_h: int, perfect: bool) -> void:
		if perfect:
			punch(9.0))
	target.point_launched.connect(func(perfect: bool) -> void: punch(12.0 if perfect else 7.0))
	target.slingshot_launched.connect(func(c: float) -> void:
		punch(8.0 + 14.0 * c)
		_shake = maxf(_shake, 0.05 * c))
	target.wings_opened.connect(func(boosted: bool) -> void: punch(10.0 if boosted else 3.0))
	target.jumped.connect(func(c: float) -> void: punch(c * 8.0))
	target.quick_recovered.connect(func() -> void: punch(5.0))
	target.looped.connect(func(_n: int) -> void: punch(6.0))
	target.loop_boosted.connect(func() -> void: punch(12.0))
	target.spider_dashed.connect(func() -> void: punch(10.0))
	target.spider_jumped.connect(func() -> void: punch(7.0))
	target.landed.connect(func(impact: float) -> void:
		_shake = maxf(_shake, clampf((impact - 20.0) / 30.0, 0.0, 1.0) * 0.12))
	target.state_changed.connect(func(_a: int, b: int) -> void:
		if b == TraversalController.State.WEB_ZIP:
			punch(4.0))


func punch(deg: float) -> void:
	_punch = maxf(_punch, deg)


func snap() -> void:
	global_position = target.global_position + Vector3.UP * 1.2
	yaw = atan2(-target.travel_dir.x, -target.travel_dir.z)


## Orienta la cámara como si el jugador la moviera (lo usa el autopiloto).
func look_towards(dir: Vector3) -> void:
	yaw = atan2(-dir.x, -dir.z)
	_idle = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := (event as InputEventMouseMotion).relative
		yaw -= motion.x * mouse_sensitivity
		pitch = clampf(pitch - motion.y * mouse_sensitivity, -1.35, 0.9)
		_idle = 0.0


func _process(delta: float) -> void:
	var stick := Input.get_vector("cam_left", "cam_right", "cam_up", "cam_down")
	if stick.length() > 0.1:
		yaw -= stick.x * stick_speed * delta
		pitch = clampf(pitch - stick.y * stick_speed * 0.7 * delta, -1.35, 0.9)
		_idle = 0.0
	_idle += delta

	var v := target.velocity
	var spd := v.length()
	var st := target.state
	var gliding := st == TraversalController.State.GLIDE
	# Al planear, mover la cámara es timón (vira hacia donde miras) durante 0,6 s.
	target.camera_steer_active = gliding and _idle < 0.6
	# Sin tocar la cámara se coloca detrás de la dirección de viaje (planeando, rápido
	# y casi enseguida para acompañar virajes de ~100°/s).
	var wait := 0.35 if gliding else 1.0
	var follow := 5.0 if gliding else 1.6
	if _idle > wait and Vector2(v.x, v.z).length() > 8.0:
		yaw = lerp_angle(yaw, atan2(-v.x, -v.z), 1.0 - exp(-follow * delta))

	# Look-ahead: el foco se adelanta un poco en la dirección del movimiento.
	var ahead := v * clampf(spd / 40.0, 0.0, 1.0) * 0.08
	ahead.y *= 0.4
	_lookahead = _lookahead.lerp(ahead, 1.0 - exp(-3.0 * delta))
	var focus := target.get_global_transform_interpolated().origin + Vector3.UP * 1.2 + _lookahead
	global_position = global_position.lerp(focus, 1.0 - exp(-14.0 * delta))
	# Al planear, la cámara acompaña el cabeceo (mira algo más hacia abajo al picar).
	var pitch_bias := 0.0
	if gliding:
		pitch_bias = clampf(target.wings.gamma * 0.45, -0.35, 0.2)
	# Roll: en los virajes (alabeo de las alas o giro del balanceo) el horizonte se inclina.
	var roll_target := 0.0
	if gliding:
		roll_target = -target.wings.bank * 0.25
	elif st == TraversalController.State.SWING or st == TraversalController.State.DIVE:
		roll_target = -target.move_input.x * clampf(spd / 30.0, 0.0, 1.0) * 0.07
	_roll = lerpf(_roll, roll_target, 1.0 - exp(-4.0 * delta))
	rotation = Vector3(pitch + pitch_bias, yaw, _roll)

	var dist := 4.5 + clampf(spd * 0.08, 0.0, 4.0)
	if gliding:
		dist += 1.5
	elif st == TraversalController.State.SLINGSHOT:
		dist = 3.8 + target.slingshot_charge * 1.2
	if distance_override > 0.0:
		dist = distance_override
	spring.spring_length = lerpf(spring.spring_length, dist, 1.0 - exp(-3.0 * delta))
	_punch = move_toward(_punch, 0.0, delta * 14.0)
	var fov := 70.0 + clampf(spd / 45.0, 0.0, 1.0) * 20.0
	if st == TraversalController.State.SLINGSHOT:
		fov -= target.slingshot_charge * 10.0          # se cierra al tensar...
	_base_fov = lerpf(_base_fov, fov, 1.0 - exp(-4.0 * delta))
	_punch_now = lerpf(_punch_now, _punch, 1.0 - exp(-22.0 * delta))   # ...y se abre de golpe
	camera.fov = _base_fov + _punch_now

	if target.state == TraversalController.State.SWING:
		_shake = maxf(_shake, clampf((target.pendulum.g_force - 4.0) / 4.0, 0.0, 1.0) * 0.06)
	elif gliding:
		_shake = maxf(_shake, clampf((spd - 55.0) / 25.0, 0.0, 1.0) * 0.012)
	_shake = move_toward(_shake, 0.0, delta * 0.3)
	# Sacudida suave (suma de senos, ~5-9 Hz): el ruido aleatorio por frame se ve sucio.
	var t := Time.get_ticks_msec() * 0.001
	camera.h_offset = (sin(t * 37.0) * 0.6 + sin(t * 53.0 + 1.3) * 0.4) * _shake
	camera.v_offset = (sin(t * 43.0 + 0.7) * 0.6 + sin(t * 31.0 + 2.1) * 0.4) * _shake
