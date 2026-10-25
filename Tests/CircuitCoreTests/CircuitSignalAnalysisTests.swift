import Testing
import Foundation
@testable import CircuitCore
@Test func steadyStateRecordingStillCalculatesStartup() throws {
    var settings=SimulationSettings();settings.analysis = .tran;settings.timeStep="1u";settings.duration="8.01";settings.startSaving="8"
    #expect(try SPICENetlist.directive(settings)==".tran 1e-06 8.01 8.0")
    settings.startSaving="9";#expect(throws:Error.self){try SPICENetlist.directive(settings)}
    let legacy=try JSONSerialization.data(withJSONObject:["analysis":"Transient","start":"10","stop":"100Meg","points":40,"source":"V1","dcStart":"0","dcStop":"1.8","dcStep":"10m","timeStep":"1u","duration":"5m","probes":[]])
    #expect(try JSONDecoder().decode(SimulationSettings.self,from:legacy).startSaving==nil)
}
@Test func fftReportsActualFrequencyAndCorrectedPeakAmplitudeWithoutDCLeakage() throws {
    let n=4096,axis=(0..<4097).map{Double($0)/4096}
    let values=axis.map{Complex(12+2*sin(2*Double.pi*50*$0))}
    let input=SimulationResult(analysis:.tran,axis:axis,waveforms:[Waveform(name:"V(OUT)",values:values)],engine:"test samples")
    let fft=try CircuitSignalAnalysis.spectrum(input)
    let peak=fft.waveforms[0].values.indices.max{fft.waveforms[0].values[$0].magnitude<fft.waveforms[0].values[$1].magnitude}!
    #expect(abs(fft.axis[peak]-50)<1e-8)
    #expect(abs(fft.waveforms[0].values[peak].magnitude-2)<1e-4)
    #expect(fft.waveforms[0].values[0].magnitude<1e-4)
    #expect(input.axis.count==n+1)
}
@Test func powerAndEnergyUseNonuniformSolverTimes() throws {
    let axis=[0.0,0.1,0.4,1.0]
    let output=SimulationResult(analysis:.tran,axis:axis,waveforms:[Waveform(name:"V(A)",values:axis.map{Complex(2*$0)}),Waveform(name:"I(VR)",values:axis.map{_ in Complex(3)})],engine:"test samples")
    let (_,power)=try CircuitSignalAnalysis.power(output,positive:"A",current:"I(VR)")
    #expect(abs(power.integral-3)<1e-10);#expect(abs(power.mean-3)<1e-10)
    let (_,delivered)=try CircuitSignalAnalysis.power(output,positive:"A",current:"I(VR)",delivered:true)
    #expect(abs(delivered.integral+3)<1e-10)
}
@Test func actualLosslessDelayLineReturnsAvailablePortWaveforms() throws {
    var settings=SimulationSettings();settings.analysis = .tran;settings.timeStep="200p";settings.duration="100n"
    let result=try EmbeddedSpice.run(netlist:"VIN IN 0 PULSE(0 1 1n 100p 100p 1u 2u)\nRS IN P 50\nT1 P 0 OUT 0 Z0=50 TD=10n\nRL OUT 0 50",settings:settings)
    let output=try #require(result.waveform("OUT"))
    let before=try #require(result.axis.indices.min{abs(result.axis[$0]-5e-9)<abs(result.axis[$1]-5e-9)})
    let after=try #require(result.axis.indices.min{abs(result.axis[$0]-50e-9)<abs(result.axis[$1]-50e-9)})
    #expect(abs(output.values[before].real)<1e-6);#expect(abs(output.values[after].real-0.5)<1e-6)
}
