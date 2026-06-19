import Foundation

/// One bubble update while Hermes streams stdout.
struct HermesStreamChunk: Equatable {
    var text: String
    var isTrace: Bool
}

/// Talks to Hermes by spawning `hermes chat -q` as a subprocess.
/// No API keys, no network — uses the local Hermes CLI directly.
/// Injects a Pip-personality system instruction for brief, playful responses.
final class HermesChatClient {

    static let shared = HermesChatClient()

    private static let workspaceDefaultsKey = "pip.hermes.workingDirectory"

    private let workQueue = DispatchQueue(label: "pip.chat-client", qos: .userInitiated)
    private let stateLock = NSLock()
    private var currentProcess: Process?
    private var sessionID: String?
    private var workingDirectory: String?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.workspaceDefaultsKey),
           FileManager.default.fileExists(atPath: saved) {
            workingDirectory = saved
        }
    }

    /// Hermes session for the current Pip chat thread (cleared when chat closes or `/new`).
    var activeSessionID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionID
    }

    /// Directory Hermes runs in (from dropped files, paths in messages, or `/cwd`).
    var activeWorkingDirectory: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return workingDirectory
    }

    func resetSession() {
        stateLock.lock()
        sessionID = nil
        stateLock.unlock()
    }

    func setWorkingDirectory(_ path: String?) {
        let resolved = Self.resolveWorkspaceDirectory(path)
        stateLock.lock()
        workingDirectory = resolved
        stateLock.unlock()
        if let resolved {
            UserDefaults.standard.set(resolved, forKey: Self.workspaceDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.workspaceDefaultsKey)
        }
    }

    /// Pick a workspace from absolute paths in a message or dropped file list.
    func adoptWorkspace(fromMessage message: String) {
        adoptWorkspace(paths: Self.pathsMentioned(in: message))
    }

    func adoptWorkspace(paths: [String]) {
        guard let resolved = Self.resolveWorkspaceDirectory(from: paths) else { return }
        setWorkingDirectory(resolved)
    }

    static let spaceAgentPersona = """
        You are the Space Agent, a floating astronaut assistant on the user's Mac desktop.
        HARD RULES (never break these):
        - Reply in at most 2 short sentences, under 40 words total.
        - Never output code, HTML, JSON, diffs, file contents, markdown fences, or multi-line blocks.
        - Never paste implementations in chat — write files with tools instead, then summarize in one sentence where they are.
        - For build/create/fix requests: do the work silently, then reply briefly (e.g. "Done — saved to ~/path/file.ext").
        - No markdown, bullets, lists, or preamble. Quiet mission-specialist tone.
        """
    static let compactMaxCharacters = 240

    /// @deprecated alias
    static let pipPersona = spaceAgentPersona

    /// Send a message and get Hermes's response. Calls completion on main queue.
    /// `onPartial` fires on main queue as stdout arrives (compact bubble traces).
    /// `onRawOutput` streams the full Hermes CLI transcript (full chat / TUI mode).
    func send(
        _ message: String,
        verbose: Bool = false,
        onRawOutput: ((String) -> Void)? = nil,
        onPartial: ((HermesStreamChunk?) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let local = Self.localSlashResponse(for: trimmed) {
            if trimmed.lowercased().hasPrefix("/stop") { cancel() }
            DispatchQueue.main.async { completion(.success(local)) }
            return
        }

        adoptWorkspace(fromMessage: trimmed)

        workQueue.async { [weak self] in
            guard let self else { return }

            let hermesPath = self.findHermes() ?? "hermes"
            let fullPrompt = Self.preparePrompt(for: trimmed, verbose: verbose)

            self.stateLock.lock()
            let resumeID = self.sessionID
            let cwd = self.workingDirectory
            self.stateLock.unlock()

            var command = "\(hermesPath) chat -q \(self.quote(fullPrompt)) --source pip"
            if !verbose {
                command += " --quiet"
            }
            if let resumeID {
                command += " --resume \(self.quote(resumeID))"
            }
            command += " 2>&1"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", command]
            if let cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: nil) {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            self.currentProcess = process

            var accumulated = ""
            let partialLock = NSLock()

            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                partialLock.lock()
                accumulated += chunk
                let snapshot = accumulated
                partialLock.unlock()
                if verbose {
                    let transcript = Self.transcriptDisplayText(from: snapshot)
                    DispatchQueue.main.async { onRawOutput?(transcript) }
                } else {
                    let update = Self.streamChunk(from: snapshot)
                    DispatchQueue.main.async { onPartial?(update) }
                }
            }

            do {
                try process.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            process.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil

            let tailData = out.fileHandleForReading.readDataToEndOfFile()
            let errorData = err.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus != 0 {
                let errStr = String(data: errorData, encoding: .utf8) ?? "unknown error"
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "HermesChat", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errStr])))
                }
                return
            }

            partialLock.lock()
            if let tail = String(data: tailData, encoding: .utf8), !tail.isEmpty {
                accumulated += tail
            }
            let raw = accumulated
            partialLock.unlock()

            if let newSession = Self.extractSessionID(from: raw) {
                self.stateLock.lock()
                self.sessionID = newSession
                self.stateLock.unlock()
            }

            let output = verbose
                ? Self.transcriptDisplayText(from: raw)
                : Self.fullDisplayText(from: raw)

            DispatchQueue.main.async {
                completion(.success(output))
            }
        }
    }

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: - Workspace + session helpers

    private static func resolveWorkspaceDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolveWorkspaceDirectory(from: [trimmed])
    }

    private static func resolveWorkspaceDirectory(from paths: [String]) -> String? {
        for raw in paths {
            var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            if path.hasPrefix("~") {
                path = NSHomeDirectory() + String(path.dropFirst())
            }
            path = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != "/", FileManager.default.fileExists(atPath: parent) {
                return parent
            }
        }
        return nil
    }

    static func pathsMentioned(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || ",;".contains($0) })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
    }

    static func extractSessionID(from raw: String) -> String? {
        let normalized = normalizeTerminalOutput(raw)

        if let regex = try? NSRegularExpression(
            pattern: #"(?:session_id:|Session:)\s*(\d{8}_\d{6}_[0-9a-f]+)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            if let match = regex.firstMatch(in: normalized, range: range),
               let idRange = Range(match.range(at: 1), in: normalized) {
                return String(normalized[idRange])
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"hermes\s+--resume\s+(\d{8}_\d{6}_[0-9a-f]+)"#) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            if let match = regex.firstMatch(in: normalized, range: range),
               let idRange = Range(match.range(at: 1), in: normalized) {
                return String(normalized[idRange])
            }
        }

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for line in lines.reversed() {
            let lower = line.lowercased()
            guard lower.hasPrefix("session_id:") else { continue }
            let inline = line.dropFirst("session_id:".count).trimmingCharacters(in: .whitespaces)
            if isSessionValue(inline) { return inline }
        }

        guard let header = lines.first?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("session_id:") else { return nil }
        let inline = header.dropFirst("session_id:".count).trimmingCharacters(in: .whitespaces)
        if isSessionValue(inline) { return inline }
        if inline.isEmpty, lines.count > 1 {
            let value = lines[1].trimmingCharacters(in: .whitespaces)
            if isSessionValue(value) { return value }
        }
        return nil
    }

    /// Full Hermes CLI transcript for the verbose chat panel (tool traces, boxes, session footer).
    static func transcriptDisplayText(from raw: String) -> String {
        normalizeTerminalOutput(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeTerminalOutput(_ raw: String) -> String {
        var text = stripANSI(raw)
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text
    }

    static func stripANSI(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[(?:\d{1,3})(?:;\d{1,3})*m"#,
            with: "",
            options: .regularExpression
        )
        return result
    }

    private static func preparePrompt(for message: String, verbose: Bool) -> String {
        if verbose {
            return expandSlashMessage(message)
        }
        guard HermesSlashQuery.matchesSlashCommand(message) else {
            return "\(spaceAgentPersona)\n\nUser: \(message)"
        }
        return expandSlashMessage(message)
    }

    private static func expandSlashMessage(_ message: String) -> String {
        guard HermesSlashQuery.matchesSlashCommand(message) else { return message }
        let semaphore = DispatchSemaphore(value: 0)
        var expanded = message
        HermesSlashCatalog.shared.expandSlashMessage(message) { result in
            expanded = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8)
        if expanded != message, expanded.contains("skill") || expanded.hasPrefix("[IMPORTANT") {
            return expanded
        }
        return message
    }

    func localSlashReply(for message: String) -> String? {
        Self.localSlashResponse(for: message)
    }

    private static func localSlashResponse(for message: String) -> String? {
        let lower = message.lowercased()
        if lower == "/stop" || lower.hasPrefix("/stop ") {
            return "Stopped."
        }
        if lower == "/help" || lower.hasPrefix("/commands") {
            return HermesSlashCatalog.shared.helpText()
        }
        if lower == "/new" || lower.hasPrefix("/new ") || lower == "/reset" {
            shared.resetSession()
            return "Started a new Hermes session — prior context cleared."
        }
        if lower.hasPrefix("/cwd ") {
            let path = String(message.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = resolveWorkspaceDirectory(path) {
                shared.setWorkingDirectory(resolved)
                return "Working directory set to \(resolved)."
            }
            return "Couldn't find that path."
        }
        if lower == "/cwd" {
            if let cwd = shared.activeWorkingDirectory {
                return "Working directory: \(cwd)"
            }
            return "No working directory set — drop a project folder or mention a path."
        }
        return nil
    }

    static let traceMaxCharacters = 72

    static func streamChunk(from raw: String) -> HermesStreamChunk? {
        if raw.lowercased().contains("session_id:") {
            let answer = stripSessionPrefix(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty, !isHermesToolOutput(answer) {
                let reply = compactReply(answer)
                guard !reply.isEmpty else { return nil }
                return HermesStreamChunk(text: reply, isTrace: false)
            }
        }
        if let trace = latestTraceLine(from: raw) {
            return HermesStreamChunk(text: trace, isTrace: true)
        }
        return nil
    }

    static func latestTraceLine(from raw: String) -> String? {
        var body = raw
        if let sessionRange = raw.range(of: "session_id:", options: [.caseInsensitive, .backwards]) {
            body = String(raw[..<sessionRange.lowerBound])
        }

        let lines = body
            .replacingOccurrences(of: "\r", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            if let trace = traceLabel(for: line) { return trace }
        }
        return nil
    }

    private static func traceLabel(for line: String) -> String? {
        let cleaned = line
            .replacingOccurrences(of: "┊", with: "")
            .replacingOccurrences(of: "│", with: "")
            .trimmingCharacters(in: .whitespaces)
        let lower = cleaned.lowercased()

        if lower.contains("omitted"), lower.contains("diff") {
            if let regex = try? NSRegularExpression(pattern: #"omitted\s+(\d+)"#),
               let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
               let range = Range(match.range(at: 1), in: lower) {
                return truncateTrace("Diff reviewed · \(lower[range]) lines")
            }
            return truncateTrace("Diff reviewed")
        }

        if lower.contains("review diff") { return truncateTrace("Review diff") }

        if cleaned.contains("→") || cleaned.contains("->") {
            if let path = pathFromDiffLine(cleaned) {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty { return truncateTrace("Editing \(name)") }
            }
            return truncateTrace("Editing file")
        }

        if lower.hasPrefix("running ") || lower.hasPrefix("executing ") {
            return truncateTrace(cleaned)
        }

        if line.contains("┊"), !lower.contains("review diff"), cleaned.count <= 48 {
            return truncateTrace(cleaned)
        }

        return nil
    }

    private static func pathFromDiffLine(_ line: String) -> String? {
        let arrow = line.contains("→") ? "→" : "->"
        let parts = line.components(separatedBy: arrow).map { $0.trimmingCharacters(in: .whitespaces) }
        let rawPath = parts.last ?? parts.first ?? ""
        return normalizeHermesPath(rawPath)
    }

    private static func normalizeHermesPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        else if path.hasPrefix("a/") { path = String(path.dropFirst(2)) }
        if path.hasPrefix("//") { path = String(path.dropFirst()) }
        return path
    }

    private static func truncateTrace(_ line: String) -> String {
        let oneLine = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard oneLine.count > traceMaxCharacters else { return oneLine }
        let end = oneLine.index(oneLine.startIndex, offsetBy: traceMaxCharacters - 1)
        return String(oneLine[..<end]) + "…"
    }

    static func fullDisplayText(from raw: String) -> String {
        let answer = stripSessionPrefix(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            if isHermesToolOutput(raw) {
                return "Done — check the project folder for your files."
            }
            return ""
        }
        return answer
    }

    static func finalDisplayText(from raw: String) -> String {
        let full = fullDisplayText(from: raw)
        guard !full.isEmpty else { return "" }
        return compactReply(full)
    }

    static func compactReply(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = removeFencedBlocks(from: text)
        if looksLikeCodeDump(text) {
            text = preambleBeforeCode(in: text)
        }
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: #"\n{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        if text.count > compactMaxCharacters {
            text = firstSentences(in: text, maxSentences: 2, maxCharacters: compactMaxCharacters)
        }
        if text.count > compactMaxCharacters {
            let end = text.index(text.startIndex, offsetBy: compactMaxCharacters)
            text = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }

    private static func removeFencedBlocks(from text: String) -> String {
        var result = text
        while let start = result.range(of: "```") {
            guard let end = result.range(of: "```", range: start.upperBound..<result.endIndex) else {
                result = String(result[..<start.lowerBound])
                break
            }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHermesToolOutput(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("review diff") { return true }
        if text.contains("→") || text.contains(" -> ") { return true }
        if text.range(of: #"a/.+\s*→\s*b/"#, options: .regularExpression) != nil { return true }
        if text.contains("@@") { return true }
        if text.range(of: #"(?m)^\s*[┊│|├└]"#, options: .regularExpression) != nil { return true }
        if looksLikeCodeDump(text) { return true }

        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.isEmpty { return false }
        let toolish = lines.filter { line in
            line.lowercased().contains("review diff")
                || line.hasPrefix("a/")
                || line.hasPrefix("b/")
                || line.contains("/Users/")
                || line.hasPrefix("@@")
                || isCodeLikeLine(line)
        }
        return toolish.count >= 1 && toolish.count * 2 >= lines.count
    }

    private static func looksLikeCodeDump(_ text: String) -> Bool {
        if text.contains("<!DOCTYPE") || text.contains("<html") { return true }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return false }
        let codey = lines.filter(isCodeLikeLine).count
        return codey >= 2 || (Double(codey) / Double(lines.count)) > 0.35
    }

    private static func isCodeLikeLine(_ line: String) -> Bool {
        if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@") { return true }
        if line.hasPrefix("<") || line.hasPrefix("</") { return true }
        if line.lowercased().contains("review diff") { return true }
        let prefixes = ["const ", "let ", "var ", "function ", "import ", "export ", "class ", "def ", "public ", "private "]
        return prefixes.contains { line.hasPrefix($0) }
    }

    private static func preambleBeforeCode(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if isCodeLikeLine(t) { break }
            kept.append(t)
        }
        let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
        return "Done — I wrote the files; open them in your editor."
    }

    private static func firstSentences(in text: String, maxSentences: Int, maxCharacters: Int) -> String {
        var sentences: [String] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            if ".!?".contains(ch) {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                buffer = ""
                if sentences.count >= maxSentences { break }
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, sentences.count < maxSentences { sentences.append(tail) }
        let joined = sentences.joined(separator: " ")
        if joined.count <= maxCharacters { return joined }
        return joined
    }

    private static func stripSessionPrefix(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.lowercased().contains("session_id") else { return trimmed }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return "" }

        if let idx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("session_id:") }) {
            return lines[(idx + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while let first = lines.first?.trimmingCharacters(in: .whitespaces), first.isEmpty {
            lines.removeFirst()
        }
        guard let header = lines.first?.trimmingCharacters(in: .whitespaces) else { return "" }
        guard header.lowercased().hasPrefix("session_id:") else { return trimmed }

        var start = 1
        let inline = header.dropFirst("session_id:".count).trimmingCharacters(in: .whitespaces)
        if inline.isEmpty, start < lines.count {
            let value = lines[start].trimmingCharacters(in: .whitespaces)
            if isSessionValue(value) || isPartialSessionValue(value) { start += 1 }
        } else if !inline.isEmpty, !isSessionValue(inline), !isPartialSessionValue(inline) {
            return String(inline)
        }

        guard start < lines.count else { return "" }
        return lines[start...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSessionValue(_ line: String) -> Bool {
        line.range(of: #"^\d{8}_\d{6}_[0-9a-f]+$"#, options: .regularExpression) != nil
    }

    private static func isPartialSessionValue(_ line: String) -> Bool {
        line.range(of: #"^\d{8}_"#, options: .regularExpression) != nil
    }

    private func findHermes() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Verbose transcript parsing (full chat panel)

enum HermesTranscriptBlock: Equatable, Identifiable {
    case status(String)
    case toolTrace(String)
    case reply(String)
    case sessionMeta(session: String, duration: String?, messages: String?)

    var id: String {
        switch self {
        case .status(let text): return "status-\(text)"
        case .toolTrace(let text): return "trace-\(text)"
        case .reply(let text): return "reply-\(text.hashValue)"
        case .sessionMeta(let session, let duration, let messages):
            return "meta-\(session)-\(duration ?? "")-\(messages ?? "")"
        }
    }
}

enum HermesTranscriptParser {
    private static let boxChars = CharacterSet(charactersIn: "─━│┌┐└┘╭╮╰╯├┤┬┴┼═║╔╗╚╝╠╣╦╩╬ ")

    static func parse(_ raw: String) -> [HermesTranscriptBlock] {
        let text = HermesChatClient.normalizeTerminalOutput(raw)
        guard !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: "\n")
        var blocks: [HermesTranscriptBlock] = []
        var replyLines: [String] = []
        var inReply = false
        var sessionId: String?
        var duration: String?
        var messageSummary: String?

        func flushReply() {
            let body = replyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            replyLines = []
            inReply = false
            guard !body.isEmpty else { return }
            blocks.append(.reply(body))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("Session:") {
                flushReply()
                sessionId = valueAfterColon(trimmed)
                continue
            }
            if trimmed.hasPrefix("Duration:") {
                duration = valueAfterColon(trimmed)
                continue
            }
            if trimmed.hasPrefix("Messages:") {
                messageSummary = valueAfterColon(trimmed)
                continue
            }
            if trimmed.hasPrefix("Resume this session")
                || trimmed.hasPrefix("hermes --resume")
                || trimmed.hasPrefix("Query:") {
                continue
            }
            if trimmed.hasPrefix("Initializing") {
                flushReply()
                blocks.append(.status(trimmed))
                continue
            }
            if isHermesBoxTop(trimmed) {
                flushReply()
                inReply = true
                continue
            }
            if isHermesBoxBottom(trimmed) {
                flushReply()
                continue
            }
            if isSeparatorOnly(trimmed) { continue }

            if isToolTrace(line) {
                flushReply()
                let trace = cleanToolTrace(line)
                if !trace.isEmpty { blocks.append(.toolTrace(trace)) }
                continue
            }

            if inReply {
                replyLines.append(unindent(line))
                continue
            }
        }

        if inReply, !replyLines.isEmpty {
            let body = replyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { blocks.append(.reply(body)) }
        }

        if let sessionId {
            blocks.append(.sessionMeta(session: sessionId, duration: duration, messages: messageSummary))
        }

        return blocks
    }

    private static func valueAfterColon(_ line: String) -> String {
        guard let idx = line.firstIndex(of: ":") else { return line }
        return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isHermesBoxTop(_ line: String) -> Bool {
        line.contains("╭") && line.localizedCaseInsensitiveContains("hermes")
    }

    private static func isHermesBoxBottom(_ line: String) -> Bool {
        line.hasPrefix("╰")
    }

    private static func isSeparatorOnly(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        return line.unicodeScalars.allSatisfy { boxChars.contains($0) }
    }

    private static func isToolTrace(_ line: String) -> Bool {
        line.contains("┊")
    }

    private static func cleanToolTrace(_ line: String) -> String {
        var text = line
            .replacingOccurrences(of: "┊", with: "")
            .replacingOccurrences(of: "│", with: "")
            .trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text
    }

    private static func unindent(_ line: String) -> String {
        if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
        return line.trimmingCharacters(in: .whitespaces)
    }
}