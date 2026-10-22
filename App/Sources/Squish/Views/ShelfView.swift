import SwiftUI

/// The floating drop shelf summoned by shaking the pointer during a file drag.
struct ShelfView: View {
    @Environment(OptimizerStore.self) private var store
    @Environment(Preferences.self) private var prefs

    private var shelf: ShelfController { .shared }

    var body: some View {
        let jobs = shelf.batch.map(store.jobs(in:)) ?? []
        let finished = !jobs.isEmpty && jobs.allSatisfy(\.state.isFinished)

        card(jobs: jobs, finished: finished)
            .contentShape(.rect(cornerRadius: 26))
            .gesture(WindowDragGesture()) // drag the shelf by any empty spot
            .padding(ShelfController.inset) // room for the glass edge inside the borderless panel
            .scaleEffect(shelf.isPresented ? 1 : 0.85)
            .opacity(shelf.isPresented ? 1 : 0)
            .frame(width: ShelfController.size.width, height: ShelfController.size.height)
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { shelf.isTargeted }, set: { t in
                withAnimation(.smooth(duration: 0.2)) { shelf.isTargeted = t }
                if t { Haptics.tap() }
            })) { providers in
                FileDrop.load(providers) { shelf.receive($0) }
                return true
            }
            .onHover { shelf.isHovering = $0 }
            .onChange(of: finished) { _, done in if done { shelf.batchFinished() } }
    }

    private func card(jobs: [ImageJob], finished: Bool) -> some View {
        ZStack {
            Group {
                if jobs.isEmpty {
                    target
                } else {
                    progress(jobs: jobs, finished: finished)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if shelf.isHovering {
                controls(jobs: jobs, finished: finished)
                    .transition(.opacity)
            }
        }
        .glassEffect(.regular.tint(shelf.isTargeted ? Color.accentColor.opacity(0.18) : .clear), in: .rect(cornerRadius: 26))
        .overlay {
            if shelf.isTargeted {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        // No `.shadow` here: on glass it renders as a rectangle clipped by the panel. Glass casts its own.
        .animation(.smooth(duration: 0.2), value: shelf.isHovering)
    }

    private var target: some View {
        VStack(spacing: 8) {
            Image(systemName: shelf.isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(shelf.isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 44)
            Text("Drop to Optimize")
                .font(.headline)
            Text(prefs.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progress(jobs: [ImageJob], finished: Bool) -> some View {
        let saved = jobs.reduce(0) { $0 + $1.savedBytes }
        let original = jobs.filter { $0.state == .optimized }.reduce(0) { $0 + $1.originalSize }
        let done = jobs.count(where: \.state.isFinished)
        let fraction = jobs.reduce(0) { $0 + $1.completion } / Double(jobs.count)
        return VStack(spacing: 10) {
            ThumbnailStack(jobs: Array(jobs.prefix(3)))
                .frame(width: 84, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .background(Circle().fill(.background).padding(2))
                            .offset(x: 6, y: 6)
                            .transition(.symbolEffect(.drawOn))
                    }
                }
                .overlay { FileDragSource(urls: jobs.compactMap { $0.state == .optimized ? $0.outputURL : nil }) }
                .help(finished ? "Drag the optimized files anywhere" : "")

            VStack(spacing: 2) {
                if finished {
                    Text(saved > 0 ? "Saved \(Fmt.bytes(saved))" : "Already Optimal")
                        .font(.headline)
                    Text(saved > 0 ? String(localized: "\(Fmt.percent(Double(saved) / Double(max(original, 1)))) smaller · drag to use") : Fmt.items(jobs.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Optimizing \(min(done + 1, jobs.count)) of \(jobs.count) · \(Fmt.percent(fraction))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 110)
                }
            }
        }
        .animation(.smooth, value: finished)
    }

    private func controls(jobs: [ImageJob], finished: Bool) -> some View {
        VStack {
            HStack {
                shelfButton("Close", "xmark") { shelf.hide() }
                Spacer()
                if finished, jobs.contains(where: { $0.state == .optimized }) {
                    shelfButton("Show in Finder", "folder") { store.reveal(jobs.filter { $0.state == .optimized }) }
                }
                if !jobs.isEmpty {
                    shelfButton("Open Squish", "macwindow") { shelf.openMainWindow() }
                }
            }
            Spacer()
        }
        .padding(8)
    }

    private func shelfButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .frame(width: 22, height: 22)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(title)
    }
}

/// A loosely fanned stack of thumbnails.
private struct ThumbnailStack: View {
    var jobs: [ImageJob]

    var body: some View {
        ZStack {
            ForEach(Array(jobs.enumerated().reversed()), id: \.element.id) { index, job in
                JobThumbnail(job: job, size: 58)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                    .rotationEffect(.degrees(Double(index) * 6 - 3))
                    .offset(x: CGFloat(index) * 6, y: CGFloat(index) * -2)
            }
        }
    }
}
