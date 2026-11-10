import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement
import AVFoundation

@MainActor final class MeetingStore: ObservableObject {
    @Published var status = "Ready for your next meeting"
    @Published var busy = false
    @Published var recording = false
    @Published var transcript = "" { didSet { persistEdits() } }
    @Published var notes = "" { didSet { persistEdits() } }
    @Published var title = "Meeting" { didSet { persistEdits() } }
    @Published var error: String?
    @Published var meetings: [MeetingDocument] = []
    @Published var selectedID: String?
    @Published var startedAt: Date?
    @Published var detectedApp: String?
    @Published var email: String?
    @Published var cloudStatus = "Sign in to back up transcripts"
    @Published var syncEnabled = UserDefaults.standard.bool(forKey: "cloudSync") { didSet { UserDefaults.standard.set(syncEnabled,forKey:"cloudSync") } }
    @Published var loginAtLaunch = SMAppService.mainApp.status == .enabled
    let monitor = MeetingMonitor()
    private let transcriber = LocalTranscriber()
    private let recorder = MeetingRecorder()
    let cloud = MeetingCloud()
    let library = MeetingLibrary()
    private var document: MeetingDocument?
    private var activity: NSObjectProtocol?
    private var restoring = false
    private var syncing = false
    private var syncTimer: Timer?
    var hasAudio: Bool { guard let document else { return false }; return (try? library.audioFiles(document).isEmpty) == false }
    init() {
        refreshArchive()
        if let path=UserDefaults.standard.string(forKey:"lastMeeting"), let doc=try? library.read(URL(fileURLWithPath:path).lastPathComponent) { select(doc) }
        recorder.onFailure = { [weak self] message in Task { @MainActor in
            guard let self else { return }; self.error=message
            if self.recording { await self.stop() }
        }}
        monitor.onDetected = { [weak self] app in
            guard let self, !self.recording, !self.busy else { return }
            self.detectedApp=app
        }
        monitor.start()
        Task { do { email=try await cloud.email(); if email != nil { cloudStatus="Ready to sync" }; await sync() } catch { cloudStatus=error.localizedDescription } }
        syncTimer=Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in Task { @MainActor in await self?.sync() } }
    }
    func setLaunchAtLogin(_ enabled:Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginAtLaunch=SMAppService.mainApp.status == .enabled }
        catch { self.error="Could not change Open at login: " + error.localizedDescription }
    }
    private func persistEdits() {
        guard !restoring, var doc=document else { return }
        doc.title=title; doc.transcript=transcript; doc.notes=notes; doc.revision += 1
        document=doc
        do { try library.save(doc); refreshArchive() }
        catch { self.error="Could not save changes: " + error.localizedDescription }
    }
    private func updateState(_ state:MeetingState) {
        document?.state=state; persistEdits()
    }
    func refreshArchive() { do { meetings=try library.list() } catch { self.error="Could not read meeting archive: " + error.localizedDescription } }
    func select(_ doc:MeetingDocument) {
        guard !busy, !recording else { return }
        restoring=true; document=doc; selectedID=doc.id; title=doc.title; transcript=doc.transcript; notes=doc.notes; restoring=false
        UserDefaults.standard.set(doc.directory.path,forKey:"lastMeeting")
        status=doc.state == .saved ? "Saved on this Mac" : "Interrupted recording. Recover its audio below."
    }
    func start() async {
        guard !busy, !recording else { return }
        busy=true; error=nil; detectedApp=nil
        do {
            var doc=try library.create(title:"Meeting · " + Date().formatted(date:.abbreviated,time:.shortened))
            doc.ownerEmail=email; doc.state = .recording; try library.save(doc)
            try await recorder.start(in:doc.directory)
            restoring=true; document=doc; selectedID=doc.id; title=doc.title; transcript=""; notes=""; restoring=false
            UserDefaults.standard.set(doc.directory.path,forKey:"lastMeeting")
            recording=true; startedAt=Date(); status="Recording microphone and system audio"; refreshArchive()
            activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Recording a meeting")
        } catch { self.error=error.localizedDescription; status="Could not start. Check audio permissions." }
        busy=false
    }
    func stop() async {
        guard recording, !busy else { return }
        busy=true; recording=false; status="Saving audio"
        defer { busy=false; if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity=nil } }
        do { let files=try await recorder.stop(); await transcribe(files) }
        catch { self.error=error.localizedDescription; status="Audio kept locally. Use Recover transcript."; updateState(.interrupted) }
    }
    private func transcribe(_ files:[URL]) async {
        guard !files.isEmpty else { self.error="No audio files found."; return }
        updateState(.transcribing)
        // Keep partial work after interruptions; per-file sidecars allow resuming without losing edits.
        var sections:[String]=[]; var failures=0
        for (index,file) in files.enumerated() {
            status="Transcribing audio \(index+1) of \(files.count) on this Mac"
            let cache=file.appendingPathExtension("txt")
            do {
                let text:String
                if let saved=try? String(contentsOf:cache,encoding:.utf8) { text=saved }
                else { text=try await transcriber.transcribe(file); try text.write(to:cache,atomically:true,encoding:.utf8) }
                if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    let name=file.lastPathComponent.hasPrefix("microphone") ? "You" : "Other participants"
                    sections.append("**\(name)**\n\(text)")
                    transcript=sections.joined(separator:"\n\n")
                }
            } catch { failures += 1 }
        }
        if failures > 0 { self.error="\(failures) audio segments need another transcription attempt. Audio and partial text are preserved."; updateState(.interrupted) }
        else { updateState(.saved) }
        status=failures == 0 ? "Saved on this Mac" : "Audio preserved. Retry with Recover transcript."
        await sync()
    }
    func recover() async {
        guard !busy, !recording, let doc=document else { return }
        busy=true; error=nil; defer { busy=false }
        do {
            // Preserve any human-edited transcript before rebuilding from audio.
            if !transcript.isEmpty { try transcript.write(to:doc.directory.appendingPathComponent("transcript-before-recovery-\(Int(Date().timeIntervalSince1970)).md"),atomically:true,encoding:.utf8) }
            await transcribe(try library.audioFiles(doc))
        } catch { self.error=error.localizedDescription }
    }
    func importAudio() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.audio,.movie]
        panel.begin { [weak self] response in
            guard response == .OK, let file=panel.url else { return }
            Task { @MainActor in
                guard let self, !self.busy, !self.recording else { return }
                let access=file.startAccessingSecurityScopedResource(); self.busy=true; self.error=nil
                defer { if access { file.stopAccessingSecurityScopedResource() }; self.busy=false }
                do {
                    var doc=try self.library.create(title:file.deletingPathExtension().lastPathComponent); doc.ownerEmail=self.email
                    let copy=doc.directory.appendingPathComponent("imported."+file.pathExtension)
                    try FileManager.default.copyItem(at:file,to:copy)
                    self.restoring=true; self.document=doc; self.selectedID=doc.id; self.title=doc.title; self.transcript=""; self.notes=""; self.restoring=false
                    UserDefaults.standard.set(doc.directory.path,forKey:"lastMeeting")
                    await self.transcribe([copy]); self.refreshArchive()
                } catch { self.error=error.localizedDescription }
            }
        }
    }
    func export() {
        let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(filenameExtension:"md")!]; panel.nameFieldStringValue="Meeting.md"
        let text="# \(title)\n\n## Notes\n\n\(notes)\n\n## Transcript\n\n\(transcript)"
        panel.begin { [weak self] response in
            guard response == .OK, let file=panel.url else { return }
            do { try text.write(to:file,atomically:true,encoding:.utf8) }
            catch { Task { @MainActor in self?.error=error.localizedDescription } }
        }
    }
    func reveal() {
        do { try FileManager.default.createDirectory(at:library.root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); NSWorkspace.shared.open(library.root) }
        catch { self.error=error.localizedDescription }
    }
    func didSignIn() async {
        do { email=try await cloud.email(); syncEnabled=true; await sync() } catch { cloudStatus=error.localizedDescription }
    }
    func restoreCloud() async {
        guard let email, !busy, !recording, !syncing else { return }
        busy=true; defer { busy=false }
        do {
            for remote in try await cloud.list() {
                guard UUID(uuidString:remote.localId) != nil else { continue }
                let dir=library.root.appendingPathComponent(remote.localId)
                // Never replace a local folder, including a damaged or partially saved one.
                guard !FileManager.default.fileExists(atPath:dir.path) else { continue }
                var doc=MeetingDocument(id:remote.localId,title:remote.title,directory:dir)
                doc.transcript=remote.transcript; doc.notes=remote.notes; doc.createdAt=Date(timeIntervalSince1970:remote.recordedAt/1000)
                doc.ownerEmail=email; doc.revision=remote.revision; doc.syncedRevision=remote.revision
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); try library.save(doc)
            }
            refreshArchive(); cloudStatus="Restored the latest 20 cloud transcripts. Existing local copies were kept."
        } catch { cloudStatus=error.localizedDescription }
    }
    func sync() async {
        guard syncEnabled, let email, !syncing else { return }
        syncing=true; defer { syncing=false }; cloudStatus="Syncing transcripts…"
        do {
            for var doc in try library.list() where doc.state == .saved && doc.syncedRevision < doc.revision {
                // Pre-login recordings stay local until the user chooses to sign in and enable sync.
                if doc.ownerEmail == nil { doc.ownerEmail=email; try library.save(doc); if document?.id == doc.id { document?.ownerEmail=email } }
                guard doc.ownerEmail == email else { continue }
                try await cloud.upload(doc)
                // Don't overwrite an edit made while the request was in flight.
                var current=try library.read(doc.id); current.syncedRevision=doc.revision; try library.save(current)
                if document?.id == current.id { document?.syncedRevision=doc.revision }
            }
            cloudStatus="Transcripts backed up · " + Date().formatted(date:.omitted,time:.shortened)
        } catch { cloudStatus=error.localizedDescription }
    }
}

