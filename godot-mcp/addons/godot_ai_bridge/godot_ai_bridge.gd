@tool
extends EditorPlugin
## Main plugin for Godot AI Bridge

const WSServer = preload("res://addons/godot_ai_bridge/ws_server.gd")
const MessageHandler = preload("res://addons/godot_ai_bridge/message_handler.gd")
const RUNTIME_AUTOLOAD_NAME := "GodotAIBridgeRuntime"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_ai_bridge/runtime_bridge.gd"

var _ws_server: Node
var _message_handler: RefCounted
var _debugger_plugin: AIBridgeDebuggerPlugin
var _port: int = 6550
const PAIRING_PATH := "res://.godot/godot-ai-bridge.json"


func _enter_tree() -> void:
	_ensure_runtime_autoload()

	_message_handler = MessageHandler.new()
	_message_handler.editor_interface = get_editor_interface()
	_message_handler.undo_redo = get_undo_redo()

	# Capture runtime output, errors, and automation responses.
	_debugger_plugin = AIBridgeDebuggerPlugin.new()
	_debugger_plugin.message_handler = _message_handler
	_message_handler.debugger_plugin = _debugger_plugin
	add_debugger_plugin(_debugger_plugin)

	_ws_server = WSServer.new()
	_ws_server.port = _port
	_ws_server.pairing_token = _create_pairing_token()
	if _ws_server.pairing_token.is_empty():
		push_error("[AI Bridge] Unable to create private pairing credentials; server disabled.")
		return
	_ws_server.message_received.connect(_on_message_received)
	_ws_server.client_connected.connect(_on_client_connected)
	_ws_server.client_disconnected.connect(_on_client_disconnected)

	add_child(_ws_server)

	var err = _ws_server.start()
	if err == OK:
		print("[AI Bridge] Server started on port ", _port)
	else:
		push_error("[AI Bridge] Failed to start server: " + str(err))


func _exit_tree() -> void:
	if _debugger_plugin:
		remove_debugger_plugin(_debugger_plugin)
		_debugger_plugin = null
	if _ws_server:
		_ws_server.stop()
		_ws_server.queue_free()
		_ws_server = null
	_message_handler = null


func _create_pairing_token() -> String:
	var bytes := Crypto.new().generate_random_bytes(32)
	if bytes.size() != 32:
		return ""
	var token := bytes.hex_encode()
	var absolute_path := ProjectSettings.globalize_path(PAIRING_PATH)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		return ""
	var directory := DirAccess.open(absolute_path.get_base_dir())
	if directory == null or directory.is_link(absolute_path.get_file()):
		return ""
	# Create an empty file, restrict access, then write the secret. Never log it.
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		return ""
	# Editor safe-save writes through a temporary file until close(). Restrict
	# the resulting empty file before reopening it without replacement.
	file.close()
	if OS.get_name() != "Windows":
		if FileAccess.set_unix_permissions(absolute_path, 384) != OK:
			return ""
	file = FileAccess.open(absolute_path, FileAccess.READ_WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify({"token": token, "port": _port, "version": 1}))
	file.close()
	return token


func _ensure_runtime_autoload() -> void:
	var autoload_key := "autoload/%s" % RUNTIME_AUTOLOAD_NAME
	var existing_value := str(ProjectSettings.get_setting(autoload_key, ""))
	var normalized_existing := existing_value.trim_prefix("*")

	if normalized_existing.is_empty():
		add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)
		# A separately launched runtime reads project.godot immediately.
		if ProjectSettings.save() != OK:
			push_error("[AI Bridge] Failed to persist runtime autoload configuration.")
		return

	if normalized_existing != RUNTIME_AUTOLOAD_PATH:
		push_warning(
			"[AI Bridge] Autoload name conflict for %s: %s"
			% [RUNTIME_AUTOLOAD_NAME, existing_value]
		)


func _on_message_received(peer_id: int, message: String) -> void:
	call_deferred("_send_response_async", peer_id, message)


func _send_response_async(peer_id: int, message: String) -> void:
	var response: String = await _message_handler.handle_message(message)
	if _ws_server:
		_ws_server.send_message(peer_id, response)


func _on_client_connected(peer_id: int) -> void:
	print("[AI Bridge] Client connected: ", peer_id)


func _on_client_disconnected(peer_id: int) -> void:
	print("[AI Bridge] Client disconnected: ", peer_id)


