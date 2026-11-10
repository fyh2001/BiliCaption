import Foundation

struct ListeningList: Codable, Equatable {
    let id: UUID
    var name: String
    var items: [MediaItem]
}

struct ListeningProgress: Codable, Equatable {
    let time: Double
    let rate: Double
    let duration: Double?
    let updatedAt: Date
}

/// Local-only listening lists and playback positions. Subtitle text is never persisted.
/// Call from the main thread, alongside CaptionStore and the app's presentation state.
final class ListeningLibrary {
    private struct Document: Codable {
        var version: Int = 1
        var lists: [ListeningList]
        var selectedListID: UUID?
        var progress: [String: ListeningProgress]
    }

    private(set) var lists: [ListeningList] = []
    private(set) var selectedListID: UUID?
    private(set) var lastError: String?
    let fileURL: URL
    private var positions: [String: ListeningProgress] = [:]
    private var dirty = false
    private var writable = true
    private var lastPersistedAt: Date?
    private var lastPlaybackURL: String?
    private var lastPaused = false

    var selectedList: ListeningList? { lists.first { $0.id == selectedListID } }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliCaption", isDirectory: true).appendingPathComponent("listening-library.json")
        load()
    }

    @discardableResult
    func selectList(_ id: UUID?) -> Bool {
        guard id == nil || lists.contains(where: { $0.id == id }) else { return false }
        selectedListID = id
        return saveMutation()
    }

    @discardableResult
    func createList(name: String) -> UUID? {
        guard let name = validName(name), lists.count < 100 else { return nil }
        let id = UUID()
        lists.append(ListeningList(id: id, name: name, items: []))
        selectedListID = id
        _ = saveMutation()
        return id
    }

    @discardableResult
    func renameList(id: UUID, name: String) -> Bool {
        guard let name = validName(name), let index = lists.firstIndex(where: { $0.id == id }) else { return false }
        lists[index].name = name
        return saveMutation()
    }

    @discardableResult
    func deleteList(id: UUID) -> Bool {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return false }
        lists.remove(at: index)
        if selectedListID == id { selectedListID = lists.first?.id }
        return saveMutation()
    }

    @discardableResult
    func addItems(_ items: [MediaItem], to id: UUID) -> Int {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return 0 }
        let remaining = min(2000 - lists[index].items.count, 10_000 - lists.reduce(0) { $0 + $1.items.count })
        guard remaining > 0 else { return 0 }
        var knownURLs = Set(lists[index].items.map(\.url))
        var knownIDs = Set(lists[index].items.map(\.id))
        var additions: [MediaItem] = []
        for item in items.prefix(2000) {
            guard let valid = item.normalized, !knownURLs.contains(valid.url) else { continue }
            // Bilibili may reuse an item id for different pages; local rows must remain individually addressable.
            let localID = knownIDs.contains(valid.id) ? UUID().uuidString.lowercased() : valid.id
            let addition = MediaItem(id: localID, url: valid.url, title: valid.title, duration: valid.duration, index: valid.index)
            additions.append(addition)
            knownURLs.insert(valid.url)
            knownIDs.insert(localID)
            if additions.count == remaining { break }
        }
        guard !additions.isEmpty else { return 0 }
        lists[index].items.append(contentsOf: additions)
        _ = saveMutation()
        return additions.count
    }

    @discardableResult
    func removeItem(id itemID: String, from listID: UUID) -> Bool {
        guard let list = lists.firstIndex(where: { $0.id == listID }),
              let item = lists[list].items.firstIndex(where: { $0.id == itemID }) else { return false }
        lists[list].items.remove(at: item)
        return saveMutation()
    }

    /// The destination is the item's final zero-based index.
    @discardableResult
    func moveItem(id itemID: String, in listID: UUID, to destination: Int) -> Bool {
        guard let list = lists.firstIndex(where: { $0.id == listID }),
              let source = lists[list].items.firstIndex(where: { $0.id == itemID }),
              destination >= 0, destination < lists[list].items.count else { return false }
        let item = lists[list].items.remove(at: source)
        lists[list].items.insert(item, at: destination)
        return saveMutation()
    }

    func progress(for url: String) -> ListeningProgress? {
        guard let key = canonicalVideoURL(url) else { return nil }
        return positions[key]
    }

    func recordProgress(url: String, time: Double, rate: Double, duration: Double? = nil,
                        paused: Bool = false, force: Bool = false, now: Date = Date()) {
        guard let key = canonicalVideoURL(url), time.isFinite, time >= 0, time <= 31_536_000,
              rate.isFinite, rate > 0, rate <= 16, now.timeIntervalSince1970.isFinite,
              duration == nil || (duration!.isFinite && duration! >= 0 && duration! <= 31_536_000) else { return }
        positions[key] = ListeningProgress(time: duration.map { min(time, $0) } ?? time,
                                          rate: rate, duration: duration, updatedAt: now)
        if positions.count > 20_000, let oldest = positions.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            positions.removeValue(forKey: oldest)
        }
        dirty = true
        let changedEpisode = lastPlaybackURL != nil && lastPlaybackURL != key
        let didPause = paused && (!lastPaused || lastPlaybackURL != key)
        lastPlaybackURL = key
        lastPaused = paused
        if force || changedEpisode || didPause || lastPersistedAt == nil || now.timeIntervalSince(lastPersistedAt!) >= 5 {
            _ = persist(now: now)
        }
    }

    @discardableResult
    func flush() -> Bool { persist(now: Date()) }

    private func validName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 100 ? clean : nil
    }

    private func saveMutation() -> Bool {
        dirty = true
        return flush()
    }

    private func persist(now: Date) -> Bool {
        guard writable else { return false }
        guard dirty else { return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let document = Document(lists: lists, selectedListID: selectedListID, progress: positions)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            dirty = false
            lastPersistedAt = now
            return true
        } catch {
            lastError = "听单保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 20 * 1024 * 1024 else { throw LibraryError.invalid }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1, document.lists.count <= 100, document.progress.count <= 20_000,
                  document.lists.reduce(0, { $0 + $1.items.count }) <= 10_000,
                  Set(document.lists.map(\.id)).count == document.lists.count,
                  document.selectedListID == nil || document.lists.contains(where: { $0.id == document.selectedListID }) else { throw LibraryError.invalid }
            var loadedLists: [ListeningList] = []
            for list in document.lists {
                guard let name = validName(list.name), list.items.count <= 2000 else { throw LibraryError.invalid }
                let items = list.items.compactMap(\.normalized)
                guard items.count == list.items.count, Set(items.map(\.id)).count == items.count,
                      Set(items.map(\.url)).count == items.count else { throw LibraryError.invalid }
                loadedLists.append(ListeningList(id: list.id, name: name, items: items))
            }
            var loadedPositions: [String: ListeningProgress] = [:]
            for (rawURL, progress) in document.progress {
                guard let url = canonicalVideoURL(rawURL), progress.time.isFinite, progress.time >= 0, progress.time <= 31_536_000,
                      progress.rate.isFinite, progress.rate > 0, progress.rate <= 16, progress.updatedAt.timeIntervalSince1970.isFinite,
                      progress.duration == nil || (progress.duration!.isFinite && progress.duration! >= 0 && progress.duration! <= 31_536_000) else { throw LibraryError.invalid }
                if loadedPositions[url] == nil || loadedPositions[url]!.updatedAt < progress.updatedAt { loadedPositions[url] = progress }
            }
            lists = loadedLists
            selectedListID = document.selectedListID
            positions = loadedPositions
        } catch {
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: fileURL, to: backup)
                lastError = "听单文件无法读取，原文件已备份为 \(backup.lastPathComponent)。可以新建听单继续使用。"
            } catch {
                // Do not replace a damaged file if we could not preserve it for recovery.
                writable = false
                lastError = "听单文件无法读取，且备份失败。原文件已保留：\(fileURL.path)"
            }
        }
    }

    private enum LibraryError: Error { case invalid }
}
