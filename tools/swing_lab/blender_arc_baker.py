"""
Baker de arcos de balanceo para Blender (probado con bpy 5.0; API compatible con 4.2+).

Simula un arco con EXACTAMENTE la misma física que el runtime
(swing_core.RegulatedPendulum), lo hornea en el hueso raíz (root motion),
adapta las poses clave del personaje a la fase del arco (con overlap por grupos
de huesos y compresión por fuerza G) y escribe curvas exportables
(SwingPhase, GForce, Tension, SwingAngle, Speed).

Flujo típico:
  1) Posar al personaje en Pose Mode y capturar cada pose clave:
       blender rig.blend --python tools/swing_lab/blender_arc_baker.py -- \
           --armature Spidey --capture Bottom
     Poses reconocidas: Start, Descent, Bottom, Ascent, Apex (fase del arco),
     Compress (aditiva de fuerza G) y opcionalmente <Pose>_Aggr (set agresivo).
  2) Hornear (en background) y exportar:
       blender -b rig.blend --python tools/swing_lab/blender_arc_baker.py -- \
           --armature Spidey --side R --entry-speed 24 --action Swing_R \
           --curve-bones --glb out/swing_R.glb

Convención: swing_core usa Y-up (Godot); aquí se convierte a Z-up con el
personaje mirando a -Y, que el exportador glTF devuelve a +Z en Godot.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from swing_core import (UP, RegulatedPendulum, SwingInput, SwingTuning,  # noqa: E402
                        V3, clamp)

try:
    import bpy
    from mathutils import Matrix, Quaternion, Vector
except ImportError:          # permite importar la parte matemática fuera de Blender
    bpy = None

POSES_TEXT = "swing_key_poses.json"
PHASE_KEYS = [("Start", -1.0), ("Descent", -0.5), ("Bottom", 0.0), ("Ascent", 0.5), ("Apex", 1.0)]
CURVE_PROPS = ("SwingPhase", "GForce", "Tension", "SwingAngle", "Speed")
# Overlap / follow-through: retraso (en frames) con el que cada grupo sigue la fase.
# Negativo = se adelanta (anticipación de la cabeza hacia el próximo anclaje).
DEFAULT_LAGS = {"thigh": 3, "shin": 3, "calf": 3, "foot": 4, "toe": 4, "leg": 3,
                "upper_arm": 1, "forearm": 1, "hand": 1, "spine": 1, "neck": -1, "head": -2}
SUBSTEP = 1.0 / 240.0


# ---------------------------------------------------------------------------
# Parte matemática (sin bpy)
# ---------------------------------------------------------------------------
def to_blender(v: V3) -> tuple[float, float, float]:
    """Y-up (Godot) -> Z-up (Blender): (x, y, z) -> (x, -z, y)."""
    return (v.x, -v.z, v.y)


def simulate_arc(t: SwingTuning, *, side: float, entry_speed: float, entry_pitch_deg: float,
                 anchor_forward: float, anchor_up: float, anchor_side: float,
                 release_angle_deg: float, fps: int,
                 max_seconds: float = 4.0) -> tuple[list[dict], V3, V3]:
    """
    Simula un balanceo canónico viajando hacia +Z (Godot) y lo muestrea a `fps`.
    side = +1 ancla a la derecha, -1 a la izquierda. Devuelve una lista de
    muestras con posición, velocidad, direcciones de cuerda/web y curvas.
    """
    pend = RegulatedPendulum(t)
    fwd = V3(0.0, 0.0, 1.0)
    right = fwd.cross(UP)
    start = V3(0.0, 0.0, 0.0)
    anchor = start + fwd * anchor_forward + UP * anchor_up + right * (side * anchor_side)
    pitch = math.radians(entry_pitch_deg)
    vel = V3(0.0, -math.sin(pitch), math.cos(pitch)) * entry_speed
    pend.attach(start, vel, anchor, fwd, ground_y=-1e4)

    samples: list[dict] = []
    per_frame = max(1, round(1.0 / (fps * SUBSTEP)))
    h = 1.0 / (fps * per_frame)
    steer_right = right
    for frame in range(int(max_seconds * fps)):
        ang = pend.signed_angle_deg()
        phase = clamp(ang / pend.PHASE_REF_DEG, -1.0, 1.0)
        samples.append({
            "frame": frame, "pos": pend.pos, "vel": pend.vel,
            "web_dir": (pend.anchor - pend.pos).normalized(UP),
            "rope_dir": (pend.pivot - pend.pos).normalized(UP),
            "phase": phase, "SwingPhase": phase, "SwingAngle": ang,
            "GForce": pend.sample.g_force, "Tension": pend.sample.tension,
            "Speed": pend.vel.length(),
        })
        if frame and (ang >= release_angle_deg or pend.should_auto_release()):
            break
        for _ in range(per_frame):
            pend.step(h, SwingInput(steer_right=steer_right))
    return samples, anchor, pend.pivot


def body_axes(sample: dict) -> tuple[V3, V3]:
    """(forward, up) del cuerpo en Y-up: eje del cuerpo sobre la web, frente con la velocidad."""
    up = sample["web_dir"]
    v = sample["vel"]
    f = v - up * v.dot(up)
    return f.normalized(V3(0, 0, 1)), up


def phase_weights(phase: float, available: list[tuple[str, float]]) -> list[tuple[str, float]]:
    """Interpolación lineal por tramos entre las dos poses clave adyacentes."""
    keys = sorted(available, key=lambda k: k[1])
    if phase <= keys[0][1]:
        return [(keys[0][0], 1.0)]
    if phase >= keys[-1][1]:
        return [(keys[-1][0], 1.0)]
    for (na, pa), (nb, pb) in zip(keys, keys[1:]):
        if pa <= phase <= pb:
            u = (phase - pa) / (pb - pa) if pb > pa else 0.0
            return [(na, 1.0 - u), (nb, u)]
    return [(keys[-1][0], 1.0)]


def lag_for_bone(name: str, lags: dict[str, int]) -> int:
    lname = name.lower()
    for key, lag in lags.items():
        if key in lname:
            return lag
    return 0


def mirror_name(name: str) -> str:
    for a, b in ((".L", ".R"), ("_L", "_R"), ("Left", "Right"), (".l", ".r"), ("_l", "_r")):
        if name.endswith(a):
            return name[: -len(a)] + b
        if name.endswith(b):
            return name[: -len(b)] + a
        if a in name:
            return name.replace(a, b)
        if b in name:
            return name.replace(b, a)
    return name


def mirror_pose(pose: dict) -> dict:
    """Espejo en X en espacio local de hueso (como 'Paste Pose Flipped')."""
    out = {}
    for bone, (w, x, y, z, lx, ly, lz) in pose.items():
        out[mirror_name(bone)] = [w, x, -y, -z, -lx, ly, lz]
    return out


# ---------------------------------------------------------------------------
# Parte Blender
# ---------------------------------------------------------------------------
def _poses_store() -> dict:
    txt = bpy.data.texts.get(POSES_TEXT)
    return json.loads(txt.as_string()) if txt and txt.as_string().strip() else {}


def _save_poses(data: dict) -> None:
    txt = bpy.data.texts.get(POSES_TEXT) or bpy.data.texts.new(POSES_TEXT)
    txt.clear()
    txt.write(json.dumps(data, indent=1))


def capture_pose(arm, name: str, root_bone: str) -> None:
    """Guarda la pose actual (matrix_basis de cada hueso) dentro del .blend."""
    data = _poses_store()
    pose = {}
    for pb in arm.pose.bones:
        if pb.name == root_bone:
            continue
        loc, rot, _ = pb.matrix_basis.decompose()
        pose[pb.name] = [rot.w, rot.x, rot.y, rot.z, loc.x, loc.y, loc.z]
    data[name] = pose
    _save_poses(data)
    print(f"[swing-baker] pose '{name}' capturada ({len(pose)} huesos)")


def _body_matrix(sample: dict, hip_height: float) -> "Matrix":
    f_y, u_y = body_axes(sample)
    f, u = Vector(to_blender(f_y)), Vector(to_blender(u_y))
    r = f.cross(u).normalized()
    rot = Matrix((-r, -f, u)).transposed().to_4x4()     # columnas: X=-r, Y=-f, Z=u
    return Matrix.Translation(Vector(to_blender(sample["pos"]))) @ rot @ Matrix.Translation((0, 0, -hip_height))


def _blend_pose(poses: dict, weights: list[tuple[str, float]], bone: str):
    q_acc, l_acc, ref = None, Vector((0, 0, 0)), None
    for name, w in weights:
        entry = poses.get(name, {}).get(bone)
        if entry is None or w <= 0.0:
            continue
        q = Quaternion(entry[:4])
        if ref is None:
            ref = q
        elif ref.dot(q) < 0.0:         # mismo hemisferio antes de mezclar
            q = -q
        q_acc = q * w if q_acc is None else Quaternion([a + b * w for a, b in zip(q_acc, q)])
        l_acc += Vector(entry[4:]) * w
    if q_acc is None:
        return None, None
    q_acc.normalize()
    return q_acc, l_acc


def _ensure_curve_bones(arm) -> list[str]:
    names = [f"CRV_{p}" for p in CURVE_PROPS]
    missing = [n for n in names if n not in arm.data.bones]
    if missing:
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.mode_set(mode="EDIT")
        for n in missing:
            eb = arm.data.edit_bones.new(n)
            eb.head, eb.tail = (0, 0, 0), (0, 0.05, 0)
            eb.use_deform = False
        bpy.ops.object.mode_set(mode="POSE")
    return names


def bake(arm, samples: list[dict], anchor: V3, pivot: V3, *, action_name: str, side: float,
         root_bone: str, hip_height: float, compress_strength: float, g_force_max: float,
         hand_ik: str | None, arm_reach: float, shoulder_offset: float, curve_bones: bool,
         lags: dict[str, int]) -> None:
    scene = bpy.context.scene
    bpy.context.view_layer.objects.active = arm
    if bpy.context.object.mode != "POSE":
        bpy.ops.object.mode_set(mode="POSE")

    arm.animation_data_create()
    action = bpy.data.actions.get(action_name) or bpy.data.actions.new(action_name)
    arm.animation_data.action = action

    poses = _poses_store()
    if side < 0:           # set izquierdo: usa <Pose>_L si existe, si no espeja el derecho
        poses = {k: (poses.get(f"{k}_L") or mirror_pose(v)) for k, v in poses.items()
                 if not k.endswith("_L")}
    aggr = all(f"{k}_Aggr" in poses for k, _ in PHASE_KEYS)
    phase_keys = [(k, p) for k, p in PHASE_KEYS if k in poses]
    if not phase_keys:
        print("[swing-baker] sin poses clave: se hornea solo root motion y curvas")

    # Crear huesos en Edit Mode reconstruye los pose bones: hacerlo antes de
    # guardar referencias a ellos.
    crv_names = _ensure_curve_bones(arm) if curve_bones else []
    root_pb = arm.pose.bones[root_bone]
    root_pb.rotation_mode = "QUATERNION"
    rest_root = arm.data.bones[root_bone].matrix_local.copy()
    n = len(samples)
    speeds = [s["Speed"] for s in samples]
    aggr_w = clamp((sum(speeds) / n - 22.0) / 6.0, 0.0, 1.0) if aggr else 0.0

    for s in samples:
        f = s["frame"] + 1
        scene.frame_set(f)
        # 1) Root motion: trayectoria del péndulo + orientación sobre la web.
        root_pb.matrix = _body_matrix(s, hip_height) @ rest_root
        root_pb.keyframe_insert("location", frame=f)
        root_pb.keyframe_insert("rotation_quaternion", frame=f)

        # 2) Poses clave por fase, con overlap por grupos de huesos.
        g_w = clamp((s["GForce"] - 1.0) / (g_force_max - 1.0), 0.0, 1.0) * compress_strength
        for pb in arm.pose.bones:
            if pb.name == root_bone or pb.name.startswith("CRV_") or not phase_keys:
                continue
            lagged = samples[int(clamp(s["frame"] - lag_for_bone(pb.name, lags), 0, n - 1))]
            weights = phase_weights(lagged["phase"], phase_keys)
            q, loc = _blend_pose(poses, weights, pb.name)
            if q is None:
                continue
            if aggr_w > 0.0:
                qa, la = _blend_pose(poses, [(f"{k}_Aggr", w) for k, w in weights], pb.name)
                if qa is not None:
                    q, loc = q.slerp(qa, aggr_w), loc.lerp(la, aggr_w)
            # 3) Squash por fuerza G: aditiva Compress relativa a Bottom.
            comp, bottom = poses.get("Compress", {}).get(pb.name), poses.get("Bottom", {}).get(pb.name)
            if comp and bottom and g_w > 0.0:
                delta = Quaternion(bottom[:4]).inverted() @ Quaternion(comp[:4])
                q = q @ Quaternion().slerp(delta, g_w)
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = q
            pb.location = loc
            pb.keyframe_insert("rotation_quaternion", frame=f)
            pb.keyframe_insert("location", frame=f)

        # 4) Mano sobre la línea de la web (IK target del rig, si existe).
        if hand_ik and hand_ik in arm.pose.bones:
            bpy.context.view_layer.update()
            hips = Vector(to_blender(s["pos"]))
            web = Vector(to_blender(s["web_dir"]))
            ik_pb = arm.pose.bones[hand_ik]
            m = ik_pb.matrix.copy()
            m.translation = hips + web * (shoulder_offset + arm_reach)
            ik_pb.matrix = m
            ik_pb.keyframe_insert("location", frame=f)

        # 5) Curvas exportables: props del objeto + "curve bones" opcionales.
        for prop in CURVE_PROPS:
            arm[prop] = float(s[prop])
            arm.keyframe_insert(f'["{prop}"]', frame=f)
        for prop, bone in zip(CURVE_PROPS, crv_names):
            pb = arm.pose.bones[bone]
            pb.location = (float(s[prop]), 0.0, 0.0)
            pb.keyframe_insert("location", frame=f)

    scene.frame_start, scene.frame_end = 1, n
    _build_helpers(samples, anchor, pivot, shoulder_offset + arm_reach)
    print(f"[swing-baker] '{action_name}': {n} frames, poses {[k for k, _ in phase_keys]}, "
          f"agresivo {aggr_w:.2f}, G pico {max(s['GForce'] for s in samples):.2f}")


def _build_helpers(samples, anchor: V3, pivot: V3, hand_reach: float) -> None:
    """Anclaje, pivote, trayectoria y web animada como referencia para animadores."""
    coll = bpy.data.collections.get("SWING_Helpers") or bpy.data.collections.new("SWING_Helpers")
    if coll.name not in bpy.context.scene.collection.children:
        bpy.context.scene.collection.children.link(coll)

    def empty(name, loc, shape):
        ob = bpy.data.objects.get(name) or bpy.data.objects.new(name, None)
        ob.empty_display_type, ob.empty_display_size = shape, 0.6
        ob.location = to_blender(loc)
        if ob.name not in coll.objects:
            coll.objects.link(ob)
        return ob

    empty("SWING_Anchor", anchor, "SPHERE")
    empty("SWING_Pivot", pivot, "PLAIN_AXES")

    def curve(name, pts):
        cu = bpy.data.curves.get(name) or bpy.data.curves.new(name, "CURVE")
        cu.dimensions = "3D"
        cu.splines.clear()
        sp = cu.splines.new("POLY")
        sp.points.add(len(pts) - 1)
        for p, co in zip(sp.points, pts):
            p.co = (*co, 1.0)
        ob = bpy.data.objects.get(name) or bpy.data.objects.new(name, cu)
        if ob.name not in coll.objects:
            coll.objects.link(ob)
        return cu

    curve("SWING_Trajectory", [to_blender(s["pos"]) for s in samples])
    web = curve("SWING_Web", [(0, 0, 0), to_blender(anchor)])
    web.bevel_depth = 0.02
    p0 = web.splines[0].points[0]
    for s in samples:
        hand = s["pos"] + s["web_dir"] * hand_reach
        p0.co = (*to_blender(hand), 1.0)
        p0.keyframe_insert("co", frame=s["frame"] + 1)


def export_glb(path: str) -> None:
    if not hasattr(bpy.ops.export_scene, "gltf"):
        bpy.ops.preferences.addon_enable(module="io_scene_gltf2")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_animations=True,
                              export_yup=True)
    print(f"[swing-baker] exportado {path}")


def main(argv: list[str]) -> None:
    ap = argparse.ArgumentParser(prog="blender_arc_baker")
    ap.add_argument("--armature", required=True)
    ap.add_argument("--root-bone", default="root")
    ap.add_argument("--capture", help="captura la pose actual con este nombre y sale")
    ap.add_argument("--side", choices=("L", "R"), default="R")
    ap.add_argument("--action", default=None)
    ap.add_argument("--entry-speed", type=float, default=22.0)
    ap.add_argument("--entry-pitch", type=float, default=20.0, help="grados de caída al enganchar")
    ap.add_argument("--anchor-forward", type=float, default=18.0)
    ap.add_argument("--anchor-up", type=float, default=22.0)
    ap.add_argument("--anchor-side", type=float, default=6.0)
    ap.add_argument("--release-angle", type=float, default=40.0)
    ap.add_argument("--fps", type=int, default=0, help="0 = fps de la escena")
    ap.add_argument("--hip-height", type=float, default=1.0)
    ap.add_argument("--arm-reach", type=float, default=0.7)
    ap.add_argument("--shoulder-offset", type=float, default=0.5, help="caderas -> hombro sobre el eje")
    ap.add_argument("--hand-ik", default=None, help="hueso IK de la mano que sujeta la web")
    ap.add_argument("--compress", type=float, default=1.0, help="intensidad del squash por G")
    ap.add_argument("--g-max", type=float, default=6.0)
    ap.add_argument("--curve-bones", action="store_true")
    ap.add_argument("--glb", default=None)
    ap.add_argument("--save", action="store_true", help="guarda el .blend al terminar")
    args = ap.parse_args(argv)

    arm = bpy.data.objects[args.armature]
    if args.capture:
        capture_pose(arm, args.capture, args.root_bone)
    else:
        side = 1.0 if args.side == "R" else -1.0
        fps = args.fps or bpy.context.scene.render.fps
        samples, anchor, pivot = simulate_arc(
            SwingTuning(), side=side, entry_speed=args.entry_speed, entry_pitch_deg=args.entry_pitch,
            anchor_forward=args.anchor_forward, anchor_up=args.anchor_up, anchor_side=args.anchor_side,
            release_angle_deg=args.release_angle, fps=fps)
        bake(arm, samples, anchor, pivot, action_name=args.action or f"Swing_{args.side}", side=side,
             root_bone=args.root_bone, hip_height=args.hip_height, compress_strength=args.compress,
             g_force_max=args.g_max, hand_ik=args.hand_ik, arm_reach=args.arm_reach,
             shoulder_offset=args.shoulder_offset, curve_bones=args.curve_bones, lags=DEFAULT_LAGS)
        if args.glb:
            export_glb(args.glb)
    if args.save:
        bpy.ops.wm.save_mainfile()


if __name__ == "__main__" and bpy is not None:
    main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
