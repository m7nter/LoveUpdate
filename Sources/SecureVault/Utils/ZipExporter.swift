import Foundation
import ZIPFoundation

struct ZipExporter {
    static func exportDay(label: String, urls: [URL], includeNotes: Bool = false, generation: Int? = nil, numberingMode: String? = nil) -> URL? {
        guard !urls.isEmpty else { return nil }

        let fm = FileManager.default
        let epoch = generation ?? VaultGate.shared.generation
        let exportDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workDir = exportDir.appendingPathComponent("photos", isDirectory: true)
        let safeLabel = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let zipURL = exportDir.appendingPathComponent(String(safeLabel.prefix(100)) + ".zip")

        do {
            try VaultGate.shared.withAccess(generation: epoch) { try fm.createDirectory(at: workDir, withIntermediateDirectories: true) }

            var metadataLines: [String] = []
            metadataLines.append("Экспорт фото — \(label)")
            metadataLines.append("Всего снимков: \(urls.count)")
            metadataLines.append("")

            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "ru_RU")
            dateFormatter.dateFormat = "d MMMM yyyy, HH:mm:ss"

            for url in urls {
                let filename = FileStorageManager.shared.exportName(for: url, numberingMode: numberingMode)
                let destURL = workDir.appendingPathComponent(filename)
                let decrypted = try PhotoExporter.jpegData(for: url, includeNotes: includeNotes, generation: epoch)
                try VaultGate.shared.withAccess(generation: epoch) { try decrypted.write(to: destURL, options: .atomic) }

                if let meta = FileStorageManager.shared.loadMeta(for: url) {
                    let dateStr = dateFormatter.string(from: meta.date)
                    metadataLines.append("""
                    Файл: \(filename)
                    Папка: \(FileStorageManager.shared.folder(for: url))
                    Событие: \(meta.eventNumber.map(String.init) ?? "отдельный снимок")
                    Кадр: \(meta.eventIndex ?? 1) / \(meta.eventCount ?? 1)
                    Координаты: \(meta.hasLocation == false ? "нет данных" : String(format: "%.6f, %.6f", meta.latitude, meta.longitude))
                    Карта: \(meta.hasLocation == false ? "нет данных" : "https://maps.google.com/?q=\(meta.latitude),\(meta.longitude)")
                    Дата съёмки: \(dateStr)
                    Заметка: \(meta.note ?? "")

                    """)
                } else {
                    metadataLines.append("""
                    Файл: \(filename)
                    Координаты: нет данных

                    """)
                }
            }

            let metaFileURL = workDir.appendingPathComponent("metadata.txt")
            try VaultGate.shared.withAccess(generation: epoch) {
                try metadataLines.joined(separator: "\n").write(to: metaFileURL, atomically: true, encoding: .utf8)
            }
            let archive = try VaultGate.shared.withAccess(generation: epoch) { try Archive(url: zipURL, accessMode: .create) }
            let contents = try VaultGate.shared.withAccess(generation: epoch) { try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) }
            for fileURL in contents {
                try VaultGate.shared.withAccess(generation: epoch) { try archive.addEntry(with: fileURL.lastPathComponent, relativeTo: workDir) }
            }

            try? fm.removeItem(at: workDir)
            return try VaultGate.shared.withAccess(generation: epoch) { zipURL }
        } catch {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: exportDir)
            return nil
        }
    }
}
