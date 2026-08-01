import Foundation

enum Platform: String, CaseIterable {
    case twitter = "Twitter"
    case discord = "Discord"

    /// Platform limits are expressed as decimal megabytes by their respective
    /// help centers. A smaller working target leaves room for MP4 metadata.
    var maxFileSize: Int64 {
        switch self {
        case .twitter: return 512_000_000
        case .discord: return 10_000_000
        }
    }

    var workingFileSize: Int64 {
        Int64(Double(maxFileSize) * 0.94)
    }

    var maxDuration: Double? {
        switch self {
        case .twitter: return 140
        case .discord: return nil
        }
    }

    var maximumFrameRate: Double {
        switch self {
        case .twitter: return 40
        case .discord: return 60
        }
    }

    var maximumVideoBitrate: Int {
        switch self {
        case .twitter: return 25_000_000
        case .discord: return 50_000_000
        }
    }

    var fileSuffix: String {
        switch self {
        case .twitter: return "_twitter"
        case .discord: return "_discord"
        }
    }

    var limitDescription: String {
        switch self {
        case .twitter: return "Free • 512 MB • 2:20 • 40 fps"
        case .discord: return "Free • under 10 MB"
        }
    }
}

enum CompressionRequirement: Equatable {
    case ready
    case editsOnly
    case compatibilityOnly
    case compression

    var message: String {
        switch self {
        case .ready: return "Already fits — no quality loss"
        case .editsOnly: return "Fits after editing — no size reduction needed"
        case .compatibilityOnly: return "Fits — only a compatibility conversion is needed"
        case .compression: return "The edited video will be optimized for this limit"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle"
        case .editsOnly: return "scissors"
        case .compatibilityOnly: return "arrow.triangle.2.circlepath"
        case .compression: return "arrow.down.circle"
        }
    }
}

private struct CompressionPlan {
    let segments: [VideoSegment]
    let editedDuration: Double
    let speed: Double
    let outputDuration: Double
    var videoBitrate: Int
    let audioBitrate: Int
    let width: Int
    let height: Int
    let frameRate: Double
    let useStreamCopy: Bool
    let preserveSourceQuality: Bool
}

private enum CompressionFailure: LocalizedError {
    case noVideoLeft
    case couldNotCreateOutput
    case outputTooLarge(actual: Int64, limit: Int64)
    case durationTooLong(actual: Double, limit: Double)
    case ffmpeg(status: Int32, message: String, details: String)

    var errorDescription: String? {
        switch self {
        case .noVideoLeft:
            return "The trims and cuts remove the entire video."
        case .couldNotCreateOutput:
            return "FFmpeg finished, but no output file was created."
        case let .outputTooLarge(actual, limit):
            let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "The result is still \(actualText), above the \(limitText) limit."
        case let .durationTooLong(actual, limit):
            return "The result is \(actual.qwikTimecode), above the \(limit.qwikTimecode) limit."
        case let .ffmpeg(_, message, _):
            return message
        }
    }

    var diagnosticDetails: String? {
        if case let .ffmpeg(status, _, details) = self {
            return "FFmpeg exit code \(status)\n\n\(details)"
        }
        return nil
    }
}

