# Verified bridge/editor audit findings (cb41a6a)

Validation environment: macOS, local Godot 4.7.stable.official.5b4e0cb0f, installed npm dependencies, isolated copied project `/tmp/godot-bridge-audit`. No tracked source files edited. Only isolated plugin copy changes `_port` to 16650. Full editor and attached headless runtime were exercised, not solely static analysis. Tests below used raw JSON-RPC requests over `ws` unless explicitly MCP HTTP.

## P1 — Arbitrary-origin unauthenticated bridge exposes GDScript execution

Location: [addons/godot_ai_bridge/ws_server.gd:57-62](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/ws_server.gd:57) (accept_stream without Origin/authentication validation), [addons/godot_ai_bridge/message_handler.gd:95-96,423-493](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/message_handler.gd:95) (arbitrary script execution).

Repro: enable plugin in an isolated editor; `new WebSocket('ws://127.0.0.1:16650', {origin:'https://untrusted.example'})`; on open immediately send `{"jsonrpc":"2.0","id":1,"method":"execute.gdscript","params":{"code":"return OS.get_name()"}}`. No initialize, credentials, or pairing. Actual response: `{"id":1,"jsonrpc":"2.0","result":{"executed":true,"result":"macOS"}}`.

The bridge binds loopback, but loopback is not an authentication boundary against web content. A browser-origin client that is permitted to connect to loopback WebSockets can execute GDScript with editor-user privileges, including Godot's filesystem/process APIs. Origin acceptance was directly verified using Node's ws Origin option; a real browser exploit was NOT run. Browser Local Network Access, mixed-content, and other restrictions vary and are material preconditions, so do not claim every browser/page is exploitable. The HTTP MCP server's Origin validation does not protect this separate bridge endpoint. Add pairing/token auth at minimum, Origin restrictions before privileged dispatch, and explicit control of arbitrary execution.

## P1 — Removing and undoing a subtree silently drops descendants on save

Location: [addons/godot_ai_bridge/message_handler.gd:218-223](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/message_handler.gd:218), especially undo ownership restoration at 221.

Fixture: `Main` root -> `Branch` -> `Leaf`, both descendants owned by Main. Call `scene_tree.remove_node {path:'Branch'}` then normal editor undo. For headless reproduction, undo via execute.gdscript:

```gdscript
var root = editor_interface.get_edited_scene_root()
var history_id = message_handler.undo_redo.get_object_history_id(root)
message_handler.undo_redo.get_history_undo_redo(history_id).undo()
return {"branch": str(root.get_node("Branch").owner), "leaf": str(root.get_node("Branch/Leaf").owner)}
```

Before removal both owners were Main; after undo Branch owner was Main, Leaf owner was `<Object#null>`. `editor.save_scene` returned saved:true and the resulting `.tscn` contained Main and Branch only; Leaf was lost. Godot remove_child clears invalid subtree ownership; code restores only the removed top node. Undo also appends instead of restoring sibling index. Preserve every affected owner and original sibling position in undo.

## P2 — Standard runtime prints/errors are never delivered to the chosen debugger capture hook

Location: [addons/godot_ai_bridge/godot_ai_bridge.gd:124-132](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/godot_ai_bridge.gd:124) (unreachable branches for ordinary engine output/error/stack messages).

Start isolated editor with `--headless --editor --debug-server tcp://127.0.0.1:16700 --lsp-port 16701 --dap-port 16702 --path /tmp/godot-bridge-audit res://main.tscn`; start separate runtime `godot --headless --remote-debug tcp://127.0.0.1:16700 --path /tmp/godot-bridge-audit res://runtime_probe.tscn`. Its script prints `BRIDGE_AUDIT_PRINT_SENTINEL`, push_warning emits `BRIDGE_AUDIT_WARNING_SENTINEL`, push_error emits `BRIDGE_AUDIT_ERROR_SENTINEL`. All appear on runtime process output. `runtime.status` succeeds, confirming live harness/session. `info.output` returns only debugger session/custom game_view messages, none of the sentinels. `info.errors {include_script:false,include_log_file:false}` returns `count:0`, `runtime_count:0`.

Godot engine dispatch confirms built-in output/error/stack messages are handled before plugin capture; only unmatched custom messages go to plugins_capture. Official source: https://github.com/godotengine/godot/blob/master/editor/debugger/script_editor_debugger.cpp#L934-L971 . This is not a problem with the new runtime RPC custom messages, which work. Default log-file inclusion can recover error text when logs exist; it does not make the advertised structured runtime capture function. Use a supported output/error signal or logging path, with a real-engine integration test. Repro fixture script and scene remain in `/tmp/godot-bridge-audit`.

## P2 — Runtime waits over five seconds always fail

