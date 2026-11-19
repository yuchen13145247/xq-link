import SwiftUI
import UIKit

struct ContentView: View {

    @ObservedObject private var engine = Pikafish.shared

    @State private var fen = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
    @State private var depth = 14.0
    @State private var best = "-"
    @State private var busy = false

    // 棋盘两点标定（对角交叉点，单位 point）
    @AppStorage("tlX") private var tlX = 40.0
    @AppStorage("tlY") private var tlY = 180.0
    @AppStorage("brX") private var brX = 350.0
    @AppStorage("brY") private var brY = 620.0

    @State private var calibrating = false
    @State private var calStep = 0
    @State private var calFirst: CGPoint?

    var body: some View {
        NavigationView {
            Form {
                Section("引擎") {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(engine.ready ? "就绪" : "启动中…")
                            .foregroundColor(engine.ready ? .green : .orange)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("搜索深度 \(Int(depth))").font(.caption)
                        Slider(value: $depth, in: 6...24, step: 1)
                    }
                    Button {
                        askEngine()
                    } label: {
                        Label("计算最佳着法", systemImage: "bolt.fill")
                    }
                    .disabled(busy || !engine.ready)

                    HStack {
                        Text("最佳着法")
                        Spacer()
                        Text(best)
                            .font(.system(.title3, design: .monospaced))
                            .bold()
                    }
                    if !engine.lastInfo.isEmpty {
                        Text(engine.lastInfo)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }

                Section("局面 FEN") {
                    TextEditor(text: $fen)
                        .frame(minHeight: 90)
                        .font(.system(.footnote, design: .monospaced))
                    Button("恢复开局局面") {
                        fen = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
                    }
                }

                Section("连线（注入点击）") {
                    HStack {
                        Text("注入能力")
                        Spacer()
                        Text(TouchInjector.shared.available ? "可用" : "不可用（缺 entitlements）")
                            .foregroundColor(TouchInjector.shared.available ? .green : .red)
                    }
                    HStack {
                        Text("左上 / 右下").font(.caption)
                        Spacer()
                        Text(String(format: "%.0f,%.0f / %.0f,%.0f", tlX, tlY, brX, brY))
                            .font(.caption.monospacedDigit())
                    }
                    Button {
                        calibrating = true
                        calStep = 0
                        calFirst = nil
                    } label: {
                        Label("标定棋盘（点两个对角交叉点）", systemImage: "scope")
                    }
                    Button {
                        playBest()
                    } label: {
                        Label("把最佳着法落到对面", systemImage: "hand.tap.fill")
                    }
                    .disabled(best == "-" || !TouchInjector.shared.available)
                    Button("测试点击屏幕中心") {
                        let b = UIScreen.main.bounds
                        TouchInjector.shared.tap(x: b.midX, y: b.midY)
                    }
                    .disabled(!TouchInjector.shared.available)
                }

                Section {
                    Text("流程：标定棋盘 → 填 FEN → 计算 → 落到对面。FEN 首行是黑方底线，红方在下方。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("象棋连线")
            .overlay { if calibrating { calibrationLayer } }
            .onAppear {
                engine.onBestMove = { mv in
                    best = mv
                    busy = false
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 标定

    private var calibrationLayer: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                Text(calStep == 0 ? "点棋盘【左上角交叉点】" : "点棋盘【右下角交叉点】")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 60)
                if let p = calFirst {
                    Circle().fill(.red).frame(width: 14, height: 14).position(p)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { v in
                    let p = v.location
                    if calStep == 0 {
                        calFirst = p
                        calStep = 1
                    } else if let first = calFirst {
                        tlX = Double(min(first.x, p.x))
                        tlY = Double(min(first.y, p.y))
                        brX = Double(max(first.x, p.x))
                        brY = Double(max(first.y, p.y))
                        calibrating = false
                        calFirst = nil
                    }
                }
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 计算与落子

    private func askEngine() {
        busy = true
        best = "-"
        engine.go(fen: fen, depth: Int(depth))
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { busy = false }
    }

    /// "h2" -> 屏幕坐标（a..i 是 0..8 列，rank 0 在底部）
    private func squarePoint(_ sq: String) -> CGPoint? {
        guard sq.count == 2 else { return nil }
        let chars = Array(sq)
        guard let firstAscii = chars[0].asciiValue else { return nil }
        let file = Int(firstAscii) - Int(Character("a").asciiValue!)
        guard file >= 0, file <= 8, let rank = chars[1].wholeNumberValue, rank >= 0, rank <= 9 else {
            return nil
        }
        let cellW = (brX - tlX) / 8.0
        let cellH = (brY - tlY) / 9.0
        return CGPoint(x: tlX + Double(file) * cellW,
                       y: tlY + Double(9 - rank) * cellH)
    }

    private func playBest() {
        let move = best.split(separator: " ").first.map(String.init) ?? best
        guard move.count >= 4 else { return }
        let from = String(move.prefix(2))
        let to = String(move.dropFirst(2).prefix(2))
        guard let p1 = squarePoint(from), let p2 = squarePoint(to) else { return }
        TouchInjector.shared.tap(x: p1.x, y: p1.y)
        usleep(120_000)
        TouchInjector.shared.tap(x: p2.x, y: p2.y)
    }
}

#Preview {
    ContentView()
}
