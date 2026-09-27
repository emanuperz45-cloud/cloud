"""
Núcleo matemático del sistema de balanceo ("péndulo regulado").

Es la fuente única de verdad en Python: lo usan el simulador de calibración
(city_sim.py), los tests y el baker de Blender (blender_arc_baker.py). La
versión runtime en GDScript (godot/swing_system/regulated_pendulum.gd) es un
port 1:1 de este archivo; si cambias una fórmula aquí, cámbiala allí.

Convenciones: metros, segundos, masa unitaria (todo son aceleraciones), eje Y
arriba (igual que Godot). El baker de Blender convierte a Z-up.
"""
from __future__ import annotations

import math
from dataclasses import dataclass


# ---------------------------------------------------------------------------
# Vector 3D mínimo (sin dependencias, para que corra en Blender y en CI)
# ---------------------------------------------------------------------------
class V3:
    __slots__ = ("x", "y", "z")

    def __init__(self, x: float = 0.0, y: float = 0.0, z: float = 0.0):
        self.x, self.y, self.z = float(x), float(y), float(z)

    def __add__(self, o: "V3") -> "V3":
        return V3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: "V3") -> "V3":
        return V3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s: float) -> "V3":
        return V3(self.x * s, self.y * s, self.z * s)

    __rmul__ = __mul__

    def __truediv__(self, s: float) -> "V3":
        return V3(self.x / s, self.y / s, self.z / s)

    def __neg__(self) -> "V3":
        return V3(-self.x, -self.y, -self.z)

    def dot(self, o: "V3") -> float:
        return self.x * o.x + self.y * o.y + self.z * o.z

    def cross(self, o: "V3") -> "V3":
        return V3(self.y * o.z - self.z * o.y,
                  self.z * o.x - self.x * o.z,
                  self.x * o.y - self.y * o.x)

    def length(self) -> float:
        return math.sqrt(self.dot(self))

    def normalized(self, fallback: "V3 | None" = None) -> "V3":
        n = self.length()
        if n < 1e-9:
            return fallback if fallback is not None else V3()
        return self / n

    def horizontal(self) -> "V3":
        return V3(self.x, 0.0, self.z)

    def tuple(self) -> tuple[float, float, float]:
        return (self.x, self.y, self.z)

    def __repr__(self) -> str:
        return f"V3({self.x:.3f}, {self.y:.3f}, {self.z:.3f})"


UP = V3(0.0, 1.0, 0.0)


def clamp(x: float, lo: float, hi: float) -> float:
    return lo if x < lo else hi if x > hi else x


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def move_toward(a: float, b: float, step: float) -> float:
    if abs(b - a) <= step:
        return b
    return a + math.copysign(step, b - a)


def smoothstep(e0: float, e1: float, x: float) -> float:
    t = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def bell(x: float, sigma: float) -> float:
    """Campana gaussiana normalizada a 1 en x = 0."""
    return math.exp(-(x / sigma) ** 2)


def project_on_plane(v: V3, n: V3) -> V3:
    return v - n * v.dot(n)


