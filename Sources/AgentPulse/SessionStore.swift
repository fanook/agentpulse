import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let persistURL: URL

    private var lastTitleScan: [String: Date] = [:]
    private let titleScanCooldown: TimeInterval = 5

    /// sessionId → active file-system watcher on its transcript. Reacts to
    /// writes so `/rename` updates (and any future transcript-derived state)
    /// show up within a few ms instead of waiting for a poll.
    private var titleWatchers: [String: (source: DispatchSourceFileSystemObject, path: String)] = [:]
    private let watcherQueue = DispatchQueue(label: "agentpulse.title-watcher", qos: .utility)

    init() {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
        let base = appSupport.appendingPathComponent("AgentPulse", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        persistURL = base.appendingPathComponent("sessions.json")

        // One-time migration from the old "Tap" directory.
        let legacy = appSupport.appendingPathComponent("Tap", isDirectory: true)
        let legacySessions = legacy.appendingPathComponent("sessions.json")
        if !fm.fileExists(atPath: persistURL.path),
           fm.fileExists(atPath: legacySessions.path) {
            try? fm.copyItem(at: legacySessions, to: persistURL)
        }

        load()
        // Wire up file-system watchers for any sessions restored from disk.
        for s in sessions {
            ensureTitleWatcher(for: s.id, path: s.transcriptPath)
        }
    }

    private func refreshCustomTitle(for sessionId: String, path: String?) {
        guard let path, !path.isEmpty else { return }
        let now = Date()
        if let last = lastTitleScan[sessionId], now.timeIntervalSince(last) < titleScanCooldown {
            return
        }
        lastTitleScan[sessionId] = now

        Task.detached {
            guard let title = Self.scanCustomTitle(at: path) else { return }
            await MainActor.run {
                guard let i = self.sessions.firstIndex(where: { $0.id == sessionId }),
                      self.sessions[i].customTitle != title else { return }
                self.sessions[i].customTitle = title
                self.save()
            }
        }
    }

    /// Start (or replace) a DispatchSource watcher on the session transcript.
    /// Fires on write/extend/rename/delete and runs a title scan — throttled
    /// by the per-session cooldown.
    private func ensureTitleWatcher(for sessionId: String, path: String?) {
        guard let path, !path.isEmpty else { return }
        if let existing = titleWatchers[sessionId], existing.path == path { return }
        stopTitleWatcher(for: sessionId)

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: watcherQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshCustomTitle(for: sessionId, path: path)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        titleWatchers[sessionId] = (source, path)

        // Kick off an initial scan so existing `/rename` records are picked up
        // before any new writes arrive.
        refreshCustomTitle(for: sessionId, path: path)
    }

    private func stopTitleWatcher(for sessionId: String) {
        titleWatchers[sessionId]?.source.cancel()
        titleWatchers.removeValue(forKey: sessionId)
    }

    /// Scan the session transcript (Claude stores this as .jsonl) for the
    /// most recent `custom-title` entry. Uses a streaming chunked read so
    /// multi-hundred-MB transcripts don't blow up memory.
    nonisolated private static func scanCustomTitle(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let needle = Data("\"type\":\"custom-title\"".utf8)
        let newline: UInt8 = 0x0a
        var latest: String?
        var carry = Data()
        let chunkSize = 256 * 1024

        func process(_ line: Data) {
            guard line.range(of: needle) != nil else { return }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let title = obj["customTitle"] as? String {
                latest = title
            }
        }

        while let data = try? handle.read(upToCount: chunkSize), !data.isEmpty {
            carry.append(data)

            var searchStart = carry.startIndex
            while let nlIdx = carry[searchStart...].firstIndex(of: newline) {
                let line = carry.subdata(in: searchStart..<nlIdx)
                process(line)
                searchStart = carry.index(after: nlIdx)
            }

            // Keep only the trailing (incomplete) line for the next round.
            if searchStart < carry.endIndex {
                carry = carry.subdata(in: searchStart..<carry.endIndex)
            } else {
                carry.removeAll(keepingCapacity: true)
            }
        }

        if !carry.isEmpty {
            process(carry)
        }
        return latest
    }

    var waitingCount: Int {
        sessions.filter { $0.status == .waiting }.count
    }

    func apply(_ event: HookEvent) {
        let now = Date()
        let idx = sessions.firstIndex(where: { $0.id == event.sessionId })

        // Every event carries a cwd; keep it fresh so renames / cd propagate.
        if let i = idx, let cwd = event.cwd, !cwd.isEmpty, sessions[i].cwd != cwd {
            sessions[i].cwd = cwd
            sessions[i].updatedAt = now
        }

        // Wire up / refresh the transcript watcher whenever we learn a path.
        if let tp = event.transcriptPath, !tp.isEmpty {
            if let i = idx { sessions[i].transcriptPath = tp }
            ensureTitleWatcher(for: event.sessionId, path: tp)
        } else if let i = idx {
            ensureTitleWatcher(for: event.sessionId, path: sessions[i].transcriptPath)
        }

        switch event.event {
        case "SessionStart":
            // A new session starts in idle — Claude is just sitting at the
            // prompt waiting for user input, not actually doing anything.
            // Real work transitions happen via UserPromptSubmit / PreToolUse.
            if let i = idx {
                sessions[i].agent = event.agent ?? sessions[i].agent
                sessions[i].cwd = event.cwd ?? sessions[i].cwd
                sessions[i].status = .idle
                sessions[i].activity = nil
                sessions[i].updatedAt = now
                sessions[i].terminal = event.terminal ?? sessions[i].terminal
                sessions[i].transcriptPath = event.transcriptPath ?? sessions[i].transcriptPath
            } else {
                sessions.append(Session(
                    id: event.sessionId,
                    agent: event.agent,
                    cwd: event.cwd ?? "~",
                    status: .idle,
                    startedAt: now,
                    updatedAt: now,
                    lastNotification: nil,
                    transcriptPath: event.transcriptPath,
                    terminal: event.terminal
                ))
            }

        case "Stop":
            if let i = idx {
                // Stop = turn ended. Any prior permission_prompt has been
                // resolved by now (approved or denied), so drop back to idle.
                sessions[i].status = .idle
                sessions[i].lastNotification = nil
                sessions[i].activity = nil
                sessions[i].updatedAt = now
            } else {
                // Unknown session — create a placeholder so user sees it.
                sessions.append(Session(
                    id: event.sessionId,
                    agent: event.agent,
                    cwd: event.cwd ?? "~",
                    status: .idle,
                    startedAt: now,
                    updatedAt: now,
                    lastNotification: nil,
                    transcriptPath: event.transcriptPath,
                    terminal: event.terminal
                ))
            }

        case "Notification":
            // Only permission_prompt is a true "go look at me now" signal.
            // idle_prompt just means Claude is waiting for the next turn —
            // that's idle, not an interruption.
            let newStatus: SessionStatus = (event.notificationType == "permission_prompt") ? .waiting : .idle
            if let i = idx {
                sessions[i].status = newStatus
                sessions[i].lastNotification = event.notificationType
                sessions[i].updatedAt = now
            } else {
                sessions.append(Session(
                    id: event.sessionId,
                    agent: event.agent,
                    cwd: event.cwd ?? "~",
                    status: newStatus,
                    startedAt: now,
                    updatedAt: now,
                    lastNotification: event.notificationType,
                    transcriptPath: event.transcriptPath,
                    terminal: event.terminal
                ))
            }

        case "UserPromptSubmit":
            if let i = idx {
                sessions[i].status = .thinking
                sessions[i].activity = nil
                sessions[i].updatedAt = now
            } else {
                sessions.append(Session(
                    id: event.sessionId,
                    agent: event.agent,
                    cwd: event.cwd ?? "~",
                    status: .thinking,
                    startedAt: now,
                    updatedAt: now,
                    lastNotification: nil,
                    transcriptPath: event.transcriptPath,
                    terminal: event.terminal
                ))
            }

        case "PreToolUse":
            if let i = idx {
                let label = [event.toolName, event.toolSummary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                sessions[i].activity = label.isEmpty ? nil : label
                sessions[i].status = .running
                sessions[i].updatedAt = now
            }

        case "PostToolUse":
            if let i = idx {
                sessions[i].activity = nil
                // After a tool finishes, Claude may reason some more before
                // the next tool call — show that as thinking rather than
                // leaving the old "running" label stuck.
                sessions[i].status = .thinking
                sessions[i].updatedAt = now
            }

        case "CwdChanged":
            // Handled by the generic cwd-refresh at the top of apply(); nothing else to do.
            if let i = idx { sessions[i].updatedAt = now }

        case "SessionEnd":
            stopTitleWatcher(for: event.sessionId)
            sessions.removeAll { $0.id == event.sessionId }

        default:
            break
        }

        save()
    }

    func remove(id: String) {
        stopTitleWatcher(for: id)
        sessions.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistURL) else { return }
        // Tolerant load: skip entries that fail to decode (e.g. stale schema
        // with an old status enum case) rather than losing the whole file.
        if let decoded = try? JSONDecoder.iso.decode([Session].self, from: data) {
            sessions = decoded
            return
        }
        if let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            var recovered: [Session] = []
            for raw in rawArray {
                guard let obj = raw as? [String: Any],
                      let bytes = try? JSONSerialization.data(withJSONObject: obj),
                      let session = try? JSONDecoder.iso.decode(Session.self, from: bytes)
                else { continue }
                recovered.append(session)
            }
            sessions = recovered
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(sessions) else { return }
        try? data.write(to: persistURL, options: .atomic)
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
