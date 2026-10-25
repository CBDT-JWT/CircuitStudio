import Foundation
@main struct ReferenceSimulationVerification {
    static func main()throws {
        let source=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
        var settings=SimulationSettings();settings.analysis = .ac;settings.start="10";settings.stop="100k";settings.points=80
        let result=try EmbeddedSpice.run(netlist:source,settings:settings)
        guard let output=result.waveform("OUT"),result.axis.count > 100 else { throw CircuitError.message("The reference RC waveform is missing.") }
        var maximumError=0.0
        for (frequency,value) in zip(result.axis,output.values) {
            let expected=Complex(1)/Complex(1,2 * .pi * frequency * 1e-4)
            maximumError=max(maximumError,abs(value.real-expected.real),abs(value.imaginary-expected.imaginary))
        }
        guard maximumError < 1e-8 else { throw CircuitError.message("Reference project to ngspice transfer mismatch.") }
        let payload:[String:Any]=["passed":true,"engine":result.engine,"samples":result.axis.count,"maxComplexError":maximumError,"expectedCutoffHz":1/(2 * Double.pi * 1e-4),"waveforms":result.waveforms.map(\.name)]
        let data=try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(decoding:data,as:UTF8.self))
    }
}
