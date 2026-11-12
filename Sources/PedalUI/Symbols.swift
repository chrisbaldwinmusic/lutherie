import PedalCore
import SwiftUI

/// The Channel Audio house look, shared with Atelier (dark faceplate, cream lettering, spaced capitals, the same
/// knobs and panels), in Lutherie's own colour: a deep oxblood red where Atelier uses gold, on a slightly warmer
/// faceplate. Gold is kept for small highlights.
public enum Theme {
    static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: alpha)
    }
    public static let bg = hex(0x191516)          // faceplate, warmed
    public static let panel = hex(0x262022)
    public static let panelEdge = hex(0x0d0a0b)
    public static let panelHi = hex(0x3a3033)
    public static let panel2 = hex(0x151112)      // buttons and menus
    public static let well = hex(0x0e0b0c)
    public static let wellEdge = hex(0x43383b)
    public static let ledOff = hex(0x30282a)
    public static let line = hex(0x43383b, 0.55)
    public static let text = hex(0xe9dfc6)        // cream
    public static let dim = hex(0xa39d8d)
    public static let gold = hex(0xc9a25a)
    public static let red = hex(0xb8403a)         // Lutherie's red
    public static let crimson = hex(0x8f2630)     // deeper, for the amp
    public static let blue = hex(0x4f86b8)
    public static let green = hex(0x62a070)
    public static let orange = hex(0xd9853b)
    public static let purple = hex(0x8672b8)
    public static let ivory = hex(0xcfc7b2)
    public static let teal = hex(0x4fa3a0)
    public static let accent = red
    public static let wire = hex(0x6fa3d0)
    public static let part = hex(0xe9dfc6)
    public static let selected = hex(0xc9a25a)
    public static let pin = hex(0xd9853b)
    public static let good = hex(0x62a070)

    /// Bold, letter-spaced capitals, as on Atelier's panels.
    public static func label(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

/// A raised panel: soft top-to-bottom shading, a dark edge and a highlight along the top.
struct PanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Theme.hex(0x2c2527), Theme.hex(0x1d1819)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.panelEdge, lineWidth: 1.2))
            .overlay(alignment: .top) { Rectangle().fill(Theme.panelHi.opacity(0.6)).frame(height: 1).padding(.horizontal, 7).padding(.top, 1.5) }
    }
}

/// Line drawings of each part in local grid units (before rotation).
enum Symbol {
    struct Shape {
        var strokes: [[CGPoint]] = []         // polylines
        var filled: [[CGPoint]] = []          // filled polygons
        var circles: [(CGPoint, CGFloat)] = []
        var dashed: [[CGPoint]] = []
        var texts: [(String, CGPoint)] = []
    }

    static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// The symbol for a particular part: switches are drawn in their present position.
    static func shape(for part: Part) -> Shape {
        var s = shape(part.kind)
        switch part.kind {
        case .spst:
            s.strokes.append(part.switchState == 0 ? [p(-0.8, 0), p(0.65, -0.75)] : [p(-0.8, 0), p(0.8, 0)])
        case .spdt:
            let y: CGFloat = part.switchState == 0 ? -1 : (part.switchState == 1 ? 1 : 0)
            s.strokes.append([p(-0.8, 0), p(y == 0 ? 0.6 : 0.8, y)])
        default: break
        }
        return s
    }

