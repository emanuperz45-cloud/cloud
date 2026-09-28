"""
Horneado del cuerpo del personaje: una sola malla continua con pesos de piel.

El cuerpo se describe como una unión suave (smooth-min) de volúmenes anatómicos
(elipsoides y conos redondeados: pecho, pectorales, dorsales, deltoides, bíceps,
cuádriceps, gemelos, glúteos, cráneo, mandíbula...) atados a los huesos del
maniquí de la demo (godot/demo/mannequin.gd). Se evalúa la SDF en una rejilla,
se extrae la superficie con marching cubes y cada vértice recibe los pesos de los
huesos cuyas primitivas lo "poseen" (exp(-(d_hueso - d_total)/σ)), suavizados
sobre la malla para que no haya pliegues al doblar.

La malla se modela en una pose de enlace (bind) con los brazos abiertos 80° y
las piernas 8°, para que brazos y piernas no se fundan con el torso. El juego
usa el esqueleto con los brazos abajo como pose de reposo; la Skin lleva las
matrices inversas de la pose de enlace (se guardan en el fichero).

Salida: godot/demo/body/body_mesh.bin (formato en BodyMesh.gd).
Requiere numpy y scikit-image:  python bake_body.py [--voxel 0.012] [--out RUTA]
"""
from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

import numpy as np
from skimage import measure

# ---------------------------------------------------------------------------
# Esqueleto (idéntico a mannequin.gd): padre, desplazamiento en reposo
# ---------------------------------------------------------------------------
BONES = ["pelvis", "spine", "head", "sh_l", "el_l", "sh_r", "el_r", "hip_l", "kn_l", "hip_r", "kn_r"]
REST = {
    "pelvis": (None, (0.0, 0.0, 0.0)),
    "spine": ("pelvis", (0.0, 0.06, 0.0)),
    "head": ("spine", (0.0, 0.60, 0.0)),
    "sh_r": ("spine", (-0.23, 0.47, 0.0)),
    "el_r": ("sh_r", (0.0, -0.30, 0.0)),
    "sh_l": ("spine", (0.23, 0.47, 0.0)),
    "el_l": ("sh_l", (0.0, -0.30, 0.0)),
    "hip_r": ("pelvis", (-0.095, -0.05, 0.0)),
    "kn_r": ("hip_r", (0.0, -0.43, 0.0)),
    "hip_l": ("pelvis", (0.095, -0.05, 0.0)),
    "kn_l": ("hip_l", (0.0, -0.43, 0.0)),
}
ARM_BIND_DEG = 80.0
LEG_BIND_DEG = 8.0


def rot_z(deg: float) -> np.ndarray:
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


# Rotaciones de la pose de enlace (misma convención que _arm/_leg: z = -lado·out;
# lado +1 = derecha = -X).
BIND_ROT = {
    "sh_r": rot_z(-ARM_BIND_DEG), "sh_l": rot_z(ARM_BIND_DEG),
    "hip_r": rot_z(-LEG_BIND_DEG), "hip_l": rot_z(LEG_BIND_DEG),
}


def bind_globals() -> dict[str, tuple[np.ndarray, np.ndarray]]:
    """Transformaciones globales (R, t) de cada hueso en la pose de enlace."""
    out: dict[str, tuple[np.ndarray, np.ndarray]] = {}
    for name in BONES:
        chain = []
        n = name
        while n is not None:
            chain.append(n)
            n = REST[n][0]
        R, t = np.eye(3), np.zeros(3)
        for n in reversed(chain):
            off = np.array(REST[n][1])
            t = t + R @ off
            R = R @ BIND_ROT.get(n, np.eye(3))
        out[name] = (R, t)
    return out


# ---------------------------------------------------------------------------
# Primitivas SDF (coordenadas locales del hueso en la pose de reposo)
# ---------------------------------------------------------------------------
def sd_ellipsoid(p: np.ndarray, c, r) -> np.ndarray:
    q = (p - np.asarray(c)) / np.asarray(r)
    k0 = np.linalg.norm(q, axis=-1)
    k1 = np.linalg.norm(q / np.asarray(r), axis=-1)
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)


def sd_round_cone(p: np.ndarray, a, b, ra: float, rb: float) -> np.ndarray:
    a, b = np.asarray(a, float), np.asarray(b, float)
    ba = b - a
    t = np.clip(((p - a) @ ba) / (ba @ ba), 0.0, 1.0)
    d = np.linalg.norm(p - (a + t[..., None] * ba), axis=-1)
    return d - (ra + (rb - ra) * t)


def smin(a: np.ndarray, b: np.ndarray, k: float) -> np.ndarray:
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


