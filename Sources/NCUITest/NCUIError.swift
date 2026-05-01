import Foundation

public enum NCUIError: Error, CustomStringConvertible {
    case binaryNotFound(buildDir: String, candidates: [String])
    case ambiguousBinary(buildDir: String, candidates: [String])
    case productNotFound(productName: String, buildDir: String)
    case launchFailed(reason: String)
    case probeHandshakeTimeout(socketPath: String)
    case probeConnectFailed(socketPath: String, underlying: Error)
    case incompatibleProbeVersion(client: Int, server: Int)
    case ioError(String)
    case probeError(String)
    case probeDisconnected
    case waitTimeout(spec: String, timeout: TimeInterval, artifactsDir: String?)
    case elementNotFound(spec: String, artifactsDir: String?)
    case unsupportedOnPlatform(String)
    case tmuxError(String)
    case alreadyLaunched
    case notLaunched

    public var description: String {
        switch self {
        case .binaryNotFound(let dir, let candidates):
            return "no executable product found in \(dir) (candidates considered: \(candidates.joined(separator: ", ")))"
        case .ambiguousBinary(let dir, let candidates):
            return "multiple executable products found in \(dir) — disambiguate with NCUIApplication(productName:). Candidates: \(candidates.joined(separator: ", "))"
        case .productNotFound(let p, let dir):
            return "product '\(p)' not found in \(dir) — did you add it as a dependency of your test target?"
        case .launchFailed(let r):
            return "launch failed: \(r)"
        case .probeHandshakeTimeout(let p):
            return "probe handshake timed out at \(p)"
        case .probeConnectFailed(let p, let e):
            return "probe connect failed at \(p): \(e)"
        case .incompatibleProbeVersion(let c, let s):
            return "incompatible probe protocol version: client=\(c) server=\(s)"
        case .ioError(let m):
            return "I/O error: \(m)"
        case .probeError(let m):
            return "probe error: \(m)"
        case .probeDisconnected:
            return "probe disconnected"
        case .waitTimeout(let spec, let t, let dir):
            let suffix = dir.map { " — artifacts at \($0)" } ?? ""
            return "wait timed out (\(t)s) for \(spec)\(suffix)"
        case .elementNotFound(let spec, let dir):
            let suffix = dir.map { " — artifacts at \($0)" } ?? ""
            return "element not found: \(spec)\(suffix)"
        case .unsupportedOnPlatform(let m):
            return "unsupported on this platform: \(m)"
        case .tmuxError(let m):
            return "tmux: \(m)"
        case .alreadyLaunched:
            return "application already launched"
        case .notLaunched:
            return "application not launched"
        }
    }
}
