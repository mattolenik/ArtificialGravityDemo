/**
 * Animation tools for Godot MCP
 *
 * Supports Animation resource (.tres/.anim) workflows and scene setup
 * for AnimationPlayer/AnimationTree nodes.
 */

import { z } from "zod";
import * as fs from "../utils/project-fs.js";
import { splitGodotStatements, splitGodotList } from "../parsers/godot-text.js";
import * as path from "path";
import { TscnParser, ParsedScene, SceneNode } from "../parsers/tscn-parser.js";
import type { ToolHandler, ServerState } from "../index.js";
import {
  getProjectRelativePath,
  resolveProjectDirectory,
  resolveProjectPath,
} from "../utils/path-utils.js";
import {
  assertSceneParentExists,
  buildSceneNodePath,
  sceneHasNodePath,
} from "../utils/scene-path-utils.js";

export interface AnimationKeyframe {
  time: number;
  value: unknown;
  transition: number;
}

export interface AnimationTrack {
  path: string;
  interpolation: "nearest" | "linear" | "cubic";
  updateMode: "continuous" | "discrete" | "capture";
  loopWrap: boolean;
  keyframes: AnimationKeyframe[];
}

export interface AnimationClip {
  length: number;
  loopMode: "none" | "linear" | "pingpong";
  step: number;
  tracks: AnimationTrack[];
}

export interface AnimationStateDefinition {
  name: string;
  animation: string;
  position?: number[];
}

export interface AnimationTransitionDefinition {
  from: string;
  to: string;
  condition?: string;
  xfadeTime?: number;
}

export interface BlendPointDefinition {
  animation: string;
  position: number[];
}

const LOOP_MODE_TO_ID: Record<AnimationClip["loopMode"], number> = {
  none: 0,
  linear: 1,
  pingpong: 2,
};

const LOOP_MODE_FROM_ID: Record<number, AnimationClip["loopMode"]> = {
  0: "none",
  1: "linear",
  2: "pingpong",
};

const INTERPOLATION_TO_ID: Record<AnimationTrack["interpolation"], number> = {
  nearest: 0,
  linear: 1,
  cubic: 2,
};

const INTERPOLATION_FROM_ID: Record<number, AnimationTrack["interpolation"]> = {
  0: "nearest",
  1: "linear",
  2: "cubic",
};

const UPDATE_MODE_TO_ID: Record<AnimationTrack["updateMode"], number> = {
  continuous: 0,
  discrete: 1,
  capture: 2,
};

const UPDATE_MODE_FROM_ID: Record<number, AnimationTrack["updateMode"]> = {
  0: "continuous",
  1: "discrete",
  2: "capture",
};

const KeyframeSchema = z.object({
  time: z.number().min(0).describe("Keyframe time in seconds"),
  value: z.unknown().describe("Keyframe value (number, bool, string, Vector, Color, etc.)"),
  transition: z.number().min(0).optional().default(1).describe("Transition weight to next keyframe"),
});

const TrackSchema = z.object({
  path: z
    .string()
    .describe("Animation target NodePath (example: '.:position' or 'Player:modulate')"),
  interpolation: z
    .enum(["nearest", "linear", "cubic"])
    .optional()
    .default("linear")
    .describe("Track interpolation mode"),
  updateMode: z
    .enum(["continuous", "discrete", "capture"])
    .optional()
    .default("continuous")
    .describe("Value update mode"),
  loopWrap: z
    .boolean()
    .optional()
    .default(true)
    .describe("Whether track wraps at loop boundary"),
  keyframes: z.array(KeyframeSchema).min(1).describe("Keyframes for this track"),
});

const StateSchema = z.object({
  name: z.string().min(1).describe("State name"),
  animation: z.string().min(1).describe("Animation clip name"),
  position: z
    .array(z.number())
    .length(2)
    .optional()
    .describe("Editor graph position [x, y] for state node"),
});

const TransitionSchema = z.object({
  from: z.string().min(1).describe("Source state"),
  to: z.string().min(1).describe("Destination state"),
  condition: z
    .string()
    .optional()
    .describe("Optional condition parameter name (bool parameter)"),
  xfadeTime: z.number().min(0).optional().default(0.15).describe("Crossfade duration"),
});

const BlendPointSchema = z.object({
  animation: z.string().min(1).describe("Animation clip name"),
  position: z
    .array(z.number())
    .length(2)
    .describe("Blend point [x, y] in blend-space coordinates"),
});

