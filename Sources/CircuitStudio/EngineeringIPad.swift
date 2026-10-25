#if os(iOS)
import SwiftUI
import WebKit
import UIKit
struct EngineeringBrowser:UIViewRepresentable {
    let workspace:EngineeringWorkspace;let url:URL
    func makeCoordinator()->Coordinator {Coordinator(workspace:workspace,url:url)}
    func makeUIView(context:Context)->WKWebView {
        let configuration=WKWebViewConfiguration();configuration.userContentController.addScriptMessageHandler(context.coordinator,contentWorld:.page,name:"circuitStudio")
        let view=WKWebView(frame:.zero,configuration:configuration);view.navigationDelegate=context.coordinator;view.uiDelegate=context.coordinator
        view.scrollView.isScrollEnabled=false;view.isOpaque=false;view.backgroundColor = .systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        workspace.webView=view;view.load(URLRequest(url:url));return view
    }
    func updateUIView(_ view:WKWebView,context:Context) {}
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator) {view.configuration.userContentController.removeScriptMessageHandler(forName:"circuitStudio",contentWorld:.page);view.stopLoading()}
    @MainActor final class Coordinator:NSObject,WKScriptMessageHandlerWithReply,WKNavigationDelegate,WKUIDelegate {
        let workspace:EngineeringWorkspace
        let url:URL

        init(workspace:EngineeringWorkspace,url:URL) { self.workspace=workspace;self.url=url }
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage,replyHandler:@escaping @MainActor @Sendable (Any?,String?)->Void) {
            guard message.frameInfo.isMainFrame,message.frameInfo.securityOrigin.protocol == "http",message.frameInfo.securityOrigin.host == "127.0.0.1",message.frameInfo.securityOrigin.port == url.port,
                  let envelope=message.body as? [String:Any],let action=envelope["action"] as? String else { replyHandler(nil,"Untrusted editor frame");return }
            let payload=envelope["payload"] as? [String:Any] ?? [:]
            if action == "simulation-drawer" {
                workspace.simulate();if payload["run"] as? Bool == true {Task{await workspace.runDrawerSimulation()}}
                replyHandler(["ok":true],nil);return
            }
            if action == "simulation-probe-mode" {
                if payload["id"] as? String == workspace.chat.projectID {workspace.simulationDraft.pickingProbes=payload["active"] as? Bool ?? false}
                replyHandler(["ok":true],nil);return
            }
            if action == "simulation-probe" {
                Task {do {
                    let stamp=try CircuitAIStamp.context(try await workspace.assistantSnapshot())
                    guard payload["id"] as? String == stamp.projectID,let name=payload["name"] as? String,!name.isEmpty,name.count<200 else{throw CircuitError.message("工程已切换，请重新选择观测网络。")}
                    if workspace.simulationDraft.projectID != stamp.projectID {await workspace.refreshSimulationDraft()}
                    let draft=workspace.simulationDraft
                    if let index=draft.value.settings.probes.firstIndex(where:{$0.caseInsensitiveCompare(name) == .orderedSame}){draft.value.settings.probes.remove(at:index)}else{draft.value.settings.probes.append(name)}
                    try await workspace.saveSimulationDraft(draft.value,projectID:stamp.projectID)
                    draft.notice="观测网络："+draft.value.settings.probes.joined(separator:", ")
                    replyHandler(["ok":true],nil)
                }catch{replyHandler(["error":error.localizedDescription],nil)}};return
            }
            if action == "model-library" {
                do { replyHandler(try workspace.modelLibrary.handle(payload),nil) } catch { replyHandler(["error":error.localizedDescription],nil) }
                return
            }
            if action == "assistant-context" {
                if let text=payload["context"] as? String,text.utf8.count<10000 { try? workspace.chat.activate(text) }
                replyHandler(["ok":true],nil);return
            }
            if action == "confirm-close" {
                guard let presenter=CircuitImageActions.controller else{replyHandler(["decision":"cancel"],nil);return}
                let alert=UIAlertController(title:"保存修改？",message:payload["name"] as? String,preferredStyle:.alert)
                if payload["canSave"] as? Bool == true{alert.addAction(UIAlertAction(title:"保存",style:.default){_ in replyHandler(["decision":"save"],nil)})}
                alert.addAction(UIAlertAction(title:"不保存",style:.destructive){_ in replyHandler(["decision":"discard"],nil)})
                alert.addAction(UIAlertAction(title:"取消",style:.cancel){_ in replyHandler(["decision":"cancel"],nil)})
                presenter.present(alert,animated:true);return
            }
            if action == "simulation-run" {
                Task {
                    do { replyHandler(try await workspace.runSimulation(payload:payload),nil) }
                    catch { replyHandler(["error":error.localizedDescription],nil) }
                }
                return
            }
            Task {do {
                if action == "simulation-result-status" { replyHandler(["available":workspace.hasSimulationResult(id:payload["id"] as? String ?? "")],nil) }
                else if action == "simulation-results" { try workspace.showSimulationResult(id:payload["id"] as? String ?? "");replyHandler([:],nil) }
                else { replyHandler(try await workspace.files.handle(action,payload:payload),nil) }
            }
            catch { replyHandler(["error":error.localizedDescription],nil) }}
        }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor (WKNavigationActionPolicy)->Void) {
            guard let target=navigationAction.request.url,target.scheme == "http",target.host == "127.0.0.1",target.port == url.port else { decisionHandler(.cancel);return };decisionHandler(.allow)
        }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { workspace.error=error.localizedDescription }
        func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping @MainActor ()->Void) {
            guard let presenter=CircuitImageActions.controller else{completionHandler();return};let alert=UIAlertController(title:"Circuit Studio",message:String(message.prefix(2000)),preferredStyle:.alert);alert.addAction(UIAlertAction(title:"好",style:.default){_ in completionHandler()});presenter.present(alert,animated:true)
        }
        func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping @MainActor (Bool)->Void) {
            guard let presenter=CircuitImageActions.controller else{completionHandler(false);return};let alert=UIAlertController(title:"Circuit Studio",message:String(message.prefix(2000)),preferredStyle:.alert);alert.addAction(UIAlertAction(title:"继续",style:.default){_ in completionHandler(true)});alert.addAction(UIAlertAction(title:"取消",style:.cancel){_ in completionHandler(false)});presenter.present(alert,animated:true)
        }
    }
}
#endif
