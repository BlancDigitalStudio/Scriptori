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
///   users/{uid}                      -> UserProfile, plus what the reader is in the middle of:
///                                       `chapterProgress` (ChapterProgress) and
///                                       `reflectionDraft` (ReflectionEntry, an unfinished check-in)
///   users/{uid}/reflections/{id}     -> ReflectionEntry
/// What the account holds about the chapter the reader is in the middle of.
struct CloudReading: Sendable {
    var progress: ChapterProgress?
    var draft: ReflectionEntry?
}

protocol ProfileSyncing: Sendable {
    func fetchProfile(userID: String) async throws -> UserProfile?
    func push(profile: UserProfile) async throws
    func push(reflection: ReflectionEntry, userID: String) async throws
    func fetchReflections(userID: String) async throws -> [ReflectionEntry]
    /// The account's journal, each time another device adds to or edits it. Ends when cancelled.
    func reflectionUpdates(userID: String) -> AsyncStream<[ReflectionEntry]>
    func fetchReading(userID: String) async throws -> CloudReading
    /// What the account holds, each time another device changes it. Ends when cancelled.
    func readingUpdates(userID: String) -> AsyncStream<CloudReading>
    func push(progress: ChapterProgress, userID: String) async throws
    /// `nil` removes the draft: the check-in was finished.
    func push(draft: ReflectionEntry?, userID: String) async throws
    func deleteAll(userID: String) async throws
}

struct LocalOnlySync: ProfileSyncing {
    func fetchProfile(userID: String) async throws -> UserProfile? { nil }
    func push(profile: UserProfile) async throws {}
    func push(reflection: ReflectionEntry, userID: String) async throws {}
    func fetchReflections(userID: String) async throws -> [ReflectionEntry] { [] }
    func reflectionUpdates(userID: String) -> AsyncStream<[ReflectionEntry]> { AsyncStream { $0.finish() } }
    func fetchReading(userID: String) async throws -> CloudReading { CloudReading() }
    func readingUpdates(userID: String) -> AsyncStream<CloudReading> { AsyncStream { $0.finish() } }
    func push(progress: ChapterProgress, userID: String) async throws {}
    func push(draft: ReflectionEntry?, userID: String) async throws {}
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

    /// Listens to the journal. As with `readingUpdates`, this device's own writes are skipped
    /// until the server has them. An entry that can't be read is left out, not fatal.
    func reflectionUpdates(userID: String) -> AsyncStream<[ReflectionEntry]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = db.collection("users").document(userID).collection("reflections")
                .order(by: "createdAt", descending: true).limit(to: 500)
                .addSnapshotListener { snapshot, _ in
                    guard let snapshot, !snapshot.metadata.hasPendingWrites else { return }
                    continuation.yield(snapshot.documents.compactMap { try? $0.data(as: ReflectionEntry.self) })
                }
            let listener = Listener(registration: registration)
            continuation.onTermination = { _ in listener.registration.remove() }
        }
    }

    /// Both are kept as fields on the profile document, not documents of their own: they are
    /// covered by the same security rule and removed with the account. Profile pushes merge,
    /// so they leave these alone. One that can't be read is treated as absent.
    func fetchReading(userID: String) async throws -> CloudReading {
        Self.reading(from: try await db.collection("users").document(userID).getDocument().data() ?? [:])
    }

    private static func reading(from data: [String: Any]) -> CloudReading {
        let decoder = Firestore.Decoder()
        return CloudReading(
            progress: data[progressField].flatMap { try? decoder.decode(ChapterProgress.self, from: $0) },
            draft: data[draftField].flatMap { try? decoder.decode(ReflectionEntry.self, from: $0) }
        )
    }

    /// Listens to the profile document. This device's own writes are skipped while they are
    /// still on their way to the server; once confirmed they arrive like any other change
    /// and are ignored by the caller for not being newer than what it already has.
    func readingUpdates(userID: String) -> AsyncStream<CloudReading> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = db.collection("users").document(userID).addSnapshotListener { snapshot, _ in
                guard let snapshot, snapshot.exists, !snapshot.metadata.hasPendingWrites else { return }
                continuation.yield(Self.reading(from: snapshot.data() ?? [:]))
            }
            let listener = Listener(registration: registration)
            continuation.onTermination = { _ in listener.registration.remove() }
        }
    }

    /// Firestore documents `ListenerRegistration.remove()` as safe to call from any thread;
    /// the type just isn't marked `Sendable`.
    private struct Listener: @unchecked Sendable {
        let registration: ListenerRegistration
    }

    func push(progress: ChapterProgress, userID: String) async throws {
        // Like the profile push, this queues the write and returns; it doesn't wait for the server.
        try db.collection("users").document(userID).setData(from: ProgressField(chapterProgress: progress), merge: true)
    }

    func push(draft: ReflectionEntry?, userID: String) async throws {
        let document = db.collection("users").document(userID)
        if let draft {
            try document.setData(from: DraftField(reflectionDraft: draft), merge: true)
        } else {
            removeDraft(from: document)
        }
    }

    /// Not `async`, so this is Firestore's queue-and-return write; from an `async` function
    /// the same call would wait for the server and hang while offline.
    private func removeDraft(from document: DocumentReference) {
        document.setData([Self.draftField: FieldValue.delete()], merge: true)
    }

    private static let progressField = "chapterProgress"
    private static let draftField = "reflectionDraft"
    private struct ProgressField: Encodable {
        let chapterProgress: ChapterProgress
    }
    private struct DraftField: Encodable {
        let reflectionDraft: ReflectionEntry
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