export function registerAnimationTools(
  tools: Map<string, ToolHandler>,
  state: ServerState
): void {
  tools.set("godot_animation_create_clip", {
    description:
      "Create an Animation resource (.tres/.anim) with value tracks and keyframes.",
    inputSchema: z.object({
      path: z.string().describe("Output path for animation resource (for example: 'res://animations/walk.tres')"),
      length: z.number().min(0.01).optional().default(1).describe("Clip length in seconds"),
      loopMode: z
        .enum(["none", "linear", "pingpong"])
        .optional()
        .default("none")
        .describe("Loop behavior"),
      step: z
        .number()
        .min(0.0001)
        .optional()
        .default(1 / 30)
        .describe("Animation step size in seconds"),
      tracks: z.array(TrackSchema).optional().default([]).describe("Value tracks to create"),
    }),
    handler: async (args) => {
      const { path: clipPath, length, loopMode, step, tracks } = args as {
        path: string;
        length: number;
        loopMode: AnimationClip["loopMode"];
        step: number;
        tracks: Array<z.infer<typeof TrackSchema>>;
      };

      const clip = normalizeClip({ length, loopMode, step, tracks });
      const content = serializeAnimationClipContent(clip);
      const fullPath = resolveProjectPath(clipPath, state.projectPath);

      await fs.mkdir(path.dirname(fullPath), { recursive: true });
      await fs.writeFile(fullPath, content, "utf-8");

      return {
        success: true,
        path: clipPath,
        summary: summarizeClip(clip),
      };
    },
  });

  tools.set("godot_animation_read_clip", {
    description:
      "Read an Animation resource (.tres/.anim) and return structured tracks/keyframes.",
    inputSchema: z.object({
      path: z.string().describe("Path to animation resource"),
    }),
    handler: async (args) => {
      const { path: clipPath } = args as { path: string };
      const fullPath = resolveProjectPath(clipPath, state.projectPath);

      const content = await fs.readFile(fullPath, "utf-8");
      const clip = parseAnimationClipContent(content);

      return {
        path: clipPath,
        clip,
        summary: summarizeClip(clip),
      };
    },
  });

  tools.set("godot_animation_add_keyframe", {
    description:
      "Add a keyframe to an existing animation track, sorted by keyframe time.",
    inputSchema: z.object({
      path: z.string().describe("Path to animation resource"),
      trackIndex: z.number().int().min(0).describe("Track index"),
      time: z.number().min(0).describe("Keyframe time in seconds"),
      value: z.unknown().describe("Keyframe value"),
      transition: z.number().min(0).optional().default(1).describe("Transition weight"),
    }),
    handler: async (args) => {
      const { path: clipPath, trackIndex, time, value, transition } = args as {
        path: string;
        trackIndex: number;
        time: number;
        value: unknown;
        transition: number;
      };

      const fullPath = resolveProjectPath(clipPath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const clip = parseAnimationClipContent(content);

      if (!clip.tracks[trackIndex]) {
        throw new Error(`Track index out of range: ${trackIndex}`);
      }
      if (time > clip.length) {
        throw new Error(`Keyframe time ${time} exceeds clip length ${clip.length}`);
      }

      clip.tracks[trackIndex].keyframes.push({ time, value, transition });
      clip.tracks[trackIndex].keyframes.sort((a, b) => a.time - b.time);

      await fs.writeFile(fullPath, serializeAnimationClipContent(clip), "utf-8");

      return {
        success: true,
        path: clipPath,
        trackIndex,
        keyframeCount: clip.tracks[trackIndex].keyframes.length,
      };
    },
  });

  tools.set("godot_animation_remove_keyframe", {
    description:
      "Remove a keyframe from an existing animation track by index or time.",
    inputSchema: z.object({
      path: z.string().describe("Path to animation resource"),
      trackIndex: z.number().int().min(0).describe("Track index"),
      keyframeIndex: z.number().int().min(0).optional().describe("Keyframe index to remove"),
      time: z.number().min(0).optional().describe("Keyframe time to remove (nearest match)"),
    }),
    handler: async (args) => {
      const { path: clipPath, trackIndex, keyframeIndex, time } = args as {
        path: string;
        trackIndex: number;
        keyframeIndex?: number;
        time?: number;
      };

      if (keyframeIndex === undefined && time === undefined) {
        throw new Error("Provide either keyframeIndex or time");
      }

      const fullPath = resolveProjectPath(clipPath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const clip = parseAnimationClipContent(content);

      const track = clip.tracks[trackIndex];
      if (!track) {
        throw new Error(`Track index out of range: ${trackIndex}`);
      }

      let removed: AnimationKeyframe | null = null;
      if (keyframeIndex !== undefined) {
        if (!track.keyframes[keyframeIndex]) {
          throw new Error(`Keyframe index out of range: ${keyframeIndex}`);
        }
        removed = track.keyframes.splice(keyframeIndex, 1)[0];
      } else if (time !== undefined) {
        const epsilon = 1e-4;
        const idx = track.keyframes.findIndex((kf) => Math.abs(kf.time - time) <= epsilon);
        if (idx === -1) {
          throw new Error(`No keyframe found near time ${time}`);
        }
        removed = track.keyframes.splice(idx, 1)[0];
      }

      await fs.writeFile(fullPath, serializeAnimationClipContent(clip), "utf-8");

      return {
        success: true,
        path: clipPath,
        trackIndex,
        removed,
        keyframeCount: track.keyframes.length,
      };
    },
  });

  tools.set("godot_animation_list_clips", {
    description:
      "List Animation resources (.tres/.anim) in the project, including basic clip metadata.",
    inputSchema: z.object({
      directory: z
        .string()
        .optional()
        .describe("Optional project subdirectory to search"),
    }),
    handler: async (args) => {
      const { directory } = args as { directory?: string };
      const searchPath = resolveProjectDirectory(directory, state.projectPath);
      const files = await findFiles(searchPath, [".tres", ".anim"]);

      const clips = await Promise.all(
        files.map(async (filePath) => {
          try {
            const content = await fs.readFile(filePath, "utf-8");
            if (!content.includes('[gd_resource type="Animation"')) {
              return null;
            }

            const clip = parseAnimationClipContent(content);
            return {
              path: getProjectRelativePath(filePath, state.projectPath),
              resPath: `res://${getProjectRelativePath(filePath, state.projectPath)}`,
              summary: summarizeClip(clip),
            };
          } catch {
            return null;
          }
        })
      );

      const filtered = clips.filter((clip) => clip !== null);

      return {
        projectPath: state.projectPath,
        directory: directory || ".",
        clips: filtered,
        count: filtered.length,
      };
    },
  });

  tools.set("godot_animation_setup_scene", {
    description:
      "Set up AnimationPlayer and optional AnimationTree nodes in a scene file.",
    inputSchema: z.object({
      scenePath: z.string().describe("Path to scene file to modify"),
      parentPath: z
        .string()
        .optional()
        .default(".")
        .describe("Parent node path for animation nodes (default: root children '.')"),
      playerName: z
        .string()
        .optional()
        .default("AnimationPlayer")
        .describe("AnimationPlayer node name"),
      createTree: z
        .boolean()
        .optional()
        .default(true)
        .describe("Create AnimationTree sibling node"),
      treeName: z
        .string()
        .optional()
        .default("AnimationTree")
        .describe("AnimationTree node name"),
      activeTree: z
        .boolean()
        .optional()
        .default(true)
        .describe("Set AnimationTree active property"),
    }),
    handler: async (args) => {
      const {
        scenePath,
        parentPath,
        playerName,
        createTree,
        treeName,
        activeTree,
      } = args as {
        scenePath: string;
        parentPath: string;
        playerName: string;
        createTree: boolean;
        treeName: string;
        activeTree: boolean;
      };

      const fullPath = resolveProjectPath(scenePath, state.projectPath);
      const content = await fs.readFile(fullPath, "utf-8");
      const scene = TscnParser.parse(content);
      const normalizedParentPath =
        assertSceneParentExists(scene, parentPath) ?? ".";

      const created: string[] = [];
      const updated: string[] = [];

      const playerNodePath = buildSceneNodePath(normalizedParentPath, playerName);
      if (!sceneHasNodePath(scene, playerNodePath)) {
        TscnParser.addNode(scene, {
          name: playerName,
          type: "AnimationPlayer",
          parent: normalizedParentPath,
          properties: {},
        });
        created.push(playerNodePath);
      }

      if (createTree) {
        const treeNodePath = buildSceneNodePath(normalizedParentPath, treeName);
        const treeProperties = {
          active: activeTree,
          anim_player: `NodePath("../${playerName}")`,
        };

        if (!sceneHasNodePath(scene, treeNodePath)) {
          TscnParser.addNode(scene, {
            name: treeName,
            type: "AnimationTree",
            parent: normalizedParentPath,
            properties: treeProperties,
          });
          created.push(treeNodePath);
        } else {
          const changed = TscnParser.modifyNode(scene, treeNodePath, {
            properties: treeProperties,
          });
          if (changed) {
            updated.push(treeNodePath);
          }
        }
      }

      await fs.writeFile(fullPath, TscnParser.serialize(scene), "utf-8");

      return {
        success: true,
        scenePath,
        parentPath: normalizedParentPath,
        created,
        updated,
        animationPlayerPath: playerNodePath,
        animationTreePath: createTree ? buildSceneNodePath(normalizedParentPath, treeName) : null,
      };
    },
  });

  tools.set("godot_animation_build_state_machine_plan", {
    description:
      "Build a state-machine configuration plan and optional script for AnimationTree runtime setup.",
    inputSchema: z.object({
      states: z.array(StateSchema).min(1).describe("State machine states"),
      transitions: z
        .array(TransitionSchema)
        .optional()
        .default([])
        .describe("State transitions"),
      entryState: z
        .string()
        .optional()
        .describe("Optional entry state (defaults to first state)"),
      outputPath: z
        .string()
        .optional()
        .describe("Optional JSON output path for plan artifact"),
    }),
    handler: async (args) => {
      const { states, transitions, entryState, outputPath } = args as {
        states: Array<z.infer<typeof StateSchema>>;
        transitions: Array<z.infer<typeof TransitionSchema>>;
        entryState?: string;
        outputPath?: string;
      };

      const plan = buildStateMachinePlan(states, transitions, entryState);

      if (outputPath) {
        const fullPath = resolveProjectPath(outputPath, state.projectPath);
        await fs.mkdir(path.dirname(fullPath), { recursive: true });
        await fs.writeFile(fullPath, JSON.stringify(plan, null, 2), "utf-8");
      }

      return {
        ...plan,
        savedTo: outputPath || null,
      };
    },
  });

  tools.set("godot_animation_build_blend_space_plan", {
    description:
      "Build a blend-space configuration plan and optional script for AnimationTree setup.",
    inputSchema: z.object({
      blendMode: z
        .enum(["1d", "2d"])
        .default("2d")
        .describe("Blend-space mode"),
      parameter: z
        .string()
        .optional()
        .default("blend_position")
        .describe("Primary parameter name"),
      secondaryParameter: z
        .string()
        .optional()
        .default("blend_position_y")
        .describe("Secondary parameter for 2D blend spaces"),
      points: z.array(BlendPointSchema).min(2).describe("Blend points"),
      outputPath: z
        .string()
        .optional()
        .describe("Optional JSON output path for plan artifact"),
    }),
    handler: async (args) => {
      const {
        blendMode,
        parameter,
        secondaryParameter,
        points,
        outputPath,
      } = args as {
        blendMode: "1d" | "2d";
        parameter: string;
        secondaryParameter: string;
        points: Array<z.infer<typeof BlendPointSchema>>;
        outputPath?: string;
      };

      const plan = buildBlendSpacePlan(
        blendMode,
        parameter,
        secondaryParameter,
        points
      );

      if (outputPath) {
        const fullPath = resolveProjectPath(outputPath, state.projectPath);
        await fs.mkdir(path.dirname(fullPath), { recursive: true });
        await fs.writeFile(fullPath, JSON.stringify(plan, null, 2), "utf-8");
      }

      return {
        ...plan,
        savedTo: outputPath || null,
      };
    },
  });
}

export function buildStateMachinePlan(
  states: AnimationStateDefinition[],
  transitions: AnimationTransitionDefinition[],
  requestedEntryState?: string
): Record<string, unknown> {
  const knownStates = new Set(states.map((state) => state.name));
  const missingTransitions = transitions
    .filter(
      (transition) =>
        !knownStates.has(transition.from) || !knownStates.has(transition.to)
    )
    .map((transition) => `${transition.from}->${transition.to}`);

  const entryState = requestedEntryState || states[0].name;
  if (!knownStates.has(entryState)) {
    throw new Error(`Entry state '${entryState}' is not defined in states list`);
  }

  if (missingTransitions.length > 0) {
    throw new Error(
      `Transitions reference unknown states: ${missingTransitions.join(", ")}`
    );
  }

  const parameters = Array.from(
    new Set(
      transitions
        .map((transition) => transition.condition)
        .filter((condition): condition is string => Boolean(condition))
    )
  );

  return {
    type: "animation_state_machine_plan",
    entryState,
    states,
    transitions,
    requiredClips: states.map((state) => state.animation),
    parameters,
    generatedScript: generateStateMachineScript(entryState, states, transitions),
  };
}

export function buildBlendSpacePlan(
  blendMode: "1d" | "2d",
  parameter: string,
  secondaryParameter: string,
  points: BlendPointDefinition[]
): Record<string, unknown> {
  const requiredClips = points.map((point) => point.animation);
  return {
    type: "animation_blend_space_plan",
    blendMode,
    parameter,
    secondaryParameter: blendMode === "2d" ? secondaryParameter : null,
    points,
    requiredClips,
    generatedScript: generateBlendSpaceScript(
      blendMode,
      parameter,
      secondaryParameter,
      points
    ),
  };
}

function generateStateMachineScript(
  entryState: string,
  states: AnimationStateDefinition[],
  transitions: AnimationTransitionDefinition[]
): string {
  const lines: string[] = [];
  lines.push("# Generated by godot_animation_build_state_machine_plan");
  lines.push("var tree := $AnimationTree");
  lines.push("var root := AnimationNodeStateMachine.new()");
  lines.push('tree.tree_root = root');
  lines.push('tree.active = true');
  lines.push("");

  for (const state of states) {
    const safeState = escapeGdString(state.name);
    const safeAnimation = escapeGdString(state.animation);
    const stateVar = toScriptIdentifier(`state_${state.name}`);

    lines.push(`var ${stateVar} := AnimationNodeAnimation.new()`);
    lines.push(`${stateVar}.animation = &"${safeAnimation}"`);
    lines.push(`root.add_node(&"${safeState}", ${stateVar})`);
    if (state.position && state.position.length === 2) {
      lines.push(
        `root.set_node_position(&"${safeState}", Vector2(${formatNumber(
          state.position[0]
        )}, ${formatNumber(state.position[1])}))`
      );
    }
    lines.push("");
  }

  lines.push(`root.set_start_node(&"${escapeGdString(entryState)}")`);
  lines.push("");

  transitions.forEach((transition, index) => {
    const transitionVar = toScriptIdentifier(
      `transition_${transition.from}_${transition.to}_${index}`
    );
    const safeFrom = escapeGdString(transition.from);
    const safeTo = escapeGdString(transition.to);

    lines.push(`var ${transitionVar} := AnimationNodeStateMachineTransition.new()`);
    lines.push(
      `${transitionVar}.xfade_time = ${formatNumber(transition.xfadeTime ?? 0.15)}`
    );
    if (transition.condition) {
      lines.push(
        `# Optional auto-advance condition: ${transitionVar}.advance_condition = &"${escapeGdString(
          transition.condition
        )}"`
      );
    }
    lines.push(
      `root.add_transition(&"${safeFrom}", &"${safeTo}", ${transitionVar})`
    );
    lines.push("");
  });

  lines.push("var playback := tree.get(\"parameters/playback\")");
  lines.push(
    `if playback is AnimationNodeStateMachinePlayback:\n\tplayback.travel(&"${escapeGdString(
      entryState
    )}")`
  );

  return lines.join("\n");
}

function generateBlendSpaceScript(
  blendMode: "1d" | "2d",
  parameter: string,
  secondaryParameter: string,
  points: BlendPointDefinition[]
): string {
  const lines: string[] = [];
  lines.push("# Generated by godot_animation_build_blend_space_plan");
  lines.push("var tree := $AnimationTree");
  lines.push(
    `var blend := ${
      blendMode === "1d" ? "AnimationNodeBlendSpace1D" : "AnimationNodeBlendSpace2D"
    }.new()`
  );
  lines.push("tree.tree_root = blend");
  lines.push("tree.active = true");
  lines.push("");

  for (const point of points) {
    const pointVar = toScriptIdentifier(`point_${point.animation}`);
    lines.push(`var ${pointVar} := AnimationNodeAnimation.new()`);
    lines.push(`${pointVar}.animation = &"${escapeGdString(point.animation)}"`);
    if (blendMode === "1d") {
      lines.push(
        `blend.add_blend_point(${pointVar}, ${formatNumber(point.position[0])})`
      );
    } else {
      lines.push(
        `blend.add_blend_point(${pointVar}, Vector2(${formatNumber(
          point.position[0]
        )}, ${formatNumber(point.position[1])}))`
      );
    }
    lines.push("");
  }

  lines.push(`# Drive blend with parameters '${parameter}'${
    blendMode === "2d" ? ` and '${secondaryParameter}'` : ""
  }`);
  if (blendMode === "1d") {
    lines.push(`tree.set("parameters/${escapeGdString(parameter)}", 0.0)`);
  } else {
    lines.push(
      `tree.set("parameters/${escapeGdString(parameter)}", Vector2(0.0, 0.0))`
    );
  }

  return lines.join("\n");
}

function toScriptIdentifier(raw: string): string {
  const normalized = raw.replace(/[^a-zA-Z0-9_]/g, "_");
  return /^[a-zA-Z_]/.test(normalized) ? normalized : `v_${normalized}`;
}

function escapeGdString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function normalizeClip(input: {
  length: number;
  loopMode: AnimationClip["loopMode"];
  step: number;
  tracks: Array<z.infer<typeof TrackSchema>>;
}): AnimationClip {
  const tracks: AnimationTrack[] = input.tracks.map((track) => {
    const keyframes = track.keyframes
      .map((keyframe) => ({
        time: keyframe.time,
        value: keyframe.value,
        transition: keyframe.transition ?? 1,
      }))
      .sort((a, b) => a.time - b.time);

    for (const keyframe of keyframes) {
      if (keyframe.time > input.length) {
        throw new Error(`Keyframe time ${keyframe.time} exceeds clip length ${input.length}`);
      }
    }

    return {
      path: track.path,
      interpolation: track.interpolation ?? "linear",
      updateMode: track.updateMode ?? "continuous",
      loopWrap: track.loopWrap ?? true,
      keyframes,
    };
  });

  return {
    length: input.length,
    loopMode: input.loopMode,
    step: input.step,
    tracks,
  };
}

const animationSources = new WeakMap<AnimationClip, string[]>();
const originalTrackKeys = new WeakMap<AnimationTrack, string>();
const originalKeyValues = new WeakMap<AnimationKeyframe, { json: string; literal: string }>();
export function serializeAnimationClipContent(clip: AnimationClip): string {
  const source = animationSources.get(clip);
  if (source) {
    let inResource = false;
    return source.map(statement => {
      if (statement.startsWith("[")) {
        inResource = statement === "[resource]";
        return statement;
      }
      if (!inResource) return statement;
      const match = statement.match(/^tracks\/(\d+)\/keys\s*=/);
      if (!match) return statement;
      const track = clip.tracks[Number(match[1])];
      if (!track) throw new Error("Cannot remove tracks through keyframe editing");
      if (originalTrackKeys.get(track) === JSON.stringify(track.keyframes)) return statement;
      return `tracks/${match[1]}/keys = ${serializeTrackKeys(track)}`;
    }).join("\n") + "\n";
  }
  const lines: string[] = [];

  lines.push('[gd_resource type="Animation" format=3]');
  lines.push("");
  lines.push("[resource]");
  lines.push(`length = ${formatNumber(clip.length)}`);
  lines.push(`loop_mode = ${LOOP_MODE_TO_ID[clip.loopMode]}`);
  lines.push(`step = ${formatNumber(clip.step)}`);

  clip.tracks.forEach((track, index) => {
    lines.push(`tracks/${index}/type = "value"`);
    lines.push(`tracks/${index}/imported = false`);
    lines.push(`tracks/${index}/enabled = true`);
    lines.push(`tracks/${index}/path = NodePath("${escapeString(track.path)}")`);
    lines.push(`tracks/${index}/interp = ${INTERPOLATION_TO_ID[track.interpolation]}`);
    lines.push(`tracks/${index}/loop_wrap = ${track.loopWrap ? "true" : "false"}`);
    lines.push(`tracks/${index}/keys = ${serializeTrackKeys(track)}`);
  });

  return `${lines.join("\n")}\n`;
}

export function parseAnimationClipContent(content: string): AnimationClip {
  const lines = splitGodotStatements(content);
  if (!lines[0]?.match(/^\[gd_resource\s+.*type="Animation"/)) throw new Error("Expected an Animation text resource");

  let length = 1;
  let loopMode: AnimationClip["loopMode"] = "none";
  let step = 1 / 30;

  interface PartialTrack {
    path?: string;
    interpolation?: AnimationTrack["interpolation"];
    updateMode?: AnimationTrack["updateMode"];
    loopWrap?: boolean;
    keyframes?: AnimationKeyframe[];
  }

  const partialTracks: Map<number, PartialTrack> = new Map();

  let inResource = false;
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line.startsWith("[")) { inResource = line === "[resource]"; continue; }
    if (!inResource) continue;

    if (line.startsWith("length =")) {
      length = parseFloatSafe(line.slice("length =".length).trim(), 1);
      continue;
    }
    if (line.startsWith("loop_mode =")) {
      const loopModeId = parseIntSafe(line.slice("loop_mode =".length).trim(), 0);
      loopMode = LOOP_MODE_FROM_ID[loopModeId] || "none";
      continue;
    }
    if (line.startsWith("step =")) {
      step = parseFloatSafe(line.slice("step =".length).trim(), 1 / 30);
      continue;
    }

    const typeMatch = line.match(/^tracks\/(\d+)\/type\s*=\s*"([^"]+)"$/);
    if (typeMatch) {
      if (typeMatch[2] !== "value") throw new Error(`Unsupported animation track type: ${typeMatch[2]}`);
      const index = parseIntSafe(typeMatch[1], 0);
      if (!partialTracks.has(index)) partialTracks.set(index, {});
      continue;
    }

    const pathMatch = line.match(/^tracks\/(\d+)\/path\s*=\s*NodePath\("([^"]*)"\)$/);
    if (pathMatch) {
      const index = parseIntSafe(pathMatch[1], 0);
      const track = partialTracks.get(index) || {};
      track.path = pathMatch[2];
      partialTracks.set(index, track);
      continue;
    }

    const interpMatch = line.match(/^tracks\/(\d+)\/interp\s*=\s*(\d+)$/);
    if (interpMatch) {
      const index = parseIntSafe(interpMatch[1], 0);
      const track = partialTracks.get(index) || {};
      track.interpolation =
        INTERPOLATION_FROM_ID[parseIntSafe(interpMatch[2], 1)] || "linear";
      partialTracks.set(index, track);
      continue;
    }

    const loopWrapMatch = line.match(/^tracks\/(\d+)\/loop_wrap\s*=\s*(true|false)$/);
    if (loopWrapMatch) {
      const index = parseIntSafe(loopWrapMatch[1], 0);
      const track = partialTracks.get(index) || {};
      track.loopWrap = loopWrapMatch[2] === "true";
      partialTracks.set(index, track);
      continue;
    }

    const keysMatch = line.match(/^tracks\/(\d+)\/keys\s*=\s*(\{[\s\S]*\})$/);
    if (keysMatch) {
      const index = parseIntSafe(keysMatch[1], 0);
      const track = partialTracks.get(index) || {};
      const parsed = parseTrackKeys(keysMatch[2]);
      track.keyframes = parsed.keyframes;
      track.updateMode = parsed.updateMode;
      partialTracks.set(index, track);
    }
  }

  if ([...partialTracks.keys()].some((key, index) => key !== index)) throw new Error("Unsupported noncontiguous animation tracks");
  const tracks = Array.from(partialTracks.entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, track]) => ({
      path: track.path || ".:property",
      interpolation: track.interpolation || "linear",
      updateMode: track.updateMode || "continuous",
      loopWrap: track.loopWrap ?? true,
      keyframes: track.keyframes ?? (() => { throw new Error("Missing or unsupported animation keys"); })(),
    }));

  const clip = { length, loopMode, step, tracks };
  animationSources.set(clip, lines);
  for (const track of tracks) originalTrackKeys.set(track, JSON.stringify(track.keyframes));
  return clip;
}

