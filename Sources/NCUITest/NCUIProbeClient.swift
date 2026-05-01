import Foundation
import NCUITestProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Connection-per-request unix-socket client. Concurrent calls do not block
/// each other: each `send` opens its own short-lived connection. The probe
/// server handles each connection on a dedicated background thread.
public final class NCUIProbeClient: @unchecked Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Wait for the socket to become connectable, with retry. Used at launch
    /// time to detect probe readiness. Doesn't keep the connection open.
    public func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let fd = try? openConnection() {
                Darwin.close(fd)
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NCUIError.probeHandshakeTimeout(socketPath: socketPath)
    }

    public func send(_ request: NCUIRequest) async throws -> NCUIResponse {
        let path = self.socketPath
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fd = try openConnectionStatic(socketPath: path)
                    defer { Darwin.close(fd) }
                    let frame = try NCUIWire.encode(request)
                    try writeAllStatic(fd: fd, data: frame)
                    let response = try readResponseStatic(fd: fd)
                    cont.resume(returning: response)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Closes any internal state. Connection-per-request, so this is just a
    /// signal that no further calls should be made — currently a no-op.
    public func close() {}

    private func openConnection() throws -> Int32 {
        return try openConnectionStatic(socketPath: socketPath)
    }
}

private func openConnectionStatic(socketPath: String) throws -> Int32 {
    let s = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
    guard s >= 0 else { throw NCUIError.ioError("socket() errno=\(errno)") }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= pathCapacity else {
        Darwin.close(s)
        throw NCUIError.ioError("socket path too long")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { p in
            _ = pathBytes.withUnsafeBufferPointer { src in
                memcpy(p, src.baseAddress, src.count)
            }
        }
    }
    let result = withUnsafePointer(to: &addr) { p -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            Darwin.connect(s, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 {
        let e = errno
        Darwin.close(s)
        throw NCUIError.ioError("connect errno=\(e)")
    }
    return s
}

private func writeAllStatic(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            throw NCUIError.ioError("empty write buffer")
        }
        var written = 0
        while written < data.count {
            let n = write(fd, base.advanced(by: written), data.count - written)
            if n < 0 {
                if errno == EINTR { continue }
                throw NCUIError.ioError("write errno=\(errno)")
            }
            written += n
        }
    }
}

private func readResponseStatic(fd: Int32) throws -> NCUIResponse {
    var lenBuf = [UInt8](repeating: 0, count: 4)
    try readExactStatic(fd: fd, into: &lenBuf, count: 4)
    let len = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16)
        | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
    if len > 16 * 1024 * 1024 {
        throw NCUIError.ioError("oversized response: \(len)")
    }
    var payload = [UInt8](repeating: 0, count: Int(len))
    try readExactStatic(fd: fd, into: &payload, count: Int(len))
    return try NCUIWire.decodeResponse(Data(payload))
}

private func readExactStatic(fd: Int32, into buf: inout [UInt8], count: Int) throws {
    try buf.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else {
            throw NCUIError.ioError("empty read buffer")
        }
        var got = 0
        while got < count {
            let n = read(fd, base.advanced(by: got), count - got)
            if n == 0 { throw NCUIError.probeDisconnected }
            if n < 0 {
                if errno == EINTR { continue }
                throw NCUIError.ioError("read errno=\(errno)")
            }
            got += n
        }
    }
}
