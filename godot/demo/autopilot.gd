class_name DemoAutopilot
extends Node
## Piloto automático para probar builds sin interfaz (y sacar capturas). Pulsa las
## mismas acciones de InputMap que un jugador, así prueba el control real.
##   --autopilot=SEGUNDOS  --scenario=tour|hang|moves  --shots=t1,t2  --shot-prefix=RUTA
##  tour : balanceo como un jugador (apunta la mira a un anclaje, clic, suelta al subir)
##  hang : apunta, hace clic y lo mantiene -> péndulo en la misma telaraña hasta colgar
##  aim  : la telaraña va donde apunta la mira (punto exacto, cono de asistencia, fallo),
##         y mantener el clic no reengancha ni se convierte en wall run
##  moves: charge jump, web zip + quick zip, truco, colgarse y subir por la web,
##         sprint contra una fachada, wall run, trepar y salto de pared
##  pose : personaje quieto en la calle con la cámara de frente y cerca (traje)
##  run  : sprint por la avenida x = 0 con una curva (capturas de la carrera)
##  sm2  : Loop de Loop (picada + clic), Spider-Dash, Spider-Jump, vault sobre un
##         aire acondicionado y salto de borde de azotea esprintando
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
var _alog := OS.has_environment("AP_ANIMLOG")     ## registra saltos bruscos de los huesos
var _alog_prev := {}                               ## hueso -> [rotación anterior, giro del paso anterior]
var _alog_events: Array = []


func _ready() -> void:
	if not "--show-help" in OS.get_cmdline_user_args():
		hud.set_help_visible(false)      # capturas limpias (salvo --show-help)
	player.web_fired.connect(func(_h: int, a: Vector3) -> void:
		_count("web_fired")
		if OS.has_environment("AP_DEBUG"):
			print("[dbg] t=%.2f web_fired hand=%s state=%s anchor=%s player=%s aim=%s" % [_t, _h, player.state, a, player.global_position, player.aim_ray()])
		_anchor = a)
	player.web_missed.connect(func(_h: int, _tip: Vector3) -> void:
		_count("web_missed")
		if OS.has_environment("AP_DEBUG"):
			print("[dbg] t=%.2f web_missed state=%s" % [_t, player.state]))
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
	player.loop_boosted.connect(func() -> void:
		_count("loop_boost")
		_mark["loop_boost_speed"] = snappedf(player.velocity.length(), 0.1))
	player.spider_dashed.connect(func() -> void:
		_count("spider_dash")
		_mark["dash_speed"] = snappedf(player.velocity.length(), 0.1))
	player.spider_jumped.connect(func() -> void:
		_count("spider_jump")
		_mark["jump_vy"] = snappedf(player.velocity.y, 0.1))
	player.vaulted.connect(func(h: float) -> void:
		_count("vault")
		_mark["vault_h"] = snappedf(h, 0.01))
	player.ledge_leaped.connect(func() -> void: _count("ledge_leap"))
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


## Como un jugador: apunta la mira al mejor anclaje que ve y hace clic (cada `retry` s
## hasta que engancha). Devuelve false si no ve ninguno.
func _aim_and_tap(retry := 0.15) -> bool:
	var finder := player.anchor_finder
	var p := player.global_position
	var cand := finder.best_for(float(player.hand), p, player.velocity, player.travel_dir)
	if cand == null:
		cand = finder.best_for(float(-player.hand), p, player.velocity, player.travel_dir)
	if cand == null:
		return false
	camera_rig.aim_at(cand.point)
	if player.state_time > 0.12 and fmod(_t, retry) < 1.0 / 60.0 * 1.01:
		_tap("swing")
	return true