    static func shape(_ kind: PartKind) -> Shape {
        var s = Shape()
        switch kind {
        case .nmos, .pmos:
            s.circles.append((p(0.4, 0), 1.35))
            s.strokes += [[p(-2, 0), p(-0.5, 0)], [p(-0.5, -0.7), p(-0.5, 0.7)],
                          [p(-0.15, -0.85), p(-0.15, -0.35)], [p(-0.15, -0.25), p(-0.15, 0.25)], [p(-0.15, 0.35), p(-0.15, 0.85)],
                          [p(-0.15, -0.6), p(1, -0.6), p(1, -2)], [p(-0.15, 0.6), p(1, 0.6), p(1, 2)],
                          [p(-0.15, 0), p(1, 0), p(1, 0.6)]]
            if kind == .nmos {
                s.filled.append([p(-0.1, 0), p(0.4, -0.25), p(0.4, 0.25)])
            } else {
                s.filled.append([p(0.55, 0), p(0.05, -0.25), p(0.05, 0.25)])
            }
        case .spst:
            s.strokes += [[p(-2, 0), p(-0.8, 0)], [p(0.8, 0), p(2, 0)]]
            s.circles += [(p(-0.8, 0), 0.14), (p(0.8, 0), 0.14)]
        case .spdt:
            s.strokes += [[p(-2, 0), p(-0.8, 0)], [p(0.8, -1), p(2, -1)], [p(0.8, 1), p(2, 1)]]
            s.circles += [(p(-0.8, 0), 0.14), (p(0.8, -1), 0.14), (p(0.8, 1), 0.14)]
            s.texts += [("A", p(1.4, -1.55)), ("B", p(1.4, 1.55))]
        case .resistor, .pot:
            var zig = [p(-2, 0), p(-1.2, 0)]
            for i in 0..<6 { zig.append(p(-1.0 + CGFloat(i) * 0.4, i % 2 == 0 ? -0.4 : 0.4)) }
            zig += [p(1.2, 0), p(2, 0)]
            s.strokes.append(zig)
            if kind == .pot {
                s.strokes.append([p(0, -2), p(0, -0.55)])
                s.filled.append([p(-0.28, -0.95), p(0.28, -0.95), p(0, -0.5)])
            }
        case .capacitor:
            s.strokes += [[p(-2, 0), p(-0.22, 0)], [p(0.22, 0), p(2, 0)], [p(-0.22, -0.75), p(-0.22, 0.75)], [p(0.22, -0.75), p(0.22, 0.75)]]
        case .inductor:
            var coil: [CGPoint] = [p(-2, 0), p(-1.2, 0)]
            for k in 0..<4 {
                let cx = -0.9 + CGFloat(k) * 0.6
                for a in stride(from: 180.0, through: 360.0, by: 20) {
                    coil.append(p(cx + 0.3 * CGFloat(cos(a * .pi / 180)), 0.45 * CGFloat(sin(a * .pi / 180))))
                }
            }
            coil += [p(1.2, 0), p(2, 0)]
            s.strokes.append(coil)
        case .diode, .led, .zener:
            s.strokes += [[p(-2, 0), p(-0.55, 0)], [p(0.55, 0), p(2, 0)], [p(0.55, -0.6), p(0.55, 0.6)]]
            if kind == .zener { s.strokes += [[p(0.55, -0.6), p(0.25, -0.85)], [p(0.55, 0.6), p(0.85, 0.85)]] }
            s.filled.append([p(-0.55, -0.6), p(-0.55, 0.6), p(0.55, 0)])
            if kind == .led {
                s.strokes += [[p(0.1, -0.75), p(0.6, -1.3)], [p(0.5, -0.75), p(1.0, -1.3)]]
                s.filled += [[p(0.6, -1.3), p(0.38, -1.2), p(0.55, -1.08)], [p(1.0, -1.3), p(0.78, -1.2), p(0.95, -1.08)]]
            }
        case .npn, .pnp:
            s.circles.append((p(0.4, 0), 1.35))
            s.strokes += [[p(-2, 0), p(-0.25, 0)], [p(-0.25, -0.85), p(-0.25, 0.85)],
                          [p(-0.25, -0.4), p(1, -1.15), p(1, -2)], [p(-0.25, 0.4), p(1, 1.15), p(1, 2)]]
            if kind == .npn {
                s.filled.append([p(1, 1.15), p(0.5, 1.15), p(0.75, 0.75)])
            } else {
                s.filled.append([p(-0.2, 0.42), p(0.35, 0.55), p(0.1, 0.9)])
            }
        case .njfet, .pjfet:
            s.circles.append((p(0.4, 0), 1.35))
            s.strokes += [[p(-2, 0), p(-0.1, 0)], [p(-0.1, -0.9), p(-0.1, 0.9)],
                          [p(-0.1, -0.6), p(1, -0.6), p(1, -2)], [p(-0.1, 0.6), p(1, 0.6), p(1, 2)]]
            s.filled.append(kind == .njfet ? [p(-0.1, 0), p(-0.55, -0.25), p(-0.55, 0.25)] : [p(-0.75, 0), p(-0.3, -0.25), p(-0.3, 0.25)])
        case .triode:
            s.circles.append((p(0.5, 0), 1.55))
            s.strokes += [[p(0.1, -0.8), p(1.1, -0.8)], [p(1, -0.8), p(1, -2)],
                          [p(-2, 0), p(-0.1, 0)],
                          [p(0.1, 0.8), p(1.0, 0.8), p(1.0, 2)], [p(0.1, 0.8), p(0.1, 1.05)]]
            s.dashed.append([p(-0.1, 0), p(1.1, 0)])
        case .pentode:
            s.circles.append((p(0.5, 0), 1.6))
            s.strokes += [[p(0.1, -0.95), p(1.1, -0.95)], [p(1, -0.95), p(1, -2)],
                          [p(-2, 0), p(-0.6, 0), p(-0.1, 0.25)],
                          [p(1.1, -0.35), p(2.5, -0.35), p(3, 0)],
                          [p(0.1, 0.9), p(1.0, 0.9), p(1.0, 2)], [p(0.1, 0.9), p(0.1, 1.15)]]
            s.dashed += [[p(-0.1, 0.25), p(1.1, 0.25)], [p(-0.1, -0.35), p(1.1, -0.35)]]
        case .transformer:
            for (x, bulge) in [(-0.7, -1.0), (0.7, 1.0)] {
                var coil: [CGPoint] = [p(x < 0 ? -2 : 2, -2), p(x, -2)]
                for k in 0..<4 {
                    let cy = -1.5 + CGFloat(k)
                    for a in stride(from: -90.0, through: 90.0, by: 20) {
                        coil.append(p(x + CGFloat(bulge) * 0.42 * CGFloat(cos(a * .pi / 180)), cy + 0.5 * CGFloat(sin(a * .pi / 180))))
                    }
                }
                coil += [p(x, 2), p(x < 0 ? -2 : 2, 2)]
                s.strokes.append(coil)
            }
            s.strokes += [[p(-2, 0), p(-0.7, 0)], [p(-0.12, -1.9), p(-0.12, 1.9)], [p(0.12, -1.9), p(0.12, 1.9)]]
        case .opamp:
            s.strokes += [[p(-1.5, -1.8), p(-1.5, 1.8), p(1.6, 0), p(-1.5, -1.8)],
                          [p(-2, 1), p(-1.5, 1)], [p(-2, -1), p(-1.5, -1)], [p(1.6, 0), p(2, 0)]]
            s.texts += [("+", p(-1.05, 1)), ("−", p(-1.05, -1))]
        case .ground:
            s.strokes += [[p(0, 0), p(0, 0.6)], [p(-0.7, 0.6), p(0.7, 0.6)], [p(-0.45, 0.85), p(0.45, 0.85)], [p(-0.2, 1.1), p(0.2, 1.1)]]
        case .supply:
            s.strokes += [[p(0, 0), p(0, -0.6)], [p(-0.7, -0.6), p(0.7, -0.6)]]
        case .input:
            s.strokes += [[p(0, 0), p(-0.6, 0)]]
            s.circles.append((p(-0.95, 0), 0.35))
        case .output:
            s.strokes += [[p(0, 0), p(0.6, 0)]]
            s.circles.append((p(0.95, 0), 0.35))
        case .label:
            s.strokes += [[p(0, 0), p(0.4, -0.45), p(2.6, -0.45), p(2.6, 0.45), p(0.4, 0.45), p(0, 0)]]
        }
        return s
    }

