import Foundation

/// Claude Desktop's local agent-mode sessions (the in-app agent, a.k.a.
/// Cowork) — distinct from Claude Code's `~/.claude/projects/` even though
/// the two write the same message payloads.
///
/// On-disk layout:
///
///     ~/Library/Application Support/Claude/local-agent-mode-sessions/
///       <account-uuid>/
///         <space-uuid>/
///           local_<session-uuid>.json     ← sidecar metadata
///           local_<session-uuid>/
///             audit.jsonl                 ← the transcript
///             outputs/ uploads/ …
///
/// The sidecar is a gift: `title`, `model`, `createdAt`, `lastActivityAt`
/// and `isArchived` are all recorded explicitly, so unlike every other
/// provider we don't have to infer a title from the first user message.
///
/// `audit.jsonl` is Claude Code's JSONL with a slightly different
/// envelope — `session_id` for `sessionId`, `_audit_timestamp` for
/// `timestamp`, plus HMAC fields we ignore. The `message` object inside
/// is byte-identical, so both `JsonlParser` and `TranscriptParser` handle
/// these files once they know to look for the alternate envelope keys.
///
/// Read-only: there is no CLI that can resume one of these, so
/// `supportsResume` is false and the UI hides its resume affordances.
public struct ClaudeDesktopProvider: Provider {
    public static let id: ProviderID = .claudeDesktop
    public let displayName = "Claude Desktop"
    public let iconAssetName = "claude"
    public let supportsResume = false

    public init() {}

    public func isAvailable() -> Bool {
        // One session with a transcript is enough; walking the whole tree
        // on every launch would cost more than the tile is worth.
        !Self.enumerateSessions(under: Self.sessionsRoot(), limit: 1).isEmpty
    }

    public func watchRoots() -> [URL] { [Self.sessionsRoot()] }

    public func makeParser() -> any SessionParser { ClaudeDesktopParser() }

    /// Required by the protocol but never dispatched — `supportsResume`
    /// is false, so `SessionLauncher` never asks. Returns a command that
    /// merely brings Claude Desktop to the front, which is the closest
    /// honest approximation if a future caller ignores the flag.
    public func resumeCommand(
        sessionID: String,
        cwd: String,
        terminal: Terminal,
        loginShell: String
    ) -> LaunchCommand {
        LaunchCommand(executable: "/usr/bin/open", arguments: ["-a", "Claude"])
    }

    public static func sessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude/local-agent-mode-sessions",
                isDirectory: true
            )
    }

    /// One discovered session: where its transcript lives, plus the
    /// space it belongs to (used for workspace bucketing when the
    /// sidecar carries no user-selected folder).
    public struct DiscoveredSession: Sendable, Equatable {
        /// `.../<space>/local_<uuid>/audit.jsonl`
        public let auditURL: URL
        /// `.../<space>/local_<uuid>.json`, absent for a session whose
        /// sidecar was never written (Claude Desktop killed mid-start).
        public let sidecarURL: URL?
        /// The `<space-uuid>` directory name.
        public let spaceID: String
        /// Bare session UUID — the `local_` prefix stripped, because
        /// `SessionID` only accepts a canonical UUID.
        public let sessionUUID: String
    }

    /// Walks `<account>/<space>/local_*/audit.jsonl`. Depth is fixed by
    /// the layout above rather than using a deep enumerator, so an
    /// unrelated directory dropped into Application Support can't send
    /// us walking a large tree. `limit` short-circuits the walk for the
    /// availability probe.
    public static func enumerateSessions(
        under root: URL,
        limit: Int = .max
    ) -> [DiscoveredSession] {
        let fm = FileManager.default
        var found: [DiscoveredSession] = []

        func children(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        for account in children(root) where isDirectory(account) {
            for space in children(account) where isDirectory(space) {
                for entry in children(space) where isDirectory(entry) {
                    let name = entry.lastPathComponent
                    guard name.hasPrefix("local_") else { continue }
                    let audit = entry.appendingPathComponent("audit.jsonl", isDirectory: false)
                    guard fm.fileExists(atPath: audit.path) else { continue }

                    let uuid = String(name.dropFirst("local_".count))
                    // Anything that isn't a real UUID can't become a
                    // `SessionID`, so skip rather than fail downstream.
                    guard UUID(uuidString: uuid) != nil else { continue }

                    let sidecar = space.appendingPathComponent("\(name).json", isDirectory: false)
                    found.append(
                        DiscoveredSession(
                            auditURL: audit,
                            sidecarURL: fm.fileExists(atPath: sidecar.path) ? sidecar : nil,
                            spaceID: space.lastPathComponent,
                            sessionUUID: uuid
                        )
                    )
                    if found.count >= limit { return found }
                }
            }
        }
        return found
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
