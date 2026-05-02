extends Node3D
class_name PointTag

const KIND_SPAWN: int = 0
const KIND_PATROL: int = 1

@export_enum("Spawn:0", "Patrol:1") var tag_kind: int = KIND_SPAWN


func _ready() -> void:
	var g := "lvl_spawn" if tag_kind == KIND_SPAWN else "lvl_patrol"
	add_to_group(g)
	add_to_group("lvl_point_tags")
