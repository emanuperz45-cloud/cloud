class_name RegulatedPendulum
extends RefCounted
## Péndulo regulado: port 1:1 de RegulatedPendulum en tools/swing_lab/swing_core.py.
##
## Péndulo esférico con restricción unilateral (la cuerda solo tira), pivote
## dinámico resuelto al enganchar, regulación de longitud por clearance y un
## regulador de energía que inyecta aceleración tangencial en el fondo del arco.
## No toca la escena: el TraversalController lo integra y mueve el cuerpo.

const PHASE_REF_DEG := 75.0

var tuning: SwingTuning
var active := false
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var anchor := Vector3.ZERO   ## punto real en la geometría (donde se dibuja la web)
var pivot := Vector3.ZERO    ## pivote físico regulado
var travel := Vector3.FORWARD
var length := 0.0
var ground_y := 0.0
var cruise_y := NAN          ## NAN = sin banda de altitud
var time := 0.0

# Salidas para animación (equivalen a SwingSample en Python)
var swing_angle_deg := 0.0   ## < 0 bajando hacia el fondo, > 0 subiendo
var phase := 0.0             ## -1..1, 0 = fondo del arco
var tension := 0.0           ## m/s^2
var g_force := 0.0
var taut := false
var boost := 0.0
var speed := 0.0
var last_release_perfect := false
## Péndulo sostenido: tras la primera inversión con el gatillo mantenido, el
## arco se amortigua y el pivote converge al anclaje real (queda colgado).
var sustain := false
var hang_pivot := Vector3.ZERO
var swing_axis := Vector3.ZERO    ## eje de giro del arco al enganchar
var orbit := 0.0                  ## rad recorridos alrededor del pivote
var loops := 0                    ## vueltas completas (loop de loop)


func _init(p_tuning: SwingTuning) -> void:
	tuning = p_tuning


func duplicate_state() -> RegulatedPendulum:
	var p := RegulatedPendulum.new(tuning)
	p.active = active
	p.pos = pos
	p.vel = vel
	p.anchor = anchor
	p.pivot = pivot
	p.travel = travel
	p.length = length
	p.ground_y = ground_y
	p.cruise_y = cruise_y
	p.sustain = sustain
	p.hang_pivot = hang_pivot
	p.swing_axis = swing_axis
	p.orbit = orbit
	p.loops = loops
	p.time = time
	return p


static func flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


static func safe_normalized(v: Vector3, fallback: Vector3) -> Vector3:
	return v.normalized() if v.length_squared() > 1e-12 else fallback


static func project_on_plane(v: Vector3, n: Vector3) -> Vector3:
	return v - n * v.dot(n)


static func bell(x: float, sigma: float) -> float:
	return exp(-(x / sigma) * (x / sigma))


func rope_dir() -> Vector3:
	return safe_normalized(pos - pivot, Vector3.DOWN)


func signed_angle_deg() -> float:
	var n := rope_dir()
	var theta := rad_to_deg(acos(clampf(-n.y, -1.0, 1.0)))
	return theta if vel.dot(flat(n)) >= 0.0 else -theta


func bottom_y() -> float:
	return pivot.y - length


## Pivote dinámico: centrado lateral + colocación del fondo del arco.
func solve_pivot(p_pos: Vector3, p_anchor: Vector3, p_travel: Vector3) -> Vector3:
	var fwd := safe_normalized(flat(p_travel), Vector3.FORWARD)
	var right := fwd.cross(Vector3.UP).normalized()
	var rel := p_anchor - p_pos
	var lateral := rel.dot(right)
	var forward := rel.dot(fwd)
	var height := maxf(rel.y, 0.1)

	var d_lat := -tuning.pivot_center_strength * lateral
	var desired_forward := height * tan(deg_to_rad(tuning.pivot_attach_angle_deg))
	var d_fwd := clampf(desired_forward - forward, -tuning.pivot_shift_max, tuning.pivot_shift_max)
	var result := p_anchor + right * d_lat + fwd * d_fwd

	# Limita la divergencia entre la web visual (pos->anchor) y la cuerda física.
	var va := (p_anchor - p_pos).normalized()
	var vp := (result - p_pos).normalized()
	var div := rad_to_deg(acos(clampf(va.dot(vp), -1.0, 1.0)))
	if div > tuning.pivot_max_divergence_deg:
		result = p_anchor + (result - p_anchor) * (tuning.pivot_max_divergence_deg / div)
	return result


