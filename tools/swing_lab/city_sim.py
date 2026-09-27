"""
Simulador de calibración del balanceo en una "avenida" sintética de Manhattan.

Ejecuta el péndulo regulado (swing_core.py) con un piloto automático y reporta
las métricas que usamos para fijar los valores de la sección 5 del documento:
velocidad de crucero, G máxima, duración de cada balanceo, clearance con el
suelo, colisiones con fachadas y la ganancia de la maniobra picada -> swing.

Uso:
    python3 tools/swing_lab/city_sim.py              # informe completo
    python3 tools/swing_lab/city_sim.py --csv out.csv  # además vuelca la trayectoria
"""
from __future__ import annotations

import argparse
import csv
import math
import random
import statistics
from dataclasses import dataclass, field, replace

from swing_core import (UP, AnchorCandidate, RegulatedPendulum, SwingInput,
                        SwingTuning, V3, ideal_anchor_point, score_anchor,
                        step_air, terminal_velocity)

H = 1.0 / 240.0          # sub-paso físico
STREET_HALF_WIDTH = 15.0
BODY_RADIUS = 0.45


# ---------------------------------------------------------------------------
# Ciudad sintética: dos filas de edificios (AABB) flanqueando una avenida en +Z
# ---------------------------------------------------------------------------
@dataclass
class Box:
    mn: V3
    mx: V3


def build_city(length: float = 4000.0, seed: int = 7) -> list[Box]:
    rng = random.Random(seed)
    boxes: list[Box] = []
    block, cross_street = 80.0, 20.0
    z = -40.0
    while z < length:
        z_end = z + block - cross_street
        cuts = sorted(rng.uniform(z + 10, z_end - 10) for _ in range(rng.randint(0, 2)))
        edges = [z] + cuts + [z_end]
        for side in (-1.0, 1.0):
            for a, b in zip(edges, edges[1:]):
                h = rng.uniform(35.0, 140.0)
                inset = rng.uniform(0.0, 4.0)       # fachadas no perfectamente alineadas
                x0 = STREET_HALF_WIDTH + inset
                x_min, x_max = (x0, x0 + 50.0) if side > 0 else (-x0 - 50.0, -x0)
                boxes.append(Box(V3(x_min, 0.0, a), V3(x_max, h, b)))
        z += block
    return boxes


class City:
    def __init__(self, boxes: list[Box]):
        self.boxes = boxes
        self.cell = 40.0
        self.grid: dict[int, list[Box]] = {}
        for b in boxes:
            for c in range(int(math.floor(b.mn.z / self.cell)), int(math.floor(b.mx.z / self.cell)) + 1):
                self.grid.setdefault(c, []).append(b)

    def _near(self, z0: float, z1: float) -> list[Box]:
        lo, hi = sorted((z0, z1))
        seen: dict[int, Box] = {}
        for c in range(int(math.floor(lo / self.cell)), int(math.floor(hi / self.cell)) + 1):
            for b in self.grid.get(c, ()):
                seen[id(b)] = b
        return list(seen.values())

    def raycast(self, o: V3, d: V3, max_t: float) -> tuple[float, V3, V3] | None:
        best = None
        for b in self._near(o.z, o.z + d.z * max_t):
            hit = _ray_aabb(o, d, b, max_t)
            if hit and (best is None or hit[0] < best[0]):
                best = hit
        if best is None:
            return None
        t, n = best
        return t, o + d * t, n

    def sphere_hits(self, p: V3, r: float) -> bool:
        for b in self._near(p.z - r, p.z + r):
            q = V3(min(max(p.x, b.mn.x), b.mx.x), min(max(p.y, b.mn.y), b.mx.y),
                   min(max(p.z, b.mn.z), b.mx.z))
            if (p - q).length() < r:
                return True
        return False


def _ray_aabb(o: V3, d: V3, b: Box, max_t: float) -> tuple[float, V3] | None:
    t0, t1 = 0.0, max_t
    normal = None
    for axis in ("x", "y", "z"):
        oa, da = getattr(o, axis), getattr(d, axis)
        lo, hi = getattr(b.mn, axis), getattr(b.mx, axis)
        if abs(da) < 1e-9:
            if oa < lo or oa > hi:
                return None
            continue
        tn, tf = (lo - oa) / da, (hi - oa) / da
        sign = -1.0
        if tn > tf:
            tn, tf, sign = tf, tn, 1.0
        if tn > t0:
            t0 = tn
            normal = V3(**{a: (sign if a == axis else 0.0) for a in ("x", "y", "z")})
        t1 = min(t1, tf)
        if t0 > t1:
            return None
    if normal is None:          # origen dentro de la caja
        return None
    return t0, normal


