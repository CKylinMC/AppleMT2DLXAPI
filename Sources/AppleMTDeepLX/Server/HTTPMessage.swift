import Foundation

/// 解析后的 HTTP 请求。
struct HTTPRequest: Sendable {
    let method: String
    /// 不含查询串的纯路径
    let path: String
    /// 查询参数（未解码重复键取最后一个）
    let query: [String: String]
    /// 请求头（键统一小写）
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var queryToken: String? {
        query["token"]
    }

    var contentType: String {
        header("content-type") ?? ""
    }
}

/// HTTP 响应。
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(status: Int = 200, _ body: Data, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        for (key, value) in extraHeaders { headers[key] = value }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    static func text(status: Int = 200, _ text: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8))
    }

    /// 序列化 Codable 为 JSON 响应；失败时返回 500。
    static func jsonEncoded<T: Encodable>(status: Int = 200, _ value: T, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        guard let data = try? JSONEncoder().encode(value) else {
            return .text(status: 500, "internal encoding error")
        }
        return .json(status: status, data, extraHeaders: extraHeaders)
    }

    static var reasonPhraseTable: [Int: String] {
        [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
         405: "Method Not Allowed", 408: "Request Timeout", 413: "Payload Too Large",
         429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"]
    }

    var reasonPhrase: String {
        Self.reasonPhraseTable[status] ?? "Unknown"
    }

    /// 序列化为可写入连接的字节流。
    func serialized(keepAlive: Bool) -> Data {
        var lines: [String] = ["HTTP/1.1 \(status) \(reasonPhrase)"]
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = keepAlive ? "keep-alive" : "close"
        allHeaders["Server"] = "AppleMTDeepLX/1.0.0"
        for (key, value) in allHeaders {
            lines.append("\(key): \(value)")
        }
        let head = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