function parseTrackKeys(keysLiteral: string): {
  keyframes: AnimationKeyframe[];
  updateMode: AnimationTrack["updateMode"];
} {
  const fields = parseDictionary(keysLiteral);
  if (Object.keys(fields).some(key => !["times", "transitions", "update", "values"].includes(key))) throw new Error("Unsupported animation key dictionary fields");
  const timesMatch = keysLiteral.match(/"times"\s*:\s*PackedFloat32Array\(([^)]*)\)/);
  const transitionsMatch = keysLiteral.match(
    /"transitions"\s*:\s*PackedFloat32Array\(([^)]*)\)/
  );
  const updateMatch = keysLiteral.match(/"update"\s*:\s*(\d+)/);
  const valuesMatch = keysLiteral.match(/"values"\s*:\s*\[([\s\S]*)]\s*}/);

  const times = parsePackedFloatArray(timesMatch?.[1]);
  const transitions = parsePackedFloatArray(transitionsMatch?.[1]);
  const updateMode =
    UPDATE_MODE_FROM_ID[parseIntSafe(updateMatch?.[1], 0)] || "continuous";

  const valueLiterals = valuesMatch ? splitTopLevel(valuesMatch[1], ",") : [];
  const values = valueLiterals.map(part => parseVariant(part.trim()));
  if (updateMatch && !(Number(updateMatch[1]) in UPDATE_MODE_FROM_ID)) throw new Error("Unsupported animation update mode");

  if (!timesMatch || !valuesMatch || times.length !== values.length || (transitionsMatch && transitions.length !== times.length)) throw new Error("Unsupported or inconsistent animation keys");
  const length = times.length;
  const keyframes: AnimationKeyframe[] = [];
  for (let i = 0; i < length; i++) {
    const keyframe = { time: times[i], value: values[i], transition: transitions[i] ?? 1 };
    keyframes.push(keyframe);
    originalKeyValues.set(keyframe, { json: JSON.stringify(values[i]), literal: valueLiterals[i] });
  }

  return { keyframes, updateMode };
}

