import Foundation

enum AutomixModelPolicy {
    static func paths(
        beat: String,
        vocal: String,
        accelerator: AutomixAccelerator?,
        playbackStarted: Bool,
        enabled: Bool,
        efficient: Bool
    ) -> (beat: String, vocal: String, accelerator: AutomixAccelerator?) {
        guard playbackStarted && enabled else { return ("", "", nil) }
        // The accelerator only makes sense beside the ONNX beat graph: that graph
        // is the fallback, runs short tracks, and gates `analyzer_ready`.
        let accelerated = efficient || beat.isEmpty ? nil : accelerator
        return (beat, efficient ? "" : vocal, accelerated)
    }
}

/// Serialize native model replacement off-main so rapid preference changes
/// finish in request order and never interleave two graph configurations.
actor AutomixModelLoader {
    static let shared = AutomixModelLoader()

    private struct Configuration: Equatable {
        let beat: String
        let vocal: String
        let accelerator: String
    }
    // A fresh process already has no models. Do not cross into the native
    // analyzer just because the user enabled Automix without downloading any.
    private var applied: Configuration? = Configuration(beat: "", vocal: "", accelerator: "")
    private var lastReady = false
    private var revision: UInt64 = 0

    func configure(beat: String, vocal: String, accelerator: AutomixAccelerator?) async -> Bool {
        revision &+= 1
        let request = revision
        let configuration = Configuration(beat: beat, vocal: vocal,
            accelerator: accelerator.map { $0.identity + "|" + $0.modelURL.absoluteString } ?? "")
        if applied == configuration { return lastReady }
        applied = nil
        let ready = configureAnalyzer(beatModelPath: beat, vocalModelPath: vocal)
        guard ready, !beat.isEmpty, let accelerator else {
            setBeatAccelerator(accelerator: nil, identity: "")
            applied = configuration; lastReady = ready
            return ready
        }
        if let model = BeatThisCoreML(modelURL: accelerator.modelURL) {
            setBeatAccelerator(accelerator: model, identity: accelerator.identity)
            applied = configuration; lastReady = ready
            return ready
        }
        // A compiled model an OS update invalidated: rebuild once from the
        // verified archive, then give up and leave the analysis on rten. The
        // rebuild itself runs off the main actor inside the store.
        let rebuilt = await AutomixModelStore.shared.recompileBeatCoreML()
        // Actors can reenter at await. A later disable/configuration owns the
        // analyzer now; an old compilation must not install its model again.
        guard revision == request else { return false }
        if let rebuilt, let model = BeatThisCoreML(modelURL: rebuilt.modelURL) {
            setBeatAccelerator(accelerator: model, identity: rebuilt.identity)
        } else {
            setBeatAccelerator(accelerator: nil, identity: "")
        }
        applied = configuration; lastReady = ready
        return ready
    }
}
