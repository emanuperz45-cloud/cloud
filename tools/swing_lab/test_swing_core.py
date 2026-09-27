"""Tests del núcleo del péndulo regulado.  python3 -m unittest -v (desde tools/swing_lab)"""
import math
import unittest
from dataclasses import replace

import city_sim
from swing_core import (UP, AnchorCandidate, Glider, RegulatedPendulum, SwingInput, SwingTuning, V3,
                        score_anchor, step_air, terminal_velocity)

H = 1.0 / 240.0


def pure_pendulum_tuning() -> SwingTuning:
    """Sin asistencias ni arrastre: debe comportarse como un péndulo ideal."""
    return replace(SwingTuning(), gravity_scale_swing_down=2.0, gravity_scale_swing_up=2.0,
                   catch_retention=0.0, attach_min_tangent_speed=0.0, boost_accel_max=0.0,
                   pivot_center_strength=0.0, pivot_shift_max=0.0, swing_air_drag=0.0,
                   overspeed_drag=0.0, lane_keep=0.0)


class PendulumTests(unittest.TestCase):
    def setUp(self):
        self.t = pure_pendulum_tuning()
        self.p = RegulatedPendulum(self.t)
        self.anchor = V3(0.0, 100.0, 0.0)
        L = 25.0
        start = self.anchor + V3(0.0, -math.cos(math.radians(50)), -math.sin(math.radians(50))) * L
        self.p.attach(start, V3(0.0, 0.0, 0.0), self.anchor, V3(0, 0, 1), ground_y=-1000.0)

    def energy(self) -> float:
        g_eff = self.t.g * 2.0
        return 0.5 * self.p.vel.dot(self.p.vel) + g_eff * self.p.pos.y

    def test_pivot_equals_anchor_without_regulation(self):
        self.assertAlmostEqual((self.p.pivot - self.anchor).length(), 0.0, places=6)

    def test_energy_conserved_and_rope_respected(self):
        e0 = self.energy()
        for _ in range(int(3.0 / H)):
            self.p.step(H, SwingInput(hold=False))
            self.assertLessEqual((self.p.pos - self.p.pivot).length(), self.p.length + 1e-6)
        self.assertLess(abs(self.energy() - e0) / abs(e0), 0.01)

    def test_tension_at_bottom_matches_closed_form(self):
        g_eff = self.t.g * 2.0
        best = None
        for _ in range(int(2.0 / H)):
            s = self.p.step(H, SwingInput(hold=False))
            if best is None or abs(s.swing_angle_deg) < abs(best[0]):
                best = (s.swing_angle_deg, s.tension, self.p.vel.length())
            if s.swing_angle_deg > 10.0:
                break
        _, tension, v = best
        expected = v * v / self.p.length + g_eff
        self.assertAlmostEqual(tension, expected, delta=expected * 0.02)

    def test_phase_sign_convention(self):
        s = self.p.step(H, SwingInput(hold=False))
        self.assertLess(s.swing_angle_deg, 0.0)     # bajando hacia el fondo
        for _ in range(int(3.0 / H)):
            s = self.p.step(H, SwingInput(hold=False))
            if s.swing_angle_deg > 5.0:
                break
        self.assertGreater(s.swing_angle_deg, 0.0)  # subiendo tras el fondo


