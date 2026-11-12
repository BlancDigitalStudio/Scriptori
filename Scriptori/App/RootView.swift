import ScriptoriKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                LaunchView()
            case .onboarding:
                OnboardingView()
            case .signIn:
                SignInView()
            case .paywall:
                PaywallView(isDismissible: false)
            case .main:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.phase)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            PaletteBackground(palette: .dawn)
            VStack(spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 44))
                    .symbolEffect(.pulse)
                Text("Scriptori")
                    .font(Typography.display(36))
            }
            .foregroundStyle(.white)
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ScriptoriFeedView()
                .tabItem { Label("Today", systemImage: "leaf") }
                .tag(AppModel.Tab.today)
            JournalView()
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(AppModel.Tab.journal)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppModel.Tab.profile)
        }
        // White reads on the Today feed's dark palettes; Journal and Profile use system backgrounds.
        .tint(model.selectedTab == .today ? .white : .brandTint)
    }
}
