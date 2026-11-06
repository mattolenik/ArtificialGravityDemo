import { withFileMutation } from "./project-fs.js";
import { usesEditorBridgeTool } from "./tool-metadata.js";
/** File operations share a queue, including independent HTTP requests and readers. */
export class FileToolRegistry extends Map {
    set(name, tool) {
        if (!usesEditorBridgeTool(name)) {
            const handler = tool.handler;
            return super.set(name, { ...tool, handler: args => withFileMutation(() => handler(args)) });
        }
        return super.set(name, tool);
    }
}
//# sourceMappingURL=tool-registry.js.map