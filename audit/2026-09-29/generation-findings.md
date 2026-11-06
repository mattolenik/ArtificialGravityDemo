# Generated-content audit findings

Audit scope: scripts, shaders, input, audio, navigation, UI components, UI themes, UI layout. Source checkout cb41a6a at `/Users/alexmeckes/Documents/ChatGPT/godotmcp`. No tracked source edits. Procedural implementation coverage delegated to the scene/resource auditor.

Reproductions invoke the real registered handlers after `inputSchema.parse`, then load emitted assets with installed Godot 4.7 (`4.7.stable.official.5b4e0cb0f`). They use the freshly built `dist` corresponding to audited source.

## Highest-priority confirmed findings

### P1 — Updating a bus silently deletes all persisted effects

Source: [src/tools/audio-tools.ts:599-617](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/audio-tools.ts:599), particularly `609-614`; parser `620-658`; destructive rewrite callers `292`, `340-344`, `584`.

`parseAudioBusLayoutContent` retains only name/send/volume/mute/solo/bypass. `serializeAudioBusLayoutContent` recreates the entire .tres from those fields, losing all subresources, ext resources, `bus/N/effect/M/effect`, and enabled flags. Consequently changing just volume through `godot_audio_set_bus`, removing another bus, or applying a mix profile destroys every configured effect chain.

Repro: start with a valid Master bus containing one AudioEffectReverb subresource and enabled slot, then call `godot_audio_set_bus({name:"Master",volumeDb:-6})`. Handler reports `success:true`. Actual Godot `AudioServer.set_bus_layout` and `get_bus_effect_count(0)` show `EFFECTS_BEFORE=1`, `EFFECTS_AFTER=0`.

Fix direction: preserve the complete resource document and modify requested bus properties only, including effect resources when bus indices change; add a fixture with actual saved effects.

### P1/P2 — Adding an input action changes unrelated existing bindings

Source: [src/tools/input-tools.ts:550-556](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/input-tools.ts:550), `663-680`, especially `672-673`; full-section rewrite at `215-219`.

Every mutation reparses and reserializes the full InputMap. Recognized mouse events lose modifier keys on parse, then all modifiers are hardcoded false on serialization. Key events also lose `key_label`, `location`, and other unsupported fields (`669`). The raw-preservation mechanism applies only to unrecognized event classes, so it does not protect existing valid fields on recognized classes.

Repro: project has `modified_click` bound to `Object(InputEventMouseButton,"button_index":1,"ctrl_pressed":true)`. Add an unrelated `jump` action with a space key binding using `godot_input_set_action`. Godot `InputMap.load_from_project_settings()` and `action_get_events("modified_click")[0].ctrl_pressed` return `false` afterward. This silently changes Ctrl+click to plain click. Removing an action or applying a preset uses the same lossy rewrite.

Fix direction: preserve untouched event literals/fields, or edit only the target action. Explicitly regression-test modifier mouse shortcuts and located/labeled key events.

### P2 — UI components generated with nested relative paths cannot load their scripts

Source: [src/tools/ui-component-tools.ts:157-168](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/ui-component-tools.ts:157), `375-376`; identical pattern HUD `486-487`, dialog `719-720`.

Filesystem paths are resolved relative to the project, but generated `[ext_resource]` paths reuse the original input directory. Godot resolves a relative ext_resource path relative to the .tscn directory, producing a duplicated directory component. Menus, HUDs and dialogs are affected.

Repro: `godot_ui_create_menu({path:"scenes/menu.tscn",title:"Menu",buttons:[{text:"Play"}]})` reports success and writes `scenes/menu.gd`. Loading the generated scene in Godot errors: `Attempt to open script 'res://scenes/scenes/menu.gd' ... File not found`, then `referenced non-existent resource`. A `res://` input avoids it, but project-relative paths are otherwise supported by the shared resolver.

Fix direction: canonicalize resource references to project-root `res://...`, independently from disk paths, or use the script basename relative to the scene.

### P2 — The default script generator emits invalid movement code

Source: [src/tools/script-tools.ts:585-590](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/script-tools.ts:585); default `extends:"Node"` schema near `126-129`.

The generator selects `position += Vector2 ...` for every non-CharacterBody class when the description mentions player/movement/WASD. Default Node has no position; Node3D has Vector3 position, which cannot be added to Vector2. Thus a normal minimal invocation returns uncompilable GDScript.

