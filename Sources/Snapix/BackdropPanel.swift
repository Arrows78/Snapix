import AppKit
import SwiftUI

@MainActor
final class BackdropModel: ObservableObject {
    private let doc: Document
    private let refresh: () -> Void

    @Published var cfg: BackdropConfig {
        didSet {
            guard cfg != oldValue else { return }
            doc.state.backdrop = cfg
            cfg.save()
            refresh()
        }
    }

    init(doc: Document, refresh: @escaping () -> Void) {
        self.doc = doc
        self.refresh = refresh
        cfg = doc.state.backdrop
        hasImage = doc.state.backdropImage != nil
    }

    @Published var hasImage = false

    func reverse() { (cfg.fromHex, cfg.toHex) = (cfg.toHex, cfg.fromHex) }

    func loadImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        doc.state.backdropImage = cg
        hasImage = true
        cfg.enabled = true
        refresh()
    }

    func removeImage() {
        doc.state.backdropImage = nil
        hasImage = false
        refresh()
    }

    func randomize() {
        let p = BackdropConfig.presets.randomElement()!
        cfg.fromHex = p.0
        cfg.toHex = p.1
        cfg.angle = CGFloat(Int.random(in: 0..<360))
        cfg.gradient = true
    }
}

struct BackdropPanel: View {
    @ObservedObject var model: BackdropModel

    private func colorBinding(_ keyPath: WritableKeyPath<BackdropConfig, UInt32>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.cfg[keyPath: keyPath])) },
                set: { model.cfg[keyPath: keyPath] = NSColor($0).hexValue })
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<CGFloat>, _ range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Backdrop (K)", isOn: $model.cfg.enabled).toggleStyle(.switch).font(.headline)
            Group {
                slider("Padding", $model.cfg.padding, 8...240)
                slider("Inner radius", $model.cfg.innerRadius, 0...60)
                slider("Outer radius", $model.cfg.outerRadius, 0...80)
                Toggle("Shadow", isOn: $model.cfg.shadow)
                HStack {
                    Toggle("Gradient", isOn: $model.cfg.gradient)
                    if model.cfg.gradient {
                        Toggle("Radial", isOn: $model.cfg.radial)
                        Button("Reverse", action: model.reverse).controlSize(.small)
                    }
                }
                HStack {
                    ColorPicker(LocalizedStringKey(model.cfg.gradient ? "From" : "Color"), selection: colorBinding(\.fromHex))
                    if model.cfg.gradient { ColorPicker("To", selection: colorBinding(\.toHex)) }
                }
                if model.cfg.gradient { slider("Angle", $model.cfg.angle, 0...360) }
                Picker("Ratio", selection: Binding(get: { model.cfg.ratio ?? 0 }, set: { model.cfg.ratio = $0 > 0 ? $0 : nil })) {
                    ForEach(Array(BackdropConfig.ratios.enumerated()), id: \.offset) { _, r in Text(LocalizedStringKey(r.name)).tag(r.value ?? 0) }
                }
            }
            .disabled(!model.cfg.enabled)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(BackdropConfig.presets.enumerated()), id: \.offset) { _, p in
                    Button {
                        model.cfg.fromHex = p.0; model.cfg.toHex = p.1; model.cfg.gradient = true; model.cfg.enabled = true
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: p.0)), Color(nsColor: NSColor(hex: p.1))],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 48, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Randomize", action: model.randomize).disabled(!model.cfg.enabled)
                Button("Image…", action: model.loadImage)
                if model.hasImage { Button("Remove image", action: model.removeImage) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
