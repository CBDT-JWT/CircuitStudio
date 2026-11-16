import test from 'node:test';
import assert from 'node:assert/strict';
import {ProjectStore,makeComponent,connectPins,clone,resolveNets,netlist,uid} from './model.mjs';
import {importProject} from './importer.mjs';
import {selectionPayload,insertPayload} from './editing.mjs';
import {schematicMarkup,svgDocument} from './renderer.mjs';
import {normalizeColor,selectionStyleSummary,commitSelectionStyle,lineStyleOf} from './object-styles.mjs';

function fixture(){
 const store=new ProjectStore(),cell=store.cell;
 const a=makeComponent('resistor',0,0,'R1'),b=makeComponent('capacitor',240,0,'C1'),shape=makeComponent('rectangle',120,-150,'');
 cell.components.push(a,b,shape);connectPins(cell,[{instanceId:a.id,pinName:'1'},{instanceId:b.id,pinName:'1'}]);
 const wire=cell.wires[0],note={id:uid(),text:'输出 V_{out}',position:{x:25.5,y:100.25},size:18};cell.notes.push(note);
 return {store,ids:new Set([a.id,shape.id,wire.id,note.id]),a,b,shape,wire,note};
}
const topology=cell=>{const {pinNets,wireNets,nets}=resolveNets(cell);return {pinNets,wireNets,nets};};

test('batch styles are one undo step and leave connectivity, SPICE and unselected objects intact',()=>{
 const {store,ids,a,b,wire,note}=fixture(),before=clone(store.project),nets=topology(store.cell),spice=netlist(store.project);
 assert.equal(commitSelectionStyle(store,ids,{color:'#f50',lineStyle:'dashed'}),4);
 assert.equal(store.undoStack.length,1);assert.equal(store.cell.components.find(p=>p.id===a.id).color,'#ff5500');
 assert.equal(store.cell.wires[0].color,'#ff5500');assert.equal(store.cell.wires[0].lineStyle,'dashed');
 assert.equal(store.cell.notes[0].color,'#ff5500');assert(!Object.hasOwn(store.cell.notes[0],'lineStyle'));
 assert.deepEqual(store.cell.components.find(p=>p.id===b.id),before.cells[0].components.find(p=>p.id===b.id));
 assert.deepEqual(topology(store.cell),nets);assert.equal(netlist(store.project),spice);assert.deepEqual(store.cell.wires[0].points,wire.points);
 store.undo();assert.equal(store.cell.components.find(p=>p.id===a.id).color,null);assert.equal(store.cell.notes.find(p=>p.id===note.id).color,undefined);
 store.redo();assert.equal(store.cell.wires[0].lineStyle,'dashed');
});
test('unchanged styles do not create duplicate undo entries and text-only line changes do nothing',()=>{
 const {store,ids,note}=fixture();commitSelectionStyle(store,ids,{color:'#aabbcc',lineStyle:'dashed'});
 const revision=store.project.revision;assert.equal(commitSelectionStyle(store,ids,{color:'#abc',lineStyle:'dashed'}),0);assert.equal(store.project.revision,revision);
 assert.equal(commitSelectionStyle(store,new Set([note.id]),{lineStyle:'solid'}),0);assert.equal(store.project.revision,revision);
 commitSelectionStyle(store,ids,{color:null,lineStyle:'solid'});assert.equal(selectionStyleSummary(store.cell,ids).color,null);assert.equal(selectionStyleSummary(store.cell,ids).lineStyle,'solid');
});
test('invalid style input fails atomically and mixed selections report mixed values',()=>{
 const {store,ids,a}=fixture(),before=clone(store.project);
 assert.throws(()=>commitSelectionStyle(store,ids,{color:'#123456',lineStyle:'other'}));
 assert.throws(()=>commitSelectionStyle(store,ids,{color:'red" onload="bad'}));assert.deepEqual(store.project,before);
 assert.equal(normalizeColor('#aBc'),'#aabbcc');
 commitSelectionStyle(store,new Set([a.id]),{color:'#112233',lineStyle:'dashed'});
 const summary=selectionStyleSummary(store.cell,ids);assert.equal(summary.color,undefined);assert.equal(summary.lineStyle,undefined);assert.equal(summary.strokeCount,3);
});
test('save/reopen and editable clipboard round trips retain all authored styles',()=>{
 const {store,ids,a}=fixture();commitSelectionStyle(store,ids,{color:'#a23456',lineStyle:'dashed'});
 store.cell.components.find(p=>p.id===a.id).textColor='#1288ff';
 const reopened=importProject(JSON.stringify(store.project)),cell=reopened.cells[0],payload=selectionPayload(cell,ids),count=cell.components.length;
 insertPayload(cell,payload,{x:400,y:300});
 assert.equal(cell.components[count].color,'#a23456');assert.equal(cell.components[count].textColor,'#1288ff');assert.equal(cell.components[count].lineStyle,'dashed');
 assert.equal(cell.wires.at(-1).color,'#a23456');assert.equal(lineStyleOf(cell.wires.at(-1)),'dashed');assert.equal(cell.notes.at(-1).color,'#a23456');
});
test('authored colors stay visible when selected and SVG exports retain dashes without selection decoration',()=>{
 const {store,ids,a,wire}=fixture();commitSelectionStyle(store,ids,{color:'#2266cc',lineStyle:'dashed'});
 const interactive=schematicMarkup(store.cell,{interactive:true,selected:ids});
 const group=interactive.match(new RegExp('<g[^>]+data-component="'+a.id+'"[^>]*>'))[0];assert.match(group,/color="#2266cc"/);assert.match(group,/stroke-dasharray="7 5"/);
 const stroke=interactive.match(new RegExp('<path[^>]+data-wire="'+wire.id+'"[^>]*>'))[0];assert.match(stroke,/stroke="#2266cc"/);assert.match(stroke,/stroke-dasharray="7 5"/);
 assert.match(interactive,/data-selection="true"/);
 const svg=svgDocument(store.cell,{selection:ids});assert.match(svg,/stroke-dasharray="7 5"/);assert.match(svg,/#2266cc/);assert(!svg.includes('data-selection="true"'));assert(!svg.includes('data-text-frame'));
});
test('component text color can differ from body color, while coloring the whole component resets that override',()=>{
 const {store,a}=fixture(),part=store.cell.components.find(p=>p.id===a.id);part.color='#112233';part.textColor='#dd3355';
 const svg=svgDocument(store.cell);const label=svg.match(new RegExp('<text[^>]+data-label-instance="'+a.id+'"[^>]*>'))[0];assert.match(label,/fill="#dd3355"/);
 commitSelectionStyle(store,new Set([a.id]),{color:'#112233'});assert.equal(store.cell.components.find(p=>p.id===a.id).textColor,null);
});

test('one component label can be colored without recoloring its value or body',()=>{const {store,a}=fixture();const part=store.cell.components.find(p=>p.id===a.id);part.color='#2266cc';part.referenceColor='#aa22cc';const svg=svgDocument(store.cell),reference=svg.match(new RegExp('<text[^>]+data-label-instance="'+a.id+'"[^>]+data-label="reference"[^>]*>'))[0],value=svg.match(new RegExp('<text[^>]+data-label-instance="'+a.id+'"[^>]+data-label="value"[^>]*>'))[0];assert.match(reference,/fill="#aa22cc"/);assert.match(value,/fill="#2266cc"/);commitSelectionStyle(store,new Set([a.id]),{color:'#2266cc'});assert.equal(store.cell.components[0].referenceColor,null);});
