class_name BodyMesh
extends RefCounted
## Cuerpo continuo del personaje horneado por tools/body_baker/bake_body.py.
##
## Formato de body_mesh.bin (little-endian):
##   "SPDB", u32 versión, u32 vértices, u32 triángulos, u32 huesos,
##   6 f32 caja (min, max), por hueso: u8 largo + nombre + 12 f32 (base en
##   columnas + origen) de su transformación global en la pose de enlace,
##   posiciones u16×3 cuantizadas en la caja, normales i8×3, huesos u8×4,
##   pesos u8×4 (suman 255) e índices u16×3.
## La malla está modelada en la pose de enlace (brazos abiertos): la Skin guarda
## las inversas de esas matrices y el esqueleto de reposo tiene los brazos abajo.
## UV / UV2.x guardan la posición de enlace: el shader del traje dibuja la
## telaraña en esas coordenadas, así el dibujo se mueve pegado a la piel.

const PATH := "res://demo/body/body_mesh.bin"

var mesh: ArrayMesh
var skin: Skin
var bone_names := PackedStringArray()
var bind_globals: Array[Transform3D] = []


static func load_file(path: String = PATH) -> BodyMesh:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 64 or bytes.slice(0, 4).get_string_from_ascii() != "SPDB":
		return null
	var b := BodyMesh.new()
	var nv := bytes.decode_u32(8)
	var nt := bytes.decode_u32(12)
	var nb := bytes.decode_u32(16)
	var lo := Vector3(bytes.decode_float(20), bytes.decode_float(24), bytes.decode_float(28))
	var hi := Vector3(bytes.decode_float(32), bytes.decode_float(36), bytes.decode_float(40))
	var o := 44
	for i in nb:
		var ln := bytes.decode_u8(o)
		b.bone_names.append(bytes.slice(o + 1, o + 1 + ln).get_string_from_ascii())
		o += 1 + ln
		var f := bytes.slice(o, o + 48).to_float32_array()
		o += 48
		b.bind_globals.append(Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]),
				Vector3(f[6], f[7], f[8])), Vector3(f[9], f[10], f[11])))

	var scale := (hi - lo) / 65535.0
	var verts := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	verts.resize(nv)
	uv.resize(nv)
	uv2.resize(nv)
	for i in nv:
		var p := lo + Vector3(bytes.decode_u16(o), bytes.decode_u16(o + 2), bytes.decode_u16(o + 4)) * scale
		o += 6
		verts[i] = p
		uv[i] = Vector2(p.x, p.y)
		uv2[i] = Vector2(p.z, 0.0)
	var normals := PackedVector3Array()
	normals.resize(nv)
	for i in nv:
		normals[i] = Vector3(bytes.decode_s8(o), bytes.decode_s8(o + 1), bytes.decode_s8(o + 2)).normalized()
		o += 3
	var bones := PackedInt32Array()
	bones.resize(nv * 4)
	for i in nv * 4:
		bones[i] = bytes.decode_u8(o + i)
	o += nv * 4
	var weights := PackedFloat32Array()
	weights.resize(nv * 4)
	for i in nv * 4:
		weights[i] = bytes.decode_u8(o + i) / 255.0
	o += nv * 4
	var indices := PackedInt32Array()
	indices.resize(nt * 3)
	for i in nt * 3:
		indices[i] = bytes.decode_u16(o + i * 2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	b.mesh = ArrayMesh.new()
	b.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	b.skin = Skin.new()
	for i in nb:
		b.skin.add_named_bind(b.bone_names[i], b.bind_globals[i].affine_inverse())
	return b
