import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const base=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../dist/tools')+'/';
const root=await fs.mkdtemp(path.join(os.tmpdir(),'godot-generation-audit-')); console.log('FIXTURES',root);
await fs.mkdir(root,{recursive:true});
const tools=new Map(); const state={projectPath:root,editorConnected:false,editorPort:6550};
for(const [file,fn] of [['audio','registerAudioTools'],['input','registerInputTools'],['ui-component','registerUIComponentTools'],['ui-theme','registerUIThemeTools'],['script','registerScriptTools']]) (await import(base+file+'-tools.js'))[fn](tools,state);
const call=async(name,args)=>{const t=tools.get(name);return t.handler(t.inputSchema.parse(args));};
await fs.writeFile(root+'/project.godot',`config_version=5\n[application]\nconfig/name="Audit"\n[input]\nmodified_click={\n"deadzone": 0.5,\n"events": [Object(InputEventMouseButton,"button_index":1,"ctrl_pressed":true)]\n}\n`);
await fs.writeFile(root+'/default_bus_layout.tres',`[gd_resource type="AudioBusLayout" load_steps=2 format=3]\n[sub_resource type="AudioEffectReverb" id="Reverb"]\nroom_size = 0.8\n[resource]\nbus/0/name = &"Master"\nbus/0/effect/0/effect = SubResource("Reverb")\nbus/0/effect/0/enabled = true\n`);
await fs.copyFile(root+'/default_bus_layout.tres',root+'/before.tres');
console.log('audio',await call('godot_audio_set_bus',{name:'Master',volumeDb:-6}));
console.log('input',await call('godot_input_set_action',{action:'jump',events:[{type:'key',physicalKeycode:32}]}));
console.log('relative menu',await call('godot_ui_create_menu',{path:'scenes/menu.tscn',title:'Menu',buttons:[{text:'Play'}]}));
console.log('empty menu',await call('godot_ui_create_menu',{path:'res://empty_menu.tscn',title:'Menu',buttons:[]}));
console.log('theme',await call('godot_ui_create_stylebox',{path:'res://transparent.tres',bg_color:{r:0,g:0,b:0,a:0},content_margins:0}));
const movement=await call('godot_generate_script',{description:'player movement'});
await fs.writeFile(root+'/movement.gd',movement.generatedScript);
console.log('script generated',movement.generatedScript);
console.log('validation',await call('godot_validate_script',{content:movement.generatedScript}));
await fs.writeFile(root+'/verify.gd',`extends SceneTree\nfunc _initialize():\n\tAudioServer.set_bus_layout(load("res://before.tres"))\n\tprint("EFFECTS_BEFORE=",AudioServer.get_bus_effect_count(0))\n\tAudioServer.set_bus_layout(load("res://default_bus_layout.tres"))\n\tprint("EFFECTS_AFTER=",AudioServer.get_bus_effect_count(0))\n\tInputMap.load_from_project_settings()\n\tprint("CTRL_AFTER=",InputMap.action_get_events("modified_click")[0].ctrl_pressed)\n\tprint("ALPHA=",load("res://transparent.tres").bg_color.a)\n\tprint("MARGIN=",load("res://transparent.tres").content_margin_left)\n\tprint("RELATIVE_MENU=",load("res://scenes/menu.tscn"))\n\tprint("EMPTY_MENU=",load("res://empty_menu.tscn"))\n\tprint("MOVEMENT=",load("res://movement.gd"))\n\tquit()\n`);

(await import(base+"shader-tools.js")).registerShaderTools(tools,state);
(await import(base+"navigation-tools.js")).registerNavigationTools(tools,state);
const effects=['flash','outline','dissolve','pixelate','wave','gradient_map','chromatic_aberration','vignette','crt','hologram','fresnel'];
const paths=[];
for(const effect of effects){const shaderType=['hologram','fresnel'].includes(effect)?'spatial':'canvas_item'; const result=await call('godot_generate_shader',{description:'effect',shaderType,effect}); await fs.writeFile(root+'/'+effect+'.gdshader',result.generatedShader); paths.push('res://'+effect+'.gdshader');}
for(const shaderType of ['canvas_item','spatial','particles','sky','fog']) {const result=await call('godot_generate_shader',{description:'custom effect',shaderType}); await fs.writeFile(root+'/custom_'+shaderType+'.gdshader',result.generatedShader);paths.push('res://custom_'+shaderType+'.gdshader');}
await fs.writeFile(root+'/verify_shaders.gd',`extends SceneTree\nfunc _initialize():\n\tfor path in ${JSON.stringify(paths)}:\n\t\tprint("CHECK=",path)\n\t\tvar shader: Shader = load(path)\n\t\tprint("UNIFORMS=", shader.get_shader_uniform_list())\n\tquit()\n`);
await fs.writeFile(root+'/nav.tscn',`[gd_scene format=3]\n[node name="Root" type="Node"]\n[node name="Region" type="NavigationRegion3D" parent="."]\nenabled = false\nnavigation_mesh = null\n[node name="Agent" type="NavigationAgent2D" parent="."]\n`);
console.log('NAV_VALIDATION',await call('godot_navigation_validate_paths',{scenePath:'res://nav.tscn',strict:true}));
console.log('NAV_BAKE_PLAN',await call('godot_navigation_build_bake_plan',{scenePath:'res://nav.tscn'}));

for(const script of ['verify.gd','verify_shaders.gd']) {
const engine=spawnSync(process.env.GODOT_BIN || 'godot',['--headless','--path',root,'--script',script],{encoding:'utf8',timeout:20000});
console.log('ENGINE',script,engine.status,engine.error?.message || '',engine.stdout,engine.stderr);
}
