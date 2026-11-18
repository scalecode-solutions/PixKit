@preconcurrency import AVFoundation
import Foundation
import Observation

/// Records an audio clip (AAC in .m4a) into the capture folder, up to
/// `PixCapture.maxDuration`. The file is the caller's once `stop()` hands it
/// over; `cancel()` and a failed start delete it.
@MainActor
@Observable
final class PixClipRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// 0…1, for a level meter.
    private(set) var level: Float = 0

    private let config: PixConfig
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var timer: Timer?
    /// Called when the clip reaches the cap and stops by itself.
    var onLimit: ((URL) -> Void)?

    init(config: PixConfig) { self.config = config }

    func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await config.prompt { await AVAudioApplication.requestRecordPermission() }
    }

    func start() async throws {
        guard !isRecording else { return }
        guard await requestPermission() else { throw PixCaptureError.denied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let url = try PixCapture.newFile(config, ext: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: PixCapture.maxDuration) else { throw PixCaptureError.unavailable }
            recorder = r
        } catch {
            PixCapture.discard(url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        file = url
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stop and hand the clip over (nil when nothing was recording).
    @discardableResult
    func stop() -> URL? {
        guard isRecording, let recorder, let url = file else { return nil }
        recorder.stop()
        finish()
        PixCapture.protect(url)
        return url
    }

    /// Stop and delete the clip.
    func cancel() {
        guard isRecording else { return }
        recorder?.stop()
        PixCapture.discard(file)
        finish()
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        if !recorder.isRecording {
            // record(forDuration:) reached the cap.
            if let url = stop() { onLimit?(url) }
            return
        }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 60) / 60))
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        file = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
