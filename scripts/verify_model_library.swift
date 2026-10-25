import Foundation
@main struct Verify {
 static func main() throws {
  let repository=URL(fileURLWithPath:CommandLine.arguments[1]);let root=repository.appendingPathComponent("Engineering/PDK")
  let catalog=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("catalog.json"))) as! [[String:Any]]
  var checks:[[String:Any]]=[]
  for entry in catalog {
   let id=entry["id"] as! String
   let models=try String(contentsOf:root.appendingPathComponent(entry["path"] as! String),encoding:.utf8)
   let sky=(entry["process"] as! String)=="SKY130";let vdd=sky ? 1.8 : 3.3
   let devices=entry["devices"] as! [String];let n=devices.first{$0.contains("nmos") || $0.contains("nfet")}!;let p=devices.first{$0.contains("pmos") || $0.contains("pfet")}!
   let pLength=p.contains("pfet_01v8_lvt") ? "0.35" : "0.15"
   let parts=sky ? "XP OUT IN VDD VDD \(p) w=2 l=\(pLength) nf=1 m=1\nXN OUT IN 0 0 \(n) w=1 l=0.15 nf=1 m=1" : "MP OUT IN VDD VDD \(p) W=2u L=280n\nMN OUT IN 0 0 \(n) W=1u L=280n"
   let source="VDD VDD 0 \(vdd)\nVIN IN 0 DC \(vdd/2) AC 1 PULSE(0 \(vdd) 1n 100p 100p 10n 20n)\n"+parts+"\nC1 OUT 0 1p"
   var settings=SimulationSettings();settings.analysis = .dc;settings.source="VIN";settings.dcStart="0";settings.dcStop=String(vdd);settings.dcStep="10m";settings.probes=["OUT","IN"]
   let result=try EmbeddedSpice.run(netlist:source,settings:settings,models:models)
   guard let trace=result.waveform("OUT"),trace.values.first!.real>vdd*0.9,trace.values.last!.real<0.1 else { throw CircuitError.message("Invalid real model DC: "+id) }
   let report:[String:Any]=["id":id,"realModel":true,"engine":result.engine,"samples":result.axis.count,"outputLowInput":trace.values.first!.real,"outputHighInput":trace.values.last!.real]
   checks.append(report);print("Verified model packet:",id);fflush(stdout)
   try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  }
  if CommandLine.arguments.count>3 {
    let inverter=try String(contentsOfFile:CommandLine.arguments[3],encoding:.utf8)
    let models=try String(contentsOf:root.appendingPathComponent("SKY130/sky130-1p8-svt-tt.spice"),encoding:.utf8)
    var settings=SimulationSettings();settings.analysis = .dc;settings.source="V1";settings.dcStart="0";settings.dcStop="1.8";settings.dcStep="10m";settings.probes=["Vo"]
    let result=try EmbeddedSpice.run(netlist:inverter,settings:settings,models:models,supplies:["VDD":"1.8","VSS":"0"])
    guard let trace=result.waveform("Vo"),result.axis.count==181,trace.values.first!.real>0.1,trace.values.last!.real<0.01 else { throw CircuitError.message("Saved inverter failed with real SKY130 models") }
    let report:[String:Any]=["id":"saved-inverter-sky130-svt-tt","realModel":true,"engine":result.engine,"samples":result.axis.count,"outputLowInput":trace.values.first!.real,"outputHighInput":trace.values.last!.real]
    checks.append(report);print("Verified saved inverter with real SKY130:",report)
    try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  }
 }
}
