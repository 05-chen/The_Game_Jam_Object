extends Node

## --- 基础配置 ---
const DEFAULT_SAMPLE_RATE: int = 16000
const LOCAL_PACKET_READ_LIMIT: int = 6

## --- 状态变量 ---
var _sample_rate: int = DEFAULT_SAMPLE_RATE
var _is_recording: bool = false
var always_on_voice: bool = true

# 核心：由外部逻辑脚本（如 PainVoiceLogic）修改此变量
var is_disabled_by_pain: bool = false 

## --- 远程音频组件 ---
var _remote_player: AudioStreamPlayer = null
var _remote_generator: AudioStreamGenerator = null
var _remote_playback: AudioStreamGeneratorPlayback = null
var _remote_pcm_buffer: PackedByteArray = PackedByteArray()
var _remote_read_idx: int = 0
var _remote_volume_multiplier: float = 1.0
var _runtime_enabled: bool = true

func _ready() -> void:
	# 只允许 Autoload 单例实例运行语音主循环，避免场景内重复 VoiceCore 造成双录音/双播放
	if self != VoiceChatManager:
		process_mode = Node.PROCESS_MODE_DISABLED
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 确保 Steam 初始化后再设置语音
	call_deferred("_setup_voice")

func _setup_voice() -> void:
	_setup_sample_rate()
	_setup_remote_audio_player()

func _process(_delta: float) -> void:
	if not _runtime_enabled:
		if _is_recording:
			_set_recording(false)
		return
	if not NetworkManager.is_multiplayer_game:
		if _is_recording: _set_recording(false)
		_remote_volume_multiplier = 1.0
		is_disabled_by_pain = false
		return

	_update_recording_state()
	
	if _is_recording:
		_poll_and_send_local_voice()
		
	_consume_remote_audio_frames()

func _setup_sample_rate() -> void:
	if not Steam.isSteamRunning():
		print("语音组件：Steam 未运行")
		return
	_sample_rate = DEFAULT_SAMPLE_RATE

func _setup_remote_audio_player() -> void:
	_remote_player = AudioStreamPlayer.new()
	_remote_player.name = "RemoteVoicePlayer"
	add_child(_remote_player)

	_remote_generator = AudioStreamGenerator.new()
	_remote_generator.mix_rate = _sample_rate
	_remote_generator.buffer_length = 0.06
	_remote_player.stream = _remote_generator
	_remote_player.play()
	_remote_playback = _remote_player.get_stream_playback()

func _update_recording_state() -> void:
	# 核心逻辑：只有在没被疼痛禁用时，按键或常开才有效
	var can_work = not is_disabled_by_pain
	var should_record: bool = (always_on_voice or Input.is_action_pressed("push_to_talk")) and can_work
	
	if should_record != _is_recording:
		_set_recording(should_record)

func _set_recording(enable: bool) -> void:
	_is_recording = enable
	if enable:
		Steam.startVoiceRecording()
	else:
		Steam.stopVoiceRecording()

func stop_voice_capture(reason: String = "") -> void:
	shutdown_voice(reason if reason != "" else "stop_voice_capture")

func shutdown_voice(reason: String = "") -> void:
	if not _runtime_enabled and not _is_recording:
		return
	print("[Voice] shutdown_voice reason=", reason)
	_runtime_enabled = false
	if _is_recording:
		_set_recording(false)
	_remote_pcm_buffer.clear()
	_remote_read_idx = 0
	_remote_volume_multiplier = 0.0
	is_disabled_by_pain = false
	if _remote_player and _remote_player.playing:
		_remote_player.stop()

func startup_voice(reason: String = "") -> void:
	if _runtime_enabled:
		return
	print("[Voice] startup_voice reason=", reason)
	_runtime_enabled = true
	_remote_volume_multiplier = 1.0
	if _remote_player and not _remote_player.playing:
		_remote_player.play()

func set_local_pain_voice_policy(pain: float) -> void:
	# 规则：>=80 禁言；40~80 保持可录音，由远端播放增益做衰减体现
	is_disabled_by_pain = pain >= 80.0

func set_remote_pain_voice_policy(pain: float) -> void:
	# 规则：40~80 线性衰减；>=80 完全静音
	if pain >= 80.0:
		_remote_volume_multiplier = 0.0
	elif pain >= 40.0:
		_remote_volume_multiplier = GameManager.get_voice_multiplier_from_pain(pain)
	else:
		_remote_volume_multiplier = 1.0

func _poll_and_send_local_voice() -> void:
	for _i in range(LOCAL_PACKET_READ_LIMIT):
		var voice_data: Dictionary = Steam.getVoice()
		
		if voice_data.get("result", -1) != Steam.VOICE_RESULT_OK:
			break

		var packet: PackedByteArray = voice_data.get("buffer", PackedByteArray())
		if packet.is_empty():
			break
			
		NetworkManager.send_voice_packet(packet)

func push_remote_voice_packet(compressed_voice: PackedByteArray) -> void:
	if compressed_voice.is_empty(): return
	
	var decompressed: Dictionary = Steam.decompressVoice(compressed_voice, _sample_rate)
	if decompressed.get("result", -1) != Steam.VOICE_RESULT_OK: return

	var pcm: PackedByteArray = decompressed.get("uncompressed", PackedByteArray())
	if pcm.is_empty(): return
	
	_remote_pcm_buffer.append_array(pcm)

func _consume_remote_audio_frames() -> void:
	if _remote_playback == null or _remote_pcm_buffer.is_empty():
		return

	var frames_available: int = _remote_playback.get_frames_available()
	
	var volume_mul: float = _remote_volume_multiplier

	while frames_available > 0 and _remote_read_idx + 1 < _remote_pcm_buffer.size():
		var lo: int = _remote_pcm_buffer[_remote_read_idx]
		var hi: int = _remote_pcm_buffer[_remote_read_idx + 1]
		
		var raw_value: int = lo | (hi << 8)
		if raw_value >= 32768: raw_value -= 65536
		
		var amplitude: float = clampf((float(raw_value) / 32768.0) * volume_mul, -1.0, 1.0)
		_remote_playback.push_frame(Vector2(amplitude, amplitude))
		
		_remote_read_idx += 2
		frames_available -= 1

	if _remote_read_idx >= _remote_pcm_buffer.size():
		_remote_pcm_buffer.clear()
		_remote_read_idx = 0
	elif _remote_pcm_buffer.size() > 8192: 
		_remote_pcm_buffer = _remote_pcm_buffer.slice(_remote_read_idx)
		_remote_read_idx = 0