Repro: `godot_generate_script({description:"player movement"})` emits `extends Node` and a `_process` body using `position`. Godot errors at generated line 8: `Identifier "position" not declared in the current scope`. The project's `godot_validate_script` reports `valid:true`, zero issues for exactly this output (its checks are heuristic linting, not parsing).

Fix direction: restrict movement templates to appropriate base classes/dimensions, select a compatible default, or reject incompatible combinations. Test the public handler output with the real GDScript parser. Avoid presenting heuristic lint results as compilation validity.

## Smaller confirmed defects

### P2 — Empty menu/dialog button arrays generate an empty function body

Source: [src/tools/ui-component-tools.ts:458-462](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/ui-component-tools.ts:458) and `805-809`.

Schemas accept an empty buttons array. The generator emits `func _ready() -> void:` followed by no indented statements. Repro `godot_ui_create_menu({path:"res://empty_menu.tscn",title:"Menu",buttons:[]})` returns success, but Godot errors `Expected indented block after function declaration`. An empty custom dialog is similarly affected. Emit `pass` or require a nonempty array.

### P2 — Fully transparent theme/stylebox colors become opaque

Source: [src/tools/ui-theme-tools.ts:408](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/ui-theme-tools.ts:408) (also `330`, `335`, `384-385`, `411`, `436`).

Using `a || 1` treats valid alpha 0 as omitted. `godot_ui_create_stylebox` with `bg_color:{r:0,g:0,b:0,a:0}` produces alpha 1; actual Godot reads `ALPHA=1.0`. Similar truthiness checks discard explicit content margin 0 (`428-432`); Godot reads `MARGIN=-1.0`, its automatic-margin sentinel. Use nullish/default handling and undefined checks.

### P2 — Navigation validation can approve a region from the wrong dimension

Source: [src/tools/navigation-tools.ts:706-716](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/navigation-tools.ts:706) and `653-656`.

Descriptors already contain dimension, but layer coverage checks ignore it and ignore enabled state. A NavigationAgent2D plus a disabled NavigationRegion3D on layer 1 returns `valid:true`, no warnings, even with `strict:true`. Separately a region with explicit `navigation_mesh = null` counts as having a resource and returns `readyForBake:true` because the check only tests `!== undefined`. This is reproducible by the public handlers; see `more-repro.mjs`. This does not require implementing full pathfinding: elementary dimension and non-null resource checks are missing from the advertised consistency checks.

## Repro artifacts and commands

- `/tmp/godot-mcp-generation-audit/repro.mjs`: primary fixtures, real tool calls, writes `game/verify.gd`.
- `/tmp/godot-mcp-generation-audit/game/verify.gd`: real engine load and state checks.
- `/tmp/godot-mcp-generation-audit/engine-results.txt`: captured engine evidence.
- `/tmp/godot-mcp-generation-audit/more-repro.mjs`: shader coverage plus navigation validation fixture.
- `/tmp/godot-mcp-generation-audit/shader-results.txt`: shader parser output.

```sh
node /tmp/godot-mcp-generation-audit/repro.mjs
godot --headless --path /tmp/godot-mcp-generation-audit/game --script res://verify.gd
node /tmp/godot-mcp-generation-audit/more-repro.mjs
godot --headless --path /tmp/godot-mcp-generation-audit/game --script res://verify_shaders.gd
```

Note: Godot printed errors but exited zero for resource/script load failures inside the check script, so CI must inspect load validity/error output rather than trusting process exit alone.

## Positive coverage and remaining limits

All 11 built-in shader effects and all five custom shader-type templates passed Godot's headless shader parser via `Shader.get_shader_uniform_list()`. Confirmed this method actually invokes parsing by first probing with an intentionally invalid unknown identifier, which produced a compiler error. This confirms syntax only, not GPU render appearance or intended behavior. Shader presets ignore requested `shaderType` and always emit their hardcoded type; custom sky/fog templates contain only the header. These limitations are noted, not elevated above confirmed destructive and broken-output findings.

Reviewed navigation and UI layout serializers; no additional high-confidence data-loss finding independent of the shared TSCN parser's issues. No UI visual-render review performed.

Test blindspots: `src/tools/script-tools.test.ts`, `shader-tools.test.ts`, and `procedural-tools.test.ts` import only Vitest and test copied regexes/data/templates rather than production implementations. Registry integration mostly verifies registration/schemas, not generated outputs. Audio tests import production but round-trip only simplified no-effects layouts. Input tests cover common types and joypad round trips but not modifier mouse events or key metadata preservation. No production UI generation tests identified. These gaps explain why engine-invalid outputs and destructive round trips pass the existing suite.