    /// Box used for clicking on a part, in local units.
    static func bounds(_ kind: PartKind) -> CGRect {
        switch kind {
        case .resistor, .capacitor, .inductor, .diode, .led, .zener: return CGRect(x: -2, y: -0.8, width: 4, height: 1.6)
        case .spst: return CGRect(x: -2, y: -1.0, width: 4, height: 1.6)
        case .spdt: return CGRect(x: -2, y: -1.5, width: 4, height: 3)
        case .pot: return CGRect(x: -2, y: -2, width: 4, height: 2.8)
        case .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .triode, .opamp, .transformer: return CGRect(x: -2, y: -2, width: 4, height: 4)
        case .pentode: return CGRect(x: -2, y: -2, width: 5, height: 4)
        case .label: return CGRect(x: 0, y: -0.6, width: 2.8, height: 1.2)
        case .input: return CGRect(x: -1.5, y: -0.6, width: 1.6, height: 1.2)
        case .output: return CGRect(x: -0.1, y: -0.6, width: 1.6, height: 1.2)
        case .ground: return CGRect(x: -0.8, y: -0.2, width: 1.6, height: 1.5)
        case .supply: return CGRect(x: -0.8, y: -1.0, width: 1.6, height: 1.2)
        }
    }

    /// Text shown next to a part.
    static func caption(_ part: Part) -> (String, String) {
        switch part.kind {
        case .resistor: return (part.name, Eng.format(part["r"], unit: "Ω"))
        case .capacitor: return (part.name, Eng.format(part["c"], unit: "F"))
        case .inductor: return (part.name, Eng.format(part["l"], unit: "H"))
        case .pot: return (part.text.isEmpty ? part.name : part.text, Eng.format(part["r"], unit: "Ω") + " " + part.model + (part.gang > 0 ? " · gang \(part.gang)" : ""))
        case .diode, .led, .zener, .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .triode, .pentode, .opamp: return (part.name, part.model)
        case .transformer: return (part.name, Eng.format(part["zpp"], unit: "Ω") + " : " + Eng.format(part["zs"], unit: "Ω"))
        case .spst, .spdt: return (part.text.isEmpty ? part.name : part.text, part.switchStateName)
        case .supply: return (part.text.isEmpty ? Eng.format(part["v"], unit: "V") : part.text, "")
        case .input: return ("Guitar in", "")
        case .output: return ("Out", "")
        case .label: return (part.text, "")
        case .ground: return ("", "")
        }
    }
}