func attach(p_pos: Vector3, p_vel: Vector3, p_anchor: Vector3, p_travel: Vector3,
		p_ground_y: float, p_cruise_y: float = NAN) -> void:
	active = true
	time = 0.0
	pos = p_pos
	anchor = p_anchor
	travel = safe_normalized(flat(p_travel), Vector3.FORWARD)
	ground_y = p_ground_y
	cruise_y = p_cruise_y
	pivot = solve_pivot(p_pos, p_anchor, travel)
	length = clampf((p_pos - pivot).length(), tuning.rope_min, tuning.rope_max)
	var away := flat(pivot - p_anchor)
	hang_pivot = p_anchor + safe_normalized(away, Vector3.ZERO) \
			* minf(tuning.hang_wall_offset, away.length())
	sustain = false

	# Catch: la componente que se aleja del pivote se redirige al plano tangente.
	var n := rope_dir()
	var v_out := p_vel.dot(n)
	var v_t := p_vel - n * maxf(v_out, 0.0)
	var vt_len := v_t.length()
	if v_out > 0.0 and vt_len > 1.0:
		v_t *= lerpf(vt_len, p_vel.length(), tuning.catch_retention) / vt_len

	# Attach kick: velocidad tangencial mínima hacia delante.
	var tan_fwd := project_on_plane(travel, n).normalized()
	var along := v_t.dot(tan_fwd)
	if along < tuning.attach_min_tangent_speed:
		v_t += tan_fwd * (tuning.attach_min_tangent_speed - along)
	vel = v_t
	speed = vel.length()
	swing_angle_deg = signed_angle_deg()
	phase = clampf(swing_angle_deg / PHASE_REF_DEG, -1.0, 1.0)
	swing_axis = rope_dir().cross(vel).normalized()
	orbit = 0.0
	loops = 0


## Devuelve la velocidad de salida; last_release_perfect indica si cayó en la ventana.
## allow_perfect = false para sueltas automáticas (swing encadenado): sin bonus.
func release(allow_perfect: bool = true) -> Vector3:
	active = false
	var ang := signed_angle_deg()
	var perfect := allow_perfect \
			and absf(ang - tuning.release_perfect_angle_deg) <= tuning.release_perfect_window_deg
	var mult := 1.0 + tuning.release_perfect_bonus if perfect else 1.0
	var up_scale := clampf(ang / tuning.release_perfect_angle_deg, 0.0, 1.0)
	if not is_nan(cruise_y):
		var above := pos.y - cruise_y
		up_scale *= clampf(1.0 - above / tuning.release_band_height, 0.0, 1.0)
	var fwd := safe_normalized(flat(vel), travel)
	var v := vel + Vector3.UP * (tuning.release_up_boost * mult * up_scale) \
			+ fwd * (tuning.release_fwd_boost * mult)
	v.y = minf(v.y, tuning.release_max_up_speed)
	last_release_perfect = perfect
	return v


func goal_bottom_speed(g_eff: float) -> float:
	var goal := tuning.target_bottom_speed
	if is_nan(cruise_y):
		return goal
	var excess := bottom_y() - cruise_y
	var goal_sq := goal * goal - 2.0 * g_eff * tuning.altitude_energy_weight * excess
	return clampf(sqrt(maxf(goal_sq, 0.0)), tuning.attach_min_tangent_speed, tuning.speed_soft_cap)


