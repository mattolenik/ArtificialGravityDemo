## Sliders over the dirt simulation's levers, live: ToolParams' numbers (read by the box each step) and dirt's
## row of the MaterialSet (the box's material table re-uploaded on a change). Nothing is saved: read the
## numbers off the labels and put them in tool_params.gd or materials.tres.
class_name Levers
extends GridContainer

@export var terrain: Terrain

## [label, property, index into a MaterialSet packed array (-1: a ToolParams float), min, max, step]
const LEVERS := [
	["slump rate", "slump_rate", -1, 0.0, 1.0, 0.005],
	["roof thickness max m", "roof_thickness_max", -1, 0.0, 10.0, 0.1],
	["settle time s", "settle_time", -1, 0.0, 5.0, 0.1],
	["tamp step", "tamp_step", -1, 0.0, 1.0, 0.05],
	["dirt roof span dry m", "roof_span_dry", 0, 0.0, 30.0, 0.5],
	["dirt roof span wet m", "roof_span_saturated", 0, 0.0, 30.0, 0.5],
	["dirt stable slope dry °", "stable_slope_dry", 0, 0.0, 90.0, 1.0],
	["dirt stable slope wet °", "stable_slope_saturated", 0, 0.0, 90.0, 1.0],
	["dirt repose dry °", "repose_dry", 0, 0.0, 60.0, 1.0],
	["dirt repose damp °", "repose_damp", 0, 0.0, 60.0, 1.0],
	["dirt repose wet °", "repose_saturated", 0, 0.0, 60.0, 1.0],
	["dirt swell", "swell_factor", 0, 1.0, 2.0, 0.05],
]


func _ready() -> void:
	columns = 3
	for l: Array in LEVERS:
		var obj: Resource = terrain.materials if l[2] >= 0 else terrain.tool_params
		var name_label := Label.new()
		name_label.text = l[0]
		var slider := HSlider.new()
		slider.min_value = l[3]
		slider.max_value = l[4]
		slider.step = l[5]
		slider.value = obj.get(l[1])[l[2]] if l[2] >= 0 else obj.get(l[1])
		slider.focus_mode = Control.FOCUS_NONE
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size.x = 150
		var value_label := Label.new()
		value_label.text = str(slider.value)
		slider.value_changed.connect(func(v: float) -> void:
			set_lever(obj, l[1], l[2], v)
			value_label.text = str(v)
			if l[2] >= 0:
				terrain.box.update_materials())
		add_child(name_label)
		add_child(slider)
		add_child(value_label)


## Sets a ToolParams float (index -1) or one entry of a MaterialSet packed array.
static func set_lever(obj: Resource, prop: String, index: int, v: float) -> void:
	if index < 0:
		obj.set(prop, v)
		return
	var a: PackedFloat32Array = obj.get(prop)
	a[index] = v
	obj.set(prop, a)
