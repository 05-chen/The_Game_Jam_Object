extends Node3D
class_name PointTag

## 关卡标记点：挂在 Blender 导出场景中的空物体 / Marker3D 上（在 Godot 里指定脚本即可）。
## 与 [LevelBase] 的「按命名前缀自动入组」二选一或混用；本脚本用枚举明确类型。
## 分组说明见 [LevelBase] 常量 GROUP_SPAWN / GROUP_PATROL 及 [Groups 文档](https://docs.godotengine.org/en/stable/tutorials/scripting/groups.html)。

const KIND_SPAWN: int = 0
const KIND_PATROL: int = 1

@export_enum("Spawn:0", "Patrol:1") var tag_kind: int = KIND_SPAWN


func _ready() -> void:
	var g := "lvl_spawn" if tag_kind == KIND_SPAWN else "lvl_patrol"
	add_to_group(g)
	add_to_group("lvl_point_tags")
