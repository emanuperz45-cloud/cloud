class_name DemoHud
extends CanvasLayer
## HUD de la demo: velocidad, estado, fuerza G, aviso de suelta perfecta,
## retícula del punto de posado (Point Launch) y ayuda de controles.

const STATE_NAMES := [
	"SUELO", "CAÍDA", "PICADA", "BALANCEO", "WEB ZIP", "POINT ZIP", "POSADO", "WALL RUN",
]
const HELP := """\
CLIC IZQ / R2 mantenido: balanceo en la misma telaraña (si no sueltas, te quedas colgado)
   colgado: W/S subir o bajar por la telaraña · suelta el clic para caer
ESPACIO / A: en el balanceo salta (abajo = adelante, al final = arriba) · en el aire = Web Zip
   en el suelo: mantén para Charge Jump · al rodar tras aterrizar = Quick Recovery
SUELO: clic mantenido = sprint (contra una fachada sube corriendo) · salta con clic = telaraña
PARED: con clic corres, sin clic trepas · ESPACIO tira hacia arriba o salta de la pared
MAYÚS / B: picada · en una esquina corriendo, gira la esquina con una telaraña
Q, CLIC DER / L2: point zip al punto amarillo, ESPACIO al llegar = Point Launch
F / Y + dirección: trucos · R: reaparecer · ESC: ratón · H: ocultar ayuda"""

var controller: TraversalController
var camera_rig: CameraRig

var _stats: Label
var _banner: Label
var _help: Label
var _reticle: Control
var _banner_time := 0.0
var _perch: Variant = null


func _ready() -> void:
	_stats = _label(22, Vector2(24, 20))
	_banner = _label(40, Vector2.ZERO)
	_banner.anchor_right = 1.0
	_banner.offset_top = 140.0
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_help = _label(17, Vector2.ZERO)
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.offset_left = 24.0
	_help.offset_top = -320.0
	_help.offset_bottom = -16.0
	_help.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_help.text = HELP
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


func set_help_visible(v: bool) -> void:
	_help.visible = v


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
			TraversalController.State.SWING]:
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
		TraversalController.State.GROUNDED:
			if c.jump_charge > 0.0:
				return "CARGANDO SALTO %d%%" % int(c.jump_charge * 100.0)
			if c.sprinting:
				return "SPRINT"
	return STATE_NAMES[c.state]


func _draw_reticle() -> void:
	var cam := camera_rig.camera
	var center := _reticle.size * 0.5
	_reticle.draw_circle(center, 2.5, Color(1, 1, 1, 0.6))
	if _perch == null or cam.is_position_behind(_perch):
		return
	var p := cam.unproject_position(_perch)
	var pulse := 14.0 + sin(Time.get_ticks_msec() * 0.008) * 3.0
	_reticle.draw_arc(p, pulse, 0.0, TAU, 32, Color(1.0, 0.85, 0.2, 0.95), 3.0)
	_reticle.draw_circle(p, 3.5, Color(1.0, 0.85, 0.2, 0.95))
