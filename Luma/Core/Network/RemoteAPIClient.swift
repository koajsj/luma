import CryptoKit
import Foundation
import Security

enum RemoteError: LocalizedError {
    case invalidURL, insecureURL, unregistered, invalidResponse, authenticationExpired, deviceRevoked
    case server(Int, String)
    case onlineMessagesUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: "服务器地址无效"
        case .insecureURL: "在线模式需要 HTTPS 服务器地址"
        case .unregistered: "此设备尚未在服务器登记"
        case .invalidResponse: "服务器响应格式无效"
        case .authenticationExpired: "设备会话已失效，请重新登录在线账号"
        case .deviceRevoked: "此设备已从服务器撤销，在线会话已清除"
        case .server(409, "v4_prekeys_exhausted"): "对方设备的一次性安全密钥已用完，请对方打开 Luma 后重试"
        case let .server(code, reason): "服务器请求失败（\(code)：\(reason)）"
        case .onlineMessagesUnavailable: "线上消息协议尚未完成，不能发送本机密文"
        }
    }
}

struct RemoteRegistration: Codable {
    let backendUserID: UUID
    let backendDeviceID: UUID
    let baseURL: URL
}

struct RemoteTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

struct RemoteTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

struct RemoteChallenge: Decodable {
    let challengeID: UUID
    let nonce: String
}

/// Account-scoped public routing IDs and bearer secrets share Keychain protection.
struct RemoteSessionStore {
    let keychain: KeychainManager

    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func registration(for userID: String) throws -> RemoteRegistration? {
        guard let bytes = try keychain.read("remote.registration.\(userID)") else { return nil }
        return try JSONDecoder().decode(RemoteRegistration.self, from: bytes)
    }

    func save(_ registration: RemoteRegistration, for userID: String) throws {
        try keychain.save(JSONEncoder().encode(registration), account: "remote.registration.\(userID)")
    }

    func tokens(for userID: String) throws -> RemoteTokens? {
        guard let bytes = try keychain.read("remote.tokens.\(userID)") else { return nil }
        return try JSONDecoder().decode(RemoteTokens.self, from: bytes)
    }

    func save(_ response: RemoteTokenResponse, for userID: String) throws {
        let value = RemoteTokens(accessToken: response.accessToken, refreshToken: response.refreshToken,
                                 expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)))
        try keychain.save(JSONEncoder().encode(value), account: "remote.tokens.\(userID)")
    }

    func clearTokens(for userID: String) throws { try keychain.delete("remote.tokens.\(userID)") }

    func clearAll(for userID: String) throws {
        try clearTokens(for: userID)
        try keychain.delete("remote.registration.\(userID)")
        try keychain.delete("remote.auth-private.\(userID)")
    }
}

struct RemoteDeviceSigner {
    let keychain: KeychainManager

    init(keychain: KeychainManager = KeychainManager()) { self.keychain = keychain }

    func publicKey(for userID: String) throws -> Data {
        try key(for: userID, create: true).publicKey.rawRepresentation
    }

    func sign(_ text: String, userID: String) throws -> String {
        let signature = try key(for: userID, create: false).signature(for: Data(text.utf8))
        return signature.base64URLEncodedString()
    }

    private func key(for userID: String, create: Bool) throws -> Curve25519.Signing.PrivateKey {
        let account = "remote.auth-private.\(userID)"
        if let data = try keychain.read(account) {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { throw KeychainError.invalidData }
            return key
        }
        guard create else { throw KeychainError.missing }
        let key = Curve25519.Signing.PrivateKey()
        try keychain.save(key.rawRepresentation, account: account)
        return key
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// All requests use URLSession's normal TLS validation; no certificate bypass is installed.
final class RemoteAPIClient {
    static let ephemeralSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let baseURL: URL
    let userID: String
    private let store: RemoteSessionStore
    private let signer: RemoteDeviceSigner
    private let session: URLSession

    init(baseURL: URL, userID: String, store: RemoteSessionStore = RemoteSessionStore(),
         signer: RemoteDeviceSigner = RemoteDeviceSigner(), session: URLSession? = nil) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host,
              !host.isEmpty, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw RemoteError.invalidURL }
        guard scheme == "https" else { throw RemoteError.insecureURL }
        self.baseURL = baseURL
        self.userID = userID
        self.store = store
        self.signer = signer
        self.session = session ?? Self.ephemeralSession
    }

