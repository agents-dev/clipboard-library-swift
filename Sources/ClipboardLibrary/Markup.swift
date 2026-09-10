import SwiftUI
import AppKit
import GRDB

struct MarkupLayer: Codable {
    var tool: String
    var points: [CGPoint]
    var text: String
    var width: Double
    var red: Double
    var green: Double
    var blue: Double
}
struct MarkupDocument: Codable {
    var version = 1
    var sourceID: String
    var layers: [MarkupLayer]
}
struct MarkupView: View {
    let image: NSImage
    let itemID: String
    let repository: ClipboardRepository
    @Environment(\.dismiss) var dismiss
    @State var layers: [MarkupLayer] = []
    @State var redo: [MarkupLayer] = []
    @State var tool = "Pen"
    @State var width = 4.0
    @State var color = Color.red
    @State var text = "Text"
    @State var error = ""
    @State var draft: MarkupLayer?
    @State var versions: [(String, String, Data)] = []
    @State var selectedVersion = "Original"
    var body: some View {
        VStack {
            HStack {
                Picker("Tool", selection: $tool) { ForEach(["Pen", "Highlighter", "Arrow", "Rectangle", "Ellipse", "Text", "Crop", "Blur", "Redact"], id: \.self) { Text($0) } }.frame(width: 170)
                ColorPicker("Color", selection: $color).labelsHidden()
                Slider(value: $width, in: 1...30).frame(width: 90)
                TextField("Label", text: $text).frame(width: 100)
                Button("Undo") { if let last = layers.popLast() { redo.append(last) } }.disabled(layers.isEmpty)
                Button("Redo") { if let last = redo.popLast() { layers.append(last) } }.disabled(redo.isEmpty)
            }
            Picker("Version", selection: $selectedVersion) { Text("Original").tag("Original"); ForEach(versions, id: \.0) { version in Text(version.1).tag(version.0) } }.onChange(of: selectedVersion) { _, value in
                if value == "Original" { layers = [] } else if let version = versions.first(where: { $0.0 == value }) { do { layers = try JSONDecoder().decode(MarkupDocument.self, from: version.2).layers; redo = [] } catch { self.error = error.localizedDescription } }
            }
            Canvas { context, size in
                context.draw(Image(nsImage: image), in: CGRect(origin: .zero, size: size))
                for layer in layers + (draft.map { [$0] } ?? []) { draw(layer, context: &context, size: size) }
            }.aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                .overlay { GeometryReader { geometry in Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let point = CGPoint(x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height)
                    if draft == nil { let c = NSColor(color).usingColorSpace(.deviceRGB) ?? .red; draft = MarkupLayer(tool: tool, points: [point], text: text, width: width, red: c.redComponent, green: c.greenComponent, blue: c.blueComponent) }
                    draft?.points.append(point)
                }.onEnded { _ in if let draft { layers.append(draft); redo = [] }; draft = nil }) } }
            HStack {
                Text(error).foregroundStyle(.red); Spacer()
                Button("Save version") { save() }
                Button("Copy PNG") { if let data = rendered() { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png) } }
                Button("Export PNG") { let panel = NSSavePanel(); panel.nameFieldStringValue = "Markup.png"; if panel.runModal() == .OK, let url = panel.url, let data = rendered() { do { try data.write(to: url) } catch { self.error = error.localizedDescription } } }
                Button("Done") { dismiss() }
            }
        }.padding().frame(width: 850, height: 650).onAppear { loadVersions() }
    }
    func loadVersions() { do { versions = try repository.db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM markup WHERE itemID=? ORDER BY rowid DESC", arguments: [itemID]).map { ($0["id"], $0["name"], $0["document"]) } } } catch { self.error = error.localizedDescription } }
    func save() {
        do { let data = try JSONEncoder().encode(MarkupDocument(sourceID: itemID, layers: layers)); try repository.db.write { try $0.execute(sql: "INSERT INTO markup(id,itemID,name,document) VALUES(?,?,?,?)", arguments: [UUID().uuidString, itemID, Date().formatted(), data]) }; loadVersions(); error = "Version saved" } catch { self.error = error.localizedDescription }
    }
    @MainActor func rendered() -> Data? {
        let renderer = ImageRenderer(content: Canvas { context, size in context.draw(Image(nsImage: image), in: CGRect(origin: .zero, size: size)); for layer in layers { draw(layer, context: &context, size: size) } }.frame(width: image.size.width, height: image.size.height))
        guard var cg = renderer.cgImage else { return nil }
        if let crop = layers.last(where: { $0.tool == "Crop" }), let a = crop.points.first, let b = crop.points.last {
            let rect = CGRect(x: min(a.x,b.x)*CGFloat(cg.width), y: min(a.y,b.y)*CGFloat(cg.height), width: abs(a.x-b.x)*CGFloat(cg.width), height: abs(a.y-b.y)*CGFloat(cg.height)).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if rect.width > 1, rect.height > 1, let cropped = cg.cropping(to: rect) { cg = cropped }
        }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    func draw(_ layer: MarkupLayer, context: inout GraphicsContext, size: CGSize) {
        guard let a = layer.points.first, let b = layer.points.last else { return }
        let start = CGPoint(x: a.x * size.width, y: a.y * size.height), end = CGPoint(x: b.x * size.width, y: b.y * size.height)
        let rect = CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(start.x-end.x), height: abs(start.y-end.y))
        let color = Color(red: layer.red, green: layer.green, blue: layer.blue)
        var path = Path()
        switch layer.tool {
        case "Crop": return
        case "Blur":
            var blurred = context; blurred.clip(to: Path(rect)); blurred.addFilter(.blur(radius: 12)); blurred.draw(Image(nsImage: image), in: CGRect(origin: .zero, size: size)); return
        case "Rectangle": path.addRect(rect)
        case "Ellipse": path.addEllipse(in: rect)
        case "Redact": context.fill(Path(rect), with: .color(.black)); return
        case "Text": context.draw(Text(layer.text).font(.system(size: max(16, layer.width * 4))).foregroundColor(color), at: start, anchor: .topLeading); return
        case "Arrow":
            path.move(to: start); path.addLine(to: end)
            let angle = atan2(end.y-start.y, end.x-start.x)
            for offset in [-0.5,0.5] { path.move(to: end); path.addLine(to: CGPoint(x: end.x - 18*cos(angle+offset), y: end.y - 18*sin(angle+offset))) }
        default: path.addLines(layer.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        }
        context.stroke(path, with: .color(color.opacity(layer.tool == "Highlighter" ? 0.3 : 1)), style: StrokeStyle(lineWidth: layer.tool == "Highlighter" ? layer.width * 4 : layer.width, lineCap: .round, lineJoin: .round))
    }
}
