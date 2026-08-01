import AVFoundation
import AVKit
import SwiftUI

@MainActor
private final class VideoPreviewModel: NSObject, ObservableObject {
    let player: AVPlayer
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackEnd = Double.greatestFiniteMagnitude

    init(url: URL) {
        player = AVPlayer(url: url)
        super.init()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                if self.isPlaying, seconds >= self.playbackEnd {
                    self.pause()
                    self.seek(to: self.playbackEnd)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func togglePlayback(from start: Double, to end: Double) {
        if isPlaying {
            pause()
            return
        }

        playbackEnd = end
        if currentTime < start || currentTime >= end - 0.05 {
            seek(to: start)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: Double) {
        let safeTime = max(0, time)
        currentTime = safeTime
        player.seek(
            to: CMTime(seconds: safeTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

/// Uses AppKit's AVPlayerView directly. This avoids the SwiftUI VideoPlayer
/// compatibility bridge that crashes on some macOS 15 point releases when the
/// app is compiled with a newer SDK.
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct TrimEditorView: View {
    let video: VideoInfo
    @Binding var edit: VideoEdit

    @StateObject private var preview: VideoPreviewModel
    @State private var isSelectingCut = false
    @State private var cutStart: Double = 0
    @State private var cutEnd: Double = 0
    @State private var trimStartDragOrigin: Double?
    @State private var trimEndDragOrigin: Double?
    @State private var cutStartDragOrigin: Double?
    @State private var cutEndDragOrigin: Double?

    init(video: VideoInfo, edit: Binding<VideoEdit>) {
        self.video = video
        _edit = edit
        _preview = StateObject(wrappedValue: VideoPreviewModel(url: video.url))
    }

    var body: some View {
        VStack(spacing: 11) {
            NativeVideoPlayer(player: preview.player)
                .frame(height: 168)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 5) {
                timeline

                HStack {
                    Text(edit.trimStart.qwikTimecode)
                    Spacer()
                    Text("Output \(edit.editedDuration(for: video.duration).qwikTimecode)")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(edit.trimEnd.qwikTimecode)
                }
                .font(.caption)
                .monospacedDigit()
            }

            playerControls

            if isSelectingCut {
                cutSelectionControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack {
                    Button {
                        beginCutSelection()
                    } label: {
                        Label("Cut a Section", systemImage: "scissors")
                    }
                    .help("Select a section in the middle to remove")

                    Spacer()

                    if edit.hasTimelineEdits(for: video.duration) {
                        Button("Reset All") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                edit.resetTimeline(duration: video.duration)
                                preview.seek(to: 0)
                            }
                        }
                    }
                }
                .controlSize(.small)
            }

            if !edit.cuts.isEmpty {
                cutList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("Drag the blue handles to trim the ends. Click the timeline to preview any moment.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            preview.pause()
        }
    }

    private var playerControls: some View {
        HStack(spacing: 8) {
            Button {
                preview.togglePlayback(from: edit.trimStart, to: edit.trimEnd)
            } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help(preview.isPlaying ? "Pause" : "Play selected range")

            Button {
                stepPreview(by: -1)
            } label: {
                Label("1s", systemImage: "gobackward")
            }
            .help("Back one second")

            Text(preview.currentTime.qwikTimecode)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 48)

            Button {
                stepPreview(by: 1)
            } label: {
                Label("1s", systemImage: "goforward")
            }
            .help("Forward one second")

            Spacer()

            Text("Blue is kept • Red is removed")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .controlSize(.small)
    }

    private var cutSelectionControls: some View {
        VStack(spacing: 7) {
            HStack {
                Label("Select the orange range", systemImage: "arrow.left.and.right")
                    .font(.caption)
                Spacer()
                Text("\(cutStart.qwikTimecode)–\(cutEnd.qwikTimecode)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSelectingCut = false
                    }
                }

                Spacer()

                Button("Remove Selected Section") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        edit.addCut(from: cutStart, to: cutEnd, duration: video.duration)
                        isSelectingCut = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cutEnd - cutStart < 0.05)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }

    private var cutList: some View {
        VStack(spacing: 4) {
            ForEach(edit.cuts) { cut in
                HStack {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("Removed \(cut.start.qwikTimecode)–\(cut.end.qwikTimecode)")
                        .monospacedDigit()
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            edit.removeCut(id: cut.id, duration: video.duration)
                        }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Keep this section")
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let duration = max(0.001, video.duration)
            let centerY = geometry.size.height / 2

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 18)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                preview.pause()
                                let fraction = min(max(0, value.location.x / width), 1)
                                preview.seek(to: duration * fraction)
                            }
                    )

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.62))
                    .frame(
                        width: timelineWidth(from: edit.trimStart, to: edit.trimEnd, totalWidth: width),
                        height: 18
                    )
                    .offset(x: timelineX(for: edit.trimStart, totalWidth: width))
                    .allowsHitTesting(false)

                ForEach(edit.cuts) { cut in
                    Rectangle()
                        .fill(Color.red.opacity(0.82))
                        .frame(
                            width: timelineWidth(from: cut.start, to: cut.end, totalWidth: width),
                            height: 18
                        )
                        .offset(x: timelineX(for: cut.start, totalWidth: width))
                        .allowsHitTesting(false)
                }

                if isSelectingCut {
                    Rectangle()
                        .fill(Color.orange.opacity(0.78))
                        .frame(
                            width: timelineWidth(from: cutStart, to: cutEnd, totalWidth: width),
                            height: 18
                        )
                        .offset(x: timelineX(for: cutStart, totalWidth: width))
                        .allowsHitTesting(false)

                    timelineHandle(color: .orange, compact: true)
                        .position(x: handleX(for: cutStart, totalWidth: width), y: centerY)
                        .gesture(cutStartGesture(totalWidth: width))

                    timelineHandle(color: .orange, compact: true)
                        .position(x: handleX(for: cutEnd, totalWidth: width), y: centerY)
                        .gesture(cutEndGesture(totalWidth: width))
                }

                Rectangle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.55), radius: 1)
                    .frame(width: 2, height: 26)
                    .position(
                        x: handleX(for: min(max(0, preview.currentTime), duration), totalWidth: width),
                        y: centerY
                    )
                    .allowsHitTesting(false)

                timelineHandle(color: .accentColor, compact: false)
                    .position(x: handleX(for: edit.trimStart, totalWidth: width), y: centerY)
                    .gesture(trimStartGesture(totalWidth: width))
                    .help("Drag to trim the beginning")

                timelineHandle(color: .accentColor, compact: false)
                    .position(x: handleX(for: edit.trimEnd, totalWidth: width), y: centerY)
                    .gesture(trimEndGesture(totalWidth: width))
                    .help("Drag to trim the end")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Trim timeline")
        }
        .frame(height: 34)
    }

