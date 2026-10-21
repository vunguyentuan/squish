import SwiftUI

/// Empty state: a quiet drop well, in the spirit of Apple's own "drop here" areas.
struct DropZoneView: View {
    var isTargeted: Bool
    var choose: () -> Void

    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: isTargeted ? [] : [7, 5])
                    )

                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .symbolEffect(.bounce.up, value: isTargeted)
                        .padding(.bottom, 4)
                    Text("Drop Images or Videos")
                        .font(.title3.weight(.semibold))
                    Text("PNG, JPEG, WebP, SVG, HEIC, AVIF, GIF, MOV and MP4")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose Files…", action: choose)
                        .controlSize(.large)
                        .padding(.top, 8)
                }
                .padding(24)
            }
            .padding([.horizontal, .top], 20)

            Group {
                if prefs.shakeToShelf {
                    Label("Shake the pointer while dragging files to open the drop shelf.", systemImage: "cursorarrow.motionlines")
                } else {
                    Label("Using \(prefs.summary) · \(prefs.saveMode.title)", systemImage: "slider.horizontal.3")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
        }
        .animation(.smooth(duration: 0.2), value: isTargeted)
    }
}
