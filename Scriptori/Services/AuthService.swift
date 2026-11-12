import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import ScriptoriKit
import UIKit
#if canImport(FirebaseAuth)
import FirebaseAuth
import FirebaseCore
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

struct AuthSession: Codable, Hashable, Sendable {
    let userID: String
    let provider: AuthProvider
    var email: String?
    var displayName: String?
}

enum AuthError: LocalizedError {
    case backendNotConfigured
    case missingIdentityToken
    case cancelled

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: "This sign-in option needs Firebase configured. See docs/ARCHITECTURE.md."
        case .missingIdentityToken: "Apple didn't return an identity token. Please try again."
        case .cancelled: nil
        }
    }
}

/// Unifies Sign in with Apple, Google and email/password.
///
/// With the Firebase SDK linked (`FirebaseAuth`, `GoogleSignIn` packages + `GoogleService-Info.plist`)
/// every provider exchanges its credential for a Firebase user, giving one stable UID across devices.
/// Without it, Apple sign-in still works natively (keyed on the Apple user ID) so the app is fully usable
/// in development.
@Observable
@MainActor
final class AuthService {
    private(set) var session: AuthSession?
    private var currentNonce: String?
    private let defaultsKey = "scriptori.authSession"

    static var isFirebaseConfigured: Bool {
        #if canImport(FirebaseAuth)
        return FirebaseApp.app() != nil
        #else
        return false
        #endif
    }

    func restoreSession() async -> AuthSession? {
        #if canImport(FirebaseAuth)
        if Self.isFirebaseConfigured, let user = Auth.auth().currentUser {
            session = AuthSession(user: user, provider: storedSession()?.provider ?? .email)
            return session
        }
        #endif
        guard let stored = storedSession() else { return nil }
        if stored.provider == .apple {
            let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: stored.userID)
            guard state == .authorized else {
                clear()
                return nil
            }
        }
        session = stored
        return stored
    }

    // MARK: Sign in with Apple

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async throws -> AuthSession {
        let authorization: ASAuthorization
        switch result {
        case .success(let value): authorization = value
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { throw AuthError.cancelled }
            throw error
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AuthError.missingIdentityToken
        }
        let name = credential.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }

        #if canImport(FirebaseAuth)
        if Self.isFirebaseConfigured {
            guard let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce
            else { throw AuthError.missingIdentityToken }
            let firebaseCredential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce, fullName: credential.fullName)
            let result = try await Auth.auth().signIn(with: firebaseCredential)
            var session = AuthSession(user: result.user, provider: .apple)
            session.displayName = session.displayName ?? name
            return persist(session)
        }
        #endif

        return persist(AuthSession(userID: credential.user, provider: .apple, email: credential.email, displayName: name))
    }

    // MARK: Google

    func signInWithGoogle() async throws -> AuthSession {
        #if canImport(FirebaseAuth) && canImport(GoogleSignIn)
        guard Self.isFirebaseConfigured, let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.backendNotConfigured
        }
        guard let presenter = UIApplication.shared.topViewController else { throw AuthError.cancelled }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else { throw AuthError.missingIdentityToken }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
        let authResult = try await Auth.auth().signIn(with: credential)
        return persist(AuthSession(user: authResult.user, provider: .google))
        #else
        throw AuthError.backendNotConfigured
        #endif
    }

    // MARK: Email / password

    func signIn(email: String, password: String, createAccount: Bool) async throws -> AuthSession {
        #if canImport(FirebaseAuth)
        if Self.isFirebaseConfigured {
            let result = createAccount
                ? try await Auth.auth().createUser(withEmail: email, password: password)
                : try await Auth.auth().signIn(withEmail: email, password: password)
            return persist(AuthSession(user: result.user, provider: .email))
        }
        #endif
        #if DEBUG
        return persist(AuthSession(userID: "dev-\(email.lowercased())", provider: .email, email: email))
        #else
        throw AuthError.backendNotConfigured
        #endif
    }

    #if DEBUG
    func signInAsGuest() -> AuthSession {
        persist(AuthSession(userID: "guest-local", provider: .guest, displayName: "Guest"))
    }
    #endif

    func signOut() {
        #if canImport(FirebaseAuth)
        if Self.isFirebaseConfigured { try? Auth.auth().signOut() }
        #endif
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        clear()
    }

    func deleteAccount() async throws {
        #if canImport(FirebaseAuth)
        if Self.isFirebaseConfigured { try await Auth.auth().currentUser?.delete() }
        #endif
        clear()
    }

    // MARK: Helpers

    private func persist(_ session: AuthSession) -> AuthSession {
        self.session = session
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        return session
    }

    private func storedSession() -> AuthSession? {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }

    private func clear() {
        session = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(FirebaseAuth)
private extension AuthSession {
    init(user: User, provider: AuthProvider) {
        self.init(userID: user.uid, provider: provider, email: user.email, displayName: user.displayName)
    }
}
#endif

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
