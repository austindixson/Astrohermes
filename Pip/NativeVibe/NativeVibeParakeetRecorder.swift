import AVFoundation
import Foundation

/// Records short mic clips as 16 kHz mono WAV for Parakeet transcription.
final class NativeVibeParakeetRecorder {
    static let shared = NativeVibeParakeetRecorder()

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    private init() {}

    func record(seconds: TimeInterval, completion: @escaping (Result<URL, Error>) -> Void) {
        requestMicAccess { granted in
            guard granted else {
                completion(.failure(NSError(
                    domain: "NativeVibeParakeet",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
                )))
                return
            }
            self.startRecording(seconds: seconds, completion: completion)
        }
    }

    private func requestMicAccess(_ completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { completion($0) }
        } else {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        }
    }

    private func startRecording(seconds: TimeInterval, completion: @escaping (Result<URL, Error>) -> Void) {
        stop()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativevibe-parakeet-\(UUID().uuidString).wav")
        outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = false
            rec.prepareToRecord()
            guard rec.record() else {
                throw NSError(domain: "NativeVibeParakeet", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "AVAudioRecorder failed to start",
                ])
            }
            recorder = rec
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.recorder?.stop()
                self.recorder = nil
                if let outputURL = self.outputURL,
                   FileManager.default.fileExists(atPath: outputURL.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                   let size = attrs[.size] as? NSNumber, size.intValue > 128 {
                    completion(.success(outputURL))
                } else {
                    completion(.failure(NSError(domain: "NativeVibeParakeet", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: "No audio captured",
                    ])))
                }
                self.outputURL = nil
            }
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
    }
}