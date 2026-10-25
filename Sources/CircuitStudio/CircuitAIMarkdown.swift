#if os(macOS)
import SwiftUI
import WebKit

struct CircuitAIMarkdown:View {
    let text:String
    @State private var height:CGFloat=60
    var body:some View { MarkdownBrowser(text:text,height:$height).frame(height:height) }
}
/// WebKit consumes wheel events even when a reply has no internal vertical scroll.
/// Route vertical gestures to the enclosing conversation without changing text selection.
final class TranscriptMarkdownWebView:WKWebView {
    private var scrollMonitor:Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopScrollForwarding()
        guard window != nil else { return }
        scrollMonitor=NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) { [weak self] event in
            guard let self,self.window === event.window,!self.isHiddenOrHasHiddenAncestor,
                  self.visibleRect.contains(self.convert(event.locationInWindow,from:nil)),
                  abs(event.scrollingDeltaY)>=abs(event.scrollingDeltaX),
                  let conversation=self.conversationScrollView else { return event }
            conversation.scrollWheel(with:event)
            return nil
        }
    }
    var conversationScrollView:NSScrollView? {
        var ancestor=superview
        while let view=ancestor {
            if let scroll=view as? NSScrollView { return scroll }
            ancestor=view.superview
        }
        return nil
    }
    func stopScrollForwarding() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor);self.scrollMonitor=nil }
    }
}
private struct MarkdownBrowser:NSViewRepresentable {
    let text:String;@Binding var height:CGFloat
    func makeCoordinator()->Coordinator { Coordinator(parent:self) }
    func makeNSView(context:Context)->WKWebView {
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator,name:"markdown")
        let view=TranscriptMarkdownWebView(frame:.zero,configuration:configuration);view.navigationDelegate=context.coordinator
        view.setValue(false,forKey:"drawsBackground")
        if let root=Bundle.main.url(forResource:"EngineeringEditor",withExtension:nil) {
            let folder=root.appendingPathComponent("markdown")
            view.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder)
        }
        return view
    }
    func updateNSView(_ view:WKWebView,context:Context) {
        context.coordinator.parent=self
        if context.coordinator.ready,context.coordinator.rendered != text { context.coordinator.render(view) }
    }
    static func dismantleNSView(_ view:WKWebView,coordinator:Coordinator) { (view as? TranscriptMarkdownWebView)?.stopScrollForwarding();view.configuration.userContentController.removeScriptMessageHandler(forName:"markdown");view.stopLoading() }
    @MainActor final class Coordinator:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
        var parent:MarkdownBrowser;var ready=false;var rendered=""
        init(parent:MarkdownBrowser) { self.parent=parent }
        func render(_ view:WKWebView) { rendered=parent.text;view.callAsyncJavaScript("window.renderCircuitMarkdown(text)",arguments:["text":parent.text],in:nil,in:.page,completionHandler:nil) }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { ready=true;render(webView) }
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
            guard message.frameInfo.isMainFrame,message.frameInfo.request.url?.isFileURL==true,let body=message.body as? [String:Any] else { return }
            if let height=body["height"] as? Double,height.isFinite { parent.height=CGFloat(min(20000,max(24,height))) }
            if let text=body["copy"] as? String,text.utf8.count<=100_000 { NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string) }
        }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor (WKNavigationActionPolicy)->Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url=navigationAction.request.url,["https","http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(navigationAction.request.url?.isFileURL==true ? .allow : .cancel) }
        }
    }
}
#endif
