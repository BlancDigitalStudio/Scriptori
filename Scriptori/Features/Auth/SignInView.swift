import AuthenticationServices
import SwiftUI

/// First screen for anyone signed out: choose Create account or Log in, then a provider.
/// New accounts continue into onboarding; existing ones go straight to the app.
struct SignInView: View {
    @Environment(AppModel.self) private var model

    private enum Mode {
        case create, logIn

        var title: String { self == .create ? "Create your account" : "Welcome back" }
        var subtitle: String {
            self == .create
                ? "Your streak, reflections and subscription stay with your account."
                : "Log in to pick up where you left off."
        }
        var verb: String { self == .create ? "Sign up" : "Log in" }
    }

    @State private var mode: Mode?
    @State private var showEmail = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            PaletteBackground(palette: .meadow)
            Group {
                if let mode { providers(for: mode) } else { landing }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .disabled(isWorking)

            if isWorking { ProgressView().tint(.white).controlSize(.large) }
        }
        .foregroundStyle(.white)
        .animation(.snappy, value: mode)
        .sheet(isPresented: $showEmail) {
            let isCreating = mode == .create
            EmailSignInSheet(isCreating: isCreating) { email, password in
                showEmail = false
                run { try await model.auth.signIn(email: email, password: password, createAccount: isCreating) }
            }
        }
    }

    private var landing: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "leaf.fill").font(.system(size: 48))
            Text("Scriptori").font(Typography.display(42))
            Text("One chapter a day from a book you choose.")
                .multilineTextAlignment(.center)
                .opacity(0.75)
                .padding(.horizontal, 24)
            Spacer()

            Button("Create account") { show(.create) }
                .buttonStyle(PrimaryButtonStyle())

            Button("Log in") { show(.logIn) }
                .buttonStyle(PrimaryButtonStyle(tint: .white.opacity(0.15), foreground: .white))

            #if DEBUG
            Button("Continue as guest (debug)") {
                run { model.auth.signInAsGuest() }
            }
            .font(.footnote)
            .opacity(0.7)
            .padding(.top, 4)
            #endif

            errorLabel
        }
    }

    private func providers(for mode: Mode) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button { show(nil) } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.top, 12)
            Spacer()
            Text(mode.title).font(Typography.display(34))
            Text(mode.subtitle)
                .multilineTextAlignment(.center)
                .opacity(0.75)
                .padding(.horizontal, 24)
            Spacer()

            SignInWithAppleButton(mode == .create ? .signUp : .signIn) { request in
                model.auth.prepareAppleRequest(request)
            } onCompletion: { result in
                run { try await model.auth.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(.capsule)

            Button {
                run { try await model.auth.signInWithGoogle() }
            } label: {
                Label("\(mode.verb) with Google", systemImage: "g.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle(tint: .white.opacity(0.15), foreground: .white))

            Button { showEmail = true } label: {
                Label("\(mode.verb) with email", systemImage: "envelope.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)

            errorLabel
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let errorText {
            Text(errorText).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
        }
    }

    private func show(_ mode: Mode?) {
        errorText = nil
        self.mode = mode
    }

    private func run(_ action: @escaping @MainActor () async throws -> AuthSession) {
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                await model.didSignIn(try await action())
            } catch AuthError.cancelled {
                return
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Email form styled to match the sign-in screen: the meadow palette, not the system purple tint.
private struct EmailSignInSheet: View {
    let isCreating: Bool
    let onSubmit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private let palette = Palette.meadow
    private var isValid: Bool { email.contains("@") && password.count >= 8 }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            VStack(spacing: 20) {
                HStack {
                    Text(isCreating ? "Create account" : "Log in")
                        .font(Typography.display(28))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.15), in: .circle)
                    }
                    .accessibilityLabel("Close")
                }

                VStack(spacing: 12) {
                    field {
                        TextField("", text: $email, prompt: prompt("Email"))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .email)
                            .onSubmit { focus = .password }
                    }
                    field {
                        SecureField("", text: $password, prompt: prompt("Password (8+ characters)"))
                            .textContentType(isCreating ? .newPassword : .password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(submit)
                    }
                }

                Button(action: submit) {
                    Text(isCreating ? "Create account" : "Log in")
                }
                .buttonStyle(PrimaryButtonStyle(tint: palette.accent, foreground: Color(hex: 0x10261E)))
                .disabled(!isValid)
                .opacity(isValid ? 1 : 0.5)

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .tint(palette.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(.white.opacity(0.14), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(.white.opacity(0.55))
    }

    private func submit() {
        guard isValid else { return }
        onSubmit(email.trimmingCharacters(in: .whitespaces), password)
    }
}
