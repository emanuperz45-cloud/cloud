class_name CityBuilder
extends Node3D
## Ciudad procedural en rejilla (estilo Manhattan) para probar el balanceo.
##
## Calles centradas en múltiplos de `pitch` en X y Z. Cada manzana se divide en
## solares con alturas aleatorias (más altas en el centro). Todo se dibuja con
## un único MultiMesh y cada edificio tiene su BoxShape3D en la capa World, que
## es la que barre AnchorFinder. Las esquinas de algunas azoteas generan puntos
## de posado (grupo "perch_points") para el Point Launch.
## Para las Web Wings añade túneles de viento sobre las avenidas (anillos azules +
## rayas que fluyen) y corrientes ascendentes sobre azoteas (columnas con rejilla).

const BUILDING_SHADER := preload("res://demo/building.gdshader")
const GROUND_SHADER := preload("res://demo/ground.gdshader")
const WIND_SHADER := preload("res://demo/wind.gdshader")
## Túneles de viento: [inicio, fin] sobre las avenidas (x o z múltiplo de pitch).
const TUNNELS := [
	[Vector3(0.0, 85.0, 260.0), Vector3(0.0, 64.0, -420.0)],
	[Vector3(-420.0, 96.0, -168.0), Vector3(420.0, 74.0, -168.0)],
	[Vector3(252.0, 58.0, -300.0), Vector3(252.0, 104.0, 420.0)],
	[Vector3(420.0, 72.0, 252.0), Vector3(-420.0, 92.0, 252.0)],
	[Vector3(-336.0, 112.0, 420.0), Vector3(-336.0, 70.0, -420.0)],
]
const TUNNEL_RADIUS := 8.0
const UPDRAFT_COUNT := 14
const PALETTE := [
	Color(0.62, 0.6, 0.56), Color(0.5, 0.52, 0.55), Color(0.66, 0.55, 0.45),
	Color(0.42, 0.45, 0.5), Color(0.72, 0.7, 0.66), Color(0.55, 0.42, 0.36),
]

@export var blocks := 8
@export var block_size := 60.0
@export var street_width := 24.0

var pitch: float:
	get:
		return block_size + street_width

var building_count := 0
var wind_field := WindField.new()
var _roofs: Array[Vector4] = []      ## (x centro, altura, z centro, lado menor)
var _body: StaticBody3D
var _transforms: Array[Transform3D] = []
var _colors: Array[Color] = []
var _rng := RandomNumberGenerator.new()


func build(seed_value: int) -> void:
	_rng.seed = seed_value
	_body = StaticBody3D.new()
	_body.name = "CityCollision"
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)
	_build_ground()

	var half := blocks * pitch
	for bx in range(-blocks, blocks):
		for bz in range(-blocks, blocks):
			var x0 := bx * pitch + street_width * 0.5
			var z0 := bz * pitch + street_width * 0.5
			var center := Vector2(x0 + block_size * 0.5, z0 + block_size * 0.5)
			var downtown := clampf(1.0 - center.length() / half, 0.0, 1.0)
			_build_block(x0, z0, downtown)
	_build_multimesh()
	_build_wind(seed_value)


func _build_ground() -> void:
	var size := blocks * pitch * 2.0 + 800.0
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(size, size)
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	mat.set_shader_parameter("pitch", pitch)
	mat.set_shader_parameter("street", street_width)
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Ground"
	add_child(mi)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 2.0, size)
	shape.shape = box
	shape.position = Vector3(0.0, -1.0, 0.0)
	_body.add_child(shape)


func _build_block(x0: float, z0: float, downtown: float) -> void:
	if _rng.randf() < 0.1:
		return                                   # plaza abierta: obliga a planear/zip
	if _rng.randf() < 0.15 + downtown * 0.2:
		# Torre que ocupa la manzana entera.
		_add_building(x0 + 2.0, z0 + 2.0, block_size - 4.0, block_size - 4.0,
				_height(downtown) * 1.35)
		return
	var lot := block_size * 0.5
	for ix in 2:
		for iz in 2:
			var inset := _rng.randf_range(1.0, 4.5)
			_add_building(x0 + ix * lot + inset, z0 + iz * lot + inset,
					lot - inset * 2.0 + _rng.randf_range(0.0, 2.0),
					lot - inset * 2.0 + _rng.randf_range(0.0, 2.0), _height(downtown))


func _height(downtown: float) -> float:
	var r := _rng.randf()
	var h := 0.0
	if r < 0.35:
		h = _rng.randf_range(18.0, 40.0)
	elif r < 0.8:
		h = _rng.randf_range(40.0, 95.0)
	else:
		h = _rng.randf_range(95.0, 170.0)
	return h * lerpf(0.75, 1.3, downtown)


