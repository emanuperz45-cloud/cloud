class_name LookAtChainModifier
extends SkeletonModifier3D
## Head tracking repartido en una cadena (columna alta -> cuello -> cabeza).
##
## Cada hueso corrige una fracción del error restante (weights), de modo que la
## cabeza termina alineada y la columna acompaña: evita el "cuello de búho".
## Límite angular total para no romper la pose a velocidades altas.

@export var bones: Array[StringName] = [&"spine_03", &"neck", &"head"]
@export var weights: PackedFloat32Array = PackedFloat32Array([0.2, 0.3, 0.5])
@export var target: Node3D
## Eje "mirada" de los huesos en su espacio local (depende del rig; +Z en glTF).
@export var forward_axis := Vector3(0.0, 0.0, 1.0)
@export var max_angle_deg := 75.0


func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or target == null or bones.is_empty():
		return
	var t := skel.global_transform.affine_inverse() * target.global_position
	var budget := deg_to_rad(max_angle_deg)
	var remaining_w := 0.0
	for w in weights:
		remaining_w += w

	for i in bones.size():
		var idx := skel.find_bone(bones[i])
		if idx < 0:
			continue
		var w := weights[i] if i < weights.size() else 0.0
		if remaining_w <= 1e-5:
			break
		var frac := w / remaining_w
		remaining_w -= w

		var tr := skel.get_bone_global_pose(idx)
		var fwd := (tr.basis * forward_axis).normalized()
		var desired := (t - tr.origin).normalized()
		var axis := fwd.cross(desired)
		if axis.length_squared() < 1e-10:
			continue
		var angle := minf(fwd.angle_to(desired), budget) * frac
		budget -= angle
		var new_basis := Basis(Quaternion(axis.normalized(), angle)) * tr.basis
		var parent := skel.get_bone_parent(idx)
		var parent_basis := skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
		skel.set_bone_pose_rotation(idx, (parent_basis.inverse() * new_basis).get_rotation_quaternion())
