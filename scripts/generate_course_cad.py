#!/usr/bin/env python3
"""Author editable course examples from the supplied A1/A2 CAD assignment pages.
Every unspecified numerical choice is recorded as an example assumption.
No reference waveform or claimed solve is fabricated by this generator.
"""
from pathlib import Path
import json,math,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'Engineering/CourseCAD';OUT.mkdir(exist_ok=True)
source_inventory=json.loads((OUT/'source-inventory.json').read_text())
assignments=[];cases=[]
BJT='.model QN NPN IS=1e-14 BF=200 VAF=100 CJE=10p CJC=4p TF=400p TR=20n\n.model QP PNP IS=1e-14 BF=200 VAF=100 CJE=10p CJC=4p TF=400p TR=20n\n'
DIODE='.model DCAD D IS=2n N=1.7 RS=.15 CJO=5p TT=5n BV=50 IBV=10u\n'
SWITCH='.model SWCAD SW RON=.01 ROFF=1e9 VT=.9 VH=.02\n'
MODEL_NOTE='BJT/二极管使用明确给定参数的教学模型，可替换模型库；不冒充某个商用器件或代工工艺。'
MOS_NOTE='MOS 使用内置 GF180MCU 3.3V TT 官方 BSIM4；本例在 1.8V 电源下运行，不代表 1.8V 工艺模型。W/L 为示例设计，须结合实际曲线重新提取参数。'
base={'analysis':'Transient','start':'1','stop':'100Meg','points':40,'source':'VIN','dcStart':'0','dcStop':'1.8','dcStep':'10m','timeStep':'1u','duration':'5m','probes':['IN','OUT']}
def run(title,analysis='Transient',**kw):return {'title':title,'settings':dict(base,analysis=analysis,**kw)}
def ac(**kw):return run('交流幅相','AC analysis',**kw)
def tran(**kw):return run('时域波形','Transient',**kw)
def dc(**kw):return run('直流扫描','DC sweep',**kw)
def group(chapter,title,pages,goals,assumptions='',optional=False,suffix=''):
 id=chapter+suffix
 assignments.append(dict(id=id,chapter=chapter,title=title,pdf=next(row['file'] for row in source_inventory if row['file'].startswith(chapter)),pages=pages,goals=goals,assumptions=assumptions,optional=optional,caseIDs=[]))
 return assignments[-1]
def case(g,title,deck,runs,models='',mos=False,external=None,notes=''):
 # Keep DC bias explicit: the original editor requires it even for time sources.
 lines=[]
 for line in deck.strip().splitlines():
  match=re.match(r'^([VI]\S*\s+\S+\s+\S+\s+)(SIN|PULSE|PWL)\(([^\s,)]+)',line,re.I)
  if match:
   bias='0' if match[2].upper()=='PWL' else match[3]
   line=match[1]+'DC '+bias+' '+line[len(match[1]):]
  lines.append(line)
 deck='\n'.join(lines)
 id=g['id']+'-'+str(len(g['caseIDs'])+1).zfill(2);g['caseIDs'].append(id)
 c=dict(id=id,assignmentID=g['id'],title=title,netlist='* Circuit Studio course example '+id+'\n'+deck.strip()+'\n',models=models,modelPacket='gf180-tt' if mos else None,externalModels=external or {},runs=runs,notes=notes)
 cases.append(c);return c
# A1-02: all two-source / three-load combinations.
g=group('A1-02','电源、负载与功率守恒',[70],['比较直流电压源与正弦电流源驱动 R、C、串联 RC 时的电压电流。','由实际波形计算源输出功率、电阻耗散和电容储能。'],'未指定数值：R=1kΩ、C=100nF、直流5V、正弦电流峰值1mA/1kHz。直流接通采用有限10ns上升沿；纯电容增加1TΩ数值参考电阻。')
for source in ['DC','AC']:
 for load in ['R','C','RC']:
  deck='V1 IN 0 DC 0 PULSE(0 5 1u 10n 10n 100m 200m)\n' if source=='DC' else 'I1 0 IN DC 0 AC 1m SIN(0 1m 1k)\n'
  deck+= {'R':'VR IN RP 0\nR1 RP 0 1k','C':'VC IN CP 0\nC1 CP 0 100n\nRREF IN 0 1T','RC':'VR IN RP 0\nR1 RP MID 1k\nVC MID CP 0\nC1 CP 0 100n\nRREF IN 0 1T'}[load]
  case(g,('直流电压源' if source=='DC' else '交流电流源')+' · '+load,deck,[tran(probes=['IN'],duration='5m',timeStep='500n')])
