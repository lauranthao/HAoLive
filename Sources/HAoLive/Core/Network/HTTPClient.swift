// HTTPClient.swift
// HAo Live — one URLSession wrapper for all platform adapters.
// Browser-style headers (the platforms' web APIs answer a browser UA;
// the probes showed several endpoints 403 without one), 20s timeout,
// and HTTP-status errors surfaced as LiveSiteError so the UI can show
// a real message instead of a silent empty list.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stateless HTTP client. Safe to share across adapters.
final class HTTPClient: Sendable {
    static let shared = HTTPClient()

    /// Desktop Chrome UA: the web APIs used by these adapters were
    /// verified against it from this VM.
    let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get(_ urlString: String, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request)
    }

    func getJSON(_ urlString: String, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        let data = try await get(urlString, headers: headers, timeout: timeout)
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        return json
    }

    /// GET returning the response headers too (keys lowercased).
    /// Needed when the caller must read set-cookie — Douyin hands out
    /// its anonymous ttwid cookie in set-cookie, and the body alone
    /// does not carry it. Multiple set-cookie lines arrive combined
    /// in one value; the caller scans it for the cookie names it
    /// needs instead of splitting on commas (cookie dates contain
    /// commas, so a comma split would corrupt Expires values).
    func getWithHeaders(_ urlString: String, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> (data: Data, headers: [String: String]) {
        guard let url = URL(string: urlString) else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, http) = try await performWithResponse(request)
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                out[k.lowercased()] = v
            }
        }
        return (data, out)
    }

    /// POST with application/x-www-form-urlencoded body (Douyu's play API).
    func postForm(_ urlString: String, fields: [String: String], headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = fields
            .map { key, value in
                // Strict application/x-www-form-urlencoded encoding
                // (build 11, found by the LOOK group): .urlQueryAllowed
                // leaves `+` unencoded, and a form body reads `+` as
                // a space — a base64 value (LOOK WeAPI `params`) came
                // back as HTTP 200 with an empty body. Only
                // alphanumerics + -._* pass through; space becomes
                // `+`; everything else (%2B for `+`, %2F for `/`,
                // %3D for `=`, %26 for `&`) is percent-encoded.
                let k = Self.formEncode(key)
                let v = Self.formEncode(value)
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await perform(request)
    }

    /// One application/x-www-form-urlencoded field (see postForm).
    static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    func postFormJSON(_ urlString: String, fields: [String: String], headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        let data = try await postForm(urlString, fields: fields, headers: headers, timeout: timeout)
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        return json
    }

    /// POST with a raw JSON body (Twitch GraphQL, YouTube InnerTube).
    func postJSON(_ urlString: String, jsonData: Data, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LiveSiteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = jsonData
        return try await perform(request)
    }

    func postJSONParsed(_ urlString: String, jsonData: Data, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        let data = try await postJSON(urlString, jsonData: jsonData, headers: headers, timeout: timeout)
        guard let json = JSONValue.parse(data) else { throw LiveSiteError.invalidResponse }
        return json
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await performWithResponse(request).0
    }

    private func performWithResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveSiteError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LiveSiteError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveSiteError.httpStatus(http.statusCode)
        }
        return (data, http)
    }
}