final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    var store:MeetingStore?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the main view's detection observer alive while the app lives in the menu bar.
        if sender.title == "Bloom Meetings" { sender.orderOut(nil); return false }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let store,store.recording || store.busy else { return .terminateNow }
            let alert=NSAlert(); alert.messageText="A recording or transcription is still running"
            alert.informativeText="Stop recording and wait for the save before quitting."; alert.addButton(withTitle:"Keep open"); alert.runModal(); return .terminateCancel
        }
    }
}

struct SignInView:View {
    @ObservedObject var store:MeetingStore
    @State private var email="david@bloom.diy"
    @State private var code=""
    @State private var sent=false
    @State private var working=false
    @State private var issue:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Back up your meetings").font(.title2.bold())
            Text("Sign in with your Bloom email. Transcripts and notes are private to your account in Bloom's Convex backend. Audio stays on this Mac.").foregroundStyle(.secondary)
            TextField("you@bloom.diy",text:$email).disabled(sent || working)
            if sent { SecureField("Code from your email",text:$code) }
            if let issue { Text(issue).foregroundStyle(.red) }
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                Button(sent ? "Sign in" : "Email me a code") { Task {
                    working=true; issue=nil; defer { working=false }
                    do {
                        email=email.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                        if sent { try await store.cloud.verify(email,code:code.trimmingCharacters(in:.whitespacesAndNewlines)); await store.didSignIn(); dismiss() }
                        else { try await store.cloud.sendCode(email); sent=true }
                    } catch { issue=error.localizedDescription }
                }}.buttonStyle(.borderedProminent).disabled(working)
            }
        }.padding(28).frame(width:440)
    }
}

