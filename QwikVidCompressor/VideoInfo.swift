import AVFoundation
import AppKit

struct VideoInfo {
    let url: URL
    let duration: Double
    let resolution: CGSize
    let fileSize: Int64
    let thumbnail: NSImage?
    let hasAudio: Bool
    let videoCodec: String
    let frameRate: Double
    let estimatedVideoBitrate: Double

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
        guard let videoTrack = tracks.first else {
            throw VideoInfoError.noVideoTrack
        }

        var resolution = CGSize(width: 1920, height: 1080)
        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = size.applying(transform)
        resolution = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let estimatedVideoBitrate = try await videoTrack.load(.estimatedDataRate)
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let codec = formatDescriptions.first.map {
            Self.codecName(for: CMFormatDescriptionGetMediaSubType($0))
        } ?? "unknown"

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
            thumbnail: thumbnail,
            hasAudio: !audioTracks.isEmpty,
            videoCodec: codec,
            frameRate: frameRate > 0 ? frameRate : 30,
            estimatedVideoBitrate: Double(estimatedVideoBitrate)
        )
    }

    private static func codecName(for code: FourCharCode) -> String {
        switch code {
        case 0x61766331: return "h264" // avc1
        case 0x61766333: return "h264" // avc3
        case 0x68766331: return "hevc" // hvc1
        case 0x68657631: return "hevc" // hev1
        case 0x61763031: return "av1"  // av01
        default:
            let characters: [Character] = [
                Character(UnicodeScalar((code >> 24) & 0xff) ?? "?"),
                Character(UnicodeScalar((code >> 16) & 0xff) ?? "?"),
                Character(UnicodeScalar((code >> 8) & 0xff) ?? "?"),
                Character(UnicodeScalar(code & 0xff) ?? "?")
            ]
            return String(characters)
        }
    }
}

enum VideoInfoError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The selected file does not contain a video track."
        }
    }
}