def primitives() -> dict[str, list]:
    """Volúmenes por hueso. sgn: -1 derecha (X negativa), +1 izquierda."""
    P: dict[str, list] = {b: [] for b in BONES}
    E, C = "e", "c"
    P["pelvis"] += [
        (E, (0.0, -0.03, 0.0), (0.160, 0.112, 0.112)),
        (E, (0.0, -0.10, 0.012), (0.095, 0.06, 0.085)),          # entrepierna
        (E, (0.0, 0.07, 0.008), (0.142, 0.11, 0.1)),             # bajo vientre (puente con el abdomen)
    ]
    for sgn in (-1.0, 1.0):
        P["pelvis"].append((E, (sgn * 0.072, -0.075, -0.052), (0.082, 0.088, 0.072)))   # glúteos
    P["spine"] += [
        (E, (0.0, 0.09, 0.006), (0.138, 0.14, 0.1)),              # abdomen
        (E, (0.0, 0.2, 0.0), (0.155, 0.13, 0.104)),               # cintura/costillas bajas
        (E, (0.0, 0.305, 0.0), (0.182, 0.168, 0.115)),            # caja torácica
        (E, (0.0, 0.295, -0.03), (0.192, 0.155, 0.098)),          # dorsales
        (C, (-0.165, 0.435, -0.012), (0.165, 0.435, -0.012), 0.062, 0.062),   # trapecios
    ]
    for sgn in (-1.0, 1.0):
        P["spine"].append((E, (sgn * 0.074, 0.335, 0.056), (0.082, 0.058, 0.052)))      # pectorales
        P["spine"].append((E, (sgn * 0.05, 0.13, 0.062), (0.05, 0.075, 0.035)))         # oblicuos/abdominales
    P["head"] += [
        (C, (0.0, -0.13, -0.006), (0.0, 0.03, 0.0), 0.054, 0.049),                      # cuello
        (E, (0.0, 0.12, 0.004), (0.096, 0.12, 0.11)),                                    # cráneo
        (E, (0.0, 0.058, 0.035), (0.07, 0.058, 0.074)),                                  # mandíbula
    ]
    for side, sgn in (("r", -1.0), ("l", 1.0)):
        P["sh_" + side] += [
            (E, (sgn * 0.014, -0.025, 0.0), (0.074, 0.08, 0.072)),                       # deltoides
            (C, (0.0, 0.0, 0.0), (0.0, -0.29, 0.0), 0.058, 0.047),                       # húmero
            (E, (0.0, -0.14, 0.017), (0.044, 0.085, 0.044)),                             # bíceps
            (E, (0.0, -0.13, -0.016), (0.043, 0.09, 0.042)),                             # tríceps
        ]
        P["el_" + side] += [
            (C, (0.0, 0.0, 0.0), (0.0, -0.26, 0.0), 0.048, 0.034),                       # antebrazo
            (E, (0.0, -0.07, 0.004), (0.049, 0.08, 0.046)),                              # musculatura
            (E, (0.0, -0.345, 0.0), (0.023, 0.058, 0.044)),                              # mano
            (C, (sgn * -0.004, -0.30, 0.034), (sgn * -0.004, -0.355, 0.056), 0.014, 0.011),  # pulgar
        ]
        P["hip_" + side] += [
            (C, (0.0, 0.02, 0.0), (0.0, -0.42, 0.0), 0.088, 0.058),                      # fémur
            (E, (0.0, -0.17, 0.026), (0.078, 0.15, 0.07)),                               # cuádriceps
            (E, (0.0, -0.2, -0.02), (0.07, 0.13, 0.065)),                                # isquios
        ]
        P["kn_" + side] += [
            (E, (0.0, 0.0, 0.012), (0.058, 0.06, 0.058)),                                # rodilla
            (C, (0.0, 0.0, 0.0), (0.0, -0.41, 0.0), 0.053, 0.035),                       # tibia
            (E, (0.0, -0.13, -0.03), (0.058, 0.105, 0.06)),                              # gemelo
            (C, (0.0, -0.425, -0.025), (0.0, -0.452, 0.135), 0.043, 0.031),              # pie
        ]
    return P


# Suavidad de la unión dentro de cada hueso: el tronco se funde mucho más que las
# extremidades (sin "cuentas" entre pecho, abdomen y cadera).
BONE_K = {"pelvis": 0.07, "spine": 0.07, "head": 0.04}


def eval_bone(prims: list, p_local: np.ndarray, k: float = 0.025) -> np.ndarray:
    d = None
    for pr in prims:
        if pr[0] == "e":
            di = sd_ellipsoid(p_local, pr[1], pr[2])
        else:
            di = sd_round_cone(p_local, pr[1], pr[2], pr[3], pr[4])
        d = di if d is None else smin(d, di, k)
    return d


def bone_distances(p: np.ndarray, G, P) -> dict[str, np.ndarray]:
    out = {}
    for b in BONES:
        R, t = G[b]
        local = (p - t) @ R          # R ortonormal: R^T (p - t)
        out[b] = eval_bone(P[b], local, BONE_K.get(b, 0.025))
    return out


