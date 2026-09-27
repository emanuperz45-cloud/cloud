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
##  run  : sprint por la avenida x = 0 con una curva (capturas de la carrera)
##  glide: Web Wings desde lo alto: planeo, picada + alas (impulso), viraje,
##         túnel de viento de la avenida x = 0, corriente ascendente y timón de cámara
##  sling: Super Slingshot desde el suelo (carga completa), cancelación y loop
##         (clic + truco mantenidos en un swing rápido)

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
	hud.set_help_visible(false)          # capturas limpias
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
	player.looped.connect(func(n: int) -> void: _count("loop_%d" % n))
	player.state_changed.connect(func(a: int, b: int) -> void:
		if OS.has_environment("AP_DEBUG"):
			print("[dbg] t=%.2f %s -> %s pos=%s v=%s" % [_t, a, b, player.global_position, player.velocity]))
	player.wings_opened.connect(func(b: bool) -> void: _count("wings_boost" if b else "wings"))
	player.wings_closed.connect(func() -> void: _count("wings_closed"))
	player.slingshot_launched.connect(func(c: float) -> void:
		_count("slingshot")
		_mark["sling_charge"] = snappedf(c, 0.01)
		_mark["sling_speed"] = snappedf(player.velocity.length(), 0.1))


func _count(key: String) -> void:
	_stats.events[key] = _stats.events.get(key, 0) + 1


func _press(action: String, down: bool) -> void:
	if down:
		if not Input.is_action_pressed(action):   # re-pulsar cada frame = "just pressed" continuo
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
	sub = sub.split(" ")[0] if sub.begins_with("CARGANDO") or sub.begins_with("SLINGSHOT") else sub
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
		"glide":
			_glide()
		"sling":
			_sling()
		"run":
			if _at(0.02):
				_place(Vector3(0.0, 0.95, 60.0), Vector3.FORWARD)
			_press("move_forward", _t > 0.1)
			_press("swing", _t > 0.1 and _t < 4.0)          # sprint
			_press("move_right", _t > 2.4 and _t < 3.4)     # curva: inclinación hacia dentro
		"pose":
			if _at(0.02):
				_place(Vector3(-4.0, 0.95, 3.0), Vector3.FORWARD)
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
		for action in ["swing", "move_forward", "move_right", "move_back", "dive", "jump", "point_zip"]:
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


