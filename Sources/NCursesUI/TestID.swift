import Foundation

extension View {
    public func testID(_ id: String) -> some View {
        TestIDView(id: id, content: self)
    }
}

public struct TestIDView<Content: View>: View {
    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }

    public var body: Content { content }
}
