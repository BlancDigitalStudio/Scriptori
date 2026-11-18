import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct ScriptoriApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(FirebaseCore)
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                #if canImport(GoogleSignIn)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.handleBecameActive() }
            case .background: Task { await model.handleEnteredBackground() }
            default: break
            }
        }
    }
}