function parsePackedFloatArray(raw: string | undefined): number[] {
  if (!raw) return [];

  const trimmed = raw.trim();
  if (!trimmed) return [];

  return trimmed
    .split(",")
    .map((value) => parseFloatSafe(value.trim(), NaN))
    .filter((value) => Number.isFinite(value));
}

function serializeTrackKeys(track: AnimationTrack): string {
  const times = track.keyframes.map((keyframe) => formatNumber(keyframe.time));
  const transitions = track.keyframes.map((keyframe) => formatNumber(keyframe.transition));
  const values = track.keyframes.map((keyframe) => {
    const original = originalKeyValues.get(keyframe);
    return original?.json === JSON.stringify(keyframe.value) ? original.literal : serializeVariant(keyframe.value);
  });

  return `{"times": PackedFloat32Array(${times.join(", ")}), "transitions": PackedFloat32Array(${transitions.join(", ")}), "update": ${
    UPDATE_MODE_TO_ID[track.updateMode]
  }, "values": [${values.join(", ")}]} `;
}

function serializeVariant(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return formatNumber(value);

  if (typeof value === "string") {
    return `"${escapeString(value)}"`;
  }

  if (Array.isArray(value)) {
    return `[${value.map((item) => serializeVariant(item)).join(", ")}]`;
  }

  if (typeof value === "object" && value !== null) {
    const obj = value as Record<string, unknown>;
    if (obj._type === "Raw") return TscnParser.serializeValue(obj);

    if (obj._type === "Vector2") {
      return `Vector2(${formatNumber(Number(obj.x ?? 0))}, ${formatNumber(Number(obj.y ?? 0))})`;
    }
    if (obj._type === "Vector3") {
      return `Vector3(${formatNumber(Number(obj.x ?? 0))}, ${formatNumber(Number(obj.y ?? 0))}, ${formatNumber(Number(obj.z ?? 0))})`;
    }
    if (obj._type === "Color") {
      const alpha = obj.a === undefined ? 1 : Number(obj.a);
      return `Color(${formatNumber(Number(obj.r ?? 0))}, ${formatNumber(Number(obj.g ?? 0))}, ${formatNumber(Number(obj.b ?? 0))}, ${formatNumber(alpha)})`;
    }
    if (obj._type === "NodePath") {
      return `NodePath("${escapeString(String(obj.path ?? ""))}")`;
    }

    const dictionary = Object.entries(obj)
      .map(([key, entryValue]) => `"${escapeString(key)}": ${serializeVariant(entryValue)}`)
      .join(", ");
    return `{${dictionary}}`;
  }

  return `"${escapeString(String(value))}"`;
}

