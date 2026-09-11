import SwiftUI
import UniformTypeIdentifiers

struct ClipboardDrag: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .clipboardLibraryItem)
    }
}

extension UTType {
    static let clipboardLibraryItem = UTType(exportedAs: "local.clipboard-library.item")
}

func clipboardNoteText(_ representations: [PasteboardRepresentation], fallback: String) -> String {
    let groups = Dictionary(grouping: representations, by: \.itemIndex)
    let texts = groups.keys.sorted().compactMap { index -> String? in
        let reps = groups[index] ?? []
        for type in ["public.utf8-plain-text", "public.url", "public.file-url"] {
            if let rep = reps.first(where: { $0.uti == type }),
               let text = String(data: rep.data, encoding: .utf8) { return text }
        }
        if let rep = reps.first(where: { $0.uti == "public.rtf" }),
           let text = NSAttributedString(rtf: rep.data, documentAttributes: nil) { return text.string }
        return nil
    }
    return texts.isEmpty ? fallback : texts.joined(separator: "\n")
}
