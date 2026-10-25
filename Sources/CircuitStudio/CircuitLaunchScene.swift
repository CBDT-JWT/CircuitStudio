#if os(iOS)
import SwiftUI

/// Keep the native document browser, including iCloud, recents and multiple windows.
struct CircuitLaunchScene: Scene {
    @Binding var showGuide: Bool

    var body: some Scene {
        DocumentGroupLaunchScene(
            Text("Circuit Studio")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(StudioStyle.accent)
        ) {
            CircuitLaunchActions(showGuide: $showGuide)
        } background: {
            CircuitLaunchPaper()
        } overlayAccessoryView: { geometry in
            CircuitLaunchAccessories(geometry: geometry)
        }
    }

}

private struct CircuitLaunchActions: View {
    @Binding var showGuide: Bool
    var body: some View {
        NewDocumentButton("新建电路", contentType: .circuit)
        Button("画板指南") { showGuide = true }
            .fullScreenCover(isPresented: $showGuide) {
                CircuitLaunchGuide { showGuide = false }
            }
    }
}

private struct CircuitLaunchPaper: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(
                scheme == .dark ? Color(red: 0.08, green: 0.11, blue: 0.11) : Color(red: 0.97, green: 0.98, blue: 0.96)
            ))
            var dots = Path()
            for x in stride(from: 12.0, to: size.width, by: 24) {
                for y in stride(from: 12.0, to: size.height, by: 24) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(StudioStyle.accent.opacity(scheme == .dark ? 0.17 : 0.12)))
        }.accessibilityHidden(true)
    }
}

private struct CircuitLaunchAccessories: View {
    let geometry: DocumentLaunchGeometryProxy
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let title = geometry.titleViewFrame
        let frame = geometry.frame
        ZStack {
            if !typeSize.isAccessibilitySize {
                VStack(spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(StudioStyle.accent)
                    Text("绘图 · 批注 · 本地仿真")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .position(x: title.midX, y: max(frame.minY + 48, title.minY - 45))
                if frame.width > 900 {
                    LaunchCircuitSketch()
                        .frame(width: 185, height: 135)
                        .rotationEffect(.degrees(-7))
                        .position(x: max(frame.minX + 125, title.minX - 130), y: title.midY + 12)
                    LaunchWaveSketch()
                        .frame(width: 160, height: 110)
                        .rotationEffect(.degrees(6))
                        .position(x: min(frame.maxX - 110, title.maxX + 120), y: title.midY + 12)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small circuit and response drawings use the same ink colour as the editor.
private struct LaunchCircuitSketch: View {
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            path.move(to: CGPoint(x: 18, y: 66)); path.addLine(to: CGPoint(x: 18, y: 25)); path.addLine(to: CGPoint(x: 49, y: 25))
            for (x, y) in [(55.0, 17.0), (63, 33), (71, 17), (79, 33), (87, 17), (95, 33), (101, 25)] { path.addLine(to: CGPoint(x: x, y: y)) }
            path.addLine(to: CGPoint(x: 147, y: 25)); path.addLine(to: CGPoint(x: 147, y: 62))
            path.move(to: CGPoint(x: 130, y: 62)); path.addLine(to: CGPoint(x: 164, y: 62))
            path.move(to: CGPoint(x: 130, y: 72)); path.addLine(to: CGPoint(x: 164, y: 72))
            path.move(to: CGPoint(x: 147, y: 72)); path.addLine(to: CGPoint(x: 147, y: 109)); path.addLine(to: CGPoint(x: 18, y: 109)); path.addLine(to: CGPoint(x: 18, y: 94))
            path.addEllipse(in: CGRect(x: 4, y: 66, width: 28, height: 28))
            path.move(to: CGPoint(x: 13, y: 75)); path.addLine(to: CGPoint(x: 23, y: 75)); path.move(to: CGPoint(x: 18, y: 70)); path.addLine(to: CGPoint(x: 18, y: 80))
            path.move(to: CGPoint(x: 13, y: 86)); path.addLine(to: CGPoint(x: 23, y: 86))
            context.stroke(path, with: .color(StudioStyle.accent.opacity(0.65)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            context.draw(Text("R").font(.system(size: 12, design: .serif)).foregroundStyle(.secondary), at: CGPoint(x: 74, y: 4))
            context.draw(Text("C").font(.system(size: 12, design: .serif)).foregroundStyle(.secondary), at: CGPoint(x: 177, y: 67))
        }
    }
}

private struct LaunchWaveSketch: View {
    var body: some View {
        Canvas { context, _ in
            var axes = Path()
            axes.move(to: CGPoint(x: 12, y: 8)); axes.addLine(to: CGPoint(x: 12, y: 88)); axes.addLine(to: CGPoint(x: 151, y: 88))
            context.stroke(axes, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            var wave = Path()
            wave.move(to: CGPoint(x: 12, y: 27))
            wave.addCurve(to: CGPoint(x: 145, y: 80), control1: CGPoint(x: 87, y: 27), control2: CGPoint(x: 72, y: 72))
            context.stroke(wave, with: .color(StudioStyle.accent.opacity(0.65)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.draw(Text("f").font(.system(size: 12, design: .serif)).foregroundStyle(.secondary), at: CGPoint(x: 147, y: 103))
        }
    }
}

private struct CircuitLaunchGuide: View {
    let done: () -> Void
    private let tools: [(String, String, String)] = [
        ("cursorarrow.rays", "元件库", "选择元件后点画布放置。支持晶体管、开关、受控源、逻辑门和信号流等 78 个参考库条目。"),
        ("pencil.tip", "批注笔", "记录推导与说明；长按切换颜色、笔粗和荧光笔。批注独立保存。"),
        ("sparkle", "激光笔", "用于讲解的红色指示线会自动淡出，不保存到文档。"),
        ("eraser", "橡皮擦", "默认擦除电路元件、导线与笔迹；长按可选择只擦批注、未识别笔迹或电路对象。支持撤销。"),
        ("selection.pin.in.out", "框选与复制", "在空白处拖出矩形，选中元件、导线和文字。复制后可直接以透明 PNG 粘贴到 Office 或其他 App；长按可切换套索。"),
        ("plus", "添加", "添加标准元件、网络标签，或复制当前选区。")
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("一张画板，绘图与思考。")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("画板默认使用矩形框选，手指和 Pencil 均可选择、放置与移动对象。双指移动画布，捏合缩放。批注笔仍默认仅接受 Pencil，长按可开启手指绘图。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(tools, id: \.1) { tool in
                        HStack(alignment: .top, spacing: 18) {
                            Image(systemName: tool.0).font(.system(size: 24)).foregroundStyle(StudioStyle.accent).frame(width: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tool.1).font(.headline)
                                Text(tool.2).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Text("从电路模板开始").font(.title3.bold())
                    Text("在编辑器左侧点 Explore templates，可套用共源放大器、差分对、电流镜、RC 滤波器或 CMOS 反相器。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("电路元件由元件库放置，手写识别暂不开放。CircuitAI 通过服务器连接，购买订阅后自动连接；绘图、复制导出和本地仿真可离线使用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("画板指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: done) } }
        }.tint(StudioStyle.accent)
    }
}
#endif
