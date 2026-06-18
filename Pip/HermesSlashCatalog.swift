import AppKit
import Combine
import Foundation

struct HermesSlashItem: Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case command, skill }

    var id: String { command }
    let command: String
    let description: String
    let category: String
    let kind: Kind

    var insertText: String { command + " " }
}

struct HermesSlashCatalogSnapshot: Equatable {
    var commands: [HermesSlashItem] = []
    var skills: [HermesSlashItem] = []
    var loadedAt: Date = .distantPast

    var allItems: [HermesSlashItem] { commands + skills }

    static let empty = HermesSlashCatalogSnapshot()
}

enum HermesSlashQuery {
    /// Hermes slash detection — `/help` yes, `/Users/foo` no.
    static func active(in text: String, caret: Int) -> (query: String, range: NSRange)? {
        let safeCaret = max(0, min(caret, (text as NSString).length))
        let prefix = (text as NSString).substring(to: safeCaret)
        guard let slashIndex = prefix.lastIndex(of: "/") else { return nil }

        let tokenStart = prefix.distance(from: prefix.startIndex, to: slashIndex)
        if tokenStart > 0 {
            let prev = prefix[prefix.index(before: slashIndex)]
            if !prev.isWhitespace && prev != "\n" { return nil }
        }

        let token = String(prefix[slashIndex...])
        if token.dropFirst().contains("/") { return nil }

        let query = String(token.dropFirst())
        if query.contains(" ") || query.contains("\n") { return nil }
        return (query, NSRange(location: tokenStart, length: safeCaret - tokenStart))
    }

    static func matchesSlashCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        return trimmed.range(of: #"^/[^\s/]+"#, options: .regularExpression) != nil
    }
}

final class HermesSlashCatalog {
    static let shared = HermesSlashCatalog()

    private let queue = DispatchQueue(label: "pip.slash-catalog", qos: .utility)
    private var snapshot = HermesSlashCatalogSnapshot.empty
    private let lock = NSLock()

    private init() {}