# ---------------------------------------------------------------------------
# Búsqueda de anclaje: abanico de rayos + puntuación
# ---------------------------------------------------------------------------
def find_anchor(city: City, pos: V3, travel: V3, side: float, t: SwingTuning,
                speed: float = 0.0) -> AnchorCandidate | None:
    fwd = travel.horizontal().normalized()
    right = fwd.cross(UP).normalized()
    origin = pos + UP * 0.8
    ideal = ideal_anchor_point(pos, travel, side, t, speed)
    best: AnchorCandidate | None = None
    for f_off in (-8.0, -2.0, 4.0, 10.0):
        for u_off in (-8.0, 0.0, 8.0):
            for lat in (0.6, 1.0, 1.6, 2.4, -1.0, -2.0):
                target = ideal + fwd * f_off + UP * u_off + right * (side * t.anchor_ideal_side * (lat - 1.0))
                d = (target - origin).normalized()
                hit = city.raycast(origin, d, t.anchor_max_distance)
                if hit is None:
                    continue
                _, point, normal = hit
                cand = AnchorCandidate(point=point, normal=normal, ground_y=0.0)
                cand.score = score_anchor(cand, pos, travel, side, t, speed)
                if cand.score > 0.0 and (best is None or cand.score > best.score):
                    best = cand
    return best


# ---------------------------------------------------------------------------
# Piloto automático
# ---------------------------------------------------------------------------
@dataclass
class SwingRecord:
    attach_speed: float
    attach_height: float
    rope: float
    duration: float = 0.0
    max_speed: float = 0.0
    max_g: float = 0.0
    min_height: float = 1e9
    release_speed: float = 0.0
    release_angle: float = 0.0
    perfect: bool = False


@dataclass
class RunResult:
    label: str
    time: float
    distance: float
    swings: list[SwingRecord] = field(default_factory=list)
    collisions: int = 0
    ground_hits: int = 0
    max_lateral: float = 0.0
    failed_attach: int = 0
    trajectory: list[tuple] = field(default_factory=list)


def run(t: SwingTuning, city: City, *, label: str, duration: float = 60.0,
        release_angle: float = 40.0, start: V3 | None = None, start_vel: V3 | None = None,
        dive_until_y: float | None = None, record: bool = False,
        use_cruise: bool = True) -> RunResult:
    pend = RegulatedPendulum(t)
    pos = start or V3(0.0, 45.0, 0.0)
    vel = start_vel or V3(0.0, 0.0, 12.0)
    travel = V3(0.0, 0.0, 1.0)
    side = 1.0
    state = "DIVE" if dive_until_y is not None else "FALL"
    since_release = 1.0
    res = RunResult(label=label, time=0.0, distance=0.0)
    rec: SwingRecord | None = None
    z0 = pos.z
    steer_right = V3(-1.0, 0.0, 0.0)      # derecha de cámara mirando a +Z (Y arriba)
    in_collision = False
    skyline = 80.0                        # EMA de la altura de los anclajes encontrados
    steps = int(duration / H)

    for i in range(steps):
        if state in ("FALL", "DIVE"):
            # Mantiene el carril: corrige la deriva lateral con el control aéreo.
            control = V3(-pos.x * 0.15 - vel.x * 0.3, 0.0, 0.0)
            pos, vel = step_air(pos, vel, H, t, dive=(state == "DIVE"),
                                control=control, forward=travel)
            since_release += H
            if state == "DIVE" and pos.y <= dive_until_y:
                state = "FALL"
                since_release = 1.0
            # Modelo de jugador: dispara tras el ápice, esperando más si va por
            # encima de su altura de crucero (así es como se controla la altitud).
            cruise_y = t.cruise_skyline_fraction * skyline
            ready = since_release > 0.2 and vel.y < -2.0 and pos.y < cruise_y + 12.0
            want = state == "FALL" and (ready or vel.y < -14.0 or pos.y < 18.0)
            if want:
                cand = find_anchor(city, pos, travel, side, t, vel.length())
                if cand is None:
                    res.failed_attach += 1
                else:
                    skyline += (cand.point.y - skyline) * 0.3
                    cruise_y = cand.ground_y + t.cruise_skyline_fraction * (skyline - cand.ground_y)
                    pend.attach(pos, vel, cand.point, travel, cand.ground_y, cruise_y if use_cruise else None)
                    rec = SwingRecord(attach_speed=vel.length(), attach_height=pos.y, rope=pend.length)
                    state = "SWING"
        else:
            # Steering suave hacia el centro de la avenida (como haría un jugador).
            steer = max(-1.0, min(1.0, pos.x * 0.08 + vel.x * 0.05))
            s = pend.step(H, SwingInput(steer=steer, steer_right=steer_right))
            pos, vel = pend.pos, pend.vel
            rec.duration += H
            rec.max_speed = max(rec.max_speed, s.speed)
            rec.max_g = max(rec.max_g, s.g_force)
            rec.min_height = min(rec.min_height, pos.y)
            if s.swing_angle_deg >= release_angle or pend.should_auto_release():
                rec.release_angle = s.swing_angle_deg
                vel, rec.perfect = pend.release()
                rec.release_speed = vel.length()
                res.swings.append(rec)
                state, since_release, side = "FALL", 0.0, -side

        if pos.y < BODY_RADIUS:
            res.ground_hits += 1
            pos.y, vel.y = BODY_RADIUS, max(vel.y, 0.0)
        hit = city.sphere_hits(pos, BODY_RADIUS)
        if hit and not in_collision:
            res.collisions += 1
        in_collision = hit
        res.max_lateral = max(res.max_lateral, abs(pos.x))
        if record and i % 4 == 0:
            res.trajectory.append((i * H, state, pos.x, pos.y, pos.z, vel.length(),
                                   pend.sample.g_force if state == "SWING" else 1.0))

    res.time = steps * H
    res.distance = pos.z - z0
    return res


