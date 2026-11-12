import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var showEmail = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            PaletteBackground(palette: .meadow)
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "leaf.fill").font(.system(size: 48))
                Text("Scriptori").font(Typography.display(42))
                Text("Save your streak, reflections and subscription across devices.")
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
                    .padding(.horizontal, 24)
                Spacer()

                SignInWithAppleButton(.continue) { request in
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
                    Label("Continue with Google", systemImage: "g.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: .white.opacity(0.15), foreground: .white))

                Button("Continue with email") { showEmail = true }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)

                #if DEBUG
                Button("Continue as guest (debug)") {
                    run { model.auth.signInAsGuest() }
                }
                .font(.footnote)
                .opacity(0.7)
                #endif

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .disabled(isWorking)

            if isWorking { ProgressView().tint(.white).controlSize(.large) }
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showEmail) {
            EmailSignInSheet { email, password, create in
                showEmail = false
                run { try await model.auth.signIn(email: email, password: password, createAccount: create) }
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
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

private struct EmailSignInSheet: View {
    let onSubmit: (String, String, Bool) -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var isCreating = false

    private var isValid: Bool { email.contains("@") && password.count >= 8 }

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $isCreating) {
                    Text("Sign in").tag(false)
                    Text("Create account").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (8+ characters)", text: $password)
                        .textContentType(isCreating ? .newPassword : .password)
                }
                Button(isCreating ? "Create account" : "Sign in") {
                    onSubmit(email.trimmingCharacters(in: .whitespaces), password, isCreating)
                }
                .disabled(!isValid)
            }
            .navigationTitle("Email")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
