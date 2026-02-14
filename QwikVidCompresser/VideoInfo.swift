import AVFoundation
import AppKit

struct VideoInfo {
    let url: URL
    let duration: Double
    let resolution: CGSize
    let fileSize: Int64
    let thumbnail: NSImage?

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var resolutionFormatted: String {
        "\(Int(resolution.width))x\(Int(resolution.height))"
    }

    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var fileName: String {
        url.lastPathComponent
    }

    static func load(from url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)

        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var resolution = CGSize(width: 1920, height: 1080)
        if let track = tracks.first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformedSize = size.applying(transform)
            resolution = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        var thumbnail: NSImage?
        let time = CMTime(seconds: min(1.0, duration * 0.1), preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return VideoInfo(
            url: url,
            duration: duration,
            resolution: resolution,
            fileSize: fileSize,
            thumbnail: thumbnail
        )
    }
}
