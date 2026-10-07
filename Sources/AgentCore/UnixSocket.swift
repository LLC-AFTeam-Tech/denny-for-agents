import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Minimal blocking AF_UNIX stream socket shared by the hook (client) and
/// the app (server). Messages are JSON lines.
public final class UnixSocket {
    public static let maxLineBytes = 1 << 20

    public let fd: Int32
    private var buffer = Data()
    private var isClosed = false
    private let lock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    /// Safe to call more than once: a second close must never hit an fd
    /// number the OS has already handed to someone else.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        _ = shutdown(fd, Int32(SHUT_RDWR))
        _ = systemClose(fd)
    }

    public static func connect(path: String) -> UnixSocket? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return nil }
        guard var address = makeAddress(path: path) else {
            _ = systemClose(fd)
            return nil
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            _ = systemClose(fd)
            return nil
        }
        let connection = UnixSocket(fd: fd)
        connection.disableSigPipe()
        return connection
    }

    /// Binds and listens, replacing a stale socket file. The directory is
    /// created with 0700 so only this user can talk to Denny.
    public static func listen(path: String) -> UnixSocket? {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(directory, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return nil }
        guard var address = makeAddress(path: path) else {
            _ = systemClose(fd)
            return nil
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, systemListen(fd, 16) == 0 else {
            _ = systemClose(fd)
            return nil
        }
        _ = chmod(path, 0o600)
        return UnixSocket(fd: fd)
    }

    /// TCP listener on 127.0.0.1 only -- never on all interfaces.
    public static func listenLoopback(port: UInt16) -> UnixSocket? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = loopbackAddress(port: port)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, systemListen(fd, 16) == 0 else {
            _ = systemClose(fd)
            return nil
        }
        return UnixSocket(fd: fd)
    }

    public static func connectLoopback(port: UInt16) -> UnixSocket? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return nil }
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            _ = systemClose(fd)
            return nil
        }
        let connection = UnixSocket(fd: fd)
        connection.disableSigPipe()
        return connection
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        return address
    }

    public func accept() -> UnixSocket? {
        let client = systemAccept(fd, nil, nil)
        guard client >= 0 else { return nil }
        let connection = UnixSocket(fd: client)
        connection.disableSigPipe()
        return connection
    }

    public func setReceiveTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The other side hung up (a hook killed by its timeout, say). A write
    /// would still "succeed" into the kernel buffer and be lost.
    public var peerHasClosed: Bool {
        var byte: UInt8 = 0
        let received = recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
        return received == 0 || (received < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    @discardableResult
    public func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let sent = send(fd, pointer, remaining, 0)
                if sent <= 0 { return false }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
            return true
        }
    }

    /// Next line without the trailing newline; nil on EOF, timeout or a
    /// line longer than `maxLineBytes`.
    public func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            if buffer.count > Self.maxLineBytes { return nil }
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func disableSigPipe() {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func makeAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.listen(fd, backlog)
    #else
    return Glibc.listen(fd, backlog)
    #endif
}

private func systemAccept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    #if canImport(Darwin)
    return Darwin.accept(fd, address, length)
    #else
    return Glibc.accept(fd, address, length)
    #endif
}
