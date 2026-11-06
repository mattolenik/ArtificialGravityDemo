import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { registerResourceTools } from "./resource-tools.js";
import type { ServerState, ToolHandler } from "../index.js";
const directories: string[] = [];
afterEach(async()=>{for(const dir of directories.splice(0)) await fs.rm(dir,{recursive:true,force:true});});
async function setup() { const root=await fs.mkdtemp(path.join(os.tmpdir(),'resource-regression-'));directories.push(root);const tools=new Map<string,ToolHandler>();registerResourceTools(tools,{projectPath:root} as ServerState);return {root,tools}; }
describe('resource production handlers',()=>{
 it('serializes dictionaries, reserved-looking keys and escaped strings',async()=>{
  const {root,tools}=await setup();const tool=tools.get('godot_write_resource')!;
  await tool.handler(tool.inputSchema.parse({path:'test.tres',resourceType:'Resource',properties:{resource_name:'Say "hello"\\path\nnext','metadata/inventory':{x:1,y:2,_private:3},'metadata/text':'Vector2(1, 2)'}}));
  const text=await fs.readFile(path.join(root,'test.tres'),'utf8');
  expect(text).toContain('resource_name = "Say \\"hello\\"\\\\path\\nnext"');
  expect(text).toContain('metadata/inventory = {"x": 1, "y": 2, "_private": 3}');
  expect(text).toContain('metadata/text = "Vector2(1, 2)"');
 });
 it('rejects nonpositive costs and caps positive-cost work before looping',async()=>{
  const {tools}=await setup();const tool=tools.get('godot_generate_wave_config')!;
  for(const cost of [0,-1]) expect(()=>tool.inputSchema.parse({waveCount:1,enemyTypes:[{name:'slime',baseCost:cost}]})).toThrow();
  await expect(tool.handler(tool.inputSchema.parse({waveCount:100,difficultyScale:2,enemyTypes:[{name:'slime',baseCost:1}]}))).rejects.toThrow(/work limit/);
  const result=await tool.handler(tool.inputSchema.parse({waveCount:2,enemyTypes:[{name:'slime',baseCost:5}]})) as any;
  expect(result.waves).toHaveLength(2);
 });
});
