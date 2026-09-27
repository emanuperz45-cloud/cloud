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
@export var target_bottom_speed: float = 38.0
@export_range(0.0, 1.0) var altitude_energy_weight: float = 0.75
@export_range(0.0, 1.0) var cruise_skyline_fraction: float = 0.5

@export_group("Límites de velocidad")
@export var speed_soft_cap: float = 42.0
@export var speed_hard_cap: float = 55.0
@export var overspeed_drag: float = 0.03
@export var swing_air_drag: float = 0.0008

@export_group("Control lateral")
@export var steer_accel: float = 16.0
@export var lane_keep: float = 1.2

@export_group("Suelta")
@export var release_up_boost: float = 5.5
@export var release_fwd_boost: float = 5.0
@export var release_perfect_angle_deg: float = 40.0
@export var release_perfect_window_deg: float = 9.0
@export var release_perfect_bonus: float = 0.45
@export var release_max_up_speed: float = 17.0
@export var release_band_height: float = 12.0
@export var auto_release_angle_deg: float = 95.0
@export var stall_speed: float = 3.0
## Gatillo mantenido = misma telaraña (sin suelta automática). Tras la primera
## inversión el arco se amortigua hasta quedar colgado del anclaje.
@export var hang_damping: float = 0.75
@export var hang_pivot_rate: float = 0.8
@export var hang_wall_offset: float = 1.0
@export var reel_climb_speed: float = 5.0
@export var hang_min_length: float = 4.0
## Loop: mantener truco en un arco rápido recoge cuerda hasta L = factor·v²/(5·g).
@export var loop_radius_factor: float = 0.8
@export var loop_min_speed: float = 20.0
@export var reattach_delay: float = 0.15
## "Swing jump" (salto durante el swing): en el fondo del arco lanza hacia
## delante, al final del arco hacia arriba (como en el original).
@export var swing_jump_up: float = 9.0
@export var swing_jump_forward: float = 9.0
@export var hang_jump_up: float = 12.0

@export_group("Caída libre / picada")
@export var fall_drag: float = 0.011
@export var dive_drag: float = 0.0076
@export var air_horizontal_damping: float = 0.04
@export var air_control_accel: float = 7.0
@export var dive_forward_accel: float = 4.0

@export_group("Web zip / point launch")
@export var zip_speed: float = 32.0
@export var zip_up_speed: float = 5.0
@export var zip_duration: float = 0.3
@export var zip_cooldown: float = 0.25
## Quick Zip: un segundo zip seguido no pierde altura.
@export var quick_zip_window: float = 1.0
@export var point_zip_speed: float = 46.0
@export var point_launch_forward: float = 18.0
@export var point_launch_up: float = 19.0
@export var point_launch_perfect_mult: float = 1.25
@export var point_launch_window: float = 0.22

@export_group("Web Wings (planeo)")
@export var glide_gravity: float = 9.81
@export var glide_drag: float = 0.0015
@export var glide_neutral_deg: float = -8.0
@export var glide_dive_deg: float = -50.0
@export var glide_climb_deg: float = 22.0
@export var glide_pitch_rate: float = 2.2
@export var glide_max_bank_deg: float = 65.0
@export var glide_bank_rate: float = 7.0
@export var glide_turn_rate: float = 1.7            ## rad/s con el stick a fondo (~97°/s)
@export var glide_turn_highspeed: float = 0.7      ## fracción del viraje que queda a 70 m/s
## Timón con la cámara: al planear, girar la cámara (ratón / stick derecho) vira
## hacia donde miras; 40° de diferencia = alabeo máximo.
@export var glide_camera_steer: float = 1.0
@export var glide_camera_steer_deg: float = 40.0
@export var glide_stall_speed: float = 9.0
@export var glide_flare_drag: float = 0.8
@export var glide_open_min_speed: float = 14.0
@export var glide_dive_boost: float = 10.0
@export var glide_tunnel_accel: float = 26.0
@export var glide_tunnel_align: float = 1.5
@export var glide_tunnel_speed: float = 72.0       ## el empuje se anula a esta velocidad
@export var glide_tunnel_authority: float = 0.8    ## en el túnel el viento manda sobre el cabeceo
@export var glide_tunnel_center: float = 1.2       ## 1/s, deriva hacia el eje del túnel
@export var glide_updraft_speed: float = 16.0
@export var glide_updraft_accel: float = 30.0
@export var glide_updraft_decay: float = 1.2       ## s de inercia del impulso al salir

@export_group("Super Slingshot")
@export var slingshot_charge_time: float = 1.2
@export var slingshot_pull_back: float = 1.6
@export var slingshot_min_speed: float = 20.0
@export var slingshot_max_speed: float = 58.0
@export var slingshot_lift: float = 1.0         ## componente vertical de la dirección (45°)

@export_group("Anclajes")
@export var anchor_ideal_forward: float = 18.0
@export var anchor_ideal_up: float = 22.0
@export var anchor_ideal_side: float = 9.0
@export var anchor_min_height: float = 6.0
@export var anchor_max_distance: float = 65.0
@export var anchor_ideal_radius: float = 30.0
@export var anchor_speed_scale_min: float = 0.8
@export var anchor_speed_scale_max: float = 1.5

@export_group("Suelo")
@export var run_speed: float = 10.0
@export var sprint_speed: float = 18.0
@export var jump_speed: float = 9.0
@export var charge_jump_speed: float = 25.0
@export var charge_jump_time: float = 0.7
@export var quick_recovery_window: float = 0.45
@export var quick_recovery_up: float = 13.0

@export_group("Wall run")
@export var wall_run_min_speed: float = 9.0
@export var wall_run_vertical_angle_deg: float = 40.0
@export var wall_run_speed_retention: float = 0.85
@export var wall_run_gravity_scale: float = 0.35
@export var wall_run_stick_accel: float = 25.0
@export var wall_run_max_time: float = 2.5
@export var wall_jump_out: float = 11.0
@export var wall_jump_up: float = 9.0
@export var wall_crawl_speed: float = 5.0
@export var wall_web_pull: float = 14.0
@export var wall_run_max_speed: float = 36.0
@export var corner_launch_boost: float = 6.0
@export var corner_turn_buffer: float = 0.5

@export_group("Solver")
@export var substep: float = 1.0 / 240.0
@export var predict_horizon: float = 1.0
@export var predict_interval: float = 0.1
@export var avoid_accel: float = 22.0
