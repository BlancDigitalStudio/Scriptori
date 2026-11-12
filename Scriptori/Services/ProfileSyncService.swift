import Foundation
import ScriptoriKit
#if canImport(FirebaseFirestore)
import FirebaseCore
import FirebaseFirestore
#endif

/// Backend sync for the profile and reflection journal. The app is offline-first:
/// everything is written to `LocalStore` immediately and pushed here best-effort.
///
/// Firestore layout:
///   users/{uid}                      -> UserProfile
///   users/{uid}/reflections/{id}     -> ReflectionEntry
protocol ProfileSyncing: Sendable {
    func fetchProfile(userID: String) async throws -> UserProfile?
    func push(profile: UserProfile) async throws
    func push(reflection: ReflectionEntry, userID: String) async throws
    func fetchReflections(userID: String) async throws -> [ReflectionEntry]
    func deleteAll(userID: String) async throws
}

struct LocalOnlySync: ProfileSyncing {
    func fetchProfile(userID: String) async throws -> UserProfile? { nil }
    func push(profile: UserProfile) async throws {}
    func push(reflection: ReflectionEntry, userID: String) async throws {}
    func fetchReflections(userID: String) async throws -> [ReflectionEntry] { [] }
    func deleteAll(userID: String) async throws {}
}

#if canImport(FirebaseFirestore)
struct FirestoreSync: ProfileSyncing {
    private var db: Firestore { Firestore.firestore() }

    func fetchProfile(userID: String) async throws -> UserProfile? {
        let snapshot = try await db.collection("users").document(userID).getDocument()
        return snapshot.exists ? try snapshot.data(as: UserProfile.self) : nil
    }

    func push(profile: UserProfile) async throws {
        try db.collection("users").document(profile.id).setData(from: profile, merge: true)
    }

    func push(reflection: ReflectionEntry, userID: String) async throws {
        var synced = reflection
        synced.syncState = .synced
        try db.collection("users").document(userID).collection("reflections")
            .document(reflection.id.uuidString).setData(from: synced)
    }

    func fetchReflections(userID: String) async throws -> [ReflectionEntry] {
        let snapshot = try await db.collection("users").document(userID).collection("reflections")
            .order(by: "createdAt", descending: true).limit(to: 500).getDocuments()
        return try snapshot.documents.map { try $0.data(as: ReflectionEntry.self) }
    }

    func deleteAll(userID: String) async throws {
        let reflections = try await db.collection("users").document(userID).collection("reflections").getDocuments()
        let batch = db.batch()
        reflections.documents.forEach { batch.deleteDocument($0.reference) }
        batch.deleteDocument(db.collection("users").document(userID))
        try await batch.commit()
    }
}
#endif

enum SyncFactory {
    static func make() -> ProfileSyncing {
        #if canImport(FirebaseFirestore)
        if FirebaseApp.app() != nil { return FirestoreSync() }
        #endif
        return LocalOnlySync()
    }
}