## Mantener el clic mientras `want`: en el aire, si no hay telaraña apunta y dispara; una
## vez enganchado lo mantiene (soltar = soltarse); en el suelo y en la pared es el
## sprint / la carrera vertical.
func _swing_click(want: bool) -> void:
	if not want:
		_press("swing", false)
	elif player.state in [TraversalController.State.SWING, TraversalController.State.WALL_RUN,
			TraversalController.State.GROUNDED]:
		_press("swing", true)
	else:
		_press("swing", false)
		_aim_and_tap()


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

	if _alog:
		_log_anim(delta)
	match scenario:
		"aim":
			_aim()
		"hang":
			_hang()
		"moves":
			_moves()
		"glide":
			_glide()
		"sling":
			_sling()
		"sm2":
			_sm2()
		"run":
			if _at(0.02):
				_place(Vector3(0.0, 0.95, 60.0), Vector3.FORWARD)
			_press("move_forward", _t > 0.1)
			_press("swing", _t > 0.1 and _t < 4.0)          # sprint
			_press("move_right", _t > 2.4 and _t < 3.4)     # curva: inclinación hacia dentro
		"pose":
			if _at(0.02):
				_place(Vector3(-4.0, 0.95, 3.0), Vector3.FORWARD)
			camera_rig.distance_override = 1.7
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
		if _alog:
			_alog_events.sort_custom(func(a: Array, b: Array) -> bool: return a[2] > b[2])
			print("[animlog] %d saltos (Δ giro por paso > umbral); los 25 mayores [t, hueso, Δ°/paso, estado, °/s]:" % _alog_events.size())
			for e in _alog_events.slice(0, 25):
				print("[animlog] ", e)
			if OS.has_environment("AP_ANIMLOG_ALL"):
				_alog_events.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
				for e in _alog_events:
					print("[animlog-all] ", e)
			var by := {}
			for e in _alog_events:
				by[e[1]] = by.get(e[1], 0) + 1
			print("[animlog] por hueso: ", JSON.stringify(by))
			var agg := {}
			for e in _alog_events:
				var key: String = "%s|%s" % [e[3], e[1]]
				var a: Array = agg.get(key, [0, 0.0])
				a[0] += 1
				a[1] = maxf(a[1], e[2])
				agg[key] = a
			var keys := agg.keys()
			keys.sort_custom(func(a: String, b: String) -> bool: return agg[a][0] > agg[b][0])
			for k in keys.slice(0, 30):
				print("[animlog] %-28s n=%4d  max=%.1f°" % [k, agg[k][0], agg[k][1]])
		main.get_tree().quit()


# --- tour: balanceo de jugador (apunta, clic, suelta al subir, vuelve a apuntar) ---
func _tour() -> void:
	var p := player.global_position
	var around := atan2(p.x, p.z) + 0.5
	var waypoint := Vector3(sin(around), 0.0, cos(around)) * 300.0
	var st := player.state
	if st == TraversalController.State.SWING:
		var pend := player.pendulum
		camera_rig.look_towards(RegulatedPendulum.flat(waypoint - p).normalized())
		_press("swing", not (pend.swing_angle_deg >= 35.0 or pend.sustain))
	elif st == TraversalController.State.GROUNDED:
		_press("swing", true)                               # sprint...
		if player.state_time > 0.3 and fmod(player.state_time, 1.0) < 0.02:
			_tap("jump")                                    # ...y salto: el clic dispara al aire
		camera_rig.look_towards(RegulatedPendulum.flat(waypoint - p).normalized())
	elif st == TraversalController.State.WALL_RUN:
		_press("swing", true)                               # corre por la fachada hasta la cornisa
		camera_rig.look_towards(RegulatedPendulum.flat(waypoint - p).normalized())
	else:
		_press("swing", false)
		if not _aim_and_tap():
			camera_rig.look_towards(RegulatedPendulum.flat(waypoint - p).normalized())
	_press("move_forward", true)
	var cycle := fmod(_t, 9.0)
	_press("dive", cycle > 6.0 and cycle < 7.0 and p.y > 45.0)
	if st == TraversalController.State.FALL and fmod(_t, 7.0) < 0.02 and player.velocity.y < 0.0:
		_tap("jump")                                        # web zip en el aire
	if st == TraversalController.State.FALL and fmod(_t + 3.0, 5.0) < 0.02:
		_tap("trick")