g=group('A1-03','线性失真与非线性失真',[70],['比较电阻分压、RC 分压的方波输出与输入频谱。','观察二极管网络对正弦信号产生的谐波。'],'未指定数值：R=1kΩ，C=100nF，1kHz激励；二极管为教学模型。')
case(g,'电阻分压 · 无失真','VIN IN 0 PULSE(0 1 1u 10n 10n 500u 1m)\nR1 IN OUT 1k\nR2 OUT 0 1k',[tran(duration='10m',timeStep='1u')])
case(g,'RC 分压 · 线性失真','VIN IN 0 PULSE(0 1 1u 10n 10n 500u 1m)\nR1 IN OUT 1k\nC1 OUT 0 100n',[tran(duration='10m',timeStep='1u'),ac(stop='1Meg')])
case(g,'二极管 · 非线性失真','VIN IN 0 SIN(0 2 1k)\nR1 IN OUT 1k\nD1 OUT 0 DCAD',[tran(duration='10m',timeStep='1u')],DIODE)
g=group('A1-04','发射极负反馈的放大器等效电路',[64],['测量输入电阻、输出电阻、诺顿电流及负载电压增益。','比较带和不带发射极负反馈的结果。'],'原题：rbe=10kΩ，rce=100kΩ，gm=40mS，RE=1kΩ，RS=100Ω，RL=10kΩ。输入AC=1V；测试源只用于端口测量。')
small='RBE B E 10k\nRCE OUT E 100k\nGM OUT E B E 40m\n'
case(g,'负反馈 · 电压增益','VIN IN 0 DC 0 AC 1 SIN(0 10m 1k)\nRS IN B 100\n'+small+'RE E 0 1k\nRL OUT 0 10k',[ac(probes=['IN','B','E','OUT'],start='1',stop='1Meg'),tran(probes=['IN','OUT'])])
case(g,'无负反馈 · 对照','VIN IN 0 DC 0 AC 1\nRS IN B 100\n'+small.replace(' E ',' 0 ').replace('B E','B 0')+'RL OUT 0 10k',[ac(probes=['IN','OUT'])])
case(g,'输出电阻测试','VIN IN 0 DC 0 AC 0\nRS IN B 100\n'+small+'RE E 0 1k\nVTEST OUT 0 DC 0 AC 1',[ac(probes=['OUT'])],notes='Rout=V(OUT)/(-I(VTEST))，输入独立源置零；移除负载后测量。')
g=group('A1-05','共基组态 y 参数与等效电路',[77],['通过两个短路端口测试求 y11、y21、y12、y22。','比较原共基等效电路和 y 参数受控源模型的相同激励响应。'],'原页未给数值，示例沿用前章 rbe=10kΩ、rce=100kΩ、gm=40mS。',suffix='-cb')
for inputPort in [1,2]:
 case(g,f'端口{inputPort}加压、另一端短路',f'V1 E 0 DC 0 AC {1 if inputPort==1 else 0}\nV2 C 0 DC 0 AC {1 if inputPort==2 else 0}\nRBE E 0 10k\nRCE E C 100k\nGM E C E 0 40m',[ac(probes=['E','C'],start='10',stop='1Meg')],notes='端口流入网络电流=-I(V1)、-I(V2)。')
cb='VIN IN 0 DC 0 AC 1 SIN(0 .01 1k)\nRS IN E 100\nRL C 0 10k\n'
case(g,'原始共基等效电路',cb+'RBE E 0 10k\nRCE E C 100k\nGM E C E 0 40m',[ac(probes=['IN','E','C'])])
case(g,'y 参数等效电路',cb+'G11 E 0 E 0 .04011\nG12 E 0 C 0 -10u\nG21 C 0 E 0 -.04001\nG22 C 0 C 0 10u',[ac(probes=['IN','E','C'])])
g=group('A1-05','三端口环行器与反射',[78],['验证匹配端口吸收功率的环行方向。','比较端口2、端口3和源内阻失配时的反射波形。'],'原题 G=20mS、传输线Z0=50Ω。示例延时10ns、激励1V脉冲；失配电阻取100Ω/200Ω。使用 ngspice 的真实理想延时线 T 卡，并以可编辑层级模块呈现。',True,'-circulator')
for rS,r2,r3 in [(50,50,50),(50,100,50),(50,100,200),(100,100,200)]:
 deck=f'VIN IN 0 PULSE(0 1 1n 100p 100p 100n 300n)\nRS IN A1 {rS}\nXTL1 A1 0 P1 0 COURSE_LINE\nXTL2 P2 0 A2 0 COURSE_LINE\nXTL3 P3 0 A3 0 COURSE_LINE\nR2 A2 0 {r2}\nR3 A3 0 {r3}\nG12 P1 0 P2 0 20m\nG13 P1 0 P3 0 -20m\nG21 P2 0 P1 0 -20m\nG23 P2 0 P3 0 20m\nG31 P3 0 P1 0 20m\nG32 P3 0 P2 0 -20m'
 case(g,f'Rs={rS}Ω · R2={r2}Ω · R3={r3}Ω',deck,[tran(probes=['IN','A1','A2','A3','P1','P2','P3'],duration='500n',timeStep='200p')],external={'COURSE_LINE':{'count':4,'body':'T1 {0} {1} {2} {3} Z0=50 TD=10n'}})
g=group('A1-06','桥式整流与滤波',[82],['比较 S/A/B/L 的对地电压和源电流。','比较源内阻、滤波电容与二极管反向击穿的影响。'],'原题变压器1:1。示例使用理想变压器等效受控源；RL=1kΩ，输入50Hz/10V峰值，大电容100µF；击穿模型BV=50V。',suffix='-bridge')
for r,c,amp in [(0.01,0,10),(100,0,10),(0.01,100e-6,10),(100,100e-6,10),(100,0,80)]:
 deck=f'VIN S 0 SIN(0 {amp} 50)\nXTR S 0 A0 B COURSE_XFMR\nRS A0 A {r}\nD1 A L DCAD\nD3 B L DCAD\nD4 0 A DCAD\nD2 0 B DCAD\nRL L 0 1k\nRREF B 0 1T'+(f'\nCF L 0 {c}' if c else '')
 case(g,f'Rs={r:g}Ω · C={c:g}F · Vin={amp}V峰值',deck,[tran(probes=['S','A','B','L'],duration='100m',timeStep='20u')],DIODE,external={'COURSE_XFMR':{'count':4,'body':'VSENSE {0} N1 0\nESEC {2} {3} N1 {1} 1\nFPRI N1 {1} ESEC -1'}})
g=group('A1-06','非反相放大器的饱和',[83],['确认闭环增益10的转移特性和饱和。','比较2Vpp与5Vpp正弦输入时的输出。'],'原题R1=1kΩ、R2=9kΩ；未指定Vsat，示例取±15V。运放为平滑饱和教学宏模型，开环增益100000。',True,'-saturation')
for amp in [1,2.5]:
 case(g,f'输入 {2*amp:g}Vpp',f'VIN IN 0 DC 0 AC 1 SIN(0 {amp} 1k)\nXOP OUT 0 IN FB COURSE_OP\nR2 OUT FB 9k\nR1 FB 0 1k',[dc(dcStart='-2',dcStop='2',dcStep='10m'),tran(duration='5m',timeStep='1u')],external={'COURSE_OP':{'count':4,'body':'B1 {0} {1} V=15*tanh(100000*V({2},{3})/15)'}})
