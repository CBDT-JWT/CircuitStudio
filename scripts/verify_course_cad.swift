import Foundation
@main struct CourseCADVerification {
    struct Example:Decodable {struct Preset:Decodable{var title:String;var settings:SimulationSettings};var id:String;var source:String;var modelPacket:String?;var runs:[Preset]}
    static func main() throws {
        let args=CommandLine.arguments
        let examples=try JSONDecoder().decode([Example].self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
        let example=examples.first{$0.id==args[3]}!
        let models=example.modelPacket == "gf180-tt" ? try String(contentsOfFile:args[2]+"/GF180MCU/gf180mcu-3p3-tt.spice",encoding:.utf8):""
        var checks:[[String:Any]]=[]
        for (index,preset) in example.runs.enumerated() {
            let started=Date()
            do {
                let result=try EmbeddedSpice.run(netlist:example.source,settings:preset.settings,models:models,timeout:35)
                guard !result.axis.isEmpty,!result.waveforms.isEmpty else{throw CircuitError.message("No actual samples")}
                var missing:[String]=[]
                for name in preset.settings.probes where result.waveform(name)==nil {missing.append(name)}
                guard missing.isEmpty else{throw CircuitError.message("Missing plotted probes: "+missing.joined(separator:","))}
                var vectors:[[String:Any]]=[]
                let at=result.axis.indices.min{abs(result.axis[$0]-1000)<abs(result.axis[$1]-1000)} ?? 0
                for wave in result.waveforms {
                    vectors.append(["name":wave.name,"minimum":wave.values.map(\.real).min() ?? 0,"maximum":wave.values.map(\.real).max() ?? 0,"first":wave.values[0].real,"last":wave.values.last!.real,"sampleAxis":result.axis[at],"sampleReal":wave.values[at].real,"sampleImaginary":wave.values[at].imaginary,"lastMagnitude":wave.values.last!.magnitude])
                }
                if example.id=="A1-03-01",let input=result.waveform("IN"),let output=result.waveform("OUT") {guard zip(input.values,output.values).allSatisfy({abs($0.real/2-$1.real)<1e-8}) else{throw CircuitError.message("Resistor divider analytical check failed")}}
                if example.id=="A1-11-01" {
                    let a="0011001011010".map{Int(String($0))!},b="0101100110010".map{Int(String($0))!}
                    guard let out=result.waveform("Z") else{throw CircuitError.message("Missing logic output")}
                    for i in a.indices {let t=Double(i)*100e-9+150e-9;let sample=result.axis.indices.min{abs(result.axis[$0]-t)<abs(result.axis[$1]-t)}!;let expected=a[i]&b[i];guard expected==1 ? out.values[sample].real>1.44:out.values[sample].real<0.36 else{throw CircuitError.message("Slow CMOS truth-table mismatch at bit \(i): \(out.values[sample].real)")}}
                }
                checks.append(["preset":index,"title":preset.title,"passed":true,"analysis":result.analysis.rawValue,"samples":result.axis.count,"engine":result.engine,"elapsed":Date().timeIntervalSince(started),"vectors":vectors,"operatingPoints":result.operatingPoints])
            }catch{checks.append(["preset":index,"title":preset.title,"passed":false,"elapsed":Date().timeIntervalSince(started),"error":error.localizedDescription])}
        }
        let body:[String:Any]=["id":example.id,"checks":checks,"passed":checks.allSatisfy{$0["passed"] as? Bool==true}]
        try JSONSerialization.data(withJSONObject:body,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[4]))
    }
}
