# Scene, resource, animation, and path audit

Audited cb41a6a. No tracked source was edited. Executable evidence uses built dist with installed dependencies and Godot 4.7.stable.official.5b4e0cb0f.

Reproduce with `node /tmp/godot-scene-repro.mjs /absolute/path/to/godot-mcp`. Run the repository build first if dist is missing or stale. The script writes a new temporary project, optionally generates real fixtures and verifies reload using Godot (override executable with GODOT_BIN), and saves checks.json plus engine-output.txt. The zero-cost infinite loop is isolated in a child process and killed after two seconds. Without Godot it falls back to equivalent text fixtures. Latest run reproduced 11/11 checks in `/var/folders/qj/8hf63fb90v3gsk726drqfxlr0000gn/T/godot-audit-repro-F9K1Fv`. Original manual fixtures remain in `/tmp/godot-scene-audit.YFeB7m`.

## Findings

### [P1] Scene edits erase multiline properties

Locations: [src/parsers/tscn-parser.ts:249-259](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:249) (nodes), `:201-211` (subresources).

Properties are parsed one physical line at a time. Godot normally writes dictionaries over multiple lines. A Godot-generated metadata dictionary containing coins=42 and items=[sword,shield] becomes `{}` after parse/serialize; engine reload confirmed loss. This affects unrelated edits through every tool that rewrites existing scenes, including animation and UI setup. The parser receives only `{` and silently substitutes an empty dictionary. Multiline arrays and multiline strings are likewise unsupported.

Fix: consume complete Variant expressions across lines, with delimiter/string state, or preserve untouched expressions losslessly; fail before writing on unsupported syntax. Evidence checks: multiline_scene_dictionary_loss; original.tscn versus roundtrip.tscn.

### [P1] Scene serialization changes typed values into strings

Locations: [src/parsers/tscn-parser.ts:433-434](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:433), `:536-541`; incomplete literal whitelist `:604-619`.

Unknown Variant literals are returned as ordinary JS strings and later quoted. PackedVector2Array, other Packed arrays, typed arrays, Vector2i, and StringNames are examples. A real Godot-generated Polygon2D triangle becomes `polygon = "PackedVector2Array(0, 0, 10, 0, 0, 10)"`. Engine reload confirmed the original triangle becomes an empty polygon. This affects single-line properties independently of the multiline parser bug. Plain strings that resemble whitelisted constructors can conversely change into typed values.

Fix: preserve literal/string distinctions with tagged values or a lossless representation. Evidence check: packed_array_quoted.

### [P1] Animation keyframe editing deletes Godot-authored keys

Location: [src/tools/animation-tools.ts:901-907](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/animation-tools.ts:901); mutation writes at `:256` and `:312`.

The keys regex requires the entire dictionary on one line. Godot ResourceSaver.save emitted the keys dictionary across six lines. Reading an actual two-key Animation returned zero keyframes. Calling godot_animation_add_keyframe with time=0.5 then succeeded and overwrote the file with only that new key. Engine reload confirms original KEYS=2 versus edited KEYS=1. Existing animations may therefore be destroyed by the first normal edit.

Fix: parse complete dictionary values and reject incomplete or unsupported input before overwriting. Evidence checks: multiline_animation_keys_loss; animation_edit_deletes_existing_keys.

Additional preservation issue from source inspection: `:865-870` ignores the matched track type; `:820-822` serializes every track as enabled value/imported=false. Mixed method/audio/position tracks and disabled tracks are transformed during edits. Preserve track metadata/types or reject unsupported clips explicitly.

### [P1] Removing a node deletes unrelated siblings' descendants

Location: [src/parsers/tscn-parser.ts:657](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:657).

The predicate `node.parent?.startsWith(nodePath)` lacks a slash boundary. A scene with Player/Sprite and Player2/Sprite loses both Sprites when removing Player; the resulting node list is just Root and Player2. It can also delete descendants matching a prefix even if the requested node does not exist.

Fix: compare exact parent path or slash-delimited descendants. Treat root removal explicitly because current root-relative paths also leave descendants behind when root is removed. Evidence check: remove_deletes_sibling_descendant.

