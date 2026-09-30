extends SceneTree
## Laboratorio de animación: renderiza hojas de contacto de cada movimiento sin la
## ciudad (rápido incluso con render por software) para revisar las posturas.
##
##   godot --path godot --rendering-driver opengl3 --fixed-fps 60 --resolution 640x640 \
##     --script res://demo/anim_lab.gd -- --case=swing --view=side --out=/ruta/swing.png
##
## Casos: idle, walk, run, sprint, swing, swing_fast, hang, climb, rise, fall, flip_tuck,
## flip_layout, flip_spread, flip_pike, dive, glide, glide_bank, dash, zip, perch,
## hero, soft_land, charge, wall_run, crawl, slingshot, vault.
## Vistas: side (desde la derecha del personaje), front, back, three (3/4).
## Opciones: --frames=8 --dur=1.2 (s entre la primera y la última captura)
## --warm=0.6 (s de ajuste antes de capturar) --tile=320x400.

var c: TraversalController
var body: Mannequin
var anim: TraversalAnimator
var visual: Node3D
var cam: Camera3D
var wall: MeshInstance3D
var args := {}
var _update: Callable
var _flip_started := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_build_world()
	_run.call_deferred()


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.7, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.7)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	root.add_child(sun)

	var grid := Shader.new()
	grid.code = """shader_type spatial;
void fragment() {
	vec2 p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec2 g = abs(fract(p - 0.5) - 0.5) / fwidth(p);
	float l = 1.0 - min(min(g.x, g.y), 1.0);
	ALBEDO = mix(vec3(0.42, 0.45, 0.5), vec3(0.2, 0.22, 0.26), l);
	ROUGHNESS = 0.9;
}"""
	var gm := ShaderMaterial.new()
	gm.shader = grid
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = gm
	root.add_child(ground)
	wall = MeshInstance3D.new()
	var wm := PlaneMesh.new()
	wm.size = Vector2(12.0, 12.0)
	wall.mesh = wm
	wall.material_override = gm
	wall.visible = false
	root.add_child(wall)

	c = TraversalController.new()
	c.tuning = SwingTuning.new()
	c.position = Vector3(0.0, 0.9, 0.0)
	c.process_mode = Node.PROCESS_MODE_DISABLED        # solo lleva los datos del estado
	root.add_child(c)
	visual = Node3D.new()
	visual.process_mode = Node.PROCESS_MODE_ALWAYS
	c.add_child(visual)
	body = Mannequin.new()
	body.controller = c
	visual.add_child(body)
	var web_mat := StandardMaterial3D.new()
	web_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	web_mat.vertex_color_use_as_albedo = true
	web_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var webs: Array[WebLine] = []
	for i in 2:
		var web := WebLine.new()
		web.material = web_mat
		web.process_mode = Node.PROCESS_MODE_ALWAYS
		root.add_child(web)
		webs.append(web)
	anim = TraversalAnimator.new()
	anim.process_mode = Node.PROCESS_MODE_ALWAYS
	anim.controller = c
	anim.visual_root = visual
	anim.web_line = webs[0]
	anim.web_line_alt = webs[1]
	anim.hand_socket_left = body.hand_socket_left
	anim.hand_socket_right = body.hand_socket_right
	c.add_child(anim)
	cam = Camera3D.new()
	cam.fov = 38.0
	root.add_child(cam)
	cam.make_current()


func _put_state(state: TraversalController.State, vel: Vector3) -> void:
	c.state = state
	c.velocity = vel
	var flat := RegulatedPendulum.flat(vel)
	if flat.length() > 0.5:
		c.travel_dir = flat.normalized()


