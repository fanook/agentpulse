import Foundation

/// Runtime-selected connection info for the local HTTP bridge.
///
/// AgentPulse writes two files that hooks read to find the daemon:
///   - ~/.pulse/port   — the TCP port the daemon bound to this run
///   - ~/.pulse/token  — a long-random secret hooks send in X-AgentPulse-Token
///
/// Hooks don't care which port we ended up on (in case 9876 was busy),
/// and an attacker that only has localhost access can't forge events
/// without reading the token file from disk.
enum Runtime {
    /// Preferred port; daemon tries this first, then nearby ports.
    static let preferredPort: UInt16 = 9876
    static let maxPortTries: UInt16 = 20

    static var runtimeDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pulse", isDirectory: true)
    }

    static var portFile: URL  { runtimeDir.appendingPathComponent("port") }
    static var tokenFile: URL { runtimeDir.appendingPathComponent("token") }

    /// Legacy ~/.tap dir from the pre-rename version — migrate silently if found.
    static var legacyTapDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tap", isDirectory: true)
    }

    @discardableResult
    static func ensureRuntimeDir() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            migrateLegacyIfNeeded()
            return true
        } catch {
            NSLog("[AgentPulse] failed to create \(runtimeDir.path): \(error)")
            return false
        }
    }

    private static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        let legacyToken = legacyTapDir.appendingPathComponent("token")
        let legacyPort  = legacyTapDir.appendingPathComponent("port")
        if !fm.fileExists(atPath: tokenFile.path), fm.fileExists(atPath: legacyToken.path) {
            try? fm.copyItem(at: legacyToken, to: tokenFile)
        }
        if !fm.fileExists(atPath: portFile.path), fm.fileExists(atPath: legacyPort.path) {
            try? fm.copyItem(at: legacyPort, to: portFile)
        }
    }

    /// Return existing token or mint a new one and persist it 0600.
    static func loadOrCreateToken() -> String {
        ensureRuntimeDir()
        if let data = try? Data(contentsOf: tokenFile),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.count >= 16 {
            return s
        }
        let token = randomToken()
        try? token.data(using: .utf8)?.write(to: tokenFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: tokenFile.path)
        return token
    }

    static func writePortFile(_ port: UInt16) {
        ensureRuntimeDir()
        try? "\(port)".data(using: .utf8)?.write(to: portFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: portFile.path)
    }

    static func clearPortFile() {
        try? FileManager.default.removeItem(at: portFile)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
