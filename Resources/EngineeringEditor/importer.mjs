import {newProject,emptyCell,makeComponent,uid,connectPins,routeOrthogonal,simplify,snap,clone,validateProject,resolveNets,samePoint} from './model.mjs';
import {symbol,canonical,pinsFor,legacyPinsFor,transformPoint} from './symbols.mjs';
const length=(value)=>{const m=String(value).match(/^([\d.eE+-]+)(meg|[fpnumkgt])?/i);if(!m)return NaN;return Number(m[1])*({f:1e-15,p:1e-12,n:1e-9,u:1e-6,m:1e-3,k:1e3,meg:1e6,g:1e9,t:1e12}[m[2]?.toLowerCase()]??1);};
function sourceParameters(tail){const p={dc:'0',waveform:'dc',acMagnitude:'',acPhase:'0'};const dc=tail.match(/(?:^|\s)DC\s+([^\s]+)/i);if(dc)p.dc=dc[1];else if(tail.trim()&&!/^(SIN|PULSE|PWL|AC)\b/i.test(tail))p.dc=tail.trim().split(/\s/)[0];const ac=tail.match(/\bAC\s+(\S+)(?:\s+([^\s()]+))?/i);if(ac){p.acMagnitude=ac[1];p.acPhase=ac[2]&&/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(ac[2])?ac[2]:'0';}const waveform=tail.match(/\b(SIN|PULSE|PWL)\s*\(([^)]+)\)/i);if(waveform){p.waveform=waveform[1].toLowerCase();const values=waveform[2].trim().split(/[\s,]+/);if(p.waveform==='sin')for(const [i,k] of ['offset','amplitude','frequency','delay','damping','phase'].entries())p[k]=values[i]??'0';if(p.waveform==='pulse')for(const [i,k] of ['low','high','delay','rise','fall','width','period'].entries())p[k]=values[i]??'0';if(p.waveform==='pwl')p.pwlPoints=waveform[2];}return p;}
function cardsFromSource(source){const result=[];for(const raw of source.replace(/\r/g,'').split('\n')){const l=raw.trim();if(!l||l.startsWith('*'))continue;if(l.startsWith('+')){if(!result.length)throw Error('SPICE 续行没有前一条指令。');result[result.length-1]+=' '+l.slice(1).trim();}else result.push(l);}return result;}
export function parseSpice(source,{name='导入的电路',positions={},definitions={}}={}){
 if(source.length>8e6||source.includes('\0'))throw Error('SPICE 文件无效或过大。');const project=newProject(name),cell=project.cells[0];const lines=cardsFromSource(source),root=[],models=[],subs=[];let subDepth=0;
 for(const line of lines){if(/^\.subckt\b/i.test(line)){subDepth++;const fields=line.split(/\s+/);definitions[fields[1]]??={count:fields.slice(2).filter(t=>!t.includes('=')&&t.toLowerCase()!=='params:').length,ports:fields.slice(2).filter(t=>!t.includes('=')&&t.toLowerCase()!=='params:')};subs.push(line);continue;}if(subDepth){subs.push(line);if(/^\.ends\b/i.test(line))subDepth--;continue;}if(/^\.end\b/i.test(line))continue;if(line.startsWith('.')){if(/^\.(?:model|param|func|global|temp)\b/i.test(line))models.push(line);else if(!/^\.(?:tran|ac|dc|op|save|print|plot|options|ic|nodeset)\b/i.test(line))throw Error('不支持的 SPICE 指令：'+line.split(/\s/)[0]);continue;}root.push(line);}
 for(const [index,line] of root.entries()){
  const f=line.split(/\s+/),ref=f[0],letter=ref[0].toUpperCase();let type,parameters={},pinNames=[],nodeCount=2,parameterIndex={},parameterPrefixes={},hidden=false;
  if('RCL'.includes(letter)){type={R:'resistor',C:'capacitor',L:'inductor'}[letter];pinNames=['1','2'];parameters.value=f[3];parameterIndex={3:'value'};}
  else if('VI'.includes(letter)){type=letter==='V'?'voltage-source':'current-source';pinNames=['+','-'];parameters=sourceParameters(f.slice(3).join(' '));if(letter==='V'&&/^V(?:DD|SS|CC|EE)$/i.test(ref)&&f[2]==='0'&&parameters.waveform==='dc'){type='supply-stimulus';parameters.implicitGround=true;}else if(letter==='V'&&length(parameters.dc)===0&&parameters.waveform==='dc'&&!parameters.acMagnitude&&f[2]!=='0')type='current-sensor';}
  else if(letter==='M'){type=/pmos|pfet/i.test(f[5])?'pmos':'nmos';pinNames=['D','G','S','B'];nodeCount=4;parameters={model:f[5],bulk:f[4]===f[3]?'source':'external'};parameterIndex={5:'model'};for(const field of f.slice(6)){const [k,v]=field.split('=');if(v)parameters[k.toUpperCase()]=v;}parameters.W??='20u';parameters.L??='180n';}
  else if(letter==='Q'){type=/pnp/i.test(f[4])?'pnp':'npn';pinNames=['C','B','E'];nodeCount=3;parameters.model=f[4];parameterIndex={4:'model'};}
  else if(letter==='D'){type='diode';pinNames=['A','K'];parameters.model=f[3];parameterIndex={3:'model'};}
  else if('EG'.includes(letter)){type=letter==='E'?'vcvs':'vccs';pinNames=['+','-','CP','CN'];nodeCount=4;parameters.gain=f[5];parameterIndex={5:'gain'};}
  else if('FH'.includes(letter)){type=letter==='F'?'cccs':'ccvs';pinNames=['+','-'];parameters.control=f[3];parameters.gain=f[4];parameterIndex={3:'control',4:'gain'};}
  else if(letter==='X'){const targetIndex=f.findIndex((t,i)=>i>0&&(t.includes('=')||t.toLowerCase()==='params:'));const end=targetIndex<0?f.length:targetIndex;const target=f[end-1];nodeCount=end-2;const def=definitions[target]??{count:nodeCount};if(def.count!==nodeCount)throw Error(ref+' 的子电路端口数不匹配。');pinNames=def.ports??Array.from({length:nodeCount},(_,i)=>'P'+(i+1));type=target==='COURSE_XFMR'?'transformer':'external-block';parameters={model:target,cellName:target.replace(/^COURSE_/,'').slice(0,14),ports:pinNames};parameterIndex={[end-1]:'model'};for(let i=end;i<f.length;i++){const m=f[i].match(/^([^=]+)=(.+)$/);if(m){parameters[m[1]]=m[2];parameterIndex[i]=m[1];parameterPrefixes[i]=m[1]+'=';}}}
  else if(letter==='K'){type='mutual-coupling';nodeCount=0;pinNames=[];hidden=true;parameters={value:f[3]};parameterIndex={3:'value'};}
  else if(letter==='T'){type='external-block';nodeCount=4;pinNames=['P1','P2','P3','P4'];parameters={ports:pinNames,cellName:'T-line'};}
  else if(letter==='B'){type='behavioral-source';pinNames=['+','-'];}
  else if(letter==='S'){type='voltage-switch';nodeCount=4;pinNames=['P','N','CP','CN'];parameters.model=f[5];parameterIndex={5:'model'};}
  else if(letter==='W'){type='controlled-switch';pinNames=['P','N'];parameters={control:f[3],model:f[4]};parameterIndex={3:'control',4:'model'};}
  else throw Error('尚不支持的 SPICE 元件：'+ref);
  if(f.length<nodeCount+2)throw Error('元件端口不完整：'+ref);const place=positions[ref]??[index%6*120,Math.floor(index/6)*150];const c=makeComponent(type,place[0],place[1],ref,parameters);c.rotation=place[2]??0;c.flipX=place[3]==='x';c.flipY=place[3]==='y';c.card=line;c.cardPins=pinNames;c.cardParameters=parameterIndex;c.cardParameterPrefixes=parameterPrefixes;c.hidden=hidden;c.showValue=['R','C','L'].includes(letter);c.showReference=!hidden;
  for(let i=0;i<nodeCount;i++)c.netHints[pinNames[i]]=f[i+1];if(type==='transformer'&&pinNames[0]!=='P1'){c.parameters.ports=['P1','P2','P3','P4'];c.netHints=Object.fromEntries(c.parameters.ports.map((p,i)=>[p,f[i+1]]));c.cardPins=c.parameters.ports;}
  cell.components.push(c);
 }
 project.models=models.join('\n');project.subcircuits=subs.join('\n');return project;
}
export function routeImportedProject(project){
 for(const cell of project.cells){const original=cell.components.slice(),groups=new Map(),virtualTargets=[];cell.wires=[];cell.components=original.filter(c=>!c.generatedGround);
  for(const c of original){if(c.generatedGround||c.hidden)continue;for(const p of pinsFor(c)){if(p.virtual){if(c.netHints[p.name])virtualTargets.push({component:c,p,name:c.netHints[p.name]});continue;}if(p.hidden)continue;const name=c.netHints[p.name];if(!name)continue;const list=groups.get(name)??[];list.push({component:c,p,reference:{instanceId:c.id,pinName:p.name}});groups.set(name,list);}}
  for(const t of virtualTargets){
   const target=groups.get(t.name)?.[0];
   if(target){t.component.pinBindings??={};t.component.pinBindings[t.p.name]={...target.reference};}
   else if(t.name!=='0')throw Error('控制节点 '+t.name+' 没有实际电路网络，原工程未改动。');
  }
  // Ground glyphs are local attachments. They do not substitute for signal
  // routes; every non-ground signal group receives physical conductors below.
  for(const t of groups.get('0')??[]){if(['supply-stimulus','ground'].includes(t.component.type))continue;const center={x:t.component.x,y:t.component.y};let end={x:t.p.x,y:t.p.y+30};if(t.p.y<center.y)end={x:t.p.x+(t.p.x>=center.x?40:-40),y:center.y+40};else if(t.p.x!==center.x)end={x:t.p.x+(t.p.x>center.x?20:-20),y:t.p.y+30};let g=original.filter(c=>c.type==='ground'&&!c.generatedGround&&Math.abs(c.x-end.x)<15&&Math.abs(c.y-end.y)<80).sort((a,b)=>Math.hypot(a.x-end.x,a.y-end.y)-Math.hypot(b.x-end.x,b.y-end.y))[0];if(g){const pin=pinsFor(g)[0];end={x:pin.x,y:pin.y};}else{g=makeComponent('ground',end.x,end.y+10,'',{});g.generatedGround=true;g.netHints={'0':'0'};cell.components.push(g);}const points=t.p.y<center.y?[t.p,{x:t.p.x,y:t.p.y-10},{x:end.x,y:t.p.y-10},end]:[t.p,{x:end.x,y:t.p.y},end];cell.wires.push({id:uid(),points:simplify(points),start:t.reference,end:{instanceId:g.id,pinName:'0'},netName:'0'});}
  for(const [name,targets] of groups){if(name==='0'||targets.length<2)continue;const ordered=targets.slice().sort((a,b)=>a.p.x-b.p.x||a.p.y-b.p.y);for(let i=1;i<ordered.length;i++){const connected=ordered.slice(0,i).sort((a,b)=>(Math.abs(a.p.x-ordered[i].p.x)+Math.abs(a.p.y-ordered[i].p.y))-(Math.abs(b.p.x-ordered[i].p.x)+Math.abs(b.p.y-ordered[i].p.y)))[0];connectPins(cell,[connected.reference,ordered[i].reference],{netName:name});}}
 }
 return validateProject(project);
}
export function importedNetErrors(project){const issues=[];for(const cell of project.cells){const nets=resolveNets(cell);const actualByExpected=new Map(),expectedByActual=new Map();for(const c of cell.components){for(const p of pinsFor(c)){if(p.hidden||!c.netHints[p.name])continue;const wanted=c.netHints[p.name],actual=nets.pinNets[`${c.id}:${p.name}`];(actualByExpected.get(wanted)??actualByExpected.set(wanted,new Set()).get(wanted)).add(actual);(expectedByActual.get(actual)??expectedByActual.set(actual,new Set()).get(actual)).add(wanted);}}for(const [name,groups] of actualByExpected)if(groups.size!==1)issues.push('断开网络 '+name);for(const [name,groups] of expectedByActual)if(groups.size!==1)issues.push('误连网络 '+[...groups].join('/'));}return issues;}
export function prepareCourse(example,layouts){let source=example.netlist+'\n'+example.models;const definitions={};for(const [name,definition] of Object.entries(example.externalModels)){const ports=Array.from({length:definition.count},(_,i)=>'P'+(i+1));definitions[name]={...definition,ports};source+=`\n.subckt ${name} ${ports.join(' ')}\n${definition.body.replace(/\{(\d+)\}/g,(_,i)=>ports[Number(i)])}\n.ends ${name}\n`;}
 const positions=clone(layouts[example.assignmentID]);if(!positions)throw Error('课程布局不存在：'+example.assignmentID);for(const [ref,place] of Object.entries(positions))if(/^XTR/.test(ref))place[2]=270;
 if(/^A2-19-(?:1[3-8])$/.test(example.id))positions.MP[3]='y';
 if(example.id==='A2-18-dual-02')Object.assign(positions,{R1:[120,20,270],L1:[280,100]});
 if(example.id==='A2-20-06')Object.assign(positions,{C3:[140,160],C4:[390,160],C1:[270,260],C2:[520,260],RREF1:[880,200],RREF2:[1000,200]});
 const project=parseSpice(source,{name:example.title,positions,definitions});project.courseCaseId=example.id;project.modelPacket=example.modelPacket;routeImportedProject(project);return project;}
