import {uid} from './model.mjs';
import {escapeXML} from './symbols.mjs';
export function installTextEditing(c){
 let editor=null;
 function finishTextEdit(apply=true){
  if(!editor)return;const state=editor;editor=null;c.app.textEditing=false;
  const text=state.form.querySelector('textarea').value,size=Number(state.form.elements.size.value),bold=state.bold,italic=state.italic;
  state.form.remove();
  if(apply&&(text.trim()||state.note||state.part)){
   c.current().store.transact(state.note||state.part?'编辑文字':'添加文字',(_,cell)=>{
    if(state.part){const part=cell.components.find(p=>p.id===state.part.id);if(state.label==='text'){part.parameters.text=text;part.parameters.fontSize=String(size);}else if(state.label==='reference'){if(part.reference)part.reference=text;else part.parameters.name=text;}else{const key='value' in part.parameters?'value':'dc';part.parameters[key]=text;}}
    else if(state.note){const note=cell.notes.find(n=>n.id===state.note.id);Object.assign(note,{text,size,bold,italic});}
    else cell.notes.push({id:uid(),text,position:state.position,size,bold,italic});
   });c.changed('文字已更新');
  }
  c.app.tool='select';c.render();document.getElementById('canvas').focus({preventScroll:true});
 }
 function beginTextEdit({note,part,label='text',position}={}){
  finishTextEdit();document.getElementById('properties').hidden=true;
  position??=note?.position??(part&&label!=='text'?c.labelPositions(c.cell())[part.id+':'+label]:part)??{x:0,y:0};
  const value=note?.text??(part?(label==='text'?part.parameters.text??'V_x':label==='reference'?part.reference||part.parameters.name:part.parameters.value??part.parameters.dc??''):'');
  const form=document.createElement('form');form.id='canvas-text-editor';form.className='glass';form.setAttribute('aria-label','原地编辑文字');
  form.innerHTML=`<div class="text-edit-tools"><button type="button" data-style="bold" aria-label="粗体" aria-pressed="${note?.bold!==false}"><b>B</b></button><button type="button" data-style="italic" aria-label="斜体" aria-pressed="${!!note?.italic}"><i>I</i></button><button type="button" data-script="_" aria-label="下标">x₂</button><button type="button" data-script="^" aria-label="上标">x²</button><input name="size" aria-label="文字字号" type="number" min="8" max="96" value="${note?.size??part?.parameters.fontSize??16}"><button type="button" data-cancel aria-label="取消编辑">取消</button><button class="primary" aria-label="完成文字编辑">完成</button></div><textarea aria-label="文字内容" placeholder="输入文字；V_{out} 支持下标">${escapeXML(value)}</textarea><small>Enter 完成 · Shift+Enter 换行 · Esc 取消</small>`;
  const pos=c.screen(position),width=Math.min(390,innerWidth-24);form.style.width=width+'px';form.style.left=Math.max(12,Math.min(innerWidth-c.app.drawer-width-12,pos.x-8))+'px';form.style.top=Math.max(60,Math.min(innerHeight-220,pos.y-42))+'px';document.getElementById('studio').append(form);
  const state=editor={form,note,part,label,position,bold:note?.bold!==false,italic:!!note?.italic};c.app.textEditing=true;
  const field=form.querySelector('textarea');const style=()=>{field.style.fontWeight=state.bold?'700':'400';field.style.fontStyle=state.italic?'italic':'normal';field.style.fontSize=Math.max(8,Math.min(96,Number(form.elements.size.value)||16))+'px';};style();form.elements.size.oninput=style;
  form.onsubmit=e=>{e.preventDefault();finishTextEdit();};form.onkeydown=e=>{e.stopPropagation();if(e.isComposing)return;if(e.key==='Escape'){e.preventDefault();finishTextEdit(false);}else if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();finishTextEdit();}};
  form.onclick=e=>{const button=e.target.closest('button');if(!button)return;if(button.hasAttribute('data-cancel'))finishTextEdit(false);if(button.dataset.style){const key=button.dataset.style;state[key]=!state[key];button.setAttribute('aria-pressed',String(state[key]));style();field.focus();}if(button.dataset.script){const a=field.selectionStart,b=field.selectionEnd;field.setRangeText(button.dataset.script+'{'+field.value.slice(a,b)+'}',a,b,'select');field.focus();}};
  requestAnimationFrame(()=>{field.focus();if(value)field.select();});
 }
 document.addEventListener('pointerdown',e=>{if(editor&&!editor.form.contains(e.target))finishTextEdit();},true);
 return {beginTextEdit,finishTextEdit};
}
