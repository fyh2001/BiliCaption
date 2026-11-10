import Foundation

var checks = 0
var failures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures.append(name); print("FAIL: \(name)") }
}

func decode(_ body: [String: Any]) throws -> BridgeMessage {
    let data = try JSONSerialization.data(withJSONObject: body)
    return try JSONDecoder().decode(BridgeMessage.self, from: data)
}

@discardableResult
func submit(_ store: CaptionStore, _ body: [String: Any], at now: Double) -> Bool {
    do { return store.accept(try decode(body), now: now) }
    catch { failures.append("Fixture failed to decode: \(error)"); return false }
}

let episode = "https://www.bilibili.com/video/BV1Test/?p=1"
let episode2 = "https://www.bilibili.com/video/BV1Test/?p=2"

func cue(_ from: Double, _ to: Double, _ text: String) -> [String: Any] {
    ["from": from, "to": to, "content": text]
}

func track(page: String = episode, cues: [[String: Any]] = [
    cue(0, 2, "第一句话"), cue(2, 4, "第二句话"), cue(6, 10, "第三句话")
]) -> [String: Any] {
    ["kind": "track", "pageKey": page, "cues": cues]
}

func playback(page: String = episode, source: String = "tab-1", time: Double = 0,
              paused: Bool = false, rate: Double = 1, waiting: Bool = false,
              seeking: Bool = false, hasVideo: Bool = true,
              caption: String = "", captionVisible: Bool = false) -> [String: Any] {
    ["kind": "playback", "pageKey": page, "sourceId": source, "title": "听小说",
     "currentTime": time, "paused": paused, "playbackRate": rate,
     "waiting": waiting, "seeking": seeking, "hasVideo": hasVideo,
     "caption": caption, "captionVisible": captionVisible]
}

do {
    let store = CaptionStore()
    expect(store.display(at: 100).player == nil, "Before connecting, no video is selected")
    // An unordered downloaded track must still present the novel in time order.
    expect(submit(store, track(cues: [cue(6, 10, "第三句话"), cue(2, 4, "第二句话"), cue(0, 2, "第一句话")]), at: 100), "Accept a valid unordered track")
    expect(submit(store, playback(), at: 100), "Accept the video playback clock")
    expect(store.display(at: 100).text == "第一句话", "First phrase is visible at its start")
    expect(store.display(at: 101.999).text == "第一句话", "Phrase remains visible just before its end")
    expect(store.display(at: 102).text == "第二句话", "At a shared boundary, show the next phrase")
    expect(store.display(at: 103).previous == "第一句话", "Expanded context contains the previous phrase")
    expect(store.display(at: 103).next == "第三句话", "Expanded context contains the next phrase")
    expect(store.display(at: 104).text == "♪", "At a phrase end followed by silence, clear the text")
    expect(store.display(at: 105).text == "♪", "Do not carry the last phrase through a subtitle gap")
    expect(store.display(at: 106).text == "第三句话", "Next phrase appears at the end of the gap")
    expect(store.display(at: 110).text == "♪", "Final phrase disappears at its end")
}

do {
    let store = CaptionStore()
    submit(store, track(), at: 100)
    submit(store, playback(time: 0.5, paused: true), at: 100)
    expect(store.display(at: 110).text == "第一句话", "Paused video keeps its current phrase")
    expect(store.active(at: 110)?.position(at: 110) == 0.5, "Paused video clock does not advance")
    submit(store, playback(time: 0.5, rate: 2), at: 110)
    expect(store.display(at: 111).text == "第二句话", "At 2×, subtitles advance twice as fast")
    submit(store, playback(time: 6.25, rate: 0.5), at: 111)
    expect(store.display(at: 111).text == "第三句话", "Seeking forward changes the phrase immediately")
    expect(store.active(at: 113)?.position(at: 113) == 7.25, "At 0.5×, media time advances at half speed")
    submit(store, playback(time: 1, seeking: true), at: 113)
    expect(store.display(at: 118).text == "第一句话", "Seeking backward freezes at the reported media position")
    submit(store, playback(time: 1), at: 118)
    expect(store.display(at: 119).text == "第二句话", "Playback resumes from the seek result")
    submit(store, playback(time: 2.25, waiting: true), at: 119)
    expect(store.display(at: 124).text == "第二句话", "Buffering keeps subtitles aligned with stopped audio")
    submit(store, playback(time: 2.25), at: 124)
    expect(store.display(at: 126).text == "♪", "Recovered playback advances through the gap")
}