const nativeKinds={polarizedCapacitor:'capacitor',voltageSource:'voltage-source',acVoltage:'voltage-source',pulseSource:'voltage-source',currentSource:'current-source',opAmp:'opamp',vdd:'vdd-port',vss:'vdd-port',port:'bias-port',largeInductor:'inductor-large',powerRail:'vdd-port',biasPort:'bias-port',cellPin:'cell-pin',noConnect:'no-connect',opAmpSmall:'opamp-small',fdAmp:'fdamp',fdAmpSmall:'fdamp-small',fdComparator:'fd-comparator',dFlipFlop:'dff',dFlipFlopReset:'dff-reset',dFlipFlopQ:'dff-q',delayCell:'delay',andGate:'and',orGate:'or',nandGate:'nand',norGate:'nor',xorGate:'xor',xnorGate:'xnor',depletionNMOS:'depletion-nmos',depletionPMOS:'depletion-pmos',led:'diode'};
function nativePin(type,name){
 if(type==='ground')return '1';
 if(['voltage-source','current-source','battery','vcvs','vccs','cccs','ccvs'].includes(type))return ({'+':'1','-':'2'})[name]??name;
 if(['diode','zener'].includes(type))return ({A:'1',K:'2'})[name]??name;
 if(['open-switch','closed-switch','controlled-switch','voltage-switch','simple-switch','spdt-switch','chopper'].includes(type))return ({P:'1',N:'2',N2:'3'})[name]??name;
 if(type==='transformer')return ({P1:'1',P2:'2',P3:'3',P4:'4'})[name]??name;
 if(['voltage-amplifier','transconductance','adc','dac'].includes(type))return name==='+'?'IN':name==='-'?null:name;
 if(['and','or','nand','nor','xor','xnor'].includes(type))return name.startsWith('IN')?'ABCD'[Number(name.slice(2))-1]:name;
 if(['adder','multiplier'].includes(type))return ({IN:'A',IN2:'B'})[name]??name;
 if(['inverter','buffer'].includes(type))return name==='A'?'IN':name;
 if(type.startsWith('dff'))return name==='QN'?'QB':name;
 return name;
}
export function importNativeProject(packet){
 const archive=packet.archive,old=archive?.circuit;
 if(!old||![1,2,3].includes(archive.formatVersion)||!Array.isArray(old.components)||!packet.terminalNets)throw Error('旧工程格式不完整，原文件未改动。');
 if(old.figures?.length||old.figureConnectors?.length||old.handDrawing||old.annotationDrawing)throw Error('此旧工程包含图解或手写图层，暂不能完整迁移；原文件已保留，请先导出这些图层。');
 const project=newProject(old.title),cell=project.cells[0];project.importedFrom='native-circuit';project.legacyArchive=clone(archive);
 let parsed;if(packet.spice){try{parsed=parseSpice(packet.spice);}catch{/* Invalid drafts may still be edited. */}}
 project.models=parsed?.models??old.modelLibrary??'';project.subcircuits=parsed?.subcircuits??'';
 const color=c=>c?'#'+String(c).replace(/^#/,''):null;
 for(const original of old.components){
  const type=nativeKinds[original.kind]??original.kind.replace(/[A-Z]/g,m=>'-'+m.toLowerCase()),parameters={...original.parameters};
  if(type==='voltage-source'||type==='battery'||type==='current-source'){
   parameters.dc=parameters.value??'0';parameters.acMagnitude=parameters.ac??'';parameters.acPhase='0';
   parameters.waveform=original.kind==='acVoltage'?'sin':original.kind==='pulseSource'?'pulse':'dc';
   if(parameters.waveform==='sin')parameters.offset=parameters.value??'0';
   if(parameters.waveform==='pulse')Object.assign(parameters,{low:parameters.value??'0',delay:'0',rise:'1n',fall:'1n'});
  }
  if(['vdd-port','bias-port','cell-pin'].includes(type))parameters.name=original.name;
  if(['nmos','pmos','depletion-nmos','depletion-pmos','ndmos','pdmos'].includes(type)&&parameters.NF){
   const multiplier=length(parameters.M??'1')*length(parameters.NF);if(Number.isFinite(multiplier)){parameters.M=String(multiplier);delete parameters.NF;}
  }
  let part;try{part=makeComponent(type,original.position.x,original.position.y,original.name,parameters);}catch{throw Error('暂不能迁移元件 '+original.name+'（'+original.kind+'）；原文件未改动。');}
  part.id=original.id;part.x=original.position.x;part.y=original.position.y;part.rotation=original.rotation??0;part.flipX=!!original.flipX;part.flipY=!!original.flipY;part.color=color(original.appearance?.color);
  part.showReference=!!original.showName&&!!symbol(type,parameters).prefix;part.showValue=!!original.showValue&&!!symbol(type,parameters).defaults.value;
  if(original.nameOffset){part.referenceOffset={x:original.nameOffset.x,y:original.nameOffset.y};part.labelLayoutManual=true;}
  if(original.valueOffset){part.valueOffset={x:original.valueOffset.x,y:original.valueOffset.y};part.labelLayoutManual=true;}
  const previous=packet.terminalNets[original.id.toUpperCase()]??packet.terminalNets[original.id]??{},used=new Set();
  for(const pin of symbol(type,part.parameters).pins){
   const name=nativePin(type,pin.name);if(name&&previous[name]){part.netHints[pin.name]=previous[name];used.add(name);}
   else if(pin.virtual&&pin.defaultNet)part.netHints[pin.name]=pin.defaultNet;
   else if(!pin.hidden)throw Error(original.name+' 的端口 '+pin.name+' 无法完整迁移；原文件未改动。');
  }
  for(const [name,net] of Object.entries(previous))if(!used.has(name)){
   const connected=Object.values(packet.terminalNets).reduce((count,parts)=>count+Object.values(parts).filter(n=>n===net).length,0)>1||Object.values(packet.wireNets??{}).includes(net);
   if(connected)throw Error(original.name+' 的已连接端口 '+name+' 尚不能迁移；原文件未改动。');
  }
  const prototype=parsed?.cells[0].components.find(c=>c.reference===original.name);
  if(prototype?.type===type&&prototype.card&&!['nmos','pmos'].includes(type)){
   for(const key of ['card','cardPins','cardParameters','cardParameterPrefixes'])part[key]=prototype[key];
   part.parameters={...prototype.parameters,...part.parameters};
  }
  cell.components.push(part);
 }
 routeImportedProject(project);
 const issues=importedNetErrors(project);if(issues.length)throw Error('旧工程连接检查未通过，原文件未改动：'+issues.join('；'));
 for(const label of old.labels??[]){
  if(label.isNet){cell.observedNames??=[];const native=String(label.text).replace(/[{}_]/g,'');cell.observedNames.push(native);}
  else cell.notes.push({id:label.id,position:{x:label.position.x,y:label.position.y},text:label.text,size:14,color:color(label.appearance?.color)});
 }
 project.simulationConfiguration={settings:old.simulation,supplies:Object.entries(packet.supplies??old.supplyVoltages??{VDD:'1.8',VSS:'0'}).map(([n,v])=>n+'='+v).join('\n'),models:''};
 return validateProject(project);
}
export function importProject(text){
 const raw=JSON.parse(text);if(raw.schema==='circuitstudio-native-import-v1')return importNativeProject(raw);
 if(raw.schema==='circuitstudio-project-v1'){
  validateProject(raw);
  if(raw.symbolGeometryVersion!==2){
   for(const c of raw.cells){
    const previous=resolveNets(c,legacyPinsFor);
    for(const part of c.components){
     const next=new Set(pinsFor(part).map(p=>p.name));part.netHints??={};
     for(const pin of legacyPinsFor(part)){
      const name=previous.pinNets[part.id+':'+pin.name];
      if(!next.has(pin.name)&&c.wires.some(w=>w.start?.instanceId===part.id&&w.start.pinName===pin.name||w.end?.instanceId===part.id&&w.end.pinName===pin.name))throw Error(part.reference+' 的端口定义发生变化，需重新指定端口；原工程未改动。');
      if(next.has(pin.name)&&name)part.netHints[pin.name]=name;
     }
    }
   }
   routeImportedProject(raw);raw.symbolGeometryVersion=2;raw.importedFrom='symbol-geometry-v1';
  }
  return validateProject(raw);
 }
 if(!Array.isArray(raw.documents)||!raw.documents.length)throw Error('不支持此工程格式。');
 // This adapter reads the user's current instances and connection graph. It
 // deliberately ignores embedded symbol assets and never executes source code.
 const source=(raw.source?.files??[]).map(f=>f.content?.text??'').join('\n');
 const extra=(raw.modelSources??[]).flatMap(s=>s.files??[]).map(f=>f.text??'').join('\n');
 const definitions=Object.fromEntries((raw.externalSubcircuitDefinitions??[]).map(d=>[d.name,{count:d.terminals.length,ports:d.terminals.map(t=>t.name),symbol:d.name.includes('XFMR')?'transformer':'external-block'}]));
 let parsed;try{parsed=parseSpice(source+'\n'+extra,{definitions});}catch(error){throw Error('旧工程的 SPICE 数据无法完整读取，已保留原文件：'+error.message);}
 const p=newProject(raw.name??'导入的工程');p.cells=[];p.importedFrom='icproj';p.models=parsed.models;p.subcircuits=parsed.subcircuits;
 const documentIDs=new Map(raw.documents.map(d=>[d.id,uid()]));p.topCellId=documentIDs.get(raw.topDocumentId)??documentIDs.values().next().value;p.activeCellId=p.topCellId;
 for(const d of raw.documents){
  const c=emptyCell(d.netlist?.name==='__flat__'?'主电路':d.name);c.id=documentIDs.get(d.id);c.ports=(d.netlist?.terminals??[]).map(t=>({name:t.name??t,direction:'passive'}));p.cells.push(c);
  const parent=new Map(),find=k=>{if(!parent.has(k))parent.set(k,k);if(parent.get(k)!==k)parent.set(k,find(parent.get(k)));return parent.get(k);},join=(a,b)=>parent.set(find(b),find(a));
  const endpoint=e=>e?.terminal?'t:'+e.terminal.join(':'):e?.junction?'j:'+e.junction:null;
  for(const route of d.routes??[]){const keys=[route.start,...(route.legs??[]),route.end].map(endpoint).filter(Boolean);for(const k of keys.slice(1))join(keys[0],k);}
  for(const group of d.connections?.unrouted??[]){const keys=group.map(endpoint).filter(Boolean);for(const k of keys.slice(1))join(keys[0],k);}
  for(const contact of d.connections?.contacts??[]){const keys=(Array.isArray(contact)?contact:[contact.start,contact.end]).map(endpoint).filter(Boolean);for(const k of keys.slice(1))join(keys[0],k);}
  const claims=new Map();for(const net of d.nets??[]){const at=endpoint(net.at);if(!at)continue;const evidence=(d.connectivityEvidence??[]).filter(e=>e.netId===net.id);const name=evidence.find(e=>e.kind==='name-claim')?.name??evidence.find(e=>e.sourceName)?.sourceName??d.importReference?.nets?.find(n=>n.id===net.id)?.name;if(name)claims.set(find(at),name);}
  let auto=1;const groupNames=new Map(),nameFor=k=>{const root=find(k);if(!groupNames.has(root))groupNames.set(root,claims.get(root)??'IMPORT_'+auto++);return groupNames.get(root);};
  for(const original of d.instances??[]){
   const prototype=parsed.cells[0].components.find(part=>part.reference===original.name);
   let type=prototype?.type??canonical(original.type);const external=(raw.externalSubcircuitDefinitions??[]).find(e=>e.id===original.target?.definitionId);
   const child=documentIDs.get(original.target?.documentId??original.target?.cellId);
   if(child)type='cell-instance';else if(external)type=external.name.includes('XFMR')?'transformer':'external-block';
   const defaults=raw.defaults?.instancesByType?.[original.type]??{};let parameters={...prototype?.parameters,...defaults.parameters,...original.parameters};if(original.target?.kind==='model'&&original.target.name)parameters.model=original.target.name;else if(defaults.target?.kind==='model'&&defaults.target.name)parameters.model=defaults.target.name;
   if(external)parameters={...parameters,ports:external.terminals.map(t=>t.name),model:external.name};
   if(child){const target=raw.documents.find(d=>documentIDs.get(d.id)===child);parameters={...parameters,cellId:child,cellName:target.name,ports:(target.netlist?.terminals??[]).map(t=>t.name??t)};}
   let geometry;try{geometry=symbol(type,parameters);}catch{throw Error('旧工程包含尚不能完整迁移的元件 '+original.name+'（'+original.type+'），原文件未改动。');}
   const coordinate=original.coordinate??[original.placement?.position?.x??0,original.placement?.position?.y??0];const part=makeComponent(type,coordinate[0],coordinate[1],original.name??'',parameters);
   if(prototype){part.card=prototype.card;part.cardPins=prototype.cardPins;part.cardParameters=prototype.cardParameters;part.cardParameterPrefixes=prototype.cardParameterPrefixes;}
   part.rotation=original.rotation??original.placement?.rotation??0;
   if(type==='transformer'&&external)part.rotation=270;
   const mirror=original.mirror??original.placement?.mirror;part.flipX=['horizontal','both'].includes(mirror);part.flipY=['vertical','both'].includes(mirror);
   const mapping=original.importProvenance?.terminalMapping??[];
   for(const pin of geometry.pins){const oldName=mapping.find(t=>t.pinName===pin.name)?.pinName??pin.name;part.netHints[pin.name]=type==='ground'?'0':nameFor('t:'+original.id+':'+oldName);}
   if(['vdd-port','power-rail','bias-port','cell-pin'].includes(type))part.parameters.name=original.parameters?.name??original.name??part.netHints[geometry.pins[0]?.name];
   c.components.push(part);
  }
  for(const annotation of d.annotations??[])if(annotation.kind==='text'&&annotation.text){const position=annotation.anchor?.position??{x:0,y:0};c.notes.push({id:uid(),position,text:annotation.text,size:14});}
 }
 routeImportedProject(p);const issues=importedNetErrors(p);if(issues.length)throw Error('旧工程迁移后连接检查未通过，原文件未改动：'+issues.join('；'));
 return validateProject(p);
}
