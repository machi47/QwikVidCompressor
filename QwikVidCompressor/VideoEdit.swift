import Foundation

struct VideoSegment: Equatable {
    let start: Double
    let end: Double

    var duration: Double {
        max(0, end - start)
    }
}

struct VideoCut: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double

    init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }
}

struct VideoEdit: Equatable {
    var trimStart: Double
    var trimEnd: Double
    var cuts: [VideoCut]

    /// 0 preserves the original timing whenever possible. 1 allows the app to
    /// shorten difficult videos so that more bits can be spent on every frame.
    var clarityPreference: Double

    init(duration: Double) {
        trimStart = 0
        trimEnd = max(0, duration)
        cuts = []
        clarityPreference = 0
    }

    func segments(for duration: Double) -> [VideoSegment] {
        let safeDuration = max(0, duration)
        let start = min(max(0, trimStart), safeDuration)
        let end = min(max(start, trimEnd), safeDuration)
        guard end - start > 0.01 else { return [] }

        let relevantCuts = cuts
            .map { cut in
                VideoSegment(
                    start: min(max(start, min(cut.start, cut.end)), end),
                    end: min(max(start, max(cut.start, cut.end)), end)
                )
            }
            .filter { $0.duration > 0.01 }
            .sorted { $0.start < $1.start }

        var mergedCuts: [VideoSegment] = []
        for cut in relevantCuts {
            if let last = mergedCuts.last, cut.start <= last.end + 0.01 {
                mergedCuts[mergedCuts.count - 1] = VideoSegment(
                    start: last.start,
                    end: max(last.end, cut.end)
                )
            } else {
                mergedCuts.append(cut)
            }
        }

        var kept: [VideoSegment] = []
        var cursor = start
        for cut in mergedCuts {
            if cut.start - cursor > 0.01 {
                kept.append(VideoSegment(start: cursor, end: cut.start))
            }
            cursor = max(cursor, cut.end)
        }
        if end - cursor > 0.01 {
            kept.append(VideoSegment(start: cursor, end: end))
        }
        return kept
    }

    func editedDuration(for duration: Double) -> Double {
        segments(for: duration).reduce(0) { $0 + $1.duration }
    }

    func hasTimelineEdits(for duration: Double) -> Bool {
        abs(trimStart) > 0.01 || abs(trimEnd - duration) > 0.01 || !cuts.isEmpty
    }

    mutating func setTrimStart(_ time: Double, duration: Double) {
        trimStart = min(max(0, time), max(0, trimEnd - 0.1))
        normalize(duration: duration)
    }

    mutating func setTrimEnd(_ time: Double, duration: Double) {
        trimEnd = max(min(duration, time), min(duration, trimStart + 0.1))
        normalize(duration: duration)
    }

    mutating func addCut(from firstTime: Double, to secondTime: Double, duration: Double) {
        let start = min(firstTime, secondTime)
        let end = max(firstTime, secondTime)
        guard end - start > 0.05 else { return }
        cuts.append(VideoCut(start: start, end: end))
        normalize(duration: duration)
    }

    mutating func removeCut(id: UUID, duration: Double) {
        cuts.removeAll { $0.id == id }
        normalize(duration: duration)
    }

    mutating func resetTimeline(duration: Double) {
        trimStart = 0
        trimEnd = max(0, duration)
        cuts = []
    }

    mutating func normalize(duration: Double) {
        let safeDuration = max(0, duration)
        trimStart = min(max(0, trimStart), safeDuration)
        trimEnd = min(max(trimStart, trimEnd), safeDuration)

        cuts = cuts.compactMap { cut in
            let start = min(max(trimStart, min(cut.start, cut.end)), trimEnd)
            let end = min(max(trimStart, max(cut.start, cut.end)), trimEnd)
            guard end - start > 0.05 else { return nil }
            return VideoCut(id: cut.id, start: start, end: end)
        }
        .sorted { $0.start < $1.start }

        clarityPreference = min(max(0, clarityPreference), 1)
    }
}

extension Double {
    var qwikTimecode: String {
        guard isFinite else { return "0:00" }
        let totalSeconds = max(0, Int(rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
