import Foundation

public enum TUILog {
    #if DEBUG
    nonisolated(unsafe) private static var logFile: UnsafeMutablePointer<FILE>? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trader/tui.log").path
        return fopen(path, "w")
    }()

    /// Set a custom log file path (for tests).
    public static func setLogPath(_ path: String) {
        if let f = logFile { fclose(f) }
        logFile = fopen(path, "w")
    }

    @inlinable @inline(__always)
    public static func debug(_ msg: @autoclosure () -> String) {
        _write("DEBUG", msg())
    }

    @inlinable @inline(__always)
    public static func articles(_ msg: @autoclosure () -> String) {
        _write("ARTICLES", msg())
    }
    
    @inlinable @inline(__always)
    public static func signals(_ msg: @autoclosure () -> String) {
        _write("SIGNALS", msg())
    }
    
    @inlinable @inline(__always)
    public static func render(_ msg: @autoclosure () -> String) {
        _write("RENDER", msg())
    }

    @inlinable @inline(__always)
    public static func query(_ msg: @autoclosure () -> String) {
        _write("QUERY", msg())
    }

    @inlinable @inline(__always)
    public static func input(_ msg: @autoclosure () -> String) {
        _write("INPUT", msg())
    }

    @inlinable @inline(__always)
    public static func observe(_ msg: @autoclosure () -> String) {
        _write("OBSERVE", msg())
    }

    @inlinable @inline(__always)
    public static func error(_ msg: @autoclosure () -> String) {
        _write("ERROR", msg())
    }

    @usableFromInline
    static func _write(_ category: String, _ msg: String) {
        guard let f = logFile else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let color = _color(category)
        fputs("\u{1b}[90m[\(ts)]\u{1b}[0m \(color)[\(category)]\u{1b}[0m \(msg)\n", f)
        fflush(f)
    }

    @usableFromInline
    static func _color(_ category: String) -> String {
        switch category {
        case "DEBUG":    "\u{1b}[90m"   // gray
        case "RENDER":   "\u{1b}[36m"   // cyan
        case "QUERY":    "\u{1b}[34m"   // blue
        case "INPUT":    "\u{1b}[32m"   // green
        case "OBSERVE":  "\u{1b}[33m"   // yellow
        case "ERROR":    "\u{1b}[31;1m" // bold red
        case "SIGNALS": "\u{1b}[93m"   // magenta
        case "ARTICLES": "\u{1b}[35m"   // magenta
        default:         "\u{1b}[0m"    // reset
        }
    }
    #else
    @inlinable @inline(__always) static func debug(_ msg: @autoclosure () -> String) {}
    @inlinable @inline(__always) static func render(_ msg: @autoclosure () -> String) {}
    @inlinable @inline(__always) static func query(_ msg: @autoclosure () -> String) {}
    @inlinable @inline(__always) static func input(_ msg: @autoclosure () -> String) {}
    @inlinable @inline(__always) static func observe(_ msg: @autoclosure () -> String) {}
    @inlinable @inline(__always) static func error(_ msg: @autoclosure () -> String) {}
    #endif
}
