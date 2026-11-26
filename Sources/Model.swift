import Foundation
import CoreGraphics

// MARK: - Look

/// Two looks for the same notes: hand-made journal, or classic office sticky notes.
enum Theme: String {
    case journal, sticky
    case custom      // the user's own imported note paper
    case christmas   // red, green and cream: framed cards, velvet bows, a string of fairy lights
    static var current: Theme = Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .journal {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "theme") }
    }
    /// Hand-made looks (journal, Christmas) share handwriting, wobbly lines and the style list machinery.
    static var handmade: Bool { current == .journal || current == .christmas }
}

/// Classic sticky-note colours: canary, pink, blue, green, orange, lilac.
let stickyColors: [UInt32] = [0xFFF07A, 0xFFB9CF, 0xA8DAF3, 0xC6EAA2, 0xFFCB86, 0xD9C7F4]

/// Colours offered when the user picks a note colour (editor swatches, right-click menu).
/// Christmas colours only: cream, red, green, gold, gingerbread. Other custom colours are set aside in this look.
let christmasPalette: [(name: String, hex: UInt32)] = [
    ("棉花糖", 0xFBF6EA), ("糖霜饼干", 0xFFECC5), ("拐杖糖粉", 0xF8DCDA), ("冬青绿", 0xDDE8D6),
    ("鼠尾草", 0xE4EADF), ("金铃铛", 0xF5E6B8), ("姜饼", 0xE6C59C), ("缎带红", 0xF1BDB5),
]
var notePalette: [(name: String, hex: UInt32)] {
    if Theme.current == .christmas { return christmasPalette }
    return [("柠檬黄", 0xFFF07A), ("樱花粉", 0xFFB9CF), ("天空蓝", 0xA8DAF3), ("薄荷绿", 0xC6EAA2),
            ("橘子橙", 0xFFCB86), ("薰衣草", 0xD9C7F4), ("米白", 0xFBFBF7), ("牛皮纸", 0xD6B38A)]
}

/// Three note sizes to pick from (right-click → 大小, or in the editor).
enum NoteSize: String, Codable, CaseIterable {
    case small, medium, large
    var name: String { switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大" } }
    var dims: CGSize {
        switch self {
        case .small: return CGSize(width: 150, height: 132)
        case .medium: return CGSize(width: 190, height: 192)
        case .large: return CGSize(width: 240, height: 268)
        }
    }
}

// MARK: - Journal styles

enum Paper: String, Codable { case kraft, grid, lined, dot, torn, plain }
enum Attach: String, Codable { case peg, tape, bow }
enum TapePattern: String, Codable { case stripe, dot, grid }
enum Doodle: String, Codable { case star, heart, leaf, sun, holly, ribbon, tree, snow }
/// Christmas card looks: a gift tag with a stamp-edged panel, a hand-sketched double line,
/// sage candy stripes, a watercolour gingham border, a wobbly line with ribbon bows.
enum Frame: String, Codable { case tag, sketch, stripe, gingham, bows, plaid }
/// Shape of a cream panel (kept for the gift-tag look's helpers).
enum Panel: String, Codable { case wavy, scallop, bracket, loops }

/// What hangs on the rope: a handwritten note, or a shortcut to a file / folder.
enum CardKind: String, Codable { case note, image, folder, file }

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
    var frame: Frame? = nil
    var frameColor: UInt32 = 0
    var frameLine: UInt32 = 0  // hand-drawn outline of the inner panel
    var panel: Panel = .wavy
    var cornerBows = false
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

/// Christmas look: soft, hand-drawn holiday cards. frameColor / frameLine are the two inks of each card.
let christmasStyles: [NoteStyle] = [
    xmas(.tag, 0xFBF6EA, 0xD8624A, 0x4E9A5C),
    xmas(.plaid, 0xFBF5EA, 0xC2453B, 0x4F8A5B),              // pale red tartan
    xmas(.sketch, 0xF3EEE5, 0x8E2B22, 0x8E2B22, doodle: .star),
    xmas(.stripe, 0xF3EFE6, 0xD3DDCF, 0x983027),
    xmas(.plaid, 0xF6F4EA, 0x4F8A5B, 0xC2453B),              // pale green tartan
    xmas(.gingham, 0xFFFDFB, 0xDCA3A9, 0xB8935A),
    xmas(.bows, 0xF9E6E4, 0xB5342C, 0xB5342C),
    xmas(.tag, 0xFBF6EA, 0x4E9A5C, 0xD8624A),
    xmas(.sketch, 0xF6F1E7, 0x3F6B4A, 0x3F6B4A, doodle: .holly),
]

/// Every Christmas card hangs from a natural wooden peg.
private func xmas(_ f: Frame, _ paper: UInt32, _ ink: UInt32, _ ink2: UInt32, doodle: Doodle? = nil) -> NoteStyle {
    NoteStyle(paper: .plain, color: paper, attach: .peg, peg: nil, tape: 0xB5342C, tapeInk: 0xFFFFFF, tapePattern: .stripe,
              marker: paper, doodle: doodle, frame: f, frameColor: ink, frameLine: ink2)
}

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
    var wasOnRope: Bool? = nil   // put down on the desk because the rope was hidden
    var kind: String? = nil      // nil = handwritten note
    var path: String? = nil      // file shortcut: last known location
    var bookmark: Data? = nil    // file shortcut: finds the file again after a move or rename
    var doneTasks: [String]? = nil   // ticked lines of a note with several tasks
    var color: UInt32? = nil         // colour picked by the user
    var size: String? = nil          // 小 / 中 / 大 (nil = 小)
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
    var history: [StoredDone]? = nil   // tasks finished in the last 15 days (menu bar → 任务历史)
}

