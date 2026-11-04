import Foundation

// Native and Core ML seams only. The policy and loader under test are production files.
struct AutomixAccelerator: Sendable { let modelURL: URL; let identity: String }
private var nativeConfigurations = 0
private var installedIdentity = ""
func configureAnalyzer(beatModelPath: String, vocalModelPath: String) -> Bool {
    nativeConfigurations += 1
    return !beatModelPath.isEmpty
}
final class BeatThisCoreML {
    init?(modelURL: URL) { if modelURL.lastPathComponent == "needs-rebuild" { return nil } }
}
func setBeatAccelerator(accelerator: BeatThisCoreML?, identity: String) { installedIdentity = identity }
actor AutomixModelStore {
    static let shared = AutomixModelStore()
    private var pending: CheckedContinuation<AutomixAccelerator?, Never>?
    func recompileBeatCoreML() async -> AutomixAccelerator? {
        await withCheckedContinuation { pending = $0 }
    }
    func isRebuilding() -> Bool { pending != nil }
    func finish() {
        pending?.resume(returning: AutomixAccelerator(modelURL: URL(fileURLWithPath: "/rebuilt"), identity: "old-model"))
        pending = nil
    }
}

@main struct VerifyAutomixStartup {
    static func main() async {
        let fourGiB: UInt64 = 4 * 1024 * 1024 * 1024
        precondition(AutomixResourcePolicy.isConstrained(isIOS: true, physicalMemory: fourGiB))
        precondition(!AutomixResourcePolicy.isConstrained(isIOS: true, physicalMemory: fourGiB + 1))
        precondition(!AutomixResourcePolicy.isConstrained(isIOS: false, physicalMemory: fourGiB))
        precondition(AutomixResourcePolicy.mode("PERFORMANCE", constrained: true) == "EFFICIENT")
        precondition(AutomixResourcePolicy.mode("PERFORMANCE", constrained: false) == "PERFORMANCE")
        let safe = AutomixModelPolicy.paths(beat: "beat", vocal: "vocal",
            accelerator: AutomixAccelerator(modelURL: URL(fileURLWithPath: "/working"), identity: "heavy"),
            playbackStarted: true, enabled: true,
            efficient: AutomixResourcePolicy.mode("BALANCED", constrained: true) == "EFFICIENT")
        precondition(safe.beat == "beat" && safe.vocal.isEmpty && safe.accelerator == nil)
        // First play / refusal / stale previous track must never permit analysis.
        precondition(!AutomixReadiness.canPrepare(currentID: "new", loadedID: nil, source: nil, transportReady: false))
        precondition(!AutomixReadiness.canPrepare(currentID: "new", loadedID: "old", source: "/old", transportReady: true))
        precondition(!AutomixReadiness.canPrepare(currentID: "new", loadedID: "new", source: "", transportReady: true))
        precondition(AutomixReadiness.canPrepare(currentID: "new", loadedID: "new", source: "/audio", transportReady: true))
        let valid = "yt:abcdefghijk"
        precondition(YouTubePlaybackLink.url(source: valid)?.absoluteString == "https://music.youtube.com/watch?v=abcdefghijk")
        for invalid in ["saavn:abcdefghijk", "src:provider:key", "yt:abc&v=other", "yt:", "https://example.com"] {
            precondition(YouTubePlaybackLink.url(source: invalid) == nil)
        }
        let loader = AutomixModelLoader()
        _ = await loader.configure(beat: "", vocal: "", accelerator: nil)
        precondition(nativeConfigurations == 0, "No downloaded models should do no native model setup")
        let accelerator = AutomixAccelerator(modelURL: URL(fileURLWithPath: "/working"), identity: "same")
        _ = await loader.configure(beat: "/beat", vocal: "", accelerator: accelerator)
        let configurations = nativeConfigurations
        _ = await loader.configure(beat: "/beat", vocal: "", accelerator: accelerator)
        precondition(nativeConfigurations == configurations, "Repeated track loads must reuse model configuration")
        let pending = Task {
            await loader.configure(beat: "/beat", vocal: "", accelerator:
                AutomixAccelerator(modelURL: URL(fileURLWithPath: "/needs-rebuild"), identity: "old-model"))
        }
        let deadline = Date().addingTimeInterval(10)
        while !(await AutomixModelStore.shared.isRebuilding()), Date() < deadline { await Task.yield() }
        let rebuilding = await AutomixModelStore.shared.isRebuilding()
        precondition(rebuilding, "Rebuild fixture never started")
        _ = await loader.configure(beat: "", vocal: "", accelerator: nil)
        precondition(installedIdentity.isEmpty)
        await AutomixModelStore.shared.finish()
        _ = await pending.value
        precondition(installedIdentity.isEmpty, "Stale compilation re-enabled the disabled accelerator")
        print("PASS memory-constrained Automix model selection, startup readiness, empty-model no-op, model reuse, disable-during-rebuild, and official playback links")
    }
}
