class_name NetworkedAuthorityInteractable
extends StaticBody3D
## 联机解谜/拾取通用模板：**客户端请求 -> 主机校验 -> 全局广播**。
## 子类实现：`_authority_validate_host(sender_id, role) -> bool`、`_authority_apply_local()`。
## 可选重写：`is_interact_exhausted() -> bool`（已交互则不再发请求）。


func is_interact_exhausted() -> bool:
	return false


func interact(role: int) -> void:
	if is_interact_exhausted():
		return
	if not NetworkManager.is_multiplayer_game:
		_authority_apply_local()
		return
	if multiplayer.is_server():
		if _authority_validate_host(multiplayer.get_unique_id(), role):
			_authority_apply_broadcast.rpc()
	else:
		_authority_request.rpc_id(1, role)


func _authority_validate_host(_sender_id: int, _role: int) -> bool:
	push_error("NetworkedAuthorityInteractable: override _authority_validate_host()")
	return false


func _authority_apply_local() -> void:
	push_error("NetworkedAuthorityInteractable: override _authority_apply_local()")


@rpc("any_peer", "reliable")
func _authority_request(role: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	if is_interact_exhausted():
		return
	if not _authority_validate_host(sender_id, role):
		return
	_authority_apply_broadcast.rpc()


@rpc("authority", "reliable", "call_local")
func _authority_apply_broadcast() -> void:
	_authority_apply_local()
