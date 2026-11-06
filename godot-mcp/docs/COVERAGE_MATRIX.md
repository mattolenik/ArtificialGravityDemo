# Godot MCP Coverage Matrix

## Coverage Levels
| Level | Meaning |
|---|---|
| `Strong` | End-to-end workflows are supported with multiple focused tools. |
| `Partial` | Useful operations exist, but major workflow gaps remain. |
| `Minimal` | Only basic helpers exist; most workflow still manual. |
| `Missing` | No dedicated tooling in this MCP yet. |

## Current Coverage
| Godot Subsystem | Coverage | Existing Tooling | Primary Gaps | Priority |
|---|---|---|---|---|
| Scene authoring (`.tscn`) | `Strong` | `godot_read_scene`, `godot_write_scene`, `godot_add_node`, `godot_modify_node`, `godot_validate_scene` | PackedScene instancing workflows, bulk refactors, richer semantic validation | `Medium` |
| Live editor control | `Strong` | `godot_connect`, `godot_editor_*` suite | Event subscriptions/streaming deltas, richer selection/filter operations | `Medium` |
| Runtime automation and screenshots | `Partial` | `godot_runtime_status`, `godot_runtime_wait`, `godot_runtime_press_action`, `godot_runtime_release_action`, `godot_runtime_tap_action`, `godot_runtime_mouse_move`, `godot_runtime_click`, `godot_runtime_type_text`, `godot_runtime_capture_screenshot` | Project-specific state snapshots/reset hooks, drag-and-drop, richer focus/window control | `High` |
| GDScript workflows | `Strong` | `godot_read_script`, `godot_write_script`, `godot_analyze_script`, `godot_generate_script`, `godot_validate_script` | AST-grade refactors, symbol rename, dependency graphing | `Medium` |
| UI workflows | `Strong` | `godot_ui_create_theme`, `godot_ui_create_menu`, `godot_ui_create_hud`, `godot_ui_create_layout`, `godot_ui_create_container` | Existing scene patching, accessibility checks, localization wiring | `Medium` |
| Shader workflows | `Partial` | `godot_read_shader`, `godot_write_shader`, `godot_generate_shader` | Material assignment flows, shader graph equivalents, validation/linting | `Medium` |
| Resource/data workflows | `Partial` | `godot_read_resource`, `godot_write_resource`, `godot_list_resources` | Deep typed-resource editing, `.res` support, ref integrity checks | `High` |
| Tilemap/procedural generation | `Partial` | `godot_generate_dungeon`, `godot_generate_tilemap_pattern`, `godot_generate_wave_config` | TileSet authoring, navigation baking hooks, runtime placement tools | `High` |
| Project bootstrap/docs help | `Partial` | `godot_init_project`, `godot_help`, `godot_get_class_docs`, `godot_search_docs` | Official doc sync, project config management breadth, template library depth | `Low` |
| Animation system | `Partial` | `godot_animation_create_clip`, `godot_animation_read_clip`, `godot_animation_add_keyframe`, `godot_animation_remove_keyframe`, `godot_animation_list_clips`, `godot_animation_setup_scene`, `godot_animation_build_state_machine_plan`, `godot_animation_build_blend_space_plan` | Direct AnimationTree graph resource authoring, advanced track types with scene-side wiring | `High` |
| Audio system | `Partial` | `godot_audio_create_bus_layout`, `godot_audio_read_bus_layout`, `godot_audio_set_bus`, `godot_audio_remove_bus`, `godot_audio_list_players`, `godot_audio_configure_player`, `godot_audio_list_effect_presets`, `godot_audio_generate_effect_chain_script`, `godot_audio_apply_mix_profile` | Direct effect-chain serialization in bus layout resources, live runtime mixer automation hooks | `High` |
| Input map and controls | `Partial` | `godot_input_list_actions`, `godot_input_get_action`, `godot_input_set_action`, `godot_input_remove_action`, `godot_input_list_presets`, `godot_input_apply_preset` | Runtime/player-specific rebinding profiles, per-platform overrides | `High` |
| Navigation and AI helpers | `Partial` | `godot_navigation_list_nodes`, `godot_navigation_add_region`, `godot_navigation_add_agent`, `godot_navigation_add_link`, `godot_navigation_configure_region`, `godot_navigation_configure_agent`, `godot_navigation_build_bake_plan`, `godot_navigation_validate_paths` | Editor-triggered bake execution, live path visualization overlays | `High` |
| Physics tuning workflows | `Missing` | None | Collision layer/mask matrix, shape presets, rigid/character tuning helpers | `Medium` |
| Asset import pipeline | `Missing` | None | Reimport settings, texture/audio import presets, UID dependency audits | `Medium` |
| Export/deployment | `Missing` | None | Export preset creation, platform-specific options, build validation | `Medium` |
| Multiplayer/networking | `Missing` | None | ENet/WebSocket setup, authority patterns, replication helpers | `Low` |

## Prioritized Roadmap
### Phase 1 (Highest Impact)
1. Input map refinement (runtime rebinding profiles + platform/device overrides).
2. Audio refinement (direct effect serialization + runtime automation).
3. Runtime automation refinement (state snapshots/reset hooks + richer pointer semantics).
4. Navigation refinement (editor bake execution + live path visualization).
5. Animation refinement (direct graph authoring + advanced tracks).

### Phase 2 (Workflow Depth)
1. Resource editing expansion for typed `Resource` workflows and dependency-safe updates.
2. TileSet/TileMap authoring tools beyond pattern generation.
3. Asset import pipeline tools for deterministic project setup.

### Phase 3 (Release and Advanced Systems)
1. Export preset and deployment tooling.
2. Multiplayer scaffolding and replication utilities.
3. Advanced project-wide refactor/linting utilities.

## Suggested Next Tool Packs
1. `animation-tools.ts`: direct `AnimationTree` graph authoring and non-value track support.
2. `input-tools.ts`: add runtime/player profile and layered override workflows.
3. `audio-tools.ts`: direct effect-chain serialization and runtime mix/state controls.
4. `editor-tools.ts` + AI Bridge runtime harness: state snapshots/reset hooks and richer pointer semantics.
5. `navigation-tools.ts`: editor bake execution and live debug overlays.
