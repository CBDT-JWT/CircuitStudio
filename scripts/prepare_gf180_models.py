#!/usr/bin/env python3
"""Extract exact public GF180MCU 3.3V TT BSIM4 model cards, without coefficient changes."""
from pathlib import Path
import hashlib,json,re,urllib.request
ROOT=Path(__file__).resolve().parents[1]
REPOSITORY='https://github.com/google/globalfoundries-pdk-libs-gf180mcu_fd_pr'
COMMIT='9f992d5a9186d1f7820c58f039c484ad35b2edea'
RAW=f'https://raw.githubusercontent.com/google/globalfoundries-pdk-libs-gf180mcu_fd_pr/{COMMIT}/'
source=urllib.request.urlopen(RAW+'models/ngspice/sm141064.ngspice',timeout=30).read()
license=urllib.request.urlopen(RAW+'LICENSE',timeout=30).read()
design=urllib.request.urlopen(RAW+'models/ngspice/design.ngspice',timeout=30).read()
text=source.decode().replace('\r\n','\n')
folder=ROOT/'Engineering/PDK/GF180MCU';folder.mkdir(exist_ok=True,parents=True)
(folder/'LICENSE').write_bytes(license)
packets=[]
for corner,nSuffix,pSuffix in [('tt','t','t'),('ff','f','f'),('ss','s','s'),('fs','f','s'),('sf','s','f')]:
 cards=[];records=[]
 for name,suffix in [('nmos_3p3',nSuffix),('pmos_3p3',pSuffix)]:
  section=re.search(r'^\.lib '+name+'_'+suffix+r'\s*$(.*?)^\.endl '+name+'_'+suffix+r'\s*$',text,re.M|re.I|re.S).group(1)
  for card in re.findall(r'^\.model\s+'+name+r'\.\d+\s+[^\n]+\n(?:\+[^\n]*\n)*',section,re.M|re.I):
   assert re.search(r'level\s*=\s*54',card)
   cards.append(card);records.append({'model':card.split()[1],'sha256':hashlib.sha256(card.encode()).hexdigest()})
 assert len(cards)==32
 header='\n'.join(text.splitlines()[:15])+f'\n* CIRCUIT_STUDIO_GF180MCU_{corner.upper()}: exact upstream 3.3V BSIM4 cards.\n* Coefficients unchanged; no SAB wrappers, statistical mismatch or signoff.\n'
 noise='\n'.join(line for line in text.splitlines() if re.match(r'^\s*\+[np]mos_3p3_noi[abc]=',line));assert len(noise.splitlines())==6
 output=(header+'.param fnoicor=0\n.param\n'+noise+'\n'+'\n'.join(cards)).encode()
 filename=f'gf180mcu-3p3-{corner}.spice';(folder/filename).write_bytes(output)
 packets.append({'id':'gf180-'+corner,'name':'3.3V NMOS / PMOS','process':'GF180MCU','corner':corner.upper(),'path':'GF180MCU/'+filename,'notice':f'GlobalFoundries 官方 180nm、3.3V MOS、{corner.upper()} 工艺角；BSIM4 level 54，模型系数未改。开源 PDK 为实验预览。','sha256':hashlib.sha256(output).hexdigest(),'devices':['nmos_3p3','pmos_3p3'],'cards':records})
manifest={'name':'GlobalFoundries GF180MCU','technology':'180nm 3.3V MOS','corners':['TT','FF','SS','FS','SF'],'modelType':'BSIM4 level 54','repository':REPOSITORY,'commit':COMMIT,'sourceFile':'models/ngspice/sm141064.ngspice','sourceSHA256':hashlib.sha256(source).hexdigest(),'designSourceSHA256':hashlib.sha256(design).hexdigest(),'license':'Apache-2.0','upstreamStatus':'Experimental preview; not production signoff','transformations':['Select exact 3.3V NMOS/PMOS model cards for each official corner','Select upstream 3.3V noise parameters and fnoicor=0','Normalize CRLF to LF'],'packets':packets}
(folder/'SOURCE.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('GF180MCU: 5 real process corners, 32 model bins each.')
