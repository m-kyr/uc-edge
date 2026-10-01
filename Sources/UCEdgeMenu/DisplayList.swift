import ColorSync
import CoreGraphics
import Foundation

/// `--displays`: what goes into config.json's `edgeDisplays`.
enum DisplayList {
    static func text() -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "no active displays" }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "no active displays" }
        var lines = ["Active displays (global points; y grows downward, the main display's top-left is 0,0):"]
        for id in ids.prefix(Int(count)) {
            let b = CGDisplayBounds(id)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)
                .flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? } ?? "unknown"
            let tags = [CGDisplayIsMain(id) != 0 ? "main" : nil, CGDisplayIsBuiltin(id) != 0 ? "built-in" : nil]
                .compactMap { $0 }
            lines.append(String(format: "  %@  x %.0f…%.0f  y %.0f…%.0f  (%.0f×%.0f)%@", uuid,
                                b.minX, b.maxX, b.minY, b.maxY, b.width, b.height,
                                tags.isEmpty ? "" : "  " + tags.joined(separator: ", ")))
        }
        lines.append("Top edge = smallest y, bottom edge = largest y.")
        return lines.joined(separator: "\n")
    }
}
