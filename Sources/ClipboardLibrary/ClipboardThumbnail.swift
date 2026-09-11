import SwiftUI
import ImageIO

private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 32 * 1024 * 1024; images.countLimit = 400 }
}

struct ClipboardThumbnail: View {
    let repository: ClipboardRepository
    let id: String
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .task(id: id) {
            let cacheKey = "\(ObjectIdentifier(repository))-\(id)" as NSString
            if let cached = ThumbnailCache.shared.images.object(forKey: cacheKey) {
                image = cached
                return
            }
            let worker = Task.detached(priority: .utility) { () -> NSImage? in
                guard !Task.isCancelled,
                      let reps = try? repository.representations(id) else { return nil }
                for rep in reps where ["public.png", "public.tiff", "public.jpeg"].contains(rep.uti) {
                    guard !Task.isCancelled,
                          let source = CGImageSourceCreateWithData(rep.data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 280
                          ] as CFDictionary) else { continue }
                    return NSImage(cgImage: thumbnail, size: .zero)
                }
                return nil
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            if let result { ThumbnailCache.shared.images.setObject(result, forKey: cacheKey, cost: 280 * 280 * 4) }
            image = result
        }
    }
}
