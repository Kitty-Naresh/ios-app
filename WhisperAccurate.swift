import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// The accurate Whisper model (large-v3-turbo) and its state. It is large: the first load on a phone compiles the CoreML encoder,
/// which can take a minute or more (cached after that), and it holds a lot of memory. So it loads in the background, the first
/// conversation never waits for it (the live model settles lines until it is ready), it stays loaded a while after the conversation
/// closes, and it is let go of on a memory warning.
@MainActor
final class WhisperAccurate: ObservableObject {
    enum Status: Equatable {
        case unavailable        // the model is not in the app (or this is the simulator)
        case notLoaded
        case loading
        case ready
        case failed
    }

    static let shared = WhisperAccurate()
    /// How long it stays loaded after the conversation closes.
    static let keepLoaded: TimeInterval = 600

    @Published private(set) var status: Status
    let engine: WhisperEngine
    private let queue = DispatchQueue(label: "kitty.whisper.turbo.load", qos: .utility)
    private var loadTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?

    init(engine: WhisperEngine = WhisperEngine(accurate: true), available: Bool = WhisperModel.isAccurateAvailable) {
        self.engine = engine
        self.status = available ? .notLoaded : .unavailable
        #if os(iOS)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        }
        #endif
    }

    var isAvailable: Bool { status != .unavailable }

    /// What a session asks when a phrase ends: the engine if it is loaded now, else nil and the live model settles the line.
    nonisolated var provider: @Sendable () -> WhisperTranscribing? {
        let engine = self.engine
        return { engine.isLoaded ? engine : nil }
    }

    /// Starts loading in the background if it is not loaded. Returns at once.
    func prepare(keyTerms: [String]) {
        unloadTask?.cancel()
        guard status == .notLoaded || status == .failed else { return }
        status = .loading
        let engine = engine
        let queue = queue
        loadTask = Task { [weak self] in
            let started = Date()
            let error: String? = await withCheckedContinuation { cont in
                queue.async {
                    do { try engine.load(keyTerms: keyTerms, boost: 0); cont.resume(returning: nil) }
                    catch { cont.resume(returning: error.localizedDescription) }
                }
            }
            guard let self else { return }
            if let error {
                self.status = .failed
                Breadcrumb.log("whisper-turbo failed to load: \(error)")
            } else {
                self.status = .ready
                Breadcrumb.log("whisper-turbo loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }
    }

    /// For tests and the opt-in real run: returns when the load that `prepare` started has finished.
    func waitUntilLoaded() async { await loadTask?.value }

    /// Lets go of the model a while after the conversation closes.
    func unloadSoon(after seconds: TimeInterval = WhisperAccurate.keepLoaded) {
        unloadTask?.cancel()
        unloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.unloadNow()
        }
    }

    func unloadNow() {
        guard status == .ready else { return }
        status = .notLoaded
        let engine = engine
        queue.async { engine.unload() }
        Breadcrumb.log("whisper-turbo unloaded")
    }

    private func memoryWarning() {
        guard status == .ready else { return }
        Breadcrumb.log("whisper-turbo: memory warning")
        unloadNow()
    }
}
