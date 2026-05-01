import Foundation
import os
import NCUITestProtocol

public final class NCUIApplication: @unchecked Sendable {
    public let label: String
    public let productName: String?
    public var launchArguments: [String]
    public var launchEnvironment: [String: String]

    var probeClient: NCUIProbeClient?
    var socketPath: String?
    var resolvedBinary: String?
    var tmuxDriver: NCUITmuxDriver?
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .notLaunched)

    public enum State: Sendable {
        case notLaunched
        case launching
        case running
        case terminated
    }

    public init(
        label: String = "default",
        productName: String? = nil,
        launchArguments: [String] = [],
        launchEnvironment: [String: String] = [:]
    ) {
        self.label = label
        self.productName = productName
        self.launchArguments = launchArguments
        self.launchEnvironment = launchEnvironment
    }

    public var state: State {
        stateLock.withLock { $0 }
    }

    private func setState(_ new: State) {
        stateLock.withLock { $0 = new }
    }

    public func launch(
        handshakeTimeout: TimeInterval = 10,
        terminalSize: (cols: Int, rows: Int) = (240, 60)
    ) async throws {
        let canStart = stateLock.withLock { (current: inout State) -> Bool in
            guard current == .notLaunched else { return false }
            current = .launching
            return true
        }
        guard canStart else { throw NCUIError.alreadyLaunched }

        let binary = try BinaryResolver.resolve(productName: productName)
        self.resolvedBinary = binary

        let socketName = "ncuitest-\(getpid())-\(label)-\(UUID().uuidString.prefix(8)).sock"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(socketName)
        self.socketPath = path
        try? FileManager.default.removeItem(atPath: path)

        var env = launchEnvironment
        env["NCUITEST_SOCKET"] = path

        let sessionName = "ncuitest-\(getpid())-\(label)-\(UUID().uuidString.prefix(6))"
        let driver = NCUITmuxDriver(sessionName: sessionName)
        let cmd = ([binary] + launchArguments).map(Self.shellQuote).joined(separator: " ")
        _ = try driver.startSession(
            env: env,
            command: cmd,
            width: terminalSize.cols,
            height: terminalSize.rows
        )
        self.tmuxDriver = driver

        let client = NCUIProbeClient(socketPath: path)
        do {
            try await client.waitUntilReady(timeout: handshakeTimeout)
        } catch {
            driver.kill()
            setState(.terminated)
            if let e = error as? NCUIError, case .probeHandshakeTimeout = e {
                throw e
            }
            throw NCUIError.probeConnectFailed(socketPath: path, underlying: error)
        }

        let response = try await client.send(.ping)
        guard case .probeInfo(let info) = response.result else {
            throw NCUIError.probeError("unexpected ping response: \(response.result)")
        }
        guard info.protocolVersion == NCUIWireProtocol.version else {
            throw NCUIError.incompatibleProbeVersion(
                client: NCUIWireProtocol.version,
                server: info.protocolVersion
            )
        }

        self.probeClient = client
        setState(.running)
    }

    public func terminate() {
        let wasRunning = stateLock.withLock { (current: inout State) -> Bool in
            let was = current == .running || current == .launching
            current = .terminated
            return was
        }
        guard wasRunning else { return }

        probeClient?.close()
        tmuxDriver?.kill()
        if let path = socketPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    public func ping() async throws -> NCUIProbeInfo {
        guard let client = probeClient else { throw NCUIError.notLaunched }
        let response = try await client.send(.ping)
        guard case .probeInfo(let info) = response.result else {
            throw NCUIError.probeError("unexpected ping response: \(response.result)")
        }
        return info
    }

    public func sendRaw(_ request: NCUIRequest) async throws -> NCUIResponse {
        guard let client = probeClient else { throw NCUIError.notLaunched }
        return try await client.send(request)
    }

    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "." || $0 == "-" || $0 == "_" || $0 == "=" }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
