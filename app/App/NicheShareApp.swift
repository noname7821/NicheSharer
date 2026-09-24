import SwiftUI

@main
struct NicheShareApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverView()
                .tint(Color("AccentColor"))
        }
    }
}
