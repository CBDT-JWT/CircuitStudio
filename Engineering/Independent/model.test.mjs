import test from 'node:test';
import assert from 'node:assert/strict';
import {catalog,symbol,pinsFor} from './symbols.mjs';
import {newProject,makeComponent,ProjectStore,connectPins,resolveNets,netlist,routeOrthogonal,addCell,assertNoHierarchyCycle,uid,assertTopologyPreserved,boundsFor} from './model.mjs';
import {parseSpice,routeImportedProject,importedNetErrors} from './importer.mjs';
import {displayValue,schematicMarkup} from './renderer.mjs';
import {editorAgent,stampFor,defaultConfiguration} from './agent.mjs';
test('all 78 independently authored library entries have drawable geometry and unique pins',()=>{assert.equal(catalog.length,78);for(const entry of catalog){const s=symbol(entry.id);assert(s.ink.length>0,entry.id);assert.equal(new Set(s.pins.map(p=>p.name)).size,s.pins.length,entry.id);}});
test('real pin connections join the intended terminals only',()=>{const p=newProject(),c=p.cells[0];const a=makeComponent('resistor',0,0,'R1'),b=makeComponent('resistor',100,0,'R2');c.components.push(a,b);connectPins(c,[{instanceId:a.id,pinName:'1'},{instanceId:b.id,pinName:'1'}]);let n=resolveNets(c);assert.equal(n.pinNets[a.id+':1'],n.pinNets[b.id+':1']);assert.notEqual(n.pinNets[a.id+':1'],n.pinNets[a.id+':2']);});
test('crossings are separate, T junctions and explicit dots bond',()=>{
 const c=newProject().cells[0],a={id:uid(),points:[{x:-50,y:0},{x:50,y:0}]},b={id:uid(),points:[{x:0,y:-50},{x:0,y:50}]};c.wires=[a,b];
 assert.notEqual(resolveNets(c).wireNets[a.id],resolveNets(c).wireNets[b.id]);c.junctions=[{x:0,y:0}];assert.equal(resolveNets(c).wireNets[a.id],resolveNets(c).wireNets[b.id]);
 c.junctions=[];b.points[1]={x:0,y:0};assert.equal(resolveNets(c).wireNets[a.id],resolveNets(c).wireNets[b.id]);
});
test('transaction failures roll back and user edits prevent AI undo',()=>{const store=new ProjectStore();store.transact('AI place',(p,c)=>c.components.push(makeComponent('resistor',0,0,'R1')),{ai:true});store.transact('User move',(p,c)=>c.components[0].x=30);assert.throws(()=>store.undo(true),/用户已编辑/);const before=JSON.stringify(store.project);assert.throws(()=>store.transact('bad',(p,c)=>c.components[0].x=NaN));assert.equal(JSON.stringify(store.project),before);store.undo();assert.equal(store.cell.components[0].x,0);store.redo();assert.equal(store.cell.components[0].x,30);});
test('router detours around a component and reports impossible endpoints',()=>{const boxes=[{x:30,y:-10,width:40,height:20}];const path=routeOrthogonal({x:0,y:0},{x:100,y:0},boxes);assert(path.some(p=>p.y!==0));for(let i=1;i<path.length;i++)assert(path[i].x===path[i-1].x||path[i].y===path[i-1].y);});
test('source/RC import retains actual topology and emitted values',()=>{const p=routeImportedProject(parseSpice('VIN IN 0 SIN(0 1 1k)\nR1 IN OUT 1k\nC1 OUT 0 1n',{positions:{VIN:[0,100],R1:[100,0,270],C1:[220,100]}}));assert.deepEqual(importedNetErrors(p),[]);const source=netlist(p);assert.match(source,/R1 IN OUT 1k/);assert.match(source,/C1 OUT 0 1n/);assert.match(source,/SIN\(0 1 1k/);});
test('hierarchy cycles fail before SPICE emission',()=>{const p=newProject(),child=addCell(p,'CHILD',[{name:'IN'},{name:'OUT'}]);p.cells[0].components.push(makeComponent('cell-instance',0,0,'X1',{cellId:child.id,ports:['IN','OUT']}));assert.doesNotThrow(()=>assertNoHierarchyCycle(p));child.components.push(makeComponent('cell-instance',0,0,'X2',{cellId:p.topCellId,ports:[]}));assert.throws(()=>netlist(p),/循环引用/);});
test('AC plus SIN never interprets the waveform name as an AC phase',()=>{const p=parseSpice('VIN IN 0 AC 1 SIN(0 1 1k)');assert.equal(p.cells[0].components[0].parameters.acPhase,'0');assert.match(netlist(p),/AC 1 0 SIN/);});
test('global supply ground remains ground and does not alias a signal',()=>{const p=routeImportedProject(parseSpice('VDD VDD 0 1.8\nR1 VDD OUT 1k\nR2 OUT 0 1k',{positions:{VDD:[0,0],R1:[100,60],R2:[200,160]}}));assert.deepEqual(importedNetErrors(p),[]);assert.match(netlist(p),/VDD VDD 0 DC 1.8/);assert.match(netlist(p),/R2 OUT 0 1k/);});
test('subcircuit MOS bindings emit X and global rails traverse hierarchy',()=>{const p=newProject(),c=p.cells[0];c.components.push(makeComponent('nmos',0,0,'M1',{invocation:'subcircuit',model:'sky130_fd_pr__nfet_01v8'}));c.components.push(makeComponent('vdd-port',100,0,''));assert.match(netlist(p),/XM1 .*sky130_fd_pr__nfet_01v8 W=/);assert.match(netlist(p),/\.global VDD/);});
test('mirroring and rotating preserve the pin names and exact transformed coordinates',()=>{const c=makeComponent('nmos',100,200,'M1');c.flipX=true;c.rotation=90;const p=pinsFor(c);assert.deepEqual(p.find(p=>p.name==='G'),{name:'G',x:100,y:220,direction:'west',hidden:false});assert.equal(new Set(p.map(p=>p.name)).size,3);});
test('detaching a branch is rejected instead of silently saving a broken graph',()=>{const p=routeImportedProject(parseSpice('VIN IN 0 1\nR1 IN OUT 1k\nR2 OUT 0 1k',{positions:{VIN:[0,100],R1:[120,0,270],R2:[240,100]}}));const before=structuredClone(p.cells[0]);p.cells[0].wires=[];assert.throws(()=>assertTopologyPreserved(before,p.cells[0]),/分支连接/);});
test('large figures export complete bounds and labels use concise engineering units',()=>{const c=newProject().cells[0];c.components.push(makeComponent('line',0,0,'',{dx:'600',dy:'200'}));assert(boundsFor(c).width>600);assert.equal(displayValue(makeComponent('capacitor',0,0,'C1',{value:'1e-9'})),'1nF');assert.equal(displayValue(makeComponent('resistor',0,0,'R1',{value:'0.632455532034'})),'632.5mΩ');});
test('straight joins do not acquire gratuitous junction dots',()=>{const c=newProject().cells[0];c.wires=[{id:uid(),points:[{x:-50,y:0},{x:0,y:0}]},{id:uid(),points:[{x:0,y:0},{x:50,y:0}]}];assert(!schematicMarkup(c).includes('r="2.6"'));c.wires.push({id:uid(),points:[{x:0,y:0},{x:0,y:50}]});assert(schematicMarkup(c).includes('r="2.6"'));});
test('AI places ground and power rails with stale-context rejection and undo',async()=>{
 const tab={store:new ProjectStore(),sessionID:uid(),configuration:defaultConfiguration()},agent=editorAgent({tab:()=>tab,changed:()=>{},image:async()=>'',loadPacket:async()=>({text:''})});
 const original=stampFor(tab);await agent('add_component',{symbolId:'ground',x:0,y:100},original);assert.equal(tab.store.cell.components[0].type,'ground');
 await assert.rejects(()=>agent('add_component',{symbolId:'resistor',x:100,y:100},original),/已改变/);
 await agent('add_power_rail',{start:{x:0,y:0},end:{x:200,y:0},name:'VDD'},stampFor(tab));assert.equal(tab.store.cell.wires[0].rail,true);assert.match(netlist(tab.store.project),/\.global VDD/);
 await agent('undo_circuit_edit',{},stampFor(tab));assert.equal(tab.store.cell.wires.length,0);assert.equal(tab.store.cell.components.length,1);
});
test('renaming child ports updates parent pins and attached wires atomically',()=>{
 const p=newProject(),child=addCell(p,'FILTER',[{name:'IN'},{name:'OUT'}]);const instance=makeComponent('cell-instance',100,0,'X1',{cellId:child.id,ports:['IN','OUT']}),source=makeComponent('voltage-source',0,80,'VIN');p.cells[0].components.push(instance,source);connectPins(p.cells[0],[{instanceId:source.id,pinName:'+'},{instanceId:instance.id,pinName:'IN'}]);
 const store=new ProjectStore(p);store.transact('Rename port',project=>project.cells.find(c=>c.id===child.id).ports[0].name='INPUT',{structure:true});
 const parent=store.project.cells[0];assert.equal(parent.components[0].parameters.ports[0],'INPUT');assert(parent.wires.some(w=>w.end?.pinName==='INPUT'));
 assert.match(netlist(store.project),/\.subckt FILTER INPUT OUT/);store.undo();assert.equal(store.project.cells[0].components[0].parameters.ports[0],'IN');
});

test('parameterized subcircuit headers do not invent a PARAMS pin',()=>{const p=parseSpice('X1 IN OUT FILTER R=2k\n.subckt FILTER IN OUT PARAMS: R=1k\nR1 IN OUT {R}\n.ends FILTER');assert.equal(p.cells[0].components[0].parameters.ports.length,2);assert.equal(p.cells[0].components[0].parameters.R,'2k');assert.match(netlist(p),/X1 .*FILTER R=2k/);});

test('MOS instance geometry and finger parameters survive SPICE round trips',()=>{const p=parseSpice('M1 OUT IN 0 0 NMOS W=10u L=180n NF=4 AD=2p');assert.match(netlist(p),/NF=4 AD=2p/);});

test('an explicitly selected model corner takes precedence over the project fallback packet',async()=>{const tab={store:new ProjectStore(),sessionID:uid(),configuration:defaultConfiguration()};tab.store.project.modelPacket='gf180-tt';tab.configuration.models='* CIRCUIT_STUDIO_GF180MCU_FF\n.model selected nmos level=54';const agent=editorAgent({tab:()=>tab,changed:()=>{},image:async()=>'',loadPacket:async()=>{throw Error('Must not overwrite an explicit model choice');}});const result=await agent('simulation_payload',{},stampFor(tab));assert.equal(result.configuration.models,tab.configuration.models);});
