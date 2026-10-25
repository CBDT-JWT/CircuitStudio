import XCTest
import CoreGraphics
import ImageIO
@testable import CircuitCore

final class PublicationAppearanceTests:XCTestCase {
    func testStylePersistsAndDoesNotChangeNets() throws {
        var circuit=CircuitTemplate.rcFilter.make()
        let topology=Connectivity(circuit).nets.map(\.name)
        circuit.applyPublicationPreset(.color)
        circuit.components[0].appearance=ObjectAppearance(color:"2563eb",textColor:"b91c1c",lineScale:1.5,fontScale:1.25)
        var wire=circuit.wires[0];wire.appearance=ObjectAppearance(color:"aa2299");circuit.wires[0]=wire
        circuit.labels[0].appearance=ObjectAppearance(color:"009966")
        let saved=try CircuitArchive.decode(CircuitArchive(circuit).encoded()).circuit
        XCTAssertEqual(saved,circuit);XCTAssertEqual(Connectivity(saved).nets.map(\.name),topology)
        let svg=CircuitExport.svg(saved)
        XCTAssertTrue(svg.contains("#2563eb"));XCTAssertTrue(svg.contains("#b91c1c"));XCTAssertTrue(svg.contains("#aa2299"));XCTAssertTrue(svg.contains("#009966"))
        XCTAssertEqual(saved.mode,.publication)
    }
    func testPhysicalExportAndTransparentBackground() throws {
        var circuit=CircuitTemplate.rcFilter.make();var style=PublicationAppearance();style.widthMM=85;style.background="e6f0ff";circuit.appearance=style
        let svg=CircuitExport.svg(circuit,transparent:false)
        XCTAssertTrue(svg.contains("width=\"85.0mm\""));XCTAssertTrue(svg.contains("#e6f0ff"))
        let pdf=try CircuitExport.pdf(circuit)
        let document=CGPDFDocument(CGDataProvider(data:pdf as CFData)!)!
        XCTAssertEqual(document.page(at:1)!.getBoxRect(.mediaBox).width,85*72/25.4,accuracy:0.01)
        let png=try CircuitExport.raster(circuit,scale:300/72,transparent:true)
        let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData,nil)!,0,nil)!
        XCTAssertEqual(image.width,Int(ceil(85/25.4*300)));XCTAssertNotEqual(image.alphaInfo,.none)
        XCTAssertNotNil(circuit.smallestPrintedFont)
    }
    func testInvalidAppearanceRejectedBeforeRendering() throws {
        var circuit=Circuit();let id=circuit.add(.resistor,at:.zero)
        circuit.components[0].appearance=ObjectAppearance(color:"\"/><script>")
        XCTAssertThrowsError(try CircuitArchive.decode(CircuitArchive(circuit).encoded()))
        circuit.components[0].appearance=ObjectAppearance(fontScale:-1)
        XCTAssertThrowsError(try CircuitArchive.decode(CircuitArchive(circuit).encoded()))
        XCTAssertEqual(id,circuit.components[0].id)
    }
    func testBlackAndWhiteIsAnExplicitUndoablePreset() throws {
        var circuit=CircuitTemplate.rcFilter.make();circuit.components[0].appearance=ObjectAppearance(color:"2563eb")
        circuit.applyPublicationPreset(.monochrome)
        XCTAssertNil(circuit.components[0].appearance?.color)
        XCTAssertEqual(circuit.appearance?.ink,"171717")
        let component=circuit.components[0]
        let plain=Symbols.componentLabels(component,theme:circuit.theme)
        let styled=Symbols.componentLabels(component,theme:circuit.theme,appearance:circuit.appearance)
        XCTAssertEqual(styled.count,plain.count)
        XCTAssertEqual(styled[0].text.size,plain[0].text.size*1.15,accuracy:0.0001)
    }
}