final class Store {
    let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // SJ_DATA_DIR lets a development build run against a scratch copy instead of the real notes
        let dir = ProcessInfo.processInfo.environment["SJ_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("StringJournal", isDirectory: true)
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
    "做完了\n勾选右下角的小方框，或拖进左边的漂流瓶",
]

// MARK: - First-run guide

/// The four things worth trying by hand; each step ends when the user has actually done it.
enum GuideStep: Int, CaseIterable {
    case takeDown, hangBack, write, tick, finish, trash

    var title: String {
        switch self {
        case .takeDown: return "取下来"
        case .hangBack: return "挂回去"
        case .write: return "写几项任务"
        case .tick: return "划掉一项"
        case .finish: return "做完了"
        case .trash: return "写错了就扔掉"
        }
    }
    var hint: String {
        switch self {
        case .takeDown: return "按住便签往下拖，拖到桌面再松手"
        case .hangBack: return "把它拖回绳子，或者点它右上角的 ↑"
        case .write: return "双击这张便签，点「新建任务」写两项待办（底下还能换颜色），然后按 ⌘↩ 保存"
        case .tick: return "任务多于一项时，前面会出现小方框。点一下，划掉一项"
        case .finish: return "点右下角的方框盖个章，它会折成纸飞机飞进漂流瓶"
        case .trash: return "鼠标移到这张便签上，点左下角的垃圾桶，它会揉成纸团扔进废纸篓"
        }
    }
}

enum GuideEvent { case putOnDesk, hungBack, edited, ticked, finished, trashed }

/// Replaying the guide practises on this note, so real notes never end up in the bottle by accident.
let practiceNoteText = "练习便签\n引导用的，可以放心折腾"
/// The last guide step throws this one away.
let trashPracticeText = "扔掉我\n引导用的，写错的便签可以这样删"

struct GuideCard {
    struct Row { var usesMenuIcon = false; var symbol = "circle"; let text: String }
    let title: String
    let lead: String
    let rows: [Row]
    let primary: String
    var secondary: String? = nil
    var footnote: String? = nil
}

let guideWelcomeCard = GuideCard(
    title: "欢迎来到绳上手帐",
    lead: "顶端这根绳子，能夹便签、图片和文件夹。",
    rows: [
        .init(usesMenuIcon: true, text: "菜单栏右侧的这个小图标是它的入口，所有设置都在里面。"),
        .init(symbol: "macwindow", text: "平时绳子待在桌面这一层，窗口会盖住它，不会挡你干活。"),
    ],
    primary: "动手试试（约 2 分钟）",
    secondary: "先不用",
    footnote: "以后想看：菜单栏图标 → 新手引导")

let guideDoneCard = GuideCard(
    title: "学会了！",
    lead: "关掉这张卡片，绳子就回到桌面这一层，被窗口盖住是正常的。",
    rows: [
        .init(symbol: "eye", text: "想看绳子：挪开窗口，或者显示桌面（拇指和三指张开）。"),
        .init(symbol: "plus.circle", text: "新便签点绳子右端的 ＋；文件拖到绳子或菜单栏图标上就能挂。"),
        .init(symbol: "paintpalette", text: "便签颜色在编辑框底部换，彩色圆点可以选任意颜色；也可以右键 → 颜色。"),
        .init(symbol: "doc.on.clipboard", text: "编辑框里能用 ⌘C / ⌘V 复制粘贴；右键便签可以「复制文字」。"),
        .init(symbol: "clock.arrow.circlepath", text: "漂流瓶每天和每次重启都会清空；最近 15 天完成的任务在菜单栏图标 →「任务历史」里。"),
    ],
    primary: "开始用吧")
