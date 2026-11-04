import Foundation
import CoreGraphics

// MARK: - Journal styles

enum Paper: String, Codable { case kraft, grid, lined, dot, torn }
enum Attach: String, Codable { case peg, tape }
enum TapePattern: String, Codable { case stripe, dot, grid }
enum Doodle: String, Codable { case star, heart, leaf, sun }

struct NoteStyle {
    let paper: Paper
    let color: UInt32
    let attach: Attach
    let peg: UInt32?          // painted peg colour; nil = natural wood
    let tape: UInt32
    let tapeInk: UInt32       // pattern colour (RGB), drawn semi-opaque white-ish
    let tapePattern: TapePattern
    let marker: UInt32        // highlighter under the title
    let doodle: Doodle?
}

let journalStyles: [NoteStyle] = [
    NoteStyle(paper: .kraft, color: 0xD6B38A, attach: .tape, peg: nil, tape: 0xA9CFBF, tapeInk: 0xFFFFFF, tapePattern: .stripe, marker: 0xFFF3B0, doodle: nil),
    NoteStyle(paper: .grid,  color: 0xFBFBF7, attach: .peg,  peg: 0x9FCBB8, tape: 0xA9CFBF, tapeInk: 0xFFFFFF, tapePattern: .stripe, marker: 0xFFD8A8, doodle: .star),
    NoteStyle(paper: .lined, color: 0xFBF4D8, attach: .peg,  peg: nil, tape: 0xA9CFBF, tapeInk: 0xFFFFFF, tapePattern: .stripe, marker: 0xBFE0F5, doodle: nil),
    NoteStyle(paper: .dot,   color: 0xF8E4DF, attach: .tape, peg: nil, tape: 0xE9C25E, tapeInk: 0xFFFFFF, tapePattern: .dot, marker: 0xFFFFFF, doodle: nil),
    NoteStyle(paper: .torn,  color: 0xE3EFE6, attach: .peg,  peg: 0xF0B3AE, tape: 0xA9CFBF, tapeInk: 0xFFFFFF, tapePattern: .stripe, marker: 0xFDE6A0, doodle: .leaf),
    NoteStyle(paper: .grid,  color: 0xEBE7F6, attach: .tape, peg: nil, tape: 0xF2BCB7, tapeInk: 0xFFFFFF, tapePattern: .grid, marker: 0xFFF3B0, doodle: .heart),
    NoteStyle(paper: .lined, color: 0xFBFBF7, attach: .tape, peg: nil, tape: 0xA3C4E2, tapeInk: 0xFFFFFF, tapePattern: .stripe, marker: 0xF8C9C4, doodle: .sun),
]

// MARK: - Persistence

struct StoredNote: Codable {
    var id: UUID
    var text: String
    var style: Int
    var onRope: Bool
    var ropeX: Double      // fraction of screen width
    var deskX: Double      // fractions of screen size
    var deskY: Double
    var tilt: Double
    var stamped: Bool
}

struct StoredDone: Codable {
    var id: UUID
    var text: String
    var style: Int
    var doneAt: Date
}

struct Book: Codable {
    var version = 1
    var notes: [StoredNote] = []
    var done: [StoredDone] = []
}

final class Store {
    let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StringJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("notes.json")
    }

    func load() -> Book? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Book.self, from: data)
    }

    func save(_ book: Book) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(book) else { return }
        // keep one previous copy as a safety net
        let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try? data.write(to: url, options: .atomic)
    }
}

let welcomeNotes = [
    "取下来\n按住便签往下拖，就能把它从绳子上取下",
    "挂回去\n把便签拖回绳子附近，两边会自动让位",
    "写点什么\n双击便签就能编辑",
    "做完了\n勾选右下角的小方框，或拖进左下角的信封",
]
