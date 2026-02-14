import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onDrop: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Drop video here")
                .font(.title2)
                .fontWeight(.medium)

            Text("or press \u{2318}V to paste, or click to browse")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.4))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            browseForVideo()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func browseForVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.movie, UTType.video, UTType.mpeg4Movie,
            UTType.quickTimeMovie, UTType.avi
        ]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            onDrop(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            let videoTypes = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
            guard videoTypes.contains(url.pathExtension.lowercased()) else { return }

            DispatchQueue.main.async {
                onDrop(url)
            }
        }
    }
}
