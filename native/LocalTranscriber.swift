import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech

/// User-started, in-memory transcription of one browser application's system audio.
/// Public state and callbacks are used on the main thread. No permissions are asked
/// in init or availableBrowsers, no microphone is opened, and no cloud fallback exists.
final class LocalTranscriber: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var stateText = "本地转写未开启"
    var onChange: (() -> Void)?
    var onCaption: ((String) -> Void)?

    var availableBrowsers: [(id: String, title: String)] {
        let applications = NSWorkspace.shared.runningApplications
        var seen = Set<String>()
        return applications.compactMap { application in
            guard let id = application.bundleIdentifier,
                  Self.browserNames[id] != nil,
                  !application.isTerminated,
                  seen.insert(id).inserted else { return nil }
            return (id: id, title: application.localizedName ?? Self.browserNames[id] ?? id)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static let browserNames: [String: String] = [
        "company.thebrowser.Browser": "Arc", "company.thebrowser.dia": "Dia",
        "com.apple.Safari": "Safari", "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome", "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev", "com.google.Chrome.canary": "Google Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge", "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.brave.Browser": "Brave", "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox Developer Edition",
        "com.operasoftware.Opera": "Opera", "com.vivaldi.Vivaldi": "Vivaldi",
        "com.kagi.kagimacOS": "Orion", "org.chromium.Chromium": "Chromium"
    ]
    private let audioQueue = DispatchQueue(label: "local.bilicaption.transcription.audio", qos: .userInitiated)
    // Accessed only on audioQueue; stream callbacks use that same serial queue.
    private var audioPipeline: LocalSpeechPipeline?
    private var audioStreamIdentity: ObjectIdentifier?
    // Accessed only on the main thread.
    private var captureStream: SCStream?
    private var startupTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var recognitionContext: UInt64 = 0

    /// Call only in response to the person's explicit Start action.
    func start(bundleID: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start(bundleID: bundleID) }
            return
        }
        stopInternal()
        guard Self.browserNames[bundleID] != nil else {
            update("请选择正在运行的浏览器")
            return
        }
        let session = generation
        update("正在准备本地中文转写…")
        startupTask = Task { @MainActor [weak self] in
            await self?.begin(bundleID: bundleID, session: session)
        }
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        stopInternal()
        update("本地转写已停止")
    }

    /// Clears an episode/seek boundary while retaining the same selected browser
    /// capture. This method neither checks nor requests any new permissions.
    func resetRecognition() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.resetRecognition() }
            return
        }
        guard isRunning else { return }
        recognitionContext &+= 1
        let context = recognitionContext
        audioQueue.async { [weak self] in self?.audioPipeline?.reset(context: context) }
    }

    /// Internal PCM conversion entry point also exercised by synthetic tests.
    static func makePCMBuffer(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        try LocalSpeechPipeline.copyPCM(sample)
    }

    private func stopInternal() {
        generation &+= 1
        startupTask?.cancel()
        startupTask = nil
        isRunning = false
        let oldStream = captureStream
        captureStream = nil
        audioQueue.async { [weak self] in
            self?.audioPipeline?.stop()
            self?.audioPipeline = nil
            self?.audioStreamIdentity = nil
        }
        if let oldStream {
            Task {
                try? await oldStream.stopCapture()
                try? oldStream.removeStreamOutput(self, type: .audio)
            }
        }
    }

    private func update(_ message: String) {
        stateText = message
        onChange?()
    }

    @MainActor private func begin(bundleID: String, session: UInt64) async {
        guard generation == session, !Task.isCancelled else { return }
        let speechUsage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String ?? ""
        let screenUsage = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String ?? ""
        guard !speechUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !screenUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update("安装包缺少语音识别或系统音频权限说明，请重新安装完整程序")
            return
        }
        let authorization = await Self.speechAuthorization()
        guard generation == session, !Task.isCancelled else { return }
        guard authorization == .authorized else {
            switch authorization {
            case .denied: update("未获语音识别授权，请到系统设置 → 隐私与安全性 → 语音识别中允许")
            case .restricted: update("此 Mac 的语音识别权限受到系统限制")
            default: update("未获得语音识别授权，本地转写未启动")
            }
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.locale.language.languageCode?.identifier == "zh" else {
            update("此 Mac 不支持中文语音识别，本地转写未启动")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            update("中文离线语音模型不可用；请在系统设置中启用中文听写并安装模型，再重试。不会转到云端")
            return
        }
        guard recognizer.isAvailable else {
            update("本机中文语音识别暂不可用，请检查中文听写模型后重试。不会转到云端")
            return
        }
        // The system calls this Screen & System Audio Recording permission even
        // though this implementation registers no screen or microphone output.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            update("请允许“屏幕与系统音频录制”权限，然后重新打开程序再开始；只处理所选浏览器的声音")
            return
        }
        guard generation == session, !Task.isCancelled else { return }
        update("正在连接浏览器声音…")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard generation == session, !Task.isCancelled else { return }
            let selected = content.applications.filter { $0.bundleIdentifier == bundleID }
            guard !selected.isEmpty else {
                update("未找到所选浏览器，请打开浏览器窗口并开始播放后重试")
                return
            }
            // Inclusion is essential: never fall back to an entire-display audio
            // mix if the requested app cannot be found. Audio filtering is app-wide.
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                update("未找到可用显示器，无法建立浏览器音频捕获")
                return
            }
            let filter = SCContentFilter(display: display, including: selected, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
            configuration.queueDepth = 3
            if #available(macOS 15.0, *) { configuration.captureMicrophone = false }

            let pipeline = LocalSpeechPipeline(recognizer: recognizer, queue: audioQueue, context: recognitionContext)
            pipeline.onCaption = { [weak self] text, context in
                DispatchQueue.main.async {
                    guard let self, self.generation == session, self.recognitionContext == context, self.isRunning else { return }
                    self.onCaption?(text)
                }
            }
            pipeline.onStatus = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, self.generation == session, self.isRunning else { return }
                    self.update(text)
                }
            }
            pipeline.onFailure = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.generation == session else { return }
                    self.stopInternal()
                    self.update(message)
                }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            let streamIdentity = ObjectIdentifier(stream)
            audioQueue.async { [weak self] in
                guard let self else { return }
                self.audioPipeline = pipeline
                self.audioStreamIdentity = streamIdentity
                pipeline.start()
            }
            captureStream = stream
            try await stream.startCapture()
            guard generation == session, !Task.isCancelled else {
                try? await stream.stopCapture()
                return
            }
            isRunning = true
            startupTask = nil
            onCaption?("")
            let name = Self.browserNames[bundleID] ?? "浏览器"
            update("正在本机转写 · \(name)；此浏览器其他标签页的声音也会包含")
        } catch {
            guard generation == session else { return }
            stopInternal()
            update("无法捕获浏览器声音：\(error.localizedDescription)。请检查屏幕与系统音频录制权限")
        }
    }

    private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, audioStreamIdentity == ObjectIdentifier(stream),
              CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        audioPipeline?.accept(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        let identity = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.captureStream, ObjectIdentifier(current) == identity else { return }
            self.stopInternal()
            self.update("浏览器音频捕获已停止：\(message)")
        }
    }
}

