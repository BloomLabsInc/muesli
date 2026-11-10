import Foundation
import Security

struct CloudSession: Codable {
  var token: String
  var refreshToken: String
  var email: String
}
struct CloudMeeting: Decodable {
  let state: String?
  let localId: String
  let title: String
  let transcript: String
  let notes: String
  let recordedAt: Double
  let revision: Int
}
actor MeetingCloud {
  // Public deployment address, not a credential. Only this Bloom-owned backend receives transcripts.
  static let baseURL = URL(string: "https://reminiscent-buzzard-959.convex.cloud")!
  private var session: CloudSession?
  private var loaded = false
  private let keychain: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "diy.bloom.meetings",
    kSecAttrAccount as String: "convex-auth",
  ]
  private func load() throws {
    guard !loaded else { return }
    var query = keychain
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      session = try JSONDecoder().decode(CloudSession.self, from: data)
    } else if status != errSecItemNotFound {
      throw CaptureError.message("Cannot open the Bloom Meetings sign-in in Keychain (\(status)).")
    }
    loaded = true
  }
  private func persist(_ value: CloudSession) throws {
    let data = try JSONEncoder().encode(value)
    let result = SecItemUpdate(
      keychain as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
      var query = keychain
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(query as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw CaptureError.message("Could not save sign-in in Keychain (\(status)).")
      }
    } else if result != errSecSuccess {
      throw CaptureError.message("Could not update sign-in in Keychain (\(result)).")
    }
    session = value
  }
  func email() throws -> String? {
    try load()
    return session?.email
  }
  private func call(_ kind: String, _ path: String, _ args: [String: Any], token: String? = nil)
    async throws -> Any
  {
    var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/" + kind))
    request.httpMethod = "POST"
    request.timeoutInterval = 25
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "path": path, "args": args, "format": "json",
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw CaptureError.message("Cloud is unavailable. Your recording remains saved on this Mac.")
    }
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      result["status"] as? String == "success"
    else {
      throw CaptureError.message(
        "Cloud request was refused. Check your sign-in; local recordings are safe.")
    }
    return result["value"] ?? NSNull()
  }
  func sendCode(_ email: String) async throws {
    guard
      email.range(
        of: #"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@bloom\.diy$"#, options: .regularExpression) != nil
    else { throw CaptureError.message("Use your @bloom.diy email address.") }
    _ = try await call(
      "action", "auth:signIn", ["provider": "bloom-email", "params": ["email": email]])
  }
  func verify(_ email: String, code: String) async throws {
    let result = try await call(
      "action", "auth:signIn",
      ["provider": "bloom-email", "params": ["email": email, "code": code]])
    guard let tokens = (result as? [String: Any])?["tokens"] as? [String: String],
      let token = tokens["token"], let refresh = tokens["refreshToken"]
    else { throw CaptureError.message("The sign-in code was not accepted. Request a new code.") }
    let me = try await call("query", "meetings:me", [:], token: token)
    guard (me as? [String: String])?["email"] == email else {
      throw CaptureError.message("Sign-in identity did not match.")
    }
    try persist(CloudSession(token: token, refreshToken: refresh, email: email))
  }
  private func authenticated() async throws -> CloudSession {
    try load()
    guard let session else { throw CaptureError.message("Sign in to sync your transcripts.") }
    let pieces = session.token.split(separator: ".")
    if pieces.count == 3 {
      var base64 = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
      if let data = Data(base64Encoded: base64),
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let expiry = payload["exp"] as? Double, expiry > Date().timeIntervalSince1970 + 120
      {
        return session
      }
    }
    let result = try await call("action", "auth:signIn", ["refreshToken": session.refreshToken])
    guard let tokens = (result as? [String: Any])?["tokens"] as? [String: String],
      let token = tokens["token"], let refresh = tokens["refreshToken"]
    else { throw CaptureError.message("Sign in again to resume cloud sync.") }
    let next = CloudSession(token: token, refreshToken: refresh, email: session.email)
    try persist(next)
    return next
  }
  func upload(_ doc: MeetingDocument) async throws {
    let session = try await authenticated()
    guard doc.ownerEmail == session.email else {
      throw CaptureError.message("This meeting belongs to a different signed-in account.")
    }
    _ = try await call(
      "mutation", "meetings:save",
      [
        "localId": doc.id, "title": doc.title, "transcript": doc.transcript, "notes": doc.notes,
        "recordedAt": doc.createdAt.timeIntervalSince1970 * 1000, "revision": doc.revision,
        "state": doc.state.rawValue,
      ], token: session.token)
  }
  func list() async throws -> [CloudMeeting] {
    let session = try await authenticated()
    let value = try await call("query", "meetings:list", [:], token: session.token)
    return try JSONDecoder().decode(
      [CloudMeeting].self, from: JSONSerialization.data(withJSONObject: value))
  }
  func signOut() async throws {
    try load()
    if let session { _ = try await call("action", "auth:signOut", [:], token: session.token) }
    let status = SecItemDelete(keychain as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CaptureError.message("Could not remove this app's sign-in (\(status)).")
    }
    session = nil
  }
}