class AssistTests(unittest.TestCase):
    def setUp(self):
        self.t = SwingTuning()

    def test_catch_redirects_momentum(self):
        p = RegulatedPendulum(replace(self.t, pivot_center_strength=0.0, pivot_shift_max=0.0))
        anchor = V3(0.0, 100.0, 20.0)
        pos = V3(0.0, 80.0, 0.0)                   # cuerda a 45°, cayendo en vertical
        vel = V3(0.0, -30.0, 0.0)
        p.attach(pos, vel, anchor, V3(0, 0, 1), ground_y=0.0)
        physical = 30.0 * math.cos(math.radians(45))
        self.assertGreater(p.vel.length(), physical + 0.8 * (30.0 - physical))
        n = p.rope_dir()
        self.assertLessEqual(p.vel.dot(n), 1e-6)   # sin componente que estire la cuerda

    def test_attach_kick_guarantees_forward_speed(self):
        p = RegulatedPendulum(self.t)
        p.attach(V3(0, 40, 0), V3(0, 0, 0), V3(3, 62, 18), V3(0, 0, 1), ground_y=0.0)
        self.assertGreaterEqual(p.vel.z, self.t.attach_min_tangent_speed * 0.7)

    def test_arc_bottom_respects_ground_clearance(self):
        p = RegulatedPendulum(self.t)
        ground = 30.0
        p.attach(V3(0, 45, 0), V3(0, -5, 20), V3(0, 72, 30), V3(0, 0, 1), ground_y=ground)
        lowest = 1e9
        for _ in range(int(2.0 / H)):
            p.step(H)
            lowest = min(lowest, p.pos.y)
        self.assertGreaterEqual(lowest, ground + self.t.ground_clearance - 0.25)

    def test_boost_raises_speed_towards_target(self):
        p = RegulatedPendulum(replace(self.t, speed_soft_cap=100.0))
        p.attach(V3(0, 50, 0), V3(0, 0, 10), V3(0, 72, 18), V3(0, 0, 1), ground_y=0.0)
        vmax = 0.0
        for _ in range(int(1.5 / H)):
            s = p.step(H)
            vmax = max(vmax, s.speed)
            if s.swing_angle_deg > 20.0:
                break
        no_boost = RegulatedPendulum(replace(self.t, boost_accel_max=0.0))
        no_boost.attach(V3(0, 50, 0), V3(0, 0, 10), V3(0, 72, 18), V3(0, 0, 1), ground_y=0.0)
        vmax_nb = 0.0
        for _ in range(int(1.5 / H)):
            s = no_boost.step(H)
            vmax_nb = max(vmax_nb, s.speed)
            if s.swing_angle_deg > 20.0:
                break
        self.assertGreater(vmax, vmax_nb + 2.0)

    def test_perfect_release_window(self):
        p = RegulatedPendulum(self.t)
        p.attach(V3(0, 50, 0), V3(0, 0, 20), V3(0, 72, 18), V3(0, 0, 1), ground_y=0.0)
        while p.step(H).swing_angle_deg < self.t.release_perfect_angle_deg:
            pass
        _, perfect = p.release()
        self.assertTrue(perfect)

    def test_pivot_centering_pulls_towards_travel_line(self):
        p = RegulatedPendulum(self.t)
        anchor = V3(-15.0, 70.0, 20.0)             # fachada a la derecha (-X)
        pivot = p.solve_pivot(V3(0, 45, 0), anchor, V3(0, 0, 1))
        self.assertLess(abs(pivot.x), abs(anchor.x))
        va = (anchor - V3(0, 45, 0)).normalized()
        vp = (pivot - V3(0, 45, 0)).normalized()
        self.assertLessEqual(math.degrees(math.acos(va.dot(vp))), self.t.pivot_max_divergence_deg + 1e-6)


class HoldToHangTests(unittest.TestCase):
    """Mantener el gatillo: misma telaraña, el arco se apaga y queda colgado."""

    def attach(self):
        t = SwingTuning()
        p = RegulatedPendulum(t)
        anchor = V3(-12.0, 80.0, 20.0)            # en una fachada a la derecha
        p.attach(V3(0, 55, 0), V3(0, -4, 22), anchor, V3(0, 0, 1), ground_y=0.0)
        return t, p, anchor

    def test_no_release_and_settles_under_anchor(self):
        t, p, anchor = self.attach()
        for _ in range(int(18.0 / H)):
            p.step(H, SwingInput(hold=True))
            self.assertLessEqual((p.pos - p.pivot).length(), p.length + 1e-6)
        self.assertTrue(p.sustain)
        self.assertLess(p.vel.length(), 0.5)                    # quieto, suspendido
        off = (p.pivot - anchor).horizontal().length()
        self.assertLessEqual(off, t.hang_wall_offset + 0.05)    # bajo el anclaje real
        self.assertAlmostEqual(p.pos.x, p.pivot.x, delta=0.3)   # colgando en vertical
        self.assertGreater(p.pos.y, t.ground_clearance)

    def test_first_arc_keeps_boost_until_reversal(self):
        _, p, _ = self.attach()
        seen_boost = False
        while not p.sustain:
            s = p.step(H, SwingInput(hold=True))
            seen_boost |= s.boost > 0.0
        self.assertTrue(seen_boost)
        self.assertLess(p.signed_angle_deg(), 0.0)              # empezó la vuelta

    def test_reel_climbs_and_descends_the_web(self):
        t, p, _ = self.attach()
        for _ in range(int(12.0 / H)):
            p.step(H)
        start = p.length
        for _ in range(int(1.0 / H)):
            p.step(H, SwingInput(reel=1.0))
        self.assertAlmostEqual(p.length, start - t.reel_climb_speed, delta=0.3)
        for _ in range(int(30.0 / H)):
            p.step(H, SwingInput(reel=1.0))
        self.assertAlmostEqual(p.length, t.hang_min_length, delta=1e-6)
        for _ in range(int(60.0 / H)):
            p.step(H, SwingInput(reel=-1.0))
        self.assertLessEqual(p.bottom_y(), p.pivot.y)
        self.assertGreaterEqual(p.bottom_y(), p.ground_y + t.ground_clearance - 1e-6)