/// All mutable fields below belong to the capture's serial audio queue. Audio is
/// copied into owned PCM buffers before the CMSampleBuffer callback returns.
private final class LocalSpeechPipeline: @unchecked Sendable {
    var onCaption: ((String, UInt64) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let recognizer: SFSpeechRecognizer
    private let queue: DispatchQueue
    private let callbackQueue: OperationQueue
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var running = false
    private var recognitionGeneration: UInt64 = 0
    private var context: UInt64
    private var sessionStarted = 0.0
    private var lastSignal = 0.0
    private var waitingForSound = false
    private var lastCaption = ""
    private var rapidFailures = 0
    private var conversionFailures = 0
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0

    init(recognizer: SFSpeechRecognizer, queue: DispatchQueue, context: UInt64) {
        self.recognizer = recognizer
        self.queue = queue
        self.context = context
        callbackQueue = OperationQueue()
        callbackQueue.name = "local.bilicaption.transcription.callbacks"
        callbackQueue.maxConcurrentOperationCount = 1
        callbackQueue.underlyingQueue = queue
        recognizer.queue = callbackQueue
    }

    func start() {
        running = true
        lastSignal = ProcessInfo.processInfo.systemUptime
        beginRecognition(replay: false)
        guard running else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        running = false
        recognitionGeneration &+= 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        converter = nil
        targetFormat = nil
        preRoll.removeAll(keepingCapacity: false)
        preRollFrames = 0
        onCaption = nil
        onStatus = nil
        onFailure = nil
    }

    func reset(context: UInt64) {
        guard running else { return }
        self.context = context
        recognitionGeneration &+= 1
        preRoll.removeAll(keepingCapacity: false)
        preRollFrames = 0
        converter = nil
        lastCaption = ""
        rapidFailures = 0
        conversionFailures = 0
        waitingForSound = false
        lastSignal = ProcessInfo.processInfo.systemUptime
        beginRecognition(replay: false)
    }

    func accept(_ sample: CMSampleBuffer) {
        guard running, CMSampleBufferGetNumSamples(sample) > 0 else { return }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("中文离线模型已不可用，转写已停止；不会转到云端")
            return
        }
        do {
            let input = try LocalTranscriber.makePCMBuffer(from: sample)
            let output = try converted(input)
            guard output.frameLength > 0 else { return }
            conversionFailures = 0
            request?.append(output)
            keepPreRoll(output)
            if Self.hasSignal(output) {
                lastSignal = ProcessInfo.processInfo.systemUptime
                if waitingForSound {
                    waitingForSound = false
                    onStatus?("正在本机转写浏览器声音")
                }
            }
        } catch {
            conversionFailures += 1
            if conversionFailures >= 3 { fail("无法读取浏览器的 PCM 音频：\(error.localizedDescription)") }
        }
    }

