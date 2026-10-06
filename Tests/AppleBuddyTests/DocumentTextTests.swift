import AppKit
import NotesNative
import PDFKit
import XCTest

final class DocumentTextTests: XCTestCase {
    private func readText(_ url: URL) throws -> String {
        var error: NSError?
        guard let text = NBReadDocumentText(url, &error) else { throw error ?? NSError(domain: "test", code: 1) }
        return text
    }
    func testTinyImagesHaveNoRecognizableText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(pixels.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertEqual(try readText(url), "")
    }
    func testExtractsPDFTextAndRecognizesImageAndScannedPDF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = NSSize(width: 1200, height: 400)
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: "ZEPHYR RECEIPT 92847")
        label.font = .systemFont(ofSize: 60)
        label.textColor = .black
        label.frame = NSRect(x: 60, y: 120, width: 1100, height: 100)
        view.addSubview(label)
        let pdfURL = directory.appendingPathComponent("text.pdf")
        try view.dataWithPDF(inside: view.bounds).write(to: pdfURL)
        XCTAssertTrue(try readText(pdfURL).contains("92847"))
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("ZEPHYR RECEIPT 92847" as NSString).draw(at: NSPoint(x: 60, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black])
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let imageURL = directory.appendingPathComponent("scan.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        XCTAssertTrue(try readText(imageURL).contains("92847"))
        let scanned = PDFDocument()
        scanned.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let scanURL = directory.appendingPathComponent("scan.pdf")
        XCTAssertTrue(scanned.write(to: scanURL))
        XCTAssertTrue(try readText(scanURL).contains("92847"))
        XCTAssertThrowsError(try readText(directory.appendingPathComponent("missing.pdf")))
    }
}
