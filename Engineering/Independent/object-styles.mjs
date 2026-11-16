export function normalizeColor(value){
 if(value===null||value==='')return null;
 const raw=String(value).trim().toLowerCase();
 if(/^#[0-9a-f]{3}$/.test(raw))return '#'+[...raw.slice(1)].map(c=>c+c).join('');
 if(/^#[0-9a-f]{6}$/.test(raw))return raw;
 throw Error('请输入 #RRGGBB 或 #RGB 格式的颜色。');
}
export function colorForPicker(value,fallback='#000000'){
 try{return normalizeColor(value??null)??fallback;}catch{return fallback;}
}
export const lineStyleOf=object=>object.lineStyle==='dashed'?'dashed':'solid';
export const dashArrayFor=object=>lineStyleOf(object)==='dashed'?'7 5':'none';
export function selectedStyleObjects(cell,ids){
 return [...cell.components.map(object=>({kind:'component',object})),...cell.wires.map(object=>({kind:'wire',object})),...(cell.notes??[]).map(object=>({kind:'text',object}))].filter(({object})=>ids.has(object.id));
}
export function selectionStyleSummary(cell,ids){
 const objects=selectedStyleObjects(cell,ids),strokes=objects.filter(o=>o.kind!=='text');
 const colors=new Set(objects.map(({object})=>object.color??null)),lines=new Set(strokes.map(({object})=>lineStyleOf(object)));
 return {count:objects.length,strokeCount:strokes.length,color:colors.size===1?[...colors][0]:undefined,lineStyle:lines.size===1?[...lines][0]:undefined};
}
export function applySelectionStyle(cell,ids,patch){
 const objects=selectedStyleObjects(cell,ids);if(!objects.length)throw Error('请先选择要修改样式的对象。');
 const hasColor=Object.hasOwn(patch,'color'),color=hasColor?normalizeColor(patch.color):undefined;
 if(Object.hasOwn(patch,'lineStyle')&&!['solid','dashed'].includes(patch.lineStyle))throw Error('请选择实线或虚线。');
 let count=0;
 for(const {kind,object} of objects){
  let touched=false;
  if(hasColor){object.color=color;if(kind==='component'){object.textColor=null;object.referenceColor=null;object.valueColor=null;}touched=true;}
  if(Object.hasOwn(patch,'lineStyle')&&kind!=='text'){object.lineStyle=patch.lineStyle;touched=true;}
  if(touched)count++;
 }
 return count;
}
export function commitSelectionStyle(store,ids,patch){
 const objects=selectedStyleObjects(store.cell,ids);if(!objects.length)throw Error('请先选择要修改样式的对象。');
 const next={...patch};if(Object.hasOwn(next,'color'))next.color=normalizeColor(next.color);
 if(Object.hasOwn(next,'lineStyle')&&!['solid','dashed'].includes(next.lineStyle))throw Error('请选择实线或虚线。');
 const changes=objects.filter(({kind,object})=>Object.hasOwn(next,'color')&&((object.color??null)!==next.color||kind==='component'&&[object.textColor,object.referenceColor,object.valueColor].some(v=>v!=null))||Object.hasOwn(next,'lineStyle')&&kind!=='text'&&lineStyleOf(object)!==next.lineStyle);
 if(!changes.length)return 0;
 store.transact('修改选区样式',(_,cell)=>applySelectionStyle(cell,ids,next));return changes.length;
}
