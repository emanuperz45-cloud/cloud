class_name DemoInput
extends RefCounted
## Registra las acciones de InputMap que espera TraversalController (teclado,
## ratón y mando). Se hace por código para no depender de project.godot.

const KEY := 0
const MOUSE := 1
const JOY_BUTTON := 2
const JOY_AXIS := 3

const BINDINGS := {
	"move_forward": [[KEY, KEY_W], [JOY_AXIS, JOY_AXIS_LEFT_Y, -1.0]],
	"move_back": [[KEY, KEY_S], [JOY_AXIS, JOY_AXIS_LEFT_Y, 1.0]],
	"move_left": [[KEY, KEY_A], [JOY_AXIS, JOY_AXIS_LEFT_X, -1.0]],
	"move_right": [[KEY, KEY_D], [JOY_AXIS, JOY_AXIS_LEFT_X, 1.0]],
	"cam_left": [[JOY_AXIS, JOY_AXIS_RIGHT_X, -1.0]],
	"cam_right": [[JOY_AXIS, JOY_AXIS_RIGHT_X, 1.0]],
	"cam_up": [[JOY_AXIS, JOY_AXIS_RIGHT_Y, -1.0]],
	"cam_down": [[JOY_AXIS, JOY_AXIS_RIGHT_Y, 1.0]],
	"swing": [[MOUSE, MOUSE_BUTTON_LEFT], [JOY_AXIS, JOY_AXIS_TRIGGER_RIGHT, 1.0]],
	"jump": [[KEY, KEY_SPACE], [JOY_BUTTON, JOY_BUTTON_A]],
	"web_zip": [[KEY, KEY_E], [JOY_BUTTON, JOY_BUTTON_X]],
	"point_zip": [[KEY, KEY_Q], [MOUSE, MOUSE_BUTTON_RIGHT], [JOY_AXIS, JOY_AXIS_TRIGGER_LEFT, 1.0]],
	"dive": [[KEY, KEY_SHIFT], [JOY_BUTTON, JOY_BUTTON_B]],
	"trick": [[KEY, KEY_F], [JOY_BUTTON, JOY_BUTTON_Y]],
	"respawn": [[KEY, KEY_R], [JOY_BUTTON, JOY_BUTTON_BACK]],
	"toggle_help": [[KEY, KEY_H], [JOY_BUTTON, JOY_BUTTON_START]],
	"release_mouse": [[KEY, KEY_ESCAPE]],
}


static func setup() -> void:
	for action: String in BINDINGS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.25)
		for b: Array in BINDINGS[action]:
			InputMap.action_add_event(action, _event(b))


static func _event(b: Array) -> InputEvent:
	match b[0]:
		KEY:
			var k := InputEventKey.new()
			k.physical_keycode = b[1]
			return k
		MOUSE:
			var m := InputEventMouseButton.new()
			m.button_index = b[1]
			return m
		JOY_BUTTON:
			var j := InputEventJoypadButton.new()
			j.button_index = b[1]
			return j
	var a := InputEventJoypadMotion.new()
	a.axis = b[1]
	a.axis_value = b[2]
	return a
