import Foundation

enum MeetingState: String, Codable { case recording, transcribing, saved, interrupted }
struct MeetingDocument: Codable, Identifiable {
  var id: String
  var title: String
  var transcript: String
  var notes: String
  var createdAt: Date
  var state: MeetingState
  var revision: Int
  var syncedRevision: Int
  var ownerEmail: String?
  var directory: URL = URL(fileURLWithPath: "/")
  enum CodingKeys: String, CodingKey {
    case id, title, transcript, notes, createdAt, state, revision, syncedRevision, ownerEmail
  }
  init(id: String, title: String, directory: URL) {
    self.id = id
    self.title = title
    self.directory = directory
    transcript = ""
    notes = ""
    createdAt = Date()
    state = .saved
    revision = 0
    syncedRevision = -1
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    title = try c.decode(String.self, forKey: .title)
    transcript = try c.decode(String.self, forKey: .transcript)
    notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    state = try c.decodeIfPresent(MeetingState.self, forKey: .state) ?? .saved
    revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    syncedRevision = try c.decodeIfPresent(Int.self, forKey: .syncedRevision) ?? -1
    ownerEmail = try c.decodeIfPresent(String.self, forKey: .ownerEmail)
  }
}
struct MeetingLibrary {
  let root: URL
  init(
    root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BloomMeetings/Recordings")
  ) { self.root = root }
  func create(title: String) throws -> MeetingDocument {
    let id = UUID().uuidString
    let doc = MeetingDocument(id: id, title: title, directory: root.appendingPathComponent(id))
    try FileManager.default.createDirectory(
      at: doc.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try save(doc)
    return doc
  }
  func save(_ doc: MeetingDocument) throws {
    guard UUID(uuidString: doc.id) != nil,
      doc.directory.standardizedFileURL.deletingLastPathComponent() == root.standardizedFileURL
    else { throw CaptureError.message("Invalid meeting location") }
    try JSONEncoder().encode(doc).write(
      to: doc.directory.appendingPathComponent("meeting.json"), options: .atomic)
    let markdown =
      "# \(doc.title)\n\n" + (doc.notes.isEmpty ? "" : "## Notes\n\n\(doc.notes)\n\n")
      + doc.transcript
    try markdown.write(
      to: doc.directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
  }
  func read(_ id: String) throws -> MeetingDocument {
    guard UUID(uuidString: id) != nil else { throw CaptureError.message("Invalid meeting ID") }
    let dir = root.appendingPathComponent(id)
    var doc = try JSONDecoder().decode(
      MeetingDocument.self, from: Data(contentsOf: dir.appendingPathComponent("meeting.json")))
    doc.id = id
    doc.directory = dir
    if doc.createdAt == .distantPast {
      doc.createdAt =
        (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
    return doc
  }
  func list() throws -> [MeetingDocument] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .compactMap { try? read($0.lastPathComponent) }.sorted { $0.createdAt > $1.createdAt }
  }
  func audioFiles(_ doc: MeetingDocument) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: doc.directory, includingPropertiesForKeys: nil)
      .filter {
        ["caf", "wav", "m4a"].contains($0.pathExtension)
          || $0.lastPathComponent.hasPrefix("imported.")
      }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
      }
  }
}

/// Prompt once per call, including across brief mutes or device transitions.
struct CallDetectionState {
  private var candidate: String?
  private var since: Date?
  private var lastInput: Date?
  private var prompted = false
  mutating func observe(app: String?, at now: Date) -> String? {
    guard let app else {
      if let lastInput, now.timeIntervalSince(lastInput) > 60 {
        candidate = nil
        since = nil
        prompted = false
      }
      return nil
    }
    lastInput = now
    if candidate != app {
      candidate = app
      since = now
      prompted = false
    }
    guard !prompted, let since, now.timeIntervalSince(since) >= 4 else { return nil }
    prompted = true
    return app
  }
}

/// Each document is refreshed after earlier awaits; one failed upload cannot starve the archive.
@MainActor func backUpMeetings(
  library: MeetingLibrary, email: String,
  upload: (MeetingDocument) async throws -> Void,
  didSave: (MeetingDocument) -> Void
) async throws -> Int {
  var failures = 0
  for listed in try library.list() {
    do {
      var doc = try library.read(listed.id)
      guard doc.state == .saved || (doc.state == .interrupted && !doc.transcript.isEmpty),
        doc.syncedRevision < doc.revision
      else { continue }
      if doc.ownerEmail == nil {
        doc.ownerEmail = email
        try library.save(doc)
        didSave(doc)
      }
      guard doc.ownerEmail == email else { continue }
      try await upload(doc)
      var current = try library.read(doc.id)
      current.syncedRevision = doc.revision
      try library.save(current)
      didSave(current)
    } catch { failures += 1 }
  }
  return failures
}
