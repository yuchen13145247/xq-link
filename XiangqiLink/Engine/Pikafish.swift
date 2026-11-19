import Foundation

/// Pikafish 引擎的 Swift 封装：走 engine_shim 的 C 接口，说 UCI 文本协议。
final class Pikafish: ObservableObject {

    static let shared = Pikafish()

    @Published private(set) var ready = false
    @Published private(set) var lastInfo = ""

    private var started = false

    var onBestMove: ((String) -> Void)?

    private init() {}

    /// nnuePath: App 包内 pikafish.nnue 的绝对路径
    @discardableResult
    func start(nnuePath: String, threads: Int = 2, hashMB: Int = 64) -> Bool {
        if started { return true }

        xq_set_cb({ linePtr, _ in
            guard let linePtr else { return }
            let line = String(cString: linePtr)
            Pikafish.shared.handle(line: line)
        }, nil)

        let rc = nnuePath.withCString { p in
            xq_start(p, Int32(threads), Int32(hashMB))
        }
        started = (rc == 0)
        NSLog("[XQ] engine start rc=%d nnue=%@", rc, nnuePath)
        return started
    }

    func go(fen: String, depth: Int = 14, movetime: Int = 0) {
        guard started else { return }
        _ = fen.withCString { xq_go($0, Int32(depth), Int32(movetime)) }
    }

    func stop() { xq_stop() }

    private func handle(line: String) {
        if line == "readyok" {
            DispatchQueue.main.async { self.ready = true }
            return
        }
        if line.hasPrefix("bestmove") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return }
            let mv = String(parts[1])
            DispatchQueue.main.async { self.onBestMove?(mv) }
            return
        }
        if line.hasPrefix("info") && line.contains("score") {
            DispatchQueue.main.async { self.lastInfo = line }
        }
    }

    /// 包内 nnue 路径
    static var bundledNNUE: String? {
        Bundle.main.path(forResource: "pikafish", ofType: "nnue")
    }
}