do {
    let store = CaptionStore()
    submit(store, track(), at: 100)
    submit(store, playback(time: 6.1), at: 100)
    expect(store.active(at: 119.9) != nil, "Recent browser source remains connected")
    expect(store.active(at: 120) == nil, "Stop extrapolating when the browser heartbeat expires")
    expect(store.display(at: 121).player == nil, "Disconnected browser does not leave a false active player")
    submit(store, playback(time: 1), at: 122)
    expect(store.display(at: 122).text == "第一句话", "New heartbeat reconnects and corrects the media clock")
}

do {
    let store = CaptionStore()
    submit(store, track(), at: 100)
    submit(store, track(page: episode2, cues: [cue(0, 100, "另一集")]), at: 100)
    submit(store, playback(source: "tab-paused", time: 1, paused: true), at: 100)
    submit(store, playback(page: episode2, source: "tab-playing", time: 1), at: 101)
    expect(store.display(at: 101).text == "另一集", "Playing tab replaces an inactive paused tab")
    submit(store, playback(source: "tab-paused", time: 1, paused: true), at: 102)
    expect(store.display(at: 102).text == "另一集", "Paused tab heartbeats do not steal the novel display")
    store.selectedSource = "tab-paused"
    expect(store.display(at: 102).text == "第一句话", "Explicit tab selection takes precedence")
    store.selectedSource = nil
    submit(store, playback(page: episode2, source: "tab-playing", time: 2, paused: true), at: 103)
    submit(store, playback(source: "tab-paused", time: 6.1), at: 104)
    expect(store.display(at: 104).text == "第三句话", "Resuming another tab changes the active source")
    submit(store, playback(page: episode2, source: "tab-paused", time: 1), at: 105)
    expect(store.display(at: 105).text == "另一集", "Switching episodes in the same tab uses the new timeline")
    submit(store, playback(source: "tab-empty", time: 0, hasVideo: false), at: 106)
    expect(store.display(at: 106).text == "另一集", "A page with no video cannot steal the active source")
    store.selectedSource = "tab-empty"
    expect(store.display(at: 106).player?.hasVideo == true, "If a chosen tab loses its video, fall back to a usable video")
}

do {
    let store = CaptionStore()
    submit(store, track(cues: [cue(0, 100, "捕获的另一条语言轨道")]), at: 100)
    submit(store, playback(time: 1, caption: "网页当前可见字幕", captionVisible: true), at: 100)
    expect(store.display(at: 100.5).text == "网页当前可见字幕", "Fresh rendered subtitle wins when several languages were requested")
    expect(store.display(at: 101.5).text == "捕获的另一条语言轨道", "When rendered text gets old, use the clocked timeline")
    submit(store, playback(time: 1, caption: "隐藏的旧字幕", captionVisible: false), at: 102)
    expect(store.display(at: 102).text == "捕获的另一条语言轨道", "Hidden DOM text cannot override the background timeline")
}

do {
    let store = CaptionStore()
    submit(store, track(), at: 100)
    submit(store, playback(time: 1), at: 100)
    for (name, cues) in [
        ("empty track", []),
        ("negative time", [cue(-1, 2, "错误")]),
        ("zero duration", [cue(1, 1, "错误")]),
        ("reversed times", [cue(2, 1, "错误")]),
        ("oversized phrase", [cue(0, 2, String(repeating: "文", count: 2001))])
    ] {
        expect(!submit(store, track(cues: cues), at: 101), "Reject \(name)")
        expect(store.display(at: 101).text == "第二句话", "Rejected \(name) preserves the previous usable track")
    }
    var negativeClock = playback(time: -0.1)
    expect(!submit(store, negativeClock, at: 101), "Reject a negative playback clock")
    negativeClock["currentTime"] = 1
    negativeClock["playbackRate"] = 17
    expect(!submit(store, negativeClock, at: 101), "Reject an invalid playback speed")
    var unknown = playback()
    unknown["kind"] = "runCommand"
    expect(!submit(store, unknown, at: 101), "Unknown message types cannot change the caption state")
    let badNumber = Data("{\"kind\":\"playback\",\"pageKey\":\"\(episode)\",\"currentTime\":1e309,\"paused\":false}".utf8)
    expect((try? JSONDecoder().decode(BridgeMessage.self, from: badNumber)) == nil, "Non-finite JSON numbers cannot enter the media clock")
    let badCues = Data("{\"kind\":\"track\",\"pageKey\":\"\(episode)\",\"cues\":[{\"from\":0,\"to\":1,\"content\":7}]}".utf8)
    expect((try? JSONDecoder().decode(BridgeMessage.self, from: badCues)) == nil, "A non-text cue is rejected during decoding")
    expect(store.display(at: 101).text == "第二句话", "Malformed messages do not replace an existing playback clock")
}