function parseVariant(raw: string): unknown {
  const value = raw.trim();

  if (value === "null") return null;
  if (value === "true") return true;
  if (value === "false") return false;
  if (/^-?\d+$/.test(value)) return parseInt(value, 10);
  if (/^-?\d+\.\d+$/.test(value)) return parseFloat(value);

  if (value.startsWith('"') && value.endsWith('"')) {
    return TscnParser.parseValue(value);
  }

  if (value.startsWith("Vector2(")) {
    const params = splitTopLevel(value.slice(8, -1), ",");
    return {
      _type: "Vector2",
      x: parseFloatSafe(params[0], 0),
      y: parseFloatSafe(params[1], 0),
    };
  }

  if (value.startsWith("Vector3(")) {
    const params = splitTopLevel(value.slice(8, -1), ",");
    return {
      _type: "Vector3",
      x: parseFloatSafe(params[0], 0),
      y: parseFloatSafe(params[1], 0),
      z: parseFloatSafe(params[2], 0),
    };
  }

  if (value.startsWith("Color(")) {
    const params = splitTopLevel(value.slice(6, -1), ",");
    return {
      _type: "Color",
      r: parseFloatSafe(params[0], 0),
      g: parseFloatSafe(params[1], 0),
      b: parseFloatSafe(params[2], 0),
      a: parseFloatSafe(params[3], 1),
    };
  }

  if (value.startsWith("NodePath(")) {
    const inner = value.slice(9, -1).trim();
    const parsed = parseVariant(inner);
    return {
      _type: "NodePath",
      path: typeof parsed === "string" ? parsed : String(parsed),
    };
  }

  if (value.startsWith("[") && value.endsWith("]")) {
    const inner = value.slice(1, -1).trim();
    if (!inner) return [];
    return splitTopLevel(inner, ",").map((part) => parseVariant(part));
  }

  if (value.startsWith("{") && value.endsWith("}")) {
    return { _type: "Raw", value };
  }

  return { _type: "Raw", value };
}

