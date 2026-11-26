// JSONValue.swift
// HAo Live — lenient JSON access for platform APIs.
// Platform responses drift (ids arrive as Int or String, fields appear
// and disappear); this parses once via JSONSerialization and lets each
// adapter read what it needs without a Codable struct per endpoint.

import Foundation

/// A JSON value read leniently: numbers and numeric strings coerce,
// missing keys read as null instead of crashing the decode.
enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let n as NSNumber:
            // JSONSerialization returns __NSCFBoolean (objCType "c")
            // for true/false and NSNumber for numbers — but NSNumber
            // 0/1 also bridges to Bool, so a `case as Bool` here would
            // swallow the numbers 0 and 1 (live_status, error codes,
            // category ids). Distinguish by objCType instead.
            if String(cString: n.objCType) == "c" {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let b as Bool:
            self = .bool(b)
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init))
        default:
            self = .null
        }
    }

    /// Parse JSON data; returns nil only when the data is not JSON at all.
    static func parse(_ data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else {
            return nil
        }
        return JSONValue(raw)
    }

    subscript(key: String) -> JSONValue {
        if case .object(let dict) = self, let value = dict[key] {
            return value
        }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) {
            return items[index]
        }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var stringValue: String? {
        switch self {
        case .string(let s):
            return s
        case .number(let n):
            // Whole numbers without a decimal point ("9263298", not "9263298.0").
            if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 9_007_199_254_740_992 {
                return String(Int(n))
            }
            return String(n)
        case .bool(let b):
            return b ? "true" : "false"
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let n):
            return Int(n)
        case .string(let s):
            return Int(s)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n):
            return n
        case .string(let s):
            return Double(s)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b):
            return b
        case .number(let n):
            return n != 0
        case .string(let s):
            return s == "1" || s.lowercased() == "true"
        default:
            return nil
        }
    }

    var arrayValue: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var objectValue: [String: JSONValue] {
        if case .object(let dict) = self { return dict }
        return [:]
    }
}

/// Small text helpers for platform payloads.
enum HaoText {
    /// First non-empty string among the candidates; nil when all are
    /// missing or empty. Platform payloads often carry an empty string
    /// where a field is absent, which would otherwise block a `??`
    /// fallback to the next candidate.
    static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { !($0 ?? "").isEmpty } ?? nil
    }

    /// Strip HTML tags such as the <em class="keyword"> Bilibili wraps
    /// around search keywords in titles and anchor names.
    static func stripTags(_ text: String) -> String {
        var out = ""
        var inTag = false
        for ch in text {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Extract a balanced {...} JSON object starting at the given index.
    /// Braces inside strings are skipped; the scan assumes the JSON text
    /// itself is not backslash-escaped (plain HTML embedding).
    static func extractJSONObject(_ text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// All balanced {...} objects following every occurrence of
    /// `marker`, unescaped. Used when a page embeds the same store
    /// twice — Douyin's room page has an empty initial roomStore
    /// followed by the hydrated one; the caller picks the populated
    /// copy.
    static func extractAllEscapedJSONObjects(_ text: String, marker: String) -> [String] {
        var results: [String] = []
        var searchFrom = text.startIndex
        while let markerRange = text[searchFrom...].range(of: marker) {
            let tail = String(text[markerRange.lowerBound...])
            if let obj = extractEscapedJSONObject(tail, marker: marker) {
                results.append(obj)
            }
            searchFrom = markerRange.upperBound
        }
        return results
    }

    /// Extract a balanced {...} JSON object from HTML where the JSON is
    /// itself backslash-escaped once (quotes appear as \" — the Next.js /
    /// SSR payload style Douyin uses: the inner JSON is embedded as a
    /// JSON string). Braces are literal in that form, so depth counting
    /// works on the raw text; string boundaries are the \" sequences.
    /// The result is unescaped once back to plain JSON.
    /// - Parameter marker: plain text identifying the object, e.g. "roomStore".
    static func extractEscapedJSONObject(_ text: String, marker: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        // The object starts at the first "{" after the marker.
        guard let openIndex = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        // In the escaped text a string-boundary quote is the 2-char
        // sequence \" and a literal backslash is \\; both are skipped
        // as units while scanning.
        let escapedQuote = "\\\"" // backslash + quote
        let escapedBackslash = "\\\\" // two backslashes
        var depth = 0
        var inString = false
        var index = openIndex
        while index < text.endIndex {
            if text[index...].hasPrefix(escapedQuote) {
                inString.toggle()
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if text[index...].hasPrefix(escapedBackslash) {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            let ch = text[index]
            if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let raw = String(text[openIndex...index])
                        return unescapeJSONString(raw)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Unescape one level of JSON string escapes (\" \\ \/ \n \t \r \b \f \uXXXX).
    static func unescapeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { out.append(ch); break }
                switch s[next] {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    let hexStart = s.index(next, offsetBy: 1)
                    let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex) ?? s.endIndex
                    let hex = String(s[hexStart..<hexEnd])
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                    }
                    i = hexEnd
                    continue
                default:
                    out.append(s[next])
                }
                i = s.index(after: next)
            } else {
                out.append(ch)
                i = s.index(after: i)
            }
        }
        return out
    }
}
