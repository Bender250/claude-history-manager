import Foundation

/// Parses one Claude Desktop agent-mode session into the canonical
/// `SessionMetadata` shape.
///
/// The heavy lifting is `JsonlParser`'s — the `message` payloads in
/// `audit.jsonl` are exactly Claude Code's, so message counts, token
/// totals and flags all come out of the existing walker. This type adds
/// the two things that differ:
///
///  1. the session UUID comes from the enclosing `local_<uuid>/`
///     directory, not the filename (which is always `audit.jsonl`), and
///  2. the `local_<uuid>.json` sidecar carries an explicit `title`,
///     `model`, `createdAt` and `lastActivityAt`, which beat anything
///     inferred from the transcript.
public struct ClaudeDesktopParser: SessionParser {
    private let inner = JsonlParser()

    public init() {}

    public enum ParseError: Error {
        /// The path didn't look like `.../local_<uuid>/audit.jsonl`.
        case unrecognizedLayout(URL)
    }

    public func parse(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
        guard let uuid = Self.sessionUUID(forAuditFile: url) else {
            throw ParseError.unrecognizedLayout(url)
        }
        let sessionID = try SessionID(string: uuid)
        let (parsed, flags) = try inner.parseWithFlags(
            url: url,
            workspaceID: workspaceID,
            sessionIDOverride: sessionID
        )
        let sidecar = Self.readSidecar(forAuditFile: url)

        return (
            SessionMetadata(
                sessionID: parsed.sessionID,
                workspaceID: parsed.workspaceID,
                // Desktop records a real title; only fall back to the
                // first-user-message heuristic when it's missing.
                title: sidecar?.title ?? parsed.title,
                createdAt: sidecar?.createdAt ?? parsed.createdAt,
                lastModifiedAt: sidecar?.lastActivityAt ?? parsed.lastModifiedAt,
                messageCount: parsed.messageCount,
                tokenCount: parsed.tokenCount,
                inputTokens: parsed.inputTokens,
                outputTokens: parsed.outputTokens,
                model: sidecar?.model ?? parsed.model,
                isLive: false
            ),
            flags
        )
    }

    // MARK: - Sidecar

    /// The subset of `local_<uuid>.json` worth reading. Claude Desktop
    /// writes ~30 keys there; the rest (system prompt, MCP config, egress
    /// policy) is session configuration we don't surface.
    public struct Sidecar: Sendable, Equatable {
        public let title: String?
        public let model: String?
        public let cwd: String?
        public let createdAt: Date?
        public let lastActivityAt: Date?
        public let isArchived: Bool
        /// Folders the user granted the session access to. The closest
        /// thing Desktop has to a working directory, and the only
        /// meaningful way to bucket these sessions into workspaces.
        public let userSelectedFolders: [String]
    }

    /// Reads the sidecar sitting next to the `local_<uuid>/` directory.
    /// Returns nil when it's absent or unreadable — every field it
    /// provides has a transcript-derived fallback.
    public static func readSidecar(forAuditFile auditURL: URL) -> Sidecar? {
        let sessionDir = auditURL.deletingLastPathComponent()
        let sidecarURL = sessionDir
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionDir.lastPathComponent).json", isDirectory: false)
        return readSidecar(at: sidecarURL)
    }

    public static func readSidecar(at url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Desktop writes epoch milliseconds, unlike the ISO-8601 strings
        // in the transcript itself.
        func date(_ key: String) -> Date? {
            guard let ms = obj[key] as? Double, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Sidecar(
            title: title,
            model: (obj["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            cwd: (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: date("createdAt"),
            lastActivityAt: date("lastActivityAt"),
            isArchived: obj["isArchived"] as? Bool ?? false,
            userSelectedFolders: (obj["userSelectedFolders"] as? [String]) ?? []
        )
    }

    // MARK: - Helpers

    /// `.../local_<uuid>/audit.jsonl` → `<uuid>`. Nil if the parent
    /// directory isn't a `local_`-prefixed UUID.
    public static func sessionUUID(forAuditFile url: URL) -> String? {
        let dir = url.deletingLastPathComponent().lastPathComponent
        guard dir.hasPrefix("local_") else { return nil }
        let candidate = String(dir.dropFirst("local_".count))
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }
}
