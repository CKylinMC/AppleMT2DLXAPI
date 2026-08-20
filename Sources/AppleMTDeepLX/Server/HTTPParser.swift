import Foundation

/// HTTP/1.1 请求增量解析器。
///
/// - 单缓冲累积：每次网络读取仅 append 一次，解析用索引定位，
///   仅在提取 body 时做一次 subdata 拷贝
/// - 支持 keep-alive 与管道化（解析出一个请求后保留剩余字节）
/// - 防御：头部 16KB 上限、body 1MB 上限、拒绝 chunked
final class HTTPRequestParser {
    static let maxHeaderSize = 16 * 1024
    static let maxBodySize = 1024 * 1024

    enum Outcome {
        /// 解析出完整请求；keepAlive 指示响应后是否保持连接
        case request(HTTPRequest, keepAlive: Bool)
        /// 数据不足，等待更多字节
        case needMore
        /// 协议错误，附带应返回的响应
        case failure(HTTPResponse)
    }

    private var buffer = Data()

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// 追加网络读取的字节并尝试解析。
    func append(_ data: Data) -> Outcome {
        buffer.append(data)

        if buffer.count > Self.maxHeaderSize + Self.maxBodySize {
            return .failure(.json(status: 413, Self.errorBody("request too large")))
        }

        // 定位头部结束位置
        guard let terminatorRange = buffer.firstRange(of: Self.headerTerminator) else {
            if buffer.count > Self.maxHeaderSize {
                return .failure(.json(status: 400, Self.errorBody("request header too large")))
            }
            return .needMore
        }

        let headerData = buffer.subdata(in: 0..<terminatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.json(status: 400, Self.errorBody("invalid request encoding")))
        }

        // 解析请求行与请求头
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return .failure(.json(status: 400, Self.errorBody("empty request")))
        }
        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3 else {
            return .failure(.json(status: 400, Self.errorBody("malformed request line")))
        }
        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let version = String(requestParts[2]).uppercased()
        guard version.hasPrefix("HTTP/") else {
            return .failure(.json(status: 400, Self.errorBody("unsupported protocol")))
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // chunked 不受支持（本地 API 场景均带 Content-Length）
        if let transferEncoding = headers["transfer-encoding"],
           transferEncoding.lowercased().contains("chunked") {
            return .failure(.json(status: 400, Self.errorBody("chunked transfer not supported")))
        }

        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                return .failure(.json(status: 400, Self.errorBody("invalid content-length")))
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        if contentLength > Self.maxBodySize {
            return .failure(.json(status: 413, Self.errorBody("request body too large")))
        }

        let bodyStart = terminatorRange.upperBound
        let totalLength = bodyStart + contentLength
        if buffer.count < totalLength {
            return .needMore
        }

        let body = contentLength > 0 ? buffer.subdata(in: bodyStart..<totalLength) : Data()
        buffer.removeSubrange(0..<totalLength)

        // 拆分路径与查询串
        var path = target
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            let queryString = target[target.index(after: questionMark)...]
            for pair in queryString.split(separator: "&") {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
                let value = keyValue.count > 1
                    ? (String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1]))
                    : ""
                query[key] = value
            }
        }

        // keep-alive 判定：HTTP/1.1 默认保持，HTTP/1.0 默认关闭
        var keepAlive = !version.hasSuffix("1.0")
        if let connection = headers["connection"]?.lowercased() {
            keepAlive = connection.contains("keep-alive")
        }

        let request = HTTPRequest(
            method: method, path: path, query: query, headers: headers, body: body)
        return .request(request, keepAlive: keepAlive)
    }

    private static func errorBody(_ message: String) -> Data {
        Data("{\"code\":400,\"message\":\"\(message)\"}".utf8)
    }
}