# ---------------------------------------------------------------------------
# Parámetros de calibración (valores de referencia validados con city_sim.py)
# ---------------------------------------------------------------------------
@dataclass
class SwingTuning:
    g: float = 9.81

    # Escalas de gravedad por estado (game feel: caída pesada, subida flotante)
    gravity_scale_fall: float = 1.8
    gravity_scale_swing_down: float = 2.0
    gravity_scale_swing_up: float = 1.7
    gravity_scale_dive: float = 2.6
    gravity_scale_zip: float = 0.2

    # Cuerda
    rope_min: float = 8.0            # L_min
    rope_max: float = 45.0           # L_max
    ground_clearance: float = 3.5    # el fondo del arco nunca baja de suelo + esto
    reel_speed: float = 14.0         # m/s máx. de recogida para respetar clearance

    # Pivote dinámico (se resuelve al enganchar)
    pivot_center_strength: float = 0.65   # fracción del offset lateral corregido
    pivot_attach_angle_deg: float = 45.0  # ángulo de ataque objetivo (desde la vertical)
    pivot_shift_max: float = 7.0          # m máx. de desplazamiento del pivote
    pivot_max_divergence_deg: float = 22.0  # ángulo máx. web visual vs cuerda física

    # Conservación / redirección de momento
    catch_retention: float = 0.92         # % de la velocidad radial redirigida al tensar
    attach_min_tangent_speed: float = 13.0

    # Inyección de impulso en el fondo del arco (regulador de energía)
    boost_accel_max: float = 18.0
    boost_sigma_deg: float = 30.0
    boost_gain: float = 3.0               # 1/s, ganancia proporcional del regulador
    target_bottom_speed: float = 29.0     # velocidad de crucero en el fondo del arco
    altitude_energy_weight: float = 0.75  # 0 = ignora altura, 1 = energía total pura
    cruise_skyline_fraction: float = 0.5  # altura de crucero = fracción del skyline local

    # Límites de velocidad
    speed_soft_cap: float = 34.0
    speed_hard_cap: float = 48.0
    overspeed_drag: float = 0.03          # a = -k (|v| - soft)^2
    swing_air_drag: float = 0.0008        # cuadrática durante el balanceo

    # Control lateral
    steer_accel: float = 16.0
    lane_keep: float = 1.2                # 1/s, amortiguación de deriva lateral

    # Suelta (release)
    release_up_boost: float = 5.5
    release_fwd_boost: float = 3.0
    release_perfect_angle_deg: float = 40.0
    release_perfect_window_deg: float = 9.0
    release_perfect_bonus: float = 0.45
    release_max_up_speed: float = 17.0
    release_band_height: float = 12.0     # m sobre crucero donde el boost vertical llega a 0
    auto_release_angle_deg: float = 95.0
    stall_speed: float = 3.0

    # Caída libre / picada
    fall_drag: float = 0.011              # v_term = sqrt(g_fall / k) ~ 40 m/s
    dive_drag: float = 0.0076             # v_term ~ 58 m/s
    air_horizontal_damping: float = 0.04  # 1/s, conserva momento horizontal
    air_control_accel: float = 7.0
    dive_forward_accel: float = 4.0

    # Web zip / point launch
    zip_speed: float = 26.0
    zip_up_speed: float = 5.0
    zip_duration: float = 0.3
    point_launch_forward: float = 18.0
    point_launch_up: float = 19.0
    point_launch_perfect_mult: float = 1.25

    # Búsqueda de anclajes (offsets del punto ideal, en marco local de viaje)
    anchor_ideal_forward: float = 18.0
    anchor_ideal_up: float = 22.0
    anchor_ideal_side: float = 9.0
    anchor_min_height: float = 6.0
    anchor_max_distance: float = 65.0
    anchor_ideal_radius: float = 30.0
    anchor_speed_scale_min: float = 0.8   # el punto ideal se aleja con la velocidad
    anchor_speed_scale_max: float = 1.5   # para mantener la fuerza G en rango


# ---------------------------------------------------------------------------
# Péndulo regulado
# ---------------------------------------------------------------------------
@dataclass
class SwingInput:
    steer: float = 0.0              # -1 (izq) .. 1 (der)
    steer_right: V3 | None = None   # vector derecho de cámara (horizontal)
    hold: bool = True               # gatillo de balanceo mantenido
    external_accel: V3 | None = None  # asistencias del motor (evitación de colisiones)


@dataclass
class SwingSample:
    """Lo que la capa de animación consume cada frame."""
    swing_angle_deg: float = 0.0   # < 0 bajando hacia el fondo, > 0 subiendo
    phase: float = 0.0             # -1 .. 1 (0 = fondo del arco)
    tension: float = 0.0           # m/s^2 (masa unitaria)
    g_force: float = 0.0           # tensión en g
    taut: bool = False
    rope_length: float = 0.0
    boost: float = 0.0             # aceleración inyectada este paso
    speed: float = 0.0


