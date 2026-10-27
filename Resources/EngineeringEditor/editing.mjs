import {clone,uid,makeComponent,samePoint,simplify,routeOrthogonal} from './model.mjs';
import {pinsFor,symbol,transformPoint} from './symbols.mjs';

const containsPoint=(wire,p)=>wire.points.slice(1).some((b,i)=>{const a=wire.points[i];return Math.abs((p.x-a.x)*(b.y-a.y)-(p.y-a.y)*(b.x-a.x))<1e-5&&p.x>=Math.min(a.x,b.x)&&p.x<=Math.max(a.x,b.x)&&p.y>=Math.min(a.y,b.y)&&p.y<=Math.max(a.y,b.y);});
// Copy geometry verbatim. Only identities and coordinates change on insertion.
export function selectionPayload(cell,ids){
 const whole=cell.components.length>0&&cell.components.every(c=>ids.has(c.id));
 const wires=cell.wires.filter(w=>whole||ids.has(w.id)||(ids.has(w.start?.instanceId)&&ids.has(w.end?.instanceId)));
 return {schema:'circuitstudio-selection-v1',components:clone(cell.components.filter(c=>ids.has(c.id))),wires:clone(wires),notes:clone(cell.notes.filter(n=>ids.has(n.id))),junctions:clone((cell.junctions??[]).filter(p=>wires.some(w=>containsPoint(w,p))))};
}
export function insertPayload(cell,data,offset={x:30,y:30}){
 if(data?.schema!=='circuitstudio-selection-v1'||!Array.isArray(data.components)||!Array.isArray(data.wires))throw Error('剪贴板中没有电路对象。');
 const map=new Map(),selected=new Set();
 for(const object of [...data.components,...data.wires,...(data.notes??[])])map.set(object.id,uid());
 for(const source of data.components){const part=clone(source);part.id=map.get(source.id);part.x+=offset.x;part.y+=offset.y;
  const prefix=symbol(part.type,part.parameters).prefix;if(prefix){let i=1;while(cell.components.some(c=>c.reference===prefix+i))i++;part.reference=prefix+i;}
  for(const [name,binding] of Object.entries(part.pinBindings??{})){
   if(map.has(binding.instanceId))binding.instanceId=map.get(binding.instanceId);
   else if(map.has(binding.wireId))binding.wireId=map.get(binding.wireId);
   else if(binding.netName!=='0'){delete part.pinBindings[name];delete part.netHints[name];}
  }
  cell.components.push(part);selected.add(part.id);
 }
 for(const source of data.wires){const wire=clone(source);wire.id=map.get(source.id);wire.points=source.points.map(p=>({x:p.x+offset.x,y:p.y+offset.y}));for(const end of ['start','end'])if(wire[end])wire[end]=map.has(wire[end].instanceId)?{...wire[end],instanceId:map.get(wire[end].instanceId)}:null;cell.wires.push(wire);selected.add(wire.id);}
 for(const source of data.notes??[]){const note=clone(source);note.id=map.get(source.id);note.position={x:source.position.x+offset.x,y:source.position.y+offset.y};cell.notes.push(note);selected.add(note.id);}
 cell.junctions??=[];for(const p of data.junctions??[])cell.junctions.push({x:p.x+offset.x,y:p.y+offset.y});
 return selected;
}
function stretchEnd(points,next,atStart){
 if(!atStart)points.reverse();const old=points[0],second=points[1];if(samePoint(old,next)){if(!atStart)points.reverse();return;}
 points[0]={x:next.x,y:next.y};
 if(points.length===2){if(next.x!==second.x&&next.y!==second.y)points.splice(1,0,old.x===second.x?{x:next.x,y:second.y}:{x:second.x,y:next.y});}
 else if(old.x===second.x)second.x=next.x;else second.y=next.y;
 if(!atStart)points.reverse();
}
export function stretchWires(before,after,moved,translated=new Set()){
 const oldParts=new Map(before.components.map(c=>[c.id,c])),parts=new Map(after.components.map(c=>[c.id,c]));
 const endpoint=(wire,end)=>{const old=wire.points[end==='start'?0:wire.points.length-1],ref=wire[end];let id=ref?.instanceId,name=ref?.pinName;
  if(!id){for(const candidate of before.components.filter(c=>moved.has(c.id))){const pin=pinsFor(candidate).find(p=>!p.hidden&&samePoint(old,p));if(pin){id=candidate.id;name=pin.name;break;}}}
  if(!moved.has(id))return null;return pinsFor(parts.get(id)??oldParts.get(id)).find(p=>p.name===name)??null;
 };
 for(const wire of after.wires){if(translated.has(wire.id))continue;const original=before.wires.find(w=>w.id===wire.id);if(!original)continue;const start=endpoint(original,'start'),end=endpoint(original,'end');if(!start&&!end)continue;
  const a=original.points[0],b=original.points.at(-1);
  if(start&&end&&samePoint({x:start.x-a.x,y:start.y-a.y},{x:end.x-b.x,y:end.y-b.y}))wire.points=original.points.map(p=>({x:p.x+start.x-a.x,y:p.y+start.y-a.y}));
  else{const points=clone(original.points);if(start)stretchEnd(points,start,true);if(end)stretchEnd(points,end,false);wire.points=simplify(points);}
 }
}
export function translateSelection(cell,ids,delta,before=clone(cell)){
 const moved=new Set();for(const part of cell.components)if(ids.has(part.id)){const old=before.components.find(c=>c.id===part.id);part.x=old.x+delta.x;part.y=old.y+delta.y;moved.add(part.id);}
 for(const note of cell.notes)if(ids.has(note.id)){const old=before.notes.find(n=>n.id===note.id);note.position={x:old.position.x+delta.x,y:old.position.y+delta.y};}
 const translated=new Set();for(const wire of cell.wires)if(ids.has(wire.id)){const old=before.wires.find(w=>w.id===wire.id);wire.points=old.points.map(p=>({x:p.x+delta.x,y:p.y+delta.y}));
  const anchor=end=>{const ref=old[end],point=old.points[end==='start'?0:old.points.length-1];if(ref&&!ids.has(ref.instanceId)){const part=cell.components.find(c=>c.id===ref.instanceId);return part&&pinsFor(part).find(p=>p.name===ref.pinName);}for(const part of before.components.filter(c=>!ids.has(c.id))){const pin=pinsFor(part).find(p=>!p.hidden&&samePoint(p,point));if(pin)return pin;}return null;};
  const start=anchor('start'),end=anchor('end');if(start&&!samePoint(start,wire.points[0]))wire.points=[...routeOrthogonal(start,wire.points[0]),...wire.points.slice(1)];if(end&&!samePoint(end,wire.points.at(-1)))wire.points=[...wire.points,...routeOrthogonal(wire.points.at(-1),end).slice(1)];translated.add(wire.id);}
 cell.junctions=(before.junctions??[]).map(p=>before.wires.some(w=>translated.has(w.id)&&containsPoint(w,p))?{x:p.x+delta.x,y:p.y+delta.y}:clone(p));
 stretchWires(before,cell,moved,translated);
}
export function figureBetween(type,start,pointer,{shift=false,center=false}={}){
 let dx=pointer.x-start.x,dy=pointer.y-start.y;
 if(shift){if(['rectangle','ellipse'].includes(type)){const size=Math.max(Math.abs(dx),Math.abs(dy));dx=(Math.sign(dx)||1)*size;dy=(Math.sign(dy)||1)*size;}else{const angle=Math.round(Math.atan2(dy,dx)/(Math.PI/4))*Math.PI/4,length=Math.hypot(dx,dy);dx=Math.round(Math.cos(angle)*length);dy=Math.round(Math.sin(angle)*length);}}
 const part=makeComponent(type,0,0,'',['line','arrow'].includes(type)?{dx:String(dx*(center?2:1)),dy:String(dy*(center?2:1))}:{width:String(Math.max(1,Math.abs(dx)*(center?2:1))),height:String(Math.max(1,Math.abs(dy)*(center?2:1)))});
 part.x=start.x+(center?0:dx/2);part.y=start.y+(center?0:dy/2);return part;
}
export function figureHandles(part){
 const p=part.parameters;let points=[];
 if(['rectangle','ellipse'].includes(part.type)){const w=Number(p.width)||40,h=Number(p.height)||24;points=[['nw',-w/2,-h/2],['ne',w/2,-h/2],['se',w/2,h/2],['sw',-w/2,h/2],['n',0,-h/2],['e',w/2,0],['s',0,h/2],['w',-w/2,0]];}
 if(['line','arrow'].includes(part.type))points=[['start',-Number(p.dx??40)/2,-Number(p.dy??0)/2],['end',Number(p.dx??40)/2,Number(p.dy??0)/2]];
 if(part.type==='polarity')points=[['spacing',Number(p.spacing??64)/2,0]];
 if(part.type==='polyline')points=(p.points??[]).map((p,i)=>[String(i),p.x,p.y]);
 return points.map(([key,x,y])=>({key,...transformPoint(part,{x,y})}));
}
export function resizeFigure(part,key,point){
 const angle=-(part.rotation??0)*Math.PI/180,dx=point.x-part.x,dy=point.y-part.y,x=(dx*Math.cos(angle)-dy*Math.sin(angle))*(part.flipX?-1:1),y=(dx*Math.sin(angle)+dy*Math.cos(angle))*(part.flipY?-1:1),p=part.parameters;
 if(part.type==='polarity'){p.spacing=String(Math.max(24,Math.abs(x)*2));return;}
 if(part.type==='polyline'){p.points[Number(key)]={x,y};return;}
 if(['line','arrow'].includes(part.type)){
  const sign=key==='start'?-1:1,other={x:-sign*Number(p.dx??40)/2,y:-sign*Number(p.dy??0)/2},center=transformPoint(part,{x:(x+other.x)/2,y:(y+other.y)/2});p.dx=String(sign*(x-other.x));p.dy=String(sign*(y-other.y));part.x=center.x;part.y=center.y;return;
 }
 const w=Number(p.width)||40,h=Number(p.height)||24,oldX=key.includes('e')?w/2:-w/2,oldY=key.includes('s')?h/2:-h/2,resizeX=/[ew]/.test(key),resizeY=/[ns]/.test(key),center=transformPoint(part,{x:resizeX?(x-oldX)/2:0,y:resizeY?(y-oldY)/2:0});
 if(resizeX)p.width=String(Math.max(1,Math.abs(x+oldX)));if(resizeY)p.height=String(Math.max(1,Math.abs(y+oldY)));part.x=center.x;part.y=center.y;
}
