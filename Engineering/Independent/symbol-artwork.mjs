// Circuit Studio's renderer for separately licensed vector artwork. No upstream
// rendering or editor implementation is imported. See graphics/SOURCE.json.
import {artwork} from './symbol-artwork-data.mjs';
const xml=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
const point=p=>`${p.x},${p.y}`;
export function drawPrimitive(p){
 const st=p.style??{},width=st.strokeRole==='emphasis'?2.4:st.strokeRole==='ground'?2.906977:st.strokeRole==='normal'?1.6:1;
 const fill=p.fill==='foreground'?'currentColor':p.fill??'none';
 const style=` fill="${xml(fill)}" stroke="${p.stroke==='none'?'none':'currentColor'}" stroke-width="${width}" stroke-linecap="${st.lineCap??'square'}" stroke-linejoin="${st.lineJoin??'miter'}"${st.miterLimit?` stroke-miterlimit="${st.miterLimit}"`:''}`;
 if(p.kind==='line')return `<line x1="${p.from.x}" y1="${p.from.y}" x2="${p.to.x}" y2="${p.to.y}"${style}/>`;
 if(p.kind==='circle')return `<circle cx="${p.center.x}" cy="${p.center.y}" r="${p.radius}"${style}/>`;
 if(p.kind==='polygon'||p.kind==='polyline')return `<${p.kind} points="${p.points.map(point).join(' ')}"${style}/>`;
 if(p.kind==='path')return `<path d="${xml(p.data)}"${style}/>`;
 throw Error('Unsupported vector primitive: '+p.kind);
}
const nameFor=(id,name)=>{
 if(['opamp','opamp-small','fdamp','fdamp-small','differential-transconductance','comparator','fd-comparator'].includes(id))return ({'IN+':'+','IN-':'-'})[name]??name;
 if(['voltage-amplifier','adc','dac'].includes(id))return name==='IN'?'+':name;
 if(id==='transconductance')return ({A:'+',Y:'OUT'})[name]??name;
 if(['and','or','nand','nor','xor','xnor'].includes(id))return name==='Y'?'OUT':'IN'+('ABCD'.indexOf(name)+1);
 if(['inverter','buffer','delay'].includes(id))return name==='Y'?'OUT':name;
 if(id.startsWith('dff'))return ({CK:'CLK',QBAR:'QN',RST:'RESET'})[name]??name;
 if(['adder','multiplier'].includes(id))return ({A:'IN',B:'IN2',Y:'OUT'})[name]??name;
 if(['integrator','unit-delay','discrete-integrator','quantizer'].includes(id))return ({A:'IN',Y:'OUT'})[name]??name;
 if(['open-switch','closed-switch','simple-switch'].includes(id))return name==='1'?'P':'N';
 if(id==='spdt-switch')return ({COM:'P',A:'N',B:'N2'})[name]??name;
 if(id==='center-tapped-coil'||id==='t-coil')return name==='3'?'CT':name;
 if(id==='transformer')return ({'P-':'P1','P+':'P2','S-':'P3','S+':'P4'})[name]??name;
 if(id.startsWith('variable-'))return name==='P1'?'1':name==='P2'?'2':name;
 if(['bias-port','cell-pin','vdd-port'].includes(id))return '1';
 return name;
};
export function referenceGraphic(id,parameters={}){
 const arity=['and','or','nand','nor','xor','xnor'].includes(id)?Math.max(2,Math.min(4,Number(parameters.inputs)||2)):2;
 const a=artwork[id+(arity>2?':'+arity:'')];if(!a)return null;
 const def=a.symbol;
 if(!def){
  const [x,y,width,height]=a.libraryViewBox.split(' ').map(Number);
  return {ink:a.libraryInk,bounds:{x,y,width,height},pins:id==='power-rail'?[{name:'1',x:0,y:18,direction:'south',hidden:false}]:[],sourceID:a.sourceID};
 }
 const variantID=parameters.variant??(parameters.bulk==='external'?null:def.defaultVariantId);
 const variant=def.variants?.find(v=>v.id===variantID),hiddenParts=new Set(variant?.hiddenPrimitiveParts??[]),hiddenPins=new Set(variant?.hiddenPinNames??[]);
 const primitives=[...def.primitives.filter(p=>!hiddenParts.has(p.part)),...(variant?.additionalPrimitives??[])];
 const pins=def.pins.filter(p=>!hiddenPins.has(p.name)).map(p=>({name:nameFor(id,p.name),x:p.at.x,y:p.at.y,direction:p.direction??'south',hidden:false}));
 // These are node bindings (as in the reference's source properties), not
 // extra stems or decorative control pins on the textbook symbol.
 for(const name of (['vcvs','vccs'].includes(id)?['CP','CN']:['voltage-amplifier','transconductance','adc','dac'].includes(id)?['-']:[]))pins.push({name,x:0,y:0,direction:'west',hidden:true,virtual:true,defaultNet:['-'].includes(name)?'0':undefined});
 const defaultDrawing=(!parameters.variant||parameters.variant===def.defaultVariantId)&&parameters.bulk!=='external';
 return {ink:defaultDrawing&&a.canvasInk?a.canvasInk:primitives.map(drawPrimitive).join(''),uprightInk:defaultDrawing?a.uprightInk??'':'',pinLabels:defaultDrawing?a.pinLabels??[]:[],pins,bounds:{...def.viewBox},hideReference:def.labelVisibility==='hidden',sourceID:a.sourceID};
}
export function referenceLibrarySVG(id){
 const a=artwork[id];if(!a)return '';
 return `<svg viewBox="${a.libraryViewBox}" fill="none" stroke="currentColor" aria-hidden="true">${a.libraryInk}</svg>`;
}
export function referenceLibraryInk(id){return artwork[id]?.libraryInk??'';}
