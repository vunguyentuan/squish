import SwiftUI

/// Before/after slider. Drag anywhere to move the divider.
struct CompareView: View {
    let job: ImageJob

    @Environment(\.dismiss) private var dismiss
    @State private var before: NSImage?
    @State private var after: NSImage?
    @State private var split: CGFloat = 0.5
    @State private var zoomed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack {
                    Checkerboard().opacity(0.5)
                    if let before, let after {
                        imageLayer(after, in: geo.size)
                        imageLayer(before, in: geo.size)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * split)
                            }
                        divider(height: geo.size.height)
                            .position(x: geo.size.width * split, y: geo.size.height / 2)
                        labels
                    } else {
                        ProgressView()
                    }
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        split = min(1, max(0, value.location.x / geo.size.width))
                    }
                )
                .clipped()
            }
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 620)
        .task(load)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.headline)
                Text("\(Fmt.bytes(job.originalSize)) → \(Fmt.bytes(job.optimizedSize ?? 0)) · \(Fmt.percent(job.savedFraction)) smaller")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $zoomed) { Label("Actual Size", systemImage: "plus.magnifyingglass") }
                .toggleStyle(.button)
                .help("Toggle 1:1 pixels")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func imageLayer(_ image: NSImage, in size: CGSize) -> some View {
        if zoomed {
            Image(nsImage: image)
                .interpolation(.none)
                .frame(width: size.width, height: size.height)
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2, height: height).shadow(radius: 3)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private var labels: some View {
        VStack {
            HStack {
                tag("Before", Fmt.bytes(job.originalSize))
                Spacer()
                tag("After", Fmt.bytes(job.optimizedSize ?? 0))
            }
            Spacer()
        }
        .padding(14)
        .allowsHitTesting(false)
    }

    private func tag(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.semibold)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func load() async {
        guard let beforeURL = job.beforeURL, let afterURL = job.outputURL else { return }
        before = NSImage(contentsOf: beforeURL)
        after = NSImage(contentsOf: afterURL)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { gc, size in
            let cell: CGFloat = 12
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col).isMultiple(of: 2) {
                    gc.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
