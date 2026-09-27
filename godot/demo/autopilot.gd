class_name DemoAutopilot
extends Node
## Piloto automático para probar builds sin interfaz (y sacar capturas). Pulsa las
## mismas acciones de InputMap que un jugador, así prueba el control real.
##   --autopilot=SEGUNDOS  --scenario=tour|hang|moves  --shots=t1,t2  --shot-prefix=RUTA
##  tour : balanceo como un jugador (suelta el clic al subir) recorriendo la ciudad
##  hang : mantiene el clic sin soltar -> péndulo en la misma telaraña hasta colgar
##  moves: charge jump, web zip + quick zip, truco, colgarse y subir por la web,
##         sprint contra una fachada, wall run, trepar y salto de pared
##  pose : personaje quieto en la calle con la cámara de frente y cerca (traje)

var main: Node3D
var player: TraversalController
var camera_rig: CameraRig
var hud: DemoHud
var duration := 60.0
var scenario := "tour"
var shots: Array[float] = []
var shot_prefix := ""

var _t := 0.0
var _step := 0
var _prev_state := -1
var _release_at := -1.0
var _anchor := Vector3.ZERO
var _stats := {"events": {}, "substates": {}, "max_speed": 0.0, "min_y": INF, "max_y": -INF}
var _mark := {}
var _tapped: Array[String] = []


func _ready() -> void:
	player.web_fired.connect(func(_h: int, a: Vector3) -> void:
		_count("web_fired")
		_anchor = a)
	player.web_released.connect(func(_h: int, perfect: bool) -> void:
		_count("perfect_release" if perfect else "release"))
	player.wall_run_started.connect(func(v: bool) -> void: _count("wall_run" if v else "wall_contact"))
	player.landed.connect(func(_s: float) -> void: _count("land_" + player.land_kind))
	player.jumped.connect(func(c: float) -> void:
		_count("charge_jump")
		_mark["charge"] = c)
	player.trick_started.connect(func() -> void: _count("trick_%d" % player.trick_index))
	player.quick_recovered.connect(func() -> void: _count("quick_recovery"))
	player.corner_turned.connect(func(l: bool) -> void:
		_count("corner_launch" if l else "corner_turn"))


func _count(key: String) -> void:
	_stats.events[key] = _stats.events.get(key, 0) + 1


func _press(action: String, down: bool) -> void:
	if down:
		Input.action_press(action)
	else:
		Input.action_release(action)


func _tap(action: String) -> void:
	Input.action_press(action)
	_tapped.append(action)


func _physics_process(delta: float) -> void:
	_t += delta
	var p := player.global_position
	var sub := hud._state_name()
	sub = sub.split(" ")[0] if sub.begins_with("CARGANDO") else sub
	_stats.substates[sub] = snappedf(_stats.substates.get(sub, 0.0) + delta, 0.01)
	_stats.max_speed = maxf(_stats.max_speed, player.velocity.length())
	_stats.min_y = minf(_stats.min_y, p.y)
	_stats.max_y = maxf(_stats.max_y, p.y)
	for action in _tapped:
		Input.action_release(action)       # las pulsaciones duran un frame
	_tapped.clear()

	match scenario:
		"hang":
			_hang()
		"moves":
			_moves()
		"pose":
			if _at(0.02):
				_place(Vector3(-4.0, 0.95, 3.0), Vector3.FORWARD)
				hud.set_help_visible(false)
			camera_rig.distance_override = 3.0
			camera_rig.pitch = -0.18
			camera_rig.look_towards(Vector3.BACK)          # cámara mirando de frente al personaje
		_:
			_tour()

	if int(_t * 60.0) % 60 == 0:
		print("[autopilot] t=%5.1f %-10s pos=(%7.1f, %5.1f, %7.1f) v=%5.1f m/s cuerda=%.1f" % [
				_t, sub, p.x, p.y, p.z, player.velocity.length(), player.pendulum.length])
	for s in shots:
		if absf(_t - s) < delta * 0.5:
			var img := main.get_viewport().get_texture().get_image()
			if img:
				var path := "%s_%s.png" % [shot_prefix, str(snappedf(s, 0.1))]
				img.save_png(path)
				print("[autopilot] captura -> ", path, " (", sub, ")")
	if _t >= duration:
		for action in ["swing", "move_forward", "move_right", "dive", "jump"]:
			Input.action_release(action)
		print("[autopilot] RESUMEN ", JSON.stringify(_stats))
		main.get_tree().quit()


