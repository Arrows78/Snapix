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
    @Published var presets = BackdropPreset.saved()

    func apply(_ p: BackdropPreset) {
        var c = p.config
        c.enabled = true
        cfg = c
    }

    func savePreset(named name: String) -> Bool {
        let ok = BackdropPreset.save(BackdropPreset(name: name, config: cfg))
        presets = BackdropPreset.saved()
        return ok
    }

    func deletePreset(_ name: String) {
        BackdropPreset.delete(named: name)
        presets = BackdropPreset.saved()
    }

    func autoBalance() {
        cfg = cfg.balanced(for: CGSize(width: doc.state.image.width, height: doc.state.image.height))
    }

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

    private func askPresetName() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L("Style name")
        let alert = NSAlert()
        alert.messageText = L("Save current style")
        alert.informativeText = L("Padding, colours, corners, shadow and pattern are stored under this name.")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !model.savePreset(named: name) { Toast.show(LF("You can save up to %d styles. Delete one first.", BackdropPreset.limit), duration: 3, symbol: "exclamationmark.triangle.fill") }
        else { Toast.show(LF("Style “%@” saved", name), symbol: "checkmark.circle.fill") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Backdrop (K)", isOn: $model.cfg.enabled).toggleStyle(.switch).font(.headline)
            Group {
                slider("Padding", $model.cfg.padding, 8...240)
                slider("Inner radius", $model.cfg.innerRadius, 0...60)
                slider("Outer radius", $model.cfg.outerRadius, 0...80)
                Toggle("Shadow", isOn: $model.cfg.shadow)
                Toggle("Window frame", isOn: Binding(get: { model.cfg.windowFrame == true }, set: { model.cfg.windowFrame = $0 }))
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
                Picker("Tape", selection: Binding(get: { model.cfg.tape ?? 0 }, set: { model.cfg.tape = $0 == 0 ? nil : $0 })) {
                    Text("None").tag(0); Text("Teal").tag(1); Text("Peach").tag(2); Text("Lavender").tag(3); Text("Cream").tag(4)
                }
                Toggle("Glow", isOn: Binding(get: { model.cfg.glow == true }, set: { model.cfg.glow = $0 ? true : nil }))
                Picker("Pattern", selection: Binding(get: { model.cfg.pattern ?? 0 }, set: { model.cfg.pattern = $0 == 0 ? nil : $0 })) {
                    Text("None").tag(0); Text("Dots").tag(1); Text("Grid").tag(2); Text("Lines").tag(3)
                }
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
            Text("Wallpapers").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(BackdropConfig.wallpapers.enumerated()), id: \.offset) { i, w in
                    Button { model.cfg = model.cfg.applying(wallpaper: i) } label: {
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: w.from)), Color(nsColor: NSColor(hex: w.to))], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Text(LocalizedStringKey(w.name)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).padding(4)
                        }
                        .frame(width: 70, height: 42)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Menu("My Styles") {
                    if model.presets.isEmpty { Text("No saved styles yet") }
                    ForEach(model.presets, id: \.name) { p in Button(p.name) { model.apply(p) } }
                    Divider()
                    Button("Save Current Style…") { askPresetName() }
                    if !model.presets.isEmpty {
                        Menu("Use for New Screenshots") {
                            Button((BackdropPreset.defaultName.isEmpty ? "✓ " : "") + L("None (keep the last one)")) { BackdropPreset.defaultName = ""; model.objectWillChange.send() }
                            ForEach(model.presets, id: \.name) { p in
                                Button((BackdropPreset.defaultName == p.name ? "✓ " : "") + p.name) { BackdropPreset.defaultName = p.name; model.objectWillChange.send() }
                            }
                        }
                    }
                    if !model.presets.isEmpty {
                        Menu("Delete Style") { ForEach(model.presets, id: \.name) { p in Button(p.name, role: .destructive) { model.deletePreset(p.name) } } }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Button("Auto-balance", action: model.autoBalance)
                Button("Randomize", action: model.randomize).disabled(!model.cfg.enabled)
                Button("Image…", action: model.loadImage)
                if model.hasImage { Button("Remove image", action: model.removeImage) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