# --- glide: Web Wings -----------------------------------------------------
func _glide() -> void:
	var w := player.wings
	# 1) Desde 150 m sobre la avenida x = 0: alas en neutro, dentro del túnel.
	if _at(0.02):
		_place(Vector3(0.0, 80.0, 200.0), Vector3.FORWARD)
		player.state = TraversalController.State.FALL
		player.velocity = Vector3(0.0, -2.0, -16.0)
	if _at(0.3):
		_tap("glide")
	if _at(0.4):
		_mark["open_speed"] = snappedf(w.speed, 0.1)
	if _t > 0.4 and _t < 6.0 and player.state == TraversalController.State.GLIDE:
		_mark["tunnel_max"] = maxf(_mark.get("tunnel_max", 0.0), snappedf(player.in_tunnel, 0.01))
		_mark["tunnel_speed_max"] = maxf(_mark.get("tunnel_speed_max", 0.0), snappedf(w.speed, 0.1))
	if _at(6.0):
		_mark["state_6s"] = hud._state_name()
		_mark["y_6s"] = snappedf(player.global_position.y, 0.1)
	# 2) Picada fuera del túnel y abrir las alas a > 30 m/s: impulso.
	if _at(6.5):
		_place(Vector3(40.0, 230.0, 40.0), Vector3.FORWARD)
		player.state = TraversalController.State.FALL
	_press("dive", _t > 6.6 and _t < 9.2)
	if _at(9.25):
		_mark["dive_speed"] = snappedf(player.velocity.length(), 0.1)
		_tap("glide")
	if _at(9.3):
		_mark["boosted"] = w.boosted
		_mark["boost_speed"] = snappedf(w.speed, 0.1)
	# 3) Viraje a la derecha (alabeo) y encabritar hasta la pérdida.
	_press("move_right", _t > 9.5 and _t < 11.0)
	if _at(9.9):
		_mark["_psi0"] = w.psi
	if _at(10.9):
		_mark["bank_deg"] = snappedf(rad_to_deg(w.bank), 0.1)
		_mark["turn_deg_s"] = snappedf(rad_to_deg(float(_mark["_psi0"]) - w.psi), 0.1)   # derecha = ψ baja
		_mark.erase("_psi0")
	_press("move_back", _t > 11.2 and _t < 17.0)
	if _t > 11.2 and _t < 17.0 and w.stalled:
		_mark["stalled"] = true
	# 4) Corriente ascendente: planear sobre la primera columna.
	if _at(17.5) and player.wind_field and not player.wind_field.updrafts.is_empty():
		# Entra en la columna desde 15 m por el lado despejado (sin fachadas delante).
		var u: WindField.Updraft = player.wind_field.updrafts[0]
		var dir := _open_direction(u.center + Vector3.UP * 8.0, 60.0)
		_place(u.center + Vector3.UP * 8.0 - dir * 15.0, dir)
		player.state = TraversalController.State.FALL
		player.velocity = dir * 15.0
		_mark["updraft_y0"] = snappedf(player.global_position.y, 0.1)
	if _at(17.6):
		_tap("glide")
	if _t > 17.6 and _t < 19.5 and player.state == TraversalController.State.GLIDE:
		_mark["updraft_max"] = maxf(_mark.get("updraft_max", 0.0), snappedf(player.in_updraft, 0.01))
		_mark["updraft_y_max"] = maxf(_mark.get("updraft_y_max", -99.0), snappedf(player.global_position.y, 0.1))
	if _at(19.5):
		_mark["state_19s"] = hud._state_name()
	# 5) Timón con la cámara: mirar 70° a la izquierda sin tocar el teclado.
	if _at(19.6):
		_place(Vector3(0.0, 200.0, 60.0), Vector3.FORWARD)
		player.state = TraversalController.State.FALL
		player.velocity = Vector3(0.0, -3.0, -25.0)
	if _at(19.7):
		_tap("glide")
	if _at(19.8):
		_mark["_cam_psi0"] = w.psi
	if _t > 19.8 and _t < 21.3:
		camera_rig.look_towards(Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(70.0)))
	if _at(21.3):
		_mark["camera_turn_deg"] = snappedf(rad_to_deg(w.psi - float(_mark["_cam_psi0"])), 0.1)
		_mark.erase("_cam_psi0")
	_stats["glide"] = _mark


func _open_direction(from: Vector3, dist: float) -> Vector3:
	var space := player.get_world_3d().direct_space_state
	var best := Vector3.FORWARD
	var best_d := -1.0
	for i in 16:
		var d := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 16.0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				from - d * 15.0, from + d * dist, 1))
		var free: float = dist + 15.0 if hit.is_empty() else ((hit.position as Vector3) - (from - d * 15.0)).length()
		if free > best_d:
			best_d = free
			best = d
	return best


# --- sling: Super Slingshot y loop -----------------------------------------
func _sling() -> void:
	var ground := Vector3(0.0, 0.95, 27.0)
	if _at(0.02):
		_place(ground, Vector3.FORWARD)
	# Q mantenido + ESPACIO mantenido 1.4 s -> soltar ESPACIO (abajo: los dos tramos).
	if _at(1.0):
		_mark["state_charging"] = hud._state_name()
	if _at(2.4):
		_mark["y_after"] = snappedf(player.global_position.y, 0.1)
	# Cancelar: soltar Q con ESPACIO pulsado -> vuelve al suelo sin lanzar.
	if _at(5.0):
		_place(ground, Vector3.FORWARD)
	_press("point_zip", (_t > 5.2 and _t < 5.8) or (_t > 0.3 and _t < 2.0))
	_press("jump", (_t > 5.3 and _t < 6.2) or (_t > 0.5 and _t < 1.9))
	if _at(6.0):
		_mark["after_cancel"] = hud._state_name()
	# Loop: swing rápido con el clic mantenido y truco mantenido (cierra el arco).
	if _at(7.0):
		_place(Vector3(0.0, 60.0, 30.0), Vector3.FORWARD)
		player.state = TraversalController.State.FALL
		player.velocity = Vector3(0.0, -6.0, -44.0)
	_press("swing", _t > 7.05 and _t < 13.0)
	_press("trick", _t > 7.3 and _t < 10.0)
	_stats["sling"] = _mark


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
