#if canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import DigUpKit

/// Text recognition that gives no answer (`TextRecognition.reader` returning nil, as an app's reader does when it
/// stops waiting): the run goes on with the next file, the file isn't settled without its words, and a later run
/// reads it.
///
/// The reader is the whole process's and tests run side by side, so these readers speak only for this suite's
/// pictures, which are square (a screenshot 900 pixels a side, scans on square pages); Vision reads everyone else's.
/// One test at a time here, since each sets the reader.
@Suite(.serialized) final class TextRecognitionTests {
    /// In Caches, as `LongFilesTests` has it: a second sync needs the paths the crawl reports.
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("files"),
                                                 withIntermediateDirectories: true)
        return url
    }()

    deinit {
        TextRecognition.reader = nil
        try? FileManager.default.removeItem(at: folder)
    }

    var files: URL { folder.appendingPathComponent("files") }

    static let noAnswer: TextRecognition.Reader = { image in
        image.width == image.height ? nil : TextRecognition.vision(image)
    }

    static func answer(_ text: String) -> TextRecognition.Reader {
        { image in image.width == image.height ? text : TextRecognition.vision(image) }
    }

    @Test func aScreenshotWithoutAnAnswerStaysPendingForTheNextRun() throws {
        let shot = try writeScreenshot("Screenshot 2026-11-09 at 10.00.00.png")
        try String(repeating: "The harbour ferry leaves at seven every morning in summer. ", count: 6)
            .write(to: files.appendingPathComponent("notes.txt"), atomically: false, encoding: .utf8)
        let store = try store()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([files])

        TextRecognition.reader = Self.noAnswer
        var events: [Indexer.Event] = []
        #expect(try indexer.run(onEvent: { events.append($0) }) == ["pending": 1, "done": 1])   // on to the document
        #expect(events.first { $0.state == "pending" }?.note == "text recognition gave no answer")
        #expect(try state(store, shot.path).state == "pending")
        #expect(try kinds(store, shot.path).isEmpty)   // not its picture either: it would count as read
        #expect(try store.pendingCount() == 1)

        // Nothing about the file changed, so only its place in the queue brings it back.
        #expect(try indexer.sync([files]).queued.isEmpty)
        TextRecognition.reader = Self.answer("Booking K7QSILENT2 confirmed")
        #expect(try indexer.run() == ["done": 1])
        #expect(try state(store, shot.path).state == "done")
        #expect(try kinds(store, shot.path) == ["image", "ocr"])
        #expect(try found(store, "k7qsilent2") == [shot.path])
    }

    @Test func aScanWithoutAnAnswerStaysPendingForTheNextRun() throws {
        let scan = files.appendingPathComponent("scan.pdf")
        try ScannedPDF.write("Invoice QXSILENT4417. Payment due Friday.", to: scan, side: 700)
        let store = try store()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([files])

        TextRecognition.reader = Self.noAnswer
        #expect(try indexer.run() == ["pending": 1])
        #expect(try state(store, scan.path).state == "pending")
        #expect(try kinds(store, scan.path).isEmpty)

        TextRecognition.reader = Self.answer("Invoice QXSILENT4417. Payment due Friday.")
        #expect(try indexer.run() == ["done": 1])
        #expect(try kinds(store, scan.path) == ["page_image"])
        #expect(try found(store, "qxsilent4417") == [scan.path])
    }

    @Test func aLongPDFKeepsItsPlaceWhenAStepGetsNoAnswer() throws {
        // Seven pages, read two at a time. Page 4 is a scan, the rest have their text.
        var options = IndexOptions()
        options.bigPDFPages = 4
        options.pdfStep = 2
        let book = files.appendingPathComponent("Field guide.pdf")
        let scratch = folder.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let text = scratch.appendingPathComponent("text.pdf"), scan = scratch.appendingPathComponent("scan.pdf")
        let prose = String(repeating: "The orchard path runs down to the river. ", count: 8)
        try TextPDF.write((1...6).map { "Part \($0). " + prose }, to: text)
        try ScannedPDF.write("Specimen QXSILENT9902 was found here.", to: scan, side: 700)
        let pages = try #require(PDFDocument(url: text)), scanned = try #require(PDFDocument(url: scan)?.page(at: 0))
        pages.insert(scanned, at: 3)
        #expect(pages.write(to: book))

        let store = try store()
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([files])
        TextRecognition.reader = Self.noAnswer
        #expect(try indexer.run() == ["partial": 1])   // pages 1 and 2 have their text: no one is asked
        #expect(try state(store, book.path).info["read_to"] == "2")

        var steps: [Indexer.Step] = []
        #expect(try indexer.finishLongFiles(onStep: { steps.append($0) }).isEmpty)
        // The step with the scan isn't saved, and the two after it wait: saved, they'd move the file's place past
        // pages 3 and 4, which would never be read.
        #expect(steps.map(\.state) == ["pending"])
        #expect(steps.first?.note == "text recognition gave no answer")
        #expect(steps.first?.files == 1)
        #expect(try places(store, book.path) == [1, 2])
        #expect(try state(store, book.path).state == "partial")
        #expect(try state(store, book.path).info["read_to"] == "2")
        #expect(try store.unfinishedCount() == (1, 5))

        TextRecognition.reader = Self.answer("Specimen QXSILENT9902 was found here.")
        #expect(try indexer.finishLongFiles() == ["done": 1])
        #expect(try places(store, book.path) == Array(1...7))
        #expect(try state(store, book.path).state == "done")
        #expect(try found(store, "qxsilent9902") == [book.path])
    }

    // MARK: Files and what the index holds

    func store() throws -> IndexStore { try IndexStore(directory: folder.appendingPathComponent("index")) }

    /// A square picture named as macOS names a screenshot.
    func writeScreenshot(_ name: String) throws -> URL {
        let side = 900
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        bitmap.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        bitmap.fill(CGRect(x: 60, y: 700, width: 780, height: 90))   // a title bar, so it isn't a blank sheet
        let url = files.appendingPathComponent(name)
        guard let image = bitmap.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    func state(_ store: IndexStore, _ path: String) throws -> (state: String, info: [String: String]) {
        var result = ("", [String: String]())
        try store.db.query("SELECT id, state FROM files WHERE path = ?", [.text(path)]) { row in
            result = (row.text(1) ?? "", (try? store.info(of: row.int(0))) ?? [:])
        }
        return result
    }

    /// The kinds of a file's segments, its name's aside.
    func kinds(_ store: IndexStore, _ path: String) throws -> [String] {
        var out: [String] = []
        try store.db.query("""
            SELECT s.kind FROM segments s JOIN files f ON f.id = s.file WHERE f.path = ? AND s.kind != 'name'
            ORDER BY s.kind
            """, [.text(path)]) { out.append($0.text(0) ?? "") }
        return out
    }

    /// The pages (from 1) stored for a PDF.
    func places(_ store: IndexStore, _ path: String) throws -> [Int] {
        var out: [Int] = []
        try store.db.query("""
            SELECT s.loc FROM segments s JOIN files f ON f.id = s.file
            WHERE f.path = ? AND s.kind IN ('page', 'page_image') ORDER BY s.loc
            """, [.text(path)]) { out.append(Int($0.double(0))) }
        return out
    }

    /// The files keyword search finds `word` in.
    func found(_ store: IndexStore, _ word: String) throws -> [String] {
        var out: [String] = []
        try store.db.query("""
            SELECT f.path FROM fts JOIN segments s ON s.id = fts.rowid JOIN files f ON f.id = s.file WHERE fts MATCH ?
            """, [.text("\"\(word)\"")]) { out.append($0.text(0) ?? "") }
        return out
    }
}
#endif
