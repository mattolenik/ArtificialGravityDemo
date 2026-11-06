import type { ToolHandler } from "../index.js";
/** File operations share a queue, including independent HTTP requests and readers. */
export declare class FileToolRegistry extends Map<string, ToolHandler> {
    set(name: string, tool: ToolHandler): this;
}
//# sourceMappingURL=tool-registry.d.ts.map