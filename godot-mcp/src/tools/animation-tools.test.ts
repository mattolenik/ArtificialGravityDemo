import { describe, expect, it } from "vitest";
import {
  AnimationClip,
  buildBlendSpacePlan,
  buildStateMachinePlan,
  parseAnimationClipContent,
  registerAnimationTools,
  serializeAnimationClipContent,
} from "./animation-tools.js";
import type { ServerState, ToolHandler } from "../index.js";

describe("Animation Tools", () => {
  it("serializes and parses animation clip content", () => {
    const clip: AnimationClip = {
      length: 1.2,
      loopMode: "linear",
      step: 0.033333,
      tracks: [
        {
          path: ".:position",
          interpolation: "linear",
          updateMode: "continuous",
          loopWrap: true,
          keyframes: [
            {
              time: 0,
              value: { _type: "Vector2", x: 0, y: 0 },
              transition: 1,
            },
            {
              time: 0.6,
              value: { _type: "Vector2", x: 64, y: 0 },
              transition: 1,
            },
          ],
        },
      ],
    };

    const serialized = serializeAnimationClipContent(clip);
    const parsed = parseAnimationClipContent(serialized);

    expect(parsed.length).toBeCloseTo(1.2, 4);
    expect(parsed.loopMode).toBe("linear");
    expect(parsed.tracks.length).toBe(1);
    expect(parsed.tracks[0].path).toBe(".:position");
    expect(parsed.tracks[0].keyframes.length).toBe(2);
    expect(parsed.tracks[0].keyframes[1].time).toBeCloseTo(0.6, 4);

    const parsedValue = parsed.tracks[0].keyframes[1].value as Record<string, unknown>;
    expect(parsedValue._type).toBe("Vector2");
    expect(parsedValue.x).toBe(64);
    expect(parsedValue.y).toBe(0);
  });

  it("parses bool/string keyframes", () => {
    const raw = `[gd_resource type="Animation" format=3]

[resource]
length = 0.5
loop_mode = 0
step = 0.1
tracks/0/type = "value"
tracks/0/imported = false
tracks/0/enabled = true
tracks/0/path = NodePath(".:visible")
tracks/0/interp = 0
tracks/0/loop_wrap = false
tracks/0/keys = {"times": PackedFloat32Array(0, 0.25), "transitions": PackedFloat32Array(1, 1), "update": 1, "values": [true, false]} 
tracks/1/type = "value"
tracks/1/imported = false
tracks/1/enabled = true
tracks/1/path = NodePath(".:state")
tracks/1/interp = 1
tracks/1/loop_wrap = true
tracks/1/keys = {"times": PackedFloat32Array(0), "transitions": PackedFloat32Array(1), "update": 0, "values": ["idle"]}
`;

    const parsed = parseAnimationClipContent(raw);

    expect(parsed.tracks.length).toBe(2);
    expect(parsed.tracks[0].updateMode).toBe("discrete");
    expect(parsed.tracks[0].keyframes[0].value).toBe(true);
    expect(parsed.tracks[1].keyframes[0].value).toBe("idle");
  });

  it("builds state machine plans", () => {
    const plan = buildStateMachinePlan(
      [
        { name: "Idle", animation: "idle" },
        { name: "Run", animation: "run" },
      ],
      [{ from: "Idle", to: "Run", condition: "is_moving", xfadeTime: 0.1 }],
      "Idle"
    );

    expect(plan.type).toBe("animation_state_machine_plan");
    expect(plan.entryState).toBe("Idle");
    expect(Array.isArray(plan.requiredClips)).toBe(true);
    const script = String(plan.generatedScript);
    expect(script).toContain("AnimationNodeStateMachine");
    expect(script).toContain("AnimationNodeStateMachineTransition.new()");
    expect(script).toContain('root.add_transition(&"Idle", &"Run",');
    expect(script).not.toContain("get_transition_count(");
  });

  it("builds blend space plans", () => {
    const plan = buildBlendSpacePlan(
      "2d",
      "move_blend",
      "move_blend_y",
      [
        { animation: "idle", position: [0, 0] },
        { animation: "run", position: [1, 0] },
      ]
    );

    expect(plan.type).toBe("animation_blend_space_plan");
    expect(plan.blendMode).toBe("2d");
    const script = String(plan.generatedScript);
    expect(script).toContain("AnimationNodeBlendSpace2D");
    expect(script).toContain("Vector2(");
  });

  it("builds 1d blend space script with scalar blend positions", () => {
    const plan = buildBlendSpacePlan("1d", "speed_blend", "unused_secondary", [
      { animation: "idle", position: [0, 0] },
      { animation: "run", position: [1, 0] },
    ]);

    const script = String(plan.generatedScript);
    expect(script).toContain("AnimationNodeBlendSpace1D");
    expect(script).toContain("blend.add_blend_point(");
    expect(script).not.toContain("Vector2(");
  });

  it("registers all animation tools", () => {
    const tools: Map<string, ToolHandler> = new Map();
    const state: ServerState = {
      projectPath: ".",
      editorConnected: false,
      editorPort: 6550,
    };

    registerAnimationTools(tools, state);

    expect(tools.has("godot_animation_create_clip")).toBe(true);
    expect(tools.has("godot_animation_read_clip")).toBe(true);
    expect(tools.has("godot_animation_add_keyframe")).toBe(true);
    expect(tools.has("godot_animation_remove_keyframe")).toBe(true);
    expect(tools.has("godot_animation_list_clips")).toBe(true);
    expect(tools.has("godot_animation_setup_scene")).toBe(true);
    expect(tools.has("godot_animation_build_state_machine_plan")).toBe(true);
    expect(tools.has("godot_animation_build_blend_space_plan")).toBe(true);
  });
});

