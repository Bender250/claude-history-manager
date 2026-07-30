import Foundation

/// Watches Claude Desktop's `local-agent-mode-sessions/` tree.
///
/// Thin wrapper over the existing FSEvents `SessionsWatcher` — unlike
/// Codex there's no append-only index file to tail, so the directory
/// watch is the only channel. FSEvents is recursive, which is what we
/// need: transcripts sit three levels down at
/// `<account>/<space>/local_<uuid>/audit.jsonl`.
public actor ClaudeDesktopWatcher {
    public typealias ChangeHandler = @Sendable (ChangeSet) async -> Void

    public let sessionsRoot: URL
    public let latency: TimeInterval

    private var fsWatcher: SessionsWatcher?
    private var handler: ChangeHandler?

    public init(
        sessionsRoot: URL = ClaudeDesktopProvider.sessionsRoot(),
        latency: TimeInterval = 0.2
    ) {
        self.sessionsRoot = sessionsRoot
        self.latency = latency
    }

    /// Re-entrant: a second `start` before `stop` is a no-op.
    public func start(onChange: @escaping ChangeHandler) async {
        guard fsWatcher == nil else { return }
        handler = onChange
        let fs = SessionsWatcher(rootURL: sessionsRoot, latency: latency)
        await fs.start { [weak self] change in
            await self?.handler?(change)
        }
        fsWatcher = fs
    }

    public func stop() async {
        await fsWatcher?.stop()
        fsWatcher = nil
        handler = nil
    }
}
