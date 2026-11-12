import SwiftUI

/// Squarified treemap over TreeNode children. Tap a tile to drill in; breadcrumb to go back.
struct TreemapView: View {
    let root: TreeNode
    var statuses: [String: DiffResult.Status]? = nil   // keyed by path relative to root.url
    @State private var focusPath: [TreeNode]

    init(root: TreeNode, statuses: [String: DiffResult.Status]? = nil) {
        self.root = root
        self.statuses = statuses
        _focusPath = State(initialValue: [root])
    }

    private var focus: TreeNode { focusPath.last ?? root }

    private func relPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: root.url.path + "/", with: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    let tiles = Squarify.layout(nodes: focus.sortedChildren,
                                                 in: CGRect(origin: .zero, size: geo.size))
                    ForEach(tiles, id: \.node.id) { tile in
                        Tile(node: tile.node, rect: tile.rect,
                             status: statuses?[relPath(tile.node.url)]) { drilled in
                            focusPath.append(drilled)
                        }
                    }
                    if focus.children.isEmpty {
                        Text("no files").foregroundStyle(.secondary).padding()
                    }
                }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(focusPath.enumerated()), id: \.element.id) { idx, node in
                if idx > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(node == focusPath.last ? node.name : node.name) {
                    if idx < focusPath.count - 1 { focusPath = Array(focusPath.prefix(idx + 1)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(node == focusPath.last ? .primary : .secondary)
            }
            Spacer()
            Text(ByteFormat.string(focus.size)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Button { focusPath = [root] } label: { Image(systemName: "house") }
                .buttonStyle(.borderless).help("root")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private struct Tile: View {
        let node: TreeNode
        let rect: CGRect
        let status: DiffResult.Status?
        let onDrill: (TreeNode) -> Void
        @State private var hovered = false

        var body: some View {
            Rectangle()
                .fill(color.opacity(hovered ? 1.0 : 0.82))
                .overlay(Rectangle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    if rect.width > 64 && rect.height > 30 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.name).font(.caption2.weight(.medium)).lineLimit(1)
                            Text(ByteFormat.string(node.size))
                                .font(.system(size: 9, design: .monospaced))
                                .opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .padding(4)
                    }
                }
                .frame(width: max(rect.width - 1, 0), height: max(rect.height - 1, 0))
                .offset(x: rect.minX, y: rect.minY)
                .contentShape(Rectangle())
                .onTapGesture { if node.isDirectory && !node.children.isEmpty { onDrill(node) } }
                .onHover { hovered = $0 }
                .help("\(node.name) — \(ByteFormat.string(node.size))")
                .animation(.easeOut(duration: 0.12), value: hovered)
        }

        private var color: Color {
            switch status {
            case .onlyInSource: return Color(hue: 0.36, saturation: 0.75, brightness: 0.75)   // green: would be added
            case .onlyInDest:   return Color(hue: 0.02, saturation: 0.75, brightness: 0.75)   // red: extra in target
            case .differs:      return Color(hue: 0.10, saturation: 0.80, brightness: 0.85)   // orange: size differs
            case .same:         return Color(hue: 0.58, saturation: 0.45, brightness: 0.55)   // muted blue: in sync
            case nil:
                if node.isDirectory { return Color(hue: 0.58, saturation: 0.55, brightness: 0.72) }
                return ExtensionPalette.color(for: node.url.pathExtension)
            }
        }
    }
}

// MARK: - Squarify (Bruls et al.)

enum Squarify {
    struct Tile { let node: TreeNode; let rect: CGRect }

    static func layout(nodes: [TreeNode], in rect: CGRect) -> [Tile] {
        let items = nodes.filter { $0.size > 0 }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        var tiles: [Tile] = []
        squarify(items, scale: Double(rect.width * rect.height) / Double(total),
                 row: [], x: rect.minX, y: rect.minY,
                 w: rect.width, h: rect.height, worst: .infinity, into: &tiles)
        return tiles
    }

    private static func squarify(_ items: [TreeNode], scale: Double, row: [TreeNode],
                                 x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                                 worst: Double, into tiles: inout [Tile]) {
        guard w > 0, h > 0 else { return }   // remainder exhausted; drop any leftover items
        guard let first = items.first else {
            if !row.isEmpty { flush(row, scale: scale, x: x, y: y, w: w, h: h, into: &tiles) }
            return
        }
        let side = min(w, h)
        let candidate = row + [first]
        let candidateWorst = worstRatio(candidate, scale: scale, side: side)
        if row.isEmpty || candidateWorst <= worst {
            squarify(Array(items.dropFirst()), scale: scale, row: candidate,
                     x: x, y: y, w: w, h: h, worst: candidateWorst, into: &tiles)
        } else {
            let (newX, newY, newW, newH) = flush(row, scale: scale, x: x, y: y, w: w, h: h, into: &tiles)
            squarify(items, scale: scale, row: [], x: newX, y: newY, w: newW, h: newH,
                     worst: .infinity, into: &tiles)
        }
    }

    private static func worstRatio(_ row: [TreeNode], scale: Double, side: CGFloat) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let s = row.map { Double($0.size) * scale }
        let total = s.reduce(0, +)
        guard total > 0 else { return .infinity }
        let mx = s.max()!, mn = s.min()!
        let sideD = Double(side)
        return max((sideD * sideD * mx) / (total * total), (total * total) / (sideD * sideD * mn))
    }

    @discardableResult
    private static func flush(_ row: [TreeNode], scale: Double, x: CGFloat, y: CGFloat,
                              w: CGFloat, h: CGFloat, into tiles: inout [Tile]) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let side = min(w, h)
        let total = row.reduce(0.0) { $0 + Double($1.size) * scale }   // area of the strip
        guard side > 0 else { return (x, y, w, h) }
        let strip = total / side          // thickness of the laid strip (perpendicular to `side`)
        var off = 0.0
        for n in row {
            let area = Double(n.size) * scale
            let len = area / max(strip, 0.0001)   // long dimension along `side`
            if w <= h {  // strip along the top, tiles laid left→right
                tiles.append(Tile(node: n, rect: CGRect(x: x + CGFloat(off), y: y,
                                                        width: CGFloat(len), height: CGFloat(strip))))
            } else {     // strip along the left, tiles laid top→bottom
                tiles.append(Tile(node: n, rect: CGRect(x: x, y: y + CGFloat(off),
                                                        width: CGFloat(strip), height: CGFloat(len))))
            }
            off += len
        }
        if w <= h { return (x, y + CGFloat(strip), w, max(h - CGFloat(strip), 0)) }
        else { return (x + CGFloat(strip), y, max(w - CGFloat(strip), 0), h) }
    }
}

enum ExtensionPalette {
    static func color(for ext: String) -> Color {
        let e = ext.lowercased()
        func hue(_ h: Double, _ s: Double = 0.6, _ b: Double = 0.8) -> Color { Color(hue: h, saturation: s, brightness: b) }
        switch e {
        case "swift", "py", "js", "ts", "m", "h", "c", "cpp", "rs", "go", "rb": return hue(0.08)  // orange: code
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg": return hue(0.33)          // green: images
        case "mp4", "mov", "avi", "mkv", "webm": return hue(0.75)                                  // violet: video
        case "mp3", "wav", "aiff", "flac", "m4a": return hue(0.55)                                 // teal: audio
        case "pdf", "doc", "docx", "txt", "md", "rtf": return hue(0.15)                            // rose: docs
        case "zip", "tar", "gz", "dmg", "pkg", "ipa": return hue(0.12, 0.4, 0.6)                   // brown: archives
        case "json", "yaml", "yml", "toml", "xml", "plist", "csv": return hue(0.17, 0.5, 0.9)      // sand: data
        default: return hue(0.0, 0.0, 0.55)                                                         // gray
        }
    }
}
