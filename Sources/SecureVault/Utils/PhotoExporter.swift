import UIKit

enum PhotoExportError: LocalizedError {
    case noteTooLong, unreadableImage
    var errorDescription: String? {
        switch self {
        case .noteTooLong: return "Заметка слишком длинная для изображения. Сократите текст или отключите заметку на фото."
        case .unreadableImage: return "Не удалось прочитать фотографию."
        }
    }
}

enum ExportNoteRenderer {
    // Append a panel instead of covering an existing caption, face or object.
    static func apply(to image: UIImage, note: String) throws -> UIImage {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return image }
        let base = image.normalized() ?? image
        let padding = max(12, base.size.width * 0.025)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(12, base.size.width * 0.027)),
            .foregroundColor: UIColor.white
        ]
        let label = "Заметка\n" + text
        let availableWidth = max(1, base.size.width - padding * 2)
        let measured = (label as NSString).boundingRect(with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        let panelHeight = ceil(measured.height) + padding * 2 + 4
        let size = CGSize(width: base.size.width, height: base.size.height + panelHeight)
        guard size.height <= 32768, size.width * size.height <= 80_000_000 else { throw PhotoExportError.noteTooLong }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            base.draw(at: .zero)
            (label as NSString).draw(with: CGRect(x: padding, y: base.size.height + padding, width: availableWidth, height: panelHeight - padding * 2),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        }
    }
}

enum PhotoExporter {
    static func jpegData(for url: URL, includeNotes: Bool, generation: Int,
                         storage: FileStorageManager = .shared) throws -> Data {
        let snapshot: (Data, String?) = try VaultGate.shared.withAccess(generation: generation) {
            guard let data = storage.decryptedData(for: url) else { throw PhotoExportError.unreadableImage }
            return (data, storage.loadMeta(for: url)?.note)
        }
        guard includeNotes, let note = snapshot.1, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return snapshot.0 }
        guard let image = UIImage(data: snapshot.0) else { throw PhotoExportError.unreadableImage }
        let result = try ExportNoteRenderer.apply(to: image, note: note)
        guard let data = result.jpegData(compressionQuality: 0.95) else { throw CocoaError(.fileWriteUnknown) }
        return try VaultGate.shared.withAccess(generation: generation) { data }
    }
    static func copies(of urls: [URL], includeNotes: Bool, generation: Int, numberingMode: String? = nil) throws -> [URL] {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try VaultGate.shared.withAccess(generation: generation) { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            var result: [URL] = []
            for url in urls {
                let data = try jpegData(for: url, includeNotes: includeNotes, generation: generation)
                let target = directory.appendingPathComponent(FileStorageManager.shared.exportName(for: url, numberingMode: numberingMode))
                try VaultGate.shared.withAccess(generation: generation) { try data.write(to: target, options: .atomic) }
                result.append(target)
            }
            return try VaultGate.shared.withAccess(generation: generation) { result }
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}