g=group('A1-06','20dB 反相放大器的带宽',[84],['直流与正弦激励验证反相增益-10。','提高输入频率，观察有限运放带宽对闭环增益的影响。'],'该页为虚拟仪器扩展练习。示例R1=10kΩ、R2=100kΩ；运放宏模型A0=100000、GBW≈1MHz。',True,'-inverting')
case(g,'有限带宽反相放大器','VIN IN 0 DC .1 AC 1 SIN(0 .1 1k)\nR1 IN FB 10k\nR2 FB OUT 100k\nGM 0 N 0 FB 1m\nRN N 0 100Meg\nCN N 0 159.1549p\nEBUF BUF 0 N 0 1\nROUT BUF OUT 50',[dc(dcStart='-.5',dcStop='.5',dcStep='5m'),ac(start='10',stop='100Meg'),tran()])
g=group('A1-07','PMOS 两种参考方向的输出特性',[70],['分别以VSG/VSD和VG/VD为变量获得PMOS端口伏安曲线。'],'未指定供电，示例VDD=1.8V、W=10µm、L=1µm；采用实际GF180模型。'+MOS_NOTE,suffix='-pmos')
for ref in ['VSD','VD']:
 for control in [.8,1.0,1.2,1.6]:
  deck=f'VSW 0 D 0\nVG 0 G {control}\nMP D G 0 0 pmos_3p3 W=10u L=1u' if ref=='VSD' else f'VDD VDD 0 1.8\nVSW D 0 0\nVG G 0 {1.8-control}\nMP D G VDD VDD pmos_3p3 W=10u L=1u'
  case(g,f'{ref} 横轴 · VSG={control:g}V',deck,[dc(source='VSW',dcStart='0',dcStop='1.8',dcStep='10m',probes=['D','G'])],mos=True)
g=group('A1-07','NPN 的电压控制与电流控制输出族线',[71],['比较VBE控制和IB控制的IC-VCE族线。','从实际曲线估计Early电压及恒流区电流增益。'],MODEL_NOTE+' 示例BF=200、VAF=100V；其测量值以实际工作点为准。',True,'-npn')
for v in [.62,.65,.68]:case(g,f'VBE={v:g}V',f'VCE OUT 0 0\nVBE B 0 {v}\nQ1 OUT B 0 QN',[dc(source='VCE',dcStop='5',probes=['OUT','B'])],BJT)
for i in [2e-6,5e-6,10e-6]:case(g,f'IB={i:g}A',f'VCE OUT 0 0\nIB 0 B {i}\nQ1 OUT B 0 QN',[dc(source='VCE',dcStop='5',probes=['OUT','B'])],BJT)
g=group('A1-08','100µA PMOS 电流源与源极负反馈',[69],['先提取PMOS阈值、跨导参数和输出电阻。','比较分压偏置和源极负反馈电流源的实际输出伏安特性。'],'原题VDD=1.8V、目标100µA。示例W/L=35.6µm/1µm，反馈/无反馈偏置分别采用296.667kΩ/200kΩ上臂和100kΩ下臂；在VL=0.8V处校准约100µA，其他负载点仍应由真实曲线检查。'+MOS_NOTE)
for feedback in [False,True]:
 deck='VDD VDD 0 1.8\nR1 VDD G '+('296667' if feedback else '200k')+'\nR2 G 0 100k\n'+('RS VDD S 1k\n' if feedback else '')+f'MP OUT G {"S" if feedback else "VDD"} VDD pmos_3p3 W=35.6u L=1u\nVTEST OUT 0 .8'
 case(g,'源极负反馈' if feedback else '分压偏置',deck,[dc(source='VTEST',dcStart='0',dcStop='1.8',probes=['OUT','G']),run('偏置工作点','Operating point',probes=['OUT','G'])],mos=True)
g=group('A1-09','BJT 反相器的工作区',[58],['验证输入输出转移曲线。','比较截止、放大与饱和区，研究RB的限流作用。'],'原题RB=1kΩ、RC=10kΩ、VCC=5V。'+MODEL_NOTE)
case(g,'RB=1kΩ · RC=10kΩ','VCC VCC 0 5\nVIN IN 0 0\nRB IN B 1k\nRC VCC OUT 10k\nQ1 OUT B 0 QN',[dc(dcStop='5',dcStep='5m')],BJT)
g=group('A1-10','两种增益约为-10的反相器',[64],['比较依赖β的基极电阻方案和发射极负反馈方案。','把分段折线估计与实际直流转移曲线比较。'],'未指定供电，示例VCC=5V。基极电阻方案按BF=200设计RB=200kΩ、RC=10kΩ；反馈方案RE=1kΩ、RC=10kΩ。晶体管动态β与有限VBE会产生偏差。'+MODEL_NOTE)
case(g,'基极电阻偏置','VCC VCC 0 5\nVIN IN 0 0\nRB IN B 200k\nRC VCC OUT 10k\nQ1 OUT B 0 QN',[dc(dcStop='2',dcStep='2m')],BJT)
case(g,'发射极负反馈','VCC VCC 0 5\nVIN IN 0 0\nRE E 0 1k\nRC VCC OUT 10k\nQ1 OUT IN E QN',[dc(dcStop='2',dcStep='2m')],BJT)
def bits_source(ref,node,bits,T):
 edge=T*1e-3;pts=[(0,0)]
 for i,b in enumerate(bits):
  t=(i+1)*T;pts.extend([(t-edge,1.8*int(bits[i-1]) if i else 0),(t,1.8*int(b))])
 pts.append(((len(bits)+1)*T,1.8*int(bits[-1])))
 return f'{ref} {node} 0 PWL('+ ' '.join(f'{t:.12g} {v:g}' for t,v in pts)+')'
