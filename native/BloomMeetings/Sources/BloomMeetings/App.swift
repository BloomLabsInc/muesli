import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class MeetingStore: ObservableObject {
    @Published var status = "Ready"
    @Published var busy = false
    @Published var recording = false
    @Published var transcript = "" { didSet { persistEdits() } }
    @Published var title = "Meeting" { didSet { persistEdits() } }
    @Published var error: String?
    private let transcriber = LocalTranscriber()
    private let recorder = MeetingRecorder()
    private var directory: URL?
    private var activity: NSObjectProtocol?
    private var restoring = false
    private struct Document: Codable { let title: String; let transcript: String }
    private func persistEdits() {
        guard !restoring, let directory else { return }
        do {
            try JSONEncoder().encode(Document(title: title, transcript: transcript)).write(to: directory.appendingPathComponent("meeting.json"), options: .atomic)
            try ("# \(title)\n\n" + transcript).write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        } catch { self.error = "Could not save changes: " + error.localizedDescription }
    }
    private func newDirectory() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BloomMeetings/Recordings")
    }
    init() {
        if let path = UserDefaults.standard.string(forKey: "lastMeeting"), path.hasPrefix(root.path + "/"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("meeting.json")),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            restoring = true; directory = URL(fileURLWithPath: path); title = doc.title; transcript = doc.transcript; restoring = false
            status = "Saved locally"
        }
        recorder.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.error = message
                if self.recording { await self.stop() }
            }
        }
    }
    func start() async {
        guard !busy, !recording else { return }
        busy = true; error = nil
        do {
            let directory = try newDirectory()
            try await recorder.start(in: directory)
            self.directory = directory
            UserDefaults.standard.set(directory.path, forKey: "lastMeeting")
            recording = true; transcript = ""; status = "Recording microphone and system audio"
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording an explicitly started meeting")
        } catch { self.error = error.localizedDescription; status = "Could not start" }
        busy = false
    }
    func stop() async {
        guard recording, !busy else { return }
        busy = true; recording = false; status = "Saving audio"
        defer { busy = false; if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil } }
        do {
            let files = try await recorder.stop()
            status = "Transcribing on this Mac"
            var sections: [String] = []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let text: String
                do { text = try await transcriber.transcribe(file) }
                catch { self.error = "Some audio could not be transcribed; source audio is preserved."; continue }
                sections.append("## \(file.lastPathComponent.hasPrefix("microphone") ? "Microphone" : "Other participants")\n\n\(text)")
                transcript = sections.joined(separator: "\n\n")
            }
            status = error == nil ? "Saved locally" : "Check the save or transcription issue above"
        } catch { self.error = error.localizedDescription; status = "Audio kept locally; transcription incomplete" }
    }
    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let access = file.startAccessingSecurityScopedResource()
        busy = true; error = nil; status = "Transcribing on this Mac"
        Task {
            defer { if access { file.stopAccessingSecurityScopedResource() }; busy = false }
            do {
                let result = try await transcriber.transcribe(file)
                directory = try newDirectory()
                UserDefaults.standard.set(directory!.path, forKey: "lastMeeting")
                restoring = true; title = file.deletingPathExtension().lastPathComponent; transcript = result; restoring = false
                persistEdits(); status = error == nil ? "Saved locally" : "Check the save or transcription issue above"
            }
            catch { self.error = error.localizedDescription; status = "Transcription failed" }
        }
    }
    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = "Meeting.md"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { try ("# \(title)\n\n" + transcript).write(to: file, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
    func reveal() {
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.open(root) }
        catch { self.error = error.localizedDescription }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard let store, store.recording || store.busy else { return true }
            NSSound.beep(); return false
        }
    }
    var store: MeetingStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let store, store.recording || store.busy else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "A recording or transcription is still running"
            alert.informativeText = "Stop recording and wait for the local save before quitting."
            alert.addButton(withTitle: "Keep open")
            alert.runModal()
            return .terminateCancel
        }
    }
}

struct BloomMeetingsApp: App {
    @StateObject private var store = MeetingStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Bloom Meetings", id: "meetings") {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bloom Meetings").font(.title2.bold())
                        Text("Local audio. Local transcripts. No account.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Offline", systemImage: "lock.shield").foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Circle().fill(store.recording ? Color.red : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                    Text(store.status)
                    Spacer()
                    Button(store.recording ? "Stop and transcribe" : "Record meeting") {
                        Task { if store.recording { await store.stop() } else { await store.start() } }
                    }.buttonStyle(.borderedProminent).disabled(store.busy)
                }
                if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                TextField("Meeting name", text: $store.title).font(.headline).writingToolsBehavior(.disabled)
                TextEditor(text: $store.transcript).font(.body).writingToolsBehavior(.disabled).overlay {
                    if store.transcript.isEmpty { Text("Your transcript will appear here.").foregroundStyle(.tertiary).allowsHitTesting(false) }
                }
                HStack {
                    Button("Import audio…") { store.importAudio() }.disabled(store.busy || store.recording)
                    Button("Recordings folder") { store.reveal() }
                    Spacer()
                    Button("Export Markdown…") { store.export() }.disabled(store.transcript.isEmpty || store.busy)
                }
                Text("No uploads or background sync. Audio is kept on this Mac. Let people know before recording.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(minWidth: 640, minHeight: 480)
            .onAppear {
                delegate.store = store
                NSApp.windows.first(where: { $0.title == "Bloom Meetings" })?.delegate = delegate
            }
        }.commands { CommandGroup(replacing: .newItem) {} }
    }
}

@main enum EntryPoint {
    static func main() async {
        if CommandLine.arguments.contains("--verify-local-transcription") {
            do {
                guard let file = Bundle.main.url(forResource: "synthetic-fixture", withExtension: "wav") else { throw CaptureError.message("Synthetic fixture missing") }
                let text = try await LocalTranscriber().transcribe(file)
                print(text)
                exit(text.lowercased().contains("synthetic") && text.lowercased().contains("friday") ? 0 : 1)
            } catch { fputs("Local transcription failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-network-denied"), CommandLine.arguments.count > index + 1 {
            guard let url = URL(string: CommandLine.arguments[index + 1]), url.host == "127.0.0.1" else { exit(2) }
            do { _ = try await URLSession.shared.data(from: url); print("FAIL: network request succeeded"); exit(1) }
            catch { print("Network request denied or failed: \(error as NSError)"); exit(0) }
        }
        BloomMeetingsApp.main()
    }
}
