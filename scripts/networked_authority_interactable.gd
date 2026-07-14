class_name NetworkedAuthorityInteractable
extends StaticBody3D
## 联机解谜/拾取：**客户端请求 -> 主机校验 -> 成功广播 / 失败回传提示**。


enum RejectReason {
	NONE = 0,
	EXHAUSTED = 1, ## 已捡过或本阶段未开放
	ROLE = 2, ## 角色不对（镇定剂/止疼药）
	RANGE = 3, ## 距离/朝向不够
	PLAYER = 4, ## 找不到对应玩家
	GENERIC = 5,
}


func is_interact_exhausted() -> bool:
	return false


func interact(role: int, interact_from: Vector3 = Vector3.ZERO, has_interact_from: bool = false) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	if is_interact_exhausted():
		_send_reject(multiplayer.get_unique_id(), RejectReason.EXHAUSTED)
		return
	if multiplayer.is_server():
		var reason := _authority_reject_reason(multiplayer.get_unique_id(), role, interact_from, has_interact_from)
		if reason == RejectReason.NONE:
			var collector := _resolve_collector_pos(multiplayer.get_unique_id(), interact_from, has_interact_from)
			_authority_apply_broadcast.rpc(collector)
		else:
			_send_reject(multiplayer.get_unique_id(), reason)
	else:
		_authority_request.rpc_id(1, role, interact_from, has_interact_from)


## 子类重写：返回 RejectReason；NONE 表示通过
func _authority_reject_reason(_sender_id: int, _role: int, _interact_from: Vector3 = Vector3.ZERO, _has_interact_from: bool = false) -> int:
	if _authority_validate_host(_sender_id, _role, _interact_from, _has_interact_from):
		return RejectReason.NONE
	return RejectReason.GENERIC


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
		_send_reject(sender_id, RejectReason.EXHAUSTED)
		return
	var reason := _authority_reject_reason(sender_id, role, interact_from, has_interact_from)
	if reason != RejectReason.NONE:
		_send_reject(sender_id, reason)
		return
	var collector := _resolve_collector_pos(sender_id, interact_from, has_interact_from)
	_authority_apply_broadcast.rpc(collector)


@rpc("authority", "reliable", "call_local")
func _authority_apply_broadcast(collector_pos: Vector3) -> void:
	_authority_apply_pickup_fx(collector_pos)


func _send_reject(peer_id: int, reason: int) -> void:
	if reason == RejectReason.NONE:
		return
	# 本机（主机自己操作）直接提示；客机用 RPC
	if peer_id <= 0 or peer_id == multiplayer.get_unique_id():
		_notify_local_pickup_rejected(reason)
	else:
		_authority_reject.rpc_id(peer_id, reason)


@rpc("authority", "reliable")
func _authority_reject(reason: int) -> void:
	_notify_local_pickup_rejected(reason)


func _notify_local_pickup_rejected(reason: int) -> void:
	var msg := _reject_reason_text(reason)
	var root := get_tree().current_scene
	if root == null:
		return
	var player_name := "BlindPlayer" if GameManager.current_role == GameManager.ROLE_BLIND else "LamePlayer"
	var player := root.get_node_or_null(player_name)
	if player != null and player.has_method("_show_msg"):
		player.call("_show_msg", msg)


func _reject_reason_text(reason: int) -> String:
	match reason:
		RejectReason.EXHAUSTED:
			return "物品不可用（已拾取或不在本阶段）"
		RejectReason.ROLE:
			return "这个物品需要另一位角色来拾取"
		RejectReason.RANGE:
			return "再靠近一些，或转向物品后再试"
		RejectReason.PLAYER:
			return "拾取校验失败，请稍后再试"
		_:
			return "无法拾取"
