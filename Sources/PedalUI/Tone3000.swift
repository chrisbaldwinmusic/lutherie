import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Settings for the TONE3000 integration.
public enum Tone3000Config {
    /// The publishable key (OAuth client ID) from https://www.tone3000.com/settings. It is public by design
    /// and ships inside the app. Never put the secret key (t3k_cs_…) here. Empty = the feature is hidden.
    public static let clientID = "t3k_pub_oWQlH7TwNOx4dLKmSA38rxi7hysMZ9Da"
    static let redirectURI = "lutherie://tone3000"
    static let callbackScheme = "lutherie"
    static let base = "https://www.tone3000.com/api/v1"
    public static var isConfigured: Bool { !clientID.isEmpty }
}

/// Where a loaded profile came from on TONE3000. Sessions store this instead of the model file, which may
/// not be passed on: opening the session downloads it again through the player's own account.
public struct Tone3000Ref: Codable, Hashable, Sendable {
    public var toneID: Int
    public var modelID: Int
    public var title: String
    public var creator: String
    public var license: String
    public var modelName: String
    public var url: String?

    public var licenseName: String {
        switch license {
        case "t3k": return "TONE3000 licence"
        case "cco", "cc0": return "CC0"
        default: return license.uppercased().replacingOccurrences(of: "CC-", with: "CC ")
        }
    }
    public var credit: String { "\(title) by \(creator) · \(licenseName)" }
}

public struct Tone3000Model: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var size: String
    public var architecture: String
    public var url: String
}

public struct Tone3000Error: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// Talks to TONE3000 on behalf of the signed-in player: sign-in with their own account, their choice of
/// tone in TONE3000's own picker, and download of the one model they asked for. Nothing is fetched in bulk.
@MainActor
public final class Tone3000Client: NSObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = Tone3000Client()

    private var accessToken: String?
    private var expires = Date.distantPast
    private var session: ASWebAuthenticationSession?

    public var isSignedIn: Bool { Keychain.read("refresh") != nil }
    public func signOut() { Keychain.delete("refresh"); accessToken = nil }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }

    // MARK: Sign-in and tone picker

    /// Opens TONE3000's picker (signing in first if needed). Returns the chosen tone's ID, or nil if cancelled.
    /// Pass `reload` to ask for a particular tone again (TONE3000 checks access and may offer a replacement).
    public func pickTone(reload toneID: Int? = nil) async throws -> Int? {
        guard Tone3000Config.isConfigured else { throw Tone3000Error("TONE3000 isn't set up in this build.") }
        let verifier = Self.random(48), state = Self.random(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: Tone3000Config.base + "/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Tone3000Config.clientID),
            .init(name: "redirect_uri", value: Tone3000Config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: toneID == nil ? "select_tone" : "load_tone"),
            .init(name: "format", value: "nam"),
            .init(name: "gears", value: "amp_amp-cab_pedal"),
            .init(name: "menubar", value: "true"),
        ] + (toneID.map { [.init(name: "tone_id", value: String($0))] } ?? [])
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Tone3000Config.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: CancellationError()) }
                else { cont.resume(throwing: Tone3000Error(error?.localizedDescription ?? "Sign-in didn't finish.")) }
            }
            s.presentationContextProvider = self
            self.session = s
            if !s.start() { cont.resume(throwing: Tone3000Error("Couldn't open the TONE3000 sign-in window here.")) }
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = item("error") { throw Tone3000Error(e == "access_denied" ? "TONE3000 access was declined." : "TONE3000: \(e)") }
        guard item("state") == state else { throw Tone3000Error("The TONE3000 reply didn't match the request.") }
        if let code = item("code") {
            try await token(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                             "redirect_uri": Tone3000Config.redirectURI, "client_id": Tone3000Config.clientID])
        }
        if item("canceled") == "true" { return nil }
        return item("tone_id").flatMap { Int($0) }
    }

    private func token(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: Tone3000Config.base + "/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            if form["grant_type"] == "refresh_token" { signOut() }
            throw Tone3000Error("TONE3000 sign-in failed" + ((json["error"] as? String).map { " (\($0))" } ?? "") + ".")
        }
        accessToken = access
        expires = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let r = json["refresh_token"] as? String { Keychain.write("refresh", r) }
    }

    /// A valid access token, refreshed if it is about to run out. Nil if the player needs to sign in.
    private func bearer() async -> String? {
        if let t = accessToken, Date() < expires { return t }
        guard let r = Keychain.read("refresh") else { return nil }
        try? await token(["grant_type": "refresh_token", "refresh_token": r, "client_id": Tone3000Config.clientID])
        return accessToken
    }

    private func get(_ url: URL) async throws -> Data {
        for attempt in 0..<2 {
            guard let t = await bearer() else { throw Tone3000Error("Sign in to TONE3000 first.") }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { accessToken = nil; continue }
            guard (200..<300).contains(code) else {
                throw Tone3000Error(code == 403 || code == 404 ? "That tone isn't available to this TONE3000 account." : "TONE3000 answered with error \(code).")
            }
            return data
        }
        throw Tone3000Error("Sign in to TONE3000 first.")
    }

    // MARK: Tones and models

    /// The tone's details and its NAM captures, best match for this app first.
    public func tone(_ id: Int) async throws -> (title: String, creator: String, license: String, url: String?, models: [Tone3000Model]) {
        let t = (try? JSONSerialization.jsonObject(with: try await get(URL(string: Tone3000Config.base + "/tones/\(id)")!))) as? [String: Any] ?? [:]
        let user = t["user"] as? [String: Any] ?? [:]
        let creator = (user["display_name"] as? String) ?? (user["username"] as? String) ?? "unknown"
        let raw = try? JSONSerialization.jsonObject(with: try await get(URL(string: Tone3000Config.base + "/models?tone_id=\(id)")!))
        // the list may come bare or wrapped
        let list = (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["data"] as? [[String: Any]])
            ?? ((raw as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        var models = list.compactMap { m -> Tone3000Model? in
            guard let mid = m["id"] as? Int, let url = m["model_url"] as? String else { return nil }
            return Tone3000Model(id: mid, name: m["name"] as? String ?? "Capture \(mid)", size: m["size"] as? String ?? "",
                                 architecture: (m["architecture_version"] as? String) ?? (m["architecture_version"] as? Int).map(String.init) ?? "", url: url)
        }
        let order = ["standard", "lite", "feather", "nano", "custom"]
        models.sort { (order.firstIndex(of: $0.size) ?? 9, $0.name) < (order.firstIndex(of: $1.size) ?? 9, $1.name) }
        return (t["title"] as? String ?? "Tone \(id)", creator, t["license"] as? String ?? "", t["url"] as? String, models)
    }

    /// Downloads one model file the player asked for.
    public func download(_ model: Tone3000Model) async throws -> Data {
        guard let url = URL(string: model.url), url.scheme == "https" else { throw Tone3000Error("TONE3000 sent an address that can't be used.") }
        return try await get(url)
    }

    static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The player's TONE3000 sign-in is kept in their keychain, never in session files.
enum Keychain {
    static let service = "audio.channel.lutherie.tone3000"
    static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func write(_ key: String, _ value: String) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
