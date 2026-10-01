import Darwin
import Foundation
import UCEdgeCore

/// An IPv4 or IPv6 socket address. IPv4 is sent as IPv4-mapped IPv6 on the dual-stack socket.
struct SocketAddress: Equatable, Sendable, CustomStringConvertible {
    private(set) var storage = sockaddr_storage()
    private(set) var length: socklen_t = 0

    init?(storage: sockaddr_storage, length: socklen_t) {
        guard storage.ss_family == sa_family_t(AF_INET) || storage.ss_family == sa_family_t(AF_INET6) else { return nil }
        self.storage = storage
        self.length = length
    }

    init?(addrinfo ai: UnsafePointer<addrinfo>) {
        guard let sa = ai.pointee.ai_addr else { return nil }
        var s = sockaddr_storage()
        withUnsafeMutableBytes(of: &s) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: Int(ai.pointee.ai_addrlen)))
        }
        self.init(storage: s, length: ai.pointee.ai_addrlen)
    }

    var isIPv4: Bool { storage.ss_family == sa_family_t(AF_INET) }

    /// The address as a sockaddr_in6, mapping IPv4 to ::ffff:a.b.c.d.
    var asIPv6: sockaddr_in6 {
        var s = storage
        if s.ss_family == sa_family_t(AF_INET6) {
            return withUnsafeBytes(of: &s) { $0.load(as: sockaddr_in6.self) }
        }
        let v4 = withUnsafeBytes(of: &s) { $0.load(as: sockaddr_in.self) }
        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = v4.sin_port
        withUnsafeMutableBytes(of: &v6.sin6_addr) { b in
            b[10] = 0xff; b[11] = 0xff
            withUnsafeBytes(of: v4.sin_addr) { src in for i in 0..<4 { b[12 + i] = src[i] } }
        }
        return v6
    }

    var port: UInt16 { UInt16(bigEndian: asIPv6.sin6_port) }

    var description: String {
        var a = asIPv6
        let bytes = withUnsafeBytes(of: &a.sin6_addr) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15]):\(port)"
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &a.sin6_addr, &buf, socklen_t(buf.count))
        let host = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "[\(host)]:\(port)"
    }

    static func == (a: SocketAddress, b: SocketAddress) -> Bool { a.description == b.description }
}

enum ReceiveResult {
    case datagram(Data, SocketAddress)
    case error(Int32)
    /// The socket was shut down on purpose (`shutdownAndClose`).
    case closed
}

/// Dual-stack UDP socket bound to [::]:port with IPV6_V6ONLY = 0.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let closeLock = NSLock()
    private var closed = false
    var isClosed: Bool { closeLock.withLock { closed } }

    init(port: UInt16) throws {
        let s = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw NetError.posix("socket", errno) }
        var off: Int32 = 0, on: Int32 = 1
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            close(s)
            throw NetError.posix("bind [::]:\(port)", e)
        }
        var bound = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        fd = s
        self.port = UInt16(bigEndian: bound.sin6_port)
    }

    /// Returns 0 or the errno of a failed sendto.
    func send(_ data: Data, to address: SocketAddress) -> Int32 {
        var dst = address.asIPv6
        let n = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &dst) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        return n < 0 ? errno : 0
    }

    /// Blocking receive.
    func receive() -> ReceiveResult {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            if isClosed { return .closed }
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                return isClosed ? .closed : .error(e)
            }
            if isClosed { return .closed }
            if n == 0 && len == 0 { return .error(ENOTCONN) }
            guard let addr = SocketAddress(storage: from, length: len) else { continue }
            return .datagram(Data(buf[0..<n]), addr)
        }
    }

    /// Stops receiving: wakes a blocked `receive()` with an empty datagram to ourselves (which
    /// then returns `.closed`). The descriptor itself is closed in `deinit`, once no thread can
    /// still be using it, so its number can't be reused under a reader (v1.3).
    func shutdownAndClose() {
        let first = closeLock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        var me = sockaddr_in6()
        me.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        me.sin6_family = sa_family_t(AF_INET6)
        me.sin6_port = port.bigEndian
        me.sin6_addr = in6addr_loopback
        var empty: UInt8 = 0
        _ = withUnsafePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, &empty, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    }

    deinit { close(fd) }
}

