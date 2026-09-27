class_name TwoBoneIKModifier
extends SkeletonModifier3D
## IK analítica de dos huesos (brazo: hombro-codo-muñeca / pierna: muslo-rodilla-pie).
##
## Usos en el sistema de balanceo:
##  - Mano que sujeta la web: target sobre la línea de la web, influence = f(tensión).
##  - Mano libre en swing agresivo: agarra la web un poco más abajo.
##  - Pies en wall run: target = impacto de un rayo contra la pared.
## `influence` (heredado de SkeletonModifier3D) mezcla con la animación.
## Requisito: mid_bone es hijo directo de root_bone, tip_bone hijo de mid_bone.

@export var root_bone: StringName
@export var mid_bone: StringName
@export var tip_bone: StringName
@export var target: Node3D
## Opcional: hacia dónde apunta el codo/rodilla. Sin él se conserva el plano actual.
@export var pole: Node3D
## Copia la rotación global del target a la muñeca/pie (orientar palma o planta).
@export var match_tip_rotation := false

var _a := -1
var _b := -1
var _c := -1


func _resolve(skel: Skeleton3D) -> bool:
	_a = skel.find_bone(root_bone)
	_b = skel.find_bone(mid_bone)
	_c = skel.find_bone(tip_bone)
	return _a >= 0 and _b >= 0 and _c >= 0


## Posición mundial del hombro/cadera, para que el animador coloque el target.
func chain_root_world() -> Vector3:
	var skel := get_skeleton()
	if skel == null or not _resolve(skel):
		return global_position
	return skel.global_transform * skel.get_bone_global_pose(_a).origin


func chain_length() -> float:
	var skel := get_skeleton()
	if skel == null or not _resolve(skel):
		return 0.0
	var a := skel.get_bone_global_pose(_a).origin
	var b := skel.get_bone_global_pose(_b).origin
	var c := skel.get_bone_global_pose(_c).origin
	return a.distance_to(b) + b.distance_to(c)


func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or target == null or not _resolve(skel):
		return
	var to_skel := skel.global_transform.affine_inverse()
	var a_tr := skel.get_bone_global_pose(_a)
	var b_tr := skel.get_bone_global_pose(_b)
	var c_tr := skel.get_bone_global_pose(_c)
	var a := a_tr.origin
	var b := b_tr.origin
	var c := c_tr.origin
	var la := a.distance_to(b)
	var lb := b.distance_to(c)
	if la < 1e-5 or lb < 1e-5:
		return

	var t := to_skel * target.global_position
	var to_t := t - a
	var dist := clampf(to_t.length(), absf(la - lb) + 1e-4, (la + lb) * 0.999)
	var dir := to_t.normalized()
	if dir == Vector3.ZERO:
		return

	# Plano de flexión: pole explícito o el plano actual de la cadena.
	var pole_v := (to_skel * pole.global_position - a) if pole else (b - a)
	var bend := pole_v - dir * pole_v.dot(dir)
	if bend.length_squared() < 1e-8:
		bend = (b - a) - dir * (b - a).dot(dir)
	if bend.length_squared() < 1e-8:
		bend = dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.UP)
	bend = bend.normalized()

	# Ley de cosenos: posición nueva del codo/rodilla.
	var x := (la * la - lb * lb + dist * dist) / (2.0 * dist)
	var y := sqrt(maxf(la * la - x * x, 0.0))
	var b_new := a + dir * x + bend * y
	var c_new := a + dir * dist

	# Rotación mínima del hueso raíz para que apunte al codo nuevo.
	var q_a := Quaternion((b - a).normalized(), (b_new - a).normalized())
	var a_basis := Basis(q_a) * a_tr.basis
	var b_basis_follow := Basis(q_a) * b_tr.basis
	var c_follow := b_new + q_a * (c - b)
	# Rotación mínima del hueso medio para que la punta llegue al target.
	var q_b := Quaternion((c_follow - b_new).normalized(), (c_new - b_new).normalized())
	var b_basis := Basis(q_b) * b_basis_follow

	var parent := skel.get_bone_parent(_a)
	var parent_basis := skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	skel.set_bone_pose_rotation(_a, (parent_basis.inverse() * a_basis).get_rotation_quaternion())
	skel.set_bone_pose_rotation(_b, (a_basis.inverse() * b_basis).get_rotation_quaternion())

	if match_tip_rotation:
		var tip_basis := to_skel.basis * target.global_transform.basis
		skel.set_bone_pose_rotation(_c, (b_basis.inverse() * tip_basis).get_rotation_quaternion())
