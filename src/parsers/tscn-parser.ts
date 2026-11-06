import { splitGodotStatements, splitGodotList } from "./godot-text.js";

/**
 * TSCN (Text Scene) Parser for Godot 4.x
 *
 * Parses and serializes Godot's text-based scene format.
 * Reference: https://docs.godotengine.org/en/stable/contributing/development/file_formats/tscn.html
 */

export interface SceneHeader {
  attributes?: Record<string, string>;
  type: "gd_scene" | "gd_resource";
  loadSteps?: number;
  format: number;
  uid?: string;
}

export interface ExternalResource {
  attributes?: Record<string, string>;
  type: string;
  path: string;
  id: string;
  uid?: string;
}

export interface SubResource {
  attributes?: Record<string, string>;
  literals?: Record<string, { json: string; text: string }>;
  type: string;
  id: string;
  properties: Record<string, unknown>;
}

export interface SceneNode {
  attributes?: Record<string, string>;
  literals?: Record<string, { json: string; text: string }>;
  name: string;
  type?: string;
  parent?: string;
  instance?: string;
  instancePlaceholder?: string;
  owner?: string;
  index?: number;
  groups?: string[];
  properties: Record<string, unknown>;
}

export interface SignalConnection {
  attributes?: Record<string, string>;
  signal: string;
  from: string;
  to: string;
  method: string;
  flags?: number;
  binds?: unknown[];
}

export interface ParsedScene {
  extraSections?: string[];
  header: SceneHeader;
  externalResources: ExternalResource[];
  subResources: SubResource[];
  nodes: SceneNode[];
  connections: SignalConnection[];
}

export class TscnParser {
  /**
   * Parse a TSCN file content into structured data
   */
  static parse(content: string): ParsedScene {
    const lines = splitGodotStatements(content);
    let index = 0;
    if (!/^\[gd_(scene|resource)(?:\s|\])/.test(lines[0] || "")) throw new Error("Expected a Godot scene/resource header");

    const result: ParsedScene = {
      header: { type: "gd_scene", format: 3 },
      externalResources: [],
      subResources: [],
      nodes: [],
      connections: [],
      extraSections: [],
    };

    while (index < lines.length) {
      const line = lines[index].trim();

      if (line.startsWith("[gd_scene") || line.startsWith("[gd_resource")) {
        result.header = this.parseHeader(line);
        index++;
      } else if (line.startsWith("[ext_resource")) {
        result.externalResources.push(this.parseExtResource(line));
        index++;
      } else if (line.startsWith("[sub_resource")) {
        const { subResource, newIndex } = this.parseSubResource(lines, index);
        result.subResources.push(subResource);
        index = newIndex;
      } else if (line.startsWith("[node")) {
        const { node, newIndex } = this.parseNode(lines, index);
        result.nodes.push(node);
        index = newIndex;
      } else if (line.startsWith("[connection")) {
        result.connections.push(this.parseConnection(line));
        index++;
      } else if (line.startsWith("[")) {
        if (!/^\[editable(?:\s|\])/.test(line) && !(result.header.type === "gd_resource" && line === "[resource]")) throw new Error(`Unsupported Godot section: ${line}`);
        const section = [line];
        index++;
        while (index < lines.length && !lines[index].startsWith("[")) section.push(lines[index++]);
        result.extraSections!.push(section.join("\n"));
      } else {
        throw new Error(`Unexpected Godot statement: ${line.slice(0, 80)}`);
      }
    }

    return result;
  }

  /**
   * Serialize structured scene data back to TSCN format
   */
  static serialize(scene: ParsedScene): string {
    const lines: string[] = [];

    // Header
    lines.push(this.serializeHeader(scene.header));
    lines.push("");

    // External resources
    for (const extRes of scene.externalResources) {
      lines.push(this.serializeExtResource(extRes));
    }
    if (scene.externalResources.length > 0) {
      lines.push("");
    }

    // Sub-resources
    for (const subRes of scene.subResources) {
      lines.push(...this.serializeSubResource(subRes));
      lines.push("");
    }

    // Nodes
    for (const node of scene.nodes) {
      lines.push(...this.serializeNode(node));
      lines.push("");
    }

    // Connections
    for (const connection of scene.connections) {
      lines.push(this.serializeConnection(connection));
    }

    lines.push(...(scene.extraSections || []));
    return lines.join("\n").trim() + "\n";
  }

