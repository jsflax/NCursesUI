import Foundation
import MachO

enum BinaryResolver {
    static func resolve(productName: String?) throws -> String {
        let buildDir = configDirectory()
        let candidates = try executableCandidates(in: buildDir)

        if let name = productName {
            let path = (buildDir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            throw NCUIError.productNotFound(productName: name, buildDir: buildDir)
        }

        switch candidates.count {
        case 0:
            throw NCUIError.binaryNotFound(buildDir: buildDir, candidates: [])
        case 1:
            return (buildDir as NSString).appendingPathComponent(candidates[0])
        default:
            throw NCUIError.ambiguousBinary(buildDir: buildDir, candidates: candidates)
        }
    }

    static func configDirectory() -> String {
        // Strategy 1: env var override (CI / non-standard layouts).
        if let dir = ProcessInfo.processInfo.environment["NCUITEST_BUILD_DIR"] {
            return dir
        }
        // Strategy 2: walk dyld images to find the .xctest bundle. `swift test`
        // dynamically loads `<Package>PackageTests.xctest/Contents/MacOS/<binary>`;
        // its grandparent (after dropping the .xctest wrapper) is the SwiftPM
        // build config dir where sibling executables live.
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cName)
            guard path.contains(".xctest/Contents/MacOS/") else { continue }
            let url = URL(fileURLWithPath: path)
            // path: .../<config>/<Tests>.xctest/Contents/MacOS/<binary>
            // walk: <binary> → MacOS → Contents → <Tests>.xctest → <config>
            return url
                .deletingLastPathComponent()  // MacOS
                .deletingLastPathComponent()  // Contents
                .deletingLastPathComponent()  // <Tests>.xctest
                .deletingLastPathComponent()  // <config>
                .path
        }
        // Strategy 3: Bundle.main's parent (works on Linux where the test
        // process IS the test executable, no .xctest wrapper).
        let url = Bundle.main.bundleURL
        return url.deletingLastPathComponent().path
    }

    static func executableCandidates(in dir: String) throws -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.compactMap { name -> String? in
            // Filter out test bundles, dylibs, swift module artifacts, hidden files.
            if name.hasPrefix(".") { return nil }
            if name.hasSuffix(".xctest") { return nil }
            if name.hasSuffix(".dylib") { return nil }
            if name.hasSuffix(".so") { return nil }
            if name.hasSuffix(".a") { return nil }
            if name.hasSuffix(".swiftmodule") { return nil }
            if name.hasSuffix(".swiftdoc") { return nil }
            if name.hasSuffix(".swiftsourceinfo") { return nil }
            if name.hasSuffix(".bundle") { return nil }
            if name.hasSuffix(".o") { return nil }
            if name.hasSuffix(".d") { return nil }
            if name.hasSuffix(".json") { return nil }
            if name.hasSuffix(".txt") { return nil }
            if name == "ModuleCache" || name == "description.json" { return nil }
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            guard fm.isExecutableFile(atPath: path) else { return nil }
            return name
        }.sorted()
    }
}
