"""
Test de integración del baker de Blender (se salta si no hay `bpy`).
    pip install bpy==5.0.1 && python -m unittest test_blender_baker
"""
import os
import tempfile
import unittest

import blender_arc_baker as baker
from swing_core import SwingTuning

try:
    import bpy
    from mathutils import Vector
except ImportError:
    bpy = None


def build_test_rig():
    """Rig mínimo: root + cadera + columna + cabeza + brazo y pierna derechos + IK de mano."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    data = bpy.data.armatures.new("RigData")
    arm = bpy.data.objects.new("Rig", data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    spec = [("root", None, (0, 0, 0), (0, 0.3, 0)),
            ("hips", "root", (0, 0, 1.0), (0, 0, 1.2)),
            ("spine", "hips", (0, 0, 1.2), (0, 0, 1.5)),
            ("head", "spine", (0, 0, 1.5), (0, 0, 1.75)),
            ("upper_arm.R", "spine", (-0.2, 0, 1.45), (-0.45, 0, 1.45)),
            ("forearm.R", "upper_arm.R", (-0.45, 0, 1.45), (-0.7, 0, 1.45)),
            ("thigh.R", "hips", (-0.1, 0, 1.0), (-0.1, 0, 0.55)),
            ("shin.R", "thigh.R", (-0.1, 0, 0.55), (-0.1, 0, 0.1)),
            ("hand_ik.R", "root", (-0.7, 0, 1.45), (-0.7, 0.1, 1.45))]
    for name, parent, head, tail in spec:
        eb = data.edit_bones.new(name)
        eb.head, eb.tail = head, tail
        if parent:
            eb.parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="POSE")
    return arm


def set_pose(arm, angle_deg):
    import math
    from mathutils import Quaternion
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = Quaternion((1, 0, 0), math.radians(angle_deg)) \
            if pb.name in ("thigh.R", "shin.R", "spine") else Quaternion()
        pb.location = (0, 0, 0)


@unittest.skipIf(bpy is None, "bpy no disponible")
class BakerTests(unittest.TestCase):
    def test_bake_and_export(self):
        arm = build_test_rig()
        for name, ang in (("Start", -30), ("Descent", -10), ("Bottom", 20), ("Ascent", 35),
                          ("Apex", 50), ("Compress", 45)):
            set_pose(arm, ang)
            baker.capture_pose(arm, name, "root")

        fps = 30
        samples, anchor, pivot = baker.simulate_arc(
            SwingTuning(), side=1.0, entry_speed=22.0, entry_pitch_deg=20.0, anchor_forward=18.0,
            anchor_up=22.0, anchor_side=6.0, release_angle_deg=40.0, fps=fps)
        self.assertGreater(len(samples), 20)
        baker.bake(arm, samples, anchor, pivot, action_name="Swing_R", side=1.0, root_bone="root",
                   hip_height=1.0, compress_strength=1.0, g_force_max=6.0, hand_ik="hand_ik.R",
                   arm_reach=0.7, shoulder_offset=0.5, curve_bones=True, lags=baker.DEFAULT_LAGS)

        self.assertEqual(arm.animation_data.action.name, "Swing_R")
        scene = bpy.context.scene
        # El origen del cuerpo (caderas) debe seguir la trayectoria simulada.
        for s in (samples[0], samples[len(samples) // 2], samples[-1]):
            scene.frame_set(s["frame"] + 1)
            bpy.context.view_layer.update()
            hips = arm.matrix_world @ arm.pose.bones["hips"].head
            expected = Vector(baker.to_blender(s["pos"]))
            self.assertLess((hips - expected).length, 1e-3)
            self.assertAlmostEqual(arm["SwingPhase"], s["SwingPhase"], places=4)
            crv = arm.pose.bones["CRV_GForce"].location.x
            self.assertAlmostEqual(crv, s["GForce"], places=4)
        # La mano IK queda sobre la línea de la web.
        mid = samples[len(samples) // 2]
        scene.frame_set(mid["frame"] + 1)
        bpy.context.view_layer.update()
        ik = arm.matrix_world @ arm.pose.bones["hand_ik.R"].head
        hand = Vector(baker.to_blender(mid["pos"] + mid["web_dir"] * 1.2))
        self.assertLess((ik - hand).length, 1e-3)

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "swing_R.glb")
            baker.export_glb(path)
            self.assertGreater(os.path.getsize(path), 1000)

    def test_mirror_pose_flips_side(self):
        pose = {"upper_arm.R": [1.0, 0.1, 0.2, 0.3, 0.5, 0.0, 0.0]}
        m = baker.mirror_pose(pose)
        self.assertIn("upper_arm.L", m)
        self.assertEqual(m["upper_arm.L"], [1.0, 0.1, -0.2, -0.3, -0.5, 0.0, 0.0])


class PhaseMathTests(unittest.TestCase):
    def test_phase_weights_piecewise(self):
        w = dict(baker.phase_weights(0.25, baker.PHASE_KEYS))
        self.assertAlmostEqual(w["Bottom"], 0.5)
        self.assertAlmostEqual(w["Ascent"], 0.5)
        self.assertEqual(baker.phase_weights(-2.0, baker.PHASE_KEYS), [("Start", 1.0)])


if __name__ == "__main__":
    unittest.main()