### [P1] Wave generation can hang the MCP event loop

Locations: [src/tools/resource-tools.ts:294](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/resource-tools.ts:294) (unrestricted baseCost), `:820-828` (synchronous loop).

Validated input `{waveCount:1,enemyTypes:[{name:"slime",baseCost:0}]}` enters an infinite loop: remaining never decreases. Negative costs increase it. The reproduction child printed SCHEMA_ACCEPTED then hit the two-second timeout. Because the handler is synchronous, a call blocks other MCP work. Positive-cost requests also require bounds: permitted waveCount=100 and difficultyScale=2 makes astronomical iteration counts.

Fix: strictly positive finite costs plus explicit complexity/budget caps or bounded aggregation. Evidence check: zero_cost_wave_hang.

### [P1/P2] Symlinks bypass the project path boundary

Location: [src/utils/path-utils.ts:28-37](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/utils/path-utils.ts:28).

Containment uses path.resolve/path.relative only. In a temporary project, `project/link -> ../outside` allowed godot_write_resource(path="res://link/escape.tres") to create outside/escape.tres successfully. The same resolver underlies most read/write tools, so a project path can read or overwrite outside the selected root. Severity depends on whether project containment is intended as a security boundary.

Fix: resolve real paths, including existing ancestors for new output paths, and enforce containment of the actual target. Consider races when writing. Evidence check: symlink_escape.

### [P2] Node rename orphans descendants and references

Location: [src/parsers/tscn-parser.ts:693](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:693).

Renaming Player to Hero only changes name; Sprite retains parent="Player" and signal endpoints retain Player paths. Engine warns `Parent path './Player' for node 'Sprite' has vanished`; Hero child count is zero. Thus a supported rename operation breaks a valid subtree.

Fix: atomically update descendant parent paths, signal endpoints, and relevant NodePath references, with name-collision checks. Evidence check: rename_orphans_descendant; renamed.tscn and verify.gd.

### [P2] Resource writer cannot serialize dictionaries or escaped strings

Location: [src/tools/resource-tools.ts:422-436](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/tools/resource-tools.ts:422).

Writing properties `{"metadata/inventory":{coins:42}}` produces `metadata/inventory = [object Object]`. Godot rejects this with `Unexpected identifier 'object'` and returns null. Writing resource_name='Say "hello"' produces `resource_name = "Say "hello""`; engine loads only `Say `, silently losing text. Arrays containing such values inherit these defects.

Fix: recursive Variant serialization and proper string escaping, ideally shared with other serializers. Evidence checks: resource_serialization_dictionary.tres; resource_serialization_quoted.tres.

### [P2] Scene tree output invents top-level branches

Location: [src/parsers/tscn-parser.ts:709-724](/Users/alexmeckes/Documents/ChatGPT/godotmcp/src/parsers/tscn-parser.ts:709).

The literal parent "." is inserted as a top-level key, while nested parent paths are traversed from the top-level tree rather than the actual scene root. Root -> Player -> Sprite produces separate top-level Root, ".", and Player entries; Root._children is empty. Both godot_read_scene and godot_list_scene_nodes expose this misleading hierarchy.

Fix: establish the root node once and resolve all serialized parent paths relative to it. Evidence check: incorrect_scene_tree.

## Test gaps

- Parser roundtrip tests assert collection counts rather than complete semantic equality or Godot reload behavior.
- getSceneTree test only checks that the root exists, so it misses incorrect children.
- Animation fixtures use manually authored single-line key dictionaries unlike actual Godot saver output.
- procedural-tools.test.ts:193-270 exercises toy algorithms defined inside tests rather than production wave handlers; it never reaches the zero-cost loop.
- Path tests cover lexical traversal but no symlinks.
- Existing scene tests do not cover rename with descendants or prefix-overlapping sibling names.

Add engine-generated golden fixtures and semantic reload checks, plus handler-level tests for containment and bounded work. Audit repro deliberately captures current defects; it is not a replacement production regression suite.