function parseDictionary(raw: string): Record<string, unknown> {
  const inner = raw.slice(1, -1).trim();
  if (!inner) return {};

  const entries = splitTopLevel(inner, ",");
  const result: Record<string, unknown> = {};

  for (const entry of entries) {
    const colonIndex = findTopLevelSeparator(entry, ":");
    if (colonIndex === -1) {
      continue;
    }

    const keyPart = entry.slice(0, colonIndex).trim();
    const valuePart = entry.slice(colonIndex + 1).trim();
    const parsedKey = parseVariant(keyPart);
    result[String(parsedKey)] = parseVariant(valuePart);
  }

  return result;
}

function splitTopLevel(value: string, separator: string): string[] {
  return splitGodotList(value, separator);
}

function findTopLevelSeparator(value: string, separator: string): number {
  let parenDepth = 0;
  let bracketDepth = 0;
  let braceDepth = 0;
  let inString = false;

  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    const previous = value[i - 1];

    if (char === '"' && previous !== "\\") {
      inString = !inString;
    }

    if (!inString) {
      if (char === "(") parenDepth++;
      if (char === ")") parenDepth--;
      if (char === "[") bracketDepth++;
      if (char === "]") bracketDepth--;
      if (char === "{") braceDepth++;
      if (char === "}") braceDepth--;

      if (
        char === separator &&
        parenDepth === 0 &&
        bracketDepth === 0 &&
        braceDepth === 0
      ) {
        return i;
      }
    }
  }

  return -1;
}