describe("animation preservation regressions", () => {
 const source = `[gd_resource type="Animation" format=3 uid="uid://test"]
[resource]
resource_name = "Walk"
metadata/custom = {"hello": 42}
tracks/0/type = "value"
tracks/0/imported = true
tracks/0/enabled = false
tracks/0/path = NodePath(".:position")
tracks/0/interp = 1
tracks/0/loop_wrap = false
tracks/0/keys = {
"times": PackedFloat32Array(0, 1),
"transitions": PackedFloat32Array(1, 1),
"update": 1,
"values": [Vector2(0, 0), Vector2(0.0000001, 2)]
}`;
 it("reads actual multiline keys and preserves unrelated fields during an edit", () => {
  const clip=parseAnimationClipContent(source);
  expect(clip.tracks[0].keyframes).toHaveLength(2);
  clip.tracks[0].keyframes.splice(1,0,{time:0.5,value:{_type:"Vector2",x:1,y:1},transition:1});
  const result=serializeAnimationClipContent(clip);
  expect(result).toContain('uid="uid://test"');
  expect(result).toContain('metadata/custom = {"hello": 42}');
  expect(result).toContain('tracks/0/enabled = false');
  expect(result).toContain('tracks/0/imported = true');
  expect(parseAnimationClipContent(result).tracks[0].keyframes).toHaveLength(3);
  expect(parseAnimationClipContent(result).tracks[0].keyframes[2].value).toMatchObject({x:0.0000001});
 });
 it("leaves nested Animation subresource tracks untouched when editing the root", () => {
  const nested = `[sub_resource type="Animation" id="Nested"]
length = 5
tracks/0/type = "value"
tracks/0/path = NodePath(".:visible")
tracks/0/keys = {
"times": PackedFloat32Array(0, 5),
"transitions": PackedFloat32Array(1, 1),
"update": 1,
"values": [false, true]
}
tracks/1/type = "method"
tracks/1/path = NodePath(".")
tracks/1/keys = {"times": PackedFloat32Array(), "values": []}`;
  const document = source.replace("[resource]", nested + "\n[resource]\nmetadata/nested = SubResource(\"Nested\")");
  const clip = parseAnimationClipContent(document);
  expect(clip.tracks).toHaveLength(1);
  clip.tracks[0].keyframes.splice(1, 0, { time: 0.5, value: {_type:"Vector2", x:1, y:1}, transition:1 });
  const result = serializeAnimationClipContent(clip);
  expect(result).toContain(nested + "\n[resource]");
  expect(result).toContain('metadata/nested = SubResource("Nested")');
  expect(parseAnimationClipContent(result).tracks[0].keyframes).toHaveLength(3);
 });
 it("preserves unsupported value literals and real strings that resemble constructors", () => {
  const clip=parseAnimationClipContent(source.replace('Vector2(0, 0), Vector2(0.0000001, 2)','PackedInt32Array(1, 2), "Vector2(1, 2)"'));
  clip.tracks[0].keyframes.push({time:0.5,value:true,transition:1});
  const result=serializeAnimationClipContent(clip);
  expect(result).toContain('PackedInt32Array(1, 2), "Vector2(1, 2)", true');
 });
 it("rejects unsupported track types and malformed keys before editing", () => {
  expect(()=>parseAnimationClipContent(source.replace('type = "value"','type = "method"'))).toThrow(/Unsupported/);
  expect(()=>parseAnimationClipContent(source.replace('"times": PackedFloat32Array(0, 1)','"times": PackedFloat32Array(0)'))).toThrow(/inconsistent/);
  expect(()=>parseAnimationClipContent(source.slice(0,-1))).toThrow(/Incomplete/);
 });
});