Location: [addons/godot_ai_bridge/godot_ai_bridge.gd:98,147-150,186-199](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/godot_ai_bridge.gd:98); [addons/godot_ai_bridge/message_handler.gd:333-339,411](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/message_handler.gd:333) forwards without duration-dependent timeout.

Live `runtime.status` succeeds. `runtime.wait {seconds:6}` returns error -32603 `Timed out waiting for runtime automation response for wait...` after 5017 milliseconds. Godot's fixed DEFAULT_RUNTIME_TIMEOUT_SEC=5 cuts off the intended wait; runtime operation continues but reply is discarded. Large tap_action frame counts and click holdFrames suffer similarly. TS permits unbounded wait and separately imposes 30s request timeout. Both layers need coordinated duration-aware timeout or explicit validated limits.

## P2 — Incremental log reads skip the first newly appended line

Location: [addons/godot_ai_bridge/message_handler.gd:952,957-960,983-985](/Users/alexmeckes/Documents/ChatGPT/godotmcp/addons/godot_ai_bridge/message_handler.gd:952).

Repro files `/tmp/godot-bridge-audit/log_probe.gd` and `log_probe_handler.gd` subclass only log path resolution, invoke the original scanner unchanged. Run `godot --headless --path /tmp/godot-bridge-audit --script log_probe.gd`.

1. Log contents `first\n`; scanner returns first, `next_since_line:2` (counts trailing empty split element).
2. Append `second\n`; scan with since_line:2 returns entries:[] and next_since_line:3.

The appended second line is numbered 2 and discarded by `line_number <= since_line`; polling on newline-terminated logs consistently drops a line each cycle. Track completed lines/byte offsets correctly; also account for truncation/rotation.

## P2 — Disconnect/reconnect race clears the new connection

Location: [src/tools/editor-tools.ts:776-784](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/editor-tools.ts:776) (old socket close unconditionally clears global new socket and rejects all pending requests); related disconnect at 75-78.

Verified against real isolated bridge using built dist (built by parent): registerEditorTools, await handler godot_connect, await handler godot_disconnect, immediately await handler godot_connect, then godot_connection_status. First connection succeeds normally. Reconnect returns success:true and `(init info unavailable)`, but status connected:false. Old socket close fires after the new socket is assigned and clears wsConnection; an actual open socket is orphaned. Bind each lifecycle callback and requests to its socket instance, await/dedupe connection transitions, and don't report initialization failures as a healthy connection.

Repro command from repo root:
```js
import {registerEditorTools} from './dist/tools/editor-tools.js';
const tools=new Map();
registerEditorTools(tools,{projectPath:'/tmp/godot-bridge-audit',editorConnected:false,editorPort:16650});
const call=(name,args={})=>tools.get(name).handler(args);
console.log(await call('godot_connect'));
console.log(await call('godot_disconnect'));
console.log(await call('godot_connect'));
console.log(await call('godot_connection_status'));
process.exit();
```

## P2 — HTTP graceful shutdown leaves process alive with active bridge

Location: [src/index.ts:259-266](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/index.ts:259), bridging [src/tools/editor-tools.ts:721](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/editor-tools.ts:721).

Verified parent's static concern. Spawn `node dist/index.js --transport http --http-port 16651 --port 16650 --project /tmp/godot-bridge-audit`; POST a legacy tools/call godot_connect (headers accept:application/json,text/event-stream; content-type:application/json; mcp-protocol-version:2025-11-25). Result success:true. Send SIGTERM. After 1.5s HTTP listener is closed but child exitCode is null and process remains alive until SIGKILL; active bridge WebSocket keeps event loop alive. Signal handler overrides Node's normal termination and never disposes bridge connection. Expose/dispose editor transport as part of shutdown.

## Coverage gaps / lower-priority observations (not promoted as verified report findings)

- Existing editor-tools test checks one wait schema; RPC contract tests match source strings/method names. They do not execute Godot or exercise socket lifecycle, undo, outputs, auth, or timeouts.
- runtime text helper strips leading/trailing whitespace for type_text, changing user input (static).
- Runtime autoload is added to project.godot at enable but not removed on disable; need consider intended lifecycle (static).
- _handle_add_node instantiates arbitrary ClassDB type without ensuring Node; malformed or non-node type can cause script runtime errors instead of JSON-RPC error (static).
- _handle_save_scene ignores save_scene error return and claims saved:true (static).
- Editor scripts compiled through fresh anonymous GDScript in info.errors lose original resource path, potentially causing false relative-preload/class_name issues (not reproed).
- Interactive rendering/screenshots, keyboard/action semantics, pause behavior, Godot versions older than 4.7, and Windows/Linux not exercised.
