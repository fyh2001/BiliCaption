import Foundation

struct Cue: Codable, Equatable {
    let from: Double
    let to: Double
    let content: String
}

/// Stable identity for saved episodes. Tracking fields and transient cid values are not identities.
func canonicalVideoURL(_ raw: String) -> String? {
    guard raw.utf8.count <= 2048, let parts = URLComponents(string: raw),
          parts.scheme == "https", parts.host?.lowercased() == "www.bilibili.com",
          parts.user == nil, parts.password == nil, parts.port == nil,
          parts.path.range(of: #"^/video/BV[a-zA-Z0-9]+/?$"#, options: .regularExpression) != nil else { return nil }
    let pages = (parts.queryItems ?? []).filter { $0.name == "p" }
    guard pages.count <= 1 else { return nil }
    var result = "https://www.bilibili.com" + parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/"
    if let page = pages.first {
        guard let value = page.value, value.range(of: #"^[0-9]{1,6}$"#, options: .regularExpression) != nil,
              let number = Int(value), number >= 1, number <= 100_000 else { return nil }
        // p=1 and an omitted p refer to the same episode.
        if number > 1 { result += "?p=\(number)" }
    }
    return result
}

private extension String {
    var withLeadingSlash: String { "/" + self }
}

struct MediaItem: Codable, Equatable {
    let id: String
    let url: String
    let title: String
    var duration: Double? = nil
    var index: Int? = nil

    var normalized: MediaItem? {
        guard !id.isEmpty, id.utf8.count <= 256, !title.isEmpty, title.count <= 500,
              let url = canonicalVideoURL(url),
              duration == nil || (duration!.isFinite && duration! >= 0 && duration! <= 31_536_000),
              index == nil || (index! >= 0 && index! <= 100_000) else { return nil }
        return MediaItem(id: id, url: url, title: title, duration: duration, index: index)
    }
}

struct SubtitleTrack: Codable, Equatable {
    let id: String
    let label: String
    let language: String
    let isAI: Bool
}

struct MediaCatalog: Codable, Equatable {
    let title: String
    let items: [MediaItem]
    let subtitles: [SubtitleTrack]
    var selectedSubtitleID: String? = nil
    var subtitleStatus: String? = nil

    var normalized: MediaCatalog? {
        guard title.count <= 500, items.count <= 2000, subtitles.count <= 64,
              subtitleStatus == nil || subtitleStatus!.count <= 1000,
              subtitles.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.label.count <= 200 && $0.language.utf8.count <= 64 }),
              Set(subtitles.map(\.id)).count == subtitles.count,
              selectedSubtitleID == nil || subtitles.contains(where: { $0.id == selectedSubtitleID }) else { return nil }
        let validItems = items.compactMap(\.normalized)
        guard validItems.count == items.count, Set(validItems.map(\.id)).count == validItems.count else { return nil }
        return MediaCatalog(title: title, items: validItems, subtitles: subtitles, selectedSubtitleID: selectedSubtitleID, subtitleStatus: subtitleStatus)
    }
}

struct AccountFolder: Codable, Equatable {
    let id: String
    let title: String
    let count: Int
}

struct AccountLibrary: Codable, Equatable {
    let loggedIn: Bool
    let folders: [AccountFolder]
    let items: [MediaItem]
    var folderID: String? = nil
    var error: String? = nil

    var normalized: AccountLibrary? {
        guard folders.count <= 500, items.count <= 2000,
              folders.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.title.count <= 300 && $0.count >= 0 && $0.count <= 1_000_000 }),
              Set(folders.map(\.id)).count == folders.count,
              folderID == nil || folderID!.utf8.count <= 128, error == nil || error!.count <= 1000 else { return nil }
        let validItems = items.compactMap(\.normalized)
        guard validItems.count == items.count, Set(validItems.map(\.id)).count == validItems.count else { return nil }
        return AccountLibrary(loggedIn: loggedIn, folders: folders, items: validItems, folderID: folderID, error: error)
    }
}

struct BridgeMessage: Decodable {
    let kind: String
    let pageKey: String
    let sourceId: String?
    let title: String?
    let cues: [Cue]?
    let currentTime: Double?
    let paused: Bool?
    let waiting: Bool?
    let seeking: Bool?
    let playbackRate: Double?
    let caption: String?
    let captionVisible: Bool?
    let hasVideo: Bool?
    let duration: Double?
    let ended: Bool?
    let catalog: MediaCatalog?
    let account: AccountLibrary?
}

