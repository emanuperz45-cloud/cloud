"""Tests del horneado del cuerpo (se saltan si no hay numpy / scikit-image)."""
import math
import tempfile
import unittest
from pathlib import Path

try:
    import numpy as np
    import bake_body
    HAVE_DEPS = True
except ImportError:          # pragma: no cover - depende del entorno
    HAVE_DEPS = False


@unittest.skipUnless(HAVE_DEPS, "requiere numpy y scikit-image")
class BakeBodyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verts, cls.normals, cls.faces, cls.idx, cls.w4, cls.G = bake_body.bake(0.03)

    def test_bind_pose_opens_the_arms(self):
        R, t = self.G["el_r"]
        # Codo derecho: 0,30 m desde el hombro, abierto 80° hacia -X.
        self.assertAlmostEqual(t[0], -0.23 - 0.30 * math.sin(math.radians(80)), places=4)
        self.assertAlmostEqual(t[1], 0.53 - 0.30 * math.cos(math.radians(80)), places=4)

    def test_body_proportions(self):
        height = np.ptp(self.verts[:, 1])
        span = np.ptp(self.verts[:, 0])
        self.assertAlmostEqual(height, 1.85, delta=0.08)
        self.assertGreater(span, 1.7)                       # brazos abiertos

    def test_weights_are_normalized_and_local(self):
        self.assertTrue(np.allclose(self.w4.sum(-1), 1.0, atol=1e-5))
        # La mano derecha solo depende del brazo derecho.
        hand = self.verts[:, 0] < -0.8
        bones = set(np.array(bake_body.BONES)[self.idx[hand][self.w4[hand] > 0.05]])
        self.assertLessEqual(bones, {"sh_r", "el_r"})

    def test_faces_wind_clockwise_for_godot(self):
        v0, v1, v2 = (self.verts[self.faces[:, i]] for i in range(3))
        fn = np.cross(v1 - v0, v2 - v0)
        inward = (fn * self.normals[self.faces].mean(axis=1)).sum(-1) < 0.0
        self.assertGreater(inward.mean(), 0.99)

    def test_file_roundtrip_header(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "b.bin"
            bake_body.write(p, self.verts, self.normals, self.faces, self.idx, self.w4, self.G)
            data = p.read_bytes()
        self.assertEqual(data[:4], b"SPDB")
        nv, nt = int.from_bytes(data[8:12], "little"), int.from_bytes(data[12:16], "little")
        self.assertEqual((nv, nt), (len(self.verts), len(self.faces)))


if __name__ == "__main__":
    unittest.main()