g=group('A1-11','CMOS 与门、非理想跳变与动态功耗',[59],['保留原题A/B序列，观察NAND输出ZBAR及反相后的Z。','改变位周期T，观察速度极限和四条支路电流。'],'原题A=0011001011010、B=0101100110010。未给VDD及尺寸，示例VDD=1.8V、L=280nm；NMOS=4µm，PMOS=8µm；附20fF观测负载。'+MOS_NOTE)
for T in [100e-9,10e-9,1e-9]:
 deck='VDD VDD 0 1.8\nVDD1 VDD PWR1 0\nVDD2 VDD PWR2 0\nVGND1 GND1 0 0\nVGND2 GND2 0 0\n'+bits_source('VA','A','0011001011010',T)+'\n'+bits_source('VB','B','0101100110010',T)+'\nMP1 ZBAR A PWR1 VDD pmos_3p3 W=8u L=280n\nMP2 ZBAR B PWR1 VDD pmos_3p3 W=8u L=280n\nMN1 ZBAR A MID 0 nmos_3p3 W=4u L=280n\nMN2 MID B GND1 0 nmos_3p3 W=4u L=280n\nMP3 Z ZBAR PWR2 VDD pmos_3p3 W=8u L=280n\nMN3 Z ZBAR GND2 0 nmos_3p3 W=4u L=280n\nCL Z 0 20f'
 case(g,f'T={T:g}s',deck,[tran(probes=['A','B','ZBAR','Z'],timeStep=f'{T/50:g}',duration=f'{15*T:g}')],mos=True)
g=group('A1-12','100倍小信号放大器与耦合/旁路电容',[65],['设计并测量中频电压增益、输出摆幅和功率增益。','改变CB/CC/CE，比较低频截止及1kHz–1MHz的平坦度。'],'原题VCC=5V、RS=100Ω、RL=10kΩ。示例RC=3.6kΩ、RE=300Ω、RB1=39kΩ、RB2=10kΩ是可调设计起点，100倍是设计目标而非预填仿真结论。'+MODEL_NOTE)
for cap in ['.1u','1u','10u']:
 deck=f'VCC VCC 0 5\nVIN IN 0 DC 0 AC 1 SIN(0 1m 10k)\nRS IN SRC 100\nCB SRC B {cap}\nRB1 VCC B 39k\nRB2 B 0 10k\nRC VCC C 3.6k\nQ1 C B E QN\nRE E 0 300\nCE E 0 100u\nCC C OUT {cap}\nRL OUT 0 10k'
 case(g,'CB=CC='+cap,deck,[ac(start='10',stop='10Meg'),tran(duration='2m',timeStep='100n')],BJT)
g=group('A1-13','三种组态的功率匹配',[77],['对共射、共基、共集小信号模型改变RS、RL。','用PL/(VS²/(4RS))计算功率增益，比较端口阻抗匹配。'],'原页未给数值：沿用rbe=10kΩ、rce=100kΩ、gm=40mS。不同组态的端口与参考端按原图定义。',True)
for conf in ['CE','CB','CC']:
 for rs,rl in [(100,1e3),(1e3,1e4),(1e4,1e5)]:
  b,e,c={'CE':('INB','0','OUT'),'CB':('0','INE','OUT'),'CC':('INB','OUT','0')}[conf]
  inn=b if conf!='CB' else e
  deck=f'VIN IN 0 DC 0 AC 1\nRS IN {inn} {rs:g}\nRL OUT 0 {rl:g}\nRBE {b} {e} 10k\nRCE {c} {e} 100k\nGM {c} {e} {b} {e} 40m'
  case(g,f'{conf} · RS={rs:g}Ω · RL={rl:g}Ω',deck,[ac(start='10',stop='1Meg')])
g=group('A1-14','A/B/AB 类缓冲器',[68,63],['比较三类输出级的DC转移、正弦波形和失真。','由实际源电流和负载电压计算效率。'],'参照作业2的±15V供电。未给RL/IQ/IB：示例RL=1kΩ，A类IQ=13mA，AB类二极管偏置电流1mA。'+MODEL_NOTE)
for conf in ['A','B','AB']:
 deck='VCC VCC 0 15\nVEE VEE 0 -15\nVIN IN 0 DC 0 SIN(0 10 1k)\nRL OUT 0 1k\n'
 if conf=='A':deck+='Q1 VCC IN OUT QN\nIQ OUT VEE 13m'
 elif conf=='B':deck+='Q1 VCC IN OUT QN\nQ2 VEE IN OUT QP'
 else:deck+='IB1 VCC BP 1m\nD1 BP IN DCAD\nD2 IN BN DCAD\nIB2 BN VEE 1m\nQ1 VCC BP OUT QN\nQ2 VEE BN OUT QP'
 case(g,conf+' 类',deck,[dc(dcStart='-14',dcStop='14',dcStep='20m'),tran(duration='10m',timeStep='1u')],BJT+DIODE)
# Remaining A2 examples are authored below.
g=group('A2-17','冲激、阶跃与充电能量',[81],['减小真实开关导通电阻，观察充电电流脉冲面积与宽度。','比较源输出能量、Ron耗散和最终电容储能。'],'未指定数值：Vs=5V、C=1µF，Ron取100Ω/10Ω/1Ω。使用有限上升沿和非零Ron；不把理想零电阻冲激当作有限波形。')
for r in [100,10,1]:
 case(g,f'Ron={r}Ω',f'VIN IN 0 PULSE(0 5 1u 1n 1n 1 2)\nRON IN OUT {r}\nVC OUT CP 0\nC1 CP 0 1u',[tran(probes=['IN','OUT'],duration=f'{max(1e-5,10*r*1e-6):g}',timeStep=f'{max(1e-9,r*1e-6/100):g}')])
g=group('A2-18','RC 时间常数、方波与频谱',[63],['保留R=1kΩ、0–5V方波、T=1ms以及全部7个α。','比较电容低频分量与电阻高频分量，并观察稳态频谱。'],'原题电容初值0。瞬态先求完整启动过程，再在8τ后记录10个周期；开始记录时间不等于电路初始时间。',suffix='-rc')
for alpha in [.001,.01,.1,1,10,100,1000]:
 tau=alpha*.001;C=tau/1000;tstart=max(.01,8*tau)
 case(g,f'α={alpha:g} · C={C:g}F',f'VIN IN 0 DC 0 AC 1 PULSE(0 5 0 10n 10n 500u 1m)\nR1 IN OUT 1k\nC1 OUT 0 {C:g}\nER VR 0 IN OUT 1',[tran(probes=['IN','OUT','VR'],timeStep='1u',duration=f'{tstart+.01:g}',startSaving=f'{tstart:g}'),ac(probes=['IN','OUT','VR'],start=f'{1/(2*math.pi*tau)/100:g}',stop=f'{1/(2*math.pi*tau)*100:g}')])
