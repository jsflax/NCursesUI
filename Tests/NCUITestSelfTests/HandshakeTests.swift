import Testing
import Foundation
@testable import NCUITest
import NCUITestProtocol

@Suite("NCUITest probe handshake", .serialized)
struct HandshakeTests {
    @Test("launch + ping round-trips with matching protocol version")
    func pingRoundTrip() async throws {
        let app = NCUIApplication(label: "wd-ping", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        let info = try await app.ping()
        #expect(info.protocolVersion == NCUIWireProtocol.version)
        #expect(!info.frameworkVersion.isEmpty)

        let nextInfo = try await app.ping()
        #expect(nextInfo.frame >= info.frame)

        app.terminate()
    }

    @Test("setFocus on a missing testID returns a clear error")
    func setFocusMissingTarget() async throws {
        let app = NCUIApplication(label: "wd-stub", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        let response = try await app.sendRaw(.setFocus(.testID("nonexistent-id-xyz")))
        if case .error(let msg) = response.result {
            #expect(msg.contains("no node matched") || msg.contains("not ProbeFocusable"))
        } else {
            Issue.record("expected error response, got \(response.result)")
        }

        app.terminate()
    }
}
