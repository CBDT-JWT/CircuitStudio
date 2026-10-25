import {catalog,canonical,symbol,pinsFor,transformPoint} from './symbols.mjs';
export const clone=value=>structuredClone(value);
export const uid=()=>globalThis.crypto.randomUUID();
export const snap=(n,grid=10)=>Math.round(Number(n)/grid)*grid;
export const pointKey=p=>`${Math.round(p.x*1e5)},${Math.round(p.y*1e5)}`;
export const samePoint=(a,b)=>Math.abs(a.x-b.x)<1e-5&&Math.abs(a.y-b.y)<1e-5;
const key=(id,pin)=>`${id}:${pin}`;
export function emptyCell(name='主电路'){return {id:uid(),name,revision:0,ports:[],components:[],wires:[],notes:[],junctions:[]};}
export function newProject(name='新建电路'){const cell=emptyCell();return {schema:'circuitstudio-project-v1',version:1,id:uid(),name,revision:0,structureRevision:0,topCellId:cell.id,activeCellId:cell.id,cells:[cell],models:'',subcircuits:'',pdkBindings:[]};}
export function makeComponent(type,x,y,reference='',parameters={}){const definition=symbol(type,parameters);return {id:uid(),type:definition.id,x:snap(x),y:snap(y),rotation:0,flipX:false,flipY:false,reference,parameters:{...definition.defaults,...parameters},netHints:{},showReference:!!definition.prefix,showValue:!!definition.defaults.value,referenceOffset:{x:16,y:-8},valueOffset:{x:16,y:8},color:null};}
function onSegment(p,a,b){return Math.abs((p.x-a.x)*(b.y-a.y)-(p.y-a.y)*(b.x-a.x))<1e-5&&p.x>=Math.min(a.x,b.x)-1e-5&&p.x<=Math.max(a.x,b.x)+1e-5&&p.y>=Math.min(a.y,b.y)-1e-5&&p.y<=Math.max(a.y,b.y)+1e-5;}
class Sets{constructor(){this.parent=new Map();}find(x){if(!this.parent.has(x))this.parent.set(x,x);if(this.parent.get(x)!==x)this.parent.set(x,this.find(this.parent.get(x)));return this.parent.get(x);}join(a,b){a=this.find(a);b=this.find(b);if(a!==b)this.parent.set(b,a);}}
export function resolveNets(cell){
 const sets=new Sets(),locations=[],hints=new Map(),named=new Map(),visible=[];
 const claim=(name,k)=>{if(!name)return;hints.set(k,name);};
 for(const component of cell.components){for(const p of pinsFor(component)){const k=key(component.id,p.name);sets.find(k);locations.push({...p,key:k});if(!p.hidden)visible.push({...p,key:k,component});claim(component.netHints?.[p.name],k);if(p.hidden&&component.netHints?.[p.name]==='0'){const ground=named.get('0')??'global:0';named.set('0',ground);sets.join(k,ground);}}
  const pins=pinsFor(component);if(!pins.length)continue;
  if(component.type==='ground'||['vdd-port','power-rail','bias-port','cell-pin'].includes(component.type)){
   const name=component.type==='ground'?'0':component.parameters.name;const k=key(component.id,pins[0].name);claim(name,k);if(name){if(named.has(name))sets.join(k,named.get(name));else named.set(name,k);}}
  if(component.parameters.bulk!=='external'&&component.parameters.bulk!=='global'&&component.nets?.B&&component.nets?.S)sets.join(key(component.id,'B'),key(component.id,'S'));
 }
 const segments=[];
 for(const w of cell.wires){const wk='wire:'+w.id;sets.find(wk);claim(w.netName,wk);for(let i=1;i<w.points.length;i++)segments.push({a:w.points[i-1],b:w.points[i],key:wk});if(w.start)sets.join(wk,key(w.start.instanceId,w.start.pinName));if(w.end)sets.join(wk,key(w.end.instanceId,w.end.pinName));
  if(w.rail&&w.netName){if(named.has(w.netName))sets.join(wk,named.get(w.netName));else named.set(w.netName,wk);}}
 for(const p of locations)for(const s of segments)if(onSegment(p,s.a,s.b))sets.join(p.key,s.key);
 // T joints and explicit vertices connect. A simple crossing has no junction.
 for(const w of cell.wires)for(const p of w.points)for(const s of segments)if(onSegment(p,s.a,s.b))sets.join('wire:'+w.id,s.key);
 for(const p of cell.junctions??[]) {const hits=segments.filter(s=>onSegment(p,s.a,s.b));for(const s of hits.slice(1))sets.join(hits[0].key,s.key);}
 const groups=new Map();for(const [k] of sets.parent){const r=sets.find(k);if(!groups.has(r))groups.set(r,[]);groups.get(r).push(k);}
 const names=new Map(),used=new Set();let count=1;
 for(const [root,keys] of groups){const candidates=keys.map(k=>hints.get(k)).filter(Boolean);let name=candidates.includes('0')?'0':candidates.find(n=>/^(?:VDD|VSS|VCC|VEE|IN|OUT|VF)/i.test(n))??candidates[0];if(!name||used.has(name)){do{name='N'+count++;}while(used.has(name));}used.add(name);names.set(root,name);}
 const pinNets={};for(const p of locations)pinNets[p.key]=names.get(sets.find(p.key));const wireNets={};for(const w of cell.wires)wireNets[w.id]=names.get(sets.find('wire:'+w.id));
 return {pinNets,wireNets,nets:[...groups].map(([root,keys])=>({name:names.get(root),pins:locations.filter(p=>keys.includes(p.key)).map(p=>({instanceId:p.key.slice(0,p.key.lastIndexOf(':')),pinName:p.name})),wires:cell.wires.filter(w=>keys.includes('wire:'+w.id)).map(w=>w.id)})),visiblePins:visible};
}
function clearPath(a,b,obstacles){if(a.x!==b.x&&a.y!==b.y)return false;return !obstacles.some(o=>a.x===b.x?a.x>o.x&&a.x<o.x+o.width&&Math.max(a.y,b.y)>o.y&&Math.min(a.y,b.y)<o.y+o.height:a.y>o.y&&a.y<o.y+o.height&&Math.max(a.x,b.x)>o.x&&Math.min(a.x,b.x)<o.x+o.width);}
export function simplify(points){const out=[];for(const p of points){if(out.length&&samePoint(out.at(-1),p))continue;while(out.length>1){const a=out.at(-2),b=out.at(-1);if((a.x===b.x&&b.x===p.x)||(a.y===b.y&&b.y===p.y))out.pop();else break;}out.push({x:p.x,y:p.y});}return out;}
export function routeOrthogonal(a,b,obstacles=[],preferred,constraints={}){
 const forbiddenPoints=constraints.points??[],forbiddenSegments=constraints.segments??[];
 const vertexSafe=p=>!forbiddenSegments.some(s=>onSegment(p,s.a,s.b));
 const edgeSafe=(a,b)=>clearPath(a,b,obstacles)&&!forbiddenPoints.some(p=>onSegment(p,a,b))&&!forbiddenSegments.some(s=>(a.x===b.x&&s.a.x===s.b.x&&a.x===s.a.x&&Math.max(Math.min(a.y,b.y),Math.min(s.a.y,s.b.y))<=Math.min(Math.max(a.y,b.y),Math.max(s.a.y,s.b.y)))||(a.y===b.y&&s.a.y===s.b.y&&a.y===s.a.y&&Math.max(Math.min(a.x,b.x),Math.min(s.a.x,s.b.x))<=Math.min(Math.max(a.x,b.x),Math.max(s.a.x,s.b.x))));
 if(samePoint(a,b))return [a,b];const trials=[];
 if(preferred){const {start,end}=preferred;if(start.x!==end.x&&start.y!==end.y)throw Error('总线必须水平或竖直。');if(start.y===end.y)trials.push([a,{x:a.x,y:start.y},{x:b.x,y:start.y},b]);else trials.push([a,{x:start.x,y:a.y},{x:start.x,y:b.y},b]);}
 trials.push([a,{x:b.x,y:a.y},b],[a,{x:a.x,y:b.y},b]);
 for(let delta=20;delta<=160;delta+=20)for(const sign of [-1,1])trials.push([a,{x:a.x,y:a.y+delta*sign},{x:b.x,y:a.y+delta*sign},b],[a,{x:a.x+delta*sign,y:a.y},{x:a.x+delta*sign,y:b.y},b]);
 const cost=p=>p.slice(1).reduce((v,t,i)=>v+Math.abs(t.x-p[i].x)+Math.abs(t.y-p[i].y),0)+p.length*12;
 const available=trials.map(simplify).filter(p=>p.every(vertexSafe)&&p.slice(1).every((b,i)=>edgeSafe(p[i],b)));if(available.length)return available.sort((a,b)=>cost(a)-cost(b))[0];
 // A sparse visibility graph finds routes around actual symbol boxes. No
 // connectivity labels or hidden short-cuts are substituted for missing wires.
 const xs=[...new Set([a.x,b.x,...obstacles.flatMap(o=>[snap(o.x-10),snap(o.x+o.width+10)]),...forbiddenPoints.flatMap(p=>[p.x-10,p.x+10])])].sort((x,y)=>x-y),ys=[...new Set([a.y,b.y,...obstacles.flatMap(o=>[snap(o.y-10),snap(o.y+o.height+10)]),...forbiddenPoints.flatMap(p=>[p.y-10,p.y+10])])].sort((x,y)=>x-y);
 const vertices=xs.flatMap(x=>ys.map(y=>({x,y}))).filter(p=>vertexSafe(p)&&!obstacles.some(o=>p.x>o.x&&p.x<o.x+o.width&&p.y>o.y&&p.y<o.y+o.height));const lookup=new Map(vertices.map((p,i)=>[pointKey(p),i])),start=lookup.get(pointKey(a)),goal=lookup.get(pointKey(b));if(start===undefined||goal===undefined)throw Error('引脚被其他元件或导线遮挡，请调整位置。');
 const dist=new Map([[start,0]]),previous=new Map(),queue=[start],done=new Set();while(queue.length){queue.sort((x,y)=>(dist.get(x)+Math.abs(vertices[x].x-b.x)+Math.abs(vertices[x].y-b.y))-(dist.get(y)+Math.abs(vertices[y].x-b.x)+Math.abs(vertices[y].y-b.y)));const i=queue.shift();if(done.has(i))continue;if(i===goal){const result=[vertices[i]];let k=i;while(previous.has(k)){k=previous.get(k);result.push(vertices[k]);}return simplify(result.reverse());}done.add(i);const p=vertices[i];for(const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1]]){const xi=xs.indexOf(p.x)+dx,yi=ys.indexOf(p.y)+dy;if(xi<0||yi<0||xi>=xs.length||yi>=ys.length)continue;const j=lookup.get(pointKey({x:xs[xi],y:ys[yi]}));if(j===undefined||!edgeSafe(p,vertices[j]))continue;const d=dist.get(i)+Math.abs(p.x-vertices[j].x)+Math.abs(p.y-vertices[j].y);if(d<(dist.get(j)??Infinity)){dist.set(j,d);previous.set(j,i);queue.push(j);}}}
 throw Error('找不到不穿过元件的连线路径。请拉开元件间距。');
}
export function connectPins(cell,references,{trunk,netName}={}){
 if(references.length<2)throw Error('请选择至少两个引脚。');const targets=references.map(r=>{const c=cell.components.find(c=>c.id===r.instanceId),p=c&&pinsFor(c).find(p=>p.name===r.pinName);if(!c||!p)throw Error('引脚不存在：'+r.pinName);return {component:c,p,reference:r};});
 const boxes=cell.components.filter(c=>!['ground','vdd-port','bias-port','cell-pin','power-rail'].includes(c.type)).map(c=>({id:c.id,x:c.x-13,y:c.y-14,width:26,height:28}));
 const depart=t=>{const origin=transformPoint(t.component,{x:0,y:0});let dx=t.p.x-origin.x,dy=t.p.y-origin.y;if(Math.abs(dx)>Math.abs(dy)){dx=Math.sign(dx)||1;dy=0;}else{dy=Math.sign(dy)||1;dx=0;}return {x:t.p.x+dx*10,y:t.p.y+dy*10};};
 const resolved=resolveNets(cell),joining=new Set(targets.flatMap(t=>[resolved.pinNets[t.component.id+':'+t.p.name],t.component.netHints?.[t.p.name]]).filter(Boolean));if(netName)joining.add(netName);
 const otherWires=cell.wires.filter(w=>!joining.has(w.netName)&&!joining.has(resolved.wireNets[w.id]));
 const constraints={segments:otherWires.flatMap(w=>w.points.slice(1).map((b,i)=>({a:w.points[i],b}))),points:[...otherWires.flatMap(w=>w.points),...cell.components.flatMap(c=>pinsFor(c).filter(p=>!p.hidden&&c.netHints?.[p.name]&&!joining.has(c.netHints[p.name])).flatMap(p=>[{x:p.x,y:p.y},depart({component:c,p})]))]};
 const additions=[];for(const t of targets.slice(1)){const base=targets[0],a=depart(base),b=depart(t);let route;try{route=routeOrthogonal(a,b,boxes,trunk,constraints);}catch(error){throw Error(`${netName??'连线'} ${base.component.reference}.${base.p.name}(${a.x},${a.y}) → ${t.component.reference}.${t.p.name}(${b.x},${b.y}): ${error.message}`);}additions.push({id:uid(),points:simplify([base.p,...route,t.p]),start:base.reference,end:t.reference,netName});}cell.wires.push(...additions);return additions;
}
export function assertTopologyPreserved(before,after,{allowMerge=false}={}){
 const old=resolveNets(before).pinNets,next=resolveNets(after).pinNets,byOld=new Map(),byNew=new Map();
 for(const [pin,net] of Object.entries(old)){if(!next[pin])continue;if(!byOld.has(net))byOld.set(net,new Set());byOld.get(net).add(next[pin]);if(!byNew.has(next[pin]))byNew.set(next[pin],new Set());byNew.get(next[pin]).add(net);}
 if([...byOld.values()].some(names=>names.size>1))throw Error('此操作会断开分支连接。请把相连的导线一起框选后移动；当前修改已撤销。');
 if(!allowMerge&&[...byNew.values()].some(names=>names.size>1))throw Error('此操作会把原本分开的网络短接，当前修改已撤销。请使用连线工具明确连接。');
}
export function synchronizeHierarchy(project,previous){
 for(const cell of project.cells)for(const instance of cell.components.filter(c=>c.type==='cell-instance')){
  const target=project.cells.find(c=>c.id===instance.parameters.cellId);if(!target)throw Error('引用的层级单元不存在。');
  const oldTarget=previous.cells.find(c=>c.id===target.id),oldPorts=oldTarget?.ports??target.ports;
  const names=target.ports.map(p=>p.name),oldNames=instance.parameters.ports??oldPorts.map(p=>p.name);
  if(JSON.stringify(names)===JSON.stringify(oldNames)){instance.parameters.cellName=target.name;continue;}
  const rename=new Map(oldPorts.map(p=>[p.name,target.ports.find(n=>p.id&&n.id===p.id)?.name??target.ports.find(n=>n.name===p.name)?.name]));
  cell.wires=cell.wires.filter(w=>!['start','end'].some(end=>w[end]?.instanceId===instance.id&&rename.has(w[end].pinName)&&!rename.get(w[end].pinName)));
  for(const wire of cell.wires)for(const end of ['start','end'])if(wire[end]?.instanceId===instance.id&&rename.get(wire[end].pinName))wire[end].pinName=rename.get(wire[end].pinName);
  for(const [old,name] of rename)if(name&&name!==old&&instance.netHints[old]){instance.netHints[name]=instance.netHints[old];delete instance.netHints[old];}
  instance.parameters.ports=names;instance.parameters.cellName=target.name;
  const changing=cell.wires.filter(w=>w.start?.instanceId===instance.id||w.end?.instanceId===instance.id);cell.wires=cell.wires.filter(w=>!changing.includes(w));
  for(const wire of changing){const pin=ref=>{const part=ref&&cell.components.find(c=>c.id===ref.instanceId);return part&&pinsFor(part).find(p=>p.name===ref.pinName);};const a=pin(wire.start),b=pin(wire.end);if(a&&b)connectPins(cell,[wire.start,wire.end],{netName:wire.netName});else cell.wires.push({...wire,points:routeOrthogonal(a??wire.points[0],b??wire.points.at(-1))});}
 }
 assertNoHierarchyCycle(project);
}
export class ProjectStore {
 constructor(project=newProject()){this.project=validateProject(clone(project));this.undoStack=[];this.redoStack=[];this.aiRevision=null;}
 get cell(){return this.project.cells.find(c=>c.id===this.project.activeCellId)??this.project.cells[0];}
 transact(label,operation,{ai=false,structure=false}={}){const before=clone(this.project),draft=clone(this.project);operation(draft,draft.cells.find(c=>c.id===draft.activeCellId));synchronizeHierarchy(draft,before);validateProject(draft);draft.revision=before.revision+1;const cell=draft.cells.find(c=>c.id===draft.activeCellId);cell.revision=(before.cells.find(c=>c.id===cell.id)?.revision??0)+1;if(structure||JSON.stringify(draft.cells.map(c=>[c.id,c.ports]))!==JSON.stringify(before.cells.map(c=>[c.id,c.ports])))draft.structureRevision++;this.undoStack.push({project:before,label,ai});this.undoStack=this.undoStack.slice(-100);this.redoStack=[];this.project=draft;this.aiRevision=ai?draft.revision:null;return this.project;}
 undo(aiOnly=false){const entry=this.undoStack.at(-1);if(!entry)throw Error('没有可撤销的操作。');if(aiOnly&&(!entry.ai||this.aiRevision!==this.project.revision))throw Error('用户已编辑电路，不能撤销先前的 AI 操作。');this.undoStack.pop();this.redoStack.push({project:clone(this.project),label:entry.label,ai:entry.ai});const nextRevision=this.project.revision+1;this.project=clone(entry.project);this.project.revision=nextRevision;this.cell.revision=nextRevision;this.aiRevision=null;return this.project;}
 redo(){const e=this.redoStack.pop();if(!e)return;this.undoStack.push({project:clone(this.project),label:e.label,ai:false});const revision=this.project.revision+1;this.project=clone(e.project);this.project.revision=revision;this.cell.revision=revision;this.aiRevision=null;}
}
export function validateProject(p){if(p.schema!=='circuitstudio-project-v1'||!Array.isArray(p.cells)||!p.cells.length||p.cells.length>128||typeof p.name!=='string'||p.name.length>180)throw Error('工程格式不正确。');const ids=new Set();const validID=id=>typeof id==='string'&&/^[-\w.:]{1,140}$/.test(id);const validColor=color=>!color||/^#[\da-f]{6}$/i.test(color);for(const c of p.cells){if(!validID(c.id)||!Array.isArray(c.components)||!Array.isArray(c.wires)||!Array.isArray(c.notes)||c.components.length>10000||c.wires.length>30000||c.notes.length>5000)throw Error('电路规模超过限制或格式无效。');for(const o of [...c.components,...c.wires,...c.notes]){if(!validID(o.id)||ids.has(o.id))throw Error('重复或无效的对象标识。');if(!validColor(o.color))throw Error('对象颜色格式无效。');ids.add(o.id);}for(const part of c.components){const definition=symbol(part.type,part.parameters);if(Object.values(definition.bounds).some(v=>!Number.isFinite(v))||part.parameters.points&&(!Array.isArray(part.parameters.points)||part.parameters.points.length>1000||part.parameters.points.some(p=>!Number.isFinite(p.x)||!Number.isFinite(p.y))))throw Error('Invalid figure geometry.');if(!Number.isFinite(part.x)||!Number.isFinite(part.y)||Math.abs(part.x)>1e6||Math.abs(part.y)>1e6||![0,90,180,270].includes(part.rotation))throw Error('元件位置或方向无效。');}for(const w of c.wires)if(!Array.isArray(w.points)||w.points.length<2||w.points.length>2000||w.points.some(p=>!Number.isFinite(p.x)||!Number.isFinite(p.y)||Math.abs(p.x)>1e6||Math.abs(p.y)>1e6)||w.points.slice(1).some((b,i)=>b.x!==w.points[i].x&&b.y!==w.points[i].y))throw Error('导线必须由水平或竖直线段组成。');}return p;}
export function addCell(project,name,ports=[]){if(!name.trim()||project.cells.some(c=>c.name===name))throw Error('单元名称为空或已存在。');if(new Set(ports.map(p=>p.name)).size!==ports.length)throw Error('单元端口名称不能重复。');const cell=emptyCell(name.trim());cell.ports=ports.map(p=>({...p,id:p.id??uid()}));project.cells.push(cell);return cell;}
export function assertNoHierarchyCycle(project){const active=new Set(),visited=new Set();function visit(id){if(active.has(id))throw Error('层级单元不能形成循环引用。');if(visited.has(id))return;const cell=project.cells.find(c=>c.id===id);if(!cell)throw Error('层级单元不存在。');active.add(id);for(const c of cell.components)if(c.type==='cell-instance')visit(c.parameters.cellId);active.delete(id);visited.add(id);}for(const c of project.cells)visit(c.id);}
const cleanToken=s=>{s=String(s??'');if(!s||/[\s;`\n\r]/.test(s))throw Error('非法的 SPICE 标识：'+s);return s;};
function sourceValue(p){const dc=p.dc??p.value??'0',ac=p.acMagnitude?` AC ${p.acMagnitude} ${p.acPhase??0}`:'';if(p.waveform==='pulse')return `DC ${dc}${ac} PULSE(${p.low??0} ${p.high??1} ${p.delay??0} ${p.rise??'1n'} ${p.fall??'1n'} ${p.width??'5n'} ${p.period??'10n'})`;if(p.waveform==='sin')return `DC ${dc}${ac} SIN(${p.offset??0} ${p.amplitude??1} ${p.frequency??'1k'} ${p.delay??0} ${p.damping??0} ${p.phase??0})`;if(p.waveform==='pwl')return `DC ${dc}${ac} PWL(${p.pwlPoints??'0 0 1n 1'})`;return `DC ${dc}${ac}`;}
export function spiceForCell(project,cell){const nets=resolveNets(cell),cards=[];const used=new Set();for(const c of cell.components){const s=symbol(c.type,c.parameters);if(!s.electrical||!s.prefix)continue;const ref=cleanToken(c.reference||s.prefix+cards.length);if(used.has(ref.toLowerCase()))throw Error('位号重复：'+ref);used.add(ref.toLowerCase());const n=name=>cleanToken(nets.pinNets[key(c.id,name)]??c.netHints?.[name]??'0'),p=c.parameters,t=c.type;
 if(['resistor','variable-resistor','capacitor','variable-capacitor','inductor','inductor-large','variable-inductor'].includes(t))cards.push(`${ref} ${n('1')} ${n('2')} ${cleanToken(p.value)}`);
 else if(['voltage-source','current-source','battery','current-sensor','supply-stimulus'].includes(t))cards.push(`${ref} ${n('+')} ${p.implicitGround?'0':n('-')} ${t==='current-sensor'?'0':sourceValue(p)}`);
 else if(['nmos','pmos','depletion-nmos','depletion-pmos','ndmos','pdmos'].includes(t)){const bulk=p.bulk==='external'?n('B'):p.bulk==='global'?cleanToken(p.bulkNet??(t.includes('pmos')?'VDD':'0')):n('S');cards.push(`${p.invocation==='subcircuit'&&!ref.startsWith('X')?'X'+ref:ref} ${n('D')} ${n('G')} ${n('S')} ${bulk} ${cleanToken(p.model)} W=${cleanToken(p.W)} L=${cleanToken(p.L)}${p.M?' M='+cleanToken(p.M):''}`);}
 else if(['npn','pnp'].includes(t))cards.push(`${ref} ${n('C')} ${n('B')} ${n('E')} ${cleanToken(p.model)}`);
 else if(['diode','zener'].includes(t))cards.push(`${ref} ${n('A')} ${n('K')} ${cleanToken(p.model)}`);
 else if(['vcvs','vccs'].includes(t))cards.push(`${ref} ${n('+')} ${n('-')} ${n('CP')} ${n('CN')} ${cleanToken(p.gain??'1')}`);
 else if(['cccs','ccvs'].includes(t))cards.push(`${ref} ${n('+')} ${n('-')} ${cleanToken(p.control)} ${cleanToken(p.gain??'1')}`);
 else if(t==='cell-instance'){const target=project.cells.find(cell=>cell.id===p.cellId);if(!target)throw Error('引用的单元不存在。');cards.push(`${ref.startsWith('X')?ref:'X'+ref} ${target.ports.map(port=>n(port.name)).join(' ')} ${cleanToken(target.name)}`);}
 else if(p.model&&p.invocation==='subcircuit'&&t!=='external-block'&&t!=='transformer'){cards.push(`${ref.startsWith('X')?ref:'X'+ref} ${(p.portOrder??s.pins.map(pin=>pin.name)).map(n).join(' ')} ${cleanToken(p.model)}`);}
 else if(c.card){const words=c.card.trim().split(/\s+/);words[0]=ref;for(const [i,pinName] of (c.cardPins??[]).entries())words[i+1]=n(pinName);for(const [i,parameter] of Object.entries(c.cardParameters??{}))words[Number(i)]=cleanToken(p[parameter]);cards.push(words.join(' '));}
 else if(['opamp','opamp-small','voltage-amplifier'].includes(t))cards.push(`E${ref} ${n('OUT')} 0 ${n('+')} ${n('-')} ${cleanToken(p.gain??'100k')}`);
 else if(t==='external-block'||t==='transformer')cards.push(`${ref.startsWith('X')?ref:'X'+ref} ${s.pins.map(pin=>n(pin.name)).join(' ')} ${cleanToken(p.model??'CS_XFMR')}`);
 else if(t==='closed-switch'||t==='open-switch'||t==='simple-switch')cards.push(`R${ref} ${n('P')} ${n('N')} ${t==='closed-switch'?'1m':'1T'}`);
 else throw Error('此图形元件尚未绑定可仿真的实现：'+ref+'。请为它绑定自包含的 SPICE 子电路。');
 }return cards.join('\n');}
export function netlist(project){assertNoHierarchyCycle(project);const root=project.cells.find(c=>c.id===project.topCellId);const globals=[...new Set(project.cells.flatMap(c=>c.wires.filter(w=>w.rail&&w.scope==='global').map(w=>w.netName).concat(c.components.filter(p=>p.type==='vdd-port'&&p.parameters.scope!=='local').map(p=>p.parameters.name))).filter(Boolean))];let result='* Circuit Studio independent editor\n'+(globals.length?'.global '+globals.map(cleanToken).join(' ')+'\n':'')+spiceForCell(project,root)+'\n';for(const cell of project.cells.filter(c=>c.id!==root.id))result+=`.subckt ${cleanToken(cell.name)} ${cell.ports.map(p=>cleanToken(p.name)).join(' ')}\n${spiceForCell(project,cell)}\n.ends ${cleanToken(cell.name)}\n`;result+=(project.subcircuits??'')+'\n'+(project.models??'');return result+'\n.end\n';}
export function boundsFor(cell){const points=cell.components.filter(c=>!c.hidden).flatMap(c=>{const b=symbol(c.type,c.parameters).bounds;return [{x:b.x,y:b.y},{x:b.x+b.width,y:b.y+b.height},{x:b.x,y:b.y+b.height},{x:b.x+b.width,y:b.y}].map(p=>transformPoint(c,p)).concat([{x:c.x+70,y:c.y+35}]);}).concat(cell.wires.flatMap(w=>w.points),cell.notes.flatMap(n=>[n.position,{x:n.position.x+String(n.text).length*(n.size??14)*.7,y:n.position.y+(n.size??14)}]));if(!points.length)return {x:-200,y:-150,width:400,height:300};const xs=points.map(p=>p.x),ys=points.map(p=>p.y);return {x:Math.min(...xs)-25,y:Math.min(...ys)-25,width:Math.max(...xs)-Math.min(...xs)+50,height:Math.max(...ys)-Math.min(...ys)+50};}