do {
    let store = CaptionStore()
    let invalidPages = ["", "http://www.bilibili.com/video/BV1Test/",
                        "https://www.bilibili.com.evil.invalid/video/BV1Test/",
                        "https://www.bilibili.com@evil.invalid/video/BV1Test/",
                        "https://evil.invalid/video/BV1Test/", "https://www.bilibili.com/account",
                        "file:///video/BV1Test/", "https://www.bilibili.com/video/" + String(repeating: "x", count: 2100)]
    for page in invalidPages {
        expect(!submit(store, playback(page: page), at: 100), "Reject source page outside the supported video origin: \(page.prefix(100))")
        expect(!submit(store, track(page: page), at: 100), "Reject track from an unsupported source page: \(page.prefix(100))")
    }
    expect(store.display(at: 100).player == nil, "Rejected pages cannot create a player")
    expect(store.tracks.isEmpty, "Rejected pages cannot populate subtitle tracks")
}

// A one-shot timer must wake for every autonomous display change, but avoid
// polling while paused, disconnected, or waiting for the next browser message.
func expectWake(_ store: CaptionStore, now: Double, at boundary: Double, _ name: String) {
    let wake = store.nextRefreshDelay(at: now).map { now + $0 } ?? .infinity
    expect(wake >= boundary && wake <= boundary + 0.002, name)
}

do {
    let store = CaptionStore()
    expect(store.nextRefreshDelay(at: 100) == nil, "Disconnected app needs no periodic refresh")
    submit(store, track(), at: 100)
    expect(store.nextRefreshDelay(at: 100) == nil, "A cached track alone does not start a refresh timer")
    submit(store, playback(hasVideo: false), at: 100)
    expect(store.nextRefreshDelay(at: 100) == nil, "A source without video does not start a refresh timer")
    submit(store, playback(), at: 100)
    expectWake(store, now: 100, at: 102, "Schedule the first phrase boundary instead of polling")
    let secondPhraseWake = 100 + store.nextRefreshDelay(at: 100)!
    expect(store.display(at: secondPhraseWake).text == "第二句话", "At the scheduled wake the next phrase is visible")
    expectWake(store, now: secondPhraseWake, at: 104, "Schedule the second phrase ending")
    expectWake(store, now: 104.001, at: 106, "During a silent gap sleep until the next phrase")
    expectWake(store, now: 107, at: 110, "A delayed callback schedules from the corrected current position")
    expectWake(store, now: 110.001, at: 120, "After the final phrase only the disconnect deadline remains")
    expect(store.nextRefreshDelay(at: 120) == nil, "An expired source leaves no repeating timer")
}

do {
    let store = CaptionStore()
    submit(store, track(), at: 100)
    submit(store, playback(time: 0.5, rate: 2), at: 100)
    expectWake(store, now: 100, at: 100.75, "At 2× convert media boundary to wall-clock time")
    submit(store, playback(time: 6.25, rate: 0.5), at: 101)
    expectWake(store, now: 101, at: 108.5, "At 0.5× wait until the correct slower phrase ending")
    submit(store, playback(time: 1, paused: true), at: 102)
    expectWake(store, now: 102, at: 122, "A paused timeline schedules only the source timeout")
    submit(store, playback(time: 1, rate: 0), at: 103)
    expectWake(store, now: 103, at: 123, "Zero playback rate does not cause division by zero or polling")
    submit(store, playback(time: 1, waiting: true), at: 104)
    expectWake(store, now: 104, at: 124, "Buffering schedules only the source timeout")
    submit(store, playback(time: 1, seeking: true), at: 105)
    expectWake(store, now: 105, at: 125, "An in-progress seek does not extrapolate subtitle changes")
    submit(store, playback(time: 6.5, rate: 2), at: 106)
    expectWake(store, now: 106, at: 107.75, "After seeking, replace the old deadline using the new clock")
    expectWake(store, now: 105, at: 107.75, "A future clock origin respects the position clamp")
}

