class_name DemoHud
extends CanvasLayer
## HUD de la demo: velocidad, estado, fuerza G, aviso de suelta perfecta,
## retícula del punto de posado (Point Launch) y ayuda de controles.

const STATE_NAMES := [
	"SUELO", "CAÍDA", "PICADA", "BALANCEO", "WEB ZIP", "POINT ZIP", "POSADO", "WALL RUN",
	"PLANEO", "SLINGSHOT", "VAULT",
]
## Controles: siempre a la vista en una franja compacta abajo (H la oculta/muestra).
const CONTROLS := [
	["Clic izq · RT", "Web a la mira · mantén = columpio"],
	["Espacio · A", "Salto · en el aire: web zip"],
	["WASD · Stick", "Moverte · colgado: subir/bajar"],
	["Mayús · B", "Picada · + clic: Loop de Loop"],
	["Q · LT", "Point zip · + Espacio: Slingshot"],
	["G · Y", "Alas: planear (ratón = girar)"],
	["F · LB", "Truco en el aire"],
	["E · X", "Web zip"],
	["C · R3", "Spider-Dash"],
	["V · L3", "Spider-Jump"],
	["R · Back", "Reaparecer"],
	["H · Start", "Ocultar esta ayuda"],
]

var controller: TraversalController
var camera_rig: CameraRig

var _stats: Label
var _banner: Label
var _help: PanelContainer
var _reticle: Control
var _banner_time := 0.0
var _perch: Variant = null


func _ready() -> void:
	layer = 2
	_stats = _label(18, Vector2(20, 14))
	_banner = _label(40, Vector2.ZERO)
	_banner.anchor_right = 1.0
	_banner.offset_top = 140.0
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_help = _build_controls()
	_reticle = Control.new()
	_reticle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.draw.connect(_draw_reticle)
	add_child(_reticle)
	controller.web_released.connect(_on_web_released)
	controller.quick_recovered.connect(func() -> void: _show_banner("QUICK RECOVERY"))
	controller.corner_turned.connect(func(launched: bool) -> void:
		_show_banner("CORNER LAUNCH" if launched else "GIRO DE ESQUINA"))
	controller.point_launched.connect(func(perfect: bool) -> void:
		if perfect:
			_show_banner("¡POINT LAUNCH PERFECTO!"))
	controller.looped.connect(func(n: int) -> void:
		_show_banner("¡LOOP!" if n == 1 else "¡LOOP x%d!" % n))
	controller.wings_opened.connect(func(boosted: bool) -> void:
		if boosted:
			_show_banner("¡WEB WINGS AL LÍMITE!"))
	controller.loop_boosted.connect(func() -> void: _show_banner("¡LOOP DE LOOP!"))
	controller.slingshot_launched.connect(func(c: float) -> void:
		_show_banner("SUPER SLINGSHOT" if c < 0.95 else "¡SUPER SLINGSHOT MÁXIMO!"))


func set_help_visible(v: bool) -> void:
	_help.visible = v


## Franja de controles: 3 parejas "tecla · acción" por fila, texto pequeño sobre un
## fondo translúcido en la esquina inferior izquierda (~70 px de alto).
func _build_controls() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 5.0
	style.content_margin_bottom = 5.0
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 1)
	panel.add_child(grid)
	for pair: Array in CONTROLS:
		for i in 2:
			var l := Label.new()
			l.text = pair[i]
			l.add_theme_font_size_override("font_size", 13)
			l.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3) if i == 0 else Color(1, 1, 1, 0.92))
			l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			l.add_theme_constant_override("outline_size", 3)
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			grid.add_child(l)
	add_child(panel)
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12.0
	panel.offset_bottom = -10.0
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	return panel


func _label(size: int, pos: Vector2) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _show_banner(text: String) -> void:
	_banner.text = text
	_banner_time = 1.1


func _on_web_released(_hand: int, perfect: bool) -> void:
	if perfect and not controller.last_release_chained:
		_show_banner("¡SUELTA PERFECTA!")


