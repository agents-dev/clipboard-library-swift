import SwiftUI
import UniformTypeIdentifiers

enum NoteDrag {
    static let type = UTType(exportedAs: "local.ClipboardLibrary.note-subtree")

    static func provider(_ id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        return provider
    }
}

struct NoteDropDelegate: DropDelegate {
    let rowID: String?
    var height: CGFloat = 28
    let notes: [OutlineNote]
    @Binding var draggingID: String?
    @Binding var indicator: NoteDropDestination?
    let move: (String, NoteDropDestination) -> Void

    private func destination(_ info: DropInfo) -> NoteDropDestination {
        rowID.map { .row($0, y: info.location.y, height: height) } ?? .rootEnd
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [NoteDrag.type]), let id = draggingID else { return false }
        return (try? NoteMovePlan(id: id, destination: destination(info), notes: notes)) != nil
    }

    func dropEntered(info: DropInfo) {
        indicator = validateDrop(info: info) ? destination(info) : nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            indicator = nil
            return DropProposal(operation: .forbidden)
        }
        indicator = destination(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if indicator?.targetID == rowID { indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let expectedID = draggingID,
              let provider = info.itemProviders(for: [NoteDrag.type]).first else { return false }
        let target = destination(info)
        indicator = nil
        draggingID = nil
        provider.loadDataRepresentation(forTypeIdentifier: NoteDrag.type.identifier) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8), id == expectedID else { return }
            DispatchQueue.main.async { move(id, target) }
        }
        return true
    }
}

private struct NoteRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 28
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct NoteRowDropTarget: ViewModifier {
    let row: VisibleNote
    let notes: [OutlineNote]
    let marker: NoteInsertionMarker?
    @Binding var draggingID: String?
    @Binding var indicator: NoteDropDestination?
    let move: (String, NoteDropDestination) -> Void
    @State private var height: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear.preference(key: NoteRowHeight.self, value: geometry.size.height)
            })
            .onPreferenceChange(NoteRowHeight.self) { height = $0 }
            .background {
                if indicator == .inside(row.id) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15))
                        .padding(.leading, CGFloat(row.depth * 22) + 8)
                }
            }
            .overlay(alignment: .topLeading) {
                if let marker, marker.rowID == row.id, marker.atTop { insertionLine(depth: marker.depth) }
            }
            .overlay(alignment: .bottomLeading) {
                if let marker, marker.rowID == row.id, !marker.atTop { insertionLine(depth: marker.depth) }
            }
            .onDrop(of: [NoteDrag.type], delegate: NoteDropDelegate(
                rowID: row.id, height: height, notes: notes,
                draggingID: $draggingID, indicator: $indicator, move: move
            ))
    }

    private func insertionLine(depth: Int) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
            .padding(.leading, CGFloat(depth * 22) + 28).allowsHitTesting(false)
    }
}