class LoopTests(unittest.TestCase):
    def test_fast_short_swing_loops_then_settles(self):
        t = replace(SwingTuning(), pivot_center_strength=0.0, pivot_shift_max=0.0)
        p = RegulatedPendulum(t)
        anchor = V3(0.0, 30.0, 0.0)
        p.attach(V3(0.0, 21.0, 0.0), V3(0.0, 0.0, 32.0), anchor, V3(0, 0, 1), ground_y=-100.0)
        sustain_before_loop = False
        for _ in range(int(4.0 / H)):
            p.step(H)
            if p.loops == 0 and p.sustain:
                sustain_before_loop = True
            if p.loops >= 1:
                break
        self.assertEqual(p.loops, 1)                     # vuelta completa sin soltarse
        self.assertFalse(sustain_before_loop)            # cruzar la vertical no es inversión
        for _ in range(int(25.0 / H)):
            p.step(H)
        self.assertTrue(p.sustain)
        self.assertLess(p.vel.length(), 0.5)             # y acaba colgado

    def test_tighten_turns_a_fast_normal_swing_into_a_loop(self):
        # Swing normal de ciudad (cuerda ~30 m): sin tighten no hay loop; con tighten
        # mantenido cerca del fondo la cuerda se recoge y el arco da la vuelta.
        results = []
        for tighten in (False, True):
            p = RegulatedPendulum(SwingTuning())
            p.attach(V3(0, 60, 0), V3(0, -10, 38), V3(0, 88, 18), V3(0, 0, 1), ground_y=0.0)
            for _ in range(int(5.0 / H)):
                p.step(H, SwingInput(tighten=tighten))
                if p.loops:
                    break
            results.append((p.loops, p.length))
        self.assertEqual(results[0][0], 0)
        self.assertEqual(results[1][0], 1)
        self.assertLess(results[1][1], 22.0)

    def test_normal_swing_does_not_loop(self):
        p = RegulatedPendulum(SwingTuning())
        p.attach(V3(0, 50, 0), V3(0, 0, 20), V3(0, 72, 18), V3(0, 0, 1), ground_y=0.0)
        for _ in range(int(10.0 / H)):
            p.step(H)
        self.assertEqual(p.loops, 0)