class RegulatedPendulum:
    """
    Péndulo esférico con restricción unilateral (la cuerda solo tira), pivote
    dinámico resuelto al enganchar, regulación de longitud y regulador de
    energía que inyecta aceleración tangencial en el fondo del arco.
    """

    PHASE_REF_DEG = 75.0

    def __init__(self, tuning: SwingTuning):
        self.t = tuning
        self.active = False
        self.pos = V3()
        self.vel = V3()
        self.anchor = V3()   # punto real en la geometría (donde se dibuja la web)
        self.pivot = V3()    # pivote físico regulado
        self.travel = V3(0, 0, 1)
        self.length = 0.0
        self.ground_y = 0.0
        self.cruise_y: float | None = None
        self.time = 0.0
        self.sample = SwingSample()

    # -- helpers ----------------------------------------------------------
    def rope_dir(self) -> V3:
        """Unitario del pivote al personaje."""
        return (self.pos - self.pivot).normalized(V3(0, -1, 0))

    def signed_angle_deg(self) -> float:
        n = self.rope_dir()
        theta = math.degrees(math.acos(clamp(-n.y, -1.0, 1.0)))
        h = n.horizontal()
        # Si nos movemos alejándonos de la vertical del pivote, estamos subiendo.
        return theta if self.vel.dot(h) >= 0.0 else -theta

    def bottom_y(self) -> float:
        return self.pivot.y - self.length

    # -- ciclo de vida ----------------------------------------------------
    def solve_pivot(self, pos: V3, anchor: V3, travel: V3) -> V3:
        """Pivote dinámico: centrado lateral + colocación del fondo del arco."""
        t = self.t
        fwd = travel.horizontal().normalized(V3(0, 0, 1))
        right = fwd.cross(UP).normalized()
        rel = anchor - pos
        lateral = rel.dot(right)
        forward = rel.dot(fwd)
        height = max(rel.y, 0.1)

        d_lat = -t.pivot_center_strength * lateral
        # Queremos que la cuerda arranque a pivot_attach_angle desde la vertical.
        desired_forward = height * math.tan(math.radians(t.pivot_attach_angle_deg))
        d_fwd = clamp(desired_forward - forward, -t.pivot_shift_max, t.pivot_shift_max)
        pivot = anchor + right * d_lat + fwd * d_fwd

        # Limitar la divergencia entre la web visual (pos->anchor) y la física.
        va = (anchor - pos).normalized()
        vp = (pivot - pos).normalized()
        div = math.degrees(math.acos(clamp(va.dot(vp), -1.0, 1.0)))
        if div > t.pivot_max_divergence_deg:
            k = t.pivot_max_divergence_deg / div
            pivot = anchor + (pivot - anchor) * k
        return pivot

    def attach(self, pos: V3, vel: V3, anchor: V3, travel: V3, ground_y: float,
               cruise_y: float | None = None) -> None:
        t = self.t
        self.active = True
        self.time = 0.0
        self.pos = pos
        self.anchor = anchor
        self.travel = travel.horizontal().normalized(V3(0, 0, 1))
        self.ground_y = ground_y
        self.cruise_y = cruise_y
        self.pivot = self.solve_pivot(pos, anchor, self.travel)
        self.length = clamp((pos - self.pivot).length(), t.rope_min, t.rope_max)

        # Conservación de momento: la componente que se aleja del pivote se
        # redirige al plano tangente en vez de perderse (el "catch").
        n = self.rope_dir()
        v_out = vel.dot(n)
        v_t = vel - n * max(v_out, 0.0)
        speed = vel.length()
        vt_len = v_t.length()
        if v_out > 0.0 and vt_len > 1.0:
            v_t = v_t * (lerp(vt_len, speed, t.catch_retention) / vt_len)

        # "Attach kick": garantiza velocidad tangencial mínima hacia delante.
        tan_fwd = project_on_plane(self.travel, n).normalized()
        along = v_t.dot(tan_fwd)
        if along < t.attach_min_tangent_speed:
            v_t = v_t + tan_fwd * (t.attach_min_tangent_speed - along)
        self.vel = v_t
        self.sample = SwingSample(rope_length=self.length, speed=v_t.length())

    def release(self, allow_perfect: bool = True) -> tuple[V3, bool]:
        """Devuelve (velocidad de salida, suelta perfecta). allow_perfect=False
        para sueltas automáticas (swing encadenado), que no reciben bonus."""
        t = self.t
        self.active = False
        ang = self.signed_angle_deg()
        perfect = allow_perfect and abs(ang - t.release_perfect_angle_deg) <= t.release_perfect_window_deg
        mult = 1.0 + t.release_perfect_bonus if perfect else 1.0
        up_scale = clamp(ang / t.release_perfect_angle_deg, 0.0, 1.0)
        if self.cruise_y is not None:
            # Banda de altitud: por encima de la altura de crucero el boost
            # vertical se desvanece; así la altitud la decide el timing del
            # jugador y no la acumulación de boosts.
            above = self.pos.y - self.cruise_y
            up_scale *= clamp(1.0 - above / t.release_band_height, 0.0, 1.0)
        fwd = self.vel.horizontal().normalized(self.travel)
        v = self.vel + UP * (t.release_up_boost * mult * up_scale) + fwd * (t.release_fwd_boost * mult)
        v.y = min(v.y, t.release_max_up_speed)
        return v, perfect

    # -- integración ------------------------------------------------------
    def step(self, h: float, inp: SwingInput | None = None) -> SwingSample:
        t = self.t
        inp = inp or SwingInput()
        self.time += h
        n = self.rope_dir()
        ang = self.signed_angle_deg()

        # 1) Gravedad asimétrica
        g_scale = t.gravity_scale_swing_down if self.vel.y < 0.0 else t.gravity_scale_swing_up
        g_eff = t.g * g_scale
        acc = V3(0.0, -g_eff, 0.0)

        speed = self.vel.length()
        v_hat = self.vel.normalized(self.travel)

        # 2) Regulador de energía: inyección tangencial con campana en el fondo
        drop = max(self.pos.y - self.bottom_y(), 0.0)
        v_bottom_pred = math.sqrt(speed * speed + 2.0 * g_eff * drop)
        boost = 0.0
        if inp.hold:
            err = self.goal_bottom_speed(g_eff) - v_bottom_pred
            boost = clamp(t.boost_gain * err, 0.0, t.boost_accel_max) * bell(ang, t.boost_sigma_deg)
            acc = acc + v_hat * boost

        # 3) Steering lateral + lane keeping (en el plano tangente)
        if inp.steer_right is not None:
            s_t = project_on_plane(inp.steer_right, n).normalized()
            acc = acc + s_t * (inp.steer * t.steer_accel)
            acc = acc - s_t * (self.vel.dot(s_t) * t.lane_keep * (1.0 - abs(inp.steer)))

        if inp.external_accel is not None:
            acc = acc + project_on_plane(inp.external_accel, n)

        # 4) Arrastre + techo blando de velocidad
        acc = acc - self.vel * (t.swing_air_drag * speed)
        if speed > t.speed_soft_cap:
            acc = acc - v_hat * (t.overspeed_drag * (speed - t.speed_soft_cap) ** 2)

        # Euler semi-implícito
        self.vel = self.vel + acc * h
        self.pos = self.pos + self.vel * h

        # 5) Regulación de longitud (clearance con el suelo) + spin-up
        l_prev = self.length
        max_len = self.pivot.y - (self.ground_y + t.ground_clearance)
        l_target = clamp(min(self.length, max_len), t.rope_min, t.rope_max)
        self.length = move_toward(self.length, l_target, t.reel_speed * h)

        # 6) Restricción unilateral con proyección que preserva la rapidez
        d_vec = self.pos - self.pivot
        d = d_vec.length()
        taut = d >= self.length - 1e-4
        if taut:
            n = d_vec / d
            self.pos = self.pivot + n * self.length
            v_r = self.vel.dot(n)
            if v_r > 0.0:
                before = self.vel.length()
                self.vel = self.vel - n * v_r
                after = self.vel.length()
                if after > 1.0:
                    # retention = 1 conserva la rapidez (redirección total);
                    # retention = 0 es la proyección física clásica.
                    self.vel = self.vel * (lerp(after, before, t.catch_retention) / after)
            if self.length < l_prev:
                # Conservación de momento angular al recoger cuerda.
                v_rad = n * self.vel.dot(n)
                self.vel = v_rad + (self.vel - v_rad) * (l_prev / self.length)

        speed = self.vel.length()
        if speed > t.speed_hard_cap:
            self.vel = self.vel * (t.speed_hard_cap / speed)
            speed = t.speed_hard_cap

        # 7) Tensión analítica: T = |v_t|^2 / L + g_eff * (-n.y)
        tension = 0.0
        if taut:
            v_t = project_on_plane(self.vel, n)
            tension = max(v_t.dot(v_t) / self.length - g_eff * n.y, 0.0)

        ang = self.signed_angle_deg()
        self.sample = SwingSample(
            swing_angle_deg=ang,
            phase=clamp(ang / self.PHASE_REF_DEG, -1.0, 1.0),
            tension=tension,
            g_force=tension / t.g,
            taut=taut,
            rope_length=self.length,
            boost=boost,
            speed=speed,
        )
        return self.sample

    def goal_bottom_speed(self, g_eff: float) -> float:
        """
        Velocidad objetivo en el fondo del arco. Con banda de crucero, el
        regulador trabaja sobre energía total: si el arco pasa por encima de la
        altura de crucero, esa energía potencial sobrante se descuenta de la
        cinética objetivo (y viceversa), de modo que la altitud no deriva.
        """
        t = self.t
        goal = t.target_bottom_speed
        if self.cruise_y is None:
            return goal
        excess = self.bottom_y() - self.cruise_y
        goal_sq = goal * goal - 2.0 * g_eff * t.altitude_energy_weight * excess
        lo, hi = t.attach_min_tangent_speed, t.speed_soft_cap
        return clamp(math.sqrt(max(goal_sq, 0.0)), lo, hi)

    def should_auto_release(self) -> bool:
        s = self.sample
        return (s.swing_angle_deg >= self.t.auto_release_angle_deg
                or (s.swing_angle_deg > 0.0 and s.speed < self.t.stall_speed))


