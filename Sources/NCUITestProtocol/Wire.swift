import Foundation

public enum NCUIWireProtocol {
    public static let version: Int = 1
}

public struct NCURect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = NCURect(x: 0, y: 0, width: 0, height: 0)

    public func contains(_ other: NCURect) -> Bool {
        other.x >= x
            && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
}

public enum NCUIColorSlot: String, Codable, Sendable {
    case normal, dim, selected
    case red, green, yellow, blue, magenta, cyan, white
    case purple, gold, teal
}

public struct NCUIRGB: Codable, Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct NCUIAttributes: Codable, Equatable, Sendable {
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var inverted: Bool

    public init(bold: Bool = false, dim: Bool = false, italic: Bool = false, inverted: Bool = false) {
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.inverted = inverted
    }

    public static let none = NCUIAttributes()
}

public struct NCUIRunSnapshot: Codable, Equatable, Sendable {
    public var content: String
    public var color: NCUIColorSlot
    public var palettePair: Int32?
    public var attributes: NCUIAttributes

    public init(content: String, color: NCUIColorSlot, palettePair: Int32?, attributes: NCUIAttributes) {
        self.content = content
        self.color = color
        self.palettePair = palettePair
        self.attributes = attributes
    }
}

public struct NCUINodeSnapshot: Codable, Sendable {
    public var nodeId: UInt64
    public var typeName: String
    public var testID: String?
    public var frame: NCURect
    public var content: String?
    public var runs: [NCUIRunSnapshot]?
    public var attributes: NCUIAttributes
    public var isFocused: Bool
    public var isFocusable: Bool
    public var children: [NCUINodeSnapshot]

    public init(
        nodeId: UInt64,
        typeName: String,
        testID: String?,
        frame: NCURect,
        content: String?,
        runs: [NCUIRunSnapshot]?,
        attributes: NCUIAttributes,
        isFocused: Bool,
        isFocusable: Bool,
        children: [NCUINodeSnapshot]
    ) {
        self.nodeId = nodeId
        self.typeName = typeName
        self.testID = testID
        self.frame = frame
        self.content = content
        self.runs = runs
        self.attributes = attributes
        self.isFocused = isFocused
        self.isFocusable = isFocusable
        self.children = children
    }
}

public enum NCUINodeRef: Codable, Sendable {
    case nodeId(UInt64)
    case testID(String)
    case query(NCUIQuerySpec)
}

public struct NCUIQuerySpec: Codable, Sendable {
    public var typeName: String?
    public var testID: String?
    public var labelEquals: String?
    public var labelContains: String?
    public var labelMatches: String?
    public var firstMatch: Bool

    public init(
        typeName: String? = nil,
        testID: String? = nil,
        labelEquals: String? = nil,
        labelContains: String? = nil,
        labelMatches: String? = nil,
        firstMatch: Bool = false
    ) {
        self.typeName = typeName
        self.testID = testID
        self.labelEquals = labelEquals
        self.labelContains = labelContains
        self.labelMatches = labelMatches
        self.firstMatch = firstMatch
    }
}

public enum NCUIKeyCode: String, Codable, Sendable {
    case enter, escape, tab, backspace, delete, space
    case up, down, left, right
    case home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

public struct NCUIKeyModifiers: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = NCUIKeyModifiers(rawValue: 1 << 0)
    public static let control = NCUIKeyModifiers(rawValue: 1 << 1)
    public static let option = NCUIKeyModifiers(rawValue: 1 << 2)
}

public enum NCUIKeySpec: Codable, Sendable {
    case char(Character)
    case code(NCUIKeyCode, modifiers: NCUIKeyModifiers)

    enum CodingKeys: String, CodingKey { case kind, value, modifiers }
    enum Kind: String, Codable { case char, code }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .char(let ch):
            try c.encode(Kind.char, forKey: .kind)
            try c.encode(String(ch), forKey: .value)
        case .code(let code, let mods):
            try c.encode(Kind.code, forKey: .kind)
            try c.encode(code, forKey: .value)
            try c.encode(mods.rawValue, forKey: .modifiers)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .char:
            let s = try c.decode(String.self, forKey: .value)
            guard let ch = s.first, s.count == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "expected one character, got \(s.count)")
            }
            self = .char(ch)
        case .code:
            let code = try c.decode(NCUIKeyCode.self, forKey: .value)
            let raw = try c.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0
            self = .code(code, modifiers: NCUIKeyModifiers(rawValue: raw))
        }
    }
}

