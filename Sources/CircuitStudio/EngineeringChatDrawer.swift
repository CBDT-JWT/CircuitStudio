import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct EngineeringChatDrawer:View {
    @Bindable var chat:EngineeringChat
    var close:()->Void
    var snapshot:@MainActor () async throws -> String
    var execute:@MainActor (String,String,CircuitAIStamp) async throws -> CircuitAIToolResult
    var figureChanged:(CircuitAIFigure)->Void = {_ in}
    var showsClose=true
    @AppStorage("circuit-ai-data-consent-v1") private var cloudConsent=false
    @State private var choosingImages=false
    @State private var dropTarget=false
    @State private var purchase=false
    @State private var redeem=false
    #if DEBUG
    @State private var relaySettings=false
    #endif
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"sparkles").foregroundStyle(StudioStyle.accent)
                VStack(alignment:.leading,spacing:3) { Text("CircuitAI").font(.headline);Text(chat.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                #if DEBUG
                Button { relaySettings=true } label: { Image(systemName:"gearshape").frame(width:28,height:28) }.buttonStyle(.plain).help("服务器连接设置").accessibilityLabel("服务器连接设置")
                #endif
                if showsClose {Button(action:close) { Image(systemName:"xmark").frame(width:28,height:28) }.buttonStyle(.plain).help("关闭对话").accessibilityLabel("关闭对话")}
            }.padding(18)
            Divider()
            if chat.preparing { Spacer();ProgressView("正在读取当前电路…");Spacer() }
            else if !chat.subscription.canRequest { connectionForm }
            else if !cloudConsent {
                VStack(alignment:.leading,spacing:18){Image(systemName:"sparkles").font(.largeTitle).foregroundStyle(StudioStyle.accent);Text("使用 CircuitAI").font(.title2.weight(.semibold));Text("发送消息时，当前电路的连接、器件参数、对话及你添加的图片会经开发者服务器发送给 DeepSeek，以解读和修改电路。仿真在本机运行；AI 会读取其结果与曲线。").font(.callout);Link("隐私政策",destination:URL(string:"https://www.weitao-jiang.cn/static/circuit-studio/privacy.html")!);Button("同意并继续"){cloudConsent=true}.buttonStyle(.borderedProminent);Button("暂不使用",action:close).buttonStyle(.plain)}.padding(24).frame(maxHeight:.infinity)
            }
            else { conversation }
        }
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
        .overlay { RoundedRectangle(cornerRadius:20).stroke(.white.opacity(0.6),lineWidth:1) }
        .clipShape(RoundedRectangle(cornerRadius:20))
        .shadow(color:.black.opacity(0.08),radius:22,y:8)
        #if DEBUG
        .sheet(isPresented:$relaySettings) { RelaySettingsView(saved:{ chat.subscription.refreshRelay() }) }
        #endif
        .fileImporter(isPresented:$choosingImages,allowedContentTypes:[.image],allowsMultipleSelection:true) {result in do{for url in try result.get(){chat.attach(try CircuitAIImageAttachment.read(url))}}catch{chat.error=error.localizedDescription}}
        .offerCodeRedemption(isPresented:$redeem) { result in
            if case .failure(let error)=result { chat.error=error.localizedDescription }
            Task { await chat.subscription.refresh() }
        }
        .sheet(isPresented:$purchase) {
            SubscriptionStoreView(productIDs:chat.subscription.productIDs)
                .subscriptionStorePolicyDestination(url:URL(string:"https://www.weitao-jiang.cn/static/circuit-studio/privacy.html")!,for:.privacyPolicy)
                .subscriptionStorePolicyDestination(url:URL(string:"https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,for:.termsOfService)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { purchase=false } } }
                .onInAppPurchaseCompletion { _,result in
                    if case .success(.success(let verification))=result,case .verified(let transaction)=verification {
                        await chat.subscription.refresh();await transaction.finish();purchase=false
                    } else if case .success(.pending)=result { chat.subscription.activationStatus="购买正在等待批准，通过后会自动连接。" }
                }
        }
    }
    private var connectionForm:some View {
        VStack(alignment:.leading,spacing:18) {
            Spacer(minLength:0)
            Image(systemName:"person.crop.circle.badge.checkmark").font(.system(size:32)).foregroundStyle(StudioStyle.accent)
            Text("连接 AI 电路助手").font(.title3.weight(.semibold))
            Text("使用 App Store 订阅身份验证。购买或恢复后自动连接，无需另建账号。").font(.callout).foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:6) {
                Text("AI 月度订阅").font(.headline)
                Text("订阅后即可使用电路助手").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.background.opacity(0.7),in:RoundedRectangle(cornerRadius:13))
            Button { purchase=true } label: { Text(chat.subscription.monthlyPrice.isEmpty ? "在 App Store 订阅" : "订阅 · \(chat.subscription.monthlyPrice) / 月").frame(maxWidth:.infinity).padding(.vertical,5) }.buttonStyle(.borderedProminent).disabled(!chat.subscription.isConfigured)
            Button("已有订阅，恢复购买") { Task { await chat.subscription.restore() } }.disabled(chat.subscription.checking).frame(maxWidth:.infinity)
            Button("兑换优惠码") { redeem=true }.font(.caption).frame(maxWidth:.infinity)
            #if DEBUG
            Button("连接我的服务器（开发测试）") { relaySettings=true }.font(.caption).frame(maxWidth:.infinity)
            #endif
            if chat.subscription.checking || chat.subscription.activating { ProgressView("正在验证并连接…").controlSize(.small) }
            if !chat.subscription.activationStatus.isEmpty { Text(chat.subscription.activationStatus).font(.caption).foregroundStyle(.secondary) }
            if let error=chat.subscription.error ?? chat.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("价格以 App Store 确认页面为准。").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength:0)
        }.padding(22)
    }
    private var conversation:some View {
        VStack(spacing:0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:16) {
                        if chat.messages.isEmpty {
                            VStack(alignment:.leading,spacing:14) {
                                Text("聊聊这张电路").font(.title3.weight(.semibold))
                                Text("直接提问，或选一个问题开始。").font(.callout).foregroundStyle(.secondary)
                                ForEach(["解读这个电路的功能和信号路径","检查连接与元件参数","建议需要运行的仿真"],id:\.self) { question in Button(question) { chat.send(question,snapshot:snapshot,execute:execute) }.buttonStyle(.bordered).disabled(chat.sending) }
                            }.padding(.vertical,16)
                        }
                        ForEach(chat.messages) { message in
                            VStack(alignment:.leading,spacing:7) {
                                Text(message.role == "user" ? "你" : message.role == "tool" ? "操作结果" : "CircuitAI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                if message.role=="tool" { Text(message.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } else { CircuitAIMarkdown(text:message.text).frame(maxWidth:.infinity,alignment:.leading) }
                                if !message.attachments.isEmpty {ScrollView(.horizontal){HStack{ForEach(message.attachments){attachment in CircuitDataImage(data:attachment.data).aspectRatio(contentMode:.fit).frame(height:110).accessibilityLabel(attachment.name)}}}}
                                ForEach(message.figures) {figure in CircuitAIFigureCard(figure:figure,update:figureChanged)}
                            }.padding(14).background(message.role == "user" ? StudioStyle.accent.opacity(0.07) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14)).id(message.id)
                        }
                        if let question=chat.pendingQuestion {
                            VStack(alignment:.leading,spacing:12) {
                                Label("需要补充的信息",systemImage:"questionmark.bubble").font(.caption.weight(.semibold)).foregroundStyle(StudioStyle.accent)
                                Text(question.value.question).font(.callout.weight(.semibold))
                                ForEach(question.value.options) { option in
                                    Button { chat.answerQuestion(option.label,snapshot:snapshot,execute:execute) } label: {
                                        VStack(alignment:.leading,spacing:4) { Text(option.label).font(.callout);if let detail=option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth:.infinity,alignment:.leading).padding(11)
                                    }.buttonStyle(.plain).background(.background.opacity(0.65),in:RoundedRectangle(cornerRadius:10))
                                }
                                Text("也可以在下方输入自己的答案。").font(.caption).foregroundStyle(.secondary)
                            }.padding(15).background(StudioStyle.accent.opacity(0.07),in:RoundedRectangle(cornerRadius:14))
                        }
                        if chat.sending { HStack { ProgressView().controlSize(.small);Text(chat.activity.isEmpty ? "正在思考…" : chat.activity).font(.caption).foregroundStyle(.secondary);Spacer();Button("停止") { chat.cancel() }.font(.caption) } }
                        if let error=chat.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        Color.clear.frame(height:1).id("end")
                    }.padding(18)
                }.onChange(of:chat.messages.count) { _,_ in withAnimation { reader.scrollTo("end",anchor:.bottom) } }.onChange(of:chat.pendingQuestion?.call.id) { _,_ in withAnimation { reader.scrollTo("end",anchor:.bottom) } }
            }
            Divider()
            #if DEBUG
            if chat.subscription.privateRelay {
                HStack(spacing:5) {
                    Image(systemName:"server.rack")
                    Text(chat.subscription.activationStatus.isEmpty ? "通过你的服务器连接 CircuitAI" : chat.subscription.activationStatus)
                    Spacer(minLength:0)
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal,16).padding(.top,10)
                if let error=chat.subscription.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal,16) }
            }
            #endif
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal) {HStack(spacing:8){ForEach(chat.attachments){attachment in
                    ZStack(alignment:.topTrailing){CircuitDataImage(data:attachment.data).aspectRatio(contentMode:.fit).frame(width:76,height:64).clipShape(RoundedRectangle(cornerRadius:8));Button{chat.removeAttachment(attachment.id)}label:{Image(systemName:"xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white,.black.opacity(0.6))}.buttonStyle(.plain).accessibilityLabel("移除图片："+attachment.name).disabled(chat.sending)}
                }}}.padding(.horizontal,16).padding(.top,10)
            }
            HStack(alignment:.bottom,spacing:10) {
                Menu {Button("选择图片…",action:chooseImages);Button("粘贴图片",action:pasteImage)} label:{Image(systemName:"photo.badge.plus").font(.system(size:19))}.menuStyle(.borderlessButton).fixedSize().help("添加图片").accessibilityLabel("添加图片").disabled(chat.sending)
                TextField("询问当前电路…",text:$chat.draft,axis:.vertical).lineLimit(2...5).textFieldStyle(.plain).onSubmit { chat.submit(snapshot:snapshot,execute:execute) }
                Button { chat.submit(snapshot:snapshot,execute:execute) } label: { Image(systemName:"arrow.up.circle.fill").font(.system(size:27)) }.buttonStyle(.plain).foregroundStyle(StudioStyle.accent).disabled(chat.sending || (chat.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty)).help("发送").accessibilityLabel("发送")
            }.padding(16).background(dropTarget ? StudioStyle.accent.opacity(0.1):.clear)
             .onDrop(of:[UTType.image.identifier,UTType.fileURL.identifier],isTargeted:$dropTarget,perform:dropImages)
             #if os(macOS)
             .onPasteCommand(of:[.image],perform:{_ = dropImages($0)})
             #endif
            Text("可添加或拖入图片；发送后分析。仿真曲线可编辑、复制与导出。").font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,16).padding(.bottom,14)
        }
    }
    private func chooseImages() {
        #if os(macOS)
        let panel=NSOpenPanel();panel.allowedContentTypes=[.image];panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        guard panel.runModal() == .OK else{return}
        for url in panel.urls {do{chat.attach(try CircuitAIImageAttachment.read(url))}catch{chat.error=error.localizedDescription}}
        #else
        choosingImages=true
        #endif
    }
    private func pasteImage() {
        #if os(macOS)
        let pasted=NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff)
        #else
        let pasted=UIPasteboard.general.image?.pngData()
        #endif
        guard let bytes=pasted else {chat.error="剪贴板中没有图片。";return}
        do{chat.attach(try CircuitAIImageAttachment.read(bytes,name:"粘贴的图片"))}catch{chat.error=error.localizedDescription}
    }
    private func dropImages(_ providers:[NSItemProvider])->Bool {
        guard !chat.sending else{return false}
        let project=chat.projectID
        for provider in providers.prefix(4) {
            let imageName=provider.suggestedName ?? "拖入的图片"
            if let type=provider.registeredTypeIdentifiers.first(where:{UTType($0)?.conforms(to:.image) == true}) {
                provider.loadDataRepresentation(forTypeIdentifier:type){data,error in Task{@MainActor in guard chat.projectID==project else{return};do{guard let data else{throw error ?? CircuitError.message("无法读取图片。")};chat.attach(try CircuitAIImageAttachment.read(data,name:imageName))}catch{chat.error=error.localizedDescription}}}
            }else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){data,_ in Task{@MainActor in guard chat.projectID==project,let data,let text=String(data:data,encoding:.utf8),let url=URL(string:text),url.isFileURL else{return};do{chat.attach(try CircuitAIImageAttachment.read(url))}catch{chat.error=error.localizedDescription}}}
            }
        }
        return true
    }
}
