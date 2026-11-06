import Foundation
import MCP

extension EditMaxTools {
    /// An argument that is an object of numbers (a compressor's or limiter's settings); nil when absent or null.
    static func numbers(_ v: Value?, _ key: String) throws -> [String: Double]? {
        guard let v else { return nil }
        if case .null = v { return nil }
        guard let o = v.objectValue else { throw MCPError.invalidParams("'\(key)' must be an object of numbers, e.g. {\"ceiling\": -1}") }
        var out: [String: Double] = [:]
        for (k, x) in o {
            guard let n = x.doubleValue ?? x.intValue.map(Double.init) else { throw MCPError.invalidParams("'\(key).\(k)' must be a number") }
            out[k] = n
        }
        return out
    }
}
