import {escapeXML} from './symbols.mjs';
import {commitSelectionStyle,colorForPicker,normalizeColor,selectedStyleObjects,selectionStyleSummary} from './object-styles.mjs';

export function installStyleEditing(c){
 const panel=document.getElementById('selection-style'),toggle=document.getElementById('selection-style-toggle');let lastKey='';
 const selectionKey=()=>[...c.app.selected].sort().join('|');
 function apply(patch){
  try{
   if(!commitSelectionStyle(c.current().store,c.app.selected,patch))return;
   c.changed('选区样式已更新');
   // Keep open parameter forms in sync without discarding their other edits.
   if(c.app.selected.size===1){const [{object}]=selectedStyleObjects(c.cell(),c.app.selected);for(const id of ['prop-color','object-color']){const field=document.getElementById(id);if(field)field.value=colorForPicker(object.color);}for(const id of ['prop-line-style','object-line-style']){const field=document.getElementById(id);if(field)field.value=object.lineStyle??'solid';}}
  }catch(error){const output=panel.querySelector('[data-style-error]');if(output)output.textContent=error.message;}
 }
 function renderSelectionStyle(){
  const objects=selectedStyleObjects(c.cell(),c.app.selected),summary=selectionStyleSummary(c.cell(),c.app.selected);
  toggle.disabled=!objects.length;
  panel.style.right=Math.max(12,c.app.drawer+12)+'px';panel.style.maxWidth=Math.max(180,innerWidth-c.app.drawer-24)+'px';
  const hidden=!objects.length||c.app.textEditing||c.app.pendingType||c.app.drawerBottom||c.app.stylePanelClosedFor===selectionKey();panel.hidden=!!hidden;
  const key=JSON.stringify([!!hidden,objects.map(({object})=>[object.id,object.color,object.textColor,object.referenceColor,object.valueColor,object.lineStyle])]);if(key===lastKey)return;lastKey=key;if(hidden)return;
  const color=colorForPicker(summary.color),mixed=summary.color===undefined?'多种颜色':summary.color===null?'默认颜色':summary.color;
  panel.innerHTML=`<div class="style-heading"><strong>选区样式</strong><span>${summary.count} 项</span><button type="button" data-style-close aria-label="关闭选区样式">×</button></div><form><label class="style-color-label" for="selection-color">颜色</label><div class="style-colors"><input id="selection-color" type="color" value="${color}" aria-label="选区颜色"><input id="selection-color-hex" value="${escapeXML(summary.color??'')}" placeholder="${escapeXML(mixed)}" aria-label="选区颜色十六进制" spellcheck="false"><button type="button" data-style-reset>默认</button></div><label for="selection-line-style">线型</label><select id="selection-line-style" aria-label="选区线型" ${summary.strokeCount?'':'disabled'}>${summary.lineStyle===undefined?`<option value="" selected>${summary.strokeCount?'多种线型':'文字无轮廓线型'}</option>`:''}<option value="solid" ${summary.lineStyle==='solid'?'selected':''}>实线</option><option value="dashed" ${summary.lineStyle==='dashed'?'selected':''}>虚线</option></select><output data-style-error role="status"></output></form>`;
  const hex=panel.querySelector('#selection-color-hex');
  const applyHex=()=>{try{const color=normalizeColor(hex.value);hex.setCustomValidity('');apply({color});}catch(error){hex.setCustomValidity(error.message);hex.reportValidity();}};
  panel.querySelector('form').onsubmit=e=>{e.preventDefault();applyHex();};
  hex.oninput=()=>hex.setCustomValidity('');hex.onchange=applyHex;
  panel.querySelector('#selection-color').onchange=e=>apply({color:e.target.value});
  panel.querySelector('[data-style-reset]').onclick=()=>apply({color:null});
  panel.querySelector('#selection-line-style').onchange=e=>{if(e.target.value)apply({lineStyle:e.target.value});};
  panel.querySelector('[data-style-close]').onclick=()=>{c.app.stylePanelClosedFor=selectionKey();renderSelectionStyle();};
 }
 function showSelectionStyle(){c.app.stylePanelClosedFor=null;lastKey='';renderSelectionStyle();}
 return {renderSelectionStyle,showSelectionStyle};
}