    private func timelineHandle(color: Color, compact: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: compact ? 8 : 11, height: compact ? 24 : 30)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: compact ? 10 : 14)
            }
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .contentShape(Rectangle().inset(by: -6))
    }

    private func trimStartGesture(totalWidth: Double) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if trimStartDragOrigin == nil {
                    trimStartDragOrigin = edit.trimStart
                }
                let origin = trimStartDragOrigin ?? edit.trimStart
                let time = origin + value.translation.width / totalWidth * video.duration
                edit.setTrimStart(time, duration: video.duration)
                constrainCutSelection()
                preview.pause()
                preview.seek(to: edit.trimStart)
            }
            .onEnded { _ in
                trimStartDragOrigin = nil
            }
    }

    private func trimEndGesture(totalWidth: Double) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if trimEndDragOrigin == nil {
                    trimEndDragOrigin = edit.trimEnd
                }
                let origin = trimEndDragOrigin ?? edit.trimEnd
                let time = origin + value.translation.width / totalWidth * video.duration
                edit.setTrimEnd(time, duration: video.duration)
                constrainCutSelection()
                preview.pause()
                preview.seek(to: edit.trimEnd)
            }
            .onEnded { _ in
                trimEndDragOrigin = nil
            }
    }

    private func cutStartGesture(totalWidth: Double) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if cutStartDragOrigin == nil {
                    cutStartDragOrigin = cutStart
                }
                let origin = cutStartDragOrigin ?? cutStart
                cutStart = min(
                    max(edit.trimStart, origin + value.translation.width / totalWidth * video.duration),
                    cutEnd - 0.05
                )
                preview.pause()
                preview.seek(to: cutStart)
            }
            .onEnded { _ in
                cutStartDragOrigin = nil
            }
    }

    private func cutEndGesture(totalWidth: Double) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if cutEndDragOrigin == nil {
                    cutEndDragOrigin = cutEnd
                }
                let origin = cutEndDragOrigin ?? cutEnd
                cutEnd = max(
                    min(edit.trimEnd, origin + value.translation.width / totalWidth * video.duration),
                    cutStart + 0.05
                )
                preview.pause()
                preview.seek(to: cutEnd)
            }
            .onEnded { _ in
                cutEndDragOrigin = nil
            }
    }

    private func beginCutSelection() {
        let availableDuration = max(0.1, edit.trimEnd - edit.trimStart)
        let selectionDuration = min(5, max(0.5, availableDuration * 0.15))
        let preferredCenter = min(max(edit.trimStart, preview.currentTime), edit.trimEnd)
        cutStart = max(edit.trimStart, preferredCenter - selectionDuration / 2)
        cutEnd = min(edit.trimEnd, cutStart + selectionDuration)
        cutStart = max(edit.trimStart, cutEnd - selectionDuration)
        withAnimation(.easeInOut(duration: 0.18)) {
            isSelectingCut = true
        }
    }

    private func constrainCutSelection() {
        guard isSelectingCut else { return }
        cutStart = min(max(edit.trimStart, cutStart), max(edit.trimStart, edit.trimEnd - 0.05))
        cutEnd = max(min(edit.trimEnd, cutEnd), min(edit.trimEnd, cutStart + 0.05))
    }

    private func stepPreview(by seconds: Double) {
        preview.pause()
        let destination = min(max(edit.trimStart, preview.currentTime + seconds), edit.trimEnd)
        preview.seek(to: destination)
    }

    private func timelineX(for time: Double, totalWidth: Double) -> Double {
        totalWidth * min(max(0, time), video.duration) / max(0.001, video.duration)
    }

    private func handleX(for time: Double, totalWidth: Double) -> Double {
        min(max(6, timelineX(for: time, totalWidth: totalWidth)), max(6, totalWidth - 6))
    }

    private func timelineWidth(from start: Double, to end: Double, totalWidth: Double) -> Double {
        max(1, timelineX(for: end, totalWidth: totalWidth) - timelineX(for: start, totalWidth: totalWidth))
    }
}