private final class LockedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ value: String) {
        lock.lock()
        text.append(value)
        if text.count > 80_000 {
            text = String(text.suffix(60_000))
        }
        lock.unlock()
    }

    func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func set(_ value: Bool) {
        lock.lock()
        cancelled = value
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

@MainActor
final class VideoCompressor: ObservableObject {
    @Published var progress: Double = 0
    @Published var isCompressing = false
    @Published var error: String?
    @Published var errorDetails: String?
    @Published var outputURL: URL?
    @Published var outputFileSize: Int64 = 0
    @Published var statusMessage = ""

    private var process: Process?
    private let cancellationState = CancellationState()

    static var ffmpegPath: String? {
        let paths = [
            Bundle.main.path(forResource: "ffmpeg", ofType: nil),
            "/opt/homebrew/bin/ffmpeg",
            "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/local/opt/ffmpeg/bin/ffmpeg"
        ].compactMap { $0 }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpegInstalled: Bool {
        ffmpegPath != nil
    }

    static func requirement(video: VideoInfo, edit: VideoEdit, platform: Platform) -> CompressionRequirement {
        let editedDuration = edit.editedDuration(for: video.duration)
        let durationFits = platform.maxDuration.map { editedDuration <= $0 + 0.05 } ?? true
        let estimatedEditedSize = Double(video.fileSize)
            * editedDuration / max(0.001, video.duration)
        let estimatedSizeFits = estimatedEditedSize < Double(platform.workingFileSize)
        let timelineChanged = edit.hasTimelineEdits(for: video.duration)
        let compatible = isStreamCopyCompatible(
            video: video,
            platform: platform,
            effectiveDuration: editedDuration
        )

        if !timelineChanged, estimatedSizeFits, durationFits, compatible {
            return .ready
        }
        if estimatedSizeFits, durationFits {
            return timelineChanged ? .editsOnly : .compatibilityOnly
        }
        return .compression
    }

    func compress(video: VideoInfo, edit: VideoEdit, for platform: Platform) async {
        guard let ffmpeg = Self.ffmpegPath else {
            error = "FFmpeg not found. Install it with brew install ffmpeg."
            return
        }

        isCompressing = true
        cancellationState.set(false)
        progress = 0
        error = nil
        errorDetails = nil
        outputURL = nil
        outputFileSize = 0
        statusMessage = "Planning compression…"

        let outputURL = buildOutputURL(for: video.url, platform: platform)
        removeFileIfPresent(at: outputURL)

        do {
            var plan = try makePlan(video: video, edit: edit, platform: platform)

            if plan.useStreamCopy {
                statusMessage = "Already within the limit — finishing without quality loss…"
                let args = baseArguments + [
                    "-i", video.url.path,
                    "-map", "0:v:0",
                    "-map", "0:a?",
                    "-c", "copy",
                    "-movflags", "+faststart",
                    outputURL.path
                ]
                do {
                    try await runFFmpeg(
                        path: ffmpeg,
                        args: args,
                        duration: video.duration,
                        progressRange: 0...0.96
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A source can have a compatible video track but an audio
                    // codec that cannot be copied into MP4. Re-encoding is a
                    // dependable fallback and needs no extra decision from the user.
                    removeFileIfPresent(at: outputURL)
                    progress = 0
                    statusMessage = "Converting for compatibility…"
                    try await transcode(
                        video: video,
                        plan: &plan,
                        platform: platform,
                        ffmpegPath: ffmpeg,
                        outputURL: outputURL
                    )
                }
            } else if plan.preserveSourceQuality {
                statusMessage = edit.hasTimelineEdits(for: video.duration)
                    ? "Applying edits without size reduction…"
                    : "Converting without size reduction…"
                try await transcodePreservingQuality(
                    video: video,
                    plan: plan,
                    platform: platform,
                    ffmpegPath: ffmpeg,
                    outputURL: outputURL
                )

                if fileSize(at: outputURL) > platform.maxFileSize {
                    statusMessage = "The edited result needs light compression…"
                    try await transcode(
                        video: video,
                        plan: &plan,
                        platform: platform,
                        ffmpegPath: ffmpeg,
                        outputURL: outputURL
                    )
                }
            } else {
                try await transcode(
                    video: video,
                    plan: &plan,
                    platform: platform,
                    ffmpegPath: ffmpeg,
                    outputURL: outputURL
                )
            }

            try validate(outputURL: outputURL, platform: platform)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            outputFileSize = attributes[.size] as? Int64 ?? 0
            self.outputURL = outputURL
            progress = 1
            statusMessage = "Done"
        } catch is CancellationError {
            removeFileIfPresent(at: outputURL)
            statusMessage = "Cancelled"
        } catch {
            removeFileIfPresent(at: outputURL)
            if !cancellationState.get() {
                self.error = error.localizedDescription
                self.errorDetails = (error as? CompressionFailure)?.diagnosticDetails
            }
        }

        process = nil
        isCompressing = false
    }

    func cancel() {
        cancellationState.set(true)
        process?.terminate()
        statusMessage = "Cancelling…"
    }

    func reset() {
        progress = 0
        error = nil
        errorDetails = nil
        outputURL = nil
        outputFileSize = 0
        statusMessage = ""
    }

    // MARK: - Planning

    private func makePlan(video: VideoInfo, edit: VideoEdit, platform: Platform) throws -> CompressionPlan {
        let segments = edit.segments(for: video.duration)
        let editedDuration = segments.reduce(0) { $0 + $1.duration }
        guard editedDuration > 0.05 else { throw CompressionFailure.noVideoLeft }

        let requirement = Self.requirement(video: video, edit: edit, platform: platform)
        let useStreamCopy = requirement == .ready
        let preserveSourceQuality = requirement == .editsOnly || requirement == .compatibilityOnly

        let requiredDurationSpeed: Double
        if let maximumDuration = platform.maxDuration {
            requiredDurationSpeed = max(1, editedDuration / maximumDuration)
        } else {
            requiredDurationSpeed = 1
        }

        let baseOutputDuration = editedDuration / requiredDurationSpeed
        let baseTotalBitrate = Double(platform.workingFileSize) * 8 / max(0.1, baseOutputDuration)
        let desiredVideoBitrate = desiredQualityBitrate(video: video, platform: platform)
        let desiredAudioBitrate = video.hasAudio ? 128_000.0 : 0
        let desiredTotalBitrate = desiredVideoBitrate + desiredAudioBitrate

        let qualityRatio = max(1, desiredTotalBitrate / max(1, baseTotalBitrate))
        var speed = requiredDurationSpeed * pow(qualityRatio, edit.clarityPreference)

        // Below this rate, a valid MP4 leaves almost nothing for video. In that
        // extreme case a little additional speed is necessary even at "Keep timing".
        let technicalMinimum = video.hasAudio ? 72_000.0 : 32_000.0
        if baseTotalBitrate < technicalMinimum {
            speed = max(speed, requiredDurationSpeed * technicalMinimum / max(1, baseTotalBitrate))
        }

        let outputDuration = editedDuration / speed
        let totalBitrate = Double(platform.workingFileSize) * 8 / max(0.1, outputDuration)
        let audioBitrate = chooseAudioBitrate(totalBitrate: totalBitrate, hasAudio: video.hasAudio)
        let availableVideoBitrate = max(24_000, Int(totalBitrate) - audioBitrate)
        // The platform allowance is a ceiling, not a target. Giving a short
        // clip the entire 512 MB X budget can request an encoder-breaking
        // bitrate over 1 Gbps. Preserve useful source quality without
        // exceeding either the remaining budget or the platform ceiling.
        let videoBitrate = max(
            24_000,
            min(availableVideoBitrate, min(Int(desiredVideoBitrate), platform.maximumVideoBitrate))
        )
        let frameRate: Double
        let resolution: (width: Int, height: Int)
        if preserveSourceQuality {
            frameRate = min(max(12, video.frameRate), platform.maximumFrameRate)
            resolution = maximumDimensions(for: video.resolution, platform: platform)
        } else {
            frameRate = chooseFrameRate(
                source: video.frameRate,
                videoBitrate: videoBitrate,
                platformMaximum: platform.maximumFrameRate
            )
            resolution = chooseResolution(
                source: video.resolution,
                videoBitrate: videoBitrate,
                frameRate: frameRate,
                platform: platform
            )
        }

        return CompressionPlan(
            segments: segments,
            editedDuration: editedDuration,
            speed: speed,
            outputDuration: outputDuration,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            width: resolution.width,
            height: resolution.height,
            frameRate: frameRate,
            useStreamCopy: useStreamCopy,
            preserveSourceQuality: preserveSourceQuality
        )
    }

    private static func isStreamCopyCompatible(
        video: VideoInfo,
        platform: Platform,
        effectiveDuration: Double? = nil
    ) -> Bool {
        switch platform {
        case .discord:
            return ["h264", "hevc", "av1"].contains(video.videoCodec)
        case .twitter:
            guard video.videoCodec == "h264",
                  (effectiveDuration ?? video.duration) <= 140.05,
                  video.frameRate <= 40.05 else { return false }
            let width = video.resolution.width
            let height = video.resolution.height
            let resolutionFits = width >= height
                ? width <= 1920 && height <= 1200
                : width <= 1200 && height <= 1900
            let aspect = width / max(1, height)
            return resolutionFits && aspect >= (1 / 2.39) && aspect <= 2.39
        }
    }

    private func desiredQualityBitrate(video: VideoInfo, platform: Platform) -> Double {
        let cappedFrameRate = min(max(15, video.frameRate), platform.maximumFrameRate)
        let dimensions = maximumDimensions(for: video.resolution, platform: platform)
        let pixelBasedRate = Double(dimensions.width * dimensions.height) * cappedFrameRate * 0.05
        let sourceRate = video.estimatedVideoBitrate > 0 ? video.estimatedVideoBitrate : pixelBasedRate
        return min(12_000_000, max(350_000, min(pixelBasedRate, sourceRate * 1.05)))
    }

    private func chooseAudioBitrate(totalBitrate: Double, hasAudio: Bool) -> Int {
        guard hasAudio else { return 0 }
        switch totalBitrate {
        case 1_000_000...: return 128_000
        case 450_000...: return 96_000
        case 220_000...: return 64_000
        case 120_000...: return 48_000
        case 72_000...: return 32_000
        default: return 24_000
        }
    }

    private func chooseFrameRate(source: Double, videoBitrate: Int, platformMaximum: Double) -> Double {
        let sourceRate = min(max(12, source), platformMaximum)
        switch videoBitrate {
        case ..<220_000: return min(sourceRate, 15)
        case ..<600_000: return min(sourceRate, 24)
        case ..<1_400_000: return min(sourceRate, 30)
        default: return sourceRate
        }
    }

    private func chooseResolution(
        source: CGSize,
        videoBitrate: Int,
        frameRate: Double,
        platform: Platform
    ) -> (width: Int, height: Int) {
        let maximum = maximumDimensions(for: source, platform: platform)
        let maximumPixels = Double(maximum.width * maximum.height)
        let affordablePixels = Double(videoBitrate) / max(1, frameRate * 0.065)
        let scale = min(1, sqrt(affordablePixels / max(1, maximumPixels)))

        var width = even(Int(Double(maximum.width) * scale))
        var height = even(Int(Double(maximum.height) * scale))

        if width < 160 || height < 90 {
            let aspect = Double(maximum.width) / Double(max(1, maximum.height))
            if aspect >= 1 {
                width = 160
                height = even(max(90, Int(160 / aspect)))
            } else {
                height = 160
                width = even(max(90, Int(160 * aspect)))
            }
        }
        return (width, height)
    }

    private func maximumDimensions(for source: CGSize, platform: Platform) -> (width: Int, height: Int) {
        let sourceWidth = max(2, Int(source.width))
        let sourceHeight = max(2, Int(source.height))
        let landscape = sourceWidth >= sourceHeight
        let caps: (width: Int, height: Int)

        switch platform {
        case .twitter:
            caps = landscape ? (1920, 1200) : (1200, 1900)
        case .discord:
            caps = landscape ? (1920, 1080) : (1080, 1920)
        }

        let scale = min(
            1,
            min(Double(caps.width) / Double(sourceWidth), Double(caps.height) / Double(sourceHeight))
        )
        return (
            even(max(2, Int(Double(sourceWidth) * scale))),
            even(max(2, Int(Double(sourceHeight) * scale)))
        )
    }

    private func even(_ value: Int) -> Int {
        max(2, value - abs(value % 2))
    }

    // MARK: - Encoding

    private var baseArguments: [String] {
        ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"]
    }

    private func transcodePreservingQuality(
        video: VideoInfo,
        plan: CompressionPlan,
        platform: Platform,
        ffmpegPath: String,
        outputURL: URL
    ) async throws {
        removeFileIfPresent(at: outputURL)
        let includeAudio = video.hasAudio
        let filterGraph = buildFilterGraph(video: video, plan: plan, includeAudio: includeAudio)
        var arguments = baseArguments + [
            "-i", video.url.path,
            "-filter_complex", filterGraph,
            "-map", "[vout]",
            "-c:v", "libx264",
            "-preset", "medium",
            "-profile:v", "main",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            "-maxrate", "\(platform.maximumVideoBitrate)",
            "-bufsize", "\(platform.maximumVideoBitrate * 2)"
        ]

        if includeAudio {
            arguments += ["-map", "[aout]", "-c:a", "aac", "-b:a", "\(plan.audioBitrate)"]
        } else {
            arguments += ["-an"]
        }
        arguments += [
            "-tag:v", "avc1",
            "-movflags", "+faststart",
            outputURL.path
        ]

        try await runFFmpeg(
            path: ffmpegPath,
            args: arguments,
            duration: plan.outputDuration,
            progressRange: 0...0.96
        )
    }

    private func transcode(
        video: VideoInfo,
        plan: inout CompressionPlan,
        platform: Platform,
        ffmpegPath: String,
        outputURL: URL
    ) async throws {
        let passLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("QwikVidCompressor-\(UUID().uuidString)")
            .path
        defer { cleanPassLogs(prefix: passLog) }

        for attempt in 0..<3 {
            removeFileIfPresent(at: outputURL)
            cleanPassLogs(prefix: passLog)

            statusMessage = attempt == 0 ? "Analyzing video…" : "Tightening file size…"
            let pass1 = buildTranscodeArguments(
                video: video,
                plan: plan,
                outputPath: outputURL.path,
                passLog: passLog,
                pass: 1
            )
            try await runFFmpeg(
                path: ffmpegPath,
                args: pass1,
                duration: plan.outputDuration,
                progressRange: 0...0.48
            )

            statusMessage = "Encoding final video…"
            let pass2 = buildTranscodeArguments(
                video: video,
                plan: plan,
                outputPath: outputURL.path,
                passLog: passLog,
                pass: 2
            )
            try await runFFmpeg(
                path: ffmpegPath,
                args: pass2,
                duration: plan.outputDuration,
                progressRange: 0.48...0.96
            )

            let size = fileSize(at: outputURL)
            if size <= platform.maxFileSize {
                return
            }

            let ratio = Double(platform.workingFileSize) / Double(max(1, size))
            plan.videoBitrate = max(24_000, Int(Double(plan.videoBitrate) * ratio * 0.97))
        }

        throw CompressionFailure.outputTooLarge(
            actual: fileSize(at: outputURL),
            limit: platform.maxFileSize
        )
    }

    private func buildTranscodeArguments(
        video: VideoInfo,
        plan: CompressionPlan,
        outputPath: String,
        passLog: String,
        pass: Int
    ) -> [String] {
        let includeAudio = pass == 2 && video.hasAudio
        let filterGraph = buildFilterGraph(video: video, plan: plan, includeAudio: includeAudio)

        var arguments = baseArguments + [
            "-i", video.url.path,
            "-filter_complex", filterGraph,
            "-map", "[vout]",
            "-c:v", "libx264",
            "-preset", "medium",
            "-profile:v", "main",
            "-pix_fmt", "yuv420p",
            "-b:v", "\(plan.videoBitrate)",
            "-maxrate", "\(Int(Double(plan.videoBitrate) * 1.15))",
            "-bufsize", "\(plan.videoBitrate * 2)",
            "-pass", "\(pass)",
            "-passlogfile", passLog
        ]

        if pass == 1 {
            arguments += ["-an", "-f", "null", "/dev/null"]
        } else {
            if includeAudio {
                arguments += ["-map", "[aout]", "-c:a", "aac", "-b:a", "\(plan.audioBitrate)"]
            } else {
                arguments += ["-an"]
            }
            arguments += [
                "-tag:v", "avc1",
                "-movflags", "+faststart",
                outputPath
            ]
        }
        return arguments
    }

    private func buildFilterGraph(video: VideoInfo, plan: CompressionPlan, includeAudio: Bool) -> String {
        var filters: [String] = []
        var videoLabels: [String] = []
        var audioLabels: [String] = []

        for (index, segment) in plan.segments.enumerated() {
            let start = ffmpegNumber(segment.start)
            let end = ffmpegNumber(segment.end)
            let videoLabel = "vsegment\(index)"
            filters.append("[0:v:0]trim=start=\(start):end=\(end),setpts=PTS-STARTPTS[\(videoLabel)]")
            videoLabels.append("[\(videoLabel)]")

            if includeAudio {
                let audioLabel = "asegment\(index)"
                filters.append("[0:a:0]atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS[\(audioLabel)]")
                audioLabels.append("[\(audioLabel)]")
            }
        }

        if videoLabels.count == 1 {
            filters.append("\(videoLabels[0])null[vjoined]")
        } else {
            filters.append("\(videoLabels.joined())concat=n=\(videoLabels.count):v=1:a=0[vjoined]")
        }

        var videoTransforms = ["setpts=PTS/\(ffmpegNumber(plan.speed))"]
        videoTransforms.append("scale=\(plan.width):\(plan.height):flags=lanczos")
        videoTransforms.append("fps=\(ffmpegNumber(plan.frameRate))")
        videoTransforms.append("setsar=1")
        filters.append("[vjoined]\(videoTransforms.joined(separator: ","))[vout]")

        if includeAudio {
            if audioLabels.count == 1 {
                filters.append("\(audioLabels[0])anull[ajoined]")
            } else {
                filters.append("\(audioLabels.joined())concat=n=\(audioLabels.count):v=0:a=1[ajoined]")
            }

            let tempoFilters = audioTempoFilters(speed: plan.speed)
            if tempoFilters.isEmpty {
                filters.append("[ajoined]anull[aout]")
            } else {
                filters.append("[ajoined]\(tempoFilters.joined(separator: ","))[aout]")
            }
        }

        return filters.joined(separator: ";")
    }

    private func audioTempoFilters(speed: Double) -> [String] {
        guard abs(speed - 1) > 0.0001 else { return [] }
        var remaining = speed
        var filters: [String] = []

        while remaining > 2.0 {
            filters.append("atempo=2.0")
            remaining /= 2.0
        }
        while remaining < 0.5 {
            filters.append("atempo=0.5")
            remaining /= 0.5
        }
        filters.append("atempo=\(ffmpegNumber(remaining))")
        return filters
    }

    private func ffmpegNumber(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Process handling

    private func runFFmpeg(
        path: String,
        args: [String],
        duration: Double,
        progressRange: ClosedRange<Double>
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let progressPipe = Pipe()
            let errorPipe = Pipe()
            let progressBuffer = LockedTextBuffer()
            let errorBuffer = LockedTextBuffer()
            let gate = ContinuationGate()
            let cancellationState = self.cancellationState

            process.standardOutput = progressPipe
            process.standardError = errorPipe

            progressPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                progressBuffer.append(chunk)
                let latest = progressBuffer.contents()
                let seconds = Self.latestProgressSeconds(in: latest)
                guard let seconds else { return }
                let fraction = min(max(0, seconds / max(0.1, duration)), 1)
                let adjusted = progressRange.lowerBound + fraction * (progressRange.upperBound - progressRange.lowerBound)
                Task { @MainActor [weak self] in
                    self?.progress = adjusted
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                errorBuffer.append(chunk)
            }

            process.terminationHandler = { [weak self] finishedProcess in
                progressPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let remainingErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErrorData.isEmpty,
                   let remainingError = String(data: remainingErrorData, encoding: .utf8) {
                    errorBuffer.append(remainingError)
                }

                Task { @MainActor [weak self] in
                    self?.process = nil
                }

                if finishedProcess.terminationStatus == 0 {
                    gate.resume(continuation, with: .success(()))
                } else if cancellationState.get() {
                    gate.resume(continuation, with: .failure(CancellationError()))
                } else {
                    let details = errorBuffer.contents()
                    let message = Self.friendlyFFmpegMessage(from: details)
                    gate.resume(
                        continuation,
                        with: .failure(CompressionFailure.ffmpeg(
                            status: finishedProcess.terminationStatus,
                            message: message,
                            details: Self.tail(of: details)
                        ))
                    )
                }
            }

            self.process = process
            do {
                try process.run()
            } catch {
                progressPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                gate.resume(continuation, with: .failure(error))
            }
        }
    }

    nonisolated private static func latestProgressSeconds(in output: String) -> Double? {
        let lines = output.split(whereSeparator: \Character.isNewline)
        for line in lines.reversed() {
            if line.hasPrefix("out_time_us="),
               let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                return microseconds / 1_000_000
            }
            if line.hasPrefix("out_time_ms="),
               let microseconds = Double(line.dropFirst("out_time_ms=".count)) {
                return microseconds / 1_000_000
            }
        }
        return nil
    }

    nonisolated private static func friendlyFFmpegMessage(from details: String) -> String {
        if details.localizedCaseInsensitiveContains("can't open stats file") {
            return "FFmpeg could not create its temporary analysis files."
        }
        if details.localizedCaseInsensitiveContains("No space left on device") {
            return "There is not enough free disk space to finish this video."
        }
        if details.localizedCaseInsensitiveContains("Permission denied") {
            return "The app does not have permission to read the source or save beside it."
        }
        if details.localizedCaseInsensitiveContains("Invalid data found") {
            return "FFmpeg could not read this video. The file may be incomplete or damaged."
        }

        let usefulLine = details
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .reversed()
            .first { line in
                let lower = line.lowercased()
                return !line.isEmpty
                    && !lower.contains("conversion failed")
                    && !lower.contains("nothing was written")
                    && (lower.contains("error") || lower.contains("failed") || lower.contains("invalid"))
            }
        return usefulLine.map { "Compression failed: \($0)" } ?? "FFmpeg could not compress this video."
    }

    nonisolated private static func tail(of details: String) -> String {
        details
            .split(whereSeparator: \Character.isNewline)
            .suffix(18)
            .joined(separator: "\n")
    }

    // MARK: - Output and cleanup

    private func buildOutputURL(for inputURL: URL, platform: Platform) -> URL {
        let directory = inputURL.deletingLastPathComponent()
        let name = inputURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(name)\(platform.fileSuffix).mp4")
    }

    private func validate(outputURL: URL, platform: Platform) throws {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CompressionFailure.couldNotCreateOutput
        }
        let size = fileSize(at: outputURL)
        guard size <= platform.maxFileSize else {
            throw CompressionFailure.outputTooLarge(actual: size, limit: platform.maxFileSize)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }

    private func removeFileIfPresent(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanPassLogs(prefix: String) {
        let paths = [
            "\(prefix)-0.log",
            "\(prefix)-0.log.mbtree",
            "\(prefix).log",
            "\(prefix).log.mbtree"
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