  // Header parsing
  private static parseHeader(line: string): SceneHeader {
    const type = line.startsWith("[gd_scene") ? "gd_scene" : "gd_resource";
    const attrs = this.parseAttributes(line);

    return {
      type,
      attributes: this.parseAttributes(line, false),
      loadSteps: attrs.load_steps ? parseInt(attrs.load_steps, 10) : undefined,
      format: attrs.format ? parseInt(attrs.format, 10) : 3,
      uid: attrs.uid,
    };
  }

  private static serializeHeader(header: SceneHeader): string {
    const parts = [`[${header.type}`];

    if (header.loadSteps) {
      parts.push(`load_steps=${header.loadSteps}`);
    }
    parts.push(`format=${header.format}`);
    if (header.uid) {
      parts.push(`uid="${this.escapeText(String(header.uid))}"`);
    }

    return parts.join(" ") + this.extraAttributes(header.attributes, ["load_steps", "format", "uid"]) + "]";
  }

  // External resource parsing
  private static parseExtResource(line: string): ExternalResource {
    const attrs = this.parseAttributes(line);
    return {
      attributes: this.unknownAttributes(attrs, ["type", "path", "id", "uid"]),
      type: attrs.type || "",
      path: attrs.path || "",
      id: attrs.id || "",
      uid: attrs.uid,
    };
  }

  private static serializeExtResource(res: ExternalResource): string {
    let result = `[ext_resource type="${this.escapeText(String(res.type))}" path="${this.escapeText(String(res.path))}"`;
    if (res.uid) {
      result += ` uid="${this.escapeText(String(res.uid))}"`;
    }
    result += ` id="${this.escapeText(String(res.id))}"${this.extraAttributes(res.attributes, ["type", "path", "uid", "id"])}]`;
    return result;
  }

  // Sub-resource parsing
  private static parseSubResource(
    lines: string[],
    startIndex: number
  ): { subResource: SubResource; newIndex: number } {
    const headerLine = lines[startIndex].trim();
    const attrs = this.parseAttributes(headerLine);

    const subResource: SubResource = {
      attributes: attrs,
      type: attrs.type || "",
      id: attrs.id || "",
      properties: {},
      literals: {},
    };

    let index = startIndex + 1;
    while (index < lines.length) {
      const line = lines[index].trim();

      if (line === "" || line.startsWith("[")) {
        break;
      }

      const { key, value } = this.parseProperty(line);
      if (key) {
        subResource.properties[key] = value;
        subResource.literals![key] = { json: JSON.stringify(value), text: line.slice(line.indexOf("=") + 1).trim() };
      }
      index++;
    }

    return { subResource, newIndex: index };
  }

  private static serializeSubResource(res: SubResource): string[] {
    const lines: string[] = [];
    lines.push(`[sub_resource type="${this.escapeText(String(res.type))}" id="${this.escapeText(String(res.id))}"${this.extraAttributes(res.attributes, ["type", "id"])}]`);

    for (const [key, value] of Object.entries(res.properties)) {
      lines.push(`${key} = ${this.preservedValue(value, res.literals?.[key])}`);
    }

    return lines;
  }

