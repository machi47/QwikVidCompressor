import SwiftUI

struct ContentView: View {
    @StateObject private var compressor = VideoCompressor()
    @State private var videoInfo: VideoInfo?
    @State private var edit = VideoEdit(duration: 0)
    @State private var platform: Platform = .twitter
    @State private var isLoading = false
    @State private var optionsExpanded = false
    @State private var trimEditorExpanded = false
    @State private var technicalDetailsExpanded = false

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
        if trimEditorExpanded {
            // The completed-result controls add one more row below the editor.
            // Give that state just enough room without enlarging normal editing.
            return compressor.outputURL == nil ? 820 : 844
        }
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

            optionsView(video)
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 20)

            platformSelectionView(video)
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

    private func platformSelectionView(_ video: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases, id: \.self) { selectedPlatform in
                    Text(selectedPlatform.rawValue).tag(selectedPlatform)
                }
            }
            .pickerStyle(.segmented)
            .disabled(compressor.isCompressing)
            .onChange(of: platform) { _ in
                // Platform changes intentionally preserve every edit and
                // preference; only a result made for the old target is cleared.
                technicalDetailsExpanded = false
                compressor.reset()
            }

            HStack {
                Label(platform.limitDescription, systemImage: "info.circle")
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)

            let requirement = VideoCompressor.requirement(video: video, edit: edit, platform: platform)
            Label(requirement.message, systemImage: requirement.systemImage)
                .font(.caption.weight(.medium))
                .foregroundColor(requirement == .compression ? .orange : .green)
        }
    }

    private func optionsView(_ video: VideoInfo) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    optionsExpanded.toggle()
                    if !optionsExpanded {
                        trimEditorExpanded = false
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text(optionsSummary(video))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: optionsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(compressor.isCompressing)
            .accessibilityLabel(optionsExpanded ? "Hide More Options" : "Show More Options")

            if optionsExpanded {
                VStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            trimEditorExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "scissors")
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Trim & Cuts")
                                Text(editSummary(video))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: trimEditorExpanded ? "chevron.up" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(compressor.isCompressing)
                    .accessibilityLabel(trimEditorExpanded ? "Hide Trim and Cuts" : "Edit Trim and Cuts")
                    .accessibilityHint("Opens the video timeline editor")

                    if trimEditorExpanded {
                        TrimEditorView(video: video, edit: $edit)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Divider()

                    VStack(spacing: 5) {
                        HStack {
                            Text("Compression tradeoff")
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
                    .help("This is only used when the edited video still needs compression. Sharper frames may shorten it; Keep timing lowers detail instead.")
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .disabled(compressor.isCompressing)
        .onChange(of: edit) { _ in
            compressor.reset()
        }
    }

    private func editSummary(_ video: VideoInfo) -> String {
        guard edit.hasTimelineEdits(for: video.duration) else {
            return "Use the whole video"
        }
        let cutText = edit.cuts.isEmpty
            ? ""
            : edit.cuts.count == 1 ? " • 1 cut" : " • \(edit.cuts.count) cuts"
        return "Output \(edit.editedDuration(for: video.duration).qwikTimecode)\(cutText)"
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
            return editCount == 1 ? "More Options • 1 cut" : "More Options • \(editCount) cuts"
        }
        return "More Options"
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
            technicalDetailsExpanded = false
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            technicalDetailsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Label("Technical Details", systemImage: "terminal")
                            Spacer()
                            Image(systemName: technicalDetailsExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if technicalDetailsExpanded {
                        ScrollView {
                            Text(details)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .frame(maxHeight: 140)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
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
                technicalDetailsExpanded = false
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
        technicalDetailsExpanded = false
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
