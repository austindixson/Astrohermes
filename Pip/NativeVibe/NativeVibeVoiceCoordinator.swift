import Foundation
import Speech
import AVFoundation

/// Dual-path voice: MLX Parakeet (fast local) with Apple Speech fallback.
@MainActor
final class NativeVibeVoiceCoordinator: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var pathLabel = "Local STT"
    @Published private(set) var status = "Voice idle"

    var onFinalUtterance: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))

    override init() {
        super.init()
        NativeVibeParakeetTranscriber.shared.refreshAvailability()
    }

    var parakeetReady: Bool { NativeVibeParakeetTranscriber.shared.isAvailable() }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening(preferParakeet: parakeetReady)
        }
    }

    func startListening(preferParakeet: Bool = true) {
        if preferParakeet, NativeVibeParakeetTranscriber.shared.isAvailable() {
            beginParakeetCapture()
            return
        }
        if preferParakeet {
            status = NativeVibeParakeetTranscriber.shared.statusMessage
            pathLabel = "Local STT (fallback)"
        } else {
            pathLabel = "Local STT"
        }
        requestPermissionsAndBegin()
    }

    func stopListening() {
        NativeVibeParakeetRecorder.shared.stop()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        if !status.hasPrefix("Parakeet") && !status.hasPrefix("MLX") {
            status = "Voice idle"
        }
    }

    private func beginParakeetCapture() {
        stopListening()
        pathLabel = "MLX Parakeet"
        status = "Recording for Parakeet…"
        isListening = true
        NativeVibeOrchestrator.shared.record(source: "voice", action: "parakeet_start")

        NativeVibeParakeetTranscriber.shared.transcribe(duration: 5) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isListening = false
                switch result {
                case .success(let text):
                    self.transcript = text
                    self.status = "Parakeet: \(text.prefix(60))"
                    NativeVibeOrchestrator.shared.record(
                        source: "voice",
                        action: "parakeet_transcript",
                        payload: ["text": String(text.prefix(120))]
                    )
                    self.onFinalUtterance?(text)
                case .failure(let error):
                    self.status = "Parakeet failed — \(error.localizedDescription)"
                    NativeVibeOrchestrator.shared.record(
                        source: "voice",
                        action: "parakeet_error",
                        payload: ["error": error.localizedDescription]
                    )
                    self.pathLabel = "Local STT (fallback)"
                    self.requestPermissionsAndBegin()
                }
            }
        }
    }

    private func requestPermissionsAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            Task { @MainActor in
                guard let self else { return }
                guard speechStatus == .authorized else {
                    self.status = "Speech permission denied"
                    return
                }
                self.beginAppleSpeechRecognition()
            }
        }
    }

    private func beginAppleSpeechRecognition() {
        stopListening()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            status = "Speech recognizer unavailable"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        NativeVibeOrchestrator.shared.record(
                            source: "voice",
                            action: "apple_transcript",
                            payload: ["text": String(self.transcript.prefix(120))]
                        )
                        self.onFinalUtterance?(self.transcript)
                        self.stopListening()
                    }
                }
                if error != nil {
                    self.stopListening()
                }
            }
        }

        do {
            try audioEngine.start()
            isListening = true
            status = "Listening (Apple Speech)…"
        } catch {
            status = "Audio engine failed"
            stopListening()
        }
    }
}