struct Playback {
    var pageKey: String
    var title: String
    var time: Double
    var paused: Bool
    var rate: Double
    var caption: String
    var captionVisible: Bool
    var hasVideo: Bool
    var received: Double
    var duration: Double? = nil
    var ended: Bool = false

    func position(at now: Double) -> Double {
        let position = time + (paused || ended ? 0 : max(0, now - received) * rate)
        return duration.map { min(position, $0) } ?? position
    }
}

final class CaptionStore {
    static let staleAfter: Double = 20
    private(set) var tracks: [String: [Cue]] = [:]
    private(set) var players: [String: Playback] = [:]
    private(set) var activeSource: String?
    var selectedSource: String?
    private var catalogs: [String: (page: String, value: MediaCatalog)] = [:]
    private var accounts: [String: (page: String, value: AccountLibrary)] = [:]

    func catalog(for sourceId: String?) -> MediaCatalog? {
        guard let sourceId else { return nil }
        return catalogs[sourceId]?.value
    }

    func account(for sourceId: String?) -> AccountLibrary? {
        guard let sourceId else { return nil }
        return accounts[sourceId]?.value
    }

    @discardableResult
    func accept(_ message: BridgeMessage, now: Double) -> Bool {
        guard let page = canonicalVideoURL(message.pageKey), now.isFinite else { return false }
        if message.kind == "catalog" || message.kind == "account" {
            guard let source = message.sourceId, !source.isEmpty, source.utf8.count < 128,
                  players[source] == nil || canonicalVideoURL(players[source]!.pageKey) == page else { return false }
            if message.kind == "catalog" {
                guard let catalog = message.catalog?.normalized else { return false }
                if catalogs[source] == nil && catalogs.count >= 32 { return false }
                catalogs[source] = (page, catalog)
            } else {
                guard let account = message.account?.normalized else { return false }
                if accounts[source] == nil && accounts.count >= 32 { return false }
                accounts[source] = (page, account)
            }
            return true
        }
        if message.kind == "track" {
            guard let cues = message.cues, !cues.isEmpty, cues.count <= 50_000,
                  cues.allSatisfy({ $0.from.isFinite && $0.to.isFinite && $0.from >= 0 && $0.to > $0.from && $0.content.count <= 2000 }) else { return false }
            tracks[message.pageKey] = cues.sorted { $0.from < $1.from }
            if tracks.count > 12 {
                let used = Set(players.values.map(\.pageKey))
                if let old = tracks.keys.first(where: { !used.contains($0) }) { tracks.removeValue(forKey: old) }
            }
            return true
        }
        guard message.kind == "playback", let time = message.currentTime,
              let paused = message.paused, time.isFinite, time >= 0 else { return false }
        let source = message.sourceId ?? message.pageKey
        guard !source.isEmpty, source.utf8.count < 128 else { return false }
        let rate = message.playbackRate ?? 1
        guard rate.isFinite, rate >= 0, rate <= 16,
              message.duration == nil || (message.duration!.isFinite && message.duration! >= 0 && message.duration! <= 31_536_000) else { return false }
        if catalogs[source]?.page != page { catalogs.removeValue(forKey: source) }
        if accounts[source]?.page != page { accounts.removeValue(forKey: source) }
        let player = Playback(pageKey: message.pageKey, title: String((message.title ?? "B 站视频").prefix(300)),
                              time: time, paused: paused || message.waiting == true || message.seeking == true,
                              rate: rate, caption: String((message.caption ?? "").prefix(2000)), captionVisible: message.captionVisible ?? false,
                              hasVideo: message.hasVideo ?? true, received: now, duration: message.duration, ended: message.ended ?? false)
        players[source] = player
        let expiredSources = players.filter { now - $0.value.received >= 120 }.map(\.key)
        for expired in expiredSources {
            players.removeValue(forKey: expired)
            catalogs.removeValue(forKey: expired)
            accounts.removeValue(forKey: expired)
        }
        let current = activeSource.flatMap { players[$0] }
        if activeSource == nil || current == nil || now - (current?.received ?? 0) >= Self.staleAfter ||
            (current?.paused == true && !player.paused && player.hasVideo) {
            activeSource = source
        }
        if let selectedSource, players[selectedSource] == nil { self.selectedSource = nil }
        return true
    }

