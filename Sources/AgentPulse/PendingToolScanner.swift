import Foundation

/// Reads a Claude Code transcript (.jsonl) and finds the most recent
/// `tool_use` block — i.e. the tool that's currently sitting on a
/// permission_prompt.
///
/// Streams the tail of the file so a many-MB transcript doesn't blow up
/// memory. We only need the *last* tool_use, so we walk backwards once we
/// have enough buffered.
enum PendingToolScanner {
    /// Up to ~1 MB tail is more than enough — a single assistant turn is
    /// rarely more than a few KB.
    private static let tailBytes: Int = 1 * 1024 * 1024

    static func scanLastToolUse(at path: String) -> PendingTool? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Seek to (eof - tailBytes), clamped at 0.
        let eof = (try? handle.seekToEnd()) ?? 0
        let start = eof > UInt64(tailBytes) ? eof - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd() else { return nil }

        // Walk lines back to front so the *last* tool_use wins. We can stop
        // as soon as we find one whose tool_use_id doesn't appear in any
        // *later* tool_result — but for simplicity (Claude only ever has
        // one outstanding tool_use during a permission_prompt) we just
        // return the very last tool_use.
        let newline: UInt8 = 0x0a
        var end = data.endIndex
        var idx = data.endIndex
        while idx > data.startIndex {
            idx = data.index(before: idx)
            if data[idx] == newline || idx == data.startIndex {
                let lineStart = data[idx] == newline ? data.index(after: idx) : idx
                if lineStart < end {
                    let line = data.subdata(in: lineStart..<end)
                    if let tool = parseToolUse(line) {
                        return tool
                    }
                }
                end = idx
            }
        }
        return nil
    }

    private static func parseToolUse(_ line: Data) -> PendingTool? {
        // Cheap pre-filter so we don't parse JSON for every plain message.
        guard line.range(of: Data("\"tool_use\"".utf8)) != nil else { return nil }

        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }

        // The relevant block is the *last* tool_use in the assistant message
        // (a single turn can contain narration text + a single tool call).
        var last: [String: Any]?
        for block in content where block["type"] as? String == "tool_use" {
            last = block
        }
        guard let tu = last,
              let name = tu["name"] as? String
        else { return nil }
        let input = tu["input"] as? [String: Any] ?? [:]
        return PendingTool(name: name, summary: summarize(name: name, input: input))
    }

    /// One-line preview of the tool input. Mirrors the scope of the
    /// existing PreToolUse `tool_summary` extraction in `report.sh`.
    private static func summarize(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            if let cmd = input["command"] as? String { return collapseWhitespace(cmd) }
        case "Edit", "Write", "Read", "NotebookEdit":
            if let p = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) {
                return p
            }
        case "Glob", "Grep":
            if let pat = input["pattern"] as? String { return pat }
        case "WebFetch":
            if let url = input["url"] as? String { return url }
        case "WebSearch":
            if let q = input["query"] as? String { return q }
        case "Task":
            if let desc = input["description"] as? String { return desc }
        default:
            break
        }
        // Generic fallback: first string value we find.
        for v in input.values {
            if let s = v as? String, !s.isEmpty { return collapseWhitespace(s) }
        }
        return ""
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
