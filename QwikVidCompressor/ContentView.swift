import SwiftUI

struct ContentView: View {
    @StateObject private var compressor = VideoCompressor()
    @State private var videoInfo: VideoInfo?
    @State private var edit = VideoEdit(duration: 0)
    @State private var platform: Platform = .twitter
    @State private var isLoading = false
    @State private var optionsExpanded = false
    @State private var trimEditorExpanded = false

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
        .frame(width: 460, height: windowHeight)
        .background(.background)
        .animation(.easeInOut(duration: 0.22), value: windowHeight)
        .onPasteCommand(of: [.fileURL]) { providers in
            handlePaste(providers)
        }
    }

    private var windowHeight: CGFloat {
        guard videoInfo != nil else { return 500 }
        if trimEditorExpanded { return 820 }
        if optionsExpanded { return 620 }
        return 500
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
        VStack(spacing: 14) {
            HStack {
                Button(action: resetState) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(compressor.isCompressing)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if trimEditorExpanded {
                compactVideoHeader(video)
            } else {
                fullVideoHeader(video)
            }

            Divider()
                .padding(.horizontal, 20)

            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases, id: \.self) { selectedPlatform in
                    Text(selectedPlatform.rawValue).tag(selectedPlatform)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .disabled(compressor.isCompressing)
            .onChange(of: platform) { _ in
                compressor.reset()
            }

            platformInfoView
                .padding(.horizontal, 20)

            optionsView(video)
                .padding(.horizontal, 20)

            Spacer(minLength: 4)

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

            errorView
                .padding(.horizontal, 20)

            Spacer().frame(height: 16)
        }
    }

    private func fullVideoHeader(_ video: VideoInfo) -> some View {
        HStack(spacing: 16) {
            videoThumbnail(video, width: 160, height: 90)

            VStack(alignment: .leading, spacing: 6) {
                Text(video.fileName)
                    .font(.headline)
                    .lineLimit(2)

                Label(video.durationFormatted, systemImage: "clock")
                Label(video.resolutionFormatted, systemImage: "rectangle.on.rectangle")
                Label(video.fileSizeFormatted, systemImage: "doc")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func compactVideoHeader(_ video: VideoInfo) -> some View {
        HStack(spacing: 10) {
            videoThumbnail(video, width: 80, height: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(video.durationFormatted) • \(video.fileSizeFormatted)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func videoThumbnail(_ video: VideoInfo, width: CGFloat, height: CGFloat) -> some View {
        if let thumbnail = video.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: width, height: height)
                .overlay {
                    Image(systemName: "film")
                        .foregroundColor(.secondary)
                }
        }
    }

    private var platformInfoView: some View {
        HStack {
            Label(platform.limitDescription, systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func optionsView(_ video: VideoInfo) -> some View {
        DisclosureGroup(isExpanded: $optionsExpanded) {
            VStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        trimEditorExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Label(
                            edit.hasTimelineEdits(for: video.duration) ? "Edit Trims & Cuts" : "Trim Before Compressing",
                            systemImage: "scissors"
                        )
                        Spacer()
                        Image(systemName: trimEditorExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(compressor.isCompressing)

                if trimEditorExpanded {
                    TrimEditorView(video: video, edit: $edit)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()

                VStack(spacing: 5) {
                    HStack {
                        Text("When heavy compression is needed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(balanceName)
                            .font(.caption.weight(.medium))
                    }

                    Slider(value: $edit.clarityPreference, in: 0...1, step: 0.25)
                        .disabled(compressor.isCompressing)

                    HStack {
                        Text("Keep timing")
                        Spacer()
                        Text("Sharper frames")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .help("Sharper frames may shorten very large videos; Keep timing preserves playback speed and lowers resolution or detail instead.")
            }
            .padding(.top, 10)
        } label: {
            Label(optionsSummary(video), systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
        }
        .disabled(compressor.isCompressing)
        .onChange(of: optionsExpanded) { expanded in
            if !expanded {
                withAnimation(.easeInOut(duration: 0.2)) {
                    trimEditorExpanded = false
                }
            }
        }
        .onChange(of: edit) { _ in
            compressor.reset()
        }
    }

    private var balanceName: String {
        switch edit.clarityPreference {
        case ..<0.125: return "Original timing"
        case ..<0.375: return "Mostly timing"
        case ..<0.625: return "Balanced"
        case ..<0.875: return "Mostly clarity"
        default: return "Maximum clarity"
        }
    }

    private func optionsSummary(_ video: VideoInfo) -> String {
        let editCount = edit.cuts.count
        let hasTrim = edit.hasTimelineEdits(for: video.duration)
        if hasTrim {
            return editCount == 1 ? "Options • 1 cut" : "Options • \(editCount) cuts"
        }
        return "Options"
    }

    private var progressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: compressor.progress)
                .progressViewStyle(.linear)

            HStack {
                Text(compressor.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(compressor.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

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

                Text("Ready to post")
                    .font(.headline)
            }

            HStack(spacing: 20) {
                VStack {
                    Text("New size")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: compressor.outputFileSize, countStyle: .file))
                        .font(.subheadline.weight(.medium))
                }

                VStack {
                    Text("Of original")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    let ratio = video.fileSize > 0
                        ? Double(compressor.outputFileSize) / Double(video.fileSize) * 100
                        : 0
                    Text("\(Int(ratio))%")
                        .font(.subheadline.weight(.medium))
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
        Button {
            Task {
                await compressor.compress(video: video, edit: edit, for: platform)
            }
        } label: {
            Label("Compress for \(platform.rawValue)", systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var errorView: some View {
        if let error = compressor.error {
            VStack(alignment: .leading, spacing: 5) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)

                if let details = compressor.errorDetails {
                    DisclosureGroup("Technical details") {
                        Text(details)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func loadVideo(url: URL) {
        isLoading = true
        compressor.reset()
        Task {
            do {
                let info = try await VideoInfo.load(from: url)
                videoInfo = info
                edit = VideoEdit(duration: info.duration)
                optionsExpanded = false
                trimEditorExpanded = false
            } catch {
                compressor.error = "Failed to load video: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func resetState() {
        videoInfo = nil
        edit = VideoEdit(duration: 0)
        optionsExpanded = false
        trimEditorExpanded = false
        compressor.reset()
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