# --- tour: balanceo de jugador (suelta al subir, vuelve a disparar) ---------
func _tour() -> void:
	var p := player.global_position
	var around := atan2(p.x, p.z) + 0.5
	var waypoint := Vector3(sin(around), 0.0, cos(around)) * 300.0
	camera_rig.look_towards(RegulatedPendulum.flat(waypoint - p).normalized())
	_press("move_forward", true)
	var st := player.state
	if st == TraversalController.State.SWING:
		var pend := player.pendulum
		_press("swing", not (pend.swing_angle_deg >= 35.0 or pend.sustain))
	elif st == TraversalController.State.GROUNDED:
		_press("swing", true)                               # sprint...
		if player.state_time > 0.3 and fmod(player.state_time, 1.0) < 0.02:
			_tap("jump")                                    # ...y salto: el clic mantenido dispara
	else:
		_press("swing", player.state_time > 0.12)
	var cycle := fmod(_t, 9.0)
	_press("dive", cycle > 6.0 and cycle < 7.0 and p.y > 45.0)
	if st == TraversalController.State.FALL and fmod(_t, 7.0) < 0.02 and player.velocity.y < 0.0:
		_tap("jump")                                        # web zip en el aire
	if st == TraversalController.State.FALL and fmod(_t + 3.0, 5.0) < 0.02:
		_tap("trick")


# --- hang: mantener el clic sin soltarlo -----------------------------------
func _hang() -> void:
	_press("swing", true)
	var sw := player.state == TraversalController.State.SWING
	if sw and not _mark.has("attach_t"):
		_mark["attach_t"] = _t
	if sw and player.pendulum.sustain and player.pendulum.speed < 0.5 and not _mark.has("settled_t"):
		_mark["settled_t"] = snappedf(_t - _mark.get("attach_t", 0.0), 0.01)
	# Últimos segundos: subir por la telaraña (W) para comprobar el reel.
	var climb := _t > duration - 3.0 and _t < duration - 1.5
	_press("move_forward", climb)
	if absf(_t - (duration - 3.0)) < 0.01:
		_mark["len_before_climb"] = snappedf(player.pendulum.length, 0.01)
	if absf(_t - (duration - 1.2)) < 0.01:
		_mark["len_after_climb"] = snappedf(player.pendulum.length, 0.01)
	_stats["hang"] = {"still_on_web": sw, "speed": snappedf(player.pendulum.speed, 0.01),
			"sustain": player.pendulum.sustain, "marks": _mark,
			"dist_to_anchor": snappedf(player.global_position.distance_to(_anchor), 0.01)}


# --- moves: secuencia guionizada del moveset ------------------------------
func _at(t0: float) -> bool:
	return _t >= t0 and _t - t0 < 1.0 / 60.0


func _moves() -> void:
	var ground := Vector3(0.0, 0.95, 27.0)      # frente al centro de un solar
	if _at(0.02):
		_place(ground, Vector3.LEFT)
	# Charge Jump: mantener salto 0.8 s y soltar.
	_press("jump", _t > 0.3 and _t < 1.1)
	# Web Zip y Quick Zip en el aire.
	if _at(1.7) or _at(2.1):
		_tap("jump")
	# Truco con dirección (adelante = voltereta).
	_press("move_forward", (_t > 2.7 and _t < 2.9) or (_t > 12.0 and _t < 13.0) or _t > 17.0)
	if _at(2.8):
		_tap("trick")
	# Colgarse: mantener el clic 10 s; W para subir por la web al final.
	_press("swing", (_t > 3.4 and _t < 14.0) or (_t > 16.5 and _t < 19.5))
	if _at(14.0):
		_mark["hang_speed_before_release"] = snappedf(player.pendulum.speed, 0.01)
		_mark["hang_length"] = snappedf(player.pendulum.length, 0.01)
	# Sprint contra una fachada con el clic -> wall run; soltar -> trepar; salto.
	if _at(16.0):
		_place(ground, Vector3.LEFT)
	if _at(19.5):
		_mark["wall_state_holding"] = hud._state_name()
	_press("move_right", _t > 20.0 and _t < 21.0)
	if _at(21.2):
		_mark["wall_state_released"] = hud._state_name()
	if _at(21.5):
		_tap("jump")
	if _at(21.6):
		_mark["after_wall_jump"] = hud._state_name()
	_stats["moves"] = _mark


func _place(pos: Vector3, facing: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.travel_dir = facing
	player.pendulum.active = false
	player.state = TraversalController.State.GROUNDED
	player.state_time = 0.0
	player.wall_crawl = false
	player.land_timer = 0.0
	player.reset_physics_interpolation()
	camera_rig.look_towards(facing)
	camera_rig.snap()
	camera_rig.look_towards(facing)