func _setup(case_name: String) -> void:
	c.travel_dir = Vector3.BACK
	c.hand = TraversalController.HAND_RIGHT
	var P := TraversalController.State
	match case_name:
		"idle":
			_update = func(_t: float) -> void: _put_state(P.GROUNDED, Vector3.ZERO)
		"walk", "run", "sprint":
			var sp: float = {"walk": 2.5, "run": 10.0, "sprint": 18.0}[case_name]
			_update = func(_t: float) -> void:
				_put_state(P.GROUNDED, Vector3(0.0, 0.0, sp))
				c.sprinting = case_name == "sprint"
		"swing", "swing_fast":
			var v0 := 22.0 if case_name == "swing" else 34.0
			c.pendulum.active = true
			_update = func(t: float) -> void:
				var ph := clampf(maxf(t, 0.0) / float(args.get("dur", "1.2")) * 2.0 - 1.0, -1.0, 1.0)
				var th := deg_to_rad(-ph * 55.0)
				var L := 14.0
				c.pendulum.anchor = c.global_position + Vector3(0.0, cos(th), sin(th)) * L
				c.pendulum.phase = ph
				c.pendulum.g_force = 1.0 + 4.5 * (1.0 - absf(ph))
				c.pendulum.speed = v0 * (0.75 + 0.25 * (1.0 - absf(ph)))
				c.state_time = t + 0.3
				_put_state(P.SWING, Vector3(0.0, -sin(th), cos(th)) * c.pendulum.speed)
		"hang", "climb":
			c.pendulum.active = true
			c.pendulum.sustain = true
			_update = func(t: float) -> void:
				c.pendulum.anchor = c.global_position + Vector3(0.0, 8.0, 0.3)
				c.pendulum.speed = 0.2
				c.move_input = Vector2(0.0, -1.0) if case_name == "climb" else Vector2.ZERO
				_put_state(P.SWING, Vector3(0.0, 0.0, 0.3))
		"rise", "fall":
			_update = func(t: float) -> void:
				var tt := maxf(t, 0.0)
				var vy := 12.0 - tt * 12.0 if case_name == "rise" else -8.0 - tt * 22.0
				_put_state(P.FALL, Vector3(0.0, vy, 16.0))
		"flip_tuck", "flip_layout", "flip_spread", "flip_pike":
			var style := case_name.trim_prefix("flip_")
			var axis := Vector3.RIGHT if style != "spread" else Vector3.UP
			_update = func(t: float) -> void:
				_put_state(P.FALL, Vector3(0.0, 4.0, 18.0))
				if t >= 0.0 and not _flip_started:
					_flip_started = true
					body.start_flip(axis, 1.0, float(args.get("dur", "1.2")), style)
		"dive":
			_update = func(_t: float) -> void: _put_state(P.DIVE, Vector3(0.0, -45.0, 12.0))
		"glide", "glide_bank":
			_update = func(t: float) -> void:
				_put_state(P.GLIDE, Vector3(0.0, -3.0, 28.0))
				c.wings.bank = deg_to_rad(40.0) * sin(t * 3.0) if case_name == "glide_bank" else 0.0
		"dash":
			_update = func(_t: float) -> void:
				_put_state(P.FALL, Vector3(0.0, 1.0, 36.0))
				c.dash_timer = 0.3
		"zip":
			_update = func(_t: float) -> void: _put_state(P.WEB_ZIP, Vector3(0.0, 3.0, 28.0))
			c.web_fired.emit(TraversalController.HAND_BOTH, Vector3(0.0, 8.0, 30.0))
		"perch":
			c.position = Vector3(0.0, 0.95, 0.0)
			_update = func(_t: float) -> void: _put_state(P.PERCH, Vector3.ZERO)
		"hero":
			_update = func(t: float) -> void:
				_put_state(P.GROUNDED, Vector3.ZERO)
				c.land_kind = "hero"
				c.land_timer = maxf(0.7 - maxf(t, 0.0), 0.02)
		"soft_land":
			_update = func(t: float) -> void:
				_put_state(P.GROUNDED, Vector3.ZERO)
				c.land_kind = "soft"
				c.land_timer = clampf(0.25 - maxf(t, 0.0) * 0.25, 0.0, 0.25)
		"charge":
			_update = func(t: float) -> void:
				_put_state(P.GROUNDED, Vector3.ZERO)
				c.jump_charge = clampf(t, 0.0, 1.0)
		"wall_run":
			wall.visible = true
			wall.position = Vector3(0.0, 0.9, -0.4)
			wall.rotation_degrees = Vector3(90.0, 0.0, 0.0)
			_update = func(_t: float) -> void:
				c.wall_normal = Vector3.BACK
				c.wall_vertical = true
				c.wall_crawl = false
				_put_state(P.WALL_RUN, Vector3(0.0, 16.0, 0.0))
		"crawl":
			wall.visible = true
			wall.position = Vector3(0.0, 0.9, -0.4)
			wall.rotation_degrees = Vector3(90.0, 0.0, 0.0)
			_update = func(_t: float) -> void:
				c.wall_normal = Vector3.BACK
				c.wall_crawl = true
				_put_state(P.WALL_RUN, Vector3(0.0, 3.0, 0.0))
		"slingshot":
			c.slingshot_aim = Vector3.BACK
			c.slingshot_anchors = [Vector3(6.0, 6.0, 14.0), Vector3(-6.0, 6.0, 14.0)]
			_update = func(t: float) -> void:
				_put_state(P.SLINGSHOT, Vector3.ZERO)
				c.slingshot_charge = clampf(t, 0.0, 1.0)
		"vault":
			c.vault_hand_point = Vector3(0.0, 1.1, 0.6)
			c._vault_time = 0.4
			_update = func(t: float) -> void:
				_put_state(P.VAULT, Vector3(0.0, 0.0, 9.0))
				c.state_time = fmod(maxf(t, 0.0), 0.4)
		_:
			push_error("caso desconocido: " + case_name)
			_update = func(_t: float) -> void: pass