    private func beginRecognition(replay: Bool) {
        guard running else { return }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            fail("本机中文语音模型不可用，转写已停止；不会转到云端")
            return
        }
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        request?.endAudio()
        recognitionTask?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        let native = request.nativeAudioFormat
        let format = native.sampleRate > 0 && native.channelCount > 0 ? native : AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        if targetFormat != format {
            converter = nil
            preRoll.removeAll()
            preRollFrames = 0
        }
        targetFormat = format
        sessionStarted = ProcessInfo.processInfo.systemUptime
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Copy only value types across to the serial queue, not an SF result.
            let text = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            let errorCode = (error as NSError?)?.code
            let errorDomain = (error as NSError?)?.domain
            self?.queue.async { [weak self] in
                self?.handle(text: text, final: final, errorText: errorText, errorCode: errorCode, errorDomain: errorDomain, generation: generation)
            }
        }
        // A short, bounded overlap reduces lost words at a segment boundary.
        // It stays entirely in memory and is released when transcription stops.
        if replay { for buffer in preRoll { request.append(buffer) } }
    }

    private func handle(text: String, final: Bool, errorText: String?, errorCode: Int?, errorDomain: String?, generation: UInt64) {
        guard running, generation == recognitionGeneration else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rapidFailures = 0
            let caption = Self.captionTail(text)
            if caption != lastCaption {
                lastCaption = caption
                onCaption?(caption, context)
            }
        }
        guard final || errorText != nil else { return }
        let duration = ProcessInfo.processInfo.systemUptime - sessionStarted
        // No-speech is a normal result during a paused/silent browser. Other rapid
        // failures are bounded so a missing local model cannot cause a retry loop.
        let noSpeech = errorDomain == "kAFAssistantErrorDomain" && errorCode == 1110
        if errorText != nil && !noSpeech && duration < 8 { rapidFailures += 1 }
        else if duration >= 8 || noSpeech { rapidFailures = 0 }
        if rapidFailures >= 3 {
            fail("本地中文识别失败：\(errorText ?? "离线模型不可用")。请检查中文听写模型后重新开始；不会转到云端")
            return
        }
        recognitionGeneration &+= 1
        let waitingGeneration = recognitionGeneration
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        queue.asyncAfter(deadline: .now() + (noSpeech ? 0.5 : 0.15)) { [weak self] in
            guard let self, self.running, self.recognitionGeneration == waitingGeneration else { return }
            self.beginRecognition(replay: true)
        }
    }

    private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if request != nil && now - sessionStarted >= 50 {
            beginRecognition(replay: true)
        }
        if now - lastSignal > 12, !waitingForSound {
            waitingForSound = true
            onStatus?("等待浏览器声音；请确认所选浏览器正在播放且未静音")
        }
    }

    private func fail(_ message: String) {
        let callback = onFailure
        stop()
        callback?(message)
    }

    /// Preserves the sample's exact ASBD, including interleaved/planar layout.
    /// CopyPCMData fills owned AVAudioPCMBuffer memory, so Speech never references
    /// storage whose CMSampleBuffer/CMBlockBuffer lifetime has already ended.
    static func copyPCM(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              basic.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: basic) else { throw AudioIssue.invalidFormat }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 192_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { throw AudioIssue.invalidBuffer }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw AudioIssue.copyFailed(status) }
        return buffer
    }

    private func converted(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let targetFormat else { throw AudioIssue.invalidFormat }
        if input.format == targetFormat { return input }
        if converter?.inputFormat != input.format || converter?.outputFormat != targetFormat {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }
        guard let converter else { throw AudioIssue.invalidFormat }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { throw AudioIssue.invalidBuffer }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw error ?? AudioIssue.invalidFormat as NSError }
        return output
    }

    private func keepPreRoll(_ buffer: AVAudioPCMBuffer) {
        preRoll.append(buffer)
        preRollFrames += buffer.frameLength
        let maximum = AVAudioFrameCount(buffer.format.sampleRate * 0.6)
        while preRoll.count > 1 && preRollFrames > maximum {
            preRollFrames -= preRoll.removeFirst().frameLength
        }
    }

    private static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        // The recognizer's native format is normally planar Float32. If it isn't,
        // consider arriving non-empty PCM active rather than misreporting silence.
        guard let channels = buffer.floatChannelData else { return buffer.frameLength > 0 }
        let stride = max(1, Int(buffer.format.channelCount) * (buffer.format.isInterleaved ? 1 : 0))
        for index in Swift.stride(from: 0, to: Int(buffer.frameLength), by: 16) {
            if abs(channels[0][index * stride]) > 0.0005 { return true }
        }
        return false
    }

    private static func captionTail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 90 else { return trimmed }
        return String(trimmed.suffix(90))
    }

    private enum AudioIssue: LocalizedError {
        case invalidFormat, invalidBuffer, copyFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "不支持的 PCM 音频格式"
            case .invalidBuffer: return "无效的音频缓冲区"
            case .copyFailed(let status): return "无法复制音频样本（\(status)）"
            }
        }
    }
}
