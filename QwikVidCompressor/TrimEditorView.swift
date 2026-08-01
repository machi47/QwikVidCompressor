import AVFoundation
import AVKit
import SwiftUI

@MainActor
private final class VideoPreviewModel: ObservableObject {
    let player: AVPlayer
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    private var timeObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            Task { @MainActor [weak self] in
                self?.currentTime = seconds
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func togglePlayback(endingAt end: Double) {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= end - 0.05 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
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

    @objc private func playerDidFinish() {
        isPlaying = false
    }
}

struct TrimEditorView: View {
    let video: VideoInfo
    @Binding var edit: VideoEdit

    @StateObject private var preview: VideoPreviewModel
    @State private var pendingCutStart: Double?

    init(video: VideoInfo, edit: Binding<VideoEdit>) {
        self.video = video
        _edit = edit
        _preview = StateObject(wrappedValue: VideoPreviewModel(url: video.url))
    }

    var body: some View {
        VStack(spacing: 10) {
            VideoPlayer(player: preview.player)
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            timeline

            HStack {
                Text(preview.currentTime.qwikTimecode)
                    .monospacedDigit()
                Spacer()
                Text("Keeps \(edit.editedDuration(for: video.duration).qwikTimecode)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)

            HStack(spacing: 8) {
                Button {
                    preview.togglePlayback(endingAt: video.duration)
                } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help(preview.isPlaying ? "Pause" : "Play")

                Button {
                    preview.seek(to: max(0, preview.currentTime - 1))
                } label: {
                    Label("1s", systemImage: "gobackward")
                }
                .help("Back one second")

                Button {
                    preview.seek(to: min(video.duration, preview.currentTime + 1))
                } label: {
                    Label("1s", systemImage: "goforward")
                }
                .help("Forward one second")

                Spacer()

                Button("Set Start") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        edit.setTrimStart(preview.currentTime, duration: video.duration)
                    }
                }
                .help("Remove everything before the playhead")

                Button("Set End") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        edit.setTrimEnd(preview.currentTime, duration: video.duration)
                    }
                }
                .help("Remove everything after the playhead")
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                if let cutStart = pendingCutStart {
                    Text("Cut starts at \(cutStart.qwikTimecode)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Cancel") {
                        pendingCutStart = nil
                    }

                    Button("Cut to Here") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            edit.addCut(from: cutStart, to: preview.currentTime, duration: video.duration)
                            pendingCutStart = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(abs(preview.currentTime - cutStart) < 0.05)
                } else {
                    Button {
                        pendingCutStart = preview.currentTime
                    } label: {
                        Label("Mark Middle Cut", systemImage: "scissors")
                    }
                    .help("Mark one edge, move the playhead, then cut to the other edge")

                    Spacer()

                    if edit.hasTimelineEdits(for: video.duration) {
                        Button("Reset Trims") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                edit.resetTimeline(duration: video.duration)
                                pendingCutStart = nil
                            }
                        }
                    }
                }
            }
            .controlSize(.small)

            if !edit.cuts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(edit.cuts) { cut in
                        HStack {
                            Image(systemName: "scissors")
                                .foregroundColor(.red)
                            Text("Remove \(cut.start.qwikTimecode)–\(cut.end.qwikTimecode)")
                                .monospacedDigit()
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    edit.removeCut(id: cut.id, duration: video.duration)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Keep this section")
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onDisappear {
            preview.pause()
        }
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let duration = max(0.001, video.duration)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: width * max(0, edit.trimEnd - edit.trimStart) / duration)
                    .offset(x: width * edit.trimStart / duration)

                ForEach(edit.cuts) { cut in
                    Rectangle()
                        .fill(Color.red.opacity(0.72))
                        .frame(width: width * max(0, cut.end - cut.start) / duration)
                        .offset(x: width * cut.start / duration)
                }

                if let pendingCutStart {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2)
                        .offset(x: width * pendingCutStart / duration)
                }

                Rectangle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.45), radius: 1)
                    .frame(width: 2)
                    .offset(x: width * min(max(0, preview.currentTime), duration) / duration)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        preview.pause()
                        let fraction = min(max(0, value.location.x / width), 1)
                        preview.seek(to: duration * fraction)
                    }
            )
            .accessibilityLabel("Video timeline")
            .accessibilityValue(preview.currentTime.qwikTimecode)
        }
        .frame(height: 24)
    }
}
