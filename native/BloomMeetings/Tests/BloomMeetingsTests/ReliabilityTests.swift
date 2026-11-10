import XCTest

@testable import BloomMeetings

final class ReliabilityTests: XCTestCase {
  @MainActor func testDiaAudioHelperTriggersCallDetection() {
    XCTAssertEqual(
      MeetingMonitor.meetingAppName(
        bundleID: "company.thebrowser.browser.helper", appName: "company.thebrowser.browser.helper"),
      "Your browser")
    XCTAssertEqual(
      MeetingMonitor.meetingAppName(bundleID: "company.thebrowser.dia", appName: "Dia"), "Dia")
    XCTAssertNil(
      MeetingMonitor.meetingAppName(bundleID: "diy.bloom.meetings", appName: "Bloom Meetings"))
  }
  func testDetectionRequiresSustainedInputAndSuppressesSameCall() {
    var detector = CallDetectionState()
    let t = Date(timeIntervalSince1970: 100)
    XCTAssertNil(detector.observe(app: "Dia", at: t))
    XCTAssertNil(detector.observe(app: "Dia", at: t.addingTimeInterval(2)))
    XCTAssertEqual(detector.observe(app: "Dia", at: t.addingTimeInterval(4)), "Dia")
    XCTAssertNil(detector.observe(app: "Dia", at: t.addingTimeInterval(100)))
    XCTAssertNil(detector.observe(app: nil, at: t.addingTimeInterval(101)))
    XCTAssertNil(detector.observe(app: "Dia", at: t.addingTimeInterval(120)))
    XCTAssertNil(detector.observe(app: nil, at: t.addingTimeInterval(121)))
    XCTAssertNil(detector.observe(app: nil, at: t.addingTimeInterval(182)))
    XCTAssertNil(detector.observe(app: "Dia", at: t.addingTimeInterval(183)))
    XCTAssertEqual(detector.observe(app: "Dia", at: t.addingTimeInterval(187)), "Dia")
  }
  func testLegacyDocumentSurvivesUpgradeAndNewMeetingDoesNotOverwriteIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MeetingLibrary(root: root)
    let old = try library.create(title: "Synthetic call")
    try Data(#"{"title":"Old call","transcript":"Keep me"}"#.utf8).write(
      to: old.directory.appendingPathComponent("meeting.json"))
    let loaded = try library.read(old.id)
    XCTAssertEqual(loaded.transcript, "Keep me")
    var next = try library.create(title: "New call")
    next.state = .recording
    try library.save(next)
    XCTAssertEqual(try library.list().count, 2)
    XCTAssertEqual(try library.read(old.id).transcript, "Keep me")
    XCTAssertEqual(try library.read(next.id).state, .recording)
  }
  func testCorruptMeetingDoesNotHideHealthyArchive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MeetingLibrary(root: root)
    let good = try library.create(title: "Good")
    let broken = try library.create(title: "Broken")
    try Data("{".utf8).write(to: broken.directory.appendingPathComponent("meeting.json"))
    XCTAssertEqual(try library.list().map(\.id), [good.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: broken.directory.path))
  }

  func testShortAudioTailKeepsItsSamplesAndMeetsASRMinimum() {
    let tail: [Float] = [0.1, -0.2, 0.3]
    let prepared = LocalTranscriber.padShortTail(tail)
    XCTAssertEqual(prepared.count, 4800)
    XCTAssertEqual(Array(prepared.prefix(3)), tail)
    XCTAssertTrue(prepared.dropFirst(3).allSatisfy { $0 == 0 })
    XCTAssertEqual(LocalTranscriber.padShortTail([]), [])
  }
  func testImportedMovieRemainsRecoverable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MeetingLibrary(root: root)
    let doc = try library.create(title: "Synthetic import")
    try Data().write(to: doc.directory.appendingPathComponent("imported.mp4"))
    XCTAssertEqual(try library.audioFiles(doc).map(\.lastPathComponent), ["imported.mp4"])
  }
  @MainActor func testFailedBackupDoesNotStarveNextMeetingOrOverwriteEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MeetingLibrary(root: root)
    let a = try library.create(title: "A")
    let b = try library.create(title: "B")
    let ordered = try library.list()
    let first = ordered[0].id
    let next = ordered[1].id
    var received: [MeetingDocument] = []
    let failures = try await backUpMeetings(
      library: library, email: "a@bloom.diy",
      upload: { doc in
        if doc.id == first {
          var edited = try library.read(next)
          edited.title = "Edited during earlier upload"
          edited.revision += 1
          try library.save(edited)
          throw CaptureError.message("Synthetic failed upload")
        }
        received.append(doc)
        var edited = try library.read(doc.id)
        edited.notes = "Edited while this upload was in flight"
        edited.revision += 1
        try library.save(edited)
      }, didSave: { _ in })
    XCTAssertEqual(failures, 1)
    XCTAssertEqual(received.map(\.id), [next])
    XCTAssertEqual(received.first?.title, "Edited during earlier upload")
    let saved = try library.read(next)
    XCTAssertEqual(saved.notes, "Edited while this upload was in flight")
    XCTAssertEqual(saved.revision, 2)
    XCTAssertEqual(saved.syncedRevision, 1)
    XCTAssertEqual(try library.read(first).syncedRevision, -1)
    XCTAssertNotEqual(a.id, b.id)
  }
}
