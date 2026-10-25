#!/usr/bin/env python3
"""Prepare public SKY130 MOS packets with local micron-to-SI wrapper adaptation."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib,json,re,urllib.request
ROOT=Path(__file__).resolve().parents[1]
REPO='https://github.com/google/skywater-pdk-libs-sky130_fd_pr';COMMIT='f62031a1be9aefe902d6d54cddd6f59b57627436'
BASE=f'https://raw.githubusercontent.com/google/skywater-pdk-libs-sky130_fd_pr/{COMMIT}/'
cache=Path('/tmp/circuitstudio-sky130-source')
def get(name):
 p=cache/name
 if not p.exists():p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(urllib.request.urlopen(BASE+name,timeout=60).read())
 return p.read_text().replace('\r\n','\n')
families=['nfet_01v8','pfet_01v8','nfet_01v8_lvt','pfet_01v8_lvt']
paths=['models/parameters/invariant.spice','LICENSE']+[f'cells/{f}/sky130_fd_pr__{f}__tt.pm3.spice' for f in families]
with ThreadPoolExecutor(max_workers=4) as pool: source=dict(zip(paths,pool.map(get,paths)))
folder=ROOT/'Engineering/PDK/SKY130';folder.mkdir(exist_ok=True,parents=True);(folder/'LICENSE').write_text(source['LICENSE'])
packets=[]
for kind,group in [('svt',families[:2]),('lvt',families[2:])]:
 text='* Copyright 2020 The SkyWater PDK Authors; Apache-2.0. See LICENSE.\n'+f'* CIRCUIT_STUDIO_SKY130_{kind.upper()}_TT: official 1.8V MOS typical corner.\n* Original model coefficients retained; comments stripped for size.\n* Wrapper M geometry is converted explicitly from micrometres to SI.\n* No global .option scale: safe with SI-valued primitives and other PDKs.\n'
 records=[];geometry={}
 for family in group:
  name='sky130_fd_pr__'+family;path=f'cells/{family}/{name}__tt.pm3.spice';body=source[path]
  # Only family-specific invariant constants: avoid unrelated PDK devices/globals.
  params=[line.strip() for line in source['models/parameters/invariant.spice'].splitlines() if re.match(r'^\s*\+\s*'+re.escape(name)+r'__',line)]
  assert params
  globals=[line.strip() for line in source['models/parameters/invariant.spice'].splitlines() if re.match(r'^\s*\+\s*(?:hv|lv|lvhvt|lvt)_dlc_rotweak\s*=',line)]
  text+='\n.param\n'+'\n'.join(globals+params)+'\n'
  lines=[];adapted=0
  for line in body.splitlines():
   if not line.strip() or line.lstrip().startswith('*'):continue
   if re.match(r'^m'+re.escape(name)+r'\s',line,re.I):
    for key in ['l','w','sa','sb','sd','pd','ps']:
     line=re.sub(r'\b'+key+r'\s*=\s*\{'+key+r'\}',key+'={'+key+'*1e-6}',line,flags=re.I)
    for key in ['ad','as']:
     line=re.sub(r'\b'+key+r'\s*=\s*\{'+key+r'\}',key+'={'+key+'*1e-12}',line,flags=re.I)
    adapted+=1
   lines.append(line)
  assert adapted==1
  text+='\n'.join(lines)+'\n'
  geometry[name]={'minLengthM':min(float(x) for x in re.findall(r'\blmin\s*=\s*([\deE+.-]+)',body)),'minWidthM':min(float(x) for x in re.findall(r'\bwmin\s*=\s*([\deE+.-]+)',body))}
  records.append({'path':path,'sha256':hashlib.sha256(body.encode()).hexdigest(),'adaptedWrapperLines':adapted,'invariantParameters':len(params)})
 filename=f'sky130-1p8-{kind}-tt.spice';(folder/filename).write_text(text)
 packets.append({'id':'sky130-'+kind+'-tt','name':'1.8V '+kind.upper()+' NMOS / PMOS','process':'SKY130','corner':'TT','path':'SKY130/'+filename,'notice':'SkyWater 官方 SKY130 1.8V '+kind.upper()+' MOS、TT 典型角；'+('PMOS LVT 要求 L≥350nm。' if kind=='lvt' else '')+'原始 BSIM4 系数，适配器只做尺寸单位转换。开源发布不作为流片签核。','sha256':hashlib.sha256(text.encode()).hexdigest(),'devices':['sky130_fd_pr__'+f for f in group],'geometry':geometry,'sources':records})
 print(filename,len(text.encode()),'bytes')
(folder/'SOURCE.json').write_text(json.dumps({'repository':REPO,'commit':COMMIT,'license':'Apache-2.0','invariantSourceSHA256':hashlib.sha256(source['models/parameters/invariant.spice'].encode()).hexdigest(),'transformations':['Select official typical-corner MOS files and required invariant parameters','Strip comments/blank lines','Convert only M invocation geometry from micrometres to SI; underlying model coefficients unchanged'],'packets':packets},indent=2)+'\n')
all_packets=[]
for p in sorted((ROOT/'Engineering/PDK').glob('*/SOURCE.json')):all_packets.extend(json.loads(p.read_text()).get('packets',[]))
(ROOT/'Engineering/PDK/catalog.json').write_text(json.dumps([{k:v for k,v in p.items() if k not in ('cards','sources')} for p in all_packets],indent=2,ensure_ascii=False)+'\n')