## Un sub-paso de integración. steer en [-1, 1]; steer_right = derecha de cámara;
## reel en [-1, 1] sube (+) o baja (-) por la telaraña cuando está colgado;
## tighten recoge cuerda hasta el radio en el que cabe un loop (arco rápido).
func step(h: float, steer: float = 0.0, steer_right: Vector3 = Vector3.ZERO,
		hold: bool = true, external_accel: Vector3 = Vector3.ZERO, reel: float = 0.0,
		tighten: bool = false) -> void:
	time += h
	var n := rope_dir()
	var ang := signed_angle_deg()

	# 0) Velocidad angular alrededor del eje de giro inicial: negativa = el arco
	# se ha invertido. Cruzar la vertical por arriba NO lo es (loop de loop).
	var w := n.cross(vel).dot(swing_axis) / maxf((pos - pivot).length(), 0.1)
	orbit += w * h
	if orbit >= TAU * (loops + 1):
		loops += 1
	# Péndulo sostenido: primera inversión, tras una vuelta o casi sin velocidad.
	if hold and not sustain and (w < -0.05 or loops >= 1 \
			or (time > 0.5 and vel.length() < 1.0)):
		sustain = true

	# 1) Gravedad asimétrica (simétrica al colgar: la asimetría bombea energía)
	var g_scale := tuning.gravity_scale_swing_down if vel.y < 0.0 else tuning.gravity_scale_swing_up
	if sustain:
		g_scale = tuning.gravity_scale_swing_down
	var g_eff := tuning.g * g_scale
	var acc := Vector3(0.0, -g_eff, 0.0)

	var spd := vel.length()
	var v_hat := safe_normalized(vel, travel)

	# 2) Regulador de energía: campana gaussiana centrada en el fondo del arco
	var drop := maxf(pos.y - bottom_y(), 0.0)
	var v_bottom_pred := sqrt(spd * spd + 2.0 * g_eff * drop)
	boost = 0.0
	if hold and not sustain:
		var err := goal_bottom_speed(g_eff) - v_bottom_pred
		boost = clampf(tuning.boost_gain * err, 0.0, tuning.boost_accel_max) \
				* bell(ang, tuning.boost_sigma_deg)
		acc += v_hat * boost

	# 3) Steering + lane keeping en el plano tangente
	if steer_right != Vector3.ZERO:
		var s_t := project_on_plane(steer_right, n).normalized()
		acc += s_t * (steer * tuning.steer_accel)
		acc -= s_t * (vel.dot(s_t) * tuning.lane_keep * (1.0 - absf(steer)))
	acc += project_on_plane(external_accel, n)
	if sustain:
		acc -= project_on_plane(vel, n) * tuning.hang_damping
		pivot += (hang_pivot - pivot) * (1.0 - exp(-tuning.hang_pivot_rate * h))

	# 4) Arrastre + techo blando
	acc -= vel * (tuning.swing_air_drag * spd)
	if spd > tuning.speed_soft_cap:
		acc -= v_hat * (tuning.overspeed_drag * pow(spd - tuning.speed_soft_cap, 2.0))

	# Euler semi-implícito
	vel += acc * h
	pos += vel * h

	# 5) Regulación de longitud (clearance) + spin-up por momento angular
	var l_prev := length
	var max_len := pivot.y - (ground_y + tuning.ground_clearance)
	var min_len := tuning.rope_min
	if sustain:
		min_len = tuning.hang_min_length
		length -= reel * tuning.reel_climb_speed * h
	var v_now := vel.length()
	if tighten and not sustain and v_now > tuning.loop_min_speed:
		# Cerrar el arco: con la cuerda corta la energía alcanza para la vuelta.
		var g_up := tuning.g * tuning.gravity_scale_swing_up
		max_len = minf(max_len, tuning.loop_radius_factor * v_now * v_now / (5.0 * g_up))
	var l_target := clampf(minf(length, max_len), min_len, tuning.rope_max)
	length = move_toward(length, l_target, tuning.reel_speed * h)
	if length < l_target:
		length = l_target

	# 6) Restricción unilateral con proyección que preserva la rapidez
	var d_vec := pos - pivot
	var d := d_vec.length()
	taut = d >= length - 1e-4
	if taut:
		n = d_vec / d
		pos = pivot + n * length
		var v_r := vel.dot(n)
		if v_r > 0.0:
			var before := vel.length()
			vel -= n * v_r
			var after := vel.length()
			if after > 1.0:
				vel *= lerpf(after, before, tuning.catch_retention) / after
		if length < l_prev:
			var v_rad := n * vel.dot(n)
			vel = v_rad + (vel - v_rad) * (l_prev / length)

	spd = vel.length()
	if spd > tuning.speed_hard_cap:
		vel *= tuning.speed_hard_cap / spd
		spd = tuning.speed_hard_cap

	# 7) Tensión analítica: T = |v_t|^2 / L - g_eff * n.y
	tension = 0.0
	if taut:
		var v_t := project_on_plane(vel, n)
		tension = maxf(v_t.length_squared() / length - g_eff * n.y, 0.0)
	g_force = tension / tuning.g
	speed = spd
	swing_angle_deg = signed_angle_deg()
	phase = clampf(swing_angle_deg / PHASE_REF_DEG, -1.0, 1.0)


func should_auto_release() -> bool:
	return swing_angle_deg >= tuning.auto_release_angle_deg \
			or (swing_angle_deg > 0.0 and speed < tuning.stall_speed)