    func active(at now: Double) -> Playback? {
        guard let source = activeSourceId(at: now) else { return nil }
        return players[source]
    }

    func activeSourceId(at now: Double) -> String? {
        if let selectedSource, let player = players[selectedSource], player.hasVideo, now - player.received < Self.staleAfter { return selectedSource }
        if let activeSource, let player = players[activeSource], now - player.received < Self.staleAfter, player.hasVideo { return activeSource }
        return players.filter { $0.value.hasVideo && now - $0.value.received < Self.staleAfter }.sorted {
            if $0.value.paused != $1.value.paused { return !$0.value.paused }
            return $0.value.received > $1.value.received
        }.first?.key
    }

    func cueIndex(_ cues: [Cue], time: Double) -> Int? {
        let lower = firstCueStarting(after: time, in: cues)
        guard lower > 0 else { return nil }
        // Normally subtitle segments do not overlap. Check a few predecessors for overlapping phrases.
        for index in stride(from: lower - 1, through: max(0, lower - 8), by: -1) {
            if time < cues[index].to { return index }
        }
        return nil
    }

    private func firstCueStarting(after time: Double, in cues: [Cue]) -> Int {
        var lower = 0, upper = cues.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if cues[mid].from <= time { lower = mid + 1 } else { upper = mid }
        }
        return lower
    }

    /// Time until the display can change without a browser message. New messages
    /// must refresh immediately and replace the existing one-shot timer.
    func nextRefreshDelay(at now: Double) -> Double? {
        guard let player = active(at: now) else { return nil }
        // Only the displayed source can change the UI by expiring. At that point
        // display(at:) selects any remaining source and we schedule its deadline.
        var deadline = player.received + Self.staleAfter
        let renderedCaptionExpires = player.received + 1.3
        if player.captionVisible && !player.caption.isEmpty && now < renderedCaptionExpires {
            deadline = min(deadline, renderedCaptionExpires)
        } else if !player.paused, player.rate > 0, let cues = tracks[player.pageKey] {
            let position = player.position(at: now)
            var nextMediaBoundary: Double?
            if let index = cueIndex(cues, time: position) {
                nextMediaBoundary = cues[index].to
            }
            let nextIndex = firstCueStarting(after: position, in: cues)
            if nextIndex < cues.count {
                nextMediaBoundary = min(nextMediaBoundary ?? .infinity, cues[nextIndex].from)
            }
            if let boundary = nextMediaBoundary {
                // Use the clock's origin instead of repeatedly adding durations.
                // This also handles the position() clamp before received time.
                deadline = min(deadline, player.received + (boundary - player.time) / player.rate)
            }
        }
        // Land just after the boundary so floating point roundoff cannot cause
        // repeated immediate timers while cueIndex still sees the previous cue.
        return max(0.001, deadline - now + 0.001)
    }

    func display(at now: Double) -> (text: String, previous: String, next: String, state: String, player: Playback?) {
        guard let player = active(at: now) else { return ("B 站字幕 · 等待连接", "", "", "打开 B 站视频，并开启播放器的 AI 中文字幕", nil) }
        let state = player.paused ? "已暂停" : "正在播放 · \(String(format: "%g", player.rate))×"
        // A recent rendered caption reflects the player's chosen language, including bilingual tracks.
        if player.captionVisible && !player.caption.isEmpty && now - player.received < 1.3 {
            return (player.caption, "", "", state, player)
        }
        if let cues = tracks[player.pageKey] {
            if let index = cueIndex(cues, time: player.position(at: now)) {
                return (cues[index].content, index > 0 ? cues[index-1].content : "", index + 1 < cues.count ? cues[index+1].content : "", state, player)
            }
            return ("♪", "", "", state + " · 当前无字幕", player)
        }
        if !player.caption.isEmpty { return (player.caption, "", "", state + " · 页面字幕同步", player) }
        return ("B 站字幕 · 请开启字幕", "", "", "已连接，等待播放器加载 AI 中文字幕", player)
    }
}
