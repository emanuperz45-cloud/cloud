class_name CityBuilder
extends Node3D
## Ciudad procedural en rejilla (estilo Manhattan) para probar el balanceo.
##
## Calles centradas en múltiplos de `pitch` en X y Z. Cada manzana se divide en
## solares con alturas aleatorias (más altas en el centro). Todo se dibuja con
## un único MultiMesh y cada edificio tiene su BoxShape3D en la capa World, que
## es la que barre AnchorFinder. Las esquinas de algunas azoteas generan puntos
## de posado (grupo "perch_points") para el Point Launch.

const BUILDING_SHADER := preload("res://demo/building.gdshader")
const GROUND_SHADER := preload("res://demo/ground.gdshader")
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
