extends Node3D
## Demo jugable: ciudad procedural + personaje con el sistema de balanceo.
##
## Arma todo por código (entorno, ciudad, jugador, cámara, HUD) para que la
## escena no dependa de assets importados. Argumentos de línea de comandos
## (después de `--`), usados para probar builds sin interfaz:
##   --autopilot=SEGUNDOS [--scenario=tour|hang|moves] [--shots=t1,t2 --shot-prefix=RUTA]
## (ver demo/autopilot.gd).

const CITY_SEED := 20180907
const SPAWN := Vector3(0.0, 75.0, 40.0)

var player: TraversalController
var camera_rig: CameraRig
var hud: DemoHud

var _autopilot := -1.0
var _scenario := "tour"
var _shots: Array[float] = []
var _shot_prefix := ""
var _bounds := INF


func _ready() -> void:
	DemoInput.setup()
	_parse_args()
	_build_environment()
	var city := CityBuilder.new()
	city.name = "City"
	add_child(city)
	city.build(CITY_SEED)
	_build_player()
	camera_rig = CameraRig.new()
	camera_rig.target = player
	add_child(camera_rig)
	player.camera = camera_rig.camera          # el input direccional es relativo a la cámara
	_bounds = city.blocks * city.pitch + 150.0
	hud = DemoHud.new()
	hud.controller = player
	hud.camera_rig = camera_rig
	add_child(hud)
	get_window().title = "Web Swing Demo — %d edificios" % city.building_count
	if _autopilot < 0.0:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		var pilot := DemoAutopilot.new()
		pilot.main = self
		pilot.player = player
		pilot.camera_rig = camera_rig
		pilot.hud = hud
		pilot.duration = _autopilot
		pilot.scenario = _scenario
		pilot.shots = _shots
		pilot.shot_prefix = _shot_prefix
		add_child(pilot)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--autopilot="):
			_autopilot = value.to_float()
		elif arg.begins_with("--scenario="):
			_scenario = value
		elif arg.begins_with("--shots="):
			for t in value.split(","):
				_shots.append(t.to_float())
		elif arg.begins_with("--shot-prefix="):
			_shot_prefix = value


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.42, 0.72)
	sky_mat.sky_horizon_color = Color(0.72, 0.8, 0.9)
	sky_mat.ground_horizon_color = Color(0.6, 0.65, 0.7)
	sky_mat.ground_bottom_color = Color(0.2, 0.22, 0.25)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.68, 0.76, 0.86)
	env.fog_density = 0.0012
	env.fog_aerial_perspective = 0.4
	env.glow_enabled = true
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 320.0
	add_child(sun)


func _build_player() -> void:
	player = TraversalController.new()
	player.name = "Player"
	player.tuning = SwingTuning.new()
	player.collision_layer = 2
	player.collision_mask = 1
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	shape.shape = capsule
	player.add_child(shape)
	var finder := AnchorFinder.new()
	finder.name = "AnchorFinder"
	finder.swingable_mask = 1
	player.add_child(finder)
	player.anchor_finder = finder
	player.position = SPAWN
	add_child(player)
	player.velocity = Vector3(0.0, 0.0, -12.0)

	var visual := Node3D.new()
	visual.name = "VisualRoot"
	player.add_child(visual)
	var body := Mannequin.new()
	body.controller = player
	visual.add_child(body)

	var web_mat := StandardMaterial3D.new()
	web_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	web_mat.vertex_color_use_as_albedo = true
	web_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	web_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var webs: Array[WebLine] = []
	for i in 2:
		var web := WebLine.new()
		web.material = web_mat
		add_child(web)
		webs.append(web)

	var animator := TraversalAnimator.new()
	animator.controller = player
	animator.visual_root = visual
	animator.web_line = webs[0]
	animator.web_line_alt = webs[1]
	animator.hand_socket_left = body.hand_socket_left
	animator.hand_socket_right = body.hand_socket_right
	player.add_child(animator)


func respawn() -> void:
	player.global_position = SPAWN
	player.velocity = Vector3(0.0, 0.0, -12.0)
	player.travel_dir = Vector3.FORWARD
	player.pendulum.active = false
	player.state = TraversalController.State.FALL
	player.state_time = 0.0
	player.reset_physics_interpolation()
	camera_rig.snap()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and _autopilot < 0.0:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(_delta: float) -> void:
	var p := player.global_position
	var outside := maxf(absf(p.x), absf(p.z)) > _bounds
	if Input.is_action_just_pressed("respawn") or p.y < -30.0 or outside or not p.is_finite():
		respawn()
