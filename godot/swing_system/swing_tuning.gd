class_name SwingTuning
extends Resource
## Parámetros de calibración del sistema de balanceo.
##
## Los valores por defecto son los de tools/swing_lab/swing_core.py, validados
## con tools/swing_lab/city_sim.py. Si cambias uno aquí, cámbialo allí y vuelve
## a correr la simulación. Unidades SI; aceleraciones con masa unitaria.

@export_group("Gravedad")
@export var g: float = 9.81
@export var gravity_scale_fall: float = 1.8
@export var gravity_scale_swing_down: float = 2.0
@export var gravity_scale_swing_up: float = 1.7
@export var gravity_scale_dive: float = 2.6
@export var gravity_scale_zip: float = 0.2

@export_group("Cuerda")
@export var rope_min: float = 8.0
@export var rope_max: float = 45.0
@export var ground_clearance: float = 3.5
@export var reel_speed: float = 14.0

@export_group("Pivote dinámico")
@export_range(0.0, 1.0) var pivot_center_strength: float = 0.65
@export var pivot_attach_angle_deg: float = 45.0
@export var pivot_shift_max: float = 7.0
@export var pivot_max_divergence_deg: float = 22.0

@export_group("Momento")
@export_range(0.0, 1.0) var catch_retention: float = 0.92
@export var attach_min_tangent_speed: float = 13.0

@export_group("Inyección de impulso")
@export var boost_accel_max: float = 18.0
@export var boost_sigma_deg: float = 30.0
@export var boost_gain: float = 3.0
@export var target_bottom_speed: float = 29.0
@export_range(0.0, 1.0) var altitude_energy_weight: float = 0.75
@export_range(0.0, 1.0) var cruise_skyline_fraction: float = 0.5

@export_group("Límites de velocidad")
@export var speed_soft_cap: float = 34.0
@export var speed_hard_cap: float = 48.0
@export var overspeed_drag: float = 0.03
@export var swing_air_drag: float = 0.0008

@export_group("Control lateral")
@export var steer_accel: float = 16.0
@export var lane_keep: float = 1.2

@export_group("Suelta")
@export var release_up_boost: float = 5.5
@export var release_fwd_boost: float = 3.0
@export var release_perfect_angle_deg: float = 40.0
@export var release_perfect_window_deg: float = 9.0
@export var release_perfect_bonus: float = 0.45
@export var release_max_up_speed: float = 17.0
@export var release_band_height: float = 12.0
@export var auto_release_angle_deg: float = 95.0
@export var stall_speed: float = 3.0
## Con el gatillo mantenido, suelta sola aquí y re-dispara (swing encadenado).
@export var chain_release_angle_deg: float = 35.0
@export var reattach_delay: float = 0.15
## "Swing jump": salto al soltar (botón de salto durante el swing).
@export var swing_jump_up: float = 6.0

@export_group("Caída libre / picada")
@export var fall_drag: float = 0.011
@export var dive_drag: float = 0.0076
@export var air_horizontal_damping: float = 0.04
@export var air_control_accel: float = 7.0
@export var dive_forward_accel: float = 4.0

@export_group("Web zip / point launch")
@export var zip_speed: float = 26.0
@export var zip_up_speed: float = 5.0
@export var zip_duration: float = 0.3
@export var zip_cooldown: float = 0.35
@export var point_zip_speed: float = 38.0
@export var point_launch_forward: float = 18.0
@export var point_launch_up: float = 19.0
@export var point_launch_perfect_mult: float = 1.25
@export var point_launch_window: float = 0.22

@export_group("Anclajes")
@export var anchor_ideal_forward: float = 18.0
@export var anchor_ideal_up: float = 22.0
@export var anchor_ideal_side: float = 9.0
@export var anchor_min_height: float = 6.0
@export var anchor_max_distance: float = 65.0
@export var anchor_ideal_radius: float = 30.0
@export var anchor_speed_scale_min: float = 0.8
@export var anchor_speed_scale_max: float = 1.5

@export_group("Wall run")
@export var wall_run_min_speed: float = 9.0
@export var wall_run_vertical_angle_deg: float = 40.0
@export var wall_run_speed_retention: float = 0.85
@export var wall_run_gravity_scale: float = 0.35
@export var wall_run_stick_accel: float = 25.0
@export var wall_run_max_time: float = 2.5
@export var wall_jump_out: float = 11.0
@export var wall_jump_up: float = 9.0

@export_group("Solver")
@export var substep: float = 1.0 / 240.0
@export var predict_horizon: float = 1.0
@export var predict_interval: float = 0.1
@export var avoid_accel: float = 22.0