func _process(delta: float) -> void:
	var c := controller
	var kmh := c.velocity.length() * 3.6
	var g := c.pendulum.g_force if c.state == TraversalController.State.SWING else 1.0
	_stats.text = "%3d km/h   %s   %.1f G   altura %d m" % [int(kmh), _state_name(), g,
			int(c.global_position.y)]
	_banner_time = maxf(_banner_time - delta, 0.0)
	_banner.modulate.a = clampf(_banner_time / 0.4, 0.0, 1.0)
	if Input.is_action_just_pressed("toggle_help"):
		_help.visible = not _help.visible

	_perch = null
	if c.anchor_finder and c.state in [TraversalController.State.FALL, TraversalController.State.DIVE,
			TraversalController.State.GROUNDED, TraversalController.State.WALL_RUN,
			TraversalController.State.SWING, TraversalController.State.GLIDE]:
		var aim := -camera_rig.camera.global_transform.basis.z
		_perch = c.anchor_finder.find_perch(c.global_position, aim, 45.0)
	_reticle.queue_redraw()


func _state_name() -> String:
	var c := controller
	match c.state:
		TraversalController.State.SWING:
			if c.pendulum.sustain and c.pendulum.speed < 6.0:
				return "COLGADO"
		TraversalController.State.WALL_RUN:
			if c.wall_crawl:
				return "TREPANDO"
		TraversalController.State.GLIDE:
			if c.wings.stalled:
				return "PLANEO · PÉRDIDA"
			if c.in_tunnel > 0.3:
				return "PLANEO · TÚNEL"
			if c.in_updraft > 0.3:
				return "PLANEO · CORRIENTE"
		TraversalController.State.SLINGSHOT:
			return "SLINGSHOT %d%%" % int(c.slingshot_charge * 100.0)
		TraversalController.State.GROUNDED:
			if c.jump_charge > 0.0:
				return "CARGANDO SALTO %d%%" % int(c.jump_charge * 100.0)
			if c.sprinting:
				return "SPRINT"
	return STATE_NAMES[c.state]


func _draw_reticle() -> void:
	var cam := camera_rig.camera
	var center := _reticle.size * 0.5
	# Mira: anillo que se ilumina cuando hay un anclaje al alcance; el marcador señala el
	# punto exacto donde se clavará la telaraña (anillo sólido = justo donde apuntas;
	# con una línea hasta la mira = punto cercano elegido por la asistencia).
	var anchor := controller.aim_anchor
	var locked := anchor != null and not cam.is_position_behind(anchor.point)
	var aim_col := Color(0.55, 0.92, 1.0, 0.95) if locked else Color(1, 1, 1, 0.4)
	_reticle.draw_arc(center, 7.0, 0.0, TAU, 24, aim_col, 1.5)
	_reticle.draw_circle(center, 1.8, aim_col)
	if locked:
		var ap := cam.unproject_position(anchor.point)
		if not controller.aim_exact:
			_reticle.draw_line(center, ap, Color(aim_col, 0.35), 1.0)
		_reticle.draw_arc(ap, 10.0, 0.0, TAU, 24, aim_col, 2.0)
		_reticle.draw_circle(ap, 3.0, aim_col)
	# Medidor de Spider-Dash / Spider-Jump: una barra por carga, bajo los datos
	# de arriba a la izquierda (la franja de controles ocupa la parte de abajo).
	var charges := int(controller.tuning.spider_meter_charges)
	var bw := 56.0
	var y := 44.0
	for i in charges:
		var x0 := 22.0 + i * (bw + 6.0)
		var fill := clampf(controller.spider_meter - i, 0.0, 1.0)
		_reticle.draw_rect(Rect2(x0, y, bw, 6.0), Color(0, 0, 0, 0.45))
		var col := Color(0.95, 0.2, 0.2, 0.95) if fill >= 1.0 else Color(0.8, 0.8, 0.85, 0.6)
		_reticle.draw_rect(Rect2(x0, y, bw * fill, 6.0), col)
	if _perch == null or cam.is_position_behind(_perch):
		return
	var p := cam.unproject_position(_perch)
	var pulse := 14.0 + sin(Time.get_ticks_msec() * 0.008) * 3.0
	_reticle.draw_arc(p, pulse, 0.0, TAU, 32, Color(1.0, 0.85, 0.2, 0.95), 3.0)
	_reticle.draw_circle(p, 3.5, Color(1.0, 0.85, 0.2, 0.95))
