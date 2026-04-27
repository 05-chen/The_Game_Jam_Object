extends Area3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if body == null:
		return
	if not body.has_method("get_role"):
		return
	var world := get_tree().current_scene
	if world and world.has_method("notify_checkpoint_reached"):
		world.notify_checkpoint_reached(self)
