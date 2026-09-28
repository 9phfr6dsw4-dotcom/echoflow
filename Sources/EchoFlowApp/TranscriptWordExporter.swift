import AppKit
import EchoFlowCore
import Foundation

/// Writes a file transcript as a Word (.docx) document with macOS's built-in Office Open XML
/// writer: the title, a details line, then each timestamp/speaker heading and its paragraph.
enum TranscriptWordExporter {
    static func data(for document: FileTranscriptDocument, dateText: String) throws -> Data {
        let output = NSMutableAttributedString()

        func font(_ name: String, _ size: CGFloat, bold: Bool) -> NSFont {
            NSFont(name: name, size: size) ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }

        func append(_ text: String, font: NSFont, color: NSColor, spacingAfter: CGFloat) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacingAfter
            output.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))
        }

        append(document.displayTitle, font: font("Helvetica-Bold", 20, bold: true), color: .black, spacingAfter: 4)
        append(
            FileTranscriptExporter.detailsLine(for: document, dateText: dateText),
            font: font("Helvetica", 10, bold: false),
            color: .darkGray,
            spacingAfter: 16
        )
        for block in document.blocks {
            let line = FileTranscriptExporter.heading(for: block, in: document)
            if !line.isEmpty {
                append(line, font: font("Helvetica-Bold", 11, bold: true), color: .black, spacingAfter: 3)
            }
            append(block.text, font: font("Helvetica", 12, bold: false), color: .black, spacingAfter: 12)
        }

        return try output.data(
            from: NSRange(location: 0, length: output.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
    }
}
