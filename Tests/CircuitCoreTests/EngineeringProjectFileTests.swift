import XCTest
@testable import CircuitCore

final class EngineeringProjectFileTests:XCTestCase {
    func testLegacyPackageIsReadWithoutChangingItsDocumentOrPreview() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".circuit")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:folder)}
        let data=try CircuitArchive(CircuitTemplate.rcFilter.make()).encoded(),preview=Data([1,2,3])
        try data.write(to:folder.appendingPathComponent("document.json"));try preview.write(to:folder.appendingPathComponent("preview.png"))
        let result=try EngineeringProjectFile.read(folder)
        XCTAssertTrue(result.importedLegacy);XCTAssertEqual(result.sourceData,data)
        let packet=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(result.text.utf8)) as? [String:Any])
        XCTAssertEqual(packet["schema"] as? String,"circuitstudio-native-import-v1")
        XCTAssertFalse(try XCTUnwrap(packet["terminalNets"] as? [String:Any]).isEmpty)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("document.json")),data)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("preview.png")),preview)
    }
    func testNewEngineeringProjectIsNotTreatedAsLegacyInput() throws {
        let data=Data(#"{"schema":"circuitstudio-project-v1","cells":[]}"#.utf8)
        let result=try EngineeringProjectFile.prepare(data)
        XCTAssertFalse(result.importedLegacy);XCTAssertEqual(Data(result.text.utf8),data)
    }
    func testFutureNativeArchivesAndUnrelatedJSONFailBeforeOpening() throws {
        var archive=CircuitArchive(Circuit());archive.formatVersion=999
        XCTAssertThrowsError(try EngineeringProjectFile.prepare(archive.encoded()))
        XCTAssertThrowsError(try EngineeringProjectFile.prepare(Data(#"{"message":"unrelated"}"#.utf8)))
    }
    func testPackageCannotReadADocumentOutsideTheSelectedPackage() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder=root.appendingPathComponent("Bad.circuit"),outside=root.appendingPathComponent("outside.json")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try CircuitArchive(Circuit()).encoded().write(to:outside)
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("document.json"),withDestinationURL:outside)
        XCTAssertThrowsError(try EngineeringProjectFile.read(folder))
    }
}
