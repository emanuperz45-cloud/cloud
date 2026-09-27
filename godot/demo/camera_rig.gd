class_name CameraRig
extends Node3D
## Cámara orbital en tercera persona: ratón / stick derecho, se recoloca sola
## detrás de la velocidad, se aleja y abre el FOV con la velocidad y tiembla
## ligeramente en el pico de tensión del balanceo.

@export var target: TraversalController
@export var mouse_sensitivity := 0.0025
@export var stick_speed := 2.6

var yaw := 0.0         # 0 = mirando hacia -Z
var pitch := -0.22
var camera: Camera3D
var spring: SpringArm3D

var _idle := 10.0
var _shake := 0.0


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
	# Tras 1 s sin tocar la cámara, se coloca detrás de la dirección de viaje.
	if _idle > 1.0 and Vector2(v.x, v.z).length() > 8.0:
		yaw = lerp_angle(yaw, atan2(-v.x, -v.z), 1.0 - exp(-1.6 * delta))

	var focus := target.get_global_transform_interpolated().origin + Vector3.UP * 1.2
	global_position = global_position.lerp(focus, 1.0 - exp(-14.0 * delta))
	rotation = Vector3(pitch, yaw, 0.0)

	spring.spring_length = lerpf(spring.spring_length, 4.5 + clampf(spd * 0.08, 0.0, 4.0),
			1.0 - exp(-3.0 * delta))
	camera.fov = lerpf(camera.fov, 70.0 + clampf(spd / 45.0, 0.0, 1.0) * 20.0, 1.0 - exp(-4.0 * delta))

	if target.state == TraversalController.State.SWING:
		_shake = maxf(_shake, clampf((target.pendulum.g_force - 4.0) / 4.0, 0.0, 1.0) * 0.06)
	_shake = move_toward(_shake, 0.0, delta * 0.3)
	camera.h_offset = randf_range(-1.0, 1.0) * _shake
	camera.v_offset = randf_range(-1.0, 1.0) * _shake
