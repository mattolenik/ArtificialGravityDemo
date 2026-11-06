import type { ToolHandler } from "../index.js";
import { withFileMutation } from "./project-fs.js";
import { usesEditorBridgeTool } from "./tool-metadata.js";

/** File operations share a queue, including independent HTTP requests and readers. */
export class FileToolRegistry extends Map<string, ToolHandler> {
  override set(name: string, tool: ToolHandler): this {
    if (!usesEditorBridgeTool(name)) {
      const handler = tool.handler;
      return super.set(name, { ...tool, handler: args => withFileMutation(() => handler(args)) });
    }
    return super.set(name, tool);
  }
}