g=group('A2-18','RC 分流与 RL 分压的对偶',[64],['观测电阻、电容的分流和电阻、电感的分压。','区分相对于激励的高频与低频成分。'],'未指定数值：R=1kΩ、C=100nF；对偶RL取L=100mH，τ=100µs。电流源1mA阶跃、电压源1V阶跃。',True,'-dual')
case(g,'RC 并联分流','IS 0 OUT PULSE(0 1m 1u 10n 10n 10m 20m)\nVR OUT R 0\nR1 R 0 1k\nVC OUT C 0\nC1 C 0 100n',[tran(probes=['OUT'],duration='2m',timeStep='500n')])
case(g,'RL 串联分压','VIN IN 0 PULSE(0 1 1u 10n 10n 10m 20m)\nR1 IN OUT 1k\nL1 OUT 0 100m\nER VR 0 IN OUT 1',[tran(probes=['IN','OUT','VR'],duration='2m',timeStep='500n')])
g=group('A2-19','NMOS、PMOS、CMOS 与理想开关',[66],['比较R/C两类负载的静态信号传输。','以直流或正弦为输入、方波为控制，比较动态开关行为。'],'未给供电/器件/负载：VDD=1.8V，RL=10kΩ，CL=10pF，MOS W=10µm/L=280nm。体端按原题接最低/最高电位；理想开关使用非零10mΩ。'+MOS_NOTE)
for kind in ['NMOS','PMOS','CMOS','理想']:
 for load in ['R','C']:
  for mode in ['静态传输','直流输入动态开关','正弦输入动态开关']:
   vin='PULSE(0 1.8 10n 100p 100p 100n 200n)' if mode=='静态传输' else ('DC 1.8' if mode=='直流输入动态开关' else 'SIN(.9 .8 5Meg)')
   ctrl='DC 1.8' if mode=='静态传输' else 'PULSE(0 1.8 20n 100p 100p 50n 100n)'
   deck=f'VDD VDD 0 1.8\nVIN IN 0 {vin}\nVCTRL CTRL 0 {ctrl}\nECOMP CBAR 0 VDD CTRL 1\n'
   if kind in ['NMOS','CMOS']:deck+='MN IN CTRL OUT 0 nmos_3p3 W=10u L=280n\n'
   if kind in ['PMOS','CMOS']:deck+='MP IN CBAR OUT VDD pmos_3p3 W=10u L=280n\n'
   if kind=='理想':deck+='S1 IN OUT CTRL 0 SWCAD\n'
   deck+= 'RL OUT 0 10k' if load=='R' else 'CL OUT 0 10p\nRREF OUT 0 1T'
   case(g,f'{kind} · {load}负载 · {mode}',deck,[tran(probes=['IN','OUT','CTRL'],duration='1u',timeStep='200p')],SWITCH if kind=='理想' else '',kind!='理想')
g=group('A2-20','去耦电容位置与电源噪声',[70,69],['比较无电容、A/B单电容、2/3/4处分配相同总电容。','比较10MHz切换负载造成的模拟电源纹波。'],'原题V0=5V、R1=R2=10Ω、Ra=1kΩ、数字负载990Ω/90Ω。示例总电容100nF是待验证设计值，并非预先声称满足1/10纹波目标；每个电阻分成两半以提供中点。')
for positions in [[],['A'],['B'],['A','B'],['A','B','M2'],['A','B','M1','M2']]:
 deck='VDD VDD 0 5\nR1A VDD M1 5\nR1B M1 A 5\nR2A A M2 5\nR2B M2 B 5\nRA A 0 1k\nVC CTRL 0 PULSE(0 1.8 10n 100p 100p 50n 100n)\nEC CBAR 0 CTRL 0 -1\nS1 B D1 CTRL 0 SWCAD\nS2 B D2 CBAR 0 SWNEG\nRD1 D1 0 990\nRD2 D2 0 90\nRREF1 D1 0 1T\nRREF2 D2 0 1T'
 # Complementary controls use the same positive threshold by adding a DC reference.
 deck=deck.replace('EC CBAR 0 CTRL 0 -1','VREF VREF 0 1.8\nEC CBAR 0 VREF CTRL 1').replace('SWNEG','SWCAD')
 for i,p in enumerate(positions):deck+=f'\nC{i+1} {p} 0 {100e-9/len(positions):.12g}'
 case(g,'无去耦' if not positions else ' + '.join(positions),deck,[tran(probes=['A','B','CTRL'],timeStep='200p',duration='30u',startSaving='20u')],SWITCH)
def rlc(g,xi,L=1e-3,C=1e-6):
 R=2*xi*math.sqrt(L/C)
 return case(g,f'ξ={xi:g} · R={R:.6g}Ω',f'VIN IN 0 DC 0 AC 1 PULSE(0 1 1u 10n 10n 10 20)\nR1 IN MID {R:.12g}\nL1 MID OUT {L:.12g}\nC1 OUT 0 {C:.12g}',[ac(start='1',stop='1Meg'),tran(timeStep='2u',duration=f'{max(.01,20*xi*math.sqrt(L*C)):g}')])