func _add_building(x: float, z: float, sx: float, sz: float, h: float) -> void:
	var center := Vector3(x + sx * 0.5, h * 0.5, z + sz * 0.5)
	_transforms.append(Transform3D(Basis.from_scale(Vector3(sx, h, sz)), center))
	var base: Color = PALETTE[_rng.randi() % PALETTE.size()]
	_colors.append(base * _rng.randf_range(0.85, 1.1))

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(sx, h, sz)
	shape.shape = box
	shape.position = center
	_body.add_child(shape)
	building_count += 1
	_roofs.append(Vector4(center.x, h, center.z, minf(sx, sz)))

	# Puntos de posado en esquinas de azotea (dentro del borde, de pie sobre el tejado).
	if h > 25.0 and _rng.randf() < 0.55:
		var corner_x := x + (0.7 if _rng.randf() < 0.5 else sx - 0.7)
		var corner_z := z + (0.7 if _rng.randf() < 0.5 else sz - 0.7)
		var perch := Marker3D.new()
		perch.position = Vector3(corner_x, h + 0.95, corner_z)
		perch.add_to_group("perch_points")
		add_child(perch)


func _build_multimesh() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = BoxMesh.new()
	mm.instance_count = _transforms.size()
	for i in _transforms.size():
		mm.set_instance_transform(i, _transforms[i])
		mm.set_instance_color(i, _colors[i])
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_SHADER
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Buildings"
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)


# ---------------------------------------------------------------------------
# Viento para las Web Wings
# ---------------------------------------------------------------------------
func _build_wind(seed_value: int) -> void:
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.albedo_color = Color(0.3, 0.65, 1.0, 0.55)
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring_mat.disable_fog = true           # aditivo + niebla = banda blanca a lo lejos
	ring_mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	ring_mat.distance_fade_min_distance = 420.0
	ring_mat.distance_fade_max_distance = 60.0
	var ring_xf: Array[Transform3D] = []
	for t: Array in TUNNELS:
		var a: Vector3 = t[0]
		var b: Vector3 = t[1]
		wind_field.add_tunnel(a, b, TUNNEL_RADIUS)
		var axis := (b - a).normalized()
		var basis := _basis_y(axis)
		var length := a.distance_to(b)
		_wind_tube((a + b) * 0.5, basis, TUNNEL_RADIUS * 0.9, length,
				Color(0.35, 0.72, 1.0), 24.0, 0.5)
		var n := int(length / 30.0)
		for i in range(1, n):
			ring_xf.append(Transform3D(basis, a + axis * (float(i) * length / float(n))))

	# Corrientes ascendentes sobre azoteas medianas (RNG propio: no altera la ciudad).
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 7
	var candidates := _roofs.filter(func(r: Vector4) -> bool:
		return r.y > 30.0 and r.y < 120.0 and r.w > 14.0)
	var vent_mat := StandardMaterial3D.new()
	vent_mat.albedo_color = Color(0.18, 0.19, 0.21)
	vent_mat.roughness = 0.6
	var vent_mesh := CylinderMesh.new()
	vent_mesh.top_radius = 2.2
	vent_mesh.bottom_radius = 2.6
	vent_mesh.height = 1.2
	vent_mesh.material = vent_mat
	for i in mini(UPDRAFT_COUNT, candidates.size()):
		var r: Vector4 = candidates.pop_at(rng.randi() % candidates.size())
		var base := Vector3(r.x, r.y, r.z)
		wind_field.add_updraft(base, 70.0, 6.0)
		_wind_tube(base + Vector3.UP * 35.0, Basis.IDENTITY, 5.0, 70.0,
				Color(0.85, 0.95, 1.0), 16.0, 0.4)
		var vent := MeshInstance3D.new()
		vent.mesh = vent_mesh
		vent.position = base + Vector3.UP * 0.6
		add_child(vent)
		ring_xf.append(Transform3D(Basis.from_scale(Vector3(0.75, 1.0, 0.75)), base + Vector3.UP * 3.0))

	var torus := TorusMesh.new()
	torus.inner_radius = TUNNEL_RADIUS - 0.35
	torus.outer_radius = TUNNEL_RADIUS
	torus.rings = 48
	torus.ring_segments = 6
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = torus
	mm.instance_count = ring_xf.size()
	for i in ring_xf.size():
		mm.set_instance_transform(i, ring_xf[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "WindRings"
	mmi.multimesh = mm
	mmi.material_override = ring_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## Base ortonormal con +Y a lo largo de `axis`.
static func _basis_y(axis: Vector3) -> Basis:
	var ref := Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT
	var x := ref.cross(axis).normalized()
	return Basis(x, axis, x.cross(axis).normalized())


func _wind_tube(center: Vector3, basis: Basis, radius: float, height: float, tint: Color,
		speed: float, intensity: float) -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyl.radial_segments = 24
	cyl.rings = 1
	var mat := ShaderMaterial.new()
	mat.shader = WIND_SHADER
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("height_m", height)
	mat.set_shader_parameter("speed", speed)
	mat.set_shader_parameter("intensity", intensity)
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	mi.transform = Transform3D(basis, center)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
