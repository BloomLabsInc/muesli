import AVFoundation
import ScreenCaptureKit

/// Control operations are serialized by MeetingStore. Buffer state belongs to queue.
/// Only audio buffers are persisted; no screen output is registered or written.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "diy.bloom.meetings.audio")
    private var sinks: [SCStreamOutputType: AudioSink] = [:]
    private var failure: Error?
    private var accepting = false
    var onFailure: (@Sendable (String) -> Void)?

    func start(in directory: URL) async throws {
        let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 2_000_000_000 else { throw CaptureError.message("At least 2 GB of free space is needed to start a meeting recording.") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.message("Microphone permission was denied.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.message("No display is available for system-audio capture.") }
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.capturesAudio = true; config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 1
        queue.sync {
            sinks = [.audio: AudioSink(directory: directory, name: "others"), .microphone: AudioSink(directory: directory, name: "microphone")]
            failure = nil; accepting = true
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
            if let failure = queue.sync(execute: { self.failure }) { throw failure }
        } catch {
            try? await stream.stopCapture(); self.stream = nil
            queue.sync { accepting = false; for sink in sinks.values { sink.finish() } }
            throw error
        }
    }

    func stop() async throws -> [URL] {
        // A system stop may already have ended capture. Always finalize and keep its audio.
        try? await stream?.stopCapture()
        stream = nil
        let files = queue.sync {
            accepting = false
            return sinks.values.flatMap { sink in sink.finish(); return sink.files }
        }
        guard !files.isEmpty else { throw CaptureError.message("No audio was captured. Check microphone and system-audio permissions.") }
        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), failure == nil else { return }
        do { try sinks[type]?.append(sampleBuffer) }
        catch { failure = error; onFailure?(error.localizedDescription) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failure = error; self.onFailure?(error.localizedDescription) }
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Uncompressed CAF avoids AAC encoder backpressure and finalization dependency.
/// Rotate every 30 seconds and on device format changes to bound crash exposure.
private final class AudioSink {
    let directory: URL
    let name: String
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0
    private(set) var files: [URL] = []
    init(directory: URL, name: String) { self.directory = directory; self.name = name }
    func append(_ sample: CMSampleBuffer) throws {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let incoming = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: incoming, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard result == noErr else { throw CaptureError.message("Audio buffer conversion failed (\(result)).") }
        if file == nil || format != incoming || Double(frames) >= incoming.sampleRate * 30 {
            finish()
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free > 200_000_000 else { throw CaptureError.message("Recording stopped because disk space is low. Captured audio is preserved.") }
            let url = directory.appendingPathComponent("\(name)-\(String(format: "%04d", files.count)).caf")
            file = try AVAudioFile(forWriting: url, settings: incoming.settings, commonFormat: incoming.commonFormat, interleaved: incoming.isInterleaved)
            format = incoming; frames = 0; files.append(url)
        }
        try file?.write(from: pcm)
        frames += AVAudioFramePosition(count)
    }
    func finish() { file = nil; format = nil; frames = 0 }
}