# ---------------------------------------------------------------------------
# Caída libre / picada / zip
# ---------------------------------------------------------------------------
def step_air(pos: V3, vel: V3, h: float, t: SwingTuning, *, dive: bool = False,
             zip_active: bool = False, control: V3 | None = None,
             forward: V3 | None = None) -> tuple[V3, V3]:
    if zip_active:
        g_scale = t.gravity_scale_zip
    else:
        g_scale = t.gravity_scale_dive if dive else t.gravity_scale_fall
    k = t.dive_drag if dive else t.fall_drag
    acc = V3(0.0, -t.g * g_scale, 0.0)
    acc.y -= k * abs(vel.y) * vel.y                # arrastre cuadrático vertical
    acc = acc - vel.horizontal() * t.air_horizontal_damping
    if control is not None:
        acc = acc + control.horizontal() * t.air_control_accel
    if dive and forward is not None:
        acc = acc + forward.horizontal().normalized() * t.dive_forward_accel
    vel = vel + acc * h
    pos = pos + vel * h
    return pos, vel


def web_zip_velocity(vel: V3, aim: V3, t: SwingTuning) -> V3:
    fwd = aim.horizontal().normalized(V3(0, 0, 1))
    along = max(vel.dot(fwd), t.zip_speed)
    lateral = project_on_plane(vel.horizontal(), fwd) * 0.3
    return fwd * along + lateral + UP * max(vel.y * 0.2, t.zip_up_speed)