## Debugger plugin to capture output, errors, and runtime automation responses.
class AIBridgeDebuggerPlugin extends EditorDebuggerPlugin:
	var message_handler: RefCounted

	const FILTERED_MESSAGES := [
		"game_view:cursor_set_shape",
		"game_view:mouse_over",
	]
	const RUNTIME_PREFIX := "godot_runtime"
	const DEFAULT_RUNTIME_TIMEOUT_SEC := 5.0

	var _tracked_session_ids: Array[int] = []
	var _session_runtime_ready: Dictionary = {}
	var _pending_runtime_requests: Dictionary = {}
	var _next_runtime_request_id: int = 1

	func _has_capture(_prefix: String) -> bool:
		return true

	func _capture(message: String, data: Array, session_id: int) -> bool:
		if not message_handler:
			return false

		match message:
			"%s:ready" % RUNTIME_PREFIX:
				_handle_runtime_ready(data, session_id)
				return true
			"%s:response" % RUNTIME_PREFIX:
				_handle_runtime_response(data, session_id)
				return true

		for filtered in FILTERED_MESSAGES:
			if message == filtered:
				return false

		# Ordinary engine output/error/stack packets are consumed by Godot before
		# plugin capture. MessageHandler reads the configured runtime log instead.

		return false

	func send_runtime_request(
		method: String,
		params: Dictionary,
		timeout_seconds: float = DEFAULT_RUNTIME_TIMEOUT_SEC
	) -> Dictionary:
		var session_id := _get_active_session_id()
		if session_id == -1:
			return {
				"error": {
					"code": -32603,
					"message": "No active runtime debug session. Run a scene before using runtime automation tools."
				}
			}

		var session = get_session(session_id)
		if not session:
			return {
				"error": {
					"code": -32603,
					"message": "Failed to access the active runtime debug session."
				}
			}

		var request_id := _next_runtime_request_id
		_next_runtime_request_id += 1

		_pending_runtime_requests[request_id] = {
			"ready": false,
			"payload": {},
			"session_id": session_id
		}

		session.send_message("%s:request" % RUNTIME_PREFIX, [request_id, method, params])

		var deadline := Time.get_ticks_msec() + int(max(timeout_seconds, 0.1) * 1000.0)
		while Time.get_ticks_msec() < deadline:
			var pending = _pending_runtime_requests.get(request_id)
			if pending is Dictionary and bool(pending.get("ready", false)):
				_pending_runtime_requests.erase(request_id)
				return _coerce_runtime_reply(pending.get("payload", {}), method)
			await Engine.get_main_loop().process_frame

		_pending_runtime_requests.erase(request_id)
		return {
			"error": {
				"code": -32603,
				"message": (
					"Timed out waiting for runtime automation response for %s. "
					+ "Make sure the scene is running and the runtime harness is loaded."
				) % method
			}
		}

	func _setup_session(session_id: int) -> void:
		if not _tracked_session_ids.has(session_id):
			_tracked_session_ids.append(session_id)

		_session_runtime_ready[session_id] = false

		var session = get_session(session_id)
		if not session:
			return

		var started_callable := Callable(self, "_on_session_started").bind(session_id)
		if not session.started.is_connected(started_callable):
			session.started.connect(started_callable)

		var stopped_callable := Callable(self, "_on_session_stopped").bind(session_id)
		if not session.stopped.is_connected(stopped_callable):
			session.stopped.connect(stopped_callable)

		if session.is_active():
			_on_session_started(session_id)

	func _on_session_started(session_id: int) -> void:
		_session_runtime_ready[session_id] = false
		if message_handler:
			message_handler.begin_runtime_log()
			message_handler.log_output(
				"[DEBUG] Game started (session %d)" % session_id,
				"info",
				"debugger"
			)

	func _on_session_stopped(session_id: int) -> void:
		_session_runtime_ready.erase(session_id)
		_fail_pending_requests_for_session(
			session_id,
			"Runtime debug session stopped before the automation request completed."
		)

		if message_handler:
			message_handler.end_runtime_log()
			message_handler.log_output(
				"[DEBUG] Game stopped (session %d)" % session_id,
				"info",
				"debugger"
			)

	func _get_active_session_id() -> int:
		for i in range(_tracked_session_ids.size() - 1, -1, -1):
			var session_id = _tracked_session_ids[i]
			var session = get_session(session_id)
			if session and session.is_active():
				return session_id
		return -1

	func _handle_runtime_ready(data: Array, session_id: int) -> void:
		_session_runtime_ready[session_id] = true

		var details := ""
		if data.size() > 0 and data[0] is Dictionary:
			var payload: Dictionary = data[0]
			var scene_root := str(payload.get("scene_root", ""))
			if not scene_root.is_empty():
				details = " for %s" % scene_root

		if message_handler:
			message_handler.log_output(
				"[RUNTIME] Automation harness ready%s (session %d)" % [details, session_id],
				"info",
				"debugger"
			)

	func _handle_runtime_response(data: Array, session_id: int) -> void:
		if data.size() < 2:
			if message_handler:
				message_handler.log_output(
					"[RUNTIME] Ignoring malformed runtime response for session %d" % session_id,
					"warning",
					"debugger"
				)
			return

		var request_id := int(data[0])
		if not _pending_runtime_requests.has(request_id):
			return

		var pending: Dictionary = _pending_runtime_requests[request_id]
		pending["ready"] = true
		pending["payload"] = data[1]
		pending["session_id"] = session_id
		_pending_runtime_requests[request_id] = pending

	func _coerce_runtime_reply(payload, method: String) -> Dictionary:
		if payload is Dictionary:
			var payload_dict: Dictionary = payload
			if bool(payload_dict.get("success", false)):
				return {"result": payload_dict.get("result", {})}
			return {
				"error": {
					"code": -32603,
					"message": str(
						payload_dict.get(
							"error",
							"Runtime automation request failed for " + method
						)
					)
				}
			}

		return {"result": payload}

	func _fail_pending_requests_for_session(session_id: int, error_message: String) -> void:
		var pending_ids := _pending_runtime_requests.keys()
		for request_id in pending_ids:
			var pending: Dictionary = _pending_runtime_requests.get(request_id, {})
			if int(pending.get("session_id", -1)) != session_id:
				continue
			pending["ready"] = true
			pending["payload"] = {
				"success": false,
				"error": error_message
			}
			_pending_runtime_requests[request_id] = pending
