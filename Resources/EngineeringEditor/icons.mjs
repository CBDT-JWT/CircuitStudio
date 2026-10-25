// Original small UI vectors, separate from the schematic symbols.
export function installToolIcons(){
 const paths={
  select:'M5 3L18 12L12 13L9 19Z',
  library:'M4 4H10V10H4ZM14 4H20V10H14ZM4 14H10V20H4ZM14 14H20V20H14Z',
  wire:'M4 5H10V17H20M4 3V7M18 15V19',
  rail:'M4 5H20M7 5V14M12 5V19M17 5V14',
  text:'M4 5H20M12 5V20M8 20H16',
  undo:'M8 5L3 10L8 15M3 10H14C21 10 21 20 14 20',
  redo:'M16 5L21 10L16 15M21 10H10C3 10 3 20 10 20',
  fit:'M4 9V4H9M15 4H20V9M20 15V20H15M9 20H4V15M9 12H15M12 9V15',
 };
 for(const button of document.querySelectorAll('#tools>.icon')){
  const d=paths[button.dataset.action];if(d)button.innerHTML=`<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
 }
}
