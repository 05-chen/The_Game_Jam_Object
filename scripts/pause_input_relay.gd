extends Node
## 暂停时仍能轮询 pause_game 输入；由 GameWorld 注入 callback。

var callback: Callable = Callable()


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	if callback.is_valid():
		callback.call()