def blend(dists: dict[str, np.ndarray], k: float = 0.05) -> np.ndarray:
    d = None
    for b in BONES:
        d = dists[b] if d is None else smin(d, dists[b], k)
    return d


# ---------------------------------------------------------------------------
# Horneado
# ---------------------------------------------------------------------------
def bake(voxel: float):
    G = bind_globals()
    P = primitives()
    lo = np.array([-1.02, -1.02, -0.22])
    hi = np.array([1.02, 0.95, 0.24])
    n = np.ceil((hi - lo) / voxel).astype(int) + 1
    xs = [lo[i] + np.arange(n[i]) * voxel for i in range(3)]
    grid = np.stack(np.meshgrid(*xs, indexing="ij"), axis=-1)
    vol = blend(bone_distances(grid.reshape(-1, 3), G, P)).reshape(n)
    verts, faces, _, _ = measure.marching_cubes(vol, level=0.0, spacing=(voxel,) * 3)
    verts = verts + lo

    def sdf(p):
        return blend(bone_distances(p, G, P))

    # Normales exactas del gradiente de la SDF (sombreado suave sin facetas).
    e = 0.0015
    grad = np.stack([sdf(verts + e * np.eye(3)[i]) - sdf(verts - e * np.eye(3)[i]) for i in range(3)], axis=-1)
    normals = grad / np.linalg.norm(grad, axis=-1, keepdims=True)

    # Godot: caras frontales en sentido horario -> cross(v1-v0, v2-v0) apunta hacia dentro.
    v0, v1, v2 = verts[faces[:, 0]], verts[faces[:, 1]], verts[faces[:, 2]]
    fn = np.cross(v1 - v0, v2 - v0)
    outward = (fn * normals[faces].mean(axis=1)).sum(-1) > 0.0
    faces[outward] = faces[outward][:, ::-1]

    # Pesos: "propiedad" de cada hueso sobre el vértice, suavizada sobre la malla.
    dists = bone_distances(verts, G, P)
    d_tot = sdf(verts)
    D = np.stack([dists[b] for b in BONES], axis=-1) - d_tot[:, None]
    W = np.exp(-np.maximum(D, 0.0) / 0.012)
    W[D > 0.06] = 0.0
    W /= W.sum(-1, keepdims=True)
    nv = len(verts)
    rows = np.concatenate([faces[:, 0], faces[:, 1], faces[:, 2], faces[:, 1], faces[:, 2], faces[:, 0]])
    cols = np.concatenate([faces[:, 1], faces[:, 2], faces[:, 0], faces[:, 0], faces[:, 1], faces[:, 2]])
    deg = np.bincount(rows, minlength=nv).astype(float)
    for _ in range(4):
        acc = np.zeros_like(W)
        np.add.at(acc, rows, W[cols])
        W = 0.5 * W + 0.5 * acc / np.maximum(deg, 1.0)[:, None]
    idx = np.argsort(-W, axis=-1)[:, :4]
    w4 = np.take_along_axis(W, idx, axis=-1)
    w4 /= w4.sum(-1, keepdims=True)
    return verts, normals, faces, idx, w4, G


def write(path: Path, verts, normals, faces, idx, w4, G) -> None:
    lo, hi = verts.min(0), verts.max(0)
    q = np.round((verts - lo) / (hi - lo) * 65535.0).astype("<u2")
    nq = np.round(normals * 127.0).astype("<i1")
    wq = np.round(w4 * 255.0).astype(int)
    wq[:, 0] += 255 - wq.sum(-1)                       # suma exacta 255
    with open(path, "wb") as f:
        f.write(b"SPDB")
        f.write(struct.pack("<4I", 1, len(verts), len(faces), len(BONES)))
        f.write(struct.pack("<6f", *lo, *hi))
        for b in BONES:                                  # nombre + matriz de enlace 3x4
            name = b.encode()
            R, t = G[b]
            f.write(struct.pack("<B", len(name)) + name)
            f.write(struct.pack("<12f", *R[:, 0], *R[:, 1], *R[:, 2], *t))
        f.write(q.tobytes())
        f.write(nq.tobytes())
        f.write(idx.astype("<u1").tobytes())
        f.write(wq.astype("<u1").tobytes())
        f.write(faces.astype("<u2").tobytes())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--voxel", type=float, default=0.012)
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[2] / "godot/demo/body/body_mesh.bin"))
    a = ap.parse_args()
    verts, normals, faces, idx, w4, G = bake(a.voxel)
    assert len(verts) < 65536, "demasiados vértices para índices de 16 bits"
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    write(out, verts, normals, faces, idx, w4, G)
    print(f"{len(verts)} vértices, {len(faces)} triángulos -> {out} ({out.stat().st_size / 1024:.0f} KiB)")
    print("altura %.3f m, envergadura %.3f m" % (np.ptp(verts[:, 1]), np.ptp(verts[:, 0])))


if __name__ == "__main__":
    main()
