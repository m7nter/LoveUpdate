import UIKit
import CoreLocation

struct CaptureContext: Codable {
    var eventID: UUID
    var folder: String
    var expectedCount: Int
    var index: Int
    var eventNumber: Int
    var capturedAt: Date? = nil
    var generation: Int? = nil
}

struct PhotoMeta: Codable {
    let latitude: Double
    let longitude: Double
    let date: Date
    var note: String? = nil
    // Optional fields preserve compatibility with existing encrypted JSON.
    var hasLocation: Bool? = nil
    var folder: String? = nil
    var eventID: UUID? = nil
    var eventIndex: Int? = nil
    var eventCount: Int? = nil
    var eventNumber: Int? = nil
    var dailyNumber: Int? = nil
    var totalNumber: Int? = nil
}

final class FileStorageManager {
    static let shared = FileStorageManager()
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    private let directory: URL?
    private let defaults: UserDefaults
    private var cachedLatestURL: URL?
    private var vaultDirectory: URL {
        directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VaultPhotos")
    }

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        try? VaultGate.shared.withAccess {
            try fm.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
            backfillNumbers()
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func validFolder(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func newEventUnlocked() -> CaptureContext {
        lock.lock(); defer { lock.unlock() }
        let store = SettingsStore.shared
        let number = defaults.integer(forKey: "eventCounter") + 1
        defaults.set(number, forKey: "eventCounter")
        return CaptureContext(eventID: UUID(),
            folder: store.foldersEnabled && Self.validFolder(store.activeWorkMode) ? store.activeWorkMode : "Без режима",
            expectedCount: min(20, max(1, store.photosPerEvent)), index: 1, eventNumber: number, generation: VaultGate.shared.generation)
    }

    private func allocateNumbers(date: Date) -> (Int, Int) {
        let key = "photoDayCounter." + Self.dayKey(date)
        let daily = defaults.integer(forKey: key) + 1
        let total = defaults.integer(forKey: "photoTotalCounter") + 1
        defaults.set(daily, forKey: key)
        defaults.set(total, forKey: "photoTotalCounter")
        return (daily, total)
    }

    private func saveUnlocked(image: UIImage, location: CLLocation? = nil, context: CaptureContext? = nil) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let event = context ?? newEvent()
        guard Self.validFolder(event.folder), let jpeg = image.jpegData(compressionQuality: 0.92),
              let encrypted = CryptoManager.encrypt(jpeg) else { return nil }
        let date = event.capturedAt ?? Date()
        let numbers = allocateNumbers(date: date)
        var meta = PhotoMeta(latitude: location?.coordinate.latitude ?? 0,
                             longitude: location?.coordinate.longitude ?? 0, date: date)
        meta.hasLocation = location != nil
        meta.folder = event.folder; meta.eventID = event.eventID
        meta.eventIndex = event.index; meta.eventCount = event.expectedCount
        meta.eventNumber = event.eventNumber
        meta.dailyNumber = numbers.0; meta.totalNumber = numbers.1
        let dir = event.folder == "Без режима" ? vaultDirectory : vaultDirectory.appendingPathComponent(event.folder)
        let filename = SettingsStore.shared.numberingMode == "off"
            ? UUID().uuidString + ".jpg" : numberedName(meta: meta, fallback: UUID().uuidString)
        let url = dir.appendingPathComponent(filename)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try encrypted.write(to: url, options: .atomic)
            do { try saveMeta(meta, for: url) }
            catch { try? fm.removeItem(at: url); throw error }
            cachedLatestURL = nil
            return url
        } catch { return nil }
    }

