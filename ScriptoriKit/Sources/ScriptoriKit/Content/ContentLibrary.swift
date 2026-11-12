import Foundation

public protocol BibleContentProviding: Sendable {
    var translation: String { get }
    var books: [BibleBook] { get }
    func chapter(bookID: String, number: Int) async throws -> BibleChapter
}

public extension BibleContentProviding {
    func book(id: String) -> BibleBook? {
        books.first { $0.id == id }
    }

    func chapter(id: String) async throws -> BibleChapter {
        guard let parsed = ChapterID.parse(id) else { throw ContentError.chapterNotFound(id) }
        return try await chapter(bookID: parsed.bookID, number: parsed.number)
    }
}

public enum ContentError: Error, Sendable {
    case missingResource
    case chapterNotFound(String)
}

/// Offline content bundled with the app: the full public-domain KJV, one file per book,
/// plus hand-authored chapter guides (themes, takeaways, questions) where they exist.
/// Swap in a remote provider (e.g. API.Bible + a CMS for guides) behind the same protocol.
public struct BundledContentLibrary: BibleContentProviding {
    public let translation: String
    public let books: [BibleBook]
    private let textDirectory: URL
    private let guideDirectory: URL

    public init(bundle: Bundle? = nil) throws {
        let bundle = bundle ?? .module
        guard let catalog = bundle.url(forResource: "Books", withExtension: "json"),
              let root = bundle.resourceURL else {
            throw ContentError.missingResource
        }
        let file = try JSONDecoder().decode(CatalogFile.self, from: Data(contentsOf: catalog))
        self.translation = file.translation
        self.books = file.books
        self.textDirectory = root.appending(path: "Bible/\(file.translation)", directoryHint: .isDirectory)
        self.guideDirectory = root.appending(path: "Guides", directoryHint: .isDirectory)
    }

    public func chapter(bookID: String, number: Int) async throws -> BibleChapter {
        let id = ChapterID.make(bookID: bookID, number: number)
        guard let book = book(id: bookID) else { throw ContentError.chapterNotFound(id) }
        let url = textDirectory.appending(path: "\(bookID).json")
        guard let data = try? Data(contentsOf: url) else { throw ContentError.missingResource }
        let text = try JSONDecoder().decode(BookText.self, from: data)
        guard text.chapters.indices.contains(number - 1) else { throw ContentError.chapterNotFound(id) }

        let guide = guides(for: bookID)[id]
        return BibleChapter(
            id: id,
            book: book.name,
            number: number,
            translation: translation,
            title: guide?.title,
            palette: guide?.palette ?? book.palette,
            verses: text.chapters[number - 1].enumerated().map { BibleVerse(chapterID: id, number: $0.offset + 1, text: $0.element) },
            reflection: guide?.reflection ?? .fallback(for: book, chapter: number)
        )
    }

    private func guides(for bookID: String) -> [String: ChapterGuide] {
        let url = guideDirectory.appending(path: "\(bookID).json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ChapterGuide].self, from: data)) ?? [:]
    }
}

private struct CatalogFile: Decodable {
    let translation: String
    let books: [BibleBook]
}

private struct BookText: Decodable {
    let chapters: [[String]]
}

private struct ChapterGuide: Decodable {
    let title: String?
    let palette: String?
    let reflection: ReflectionGuide

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        palette = try container.decodeIfPresent(String.self, forKey: .palette)
        reflection = try ReflectionGuide(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case title, palette
    }
}
