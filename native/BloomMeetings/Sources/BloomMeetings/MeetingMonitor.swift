import AppKit
import Combine

@MainActor final class MeetingMonitor: ObservableObject {
  @Published var enabled = UserDefaults.standard.object(forKey: "meetingDetection") as? Bool ?? true
  {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "meetingDetection")
      updateActivity()
    }
  }
  @Published var activeApp: String?
  var onDetected: ((String) -> Void)?
  private let collector = AudioProcessAttributionCollector()
  private var state = CallDetectionState()
  private var timer: Timer?
  private var activity: NSObjectProtocol?
  private func updateActivity() {
    if enabled && activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Detect incoming meetings")
    } else if !enabled, let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
  }
  // Browsers can also use the mic for dictation: the prompt says "Microphone active"
  // and never records without an explicit click. No browsing history is read.
  private static let supported = [
    "company.thebrowser.dia", "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
    "org.mozilla.firefox", "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
    "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "com.webex.meetingmanager",
    "net.whatsapp.WhatsApp",
  ]
  static func meetingAppName(bundleID: String, appName: String) -> String? {
    // Dia and Arc report microphone activity from this shared Chromium audio helper,
    // not the visible browser's bundle identifier (observed on macOS 26).
    if bundleID == "company.thebrowser.browser.helper" { return "Your browser" }
    guard supported.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) else {
      return nil
    }
    return appName
  }
  func start() {
    guard timer == nil else { return }
    updateActivity()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    tick()
  }
  private func tick() {
    activeApp =
      collector.activeInputProcesses().compactMap { process in
        guard process.pid != ProcessInfo.processInfo.processIdentifier else {
          return nil as String?
        }
        return Self.meetingAppName(bundleID: process.bundleID, appName: process.appName)
      }.first
    if let name = state.observe(app: enabled ? activeApp : nil, at: Date()), enabled {
      onDetected?(name)
    }
  }
}
