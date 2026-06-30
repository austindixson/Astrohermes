import Foundation
import Darwin

/// Minimal PTY-backed shell session for terminal tiles.
/// SwiftTerm can replace the view layer later; this owns the process + pipes.
final class NativeVibePTYSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false

    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var process: Process?
    private let readQueue = DispatchQueue(label: "nativevibe.pty.read", qos: .userInitiated)
    private let outputLock = NSLock()
    private var readSource: DispatchSourceRead?
    private let maxOutputCharacters = 200_000

    func start(shell: String = "/bin/zsh", workingDirectory: String? = nil) {
        stop()
        guard openPTYPair() else {
            appendOutput("Failed to open PTY.\n")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l"]
        if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        do {
            try proc.run()
            process = proc
            isRunning = true
            startReading(masterFD: masterFD)
            appendOutput("Started \(shell)\n")
        } catch {
            appendOutput("Shell launch failed: \(error.localizedDescription)\n")
            cleanup()
        }
    }

    func sendInput(_ text: String) {
        guard masterFD >= 0, let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(masterFD, base, data.count)
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        cleanup()
        isRunning = false
    }

    deinit { stop() }

    private func openPTYPair() -> Bool {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return false }
        masterFD = master
        slaveFD = slave
        return true
    }

    private func startReading(masterFD: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(masterFD, &buffer, buffer.count)
            guard count > 0 else { return }
            let chunk = String(decoding: buffer.prefix(count), as: UTF8.self)
            DispatchQueue.main.async { self?.appendOutput(chunk) }
        }
        source.setCancelHandler { [weak self] in self?.cleanup() }
        source.resume()
        readSource = source
    }

    private func appendOutput(_ chunk: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        output.append(chunk)
        if output.count > maxOutputCharacters {
            output = String(output.suffix(maxOutputCharacters / 2))
        }
    }

    private func cleanup() {
        if masterFD >= 0 { close(masterFD) }
        if slaveFD >= 0 { close(slaveFD) }
        masterFD = -1
        slaveFD = -1
    }
}