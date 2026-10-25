import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import UniformTypeIdentifiers

struct CircuitAIImageAttachment:Identifiable,Equatable {
    let id=UUID();let name:String;let data:Data
    var dataURL:String {"data:image/jpeg;base64,"+data.base64EncodedString()}
    static func read(_ bytes:Data,name:String)throws->Self {
        guard bytes.count<=20_000_000,let source=CGImageSourceCreateWithData(bytes as CFData,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {throw CircuitError.message("请选择 20MB 以内的有效图片。")}
        guard let canvas=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {throw CircuitError.message("无法读取图片像素。")}
        canvas.setFillColor(CGColor(gray:1,alpha:1));canvas.fill(CGRect(x:0,y:0,width:cg.width,height:cg.height));canvas.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        guard let opaque=canvas.makeImage() else {throw CircuitError.message("无法转换图片。")}
        for quality in [0.85,0.7,0.5,0.3] {
            let buffer=NSMutableData()
            if let destination=CGImageDestinationCreateWithData(buffer,UTType.jpeg.identifier as CFString,1,nil) {
                CGImageDestinationAddImage(destination,opaque,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
                if CGImageDestinationFinalize(destination),buffer.length<=600_000{return .init(name:String(name.prefix(100)),data:buffer as Data)}
            }
        }
        throw CircuitError.message("图片过大，请裁剪后再试。")
    }
    static func read(_ url:URL)throws->Self {
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=20_000_000 else {throw CircuitError.message("请选择 20MB 以内的图片。")}
        return try read(Data(contentsOf:url),name:url.lastPathComponent)
    }
}

struct CircuitDataImage:View {
    let data:Data
    var body:some View {
        #if os(macOS)
        if let image=NSImage(data:data){Image(nsImage:image).resizable()}
        #else
        if let image=UIImage(data:data){Image(uiImage:image).resizable()}
        #endif
    }
}
@MainActor enum CircuitImageActions {
    static func copy(_ data:Data) {
        #if os(macOS)
        NSPasteboard.general.clearContents();NSPasteboard.general.setData(data,forType:.png)
        #else
        UIPasteboard.general.setData(data,forPasteboardType:UTType.png.identifier)
        #endif
    }
    static func export(_ data:Data,name:String) {
        #if os(macOS)
        let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue=name
        if panel.runModal() == .OK,let url=panel.url {do{try data.write(to:url,options:.atomic)}catch{NSAlert(error:error).runModal()}}
        #else
        do {let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let url=folder.appendingPathComponent(name);try data.write(to:url);share(url)}catch{}
        #endif
    }
    #if os(iOS)
    static var controller:UIViewController? {
        var current=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap(\.windows).first(where:{$0.isKeyWindow})?.rootViewController
        while let presented=current?.presentedViewController{current=presented};return current
    }
    static func share(_ url:URL) {
        guard let presenter=controller else{return};let sheet=UIActivityViewController(activityItems:[url],applicationActivities:nil)
        sheet.popoverPresentationController?.sourceView=presenter.view;sheet.popoverPresentationController?.sourceRect=CGRect(x:presenter.view.bounds.midX,y:presenter.view.bounds.maxY-30,width:1,height:1)
        presenter.present(sheet,animated:true)
    }
    #endif
}
