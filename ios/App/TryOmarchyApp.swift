import SwiftUI

@main
struct TryOmarchyApp: App {
    @StateObject private var session = SessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        session.sceneBecameActive()
                    }
                }
        }
    }
}
