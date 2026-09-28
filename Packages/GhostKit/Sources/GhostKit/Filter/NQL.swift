import Foundation

/// A Ghost NQL filter expression (the `filter=` query parameter).
///
/// ```swift
/// let f: NQL = .all([
///     .equals("status", "published"),
///     .in("tag", ["news", "updates"]),
///     .notIn("tag", ["hash-archive"]),
/// ])
/// f.rendered  // status:'published'+tag:['news','updates']+tag:-['hash-archive']
/// ```
public indirect enum NQL: Sendable, Equatable {
    case compare(field: String, op: Operator, value: Value)
    case all([NQL])
    case any([NQL])

    public enum Operator: String, Sendable {
        case equal = ""
        case notEqual = "-"
        case greater = ">"
        case greaterOrEqual = ">="
        case less = "<"
        case lessOrEqual = "<="
        case contains = "~"
        case notContains = "-~"
        case startsWith = "~^"
        case endsWith = "~$"
    }

    public enum Value: Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case list([String])
        case date(Date)
    }

    // MARK: Convenience

    public static func equals(_ field: String, _ value: String) -> NQL {
        .compare(field: field, op: .equal, value: .string(value))
    }
    public static func notEquals(_ field: String, _ value: String) -> NQL {
        .compare(field: field, op: .notEqual, value: .string(value))
    }
    public static func equals(_ field: String, _ value: Bool) -> NQL {
        .compare(field: field, op: .equal, value: .bool(value))
    }
    public static func `in`(_ field: String, _ values: [String]) -> NQL {
        .compare(field: field, op: .equal, value: .list(values))
    }
    public static func notIn(_ field: String, _ values: [String]) -> NQL {
        .compare(field: field, op: .notEqual, value: .list(values))
    }
    public static func isNull(_ field: String) -> NQL {
        .compare(field: field, op: .equal, value: .null)
    }
    public static func isNotNull(_ field: String) -> NQL {
        .compare(field: field, op: .notEqual, value: .null)
    }

    // MARK: Rendering

    public var rendered: String { render(nested: false) }

    private func render(nested: Bool) -> String {
        switch self {
        case let .compare(field, op, value):
            return "\(field):\(op.rawValue)\(Self.render(value))"
        case let .all(parts):
            return Self.join(parts, separator: "+", nested: nested)
        case let .any(parts):
            return Self.join(parts, separator: ",", nested: nested)
        }
    }

    private static func join(_ parts: [NQL], separator: String, nested: Bool) -> String {
        let rendered = parts.map { $0.render(nested: true) }.filter { !$0.isEmpty }
        guard !rendered.isEmpty else { return "" }
        if rendered.count == 1 { return rendered[0] }
        let body = rendered.joined(separator: separator)
        return nested ? "(\(body))" : body
    }

    private static func render(_ value: Value) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .list(let items): return "[" + items.map(quote).joined(separator: ",") + "]"
        case .date(let d): return quote(d.formatted(dateStyle))
        }
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// `yyyy-MM-dd HH:mm:ss` in UTC, the form NQL date comparisons accept.
    private static let dateStyle = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day()
        .dateSeparator(.dash)
        .dateTimeSeparator(.space)
        .time(includingFractionalSeconds: false)
        .timeSeparator(.colon)
}
