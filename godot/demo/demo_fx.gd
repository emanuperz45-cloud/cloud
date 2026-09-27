class_name DemoFx
extends CanvasLayer
## Sensación de velocidad y sonido, todo procedural (no añade assets al .exe):
##  - líneas de velocidad radiales y viñeta según la velocidad, el túnel de viento
##    y los impulsos (slingshot, alas en picada);
##  - viento continuo: ruido filtrado cuya intensidad y brillo suben con la
##    velocidad (AudioStreamGenerator);
##  - efectos sintetizados al arrancar (AudioStreamWAV): thwip de la telaraña,
##    whoosh de suelta/salto, golpe de aterrizaje, despliegue de las alas y el
##    latigazo del Super Slingshot.

const SPEED_LINES := preload("res://demo/speed_lines.gdshader")
const RATE := 22050

var controller: TraversalController

var _mat := ShaderMaterial.new()
var _boost := 0.0
var _wind: AudioStreamPlayer
var _wind_pb: AudioStreamGeneratorPlayback
var _lp1 := 0.0
var _lp2 := 0.0
var _wind_gain := 0.0
var _sfx := {}
var _players: Array[AudioStreamPlayer] = []
var _next_player := 0


func _ready() -> void:
	layer = 0
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat.shader = SPEED_LINES
	rect.material = _mat
	add_child(rect)
	_build_audio()
	controller.web_fired.connect(func(_h: int, _a: Vector3) -> void: _play("thwip", -6.0, 0.12))
	controller.web_released.connect(func(_h: int, perfect: bool) -> void:
		if controller.velocity.length() > 14.0:
			_play("whoosh", -8.0 if not perfect else -3.0, 0.1))
	controller.landed.connect(func(impact: float) -> void:
		_play("land", linear_to_db(clampf(impact / 30.0, 0.15, 1.0)) - 2.0, 0.08))
	controller.jumped.connect(func(c: float) -> void: _play("whoosh", -10.0 + c * 8.0, 0.1))
	controller.trick_started.connect(func() -> void: _play("whoosh", -9.0, 0.2))
	controller.looped.connect(func(_n: int) -> void: _play("whoosh", -4.0, 0.05))
	controller.wings_opened.connect(func(boosted: bool) -> void:
		_play("wings", -3.0, 0.05)
		if boosted:
			_boost = 1.0)
	controller.wings_closed.connect(func() -> void: _play("whoosh", -12.0, 0.1))
	controller.slingshot_launched.connect(func(c: float) -> void:
		_play("sling", -2.0, 0.03)
		_boost = maxf(_boost, c))
	controller.point_launched.connect(func(_p: bool) -> void: _boost = maxf(_boost, 0.6))


func _process(delta: float) -> void:
	var c := controller
	var spd := c.velocity.length()
	_boost = move_toward(_boost, 0.0, delta * 0.9)
	var fast := clampf((spd - 22.0) / 30.0, 0.0, 1.0)
	var target := maxf(fast, _boost) + c.in_tunnel * 0.35
	_mat.set_shader_parameter("intensity", clampf(target, 0.0, 1.0))
	_mat.set_shader_parameter("vignette", clampf(fast * 0.5 + c.in_tunnel * 0.3 + _boost * 0.3, 0.0, 0.8))
	var tint := Color(0.75, 0.88, 1.0) if c.state == TraversalController.State.GLIDE else Color.WHITE
	_mat.set_shader_parameter("tint", tint)
	_feed_wind(spd)


# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------
func _build_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.15
	_wind = AudioStreamPlayer.new()
	_wind.stream = gen
	_wind.volume_db = -4.0
	add_child(_wind)
	_wind.play()
	_wind_pb = _wind.get_stream_playback() as AudioStreamGeneratorPlayback
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_sfx["thwip"] = _synth(0.16, _thwip)
	_sfx["whoosh"] = _synth(0.42, _whoosh)
	_sfx["land"] = _synth(0.3, _land)
	_sfx["wings"] = _synth(0.38, _wings)
	_sfx["sling"] = _synth(0.7, _sling)


func _play(id: String, db: float, pitch_jitter: float) -> void:
	var p := _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	p.stream = _sfx[id]
	p.volume_db = db
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


