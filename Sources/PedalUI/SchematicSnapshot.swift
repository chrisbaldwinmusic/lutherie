import AppKit
import PedalCore
import SwiftUI

/// Draws a circuit to a PNG without needing a window (testing aid: `Lutherie --render "Preset name" out.png`).
@MainActor
public enum SchematicSnapshot {
    public static func png(_ c: Circuit, scale: CGFloat = 22) -> Data? {
        let points = c.parts.flatMap { [$0.position] + $0.pins } + c.wires.flatMap { [$0.a, $0.b] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let margin: CGFloat = 5
        let size = CGSize(width: (CGFloat(maxX - minX) + 2 * margin) * scale, height: (CGFloat(maxY - minY) + 2 * margin) * scale)
        let origin = CGPoint(x: (margin - CGFloat(minX)) * scale, y: (margin - CGFloat(minY)) * scale)
        let view = Canvas { ctx, _ in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.bg))
            for w in c.wires {
                var p = Path()
                p.move(to: CGPoint(x: origin.x + CGFloat(w.a.x) * scale, y: origin.y + CGFloat(w.a.y) * scale))
                p.addLine(to: CGPoint(x: origin.x + CGFloat(w.b.x) * scale, y: origin.y + CGFloat(w.b.y) * scale))
                ctx.stroke(p, with: .color(Theme.wire), lineWidth: 1.6)
            }
            var g = ctx
            for part in c.parts { drawPart(part, in: &g, origin: origin, scale: scale, color: Theme.part, lineWidth: 1.6) }
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// The whole editor drawn off screen (system pickers and menus don't draw this way; everything else does).
    public static func editorPNG(preset: Circuit?, width: CGFloat = 1440, height: CGFloat = 920) -> Data? {
        let model = EditorModel()
        if let p = preset { model.load(preset: p) }
        model.fitView()
        let view = EditorView(model: model) { EmptyView() }.frame(width: width, height: height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
