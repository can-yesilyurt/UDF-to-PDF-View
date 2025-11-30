//
//  ViewController.swift
//  UDF-Okuyucu
//
//  Created by foks on 30/11/2025.
//

import Cocoa
import PDFKit
internal import UniformTypeIdentifiers

class ViewController: NSViewController {
    
    @IBOutlet weak var PDFView: PDFView!
    
    // Store the current PDF document and source filename
    private var currentPDFDocument: PDFDocument?
    private var currentSourceFilename: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure PDFView
        PDFView.autoScales = true
        PDFView.displayMode = .singlePageContinuous
        PDFView.displayDirection = .vertical
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    @IBAction func saveButton(_ sender: Any) {
        guard let pdfDoc = currentPDFDocument else {
            let alert = NSAlert()
            alert.messageText = "No PDF to Save"
            alert.informativeText = "Please convert a UDF file first."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Ask where to save the PDF
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = (currentSourceFilename ?? "document") + ".pdf"
        
        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            
            if pdfDoc.write(to: url) {
                // Success - optionally show confirmation
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "PDF Saved"
                    alert.informativeText = "The PDF has been saved successfully."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                self?.showError(NSError(domain: "UDFConverter",
                                       code: 4,
                                       userInfo: [NSLocalizedDescriptionKey: "Failed to save PDF"]))
            }
        }
    }
    
    @IBAction func convertUDF(_ sender: Any) {
        // 1) Pick UDF file
        let panel = NSOpenPanel()
        // Allow .udf files (which are actually ZIP archives)
        panel.allowedContentTypes = [UTType(filenameExtension: "udf")].compactMap { $0 }
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let udfURL = panel.url else { return }

            do {
                // Store the source filename for later save operation
                self.currentSourceFilename = udfURL.deletingPathExtension().lastPathComponent
                
                // 2) Prepare temp dir + zip copy
                let fm = FileManager.default
                let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: tempDir,
                                       withIntermediateDirectories: true,
                                       attributes: nil)

                let zipURL = tempDir.appendingPathComponent("input.zip")
                try fm.copyItem(at: udfURL, to: zipURL)

                // 3) Unzip
                let unzipDest = tempDir.appendingPathComponent("unzipped")
                try fm.createDirectory(at: unzipDest,
                                       withIntermediateDirectories: true,
                                       attributes: nil)
                try self.unzip(zipURL: zipURL, to: unzipDest)

                // 4) Find content.xml
                guard let contentXML = self.findContentXML(in: unzipDest) else {
                    throw NSError(domain: "UDFConverter",
                                  code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "content.xml not found"])
                }

                // 5) Parse XML and extract <content>
                let contentText = try self.extractContentText(from: contentXML)

                // 6) Create PDF and display it in the PDFView
                let pdfDoc = try self.createPDF(from: contentText, to: <#URL#>)
                
                DispatchQueue.main.async {
                    self.currentPDFDocument = pdfDoc
                    self.PDFView.document = pdfDoc
                }

            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: - Unzip via /usr/bin/unzip

    private func unzip(zipURL: URL, to dest: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", dest.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "Unknown unzip error"
            throw NSError(domain: "UDFConverter",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - Find content.xml

    private func findContentXML(in root: URL) -> URL? {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root,
                                          includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "content.xml" {
                    return fileURL
                }
            }
        }
        return nil
    }

    // MARK: - Extract <content> from XML

    private func extractContentText(from xmlURL: URL) throws -> String {
        // XMLDocument is easiest for simple structure
        let xmlData = try Data(contentsOf: xmlURL)
        let doc = try XMLDocument(data: xmlData, options: .nodePreserveAll)
        guard let root = doc.rootElement() else {
            throw NSError(domain: "UDFConverter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No root element in XML"])
        }

        // <template><content><![CDATA[...]]></content></template>
        guard let contentElement = root.elements(forName: "content").first,
              let text = contentElement.stringValue else {
            throw NSError(domain: "UDFConverter", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "<content> element not found"])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Create PDF (simple monospaced text, 1 page)

    private func createPDF(from text: String, to url: URL) throws {
        // For a proper Turkish-friendly font, register a TTF with CTFont if needed.
        // Here we just use system mono.
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        let attrString = NSAttributedString(string: text, attributes: attrs)

        // A4 at 72 dpi ≈ 595 x 842
        let pageRect = NSRect(x: 0, y: 0, width: 595, height: 842)
        let textView = NSTextView(frame: pageRect)
        textView.isEditable = false
        textView.textStorage?.setAttributedString(attrString)

        // NOTE: This will cram everything into one PDF page.
        // For serious docs you’d switch to NSPrintOperation to get pagination.
        let pdfData = textView.dataWithPDF(inside: pageRect)
        try pdfData.write(to: url)
    }

    // MARK: - Error helper

    private func showError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

}

