import XCTest
@testable import BloomMeetings

final class ReliabilityTests: XCTestCase {
    @MainActor func testDiaAudioHelperTriggersCallDetection() {
        XCTAssertEqual(MeetingMonitor.meetingAppName(bundleID: "company.thebrowser.browser.helper", appName: "company.thebrowser.browser.helper"), "Your browser")
        XCTAssertEqual(MeetingMonitor.meetingAppName(bundleID: "company.thebrowser.dia", appName: "Dia"), "Dia")
        XCTAssertNil(MeetingMonitor.meetingAppName(bundleID: "diy.bloom.meetings", appName: "Bloom Meetings"))
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
        try Data(#"{"title":"Old call","transcript":"Keep me"}"#.utf8).write(to: old.directory.appendingPathComponent("meeting.json"))
        let loaded = try library.read(old.id)
        XCTAssertEqual(loaded.transcript, "Keep me")
        var next = try library.create(title: "New call")
        next.state = .recording; try library.save(next)
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
}