  // Node parsing
  private static parseNode(
    lines: string[],
    startIndex: number
  ): { node: SceneNode; newIndex: number } {
    const headerLine = lines[startIndex].trim();
    const attrs = this.parseAttributes(headerLine);

    const node: SceneNode = {
      attributes: attrs,
      name: attrs.name || "",
      type: attrs.type,
      parent: attrs.parent,
      instance: attrs.instance,
      instancePlaceholder: attrs.instance_placeholder,
      owner: attrs.owner,
      index: attrs.index ? parseInt(attrs.index, 10) : undefined,
      groups: attrs.groups ? this.parseArray(attrs.groups) as string[] : undefined,
      properties: {},
      literals: {},
    };

    let index = startIndex + 1;
    while (index < lines.length) {
      const line = lines[index].trim();

      if (line === "" || line.startsWith("[")) {
        break;
      }

      const { key, value } = this.parseProperty(line);
      if (key) {
        node.properties[key] = value;
        node.literals![key] = { json: JSON.stringify(value), text: line.slice(line.indexOf("=") + 1).trim() };
      }
      index++;
    }

    return { node, newIndex: index };
  }

  private static serializeNode(node: SceneNode): string[] {
    const lines: string[] = [];

    let header = `[node name="${this.escapeText(String(node.name))}"`;

    if (node.type) {
      header += ` type="${this.escapeText(String(node.type))}"`;
    }
    if (node.parent !== undefined) {
      header += ` parent="${this.escapeText(String(node.parent))}"`;
    }
    if (node.instance) {
      header += ` instance=${node.instance}`;
    }
    if (node.instancePlaceholder) {
      header += ` instance_placeholder="${this.escapeText(String(node.instancePlaceholder))}"`;
    }
    if (node.owner) {
      header += ` owner="${this.escapeText(String(node.owner))}"`;
    }
    if (node.index !== undefined) {
      header += ` index=${node.index}`;
    }
    if (node.groups && node.groups.length > 0) {
      header += ` groups=${this.serializeValue(node.groups, false, false)}`;
    }

    header += this.extraAttributes(node.attributes, ["name", "type", "parent", "instance", "instance_placeholder", "owner", "index", "groups"]) + "]";
    lines.push(header);

    for (const [key, value] of Object.entries(node.properties)) {
      lines.push(`${key} = ${this.preservedValue(value, node.literals?.[key])}`);
    }

    return lines;
  }

  // Connection parsing
  private static parseConnection(line: string): SignalConnection {
    const attrs = this.parseAttributes(line);
    return {
      attributes: this.unknownAttributes(attrs, ["signal", "from", "to", "method", "flags", "binds"]),
      signal: attrs.signal || "",
      from: attrs.from || "",
      to: attrs.to || "",
      method: attrs.method || "",
      flags: attrs.flags ? parseInt(attrs.flags, 10) : undefined,
      binds: attrs.binds ? this.parseArray(attrs.binds) : undefined,
    };
  }

  private static serializeConnection(conn: SignalConnection): string {
    let result = `[connection signal="${this.escapeText(String(conn.signal))}" from="${this.escapeText(String(conn.from))}" to="${this.escapeText(String(conn.to))}" method="${this.escapeText(String(conn.method))}"`;

    if (conn.flags !== undefined) {
      result += ` flags=${conn.flags}`;
    }
    if (conn.binds && conn.binds.length > 0) {
      result += ` binds=${this.serializeValue(conn.binds, false, false)}`;
    }

    result += this.extraAttributes(conn.attributes, ["signal", "from", "to", "method", "flags", "binds"]) + "]";
    return result;
  }

  // Utility methods
  private static escapeText(text: string): string {
    return text.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t");
  }

  private static extraAttributes(attrs: Record<string, string> | undefined, known: string[]): string {
    return Object.entries(attrs || {}).filter(([key]) => !known.includes(key))
      .map(([key, value]) => ` ${key}=${value}`).join("");
  }

  private static preservedValue(value: unknown, original?: { json: string; text: string }): string {
    return original?.json === JSON.stringify(value) ? original.text : this.serializeValue(value, !original, !original);
  }

  private static unknownAttributes(attrs: Record<string, string>, known: string[]): Record<string, string> | undefined {
    const remaining = Object.fromEntries(Object.entries(attrs).filter(([key]) => !known.includes(key)));
    return Object.keys(remaining).length ? remaining : undefined;
  }