def physical_baseline(t: SwingTuning) -> SwingTuning:
    """Péndulo 'de libro': sin asistencias. Sirve para justificar cada una."""
    return replace(t, gravity_scale_swing_down=2.0, gravity_scale_swing_up=2.0,
                   catch_retention=0.0, attach_min_tangent_speed=0.0,
                   boost_accel_max=0.0, pivot_center_strength=0.0, pivot_shift_max=0.0,
                   release_up_boost=0.0, release_fwd_boost=0.0, lane_keep=0.0,
                   steer_accel=0.0)


def summarize(r: RunResult) -> str:
    sw = r.swings or [SwingRecord(0, 0, 0)]
    steady = sw[3:] or sw          # descarta el arranque
    def m(f):
        return statistics.mean(f(s) for s in steady)
    lines = [
        f"== {r.label} ==",
        f"  distancia {r.distance:7.1f} m en {r.time:.0f} s -> crucero {r.distance / r.time:5.1f} m/s",
        f"  balanceos {len(r.swings):3d} | fallos de anclaje {r.failed_attach} | "
        f"colisiones fachada {r.collisions} | toques de suelo {r.ground_hits} | |x| max {r.max_lateral:.1f} m",
        f"  por balanceo (régimen): duración {m(lambda s: s.duration):.2f} s | cuerda {m(lambda s: s.rope):.1f} m | "
        f"v enganche {m(lambda s: s.attach_speed):.1f} | v max {m(lambda s: s.max_speed):.1f} | "
        f"v suelta {m(lambda s: s.release_speed):.1f} m/s",
        f"  G max media {m(lambda s: s.max_g):.2f} g (pico {max(s.max_g for s in sw):.2f}) | "
        f"altura mín. media {m(lambda s: s.min_height):.1f} m (mín. {min(s.min_height for s in sw):.1f}) | "
        f"sueltas perfectas {sum(s.perfect for s in r.swings)}/{len(r.swings)}",
    ]
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", help="vuelca la trayectoria del run principal")
    ap.add_argument("--seconds", type=float, default=60.0)
    args = ap.parse_args()

    t = SwingTuning()
    city = City(build_city())
    print(f"v terminal caída {terminal_velocity(t):.1f} m/s | picada {terminal_velocity(t, dive=True):.1f} m/s\n")

    main_run = run(t, city, label="Regulado, suelta perfecta (40°)", duration=args.seconds, record=bool(args.csv))
    print(summarize(main_run))
    print(summarize(run(t, city, label="Regulado, suelta temprana (25°)", duration=args.seconds, release_angle=25.0)))
    print(summarize(run(t, city, label="Regulado, suelta tardía (60°)", duration=args.seconds, release_angle=60.0)))
    print(summarize(run(physical_baseline(t), city, label="Péndulo físico sin asistencias", duration=args.seconds)))

    # Picada -> balanceo: la maniobra de momento clave.
    dive = run(t, city, label="Picada desde 160 m -> swing a 60 m", duration=8.0,
               start=V3(0, 160, 0), start_vel=V3(0, 0, 15), dive_until_y=60.0)
    first = dive.swings[0] if dive.swings else None
    if first:
        print(f"== {dive.label} ==\n  v enganche {first.attach_speed:.1f} m/s -> v max {first.max_speed:.1f} "
              f"-> v suelta {first.release_speed:.1f} m/s | G pico {first.max_g:.2f}")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "state", "x", "y", "z", "speed", "g"])
            w.writerows(main_run.trajectory)
        print(f"\ntrayectoria -> {args.csv}")


if __name__ == "__main__":
    main()
