import SwiftUI

@main
struct XiangqiLinkApp: App {
    init() {
        if let nnue = Pikafish.bundledNNUE {
            Pikafish.shared.start(nnuePath: nnue)
        } else {
            NSLog("[XQ] pikafish.nnue 没打进包，引擎起不来")
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
