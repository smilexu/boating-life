extends Resource
class_name CloudLayerProfile

## Reusable visual and motion settings for one procedural sky layer.

@export_range(0.0, 1.0, 0.01) var coverage := 0.25
@export_range(0.0, 1.0, 0.01) var density := 0.7
@export_range(0.25, 3.0, 0.05) var scale := 1.0
@export_range(0.0, 0.5, 0.01) var softness := 0.1
@export_range(0.0, 1.5, 0.01) var brightness := 1.0
@export_range(0.0, 1.0, 0.01) var bottom_darkness := 0.25
## Speed is sky-UV units per second. Keep it very small for slow weather drift.
@export_range(0.0, 0.002, 0.00001) var speed := 0.0002
@export var direction := Vector2(1.0, 0.2)
@export_range(0.0, 1.0, 0.01) var grayness := 0.25