    func cachedSnapshot() -> HermesSlashCatalogSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func refreshIfNeeded(force: Bool = false) {
        lock.lock()
        let stale = Date().timeIntervalSince(snapshot.loadedAt) > 600
        lock.unlock()
        guard force || stale || snapshot.allItems.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let loaded = Self.loadCatalog()
            self.lock.lock()
            self.snapshot = loaded
            self.lock.unlock()
        }
    }

    func matches(query: String, limit: Int = 12) -> [HermesSlashItem] {
        let snap = cachedSnapshot()
        let needle = query.lowercased()
        var results: [HermesSlashItem] = []

        if needle.isEmpty {
            results.append(contentsOf: snap.commands.prefix(6))
            results.append(contentsOf: snap.skills.prefix(max(0, limit - results.count)))
            return Array(results.prefix(limit))
        }

        for item in snap.allItems {
            let cmd = item.command.lowercased().dropFirst()
            if cmd.hasPrefix(needle) || item.command.lowercased().contains(needle) {
                results.append(item)
            }
            if results.count >= limit { break }
        }
        return results
    }

    func helpText() -> String {
        let snap = cachedSnapshot()
        var lines = ["Pip slash commands:"]
        for item in snap.commands.prefix(12) {
            lines.append("\(item.command) — \(item.description)")
        }
        lines.append("")
        lines.append("Skills: type / then search (\(snap.skills.count) installed).")
        return lines.joined(separator: "\n")
    }

    func expandSlashMessage(_ message: String, completion: @escaping (String) -> Void) {
        queue.async {
            let expanded = Self.expandMessage(message) ?? message
            DispatchQueue.main.async { completion(expanded) }
        }
    }

    private static func loadCatalog() -> HermesSlashCatalogSnapshot {
        if let python = loadViaPython() { return python }
        return loadFallback()
    }

    private static func loadViaPython() -> HermesSlashCatalogSnapshot? {
        guard let script = locateScript() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var env = ProcessInfo.processInfo.environment
        env["HERMES_AGENT_HOME"] = locateHermesAgent()
        process.environment = env
        process.arguments = [script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONDecoder().decode(CatalogJSON.self, from: data) else { return nil }

        let commands = json.builtins.map {
            HermesSlashItem(command: $0.command, description: $0.description, category: $0.category, kind: .command)
        }
        let skills = json.skills.map {
            HermesSlashItem(command: $0.command, description: $0.description, category: $0.category, kind: .skill)
        }
        return HermesSlashCatalogSnapshot(commands: commands, skills: skills, loadedAt: Date())
    }

    private static func expandMessage(_ message: String) -> String? {
        guard let script = locateScript() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var env = ProcessInfo.processInfo.environment
        env["HERMES_AGENT_HOME"] = locateHermesAgent()
        process.environment = env
        process.arguments = [script, "expand", message]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func loadFallback() -> HermesSlashCatalogSnapshot {
        let commands = [
            HermesSlashItem(command: "/stop", description: "Stop the current reply", category: "Session", kind: .command),
            HermesSlashItem(command: "/help", description: "Show slash commands", category: "Info", kind: .command),
            HermesSlashItem(command: "/skills", description: "Installed skills", category: "Tools & Skills", kind: .command),
        ]
        let skills = scanSkillsFallback()
        return HermesSlashCatalogSnapshot(commands: commands, skills: skills, loadedAt: Date())
    }

    private static func scanSkillsFallback() -> [HermesSlashItem] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/skills", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [HermesSlashItem] = []
        var seen = Set<String>()
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SKILL.md" else { continue }
            let meta = parseSkillFrontmatter(url: url)
            let slug = slugify(meta.name ?? url.deletingLastPathComponent().lastPathComponent)
            let command = "/\(slug)"
            guard seen.insert(command).inserted else { continue }
            items.append(
                HermesSlashItem(
                    command: command,
                    description: meta.description ?? "",
                    category: "Skills",
                    kind: .skill
                )
            )
        }
        return items.sorted { $0.command < $1.command }
    }

    private static func parseSkillFrontmatter(url: URL) -> (name: String?, description: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        guard text.hasPrefix("---") else { return (nil, nil) }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return (nil, nil) }
        var name: String?
        var description: String?
        for line in parts.dropFirst() {
            if line == "---" { break }
            let s = String(line)
            if s.hasPrefix("name:") { name = s.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces) }
            if s.hasPrefix("description:") {
                description = s.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return (name, description)
    }

    private static func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let cleaned = lower.replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.replacingOccurrences(of: #"[^a-z0-9-]+"#, with: "", options: .regularExpression)
    }

    private static func locateHermesAgent() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["HERMES_AGENT_HOME"],
            "\(home)/.hermes/hermes-agent",
            "/opt/homebrew/share/hermes-agent",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "\(home)/.hermes/hermes-agent"
    }

    private static func locateScript() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.hermes/pip-slash-catalog.py",
            Bundle.main.resourcePath.map { "\($0)/pip-slash-catalog.py" },
            "\(home)/Desktop/pip-mascot/scripts/pip-slash-catalog.py",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) || FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private struct CatalogJSON: Decodable {
        struct Entry: Decodable {
            let command: String
            let description: String
            let category: String
        }

        let builtins: [Entry]
        let skills: [Entry]
    }
}

// MARK: - Composer slash popup state

final class SlashCompletionController: ObservableObject {
    @Published var isVisible = false
    @Published var items: [HermesSlashItem] = []
    @Published var selectedIndex = 0
    private(set) var replaceRange = NSRange(location: 0, length: 0)

    init() {
        HermesSlashCatalog.shared.refreshIfNeeded()
    }

    func refresh(text: String, caret: Int) {
        guard let active = HermesSlashQuery.active(in: text, caret: caret) else {
            dismiss()
            return
        }
        replaceRange = active.range
        items = HermesSlashCatalog.shared.matches(query: active.query)
        selectedIndex = 0
        isVisible = !items.isEmpty
    }

    func dismiss() {
        isVisible = false
        items = []
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    func applySelected(to textView: NSTextView) {
        guard items.indices.contains(selectedIndex) else { return }
        apply(items[selectedIndex], to: textView)
    }

    func apply(_ item: HermesSlashItem, to textView: NSTextView) {
        let ns = textView.string as NSString
        guard replaceRange.location != NSNotFound, replaceRange.length >= 0 else { return }
        let safeRange = NSRange(
            location: min(replaceRange.location, ns.length),
            length: min(replaceRange.length, max(0, ns.length - replaceRange.location))
        )
        let replacement = item.insertText
        textView.insertText(replacement, replacementRange: safeRange)
        let caret = safeRange.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        dismiss()
    }
}