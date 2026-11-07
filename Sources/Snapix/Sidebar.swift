import AppKit
import SwiftUI

/// What the sidebar shows: the annotations of the open document, topmost first, and which one is selected.
@MainActor
final class SidebarModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let tool: Tool
        let summary: String
        let colorHex: UInt32
    }

    @Published var rows: [Row] = []
    @Published var selected: UUID?
    var onSelect: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onMove: ((UUID, Int) -> Void)?

    /// One-line description of an annotation for its row.
    nonisolated static func summary(for a: Annotation) -> String {
        switch a.tool {
        case .text: return a.text.isEmpty ? Tool.text.title : String(a.text.prefix(28))
        case .counter: return "\(Tool.counter.title) \(a.number)"
        case .ruler: return "\(Tool.ruler.title) · \(Int(hypot(a.p2.x - a.p1.x, a.p2.y - a.p1.y))) px"
        default: return a.tool.title
        }
    }

    func reload(from annotations: [Annotation], selected: UUID?) {
        rows = annotations.reversed().map { Row(id: $0.id, tool: $0.tool, summary: Self.summary(for: $0), colorHex: $0.color.hexValue) }
        self.selected = selected
    }
}

private struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layers").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).textCase(.uppercase)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if model.rows.isEmpty {
                Text("Annotations you add appear here.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            HStack(spacing: 8) {
                                Image(nsImage: ToolGlyph.image(for: row.tool)).renderingMode(.template).resizable().frame(width: 16, height: 16)
                                    .foregroundStyle(Color(nsColor: NSColor(hex: row.colorHex)))
                                Text(row.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                Spacer(minLength: 4)
                                Group {
                                    Button { model.onMove?(row.id, 1) } label: { Image(systemName: "chevron.up") }.help(L("Bring forward"))
                                    Button { model.onMove?(row.id, -1) } label: { Image(systemName: "chevron.down") }.help(L("Send backward"))
                                    Button { model.onDelete?(row.id) } label: { Image(systemName: "trash") }.help(L("Delete"))
                                }
                                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(model.selected == row.id ? 0.14 : 0)))
                            .contentShape(Rectangle())
                            .onTapGesture { model.onSelect?(row.id) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: Theme.bar))
        .preferredColorScheme(.dark)
    }
}

enum SidebarHost {
    @MainActor static func makeView(model: SidebarModel) -> NSView { NSHostingView(rootView: SidebarView(model: model)) }
}