struct MeetingsView:View {
    @ObservedObject var store:MeetingStore
    @ObservedObject var monitor:MeetingMonitor
    @State private var signIn=false
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:12) {
                Text("Bloom Meetings").font(.title2.bold()).padding(.horizontal)
                List(store.meetings,selection:$store.selectedID) { doc in
                    VStack(alignment:.leading,spacing:5) {
                        Text(doc.title).lineLimit(2)
                        Text(doc.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                        if doc.state != .saved { Text("Audio recovery available").font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical,5).tag(doc.id)
                }.disabled(store.recording || store.busy)
                Button("Import audio…") { store.importAudio() }.disabled(store.busy || store.recording).padding(.horizontal)
                Divider()
                Toggle("Detect calls",isOn:$monitor.enabled).padding(.horizontal)
                Toggle("Open at login",isOn:Binding(get:{store.loginAtLaunch},set:{store.setLaunchAtLogin($0)})).padding(.horizontal)
                Button(store.email ?? "Sign in with Bloom") { signIn=true }.padding(.horizontal)
                if store.email != nil {
                    Toggle("Back up transcripts",isOn:$store.syncEnabled).padding(.horizontal)
                    Button("Restore from cloud") { Task { await store.restoreCloud() } }.disabled(store.busy || store.recording).padding(.horizontal)
                }
                Text(store.cloudStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }.padding(.vertical,20).navigationSplitViewColumnWidth(min:220,ideal:250)
        } detail: {
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    Circle().fill(store.recording ? Color.red : .secondary.opacity(0.3)).frame(width:9,height:9)
                    if store.recording,let date=store.startedAt { Text(date,style:.timer).monospacedDigit() }
                    Text(store.status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.recording ? "Stop recording" : "Record meeting") { Task { if store.recording { await store.stop() } else { await store.start() } } }.buttonStyle(.borderedProminent).tint(store.recording ? .red : .accentColor).disabled(store.busy)
                }
                if let issue=store.error { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                TextField("Meeting name",text:$store.title).font(.title.bold()).textFieldStyle(.plain).writingToolsBehavior(.disabled)
                if store.selectedID == nil {
                    ContentUnavailableView("Ready for your next call",systemImage:"waveform",description:Text("When a meeting app uses your microphone, Bloom will offer to record. You can also start a recording here."))
                } else {
                    Text("YOUR NOTES").font(.caption.bold()).foregroundStyle(.secondary)
                    TextEditor(text:$store.notes).writingToolsBehavior(.disabled).frame(minHeight:70,maxHeight:130)
                    Divider()
                    Text("TRANSCRIPT").font(.caption.bold()).foregroundStyle(.secondary)
                    TextEditor(text:$store.transcript).font(.body).writingToolsBehavior(.disabled).disabled(store.busy || store.recording).overlay {
                        if store.transcript.isEmpty { Text(store.recording ? "Audio is being saved. Your transcript appears after you stop." : "Your transcript will appear here.").foregroundStyle(.tertiary).allowsHitTesting(false) }
                    }
                }
                HStack {
                    Button("Recordings folder") { store.reveal() }
                    if store.hasAudio { Button("Recover transcript") { Task { await store.recover() } }.disabled(store.recording || store.busy) }
                    Spacer()
                    Button("Export…") { store.export() }.disabled(store.transcript.isEmpty || store.busy)
                }
                Text("Audio stays on this Mac. Let people know before recording.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.frame(minWidth:900,minHeight:620)
        .onChange(of:store.selectedID) { _,id in if let doc=store.meetings.first(where:{$0.id == id}) { store.select(doc) } }
        .sheet(isPresented:$signIn) { SignInView(store:store) }
    }
}

struct BloomMeetingsApp:App {
    @StateObject private var store=MeetingStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    var body:some Scene {
        Window("Bloom Meetings",id:"meetings") {
            MeetingsView(store:store,monitor:store.monitor).onAppear {
                delegate.store=store
                NSApp.windows.first(where: { $0.title == "Bloom Meetings" })?.delegate=delegate
            }
                .onChange(of:store.detectedApp) { _,name in if name != nil { openWindow(id:"detected") } }
        }.commands { CommandGroup(replacing:.newItem) {} }
        Window("Meeting detected",id:"detected") {
            VStack(alignment:.leading,spacing:18) {
                Label("Microphone active",systemImage:"waveform").font(.headline)
                Text("Take notes for this call?").font(.title2.bold())
                Text(store.detectedApp ?? "Meeting app").foregroundStyle(.secondary)
                HStack {
                    Button("Not now") { dismissDetection() }
                    Spacer()
                    Button("Record meeting") { dismissDetection(); openWindow(id:"meetings"); Task { await store.start() } }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width:340)
                .onAppear { NSApp.windows.first(where:{$0.title == "Meeting detected"})?.level = .floating }
        }.windowResizability(.contentSize).defaultPosition(.topTrailing)
        MenuBarExtra("Bloom Meetings",systemImage:store.recording ? "record.circle.fill" : "waveform") {
            Button("Open Bloom Meetings") { openWindow(id:"meetings"); NSApp.activate(ignoringOtherApps:true) }
            Text(store.status)
            Button(store.recording ? "Stop recording" : "Record meeting") { openWindow(id:"meetings"); Task { if store.recording { await store.stop() } else { await store.start() } } }.disabled(store.busy)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
    private func dismissDetection() { store.detectedApp=nil; NSApp.windows.first(where:{$0.title == "Meeting detected"})?.close() }
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
        if CommandLine.arguments.contains("--verify-capture") {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-capture-probe-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let recorder = MeetingRecorder()
                try await recorder.start(in: folder)
                try await Task.sleep(for: .seconds(65))
                let files = try await recorder.stop()
                var tracks: [String: Double] = [:]
                for file in files {
                    let audio = try AVAudioFile(forReading: file)
                    let track = file.lastPathComponent.hasPrefix("microphone") ? "microphone" : "system"
                    tracks[track, default: 0] += Double(audio.length) / audio.fileFormat.sampleRate
                }
                print("Captured durations (seconds): \(tracks). Segments: \(files.count)")
                guard (tracks["microphone"] ?? 0) >= 55, (tracks["system"] ?? 0) >= 55, files.count >= 6 else { exit(1) }
                print("PASS: both audio tracks survived two segment rotations")
                exit(0)
            } catch { fputs("Capture check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        BloomMeetingsApp.main()
    }
}