def point_launch_velocity(forward: V3, t: SwingTuning, perfect: bool) -> V3:
    m = t.point_launch_perfect_mult if perfect else 1.0
    fwd = forward.horizontal().normalized(V3(0, 0, 1))
    return fwd * (t.point_launch_forward * m) + UP * (t.point_launch_up * m)


def terminal_velocity(t: SwingTuning, dive: bool = False) -> float:
    g = t.g * (t.gravity_scale_dive if dive else t.gravity_scale_fall)
    return math.sqrt(g / (t.dive_drag if dive else t.fall_drag))


# ---------------------------------------------------------------------------
# Puntuación de anclajes (independiente del motor)
# ---------------------------------------------------------------------------
@dataclass
class AnchorCandidate:
    point: V3
    normal: V3
    ground_y: float = 0.0     # altura del suelo bajo el fondo del arco
    score: float = 0.0


def anchor_speed_scale(speed: float, t: SwingTuning) -> float:
    """
    A más velocidad, cuerda más larga: la aceleración centrípeta v^2/L se
    mantiene en un rango legible (G estable) y el arco cubre más distancia.
    """
    return clamp(speed / t.target_bottom_speed, t.anchor_speed_scale_min, t.anchor_speed_scale_max)


def ideal_anchor_point(pos: V3, travel: V3, side: float, t: SwingTuning, speed: float = 0.0) -> V3:
    fwd = travel.horizontal().normalized(V3(0, 0, 1))
    right = fwd.cross(UP).normalized()
    k = anchor_speed_scale(speed, t)
    return (pos + fwd * (t.anchor_ideal_forward * k) + UP * (t.anchor_ideal_up * k)
            + right * (side * t.anchor_ideal_side))


def score_anchor(c: AnchorCandidate, pos: V3, travel: V3, side: float,
                 t: SwingTuning, speed: float = 0.0) -> float:
    """Devuelve la puntuación [0..1] o -1 si el candidato es inválido."""
    rel = c.point - pos
    height = rel.y
    dist = rel.length()
    if height < t.anchor_min_height or dist < t.rope_min or dist > t.anchor_max_distance:
        return -1.0
    fwd = travel.horizontal().normalized(V3(0, 0, 1))
    right = fwd.cross(UP).normalized()
    horiz = rel.horizontal()
    if horiz.dot(fwd) < -2.0:            # detrás del jugador
        return -1.0
    if c.point.y - (c.ground_y + t.ground_clearance) < t.rope_min:
        return -1.0                      # el arco no cabe sobre el suelo
    if c.normal.y < -0.5:                # cara inferior de un voladizo
        return -1.0

    ideal = ideal_anchor_point(pos, travel, side, t, speed)
    ideal_up = ideal.y - pos.y
    s_dist = 1.0 - clamp((c.point - ideal).length() / t.anchor_ideal_radius, 0.0, 1.0)
    s_dir = ((horiz.normalized().dot(fwd) + 1.0) * 0.5) ** 2
    s_height = 1.0 - clamp(abs(height - ideal_up) / ideal_up, 0.0, 1.0)
    lat = rel.dot(right)
    s_side = 1.0 if lat * side > 0.0 else 0.4
    return 0.40 * s_dist + 0.25 * s_dir + 0.20 * s_height + 0.15 * s_side