g=group('A2-21','二阶 RLC 的阻尼、幅相与阶跃',[79],['保留原题10个阻尼系数，对比幅频、相频和阶跃响应。'],'原题未指定L/C：示例L=1mH、C=1µF；R=2ξ√(L/C)，ω0=1/√(LC)。')
for xi in [.01,.1,.5,.707,.866,1,2,10,50,100]:rlc(g,xi)
g=group('A2-22','二阶低通的阶跃响应比较',[74],['比较ξ=0.1、0.866、10的阶跃响应与过冲/稳定时间。'],'未指定L/C：示例L=1mH、C=1µF，保持相同自然频率。',True)
for xi in [.1,.866,10]:rlc(g,xi)
g=group('A2-23','有源低通与运放宏模型',[79],['比较输入电阻、输出电阻、开环增益、GBW对闭环低通的影响。','检查|H0|和3dB带宽是否偏离理想值超过1%。'],'原题R1=1kΩ、R2=10kΩ、C=33nF。宏模型gm=1mS，Rn=A0/gm，Cn=gm/(2πGBW)。默认A0=100000、GBW=10MHz、Rin=1GΩ、Rout=1Ω；其他配置用于参数扫描。')
for what,rin,rout,a0,gbw in [('基准',1e9,1,1e5,1e7),('Rin=100kΩ',1e5,1,1e5,1e7),('Rin=10kΩ',1e4,1,1e5,1e7),('Rout=100Ω',1e9,100,1e5,1e7),('Rout=1kΩ',1e9,1000,1e5,1e7),('A0=1000',1e9,1,1e3,1e7),('A0=100',1e9,1,1e2,1e7),('GBW=100kHz',1e9,1,1e5,1e5),('GBW=10kHz',1e9,1,1e5,1e4)]:
 deck=f'VIN IN 0 DC 0 AC 1 SIN(0 .01 100)\nR1 IN FB 1k\nR2 FB OUT 10k\nCF FB OUT 33n\nRIN FB 0 {rin:g}\nGM 0 N 0 FB 1m\nRN N 0 {a0/.001:g}\nCN N 0 {.001/(2*math.pi*gbw):.12g}\nEOUT BUF 0 N 0 1\nROUT BUF OUT {rout:g}'
 case(g,what,deck,[ac(start='1',stop='1Meg'),tran(duration='50m',timeStep='10u')])
g=group('A2-24','单级与两级 L 型阻抗匹配',[91,86],['10MHz下比较1300Ω到50Ω的单级高通匹配与经255Ω的两级匹配。','比较可用源功率、1dB匹配带宽及储能启动过程。'],'沿用作业1的Rs=1300Ω、RI=255Ω、RL=50Ω、f0=10MHz。元件由无损L型匹配公式计算，激励峰值1V；低/高1dB频点须由实际曲线测量。')
w=2*math.pi*10e6;Q=math.sqrt(1300/50-1);q1=math.sqrt(1300/255-1);q2=math.sqrt(255/50-1)
for stages in [1,2]:
 deck='VIN IN 0 DC 0 AC 1 SIN(0 1 10Meg)\nRS IN P 1300\nRL OUT 0 50\n'
 if stages==1:deck+=f'L1 P 0 {1300/(w*Q):.12g}\nC1 P OUT {1/(w*50*Q):.12g}'
 else:deck+=f'L1 P 0 {1300/(w*q1):.12g}\nC2 P MID {1/(w*255*q1):.12g}\nC3 MID 0 {q2/(w*255):.12g}\nL4 MID OUT {q2*50/w:.12g}'
 case(g,'单级高通' if stages==1 else '高通+低通两级',deck,[ac(start='1Meg',stop='100Meg',points=100),tran(duration='10u',timeStep='500p')])
g=group('A2-25','上升沿时间与带宽',[103],['测量RC和ξ=0.866的RLC的10%–90%上升时间。','比较实际3dB带宽与上升时间乘积。'],'RC：R=1kΩ、C=100nF；RLC：L=1mH、C=1µF。RC的0.35近似关系不能直接当作所有二阶电路的精确常数。',True,'-rise')
case(g,'一阶 RC','VIN IN 0 DC 0 AC 1 PULSE(0 1 1u 1n 1n 10m 20m)\nR1 IN OUT 1k\nC1 OUT 0 100n',[ac(start='10',stop='1Meg'),tran(timeStep='100n',duration='2m')]);rlc(g,.866)
g=group('A2-25','续流二极管与感性负载开断',[104],['比较理想/CMOS开关以及有/无续流二极管的四种情况。','观察V1、VR及开关断开时的过压和体二极管影响。'],'原题未指定数值：VDD=1.8V、L=10mH、R=1kΩ、控制周期1ms。无续流二极管时用1GΩ提供数值泄放；理想开关Ron=10mΩ。CMOS开关出现超轨电压时保留真实体二极管行为。'+MOS_NOTE,suffix='-flyback')
for kind in ['理想','CMOS']:
 for diode in [False,True]:
  deck='VDD VDD 0 1.8\nVC CTRL 0 PULSE(0 1.8 100u 10n 10n 500u 1m)\nEC CBAR 0 VDD CTRL 1\nL1 VDD V1 10m\nR1 VR 0 1k\n'
  deck+= 'D1 V1 VDD DCAD\n' if diode else 'RLEAK V1 VDD 1G\n'
  deck+= 'S1 V1 VR CTRL 0 SWCAD' if kind=='理想' else 'MN V1 CTRL VR 0 nmos_3p3 W=100u L=280n\nMP V1 CBAR VR VDD pmos_3p3 W=100u L=280n M=2'
  case(g,kind+(' · 有续流' if diode else ' · 无续流'),deck,[tran(probes=['V1','VR','CTRL'],duration='3m',timeStep='500n')],DIODE+(SWITCH if kind=='理想' else ''),kind=='CMOS')
