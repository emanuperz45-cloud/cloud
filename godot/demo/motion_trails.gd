class_name MotionTrails
extends MeshInstance3D
## Estelas de movimiento en manos y pies: cintas finas orientadas a cámara que
## aparecen al ir rápido (swing, planeo, picada, zips) y se desvanecen en ~0,2 s.
## Venden el desplazamiento sin ensuciar la silueta. Se muestrean en _process con
## la posición interpolada para que no tiemblen a más de 60 fps.

@export var life := 0.2
@export var width := 0.06
@export var min_speed := 16.0          ## por debajo no hay estelas
@export var full_speed := 36.0

var controller: TraversalController
var sockets: Array[Node3D] = []

var _hist: Array[Array] = []           ## por socket: [[pos, t], ...] del más nuevo al más viejo
var _clock := 0.0
var _strength := 0.0
var _imesh := ImmediateMesh.new()


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	global_transform = Transform3D.IDENTITY
	mesh = _imesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	material_override = mat
	for i in sockets.size():
		_hist.append([])


func _process(delta: float) -> void:
	_clock += delta
	var c := controller
	var moving := c.state in [TraversalController.State.SWING, TraversalController.State.GLIDE,
			TraversalController.State.DIVE, TraversalController.State.WEB_ZIP,
			TraversalController.State.POINT_ZIP, TraversalController.State.FALL]
	var target := 0.0
	if moving:
		target = clampf((c.velocity.length() - min_speed) / (full_speed - min_speed), 0.0, 1.0)
	_strength = move_toward(_strength, target, delta * 3.0)
	_imesh.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	for i in sockets.size():
		var h: Array = _hist[i]
		var p := sockets[i].get_global_transform_interpolated().origin
		if not h.is_empty() and (h[0][0] as Vector3).distance_to(p) > 8.0:
			h.clear()                      # teletransporte (reaparecer): sin cinta larga
		h.push_front([p, _clock])
		while h.size() > 2 and _clock - float(h[h.size() - 1][1]) > life:
			h.pop_back()
		if _strength > 0.01 and h.size() >= 3 and cam:
			_ribbon(h, cam)


func _ribbon(h: Array, cam: Camera3D) -> void:
	var n := h.size()
	_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for j in n:
		var p: Vector3 = h[j][0]
		var age := clampf((_clock - float(h[j][1])) / life, 0.0, 1.0)
		var prv: Vector3 = h[maxi(j - 1, 0)][0]
		var nxt: Vector3 = h[mini(j + 1, n - 1)][0]
		var tangent := prv - nxt
		if tangent.length_squared() < 1e-10:
			tangent = Vector3.UP
		var side := tangent.cross(cam.global_position - p).normalized() * (width * 0.5 * (1.0 - age))
		var col := Color(0.88, 0.94, 1.0, (1.0 - age) * (1.0 - age) * _strength * 0.5)
		_imesh.surface_set_color(col)
		_imesh.surface_add_vertex(p - side)
		_imesh.surface_set_color(col)
		_imesh.surface_add_vertex(p + side)
	_imesh.surface_end()