  private static parseAttributes(line: string, decode = true): Record<string, string> {
    const attrs: Record<string, string> = {};
    const body = line.slice(1, -1).replace(/^\S+\s*/, "");
    const tokens: string[] = [];
    let token = "", depth = 0, quoted = false, escaped = false;
    for (const char of body) {
      if (quoted) { token += char; if (escaped) escaped = false; else if (char === "\\") escaped = true; else if (char === '"') quoted = false; continue; }
      if (char === '"') quoted = true;
      if ("([{".includes(char)) depth++;
      if (")]}".includes(char)) depth--;
      if (/\s/.test(char) && !quoted && !depth) { if (token) tokens.push(token); token = ""; } else token += char;
    }
    if (token) tokens.push(token);
    for (const token of tokens) {
      const match = token.match(/^(\w+)=([\s\S]+)$/);
      if (!match) throw new Error(`Unsupported section attribute: ${token}`);
      attrs[match[1]] = match[2];
    }
    if (decode) for (const key of ["name", "type", "parent", "instance_placeholder", "owner", "path", "id", "uid", "signal", "from", "to", "method"]) {
      if (attrs[key]?.startsWith('"')) attrs[key] = this.parseValue(attrs[key]) as string;
    }
    return attrs;
  }

  private static parseProperty(line: string): { key: string; value: unknown } {
    const eqIndex = line.indexOf("=");
    if (eqIndex === -1) {
      throw new Error(`Invalid Godot property: ${line.slice(0, 80)}`);
    }

    const key = line.substring(0, eqIndex).trim();
    const valueStr = line.substring(eqIndex + 1).trim();

    return { key, value: this.parseValue(valueStr) };
  }