    func request(_ method: String, path: String, body: Data? = nil, authenticated: Bool = true,
                 contentType: String = "application/json", extraHeaders: [String: String] = [:]) async throws -> Data {
        var request = try makeRequest(method, path: path, body: body, contentType: contentType, extraHeaders: extraHeaders)
        if authenticated {
            let tokens = try await validTokens()
            try authorize(&request, token: tokens.accessToken)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }
        if http.statusCode == 401 && authenticated {
            if case .server(_, "device_revoked") = Self.serverError(http.statusCode, data: data) {
                try store.clearTokens(for: userID)
                throw RemoteError.deviceRevoked
            }
            throw RemoteError.authenticationExpired
        }
        guard (200...299).contains(http.statusCode) else { throw Self.serverError(http.statusCode, data: data) }
        return data
    }

    func json<T: Decodable>(_ type: T.Type, method: String = "GET", path: String,
                            body: Data? = nil, authenticated: Bool = true) async throws -> T {
        let data = try await request(method, path: path, body: body, authenticated: authenticated)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteError.invalidResponse }
    }

    func authenticatedWebSocketRequest() async throws -> URLRequest {
        var request = try makeRequest("GET", path: "/ws", body: nil, contentType: "application/json", extraHeaders: [:])
        try authorize(&request, token: try await validTokens().accessToken)
        guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw RemoteError.invalidURL }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        return request
    }

    private func validTokens() async throws -> RemoteTokens {
        guard let tokens = try store.tokens(for: userID) else { throw RemoteError.authenticationExpired }
        if tokens.expiresAt > Date().addingTimeInterval(30) { return tokens }
        let body = try JSONEncoder().encode(["refreshToken": tokens.refreshToken])
        var request = try makeRequest("POST", path: "/auth/refresh", body: body, contentType: "application/json", extraHeaders: [:])
        try authorize(&request, token: tokens.refreshToken, bearer: false)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                if case .server(_, "device_revoked") = Self.serverError(http.statusCode, data: data) {
                    try store.clearTokens(for: userID)
                    throw RemoteError.deviceRevoked
                }
                throw RemoteError.authenticationExpired
            }
            throw Self.serverError(http.statusCode, data: data)
        }
        let renewed = try JSONDecoder().decode(RemoteTokenResponse.self, from: data)
        try store.save(renewed, for: userID)
        guard let fresh = try store.tokens(for: userID) else { throw RemoteError.authenticationExpired }
        return fresh
    }

    private func makeRequest(_ method: String, path: String, body: Data?, contentType: String,
                             extraHeaders: [String: String]) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"),
              let url = URL(string: "/v1" + path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host else { throw RemoteError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func authorize(_ request: inout URLRequest, token: String, bearer: Bool = true) throws {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var random = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw KeychainError.invalidData }
        let nonce = Data(random).base64URLEncodedString()
        let digest = Data(SHA256.hash(data: Data(token.utf8))).base64URLEncodedString()
        guard let url = request.url, let method = request.httpMethod else { throw RemoteError.invalidURL }
        let requestURI = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        let canonical = "luma.request.v1\n\(method)\n\(requestURI)\n\(timestamp)\n\(nonce)\n\(digest)"
        request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
        request.setValue(try signer.sign(canonical, userID: userID), forHTTPHeaderField: "X-Device-Signature")
        if bearer { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private static func serverError(_ code: Int, data: Data) -> RemoteError {
        struct Body: Decodable { let code: String }
        let reason = (try? JSONDecoder().decode(Body.self, from: data).code) ?? "unknown_error"
        return .server(code, reason)
    }
}
