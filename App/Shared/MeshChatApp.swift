import SwiftUI

@main
struct MeshChatApp: App {
    @State private var model = ChatModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
