import AuthenticationServices
import ScriptoriKit
import SwiftUI

/// Asks the reader to sign in again before their account is deleted (Firebase requires a
/// recent sign-in for that), then hands back to the caller to finish the deletion.
struct ConfirmIdentitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let provider: AuthProvider
    let onConfirmed: () -> Void

    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("For your security, sign in once more to permanently delete your account, streak and reflections.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    switch provider {
                    case .apple:
                        SignInWithAppleButton(.continue) { request in
                            model.auth.prepareAppleRequest(request)
                        } onCompletion: { result in
                            run { try await model.auth.reauthenticateWithApple(result) }
                        }
                        .frame(height: 48)
                    case .google:
                        Button("Continue with Google", systemImage: "g.circle.fill") {
                            run { try await model.auth.reauthenticateWithGoogle() }
                        }
                    default:
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button("Confirm and delete account", role: .destructive) {
                            run { try await model.auth.reauthenticate(password: password) }
                        }
                        .disabled(password.isEmpty)
                    }
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView() } }
            .navigationTitle("Confirm it's you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Task { await close() } } }
            }
        }
        .tint(.brandTint)
        .presentationDetents([.medium])
    }

    /// iOS offers to save a password when a field that still holds one goes away; confirming
    /// an identity is never the moment for that, so the field is emptied first.
    private func close() async {
        if !password.isEmpty {
            password = ""
            try? await Task.sleep(for: .milliseconds(100))
        }
        dismiss()
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorText = nil
        Task {
            defer { isWorking = false }
            do {
                try await action()
                await close()
                onConfirmed()
            } catch AuthError.cancelled {
                return
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
