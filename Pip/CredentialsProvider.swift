import Foundation

/// Pulls the OAuth access token from the local Claude Code Max session.
/// No API key, no cloud account — the token is already on disk:
///   (a) macOS login Keychain item "Claude Code-credentials"
///   (b) fallback file ~/.claude/.credentials.json
/// Both store JSON with a nested access token (e.g. claudeAiOauth.accessToken),
/// probed defensively in case the shape changes.
///
/// Blocking (runs `/usr/bin/security`) — call from a background queue.
enum CredentialsProvider {

    static func loadAccessToken() -> String? {
        if let t = fromKeychain(), !t.isEmpty { return t }
        if let t = fromCredentialsFile(), !t.isEmpty { return t }
        return nil
    }

    private static func fromKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let token = extractToken(fromJSONString: raw) { return token }
        // Some setups store the bare token rather than JSON.
        return raw.hasPrefix("{") ? nil : raw
    }

    private static func fromCredentialsFile() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return extractToken(fromJSONString: raw)
    }

    private static func extractToken(fromJSONString raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = JSONProbe.parse(data) else { return nil }
        return JSONProbe.firstString(in: object, keys: ["accessToken", "access_token"])
    }
}
