#if os(iOS)
import SwiftUI
import WebKit
import UIKit
struct CircuitAIMarkdown:View {
    let text:String
    @State private var height:CGFloat=60
    var body:some View {MarkdownBrowser(text:text,height:$height).frame(height:height)}
}
private struct MarkdownBrowser:UIViewRepresentable {
    let text:String;@Binding var height:CGFloat
    func makeCoordinator()->Coordinator { Coordinator(parent:self) }
    func makeUIView(context:Context)->WKWebView {
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator,name:"markdown")
        let view=WKWebView(frame:.zero,configuration:configuration);view.navigationDelegate=context.coordinator
        view.isOpaque=false;view.backgroundColor = .clear;view.scrollView.isScrollEnabled=false;view.scrollView.backgroundColor = .clear;view.scrollView.contentInsetAdjustmentBehavior = .never
        if let root=Bundle.main.url(forResource:"EngineeringEditor",withExtension:nil) {
            let folder=root.appendingPathComponent("markdown")
            view.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder)
        }
        return view
    }
    func updateUIView(_ view:WKWebView,context:Context) {
        context.coordinator.parent=self
        if context.coordinator.ready,context.coordinator.rendered != text { context.coordinator.render(view) }
    }
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName:"markdown");view.stopLoading() }
    @MainActor final class Coordinator:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
        var parent:MarkdownBrowser;var ready=false;var rendered=""
        init(parent:MarkdownBrowser) { self.parent=parent }
        func render(_ view:WKWebView) { rendered=parent.text;view.callAsyncJavaScript("window.renderCircuitMarkdown(text)",arguments:["text":parent.text],in:nil,in:.page,completionHandler:nil) }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { ready=true;render(webView) }
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
            guard message.frameInfo.isMainFrame,message.frameInfo.request.url?.isFileURL==true,let body=message.body as? [String:Any] else { return }
            if let height=body["height"] as? Double,height.isFinite { parent.height=CGFloat(min(20000,max(24,height))) }
            if let text=body["copy"] as? String,text.utf8.count<=100_000 { UIPasteboard.general.string=text }
        }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor (WKNavigationActionPolicy)->Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url=navigationAction.request.url,["https","http"].contains(url.scheme) { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(navigationAction.request.url?.isFileURL==true ? .allow : .cancel) }
        }
    }
}

#endif
