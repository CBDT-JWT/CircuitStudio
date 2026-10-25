/* Bundled offline; no raw HTML, remote images, scripts or network access. */
const parser=window.markdownit({html:false,linkify:true,typographer:false,breaks:true});
parser.renderer.rules.image=()=>'';
// Preserve math before Markdown's escape and emphasis parsing.
const equations=[];
function protectMath(source){
  equations.length=0;
  return source.replace(/(```[\s\S]*?```|`[^`\n]*`)|(\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([^\n]+?\\\)|(?<!\\)\$[^\n$]+?(?<!\\)\$)/g,(all,code,math)=>{
    if(code)return code;
    const index=equations.push(math)-1;return `CIRCUITAIMATHPLACEHOLDER${index}END`;
  });
}
window.renderCircuitMarkdown=text=>{
  const root=document.getElementById('content');root.innerHTML=parser.render(protectMath(String(text).slice(0,100000)));
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);const nodes=[];while(walker.nextNode())nodes.push(walker.currentNode);
  for(const node of nodes)node.textContent=node.textContent.replace(/CIRCUITAIMATHPLACEHOLDER(\d+)END/g,(_,i)=>equations[Number(i)]??'');
  window.renderMathInElement(root,{delimiters:[{left:'$$',right:'$$',display:true},{left:'\\[',right:'\\]',display:true},{left:'\\(',right:'\\)',display:false},{left:'$',right:'$',display:false}],throwOnError:false,trust:false,strict:'ignore',maxExpand:1000,maxSize:20});
  root.querySelectorAll('table').forEach(table=>{const wrap=document.createElement('div');wrap.className='table-scroll';table.replaceWith(wrap);wrap.append(table)});
  root.querySelectorAll('pre').forEach(pre=>{const button=document.createElement('button');button.className='copy';button.textContent='复制代码';button.onclick=()=>window.webkit?.messageHandlers?.markdown?.postMessage({copy:pre.querySelector('code')?.textContent??''});pre.append(button)});
  reportHeight();
};
function reportHeight(){window.webkit?.messageHandlers?.markdown?.postMessage({height:Math.ceil(document.getElementById('content').getBoundingClientRect().height+3)})}
new ResizeObserver(reportHeight).observe(document.getElementById('content'));document.fonts.ready.then(reportHeight);
