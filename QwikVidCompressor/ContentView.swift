import SwiftUI

struct ContentView: View {
    @StateObject private var compressor = VideoCompressor()
    @State private var videoInfo: VideoInfo?
    @State private var platform: Platform = .twitter
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            if !VideoCompressor.ffmpegInstalled {
                ffmpegMissingView
            } else if let video = videoInfo {
                videoDetailView(video)
            } else {
                dropZone
            }
        }
        .frame(width: 420, height: 460)
        .background(.background)
        .onPasteCommand(of: [.fileURL]) { providers in
            handlePaste(providers)
        }
    }

    // MARK: - FFmpeg Missing

    private var ffmpegMissingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text("FFmpeg Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Install via Homebrew:")
                .foregroundColor(.secondary)

            Text("brew install ffmpeg")
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        DropZoneView { url in
            loadVideo(url: url)
        }
        .padding(20)
        .overlay {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Video Detail

    private func videoDetailView(_ video: VideoInfo) -> some View {
        VStack(spacing: 16) {
            // Header with back button
            HStack {
                Button(action: resetState) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Thumbnail + info
            HStack(spacing: 16) {
                if let thumb = video.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 90)
                        .cornerRadius(8)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 160, height: 90)
                        .overlay(
                            Image(systemName: "film")
                                .font(.title)
                                .foregroundColor(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.fileName)
                        .font(.headline)
                        .lineLimit(2)

                    Label(video.durationFormatted, systemImage: "clock")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Label(video.resolutionFormatted, systemImage: "rectangle.on.rectangle")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Label(video.fileSizeFormatted, systemImage: "doc")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 20)

            // Platform picker
            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .disabled(compressor.isCompressing)

            // Platform info
            platformInfoView
                .padding(.horizontal, 20)

            Spacer()

            // Progress / Compress button / Done state
            if compressor.isCompressing {
                progressView
                    .padding(.horizontal, 20)
            } else if let outputURL = compressor.outputURL {
                doneView(video: video, outputURL: outputURL)
                    .padding(.horizontal, 20)
            } else {
                compressButton(video: video)
                    .padding(.horizontal, 20)
            }

            if let err = compressor.error {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
            }

            Spacer().frame(height: 20)
        }
    }

    private var platformInfoView: some View {
        HStack {
            if platform == .twitter {
                Label("Max 512 MB, 2m20s", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Label("Max 50 MB", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var progressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: compressor.progress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(Int(compressor.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Spacer()

                Button("Cancel") {
                    compressor.cancel()
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.caption)
            }
        }
    }

    private func doneView(video: VideoInfo, outputURL: URL) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)

                Text("Compressed!")
                    .font(.headline)
            }

            HStack(spacing: 16) {
                VStack {
                    Text("New size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: compressor.outputFileSize, countStyle: .file))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                VStack {
                    Text("Ratio")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    let ratio = video.fileSize > 0 ? Double(compressor.outputFileSize) / Double(video.fileSize) * 100 : 0
                    Text("\(Int(ratio))%")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }

                Button("Compress Another") {
                    resetState()
                }
            }
            .padding(.top, 4)
        }
    }

    private func compressButton(video: VideoInfo) -> some View {
        Button(action: {
            Task {
                await compressor.compress(video: video, for: platform)
            }
        }) {
            Label("Compress for \(platform.rawValue)", systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Actions

    private func loadVideo(url: URL) {
        isLoading = true
        Task {
            do {
                let info = try await VideoInfo.load(from: url)
                videoInfo = info
            } catch {
                compressor.error = "Failed to load video: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func resetState() {
        videoInfo = nil
        compressor.progress = 0
        compressor.error = nil
        compressor.outputURL = nil
        compressor.outputFileSize = 0
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            let videoTypes = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
            guard videoTypes.contains(url.pathExtension.lowercased()) else { return }

            DispatchQueue.main.async {
                loadVideo(url: url)
            }
        }
    }
}