public struct NCUIPaletteRGBMap: Codable, Sendable {
    public var byColorSlot: [NCUIColorSlot: NCUIRGB]
    public var byPalettePair: [Int32: NCUIRGB]

    public init(byColorSlot: [NCUIColorSlot: NCUIRGB] = [:], byPalettePair: [Int32: NCUIRGB] = [:]) {
        self.byColorSlot = byColorSlot
        self.byPalettePair = byPalettePair
    }

    enum CodingKeys: String, CodingKey { case byColorSlot, byPalettePair }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let slotMap = Dictionary(uniqueKeysWithValues: byColorSlot.map { ($0.key.rawValue, $0.value) })
        try c.encode(slotMap, forKey: .byColorSlot)
        let pairMap = Dictionary(uniqueKeysWithValues: byPalettePair.map { (String($0.key), $0.value) })
        try c.encode(pairMap, forKey: .byPalettePair)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let slotRaw = try c.decode([String: NCUIRGB].self, forKey: .byColorSlot)
        var slotMap: [NCUIColorSlot: NCUIRGB] = [:]
        for (k, v) in slotRaw {
            if let s = NCUIColorSlot(rawValue: k) { slotMap[s] = v }
        }
        let pairRaw = try c.decode([String: NCUIRGB].self, forKey: .byPalettePair)
        var pairMap: [Int32: NCUIRGB] = [:]
        for (k, v) in pairRaw {
            if let i = Int32(k) { pairMap[i] = v }
        }
        self.byColorSlot = slotMap
        self.byPalettePair = pairMap
    }
}

public struct NCUICell: Codable, Sendable {
    public var character: String
    public var fg: NCUIRGB?
    public var bg: NCUIRGB?
    public var attributes: NCUIAttributes

    public init(character: String, fg: NCUIRGB?, bg: NCUIRGB?, attributes: NCUIAttributes) {
        self.character = character
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }
}

public struct NCUICellGrid: Codable, Sendable {
    public var rows: Int
    public var cols: Int
    public var cells: [NCUICell]
    public var cursor: NCURect?
    public var palette: NCUIPaletteRGBMap

    public init(rows: Int, cols: Int, cells: [NCUICell], cursor: NCURect?, palette: NCUIPaletteRGBMap) {
        self.rows = rows
        self.cols = cols
        self.cells = cells
        self.cursor = cursor
        self.palette = palette
    }

    public func cellAt(row: Int, col: Int) -> NCUICell? {
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return cells[row * cols + col]
    }
}

public struct NCUIProbeInfo: Codable, Sendable {
    public var protocolVersion: Int
    public var frameworkVersion: String
    public var frame: UInt64

    public init(protocolVersion: Int, frameworkVersion: String, frame: UInt64) {
        self.protocolVersion = protocolVersion
        self.frameworkVersion = frameworkVersion
        self.frame = frame
    }
}

public enum NCUIRequest: Codable, Sendable {
    case ping
    case tree
    case query(NCUIQuerySpec)
    case awaitPredicate(NCUIQuerySpec, timeoutMs: Int)
    case setFocus(NCUINodeRef)
    case scrollToMakeVisible(NCUINodeRef)
    case sendKey(NCUIKeySpec)
    case sendKeys(String)
    case snapshot

    enum CodingKeys: String, CodingKey { case method, spec, timeoutMs, ref, key, text }
    enum Method: String, Codable {
        case ping, tree, query, awaitPredicate, setFocus, scrollToMakeVisible, sendKey, sendKeys, snapshot
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping:
            try c.encode(Method.ping, forKey: .method)
        case .tree:
            try c.encode(Method.tree, forKey: .method)
        case .query(let spec):
            try c.encode(Method.query, forKey: .method)
            try c.encode(spec, forKey: .spec)
        case .awaitPredicate(let spec, let timeoutMs):
            try c.encode(Method.awaitPredicate, forKey: .method)
            try c.encode(spec, forKey: .spec)
            try c.encode(timeoutMs, forKey: .timeoutMs)
        case .setFocus(let ref):
            try c.encode(Method.setFocus, forKey: .method)
            try c.encode(ref, forKey: .ref)
        case .scrollToMakeVisible(let ref):
            try c.encode(Method.scrollToMakeVisible, forKey: .method)
            try c.encode(ref, forKey: .ref)
        case .sendKey(let key):
            try c.encode(Method.sendKey, forKey: .method)
            try c.encode(key, forKey: .key)
        case .sendKeys(let text):
            try c.encode(Method.sendKeys, forKey: .method)
            try c.encode(text, forKey: .text)
        case .snapshot:
            try c.encode(Method.snapshot, forKey: .method)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let method = try c.decode(Method.self, forKey: .method)
        switch method {
        case .ping: self = .ping
        case .tree: self = .tree
        case .query:
            self = .query(try c.decode(NCUIQuerySpec.self, forKey: .spec))
        case .awaitPredicate:
            self = .awaitPredicate(
                try c.decode(NCUIQuerySpec.self, forKey: .spec),
                timeoutMs: try c.decode(Int.self, forKey: .timeoutMs)
            )
        case .setFocus:
            self = .setFocus(try c.decode(NCUINodeRef.self, forKey: .ref))
        case .scrollToMakeVisible:
            self = .scrollToMakeVisible(try c.decode(NCUINodeRef.self, forKey: .ref))
        case .sendKey:
            self = .sendKey(try c.decode(NCUIKeySpec.self, forKey: .key))
        case .sendKeys:
            self = .sendKeys(try c.decode(String.self, forKey: .text))
        case .snapshot:
            self = .snapshot
        }
    }
}