    private func loadAllUnlocked() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        guard let enumerator = fm.enumerator(at: vaultDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return [] }
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jpg" }
        let dates = Dictionary(uniqueKeysWithValues: urls.map { ($0, photoDate($0)) })
        let result = urls.sorted {
            let a = dates[$0] ?? .distantPast, b = dates[$1] ?? .distantPast
            return a == b ? $0.path < $1.path : a > b
        }
        cachedLatestURL = result.first
        return result
    }

    func photoDate(_ url: URL) -> Date {
        loadMeta(for: url)?.date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
    func loadImage(at url: URL) -> UIImage? {
        guard let data = decryptedData(for: url) else { return nil }
        return UIImage(data: data)
    }
    private func decryptedDataUnlocked(for url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let data = CryptoManager.decrypt(raw) { return data }
        return UIImage(data: raw) != nil ? raw : nil
    }
    private func metaURL(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("json") }
    private func loadMetaUnlocked(for url: URL) -> PhotoMeta? {
        guard let raw = try? Data(contentsOf: metaURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(PhotoMeta.self, from: CryptoManager.decrypt(raw) ?? raw)
    }
    private func saveMeta(_ meta: PhotoMeta, for url: URL) throws {
        let data = try JSONEncoder().encode(meta)
        guard let encrypted = CryptoManager.encrypt(data) else { throw CocoaError(.fileWriteUnknown) }
        try encrypted.write(to: metaURL(for: url), options: .atomic)
    }
    func loadAllWithMeta() -> [(URL, PhotoMeta?)] { loadAll().map { ($0, loadMeta(for: $0)) } }
    func lastPhotoLocation() -> CLLocation? {
        try? VaultGate.shared.withAccess { () -> CLLocation? in
            lock.lock(); defer { lock.unlock() }
            if let url = cachedLatestURL, !fm.fileExists(atPath: url.path) { cachedLatestURL = nil }
            if cachedLatestURL == nil { cachedLatestURL = loadAll().first }
            guard let url = cachedLatestURL, let m = loadMeta(for: url), m.hasLocation != false else { return nil }
            return CLLocation(latitude: m.latitude, longitude: m.longitude)
        }
    }
    private func overwriteUnlocked(image: UIImage, at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let jpeg = image.jpegData(compressionQuality: 0.92), let encrypted = CryptoManager.encrypt(jpeg) else { return false }
        do { try encrypted.write(to: url, options: .atomic); return true } catch { return false }
    }
    private func updateNoteUnlocked(for url: URL, note: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard fm.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        if fm.fileExists(atPath: metaURL(for: url).path), loadMeta(for: url) == nil { throw CocoaError(.fileReadCorruptFile) }
        var meta = loadMeta(for: url) ?? PhotoMeta(latitude: 0, longitude: 0, date: photoDate(url), hasLocation: false)
        meta.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        try saveMeta(meta, for: url)
    }
    func folder(for url: URL) -> String {
        url.deletingLastPathComponent() == vaultDirectory ? "Без режима" : url.deletingLastPathComponent().lastPathComponent
    }
    func eventKey(for url: URL) -> String { loadMeta(for: url)?.eventID?.uuidString ?? url.path }
    private func completeEventUnlocked(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let members = loadAll().filter { loadMeta(for: $0)?.eventID == id }
        for url in members {
            if var meta = loadMeta(for: url) {
                meta.eventCount = members.count
                try? saveMeta(meta, for: url)
            }
        }
    }
    func title(for url: URL) -> String {
        guard let meta = loadMeta(for: url) else { return url.deletingPathExtension().lastPathComponent }
        var parts: [String] = []
        let mode = SettingsStore.shared.numberingMode
        if (mode == "daily" || mode == "both"), let n = meta.dailyNumber { parts.append("За день №\(n)") }
        if (mode == "total" || mode == "both"), let n = meta.totalNumber { parts.append("Общий №\(n)") }
        if let event = meta.eventNumber { parts.append("Событие \(event) · \(meta.eventIndex ?? 1)/\(meta.eventCount ?? 1)") }
        return parts.isEmpty ? url.deletingPathExtension().lastPathComponent : parts.joined(separator: " · ")
    }
    private func numberedName(meta: PhotoMeta, fallback: String, numberingMode: String? = nil) -> String {
        var parts = [Self.dayKey(meta.date)]
        let mode = numberingMode ?? SettingsStore.shared.numberingMode
        if mode == "daily" || mode == "both" { parts.append(String(format: "D%04d", meta.dailyNumber ?? 0)) }
        if mode == "total" || mode == "both" { parts.append(String(format: "G%06d", meta.totalNumber ?? 0)) }
        if let n = meta.eventNumber { parts.append(String(format: "E%06d-%02d", n, meta.eventIndex ?? 1)) }
        if parts.count == 1 { parts.append(fallback) }
        return parts.joined(separator: "_") + ".jpg"
    }
    func exportName(for url: URL, numberingMode: String? = nil) -> String {
        guard let meta = loadMeta(for: url) else { return url.lastPathComponent }
        return numberedName(meta: meta, fallback: url.deletingPathExtension().lastPathComponent, numberingMode: numberingMode)
    }
    // Moving a member always moves its entire event, including sidecars.
    private func moveEventsUnlocked(containing urls: [URL], to folder: String) throws {
        lock.lock(); defer { lock.unlock() }
        defer { cachedLatestURL = nil }
        guard Self.validFolder(folder) else { throw CocoaError(.fileWriteInvalidFileName) }
        let keys = Set(urls.map { eventKey(for: $0) })
        let members = loadAll().filter { keys.contains(eventKey(for: $0)) }
        let dir = folder == "Без режима" ? vaultDirectory : vaultDirectory.appendingPathComponent(folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var moved: [(URL, URL, PhotoMeta?)] = []
        do {
            for source in members {
                let target = dir.appendingPathComponent(source.lastPathComponent)
                if source == target { continue }
                let original = loadMeta(for: source)
                if fm.fileExists(atPath: metaURL(for: source).path), original == nil { throw CocoaError(.fileReadCorruptFile) }
                try fm.moveItem(at: source, to: target)
                moved.append((source, target, original))
                if fm.fileExists(atPath: metaURL(for: source).path) {
                    try fm.moveItem(at: metaURL(for: source), to: metaURL(for: target))
                }
                if var meta = original { meta.folder = folder; try saveMeta(meta, for: target) }
            }
        } catch {
            for (source, target, original) in moved.reversed() {
                try? fm.moveItem(at: target, to: source)
                if fm.fileExists(atPath: metaURL(for: target).path) {
                    try? fm.moveItem(at: metaURL(for: target), to: metaURL(for: source))
                }
                if let meta = original { try? saveMeta(meta, for: source) }
            }
            throw error
        }
    }
    private func deleteUnlocked(url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { cachedLatestURL = nil }
        do {
            try fm.removeItem(at: url)
            if fm.fileExists(atPath: metaURL(for: url).path) { try fm.removeItem(at: metaURL(for: url)) }
            return true
        } catch { return false }
    }

    func newEvent() -> CaptureContext {
        // Called only from an authorized current camera session.
        (try? VaultGate.shared.withAccess { newEventUnlocked() }) ?? CaptureContext(eventID: UUID(), folder: "Без режима", expectedCount: 1, index: 1, eventNumber: 0, generation: -1)
    }
    func save(image: UIImage, location: CLLocation? = nil, context: CaptureContext? = nil) -> URL? {
        try? VaultGate.shared.withAccess(generation: context?.generation) { saveUnlocked(image: image, location: location, context: context) }
    }
    func loadAll() -> [URL] { (try? VaultGate.shared.withAccess { loadAllUnlocked() }) ?? [] }
    func loadMeta(for url: URL) -> PhotoMeta? { try? VaultGate.shared.withAccess { loadMetaUnlocked(for: url) } }
    func decryptedData(for url: URL) -> Data? { try? VaultGate.shared.withAccess { decryptedDataUnlocked(for: url) } }
    @discardableResult func overwrite(image: UIImage, at url: URL, generation: Int? = nil) -> Bool {
        (try? VaultGate.shared.withAccess(generation: generation) { overwriteUnlocked(image: image, at: url) }) ?? false
    }
    @discardableResult func updateNote(for url: URL, note: String, generation: Int? = nil) -> Bool {
        (try? VaultGate.shared.withAccess(generation: generation) { try updateNoteUnlocked(for: url, note: note); return true }) ?? false
    }
    func completeEvent(_ id: UUID) { try? VaultGate.shared.withAccess { completeEventUnlocked(id) } }
    func moveEvents(containing urls: [URL], to folder: String) throws {
        try VaultGate.shared.withAccess { try moveEventsUnlocked(containing: urls, to: folder) }
    }
    @discardableResult func delete(url: URL) -> Bool {
        (try? VaultGate.shared.withAccess { deleteUnlocked(url: url) }) ?? false
    }

    private func backfillNumbers() {
        for url in loadAll().reversed() {
            guard decryptedData(for: url) != nil else { continue }
            if fm.fileExists(atPath: metaURL(for: url).path), loadMeta(for: url) == nil { continue }
            var meta = loadMeta(for: url) ?? PhotoMeta(latitude: 0, longitude: 0, date: photoDate(url), hasLocation: false)
            if meta.totalNumber != nil && meta.dailyNumber != nil { continue }
            let numbers = allocateNumbers(date: meta.date)
            meta.dailyNumber = numbers.0; meta.totalNumber = numbers.1
            try? saveMeta(meta, for: url)
        }
    }
}
