import Foundation

/// O(1) 路由表：method + path 哈希查找。
final class Router: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private struct RouteKey: Hashable {
        let method: String
        let path: String
    }

    private let table: [RouteKey: Handler]
    private let handler: DeepLXHandler

    init(handler: DeepLXHandler, authGuard: AuthGuard) {
        self.handler = handler
        self.table = [
            RouteKey(method: "POST", path: "/translate"): { request in
                await handler.handleFreeTranslate(request, authGuard: authGuard, method: "Free")
            },
            RouteKey(method: "POST", path: "/v1/translate"): { request in
                await handler.handleFreeTranslate(request, authGuard: authGuard, method: "Free")
            },
            RouteKey(method: "POST", path: "/v2/translate"): { request in
                await handler.handleV2Translate(request, authGuard: authGuard)
            },
            RouteKey(method: "GET", path: "/"): { _ in
                handler.rootInfo()
            },
        ]
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let route = table[RouteKey(method: request.method, path: request.path)] {
            return await route(request)
        }
        // 已知路径但方法不符 → 405；其余 → 404
        let knownPath = table.keys.contains { $0.path == request.path }
        let status = knownPath ? 405 : 404
        return .jsonEncoded(
            status: status,
            DeepLXErrorResponse(code: status, message: "not found"))
    }
}
