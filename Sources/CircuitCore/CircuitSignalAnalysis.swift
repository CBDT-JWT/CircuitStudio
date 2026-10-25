import Foundation
/// Derived views of actual solver samples; interpolation never reruns the circuit.
public enum CircuitSignalAnalysis {
    public struct Measurement:Sendable {public var mean:Double;public var rms:Double;public var integral:Double;public var minimum:Double;public var maximum:Double}
    public static func measure(axis:[Double],values:[Double]) throws -> Measurement {
        guard axis.count==values.count,axis.count>=2,axis.allSatisfy(\.isFinite),values.allSatisfy(\.isFinite),zip(axis,axis.dropFirst()).allSatisfy({$0<$1}) else{throw CircuitError.message("测量需要递增时间轴和至少两个有效样本。")}
        var area=0.0,square=0.0
        for i in 1..<axis.count {let dt=axis[i]-axis[i-1];area+=dt*(values[i]+values[i-1])/2;square+=dt*(values[i]*values[i]+values[i-1]*values[i-1])/2}
        let duration=axis.last!-axis[0]
        return Measurement(mean:area/duration,rms:sqrt(max(0,square/duration)),integral:area,minimum:values.min()!,maximum:values.max()!)
    }
    public static func power(_ result:SimulationResult,positive:String,negative:String?=nil,current:String,delivered:Bool=false) throws -> (Waveform,Measurement) {
        guard result.analysis == .tran,let p=result.waveform(positive),let i=result.waveform(current) else{throw CircuitError.message("功率测量需要瞬态电压与电流波形。")}
        let n=negative.flatMap{result.waveform($0)}
        guard negative==nil || n != nil else{throw CircuitError.message("参考电压波形不存在。")}
        let values=result.axis.indices.map{index in (delivered ? -1.0:1.0)*(p.values[index].real-(n?.values[index].real ?? 0))*i.values[index].real}
        let wave=Waveform(name:delivered ? "P(DELIVERED)":"P(ABSORBED)",values:values.map{Complex($0)})
        return (wave,try measure(axis:result.axis,values:values))
    }
    /// Hann-windowed FFT, linearly resampled from adaptive solver times. Positive
    /// frequency amplitudes are corrected for coherent window gain; DC is omitted.
    public static func spectrum(_ result:SimulationResult,limit:Int=8192) throws -> SimulationResult {
        guard result.analysis == .tran,result.axis.count>=16,let last=result.axis.last,last>result.axis[0],zip(result.axis,result.axis.dropFirst()).allSatisfy({$0<$1}) else{throw CircuitError.message("FFT 需要至少 16 个递增时间样本；请先运行瞬态仿真。")}
        var count=16;while count*2<=min(8192,max(16,limit),result.axis.count){count*=2}
        let first=result.axis[0],dt=(last-first)/Double(count)
        let window=(0..<count).map{0.5-0.5*cos(2*Double.pi*Double($0)/Double(count-1))},gain=window.reduce(0,+)
        var output=SimulationResult(analysis:.ac,axis:(1...count/2).map{Double($0)/(Double(count)*dt)},waveforms:[],engine:"FFT · "+result.engine)
        for wave in result.waveforms {
            var real=[Double](repeating:0,count:count),imag=real,cursor=0
            for index in 0..<count {
                let t=first+Double(index)*dt
                while cursor+1<result.axis.count-1 && result.axis[cursor+1]<t{cursor+=1}
                let fraction=(t-result.axis[cursor])/(result.axis[cursor+1]-result.axis[cursor])
                real[index]=wave.values[cursor].real+(wave.values[cursor+1].real-wave.values[cursor].real)*fraction
            }
            let mean=real.reduce(0,+)/Double(count)
            for i in 0..<count {real[i]=(real[i]-mean)*window[i]}
            var j=0
            for i in 1..<count {var bit=count>>1;while j&bit != 0 {j^=bit;bit>>=1};j^=bit;if i<j {real.swapAt(i,j);imag.swapAt(i,j)}}
            var length=2
            while length<=count {
                let angle = -2*Double.pi/Double(length),wr=cos(angle),wi=sin(angle)
                for start in stride(from:0,to:count,by:length) {
                    var ar=1.0,ai=0.0
                    for offset in 0..<length/2 {
                        let a=start+offset,b=a+length/2,tr=real[b]*ar-imag[b]*ai,ti=real[b]*ai+imag[b]*ar
                        real[b]=real[a]-tr;imag[b]=imag[a]-ti;real[a]+=tr;imag[a]+=ti
                        let next=ar*wr-ai*wi;ai=ar*wi+ai*wr;ar=next
                    }
                }
                length*=2
            }
            let values=(1...count/2).map{i in Complex(real[i]*(i==count/2 ? 1:2)/gain,imag[i]*(i==count/2 ? 1:2)/gain)}
            output.waveforms.append(Waveform(name:wave.name,values:values))
        }
        return output
    }
}
