import AuthenticationServices
import SwiftUI
import UIKit

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
    /// The Apple ID's subscription belongs to an existing account, so sign-up is closed.
    @State private var isSignUpLocked = false

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

            if isSignUpLocked {
                SubscriptionLockedView(signedOut: .init(
                    logIn: { isSignUpLocked = false; show(.logIn) },
                    back: { isSignUpLocked = false }
                ))
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .animation(.snappy, value: mode)
        .animation(.easeInOut(duration: 0.3), value: isSignUpLocked)
        .sheet(isPresented: $showEmail) {
            EmailSignInSheet(isCreating: mode == .create)
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

            Button("Create account") { startSignUp() }
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
                run {
                    let allowsNew = !(await model.subscriptionBlocksNewAccounts())
                    return try await model.auth.completeAppleSignIn(result, allowsNewAccount: allowsNew)
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(.capsule)

            Button {
                run {
                    let allowsNew = !(await model.subscriptionBlocksNewAccounts())
                    return try await model.auth.signInWithGoogle(allowsNewAccount: allowsNew)
                }
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

    /// Sign-up only opens when the Apple ID has no trial or subscription tied to an existing
    /// account; otherwise nothing is created and the reader is pointed back to that account.
    private func startSignUp() {
        errorText = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            if await model.subscriptionBlocksNewAccounts() {
                isSignUpLocked = true
            } else {
                show(.create)
            }
        }
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
            } catch AuthError.newAccountBlocked {
                // "Log in" with Apple or Google would have made a new account; show why it didn't.
                isSignUpLocked = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Email form styled to match the sign-in screen: the meadow palette, not the system purple tint.
///
/// iOS offers to save a password whenever a filled password field leaves the screen. The sheet
/// stays up when sign-in fails, and it only leaves with a "new password" field after an account
/// is actually created — that's the one time the Save Password prompt should appear.
private struct EmailSignInSheet: View {
    let isCreating: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var passwordContentType: UITextContentType
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    init(isCreating: Bool) {
        self.isCreating = isCreating
        _passwordContentType = State(initialValue: isCreating ? .newPassword : .password)
    }

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
                    Button { Task { await closeWithoutSaving() } } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.15), in: .circle)
                    }
                    .accessibilityLabel("Close")
                    .disabled(isWorking)
                }

                VStack(spacing: 12) {
                    field {
                        TextField("", text: $email, prompt: prompt("Email"))
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .email)
                            .onSubmit { focus = .password }
                    }
                    field {
                        SecureField("", text: $password, prompt: prompt("Password (8+ characters)"))
                            .textContentType(passwordContentType)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(submit)
                    }
                }

                Button(action: submit) {
                    if isWorking {
                        ProgressView().tint(Color(hex: 0x10261E))
                    } else {
                        Text(isCreating ? "Create account" : "Log in")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(tint: palette.accent, foreground: Color(hex: 0x10261E)))
                .disabled(!isValid || isWorking)
                .opacity(isValid ? 1 : 0.5)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .tint(palette.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        // Swipe-to-dismiss would close the sheet before the password field can be unmarked,
        // which is what makes iOS offer to save. The close button unmarks it first.
        .interactiveDismissDisabled()
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
        guard isValid, !isWorking else { return }
        isWorking = true
        errorText = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password
        Task {
            do {
                let session = try await model.auth.signIn(email: email, password: password, createAccount: isCreating)
                if !isCreating { await stopPasswordSavePrompt() }
                await model.didSignIn(session)
            } catch AuthError.cancelled {
                isWorking = false
            } catch {
                isWorking = false
                errorText = error.localizedDescription
            }
        }
    }

    /// Closing without a new account must not look like a finished sign-up to Password AutoFill.
    private func closeWithoutSaving() async {
        await stopPasswordSavePrompt()
        dismiss()
    }

    /// `.password` and `.newPassword` both make iOS offer to save when the field goes away.
    /// Switching to a non-password type, and letting that reach the text field, skips the prompt.
    private func stopPasswordSavePrompt() async {
        passwordContentType = .oneTimeCode
        try? await Task.sleep(for: .milliseconds(100))
        PasswordSavePrompt.suppress()
    }
}

/// iOS decides to show "Save Password?" from the underlying text field, which SwiftUI can reset.
/// This clears that type directly, after the SwiftUI value has already changed.
private enum PasswordSavePrompt {
    @MainActor
    static func suppress() {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                suppress(in: window)
            }
        }
    }

    private static func suppress(in view: UIView) {
        if let field = view as? UITextField, field.isSecureTextEntry {
            field.textContentType = .oneTimeCode
        }
        view.subviews.forEach(suppress(in:))
    }
}
