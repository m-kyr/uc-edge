import ColorSync
import CoreGraphics
import Foundation
import UCEdgeCore

/// A configured edge display that is currently attached.
struct ResolvedDisplay: Equatable, Sendable {
    var uuid: UUID
    var id: CGDirectDisplayID
    var bounds: CGRect
}

enum Displays {
    /// Active displays whose UUID is in `uuids`, in config order. Read-only CoreGraphics queries.
    static func resolve(_ uuids: [UUID]) -> [ResolvedDisplay] {
        let active = activeDisplays()
        return uuids.compactMap { u in active.first { $0.uuid == u } }
    }

    static func activeDisplays() -> [ResolvedDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let s = CFUUIDCreateString(nil, cf) as String?,
                  let uuid = UUID(uuidString: s) else { return nil }
            return ResolvedDisplay(uuid: uuid, id: id, bounds: CGDisplayBounds(id))
        }
    }

    /// Registers a display reconfiguration callback; `onChange` runs after each completed change.
    /// Delivered on the main run loop.
    static func observeReconfiguration(_ onChange: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(CallbackBox(onChange)).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue().fn()
        }, box)
    }

    private final class CallbackBox: @unchecked Sendable {
        let fn: @Sendable () -> Void
        init(_ fn: @escaping @Sendable () -> Void) { self.fn = fn }
    }
}