enum NetError: Error, CustomStringConvertible {
    case posix(String, Int32)
    case badPort(Int)
    var description: String {
        switch self {
        case let .posix(what, e): "\(what): \(String(cString: strerror(e)))"
        case let .badPort(p): "port \(p) is not a valid UDP port"
        }
    }
}

/// Resolves `peerHosts` (AF_UNSPEC, IPv4 first) and remembers the source of the latest
/// authenticated packet, which is preferred over DNS. Thread-safe.
final class PeerAddressBook: @unchecked Sendable {
    typealias Lookup = @Sendable (String, UInt16) -> ([SocketAddress], String?)
    private let lock = NSLock()
    private var resolved: [SocketAddress] = []
    private var learned: SocketAddress?
    let hosts: [String]
    let port: UInt16
    private let lookup: Lookup

    init(hosts: [String], port: UInt16, lookup: @escaping Lookup = PeerAddressBook.lookup) {
        self.hosts = hosts
        self.port = port
        self.lookup = lookup
    }

    var preferred: SocketAddress? { lock.withLock { learned ?? resolved.first } }
    var isLearned: Bool { lock.withLock { learned != nil } }

    func learn(_ a: SocketAddress) { lock.withLock { learned = a } }

    /// Blocking (getaddrinfo); call from a utility queue. Returns a note on failure.
    @discardableResult
    func resolve() -> String? {
        var v4: [SocketAddress] = [], v6: [SocketAddress] = []
        var failures: [String] = []
        for host in hosts {
            let (addrs, err) = lookup(host, port)
            if let err { failures.append("\(host): \(err)") }
            for a in addrs where !(v4 + v6).contains(a) {
                if a.isIPv4 { v4.append(a) } else { v6.append(a) }
            }
        }
        let all = v4 + v6
        lock.withLock { resolved = all }
        return all.isEmpty ? (failures.isEmpty ? "no addresses" : failures.joined(separator: "; ")) : nil
    }

    @Sendable static func lookup(host: String, port: UInt16) -> ([SocketAddress], String?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { return ([], String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(first) }
        var out: [SocketAddress] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let a = SocketAddress(addrinfo: ai) { out.append(a) }
            p = ai.pointee.ai_next
        }
        return (out.sorted { $0.isIPv4 && !$1.isIPv4 }, nil)
    }
}

/// Serial, non-blocking send path: callers enqueue; encoding, HMAC and sendto happen here.
final class NetSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "uc-edge.send", qos: .userInteractive)
    private var wire: WireSender
    private let key: WireKey
    private let socket: UDPSocket
    let peers: PeerAddressBook
    private let onError: @Sendable (Int32, SocketAddress?) -> Void
    private let onSent: @Sendable () -> Void

    /// Copied at init: `wire` itself is only touched on `queue`.
    let senderId: UInt64

    init(socket: UDPSocket, key: WireKey, peers: PeerAddressBook,
         onSent: @escaping @Sendable () -> Void, onError: @escaping @Sendable (Int32, SocketAddress?) -> Void) {
        self.socket = socket; self.key = key; self.peers = peers
        self.onSent = onSent; self.onError = onError
        let w = WireSender()
        wire = w
        senderId = w.senderId
    }

    /// `duplicateAfterMs`: send the identical datagram again (same seq) after this delay.
    func send(_ body: PacketBody, duplicateAfterMs: Double? = nil, to explicit: SocketAddress? = nil) {
        queue.async { [self] in
            let packet = wire.packet(body, wallMs: currentWallMs())
            let data = Wire.encode(packet, key: key)
            transmit(data, to: explicit)
            if let delay = duplicateAfterMs {
                queue.asyncAfter(deadline: .now() + .microseconds(Int(delay * 1000))) { [self] in
                    transmit(data, to: explicit)
                }
            }
        }
    }

    private func transmit(_ data: Data, to explicit: SocketAddress?) {
        guard let dst = explicit ?? peers.preferred else { onError(EDESTADDRREQ, nil); return }
        let err = socket.send(data, to: dst)
        if err == 0 { onSent() } else { onError(err, dst) }
    }
}