class GliderTests(unittest.TestCase):
    """Web Wings: fineza, picado, encabritado, pérdida, viraje, túnel y corriente ascendente."""

    def fly(self, g, seconds, pitch=0.0, roll=0.0, **kw):
        pos = V3(0, 500, 0)
        for _ in range(int(seconds / H)):
            pos = pos + g.step(H, pitch, roll, **kw) * H
        return pos

    def test_neutral_glide_ratio(self):
        g = Glider(SwingTuning())
        g.open(V3(0, -2, 20))
        self.fly(g, 10.0)                            # estabiliza
        a = V3(0, 500, 0)
        b = self.fly(g, 10.0)
        ratio = b.horizontal().length() / (a.y - b.y)
        self.assertGreater(ratio, 6.3)
        self.assertLess(ratio, 8.0)
        self.assertAlmostEqual(g.speed, 28.3, delta=1.0)

    def test_dive_gains_speed_and_pull_up_trades_it_for_height(self):
        g = Glider(SwingTuning())
        g.open(V3(0, 0, 20))
        self.fly(g, 12.0, pitch=1.0)
        self.assertGreater(g.speed, 60.0)
        start = V3(0, 500, 0)
        top = start
        pos = start
        for _ in range(int(6.0 / H)):
            pos = pos + g.step(H, -1.0, 0.0) * H
            top = pos if pos.y > top.y else top
        self.assertGreater(top.y - start.y, 25.0)     # convierte velocidad en altura
        self.assertLess(g.speed, 25.0)

    def test_stall_drops_the_nose_and_recovers(self):
        g = Glider(SwingTuning())
        g.open(V3(0, 5, 12))
        min_gamma, min_speed, stalls = 1.0, 99.0, 0
        for _ in range(int(8.0 / H)):                 # encabritar sin parar
            was = g.stalled
            g.step(H, -1.0, 0.0)
            stalls += int(g.stalled and not was)
            min_gamma = min(min_gamma, g.gamma)
            min_speed = min(min_speed, g.speed)
        self.assertGreaterEqual(stalls, 1)
        self.assertLess(min_gamma, math.radians(-20.0))   # el morro cae
        self.assertGreater(min_speed, 5.0)                # sin pérdida profunda

    def test_full_bank_turns_around(self):
        g = Glider(SwingTuning())
        g.open(V3(0, -2, 20))
        psi0 = g.psi
        self.fly(g, 6.0, roll=1.0)
        self.assertLess(g.psi - psi0, -math.pi / 2)   # derecha = ψ decreciente

    def test_turn_rate_is_fast_at_any_speed(self):
        for speed, min_deg_s in ((25.0, 80.0), (65.0, 60.0)):
            g = Glider(SwingTuning())
            g.open(V3(0, 0, speed))
            self.fly(g, 0.5, roll=1.0)                   # entra en alabeo
            psi0 = g.psi
            self.fly(g, 1.0, roll=1.0)
            self.assertGreater(math.degrees(psi0 - g.psi), min_deg_s)

    def test_dive_open_boost(self):
        g = Glider(SwingTuning())
        g.open(V3(0, -40, 10), from_dive=True)
        self.assertTrue(g.boosted)
        self.assertAlmostEqual(g.speed, V3(0, -40, 10).length() + SwingTuning().glide_dive_boost, delta=1e-6)

    def test_tunnel_carries_to_cruise_and_keeps_on_axis(self):
        t = SwingTuning()
        g = Glider(t)
        g.open(V3(0, -2, 20))
        axis_o = V3(0, 500, 0)
        axis_d = V3(0, -0.03, 1).normalized()
        pos = V3(5, 497, 0)                              # entra descentrado
        max_off = 0.0
        for i in range(int(12.0 / H)):
            rel = pos - axis_o
            offset = axis_d * rel.dot(axis_d) - rel      # hacia el eje
            pos = pos + g.step(H, 0.0, 0.0, tunnel_dir=axis_d, tunnel=1.0,
                               tunnel_offset=offset) * H
            if i * H > 4.0:
                max_off = max(max_off, offset.length())
        self.assertLess(max_off, 2.0)                    # sin stick, el túnel te lleva
        self.assertGreater(g.speed, 50.0)
        self.assertLess(g.speed, t.glide_tunnel_speed)   # empuje con techo
        g2 = Glider(SwingTuning())
        g2.open(V3(0, -2, 20))
        end = self.fly(g2, 4.0, updraft=1.0)
        self.assertGreater(end.y, 500.0 + 30.0)
        # Cruzar una columna de 12 m a 20 m/s deja un impulso que dura al salir.
        g3 = Glider(SwingTuning())
        g3.open(V3(0, -2, 20))
        self.fly(g3, 0.6, updraft=1.0)
        lift_out = g3.lift
        after = self.fly(g3, 1.5)
        self.assertGreater(lift_out, 10.0)
        self.assertGreater(after.y, 500.0 + 5.0)


class AirAndAnchorTests(unittest.TestCase):
    def test_freefall_reaches_terminal_velocity(self):
        t = SwingTuning()
        pos, vel = V3(0, 5000, 0), V3()
        for _ in range(int(20.0 / H)):
            pos, vel = step_air(pos, vel, H, t)
        self.assertAlmostEqual(-vel.y, terminal_velocity(t), delta=0.5)

    def test_anchor_scoring_rejects_invalid(self):
        t = SwingTuning()
        pos, fwd = V3(0, 40, 0), V3(0, 0, 1)
        good = AnchorCandidate(V3(-8, 62, 18), V3(1, 0, 0))
        low = AnchorCandidate(V3(-8, 42, 18), V3(1, 0, 0))
        behind = AnchorCandidate(V3(-8, 62, -20), V3(1, 0, 0))
        overhang = AnchorCandidate(V3(-8, 62, 18), V3(0, -1, 0))
        self.assertGreater(score_anchor(good, pos, fwd, 1.0, t), 0.5)
        for c in (low, behind, overhang):
            self.assertEqual(score_anchor(c, pos, fwd, 1.0, t), -1.0)


class CitySimTests(unittest.TestCase):
    def test_regulated_run_is_clean(self):
        t = SwingTuning()
        city = city_sim.City(city_sim.build_city(length=1200.0))
        r = city_sim.run(t, city, label="test", duration=25.0)
        self.assertEqual(r.collisions, 0)
        self.assertEqual(r.ground_hits, 0)
        self.assertGreater(r.distance / r.time, 20.0)

    def test_assists_beat_physical_baseline(self):
        t = SwingTuning()
        city = city_sim.City(city_sim.build_city(length=1200.0))
        base = city_sim.run(city_sim.physical_baseline(t), city, label="phys", duration=25.0)
        reg = city_sim.run(t, city, label="reg", duration=25.0)
        self.assertGreater(reg.distance, base.distance)
        self.assertLess(reg.max_lateral, base.max_lateral)


if __name__ == "__main__":
    unittest.main()