function isGodotLiteral(value: string): boolean {
  const patterns = [
    /^Vector2\(/,
    /^Vector3\(/,
    /^Color\(/,
    /^NodePath\(/,
    /^Rect2\(/,
    /^Transform2D\(/,
    /^Transform3D\(/,
    /^Basis\(/,
    /^Quaternion\(/,
    /^AABB\(/,
    /^Plane\(/,
  ];
  return patterns.some((pattern) => pattern.test(value));
}

function summarizeClip(clip: AnimationClip): Record<string, unknown> {
  const keyframeCount = clip.tracks.reduce(
    (acc, track) => acc + track.keyframes.length,
    0
  );

  return {
    length: clip.length,
    loopMode: clip.loopMode,
    step: clip.step,
    trackCount: clip.tracks.length,
    keyframeCount,
  };
}

function escapeString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function unescapeString(value: string): string {
  return value
    .replace(/\\n/g, "\n")
    .replace(/\\r/g, "\r")
    .replace(/\\t/g, "\t")
    .replace(/\\"/g, '"')
    .replace(/\\\\/g, "\\");
}

function parseIntSafe(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseFloatSafe(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const parsed = parseFloat(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function formatNumber(value: number): string {
  if (Number.isInteger(value)) {
    return String(value);
  }

  return String(value);
}

async function findFiles(dir: string, extensions: string[]): Promise<string[]> {
  const results: string[] = [];

  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory() && !entry.name.startsWith(".")) {
        results.push(...(await findFiles(fullPath, extensions)));
      } else if (
        entry.isFile() &&
        extensions.some((extension) => entry.name.endsWith(extension))
      ) {
        results.push(fullPath);
      }
    }
  } catch {
    // Directory does not exist or cannot be read.
  }

  return results;
}