func _place_camera(view: String) -> void:
	var target := Vector3(0.0, 1.0, 0.0)
	var dist := float(args.get("dist", "5.2"))
	var dir := Vector3.RIGHT
	match view:
		"side":
			dir = Vector3(-1.0, 0.12, 0.0)        # desde la derecha del personaje (-X)
		"front":
			dir = Vector3(0.0, 0.12, 1.0)
		"back":
			dir = Vector3(0.0, 0.25, -1.0)
		"chase":
			dir = Vector3(0.0, 0.4, -1.0)             # como la cámara del juego: detrás y arriba
			cam.fov = 70.0
			dist = float(args.get("dist", "4.6"))
		"top":
			dir = Vector3(-0.15, 1.0, 0.1)
		_:
			dir = Vector3(-0.8, 0.3, 0.7)
	cam.position = target + dir.normalized() * dist
	cam.look_at(target, Vector3.UP if view != "top" else Vector3.BACK)


func _run() -> void:
	var case_name: String = args.get("case", "idle")
	var view: String = args.get("view", "three")
	var frames := int(args.get("frames", "8"))
	var dur := float(args.get("dur", "1.2"))
	var warm := float(args.get("warm", "0.6"))
	var tile_s: PackedStringArray = String(args.get("tile", "320x400")).split("x")
	var tile := Vector2i(int(tile_s[0]), int(tile_s[1]))
	await process_frame
	_setup(case_name)
	_place_camera(view)
	var sheet := Image.create(tile.x * frames, tile.y, false, Image.FORMAT_RGB8)
	var dt := 1.0 / 60.0
	var t := -warm
	var next_cap := 0.0
	var idx := 0
	while idx < frames:
		_update.call(t)
		await process_frame
		t += dt
		if t >= next_cap - 1e-6:
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			var sz := img.get_size()
			var ar := float(tile.x) / tile.y
			var crop := Vector2i(mini(sz.x, int(sz.y * ar)), sz.y)
			var sub := img.get_region(Rect2i((sz.x - crop.x) / 2, 0, crop.x, crop.y))
			sub.resize(tile.x, tile.y, Image.INTERPOLATE_BILINEAR)
			sheet.blit_rect(sub, Rect2i(Vector2i.ZERO, tile), Vector2i(idx * tile.x, 0))
			idx += 1
			next_cap += dur / maxf(frames - 1, 1)
	var out: String = args.get("out", "user://anim_lab.png")
	sheet.save_png(out)
	print("[anim_lab] ", case_name, " -> ", out)
	quit()