public enum NCUIResponseBody: Codable, Sendable {
    case ok
    case probeInfo(NCUIProbeInfo)
    case tree(NCUINodeSnapshot)
    case nodes([NCUINodeSnapshot])
    case node(NCUINodeSnapshot)
    case snapshot(NCUICellGrid, NCUINodeSnapshot)
    case error(String)

    enum CodingKeys: String, CodingKey { case kind, info, tree, nodes, node, grid, message }
    enum Kind: String, Codable {
        case ok, probeInfo, tree, nodes, node, snapshot, error
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try c.encode(Kind.ok, forKey: .kind)
        case .probeInfo(let info):
            try c.encode(Kind.probeInfo, forKey: .kind)
            try c.encode(info, forKey: .info)
        case .tree(let n):
            try c.encode(Kind.tree, forKey: .kind)
            try c.encode(n, forKey: .tree)
        case .nodes(let ns):
            try c.encode(Kind.nodes, forKey: .kind)
            try c.encode(ns, forKey: .nodes)
        case .node(let n):
            try c.encode(Kind.node, forKey: .kind)
            try c.encode(n, forKey: .node)
        case .snapshot(let grid, let tree):
            try c.encode(Kind.snapshot, forKey: .kind)
            try c.encode(grid, forKey: .grid)
            try c.encode(tree, forKey: .tree)
        case .error(let msg):
            try c.encode(Kind.error, forKey: .kind)
            try c.encode(msg, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .ok: self = .ok
        case .probeInfo:
            self = .probeInfo(try c.decode(NCUIProbeInfo.self, forKey: .info))
        case .tree:
            self = .tree(try c.decode(NCUINodeSnapshot.self, forKey: .tree))
        case .nodes:
            self = .nodes(try c.decode([NCUINodeSnapshot].self, forKey: .nodes))
        case .node:
            self = .node(try c.decode(NCUINodeSnapshot.self, forKey: .node))
        case .snapshot:
            let grid = try c.decode(NCUICellGrid.self, forKey: .grid)
            let tree = try c.decode(NCUINodeSnapshot.self, forKey: .tree)
            self = .snapshot(grid, tree)
        case .error:
            self = .error(try c.decode(String.self, forKey: .message))
        }
    }
}

public struct NCUIResponse: Codable, Sendable {
    public var frame: UInt64
    public var result: NCUIResponseBody

    public init(frame: UInt64, result: NCUIResponseBody) {
        self.frame = frame
        self.result = result
    }
}

public enum NCUIWire {
    public static func encode(_ request: NCUIRequest) throws -> Data {
        let payload = try JSONEncoder().encode(request)
        return frame(payload)
    }

    public static func encode(_ response: NCUIResponse) throws -> Data {
        let payload = try JSONEncoder().encode(response)
        return frame(payload)
    }

    public static func frame(_ payload: Data) -> Data {
        var len = UInt32(payload.count).bigEndian
        var out = Data()
        out.append(Data(bytes: &len, count: 4))
        out.append(payload)
        return out
    }

    public static func decodeRequest(_ payload: Data) throws -> NCUIRequest {
        try JSONDecoder().decode(NCUIRequest.self, from: payload)
    }

    public static func decodeResponse(_ payload: Data) throws -> NCUIResponse {
        try JSONDecoder().decode(NCUIResponse.self, from: payload)
    }
}