# --- hang: mantener el clic sin soltarlo -----------------------------------
func _hang() -> void:
	_swing_click(true)
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
	_stats["hang"] = {"still_on_web": sw, "webs_fired": _stats.events.get("web_fired", 0), "speed": snappedf(player.pendulum.speed, 0.01),
			"sustain": player.pendulum.sustain, "marks": _mark,
			"dist_to_anchor": snappedf(player.global_position.distance_to(_anchor), 0.01)}


# --- aim: la telaraña va donde apunta la mira ----------------------------------
## Un panel flotante sobre la ciudad da puntos de mira conocidos: disparo exacto,
## mantener el clic (no reengancha ni hace wall run), un clic nuevo dispara a lo
## apuntado, cono de asistencia y fallo con cielo o suelo.
const AIM_A := Vector3(0.0, 302.0, -36.0)     # punto apuntado en la cara delantera del panel
const AIM_B := Vector3(0.0, 300.0, -40.0)     # ídem en su cara trasera (el arco pasa por debajo)
const AIM_START := Vector3(0.0, 290.0, 0.0)


func _board(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	body.add_child(mesh)
	body.position = center
	main.add_child(body)


func _aim_start() -> void:
	_place(AIM_START, Vector3.FORWARD)
	player.state = TraversalController.State.FALL
	player.velocity = Vector3(0.0, 0.0, -2.0)


func _aim() -> void:
	var fired: int = _stats.events.get("web_fired", 0)
	# Clic mantenido por tramos: (1) primera telaraña hasta el salto, (4) clic nuevo, (5) asistida,
	# (7) desde un web zip.
	_press("swing", (_t > 0.6 and _t < 3.6) or (_t > 3.7 and _t < 5.5) or (_t > 7.4 and _t < 7.8)
			or (_t > 10.7 and _t < 12.0))
	if _at(0.02):
		_board(Vector3(0.0, 300.0, -38.0), Vector3(60.0, 40.0, 4.0))     # caras en z = -36 y -40
		_aim_start()
	# 1) Mirar al punto A y disparar: la telaraña debe clavarse justo ahí.
	if _t > 0.2 and _t < 1.5:
		camera_rig.aim_at(AIM_A)
	elif _t >= 1.5 and _t < 3.0:
		camera_rig.aim_at(AIM_B)            # mirar a otro lado no cambia la telaraña ya enganchada
	if _at(0.5):
		_mark["1_aim_exact"] = player.aim_exact
		_mark["1_aim_error_m"] = snappedf(player.aim_anchor.point.distance_to(AIM_A), 0.01) \
				if player.aim_anchor else -1.0
	if _at(0.9):
		_mark["1_state_after_click"] = hud._state_name()
		_mark["1_shot_error_m"] = snappedf(player.pendulum.anchor.distance_to(AIM_A), 0.01)
	# 2) Colgado con el clic mantenido y la mira en otro sitio: misma telaraña, sin wall run.
	if _at(2.9):
		_mark["2_same_anchor"] = player.pendulum.anchor.distance_to(AIM_A) < 1.5
		_mark["2_webs_fired"] = fired
		_mark["2_wall_run_s"] = _stats.substates.get("WALL RUN", 0.0)
		_mark["2_state"] = hud._state_name()
	# 3) Salto con el clic aún mantenido y un objetivo válido a la vista (la cara trasera
	#    del panel, tras cruzar por debajo): no reengancha.
	if _at(3.0):
		_tap("jump")
	if _t > 3.1 and _t < 5.5:
		camera_rig.aim_at(AIM_B)
		if player.aim_anchor and _t < 3.6:
			_mark["3_valid_aim_frames"] = _mark.get("3_valid_aim_frames", 0) + 1
	if _at(3.55):
		_mark["3_webs_fired_while_held"] = fired
		_mark["3_state"] = hud._state_name()
	# 4) Soltar y volver a pulsar: el clic nuevo dispara a lo apuntado (cara trasera).
	if _at(4.0):
		_mark["4_webs_fired"] = fired
		_mark["4_shot_error_m"] = snappedf(player.pendulum.anchor.distance_to(AIM_B), 0.01)
	# 5) Cono de asistencia: la mira pasa 6° por encima del borde del panel A.
	if _at(7.0):
		_aim_start()
	if _t > 7.0 and _t < 7.7:
		camera_rig.set_look(0.0, deg_to_rad(46.0))
	if _at(7.3):
		_mark["5_assist_found"] = player.aim_anchor != null
		_mark["5_assist_exact"] = player.aim_exact
		_mark["5_assist_y"] = snappedf(player.aim_anchor.point.y, 0.1) if player.aim_anchor else -1.0
	if _at(7.6):
		_mark["5_fired_on_assist"] = hud._state_name()
	# 6) Cielo y suelo: nada al alcance -> la web sale y se pierde.
	if _at(8.5):
		_aim_start()
	if _t > 8.5 and _t < 9.3:
		camera_rig.set_look(0.0, deg_to_rad(80.0))
	if _at(8.9):
		_mark["6_sky_target"] = player.aim_anchor != null
		_tap("swing")
	if _at(9.2):
		_mark["6_webs_fired"] = fired
		_mark["6_state"] = hud._state_name()
	if _at(9.5):
		_aim_start()
	if _t > 9.5 and _t < 10.3:
		camera_rig.set_look(0.0, deg_to_rad(-75.0))
	if _at(9.9):
		_mark["6_ground_target"] = player.aim_anchor != null
	# 7) Del web zip a un balanceo: un clic durante el zip suelta su web y engancha a la mira.
	if _at(10.5):
		_aim_start()
	if _t > 10.5 and _t < 11.5:
		camera_rig.aim_at(AIM_A)
	if _at(10.6):
		_tap("jump")
	if _at(10.65):
		_mark["7_state_zip"] = hud._state_name()
	if _at(11.2):
		_mark["7_state_after_click"] = hud._state_name()
		_mark["7_shot_error_m"] = snappedf(player.pendulum.anchor.distance_to(AIM_A), 0.01)
	_stats["aim"] = _mark


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
	# Colgarse: desde el aire (punto de reaparición), apuntar, clic y mantenerlo 10 s;
	# W para subir por la web al final.
	if _at(3.3):
		main.respawn()
	if _t > 3.4 and _t < 14.0:
		_swing_click(true)
	else:
		_press("swing", _t > 16.5 and _t < 19.5)
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


# --- sm2: movimientos de Spider-Man 2 y parkour ------------------------------
func _sm2() -> void:
	# 1) Loop de Loop: picada rápida y clic.
	if _at(0.02):
		_place(Vector3(0.0, 120.0, 60.0), Vector3.FORWARD)
		player.state = TraversalController.State.FALL
		player.velocity = Vector3(0.0, -8.0, -24.0)
	_press("dive", _t > 0.1 and _t < 2.2)
	# 2) Spider-Dash y 3) Spider-Jump en el aire.
	if _at(5.5):
		_place(Vector3(0.0, 150.0, 60.0), Vector3.FORWARD)
		player.state = TraversalController.State.FALL
		player.velocity = Vector3(0.0, 0.0, -15.0)
		player.spider_meter = 2.0
	if _at(5.7):
		_tap("spider_dash")
	if _at(6.6):
		_tap("spider_jump")
	if _at(6.7):
		_mark["meter_after"] = snappedf(player.spider_meter, 0.01)
	# 4) Vault: correr hacia un aire acondicionado de azotea.
	var units: Array[AABB] = main.city.roof_ac_units
	if _at(8.0) and not units.is_empty():
		var u := units[0]
		var c := u.get_center()
		_place(Vector3(c.x, u.position.y + 0.95, c.z + u.size.z * 0.5 + 5.0), Vector3.FORWARD)
		_mark["vault_target_h"] = snappedf(u.size.y, 0.01)
	_press("move_forward", (_t > 8.1 and _t < 9.5) or (_t > 10.1 and _t < 14.0))
	# 5) Salto de borde: esprintar hacia el borde de una azotea amplia.
	if _at(10.0):
		var roof := _open_roof()
		if not roof.is_empty():
			_place(Vector3(roof[0] + roof[2] * 0.5, roof[4] + 0.95, roof[1] + roof[3] * 0.5), Vector3.LEFT)
			_mark["ledge_roof_h"] = snappedf(roof[4], 0.1)
	if _t > 1.6 and _t < 5.0:
		_swing_click(true)                    # Loop de Loop: en la picada, apunta y clic
	else:
		_press("swing", _t > 10.1 and _t < 14.0)
	_stats["sm2"] = _mark


## Azotea sin obstáculos en la mitad oeste (para probar el salto de borde).
func _open_roof() -> Array:
	var city: CityBuilder = main.city
	for r: Array in city._roof_rects:
		if r[2] < 16.0 or r[3] < 12.0 or r[4] < 20.0 or r[4] > 70.0:
			continue
		var clear := true
		for u in city.roof_ac_units:
			if absf(u.get_center().z - (r[1] + r[3] * 0.5)) < 3.0 and u.get_center().x < r[0] + r[2] * 0.5 \
					and u.get_center().x > r[0] and absf(u.position.y - r[4]) < 0.1:
				clear = false
		if clear:
			return r
	return []


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
	if _t > 7.05 and _t < 13.0:
		_swing_click(true)
	else:
		_press("swing", false)
	_press("trick", _t > 7.3 and _t < 10.0)
	_stats["sling"] = _mark


## Detector de saltos bruscos: por hueso (y por la raíz visual) compara el giro de este
## paso con el anterior; una diferencia grande = cambio de velocidad angular casi instantáneo.
func _log_anim(delta: float) -> void:
	var body: Mannequin = player.get_node("VisualRoot").get_child(0)
	var nodes := {}
	for k: String in body._j:
		nodes[k] = (body._j[k] as Node3D).quaternion
	nodes["ROOT"] = Quaternion(player.get_node("VisualRoot").global_transform.basis.orthonormalized())
	if OS.has_environment("AP_ANIMLOG_SERIES") and _t > 1.5 and _t < 2.3:
		print("[series] t=%.3f kn_r=%.1f hip_r=%.1f ank_r=%.1f" % [_t, rad_to_deg((nodes["kn_r"] as Quaternion).get_angle()),
				rad_to_deg((nodes["hip_r"] as Quaternion).get_angle()), rad_to_deg((nodes["ank_r"] as Quaternion).get_angle())])
	for k: String in nodes:
		var q: Quaternion = nodes[k]
		if _alog_prev.has(k):
			var prev: Quaternion = _alog_prev[k][0]
			var step := prev.angle_to(q)
			var dstep: float = absf(step - float(_alog_prev[k][1]))
			if k == "pelvis" and dstep > 1.0 and OS.has_environment("AP_ANIMLOG"):
				print("[animlog-pelvis] t=%.2f step=%.1f° flip_t=%.3f turns=%.1f axis=%s style=%s trick=%.2f" % [_t,
						rad_to_deg(step), body._flip_t, body._flip_turns, body._flip_axis, body._flip_style, player.trick_timer])
			if dstep > (0.09 if k != "ROOT" else 0.05):
				_alog_events.append([snappedf(_t, 0.01), k, snappedf(rad_to_deg(dstep), 0.1), hud._state_name(),
						snappedf(rad_to_deg(step) / delta, 1.0)])
			_alog_prev[k] = [q, step]
		else:
			_alog_prev[k] = [q, 0.0]


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
