import Foundation
import FluidAudio

/// Adapted from Muesli's FluidAudioTranscriber, retaining only local v3 loading.
actor LocalTranscriber {
    private var manager: AsrManager?
    func transcribe(_ file: URL) async throws -> String {
        if manager == nil {
            guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Models/parakeet-tdt-0.6b-v3"), FileManager.default.fileExists(atPath: directory.path) else {
                throw CaptureError.message("The local model is missing. Install a complete Bloom Meetings build; no model will be downloaded at runtime.")
            }
            let models = try AsrModels.loadLocal(from: directory, version: .v3, encoderComputeUnits: .cpuAndNeuralEngine)
            let loaded = AsrManager(config: .default)
            try await loaded.loadModels(models)
            manager = loaded
        }
        guard let manager else { throw CaptureError.message("The local model did not load.") }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(file, decoderState: &state).text
    }
}