g=group('A2-26','谐振负载大信号放大器',[86],['改变栅极偏置与负载，观察导通角、脉冲电流和谐振正弦输出。','检查漏极电压及效率，区分饱和区和欧姆区。'],'未指定数值：VDD=1.5V、L=1µH、C=253.303pF、f0≈10MHz、输入正弦峰值0.5V；使用理想1:1变压器。W/L=100µm/280nm、负载500Ω为可调设计起点；不预填最优效率。'+MOS_NOTE)
for bias in [.4,.6,.8]:
 deck=f'VDD VDD 0 1.5\nVIN IN 0 SIN({bias:g} .5 10Meg)\nMN D IN 0 0 nmos_3p3 W=100u L=280n\nL1 VDD D 1u\nC1 VDD D 253.302959p\nXTR VDD D OUT 0 COURSE_XFMR\nRL OUT 0 500'
 case(g,f'VB0={bias:g}V',deck,[tran(probes=['IN','D','OUT'],duration='10u',timeStep='200p',startSaving='5u')],mos=True,external={'COURSE_XFMR':{'count':4,'body':'VSENSE {0} N1 0\nESEC {2} {3} N1 {1} 1\nFPRI N1 {1} ESEC -1'}})
g=group('A2-27','双 MOS 负反馈放大器',[84],['比较开环/闭环的偏置、低频增益及幅相带宽。','利用输入/输出测试源求端口阻抗。'],'未指定数值：VDD=1.8V，RD=15kΩ、RS=1kΩ、RF=10kΩ、RP=10kΩ；输入偏置1.3V，NMOS/PMOS的W分别为5µm/20µm、L=1µm。该配置是可调起点，以实际工作点确认器件区域。'+MOS_NOTE)
for feedback in [True,False]:
 deck='VDD VDD 0 1.8\nVIN IN 0 DC 1.3 AC 1 SIN(1.3 1m 1k)\nRD VDD X 15k\nMN X IN S 0 nmos_3p3 W=5u L=1u\nMP OUT X VDD VDD pmos_3p3 W=20u L=1u\nRS S 0 1k\nRP OUT 0 10k'+('\nRF OUT S 10k' if feedback else '')
 case(g,'闭环负反馈' if feedback else '开环对照',deck,[run('确认偏置','Operating point',probes=['IN','X','S','OUT']),ac(start='1',stop='100Meg'),tran() ],mos=True)
g=group('A2-28','交叉耦合差分对的 N 型负阻',[84],['通过加压求流观察N型负阻。','比较LC正弦振荡与低Q张弛振荡的波形。'],'原题未指定数值：尾电流1mA；端口测试各注入0.5mA；振荡器VCC=5V，中心抽头电感两半各100µH、耦合0.999，示例C=10nF/10pF。加入1µA、50ns的微小差分启动脉冲，未伪造振荡。'+MODEL_NOTE,True,'-n')
case(g,'N型端口测试','I1 0 A .5m\nI2 0 B .5m\nVTEST A B 0\nQ1 A B 0 QN\nQ2 B A 0 QN',[dc(source='VTEST',dcStart='-.5',dcStop='.5',dcStep='1m',probes=['A','B'])],BJT)
for cap in ['10n','10p']:
 deck=f'VCC VCC 0 5\nL1 VCC A 100u\nL2 B VCC 100u\nK1 L1 L2 .999\nC1 A B {cap}\nQ1 A B E QN\nQ2 B A E QN\nITAIL E 0 1m\nRLOSS1 A VCC 10k\nRLOSS2 B VCC 10k\nISEED A B PULSE(0 1u 1u 1n 1n 50n 1)\nEOUT OUT 0 A B 1'
 case(g,'LC振荡 · C='+cap,deck,[tran(probes=['A','B','OUT'],duration='1m' if cap=='10n' else '50u',timeStep='20n' if cap=='10n' else '1n')],BJT)
g=group('A2-28','双 CMOS 反相器的 S 型负阻',[85],['调整器件比使反相器约在VDD/2翻转。','通过端口电流扫描与端口电容验证S型负阻和张弛振荡。'],'未指定数值：VDD=1.8V、R=10kΩ、NMOS W=10µm、PMOS W=20µm、L=280nm。体端连接固定，加入微小启动脉冲。翻转点与振荡频率必须由实际模型测量。'+MOS_NOTE,True,'-s')
inv='VDD VDD 0 1.8\nMN1 MID IN 0 0 nmos_3p3 W=10u L=280n\nMP1 MID IN VDD VDD pmos_3p3 W=20u L=280n\nMN2 OUT MID 0 0 nmos_3p3 W=10u L=280n\nMP2 OUT MID VDD VDD pmos_3p3 W=20u L=280n\nR1 IN MID 10k\n'
case(g,'S型端口电流扫描',inv+'ITEST IN OUT 0',[dc(source='ITEST',dcStart='-100u',dcStop='100u',dcStep='500n',probes=['IN','MID','OUT'])],mos=True)
case(g,'电容张弛振荡',inv+'C1 IN OUT 100p\nISEED 0 IN PULSE(0 1u 1u 1n 1n 20n 1)',[tran(probes=['IN','MID','OUT'],duration='100u',timeStep='2n')],mos=True)
g=group('A2-29','理想 RC 移相振荡器的起振条件',[79],['比较开环增益小于/大于29时的衰减与起振。','核对f0=1/(2π√6RC)，区分理想无幅度限制和真实限幅电路。'],'沿用后页R=3.3kΩ、C=3.3nF，理想频率约5.97kHz。增加1nA启动脉冲。理想VCVS没有稳幅机制，不把幅度持续增长当作稳定正弦振荡。',suffix='-ideal')
for gain in [25,29,32]:
 deck=f'EAMP OUT 0 VF 0 {-gain}\nC1 OUT N1 3.3n\nC2 N1 N2 3.3n\nC3 N2 VF 3.3n\nR1 N1 0 3.3k\nR2 N2 0 3.3k\nR3 VF 0 3.3k\nISEED 0 N1 PULSE(0 1n 1u 1n 1n 100n 1)'
 case(g,f'Av0={gain}',deck,[tran(probes=['VF','OUT'],duration='5m',timeStep='500n')])
