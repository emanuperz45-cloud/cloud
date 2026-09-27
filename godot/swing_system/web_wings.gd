class_name WebWings
extends RefCounted
## Web Wings: port 1:1 de Glider en tools/swing_lab/swing_core.py.
##
## Modelo de ángulo de trayectoria (γ) y rumbo (ψ):
##   dV/dt = -g·sin γ - k·V²·(1 + flare)   (+ empuje del túnel de viento)
## γ sigue al objetivo del stick a una tasa proporcional a V (en pérdida el morro
## cae), ψ gira proporcional al alabeo (hasta ~97°/s). Stick adelante = picar.

var tuning: SwingTuning
var speed := 0.0
var gamma := 0.0      ## rad, + = subiendo
var psi := 0.0        ## rad, dirección (sin ψ, 0, cos ψ)
var bank := 0.0       ## rad, + = alabeo a la derecha
var boosted := false
var stalled := false
var lift := 0.0       ## m/s verticales de la corriente ascendente (con inercia)


func _init(p_tuning: SwingTuning) -> void:
	tuning = p_tuning


func direction() -> Vector3:
	var c := cos(gamma)
	return Vector3(c * sin(psi), sin(gamma), c * cos(psi))


func open(vel: Vector3, from_dive: bool = false) -> void:
	var v := vel.length()
	var horiz := RegulatedPendulum.flat(vel)
	if horiz.length() > 0.5:
		psi = atan2(horiz.x, horiz.z)
	gamma = clampf(asin(clampf(vel.y / maxf(v, 1e-3), -1.0, 1.0)), deg_to_rad(-60.0), deg_to_rad(20.0))
	speed = maxf(v, tuning.glide_open_min_speed)
	boosted = from_dive and v > 30.0
	if boosted:
		speed += tuning.glide_dive_boost          # "Ultimate Wings"
	bank = 0.0
	stalled = false
	lift = 0.0


## pitch_in: +1 picar / -1 encabritar. roll_in: +1 derecha. tunnel_offset: vector de
## la posición al eje del túnel (perpendicular). Devuelve la velocidad.
func step(h: float, pitch_in: float, roll_in: float, tunnel_dir: Vector3 = Vector3.ZERO,
		tunnel: float = 0.0, updraft: float = 0.0, tunnel_offset: Vector3 = Vector3.ZERO) -> Vector3:
	var t := tuning
	var g := t.glide_gravity
	var target := 0.0
	if pitch_in >= 0.0:
		target = deg_to_rad(lerpf(t.glide_neutral_deg, t.glide_dive_deg, pitch_in))
	else:
		target = deg_to_rad(lerpf(t.glide_neutral_deg, t.glide_climb_deg, -pitch_in))
	var in_tunnel := tunnel > 0.0 and tunnel_dir != Vector3.ZERO
	if in_tunnel:
		target = lerpf(target, asin(clampf(tunnel_dir.y, -1.0, 1.0)), tunnel * t.glide_tunnel_authority)
	# Pérdida con histéresis: el morro cae hasta recuperar 5 m/s por encima.
	if speed < t.glide_stall_speed:
		stalled = true
	elif speed > t.glide_stall_speed + 5.0:
		stalled = false
	if stalled:
		target = minf(target, deg_to_rad(-35.0))
	var rate := t.glide_pitch_rate * clampf(speed / 20.0, 0.3, 1.3) * h
	gamma += clampf(target - gamma, -rate, rate)

	bank += (roll_in * deg_to_rad(t.glide_max_bank_deg) - bank) * (1.0 - exp(-t.glide_bank_rate * h))
	# Viraje "arcade": tasa de giro proporcional al alabeo, casi independiente de la
	# velocidad (un viraje coordinado g·tanφ/V sería lentísimo a 60 m/s).
	var bank01 := bank / deg_to_rad(t.glide_max_bank_deg)
	var fast := clampf((speed - 30.0) / 40.0, 0.0, 1.0)
	psi -= bank01 * t.glide_turn_rate * lerpf(1.0, t.glide_turn_highspeed, fast) * h

	var drift := Vector3.ZERO
	if in_tunnel:
		# Túnel de viento: empuje a lo largo del eje (se anula a glide_tunnel_speed),
		# alineación del rumbo y deriva hacia el eje.
		var along := maxf(direction().dot(tunnel_dir), 0.0)
		var fade := maxf(1.0 - speed / t.glide_tunnel_speed, 0.0)
		speed += t.glide_tunnel_accel * tunnel * along * fade * h
		drift = tunnel_offset * (t.glide_tunnel_center * tunnel)
		var want_psi := atan2(tunnel_dir.x, tunnel_dir.z)
		var dpsi := wrapf(want_psi - psi, -PI, PI)
		var k := 1.0 - exp(-t.glide_tunnel_align * tunnel * h)
		psi += dpsi * k
		gamma += (asin(clampf(tunnel_dir.y, -1.0, 1.0)) - gamma) * k

	var drag := t.glide_drag * speed * speed * (1.0 + t.glide_flare_drag * maxf(-pitch_in, 0.0))
	speed = maxf(speed + (-g * sin(gamma) - drag) * h, 2.0)
	if updraft > 0.0:
		lift = minf(lift + t.glide_updraft_accel * updraft * h,
				maxf(lift, t.glide_updraft_speed * updraft))
	else:
		lift *= exp(-h / t.glide_updraft_decay)
	return direction() * speed + Vector3.UP * lift + drift
