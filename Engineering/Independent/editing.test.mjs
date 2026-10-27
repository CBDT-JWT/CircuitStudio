import test from 'node:test';
import assert from 'node:assert/strict';
import {newProject,makeComponent,uid,clone,ProjectStore} from './model.mjs';
import {pinsFor,symbol} from './symbols.mjs';
import {selectionPayload,insertPayload,translateSelection,figureBetween,resizeFigure} from './editing.mjs';
import {svgDocument} from './renderer.mjs';
test('copy, paste and move preserve every authored wire bend and junction',()=>{
 const store=new ProjectStore(),c=store.cell,a=makeComponent('resistor',0,0,'R1'),b=makeComponent('resistor',200,0,'R2');c.components.push(a,b);
 const pa=pinsFor(a)[0],pb=pinsFor(b)[0];c.wires.push({id:uid(),start:{instanceId:a.id,pinName:pa.name},end:{instanceId:b.id,pinName:pb.name},points:[pa,{x:pa.x,y:-80},{x:80,y:-80},{x:80,y:-120},{x:pb.x,y:-120},pb]});c.junctions=[{x:80,y:-80}];
 const original=clone(c),data=selectionPayload(c,new Set(c.components.map(c=>c.id)));let ids;
 store.transact('paste',(_,cell)=>{ids=insertPayload(cell,data,{x:300,y:100});});
 store.transact('move pasted copy',(_,cell)=>translateSelection(cell,ids,{x:50,y:30}));
 const wire=store.cell.wires[1];assert.deepEqual(wire.points,original.wires[0].points.map(p=>({x:p.x+350,y:p.y+130})));assert.deepEqual(store.cell.wires[0],original.wires[0]);assert.deepEqual(store.cell.junctions[1],{x:430,y:50});assert(ids.has(wire.start.instanceId));
 store.undo();assert.deepEqual(store.cell.wires[1].points,original.wires[0].points.map(p=>({x:p.x+300,y:p.y+100})));
});
test('moving one component stretches its endpoint without replacing remote wire bends',()=>{
 const c=newProject().cells[0],part=makeComponent('resistor',0,0,'R1');c.components.push(part);const pin=pinsFor(part)[0];c.wires=[{id:uid(),start:{instanceId:part.id,pinName:pin.name},points:[pin,{x:pin.x,y:-80},{x:100,y:-80},{x:100,y:-150},{x:200,y:-150}]}];const tail=clone(c.wires[0].points.slice(2));translateSelection(c,new Set([part.id]),{x:30,y:20});assert.deepEqual(c.wires[0].points.slice(2),tail);assert.deepEqual(c.wires[0].points[0],{x:pin.x+30,y:pin.y+20});
});
test('drawn geometry has matching preview/commit midpoint, constraints and side resizing',()=>{
 const line=figureBetween('line',{x:5,y:5},{x:40,y:20});assert.equal(line.x,22.5);assert.equal(line.parameters.dx,'35');
 const square=figureBetween('rectangle',{x:10,y:10},{x:70,y:30},{shift:true});assert.equal(square.parameters.width,square.parameters.height);
 const rect=figureBetween('rectangle',{x:10,y:10},{x:110,y:70});resizeFigure(rect,'e',{x:140,y:40});assert.equal(rect.x,75);assert.equal(rect.parameters.width,'130');assert.equal(rect.parameters.height,'60');
 resizeFigure(rect,'e',{x:-20,y:40});assert.equal(rect.parameters.width,'30');assert.equal(rect.x,-5);
});
test('polarity has editable bold text, controlled spacing and valid export geometry',()=>{
 const s=symbol('polarity',{text:'V_{out}',spacing:'120',strokeWidth:'3'});assert.match(s.ink,/stroke-width="3"/);assert.match(s.ink,/M-64.5/);assert.match(s.uprightInk,/baseline-shift="sub"/);assert.match(s.uprightInk,/out/);
 const c=newProject().cells[0];c.components.push(makeComponent('polarity',1000,-200,'',{text:'V_{out}',spacing:'120'}));const svg=svgDocument(c);assert.match(svg,/V<tspan/);assert(!svg.includes('data-resize='));
});

test('copy and move keep explicit crossing junctions inside wire segments',()=>{const c=newProject().cells[0];c.wires=[{id:uid(),points:[{x:-50,y:0},{x:50,y:0}]},{id:uid(),points:[{x:0,y:-50},{x:0,y:50}]}];c.junctions=[{x:0,y:0}];const ids=new Set(c.wires.map(w=>w.id)),packet=selectionPayload(c,ids);assert.deepEqual(packet.junctions,[{x:0,y:0}]);translateSelection(c,ids,{x:30,y:20});assert.deepEqual(c.junctions,[{x:30,y:20}]);});

test('moving a wire alone keeps its unmoved component terminals attached',()=>{const c=newProject().cells[0],a=makeComponent('resistor',0,0,'R1'),b=makeComponent('resistor',200,0,'R2');c.components=[a,b];const pa=pinsFor(a)[0],pb=pinsFor(b)[0],wire={id:uid(),start:{instanceId:a.id,pinName:pa.name},end:{instanceId:b.id,pinName:pb.name},points:[pa,{x:pa.x,y:-80},{x:pb.x,y:-80},pb]};c.wires=[wire];translateSelection(c,new Set([wire.id]),{x:30,y:20});assert.deepEqual(wire.points[0],{x:pa.x,y:pa.y});assert.deepEqual(wire.points.at(-1),{x:pb.x,y:pb.y});assert(wire.points.some(p=>p.x===pa.x+30&&p.y===-60));assert(wire.points.some(p=>p.x===pb.x+30&&p.y===-60));});
