class_name NetworkedAuthorityInteractable
extends StaticBody3D
## 联机解谜/拾取：**客户端请求 -> 主机两步校验 -> 全局广播（含拾取动画）**。


func is_interact_exhausted() -> bool:
	return false


func interact(role: int, interact_from: Vector3 = Vector3.ZERO, has_interact_from: bool = false) -> void:
	if is_interact_exhausted():
		return
	if not NetworkManager.is_multiplayer_game:
		_authority_apply_pickup_fx(interact_from if has_interact_from else global_position)
		return
	if multiplayer.is_server():
		if _authority_validate_host(multiplayer.get_unique_id(), role, interact_from, has_interact_from):
			var collector := _resolve_collector_pos(multiplayer.get_unique_id(), interact_from, has_interact_from)
			_authority_apply_broadcast.rpc(collector)
	else:
		_authority_request.rpc_id(1, role, interact_from, has_interact_from)


func _authority_validate_host(_sender_id: int, _role: int, _interact_from: Vector3 = Vector3.ZERO, _has_interact_from: bool = false) -> bool:
	push_error("NetworkedAuthorityInteractable: override _authority_validate_host()")
	return false


func _resolve_collector_pos(_sender_id: int, interact_from: Vector3, has_interact_from: bool) -> Vector3:
	return interact_from if has_interact_from else global_position


func _authority_apply_local() -> void:
	push_error("NetworkedAuthorityInteractable: override _authority_apply_local()")


func _authority_apply_pickup_fx(_collector_pos: Vector3) -> void:
	_authority_apply_local()


@rpc("any_peer", "reliable")
func _authority_request(role: int, interact_from: Vector3 = Vector3.ZERO, has_interact_from: bool = false) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	if is_interact_exhausted():
		return
	if not _authority_validate_host(sender_id, role, interact_from, has_interact_from):
		return
	var collector := _resolve_collector_pos(sender_id, interact_from, has_interact_from)
	_authority_apply_broadcast.rpc(collector)


@rpc("authority", "reliable", "call_local")
func _authority_apply_broadcast(collector_pos: Vector3) -> void:
	_authority_apply_pickup_fx(collector_pos)