g=group('A2-29','BJT 移相振荡器的加载效应',[82,80,81],['先保留同学给出的RC=2kΩ设计，再比较修改后的设计。','观察起振和频率偏差，分析基极与集电极对移相网络的加载。'],'原题VCC=9V、R=3.3kΩ、C=3.3nF、RB1=39.6kΩ、RB2=3.6kΩ、RE=330Ω；CE未定，示例100µF。为对齐原文忽略β/VA的近似，采用明确的教学参数BF=1e6、VAF=1e9V、IS=4e-14A；有限器件可另行替换，修改后的RC仍须以实际起振结果核验。'+MODEL_NOTE,suffix='-bjt')
for rc in ['2k','6.8k','10k']:
 deck=f'VCC VCC 0 9\nRB1 VCC B 39.6k\nRB2 B 0 3.6k\nR1 VCC N1 3.3k\nR2 VCC N2 3.3k\nC1 B N1 3.3n\nC2 N1 N2 3.3n\nC3 N2 OUT 3.3n\nRC VCC OUT {rc}\nQ1 OUT B E QN\nRE E 0 330\nCE E 0 100u\nISEED 0 N1 PULSE(0 100n 1u 1n 1n 100n 1)'
 case(g,'RC='+rc,deck,[run('偏置','Operating point',probes=['B','E','OUT']),tran(probes=['B','E','OUT'],duration='20m',timeStep='1u')],BJT.replace('IS=1e-14 BF=200 VAF=100','IS=4e-14 BF=1e6 VAF=1e9'))
g=group('A2-30','1MHz 电容三点式振荡器',[26],['保留讲义的Colpitts拓扑并设计BJT偏置。','观察起振过程、实际振荡频率及稳态频谱；无法起振时调整环路增益。'],'原页只指定目标1MHz。示例VCC=5V、C1=1nF、C2=10nF、L=27.863µH，使理想LC频率为1MHz；晶体管与负载会改变频率。RB1=47kΩ、RB2=12kΩ、RE=1kΩ、Cb=Cc=1µF、C0=100nF；RL=100kΩ。实际是否起振须测量。'+MODEL_NOTE)
for emitterR in ['1k','470']:
 deck=f'VCC VCC 0 5\nRB1 VCC B 47k\nRB2 B 0 12k\nCB B 0 1u\nQ1 C B E QN\nRE E 0 {emitterR}\nL1 VCC C 27.863326u\nC1 C E 1n\nC2 E 0 10n\nCC C OUT 1u\nRL OUT 0 100k\nC0 VCC 0 100n\nISEED 0 C PULSE(0 1u 100n 1n 1n 10n 1)'
 case(g,'RE='+emitterR,deck,[run('偏置','Operating point',probes=['B','E','C']),tran(probes=['C','E','OUT'],duration='100u',timeStep='2n')],BJT)
# Do not draw unused stimulus helpers in variants that have no receiving device.
# An output requested as an observation (for example VR) remains a real meter.
for entry in cases:
 lines=entry['netlist'].splitlines()
 observed={name.upper() for preset in entry['runs'] for name in preset['settings'].get('probes',[])}
 for prefix in ['E','V']:
  kept=[]
  for line in lines:
   f=line.split()
   if len(f)>3 and f[0].startswith(prefix) and (prefix=='E' or f[0] in ['VDD','VREF']):
    used=any(f[1] in other.split()[1:] for other in lines if other!=line and other and other[0]!='*')
    if not used and f[1].upper() not in observed:continue
   kept.append(line)
  lines=kept
 entry['netlist']='\n'.join(lines)+'\n'
# Show operational-amplifier and circulator models as their real functional blocks.
# Their complete numerical implementation remains in the owned model source.
for entry in cases:
 lines=entry['netlist'].splitlines();cards={line.split()[0]:line.split() for line in lines if line and line[0] not in '*. '}
 if entry['assignmentID'] in ['A1-06-inverting','A2-23'] and all(name in cards for name in ['GM','RN','CN','ROUT']) and ('EBUF' in cards or 'EOUT' in cards):
  buffer='EBUF' if 'EBUF' in cards else 'EOUT';g=cards['GM'];ro=cards['ROUT'];body=f"GCORE {{1}} N {{2}} {{3}} {g[-1]}\nRN N {{1}} {cards['RN'][-1]}\nCN N {{1}} {cards['CN'][-1]}\nEBUF BUF {{1}} N {{1}} {cards[buffer][-1]}\nROUT BUF {{0}} {ro[-1]}"
  if 'RIN' in cards:body+=f"\nRINPUT {{3}} {{1}} {cards['RIN'][-1]}"
  removed={'GM','RN','CN',buffer,'ROUT','RIN'}
  entry['netlist']='\n'.join(line for line in lines if not line or line.split()[0] not in removed)+f"\nXOP {ro[2]} 0 {g[3]} {g[4]} COURSE_CAD_OP\n"
  entry['externalModels']['COURSE_CAD_OP']={'count':4,'body':body}
 if entry['assignmentID']=='A1-05-circulator':
  names=['G12','G13','G21','G23','G31','G32'];body=[]
  for name in names:
   card=cards[name];body.append(' '.join([name]+[{'P1':'{0}','P2':'{1}','P3':'{2}','0':'{3}'}.get(token,token) for token in card[1:]]))
  entry['netlist']='\n'.join(line for line in lines if not line or line.split()[0] not in names)+'\nXCIRC P1 P2 P3 0 COURSE_CIRC\n'
  entry['externalModels']['COURSE_CIRC']={'count':4,'body':'\n'.join(body)}
# Document coverage makes exclusions auditable, instead of inventing assignments.
raw=source_inventory
coverage=[]
for row in raw:
 chapter=row['file'][:5];matched=[a['id'] for a in assignments if a['chapter']==chapter]
 coverage.append({'pdf':row['file'],'pageCount':row['pages'],'assignments':matched,'note':'' if matched else '未找到具体CAD作业；课程介绍/考评中的CAD说明不作为作业。'})
payload={'schema':'circuitstudio-course-cad-v1','title':'电子电路与系统基础 A1 / A2 · CAD 示例','assignments':assignments,'cases':cases,'coverage':coverage}
(OUT/'catalog.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n')
print(f'Authored {len(assignments)} assignments, {len(cases)} editable configurations, {sum(len(c["runs"]) for c in cases)} analysis presets.')