/// Draws one part into a canvas. `origin` and `scale` map grid units to view points.
func drawPart(_ part: Part, in ctx: inout GraphicsContext, origin: CGPoint, scale: CGFloat, color: Color, lineWidth: CGFloat) {
    let shape = Symbol.shape(for: part)
    func tx(_ q: CGPoint) -> CGPoint {
        var x = q.x, y = q.y
        if part.flipped { x = -x }
        switch part.rotation {
        case 1: (x, y) = (-y, x)
        case 2: (x, y) = (-x, -y)
        case 3: (x, y) = (y, -x)
        default: break
        }
        return CGPoint(x: origin.x + (CGFloat(part.position.x) + x) * scale, y: origin.y + (CGFloat(part.position.y) + y) * scale)
    }
    for line in shape.strokes {
        var path = Path()
        path.addLines(line.map(tx))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
    for line in shape.dashed {
        var path = Path()
        path.addLines(line.map(tx))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, dash: [3, 3]))
    }
    for poly in shape.filled {
        var path = Path()
        path.addLines(poly.map(tx))
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }
    for (c, r) in shape.circles {
        let cc = tx(c)
        ctx.stroke(Path(ellipseIn: CGRect(x: cc.x - r * scale, y: cc.y - r * scale, width: 2 * r * scale, height: 2 * r * scale)),
                   with: .color(color), lineWidth: lineWidth)
    }
    for (t, at) in shape.texts {
        ctx.draw(Text(t).font(.system(size: max(8, scale * 0.6), weight: .bold)).foregroundColor(color), at: tx(at))
    }
    // captions, kept upright
    let (title, value) = Symbol.caption(part)
    let fontSize = max(8, min(13, scale * 0.55))
    let center = tx(.zero)
    let horizontal = part.rotation % 2 == 0
    var anchor: CGPoint
    var align: UnitPoint
    switch part.kind {
    case .ground: return
    case .supply:
        anchor = tx(CGPoint(x: 0, y: -1.2)); align = .center
        if part.rotation == 2 { anchor = tx(CGPoint(x: 0, y: -1.3)) }
    case .input: anchor = CGPoint(x: center.x - 1.5 * scale, y: center.y); align = .trailing
    case .output: anchor = CGPoint(x: center.x + 1.5 * scale, y: center.y); align = .leading
    case .label: anchor = tx(CGPoint(x: 1.5, y: 0)); align = .center
    case .spdt:
        anchor = horizontal ? CGPoint(x: center.x, y: center.y - 2.1 * scale) : CGPoint(x: center.x + 1.9 * scale, y: center.y)
        align = horizontal ? .bottom : .leading
    case .transformer:
        anchor = CGPoint(x: center.x, y: center.y - 2.4 * scale); align = .bottom
    case .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .triode, .pentode, .opamp:
        anchor = CGPoint(x: center.x + (part.kind == .pentode ? 2.3 : 2.0) * scale, y: center.y - (part.kind == .pentode ? 1.3 : 0.6) * scale); align = .leading
        if part.kind != .opamp && !horizontal {
            // turned on its side: the leads run left and right, so the caption goes on the side away from the gate
            let below = tx(CGPoint(x: -2, y: 0)).y < center.y
            anchor = CGPoint(x: center.x, y: center.y + (below ? 2.0 : -2.0) * scale); align = below ? .top : .bottom
        }
    default:
        anchor = horizontal ? CGPoint(x: center.x, y: center.y - 1.1 * scale) : CGPoint(x: center.x + 0.9 * scale, y: center.y)
        align = horizontal ? .bottom : .leading
        if part.kind == .pot {
            // caption on the side away from the wiper
            let w = tx(CGPoint(x: 0, y: -2))
            if horizontal {
                let below = w.y < center.y
                anchor = CGPoint(x: center.x, y: center.y + (below ? 1.0 : -1.0) * scale); align = below ? .top : .bottom
            } else {
                let left = w.x > center.x
                anchor = CGPoint(x: center.x + (left ? -0.9 : 0.9) * scale, y: center.y); align = left ? .trailing : .leading
            }
        }
    }
    let txt = Text(title).font(.system(size: fontSize, weight: .semibold)).foregroundColor(color)
        + Text(value.isEmpty ? "" : (part.kind == .label || part.kind == .supply ? "" : "  ")).font(.system(size: fontSize))
        + Text(value).font(.system(size: fontSize)).foregroundColor(Theme.dim)
    ctx.draw(txt, at: anchor, anchor: align)
}
