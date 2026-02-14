import Foundation

enum Platform: String, CaseIterable {
    case twitter = "Twitter"
    case discord = "Discord"

    var maxFileSize: Int64 {
        switch self {
        case .twitter: return 512 * 1024 * 1024
        case .discord: return 50 * 1024 * 1024
        }
    }

    var maxDuration: Double? {
        switch self {
        case .twitter: return 140
        case .discord: return nil
        }
    }

    var fileSuffix: String {
        switch self {
        case .twitter: return "_twitter"
        case .discord: return "_discord"
        }
    }
}

@MainActor
class VideoCompressor: ObservableObject {
    @Published var progress: Double = 0
    @Published var isCompressing = false
    @Published var error: String?
    @Published var outputURL: URL?
    @Published var outputFileSize: Int64 = 0

    private var process: Process?

    static var ffmpegPath: String? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var ffmpegInstalled: Bool {
        ffmpegPath != nil
    }

    func compress(video: VideoInfo, for platform: Platform) async {
        guard let ffmpeg = Self.ffmpegPath else {
            error = "FFmpeg not found"
            return
        }

        isCompressing = true
        progress = 0
        error = nil
        outputURL = nil

        let outputPath = buildOutputPath(for: video.url, platform: platform)
        let outputURL = URL(fileURLWithPath: outputPath)

        // Remove existing output file
        try? FileManager.default.removeItem(atPath: outputPath)

        do {
            let args = buildFFmpegArgs(
                video: video,
                platform: platform,
                ffmpegPath: ffmpeg,
                outputPath: outputPath
            )

            let needsTwoPass = shouldUseTwoPass(video: video, platform: platform)

            if needsTwoPass {
                // Pass 1
                let pass1Args = buildPass1Args(
                    video: video,
                    platform: platform,
                    ffmpegPath: ffmpeg,
                    outputPath: outputPath
                )
                try await runFFmpeg(path: ffmpeg, args: pass1Args, duration: effectiveDuration(video: video, platform: platform), passNumber: 1)

                // Pass 2
                let pass2Args = buildPass2Args(
                    video: video,
                    platform: platform,
                    ffmpegPath: ffmpeg,
                    outputPath: outputPath
                )
                try await runFFmpeg(path: ffmpeg, args: pass2Args, duration: effectiveDuration(video: video, platform: platform), passNumber: 2)

                // Clean up two-pass log files
                let logFiles = ["ffmpeg2pass-0.log", "ffmpeg2pass-0.log.mbtree"]
                for logFile in logFiles {
                    try? FileManager.default.removeItem(atPath: logFile)
                }
            } else {
                try await runFFmpeg(path: ffmpeg, args: args, duration: effectiveDuration(video: video, platform: platform), passNumber: nil)
            }

            if FileManager.default.fileExists(atPath: outputPath) {
                let attrs = try FileManager.default.attributesOfItem(atPath: outputPath)
                self.outputFileSize = attrs[.size] as? Int64 ?? 0
                self.outputURL = outputURL
            } else {
                self.error = "Output file was not created"
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }

        isCompressing = false
    }

    func cancel() {
        process?.terminate()
        process = nil
        isCompressing = false
        progress = 0
    }

    // MARK: - Private

    private func buildOutputPath(for inputURL: URL, platform: Platform) -> String {
        let dir = inputURL.deletingLastPathComponent().path
        let name = inputURL.deletingPathExtension().lastPathComponent
        return "\(dir)/\(name)\(platform.fileSuffix).mp4"
    }

    private func effectiveDuration(video: VideoInfo, platform: Platform) -> Double {
        if let maxDur = platform.maxDuration, video.duration > maxDur {
            return maxDur
        }
        return video.duration
    }

    private func speedFactor(video: VideoInfo, platform: Platform) -> Double? {
        guard let maxDur = platform.maxDuration, video.duration > maxDur else { return nil }
        return video.duration / maxDur
    }

    private func targetBitrate(video: VideoInfo, platform: Platform) -> Int {
        let duration = effectiveDuration(video: video, platform: platform)
        let targetBytes = Double(platform.maxFileSize) * 0.95
        let targetBits = targetBytes * 8
        let audioBits = 128_000.0 * duration
        let videoBits = targetBits - audioBits
        return max(500_000, Int(videoBits / duration))
    }

    private func targetResolution(video: VideoInfo, platform: Platform) -> (Int, Int)? {
        let bitrate = targetBitrate(video: video, platform: platform)
        let w = Int(video.resolution.width)
        let h = Int(video.resolution.height)

        if bitrate < 1_000_000 && (w > 1280 || h > 720) {
            return (1280, 720)
        }
        if w > 1920 || h > 1080 {
            return (1920, 1080)
        }
        return nil
    }

    private func crf(video: VideoInfo, platform: Platform) -> Int {
        let duration = effectiveDuration(video: video, platform: platform)
        if duration < 30 { return 20 }
        if duration < 120 { return 23 }
        return 26
    }

    private func shouldUseTwoPass(video: VideoInfo, platform: Platform) -> Bool {
        let bitrate = targetBitrate(video: video, platform: platform)
        return bitrate < 4_000_000
    }

    private func buildVideoFilters(video: VideoInfo, platform: Platform) -> [String] {
        var filters: [String] = []

        if let speed = speedFactor(video: video, platform: platform) {
            filters.append("setpts=PTS/\(String(format: "%.4f", speed))")
        }

        if let (w, h) = targetResolution(video: video, platform: platform) {
            filters.append("scale=\(w):\(h):force_original_aspect_ratio=decrease")
            filters.append("pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2")
        }

        return filters
    }

    private func buildAudioFilters(video: VideoInfo, platform: Platform) -> [String] {
        guard let speed = speedFactor(video: video, platform: platform) else { return [] }

        // atempo filter supports 0.5 to 100.0 but for quality, chain at max 2.0x each
        var filters: [String] = []
        var remaining = speed
        while remaining > 1.0 {
            let factor = min(remaining, 2.0)
            filters.append("atempo=\(String(format: "%.4f", factor))")
            remaining /= factor
        }
        return filters
    }

    private func buildFFmpegArgs(video: VideoInfo, platform: Platform, ffmpegPath: String, outputPath: String) -> [String] {
        var args = ["-y", "-i", video.url.path]

        let videoFilters = buildVideoFilters(video: video, platform: platform)
        let audioFilters = buildAudioFilters(video: video, platform: platform)
        let br = targetBitrate(video: video, platform: platform)
        let crfVal = crf(video: video, platform: platform)

        args += ["-c:v", "libx264"]
        args += ["-profile:v", "main"]
        args += ["-pix_fmt", "yuv420p"]
        args += ["-crf", "\(crfVal)"]
        args += ["-maxrate", "\(br)"]
        args += ["-bufsize", "\(br * 2)"]

        if !videoFilters.isEmpty {
            args += ["-vf", videoFilters.joined(separator: ",")]
        }

        if !audioFilters.isEmpty {
            args += ["-af", audioFilters.joined(separator: ",")]
        }

        args += ["-c:a", "aac", "-b:a", "128k"]
        args += ["-movflags", "+faststart"]
        args += [outputPath]

        return args
    }

    private func buildPass1Args(video: VideoInfo, platform: Platform, ffmpegPath: String, outputPath: String) -> [String] {
        var args = ["-y", "-i", video.url.path]

        let videoFilters = buildVideoFilters(video: video, platform: platform)
        let br = targetBitrate(video: video, platform: platform)

        args += ["-c:v", "libx264"]
        args += ["-profile:v", "main"]
        args += ["-pix_fmt", "yuv420p"]
        args += ["-b:v", "\(br)"]
        args += ["-maxrate", "\(br)"]
        args += ["-bufsize", "\(br * 2)"]

        if !videoFilters.isEmpty {
            args += ["-vf", videoFilters.joined(separator: ",")]
        }

        args += ["-pass", "1"]
        args += ["-an"]
        args += ["-f", "null", "/dev/null"]

        return args
    }

    private func buildPass2Args(video: VideoInfo, platform: Platform, ffmpegPath: String, outputPath: String) -> [String] {
        var args = ["-y", "-i", video.url.path]

        let videoFilters = buildVideoFilters(video: video, platform: platform)
        let audioFilters = buildAudioFilters(video: video, platform: platform)
        let br = targetBitrate(video: video, platform: platform)

        args += ["-c:v", "libx264"]
        args += ["-profile:v", "main"]
        args += ["-pix_fmt", "yuv420p"]
        args += ["-b:v", "\(br)"]
        args += ["-maxrate", "\(br)"]
        args += ["-bufsize", "\(br * 2)"]

        if !videoFilters.isEmpty {
            args += ["-vf", videoFilters.joined(separator: ",")]
        }

        args += ["-pass", "2"]

        if !audioFilters.isEmpty {
            args += ["-af", audioFilters.joined(separator: ",")]
        }

        args += ["-c:a", "aac", "-b:a", "128k"]
        args += ["-movflags", "+faststart"]
        args += [outputPath]

        return args
    }

    private func runFFmpeg(path: String, args: [String], duration: Double, passNumber: Int?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardError = pipe

            nonisolated(unsafe) var continued = false
            let resume: @Sendable (Result<Void, Error>) -> Void = { result in
                guard !continued else { return }
                continued = true
                continuation.resume(with: result)
            }

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                if let timeMatch = output.range(of: #"time=(\d+):(\d+):(\d+\.\d+)"#, options: .regularExpression) {
                    let timeStr = String(output[timeMatch])
                    let components = timeStr.replacingOccurrences(of: "time=", with: "").split(separator: ":")
                    if components.count == 3,
                       let h = Double(components[0]),
                       let m = Double(components[1]),
                       let s = Double(components[2]) {
                        let currentTime = h * 3600 + m * 60 + s
                        let rawProgress = min(currentTime / max(duration, 1), 1.0)

                        let adjustedProgress: Double
                        if let pass = passNumber {
                            adjustedProgress = pass == 1 ? rawProgress * 0.5 : 0.5 + rawProgress * 0.5
                        } else {
                            adjustedProgress = rawProgress
                        }

                        DispatchQueue.main.async {
                            self?.progress = adjustedProgress
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    resume(.success(()))
                } else {
                    resume(.failure(NSError(
                        domain: "VideoCompressor",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "FFmpeg exited with code \(proc.terminationStatus)"]
                    )))
                }
            }

            self.process = process

            do {
                try process.run()
            } catch {
                resume(.failure(error))
            }
        }
    }
}
