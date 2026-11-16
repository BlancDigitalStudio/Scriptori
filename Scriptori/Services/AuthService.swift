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
    /// Deleting an account needs a recent sign-in; confirm identity with this provider, then retry.
    case requiresRecentLogin(AuthProvider)
    case notSignedIn
    case accountNotFound
    case wrongPassword
    /// The email belongs to an account that signs in with another provider (Google or Apple).
    case useOtherProvider(String)
    case emailInUse
    case invalidEmail
    case weakPassword
    case tooManyAttempts
    case offline

    var errorDescription: String? {
        switch self {
        case .accountNotFound: "Account not found. Check the email address, or create an account."
        case .wrongPassword: "Password incorrect. Please try again."
        case .useOtherProvider(let provider): "This email is registered with \(provider). Log in with \(provider) instead."
        case .emailInUse: "An account with this email already exists. Try logging in instead."
        case .invalidEmail: "That email address doesn't look right."
        case .weakPassword: "Choose a stronger password (at least 8 characters)."
        case .tooManyAttempts: "Too many attempts. Please wait a moment and try again."
        case .offline: "You appear to be offline. Check your connection and try again."
        case .backendNotConfigured: "This sign-in option needs Firebase configured. See docs/ARCHITECTURE.md."
        case .missingIdentityToken: "Apple didn't return an identity token. Please try again."
        case .cancelled: nil
        case .requiresRecentLogin: "For your security, confirm it's you before deleting your account."
        case .notSignedIn: "Your sign-in has expired. Sign out, sign back in, then delete your account."
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
    /// Last sign-in or re-authentication in this session.
    private var lastAuthenticatedAt: Date?
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
            let firebaseCredential = try firebaseAppleCredential(from: credential)
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
            do {
                let result = createAccount
                    ? try await Auth.auth().createUser(withEmail: email, password: password)
                    : try await Auth.auth().signIn(withEmail: email, password: password)
                return persist(AuthSession(user: result.user, provider: .email))
            } catch {
                throw await Self.friendlyEmailError(error, email: email, creatingAccount: createAccount)
            }
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

    /// Firebase rejects account deletion unless the user signed in within the last ~5 minutes.
    /// Checked up front so nothing is deleted when the final step would be refused.
    func requireRecentSignIn() throws {
        #if canImport(FirebaseAuth)
        guard Self.isFirebaseConfigured, session?.provider != .guest else { return }
        guard let user = Auth.auth().currentUser else { throw AuthError.notSignedIn }
        let lastSignIn = [user.metadata.lastSignInDate, lastAuthenticatedAt].compactMap { $0 }.max() ?? .distantPast
        if Date.now.timeIntervalSince(lastSignIn) > 4 * 60 {
            throw AuthError.requiresRecentLogin(session?.provider ?? .email)
        }
        #endif
    }

    /// Deletes the backend account. Throws `AuthError.requiresRecentLogin` when Firebase needs a
    /// fresh sign-in first; call one of the `reauthenticate…` methods, then try again.
    func deleteAccount() async throws {
        #if canImport(FirebaseAuth)
        if Self.isFirebaseConfigured, session?.provider != .guest {
            guard let user = Auth.auth().currentUser else { throw AuthError.notSignedIn }
            do {
                try await user.delete()
            } catch let error as NSError where error.domain == AuthErrorDomain && error.code == AuthErrorCode.requiresRecentLogin.rawValue {
                throw AuthError.requiresRecentLogin(session?.provider ?? .email)
            }
        }
        #endif
        clear()
    }

    // MARK: Re-authentication (before deleting the account)

    func reauthenticate(password: String) async throws {
        #if canImport(FirebaseAuth)
        guard Self.isFirebaseConfigured, let user = Auth.auth().currentUser, let email = user.email else {
            throw AuthError.backendNotConfigured
        }
        try await user.reauthenticate(with: EmailAuthProvider.credential(withEmail: email, password: password))
        lastAuthenticatedAt = .now
        #else
        throw AuthError.backendNotConfigured
        #endif
    }

    func reauthenticateWithGoogle() async throws {
        #if canImport(FirebaseAuth) && canImport(GoogleSignIn)
        guard Self.isFirebaseConfigured, let user = Auth.auth().currentUser,
              let clientID = FirebaseApp.app()?.options.clientID else { throw AuthError.backendNotConfigured }
        guard let presenter = UIApplication.shared.topViewController else { throw AuthError.cancelled }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else { throw AuthError.missingIdentityToken }
        try await user.reauthenticate(with: GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString))
        lastAuthenticatedAt = .now
        #else
        throw AuthError.backendNotConfigured
        #endif
    }

    /// Re-authenticates with Apple and revokes the app's Apple token, which App Review requires
    /// when a Sign in with Apple account is deleted.
    func reauthenticateWithApple(_ result: Result<ASAuthorization, Error>) async throws {
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
        #if canImport(FirebaseAuth)
        guard Self.isFirebaseConfigured, let user = Auth.auth().currentUser else { throw AuthError.backendNotConfigured }
        try await user.reauthenticate(with: try firebaseAppleCredential(from: credential))
        lastAuthenticatedAt = .now
        if let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8) {
            try? await Auth.auth().revokeToken(withAuthorizationCode: code)
        }
        #else
        throw AuthError.backendNotConfigured
        #endif
    }

    // MARK: Helpers

    #if canImport(FirebaseAuth)
    /// Turns Firebase's email/password failures into messages a reader can act on. Firebase often
    /// reports a wrong password and an unknown email as the same `invalidCredential` ("malformed
    /// or has expired"), so that case looks the email up to tell the two apart.
    private static func friendlyEmailError(_ error: Error, email: String, creatingAccount: Bool) async -> Error {
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: nsError.code) else { return error }
        switch code {
        case .emailAlreadyInUse: return AuthError.emailInUse
        case .invalidEmail: return AuthError.invalidEmail
        case .weakPassword: return AuthError.weakPassword
        case .tooManyRequests: return AuthError.tooManyAttempts
        case .networkError: return AuthError.offline
        case .userNotFound: return AuthError.accountNotFound
        case .wrongPassword: return AuthError.wrongPassword
        case .invalidCredential where !creatingAccount:
            return await diagnoseRejectedLogin(email: email) ?? error
        default: return error
        }
    }

    /// Requires "Email enumeration protection" to be turned off in the Firebase console. With it
    /// on, Firebase deliberately returns an empty list for every email, so every rejected login
    /// would read as "account not found".
    ///
    /// Firebase deprecated `fetchSignInMethods` and offers no replacement. Calling it through a
    /// protocol requirement keeps that deprecation from surfacing as a build warning.
    private protocol SignInMethodsLookup {
        static func signInMethods(for email: String) async -> [String]?
    }

    private enum FirebaseSignInMethodsLookup: SignInMethodsLookup {
        @available(*, deprecated)
        static func signInMethods(for email: String) async -> [String]? {
            try? await Auth.auth().fetchSignInMethods(forEmail: email)
        }
    }

    private static func diagnoseRejectedLogin(email: String) async -> AuthError? {
        let lookup: SignInMethodsLookup.Type = FirebaseSignInMethodsLookup.self
        guard let methods = await lookup.signInMethods(for: email) else { return nil }
        if methods.isEmpty { return .accountNotFound }
        if methods.contains(EmailAuthProvider.id) { return .wrongPassword }
        if methods.contains(GoogleAuthProvider.id) { return .useOtherProvider("Google") }
        if methods.contains("apple.com") { return .useOtherProvider("Apple") }
        return nil
    }

    private func firebaseAppleCredential(from credential: ASAuthorizationAppleIDCredential) throws -> OAuthCredential {
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce
        else { throw AuthError.missingIdentityToken }
        return OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce, fullName: credential.fullName)
    }
    #endif

    private func persist(_ session: AuthSession) -> AuthSession {
        self.session = session
        lastAuthenticatedAt = .now
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