func _feed_wind(spd: float) -> void:
	if _wind_pb == null:
		return
	var n := _wind_pb.get_frames_available()
	if n <= 0:
		return
	var gliding := controller.state == TraversalController.State.GLIDE
	var want := clampf(pow(spd / 50.0, 1.4), 0.0, 1.0) * (1.2 if gliding else 1.0) \
			+ controller.in_tunnel * 0.35
	# Filtro paso bajo de dos polos: más velocidad = viento más brillante.
	var cutoff := lerpf(250.0, 2600.0, clampf(spd / 55.0, 0.0, 1.0))
	var a := 1.0 - exp(-TAU * cutoff / RATE)
	var frames := PackedVector2Array()
	frames.resize(n)
	for i in n:
		_wind_gain += (want - _wind_gain) * 0.0004
		_lp1 += (randf_range(-1.0, 1.0) - _lp1) * a
		_lp2 += (_lp1 - _lp2) * a
		var s := _lp2 * _wind_gain * 1.6
		frames[i] = Vector2(s, s)
	_wind_pb.push_buffer(frames)


func _synth(length: float, fn: Callable) -> AudioStreamWAV:
	var count := int(length * RATE)
	var data := PackedByteArray()
	data.resize(count * 2)
	var state := {"lp": 0.0, "lp2": 0.0, "hp": 0.0, "phase": 0.0}
	for i in count:
		var t := float(i) / RATE
		var v: float = clampf(fn.call(t, length, state), -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav


static func _lowpass(st: Dictionary, x: float, cutoff: float) -> float:
	var a := 1.0 - exp(-TAU * cutoff / RATE)
	st.lp += (x - st.lp) * a
	st.lp2 += (st.lp - st.lp2) * a
	return st.lp2


## Thwip: chasquido agudo con un chirrido descendente (la web saliendo del lanzador).
static func _thwip(t: float, length: float, st: Dictionary) -> float:
	var env := minf(t / 0.004, 1.0) * exp(-t * 32.0)
	var noise := randf_range(-1.0, 1.0)
	var hp: float = noise - _lowpass(st, noise, 1800.0)
	st.phase += TAU * lerpf(2600.0, 700.0, t / length) / RATE
	return (hp * 0.9 + sin(st.phase) * 0.35) * env


static func _whoosh(t: float, length: float, st: Dictionary) -> float:
	var u := t / length
	var env := pow(sin(PI * u), 2.0)
	return _lowpass(st, randf_range(-1.0, 1.0), lerpf(400.0, 1600.0, sin(PI * u))) * env * 2.2


static func _land(t: float, _length: float, st: Dictionary) -> float:
	st.phase += TAU * lerpf(95.0, 45.0, minf(t / 0.2, 1.0)) / RATE
	var thump := sin(st.phase) * exp(-t * 14.0)
	var grit := _lowpass(st, randf_range(-1.0, 1.0), 900.0) * exp(-t * 30.0) * 1.8
	return thump * 0.9 + grit


## Alas: tela que se tensa de golpe (ráfaga de chasquidos) y se llena de aire.
static func _wings(t: float, length: float, st: Dictionary) -> float:
	var flap := maxf(sin(t * TAU * 38.0), 0.0) * exp(-t * 12.0)
	var fill := pow(sin(PI * t / length), 2.0) * 0.5
	var n := _lowpass(st, randf_range(-1.0, 1.0), 1200.0 + flap * 2500.0)
	return n * (flap * 2.0 + fill) * 1.6


## Super Slingshot: latigazo de las webs + nota grave que vibra y se apaga.
static func _sling(t: float, length: float, st: Dictionary) -> float:
	st.phase += TAU * (lerpf(210.0, 120.0, t / length) + sin(t * 70.0) * 12.0) / RATE
	var twang := sin(st.phase) * exp(-t * 6.0) * 0.6
	var crack := randf_range(-1.0, 1.0) * exp(-t * 45.0)
	var rush := _lowpass(st, randf_range(-1.0, 1.0), 1400.0) * pow(sin(PI * t / length), 2.0) * 1.8
	return twang + crack * 0.8 + rush