  static parseValue(str: string): unknown {
    str = str.trim();

    // Null
    if (str === "null") return null;

    // Boolean
    if (str === "true") return true;
    if (str === "false") return false;

    // String
    if (str.startsWith('"') && str.endsWith('"')) {
      return str.slice(1, -1).replace(/\\([\\"nrtbf])/g, (_, c: string) => ({ n: "\n", r: "\r", t: "\t", b: "\b", f: "\f" }[c] ?? c));
    }

    // Number
    if (/^-?\d+$/.test(str)) {
      return parseInt(str, 10);
    }
    if (/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(str)) {
      return parseFloat(str);
    }

    // Vector2
    if (str.startsWith("Vector2(")) {
      const inner = str.slice(8, -1);
      const [x, y] = inner.split(",").map((s) => parseFloat(s.trim()));
      return { _type: "Vector2", x, y };
    }

    // Vector3
    if (str.startsWith("Vector3(")) {
      const inner = str.slice(8, -1);
      const [x, y, z] = inner.split(",").map((s) => parseFloat(s.trim()));
      return { _type: "Vector3", x, y, z };
    }

    // Color
    if (str.startsWith("Color(")) {
      const inner = str.slice(6, -1);
      const [r, g, b, a] = inner.split(",").map((s) => parseFloat(s.trim()));
      return { _type: "Color", r, g, b, a: a ?? 1.0 };
    }

    // ExtResource reference
    if (str.startsWith("ExtResource(")) {
      const id = this.parseValue(str.slice(12, -1)) as string;
      return { _type: "ExtResource", id };
    }

    // SubResource reference
    if (str.startsWith("SubResource(")) {
      const id = this.parseValue(str.slice(12, -1)) as string;
      return { _type: "SubResource", id };
    }

    // NodePath
    if (str.startsWith("NodePath(")) {
      const path = this.parseValue(str.slice(9, -1)) as string;
      return { _type: "NodePath", path };
    }

    // Array
    if (str.startsWith("[")) {
      return this.parseArray(str);
    }

    // Dictionary
    if (str.startsWith("{")) {
      return this.parseDictionary(str);
    }

    // Return as string if unknown
    return { _type: "Raw", value: str };
  }

  private static parseArray(str: string): unknown[] {
    if (!str.startsWith("[") || !str.endsWith("]")) throw new Error("Incomplete Godot array");
    return splitGodotList(str.slice(1, -1)).map(value => this.parseValue(value));
  }

  private static parseDictionary(str: string): Record<string, unknown> {
    if (!str.startsWith("{") || !str.endsWith("}")) throw new Error("Incomplete Godot dictionary");
    const result: Record<string, unknown> = Object.create(null);
    for (const pair of splitGodotList(str.slice(1, -1))) {
      const parts = splitGodotList(pair, ":");
      if (parts.length !== 2) throw new Error("Unsupported Godot dictionary entry");
      const key = this.parseValue(parts[0]);
      // Godot supports arbitrary Variant keys; preserve those as literals instead
      // of coercing keys into JS strings or losing the resource-reference type.
      if (typeof key !== "string" || key === "_type") return { _type: "Raw", value: str };
      result[key] = this.parseValue(parts[1]);
    }
    return result;
  }

  static serializeValue(value: unknown, literalStrings = true, autoDetect = true): string {
    if (value === null) return "null";
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "number") return String(value);
    if (typeof value === "string") {
      // Check if it's already a Godot value format (ExtResource, Vector2, etc.)
      if (literalStrings && this.isGodotValueString(value)) {
        return value;
      }
      return `"${this.escapeText(value)}"`;
    }

    if (Array.isArray(value)) {
      const items = value.map((v) => this.serializeValue(v, literalStrings, autoDetect));
      return `[${items.join(", ")}]`;
    }

    if (typeof value === "object" && value !== null) {
      const obj = value as Record<string, unknown>;

      if (obj._type === "Raw" && typeof obj.value === "string") {
        if (splitGodotStatements(obj.value).length !== 1) throw new Error("Expected one Godot Variant literal");
        return obj.value;
      }

      // Special types with explicit _type
      if (obj._type === "Vector2") {
        return `Vector2(${obj.x}, ${obj.y})`;
      }
      if (obj._type === "Vector3") {
        return `Vector3(${obj.x}, ${obj.y}, ${obj.z})`;
      }
      if (obj._type === "Color") {
        return `Color(${obj.r}, ${obj.g}, ${obj.b}, ${obj.a})`;
      }
      if (obj._type === "ExtResource") {
        return `ExtResource("${this.escapeText(String(obj.id))}")`;
      }
      if (obj._type === "SubResource") {
        return `SubResource("${this.escapeText(String(obj.id))}")`;
      }
      if (obj._type === "NodePath") {
        return `NodePath("${this.escapeText(String(obj.path))}")`;
      }

      // Auto-detect Vector2 (has x, y, no z, no _type)
      const keys = Object.keys(obj);
      if (autoDetect && keys.length === 2 && 'x' in obj && 'y' in obj && typeof obj.x === 'number' && typeof obj.y === 'number') {
        return `Vector2(${obj.x}, ${obj.y})`;
      }

      // Auto-detect Vector3 (has x, y, z, no _type)
      if (autoDetect && keys.length === 3 && 'x' in obj && 'y' in obj && 'z' in obj &&
          typeof obj.x === 'number' && typeof obj.y === 'number' && typeof obj.z === 'number') {
        return `Vector3(${obj.x}, ${obj.y}, ${obj.z})`;
      }

      // Auto-detect Color (has r, g, b, optionally a)
      if (autoDetect && ('r' in obj && 'g' in obj && 'b' in obj) &&
          typeof obj.r === 'number' && typeof obj.g === 'number' && typeof obj.b === 'number') {
        const a = typeof obj.a === 'number' ? obj.a : 1.0;
        return `Color(${obj.r}, ${obj.g}, ${obj.b}, ${a})`;
      }

      // Regular dictionary (filter out internal _type if present)
      const pairs = Object.entries(obj)
        .map(([k, v]) => `${this.serializeValue(k, false, false)}: ${this.serializeValue(v, literalStrings, autoDetect)}`);
      return `{${pairs.join(", ")}}`;
    }

    return String(value);
  }

  /**
   * Check if a string is already in Godot value format
   */
  private static isGodotValueString(str: string): boolean {
    const patterns = [
      /^ExtResource\s*\(/,
      /^SubResource\s*\(/,
      /^Vector2\s*\(/,
      /^Vector3\s*\(/,
      /^Color\s*\(/,
      /^NodePath\s*\(/,
      /^Rect2\s*\(/,
      /^Transform2D\s*\(/,
      /^Transform3D\s*\(/,
      /^Basis\s*\(/,
      /^Quaternion\s*\(/,
      /^AABB\s*\(/,
      /^Plane\s*\(/,
    ];
    return patterns.some(pattern => pattern.test(str));
  }

  /**
   * Add a node to a parsed scene
   */
  static addNode(
    scene: ParsedScene,
    node: Omit<SceneNode, "properties"> & { properties?: Record<string, unknown> }
  ): void {
    if (node.parent === undefined && scene.nodes.some(existing => existing.parent === undefined)) throw new Error("Scene already has a root node; specify a parent");
    scene.nodes.push({
      ...node,
      properties: node.properties || {},
    });

    // Update load_steps in header
    this.updateLoadSteps(scene);
  }

  /**
   * Remove a node from a parsed scene (and its children)
   */
  static removeNode(scene: ParsedScene, nodePath: string): void {
    const removingRoot = scene.nodes.some(node => node.parent === undefined && node.name === nodePath);
    if (removingRoot) { scene.nodes = []; scene.connections = []; scene.extraSections = []; this.updateLoadSteps(scene); return; }
    // Build the full path for the node
    const getNodePath = (node: SceneNode): string => {
      if (!node.parent) return node.name;
      if (node.parent === ".") return node.name;
      return `${node.parent}/${node.name}`;
    };

    // Find nodes to remove (the node and all children)
    const pathsToRemove = new Set<string>();
    pathsToRemove.add(nodePath);

    // Find children
    for (const node of scene.nodes) {
      const path = getNodePath(node);
      if (path.startsWith(nodePath + "/")) {
        pathsToRemove.add(path);
      }
    }

    // Remove nodes
    scene.nodes = scene.nodes.filter((node) => {
      const path = getNodePath(node);
      return !pathsToRemove.has(path);
    });

    // Remove connections involving removed nodes
    scene.connections = scene.connections.filter(
      (conn) => !pathsToRemove.has(conn.from) && !pathsToRemove.has(conn.to)
    );

    this.updateLoadSteps(scene);
  }

  /**
   * Modify a node's properties
   */
  static modifyNode(
    scene: ParsedScene,
    nodePath: string,
    updates: Partial<SceneNode>
  ): boolean {
    const getNodePath = (node: SceneNode): string => {
      if (!node.parent) return node.name;
      if (node.parent === ".") return node.name;
      return `${node.parent}/${node.name}`;
    };

    const node = scene.nodes.find((n) => getNodePath(n) === nodePath);
    if (!node) return false;

    if (updates.name !== undefined && updates.name !== node.name) {
      const newName = updates.name;
      if (!newName || /[\/.:@"\n]/.test(newName)) throw new Error("Invalid node name");
      const newPath = node.parent && node.parent !== "." ? `${node.parent}/${newName}` : newName;
      if (scene.nodes.some(n => n !== node && getNodePath(n) === newPath)) throw new Error(`Node already exists: ${newPath}`);
      const isRoot = node.parent === undefined;
      const replacePath = (value: string): string => !isRoot && (value === nodePath || value.startsWith(nodePath + "/")) ? newPath + value.slice(nodePath.length) : value;
      // NodePaths can be relative to their containing node. Resolve to root-relative
      // coordinates, remap the renamed subtree, then restore the relative path.
      const rewriteValue = (value: unknown, context: string): unknown => {
        if (!value || typeof value !== "object") return value;
        if (Array.isArray(value)) return value.map(v => rewriteValue(v, context));
        const obj = value as Record<string, unknown>;
        if (obj._type === "NodePath" && typeof obj.path === "string") {
          // Empty paths mean no target; subname-only paths refer to this node.
          if (!obj.path || obj.path.startsWith(":")) return value;
          if (obj.path.startsWith("/")) throw new Error("Cannot safely rename a scene containing absolute NodePaths");
          const [target, ...subnames] = obj.path.split(":");
          const resolve = (base: string, relative: string) => { const parts = base ? base.split("/") : []; for (const part of relative.split("/")) { if (part === "..") { if (!parts.length) throw new Error("Cannot safely rename a NodePath outside this scene"); parts.pop(); } else if (part && part !== ".") parts.push(part); } return parts.join("/"); };
          const before = resolve(context, target);
          const from = replacePath(context).split("/").filter(Boolean);
          const to = replacePath(before).split("/").filter(Boolean);
          while (from.length && to.length && from[0] === to[0]) { from.shift(); to.shift(); }
          return { ...obj, path: ([...from.map(() => ".."), ...to].join("/") || ".") + (subnames.length ? ":" + subnames.join(":") : "") };
        }
        if (obj._type === "Raw") {
          if (typeof obj.value === "string" && obj.value.includes("NodePath(")) throw new Error("Cannot safely rename NodePaths in an unsupported Variant");
          return value;
        }
        return Object.fromEntries(Object.entries(obj).map(([k,v]) => [k, rewriteValue(v, context)]));
      };
      if (scene.subResources.some(r => JSON.stringify(r.properties).includes("NodePath")) || scene.connections.some(c => JSON.stringify(c.binds || []).includes("NodePath")) || (scene.extraSections || []).some(s => s.includes(nodePath))) throw new Error("Cannot safely rename references in scene resources or extra sections");
      const rewritten = scene.nodes.map(n => ({ n, properties: rewriteValue(n.properties, n.parent === undefined ? "" : getNodePath(n)) as Record<string, unknown> }));
      for (const { n, properties } of rewritten) { n.properties = properties; if (n.parent && n.parent !== ".") n.parent = replacePath(n.parent); if (n.owner) n.owner = replacePath(n.owner); }
      for (const conn of scene.connections) { conn.from = replacePath(conn.from); conn.to = replacePath(conn.to); }
      node.name = newName;
    }
    if (updates.type !== undefined) node.type = updates.type;
    if (updates.groups !== undefined) node.groups = updates.groups;
    if (updates.properties !== undefined) {
      node.properties = { ...node.properties, ...updates.properties };
      // Explicit tool inputs use the public Variant shorthand conventions.
      // Original literal metadata applies only to values retained from disk.
      for (const key of Object.keys(updates.properties)) delete node.literals?.[key];
    }

    return true;
  }

  /**
   * Get the scene tree as a hierarchical structure
   */
  static getSceneTree(scene: ParsedScene): Record<string, unknown> {
    const rootNode = scene.nodes.find(node => node.parent === undefined);
    if (!rootNode) return {};
    const entries = new Map<string, Record<string, unknown>>();
    for (const node of scene.nodes) {
      const key = node.parent === undefined ? "." : node.parent === "." ? node.name : `${node.parent}/${node.name}`;
      entries.set(key, { type: node.type, properties: node.properties, _children: {} });
    }
    for (const node of scene.nodes) {
      if (node.parent === undefined) continue;
      const key = node.parent === "." ? node.name : `${node.parent}/${node.name}`;
      const parent = entries.get(node.parent);
      if (!parent) throw new Error(`Missing parent: ${node.parent}`);
      (parent._children as Record<string, unknown>)[node.name] = entries.get(key);
    }
    return { [rootNode.name]: entries.get(".")! };
  }

  private static updateLoadSteps(scene: ParsedScene): void {
    scene.header.loadSteps =
      scene.externalResources.length + scene.subResources.length + 1;
  }
}