do {
    let store = CaptionStore()
    submit(store, track(cues: [cue(0, 0.5, "第一句"), cue(0.5, 10, "第二句")]), at: 100)
    submit(store, playback(caption: "网页当前字幕", captionVisible: true), at: 100)
    expectWake(store, now: 100, at: 101.3, "Fresh DOM text suppresses unnecessary underlying timeline wakes")
    let wake = 100 + store.nextRefreshDelay(at: 100)!
    expect(store.display(at: wake).text == "第二句", "DOM expiry wake switches to the current timeline phrase")
    expectWake(store, now: wake, at: 110, "After DOM expiry schedule the next media boundary")
    submit(store, playback(time: 0.25, paused: true, caption: "暂停时的网页字幕", captionVisible: true), at: 102)
    expectWake(store, now: 102, at: 103.3, "DOM text expiry still matters while paused")
    expectWake(store, now: 103.301, at: 122, "After paused DOM expiry no timeline polling remains")
    submit(store, playback(caption: "隐藏字幕", captionVisible: false), at: 104)
    expectWake(store, now: 104, at: 104.5, "Hidden DOM text does not delay the media boundary")
}

do {
    let store = CaptionStore()
    submit(store, track(cues: [cue(0, 10, "长句"), cue(1, 2, "短句甲"), cue(3, 4, "短句乙")]), at: 100)
    submit(store, playback(), at: 100)
    expectWake(store, now: 100, at: 101, "An overlapping phrase start interrupts the longer visible phrase")
    expectWake(store, now: 101.001, at: 102, "An overlapping short phrase schedules its own end")
    let resumed = 101.001 + store.nextRefreshDelay(at: 101.001)!
    expect(store.display(at: resumed).text == "长句", "When overlap ends the earlier still-active phrase reappears")
    expectWake(store, now: resumed, at: 103, "After overlap recovery schedule the next start")
    expectWake(store, now: 104.001, at: 110, "After the last overlap schedule the surviving long phrase end")
}

do {
    let store = CaptionStore()
    submit(store, track(cues: [cue(5, 30, "较晚开始的字幕")]), at: 100)
    submit(store, playback(time: 1, rate: 2), at: 100)
    expectWake(store, now: 100, at: 102, "Before the first cue schedule its start with playback rate")
    submit(store, playback(time: 5, rate: 0.5), at: 101)
    expectWake(store, now: 101, at: 121, "Disconnect can occur before a long phrase ends")
    let missingTrack = CaptionStore()
    submit(missingTrack, playback(), at: 100)
    expectWake(missingTrack, now: 100, at: 120, "Without a track wait for a message or source timeout")
    submit(missingTrack, playback(caption: "仅网页字幕", captionVisible: true), at: 101)
    expectWake(missingTrack, now: 101, at: 102.3, "DOM expiry refreshes the fallback state even without a track")
    expectWake(missingTrack, now: 102.301, at: 121, "Persistent fallback text does not need polling")
}

do {
    let store = CaptionStore()
    submit(store, track(), at: 100)
    submit(store, track(page: episode2, cues: [cue(0, 100, "备用视频")]), at: 100)
    submit(store, playback(source: "selected", time: 1, paused: true), at: 100)
    submit(store, playback(page: episode2, source: "fallback", time: 1, paused: true), at: 105)
    store.selectedSource = "selected"
    expectWake(store, now: 110, at: 120, "Schedule selected source expiry while a fresher fallback exists")
    let fallbackWake = 110 + store.nextRefreshDelay(at: 110)!
    expect(store.display(at: fallbackWake).text == "备用视频", "At expiry switch to the surviving fallback source")
    expectWake(store, now: fallbackWake, at: 125, "After source switch schedule the fallback's own timeout")
    expect(store.nextRefreshDelay(at: 125.001) == nil, "After all sources expire stop scheduling")
    submit(store, playback(source: "selected", time: 1, paused: true), at: 124)
    expectWake(store, now: 124, at: 144, "A heartbeat replaces the old source deadline")
    expectWake(store, now: 125.001, at: 144, "An unused source expiry does not wake the selected paused source")
}

if failures.isEmpty {
    print("PASS: \(checks) user-visible caption behavior checks")
} else {
    print("\(failures.count) failure(s) in \(checks) checks")
    exit(1)
}
