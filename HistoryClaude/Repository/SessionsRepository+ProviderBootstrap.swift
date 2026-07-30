import Foundation
import GRDB

// MARK: - Codex / Gemini bootstrap
//
// The Claude path's bootstrap walks `~/.claude/projects/<workspace>/<sid>.jsonl`
// — workspace-bucketed on disk. Codex stores everything date-bucketed
// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), Gemini stores per
// project_dir (`~/.gemini/tmp/<dir>/chats/session-*.json`). So neither
// fits the existing `bootstrap(rootURL:)` contract — they need their
// own walkers that produce the canonical `WorkspaceData` shape and feed
// it to the same `writeWorkspace` helper.
//
// These bootstraps run when the user switches to a provider whose
// rows aren't in the DB yet. Sequential, not parallel — the file
// counts are typically small enough that the simplicity wins, and
// the call sites already show a progress splash so a few seconds of
// indexing lands in the UI naturally.

public extension SessionsRepository {

    // MARK: - Codex

    /// Walks `~/.codex/sessions/`, parses every rollout file, groups
    /// sessions by their `cwd`, and upserts into the DB scoped as
    /// `provider = 'codex'`. Sets `currentProvider` to `.codex`
    /// before writing so existing repository invariants hold.
    func bootstrapCodex(
        sessionsRoot: URL = CodexProvider.sessionsRoot(),
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async throws {
        await setActiveProvider(.codex)
        progress?(0.0, "Scanning \(sessionsRoot.path)")

        let fm = FileManager.default
        let parser = CodexParser()

        // Date tree walk: year → month → day → rollout-*.jsonl.
        // Bounded depth so a corrupted Codex install can't run away.
        //
        // Bug 2: live data showed 9 rollout files on disk but only 1–3
        // landing in `sessions_index`. Tally visited / kept / skipped
        // counts as we walk so any future drift in Codex's filename
        // convention is visible in the unified log without re-instrumenting.
        var rolloutFiles: [URL] = []
        var visitedCount = 0
        var skippedFilenameCount = 0
        if let years = try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for year in years where Self.isDirectory(year) {
                guard let months = try? fm.contentsOfDirectory(
                    at: year, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for month in months where Self.isDirectory(month) {
                    guard let days = try? fm.contentsOfDirectory(
                        at: month, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for day in days where Self.isDirectory(day) {
                        guard let entries = try? fm.contentsOfDirectory(
                            at: day, includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        ) else { continue }
                        for entry in entries {
                            visitedCount += 1
                            if entry.pathExtension == "jsonl"
                                && entry.lastPathComponent.hasPrefix("rollout-") {
                                rolloutFiles.append(entry)
                            } else {
                                skippedFilenameCount += 1
                            }
                        }
                    }
                }
            }
        }

        AppLogger.parser.info(
            "Codex walk: visited=\(visitedCount), kept=\(rolloutFiles.count), filteredByName=\(skippedFilenameCount)"
        )
        progress?(0.1, "Parsing \(rolloutFiles.count) Codex sessions")

        // Group sessions by cwd-derived workspace_id. Sessions whose
        // session_meta lacks a cwd land in a single "(unknown)"
        // workspace so they're still surfaced.
        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]

        var parsedCount = 0
        var erroredCount = 0
        for (idx, file) in rolloutFiles.enumerated() {
            let meta = parser.extractMetadata(url: file)
            let cwd = meta?.cwd
            let workspaceID = Self.codexWorkspaceID(forCwd: cwd)

            if buckets[workspaceID] == nil {
                buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
            }

            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = attrs?.fileSize ?? 0
            let mtime = attrs?.contentModificationDate ?? Date()

            do {
                let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                buckets[workspaceID]?.entries.append(
                    ParsedSession(
                        metadata: sessionMeta,
                        size: size,
                        mtime: mtime,
                        flags: flags,
                        // Codex rollouts live under a date tree
                        // (`YYYY/MM/DD/rollout-...jsonl`) so the
                        // path isn't recoverable from `(workspace_id,
                        // sessionID)`. Record the absolute path now
                        // so TranscriptRepository can re-open the
                        // file later for the preview pane.
                        filePath: file.path
                    )
                )
                parsedCount += 1
            } catch {
                erroredCount += 1
                AppLogger.parser.error(
                    "Codex parse error for \(file.lastPathComponent): \(error.localizedDescription)"
                )
            }

            if rolloutFiles.count > 0 {
                let frac = 0.1 + (Double(idx + 1) / Double(rolloutFiles.count)) * 0.7
                if (idx + 1) % 10 == 0 || idx + 1 == rolloutFiles.count {
                    progress?(frac, "Parsed \(idx + 1) of \(rolloutFiles.count)")
                }
            }
        }

        AppLogger.parser.info(
            "Codex parse pass: parsed=\(parsedCount), errored=\(erroredCount), total=\(rolloutFiles.count)"
        )

        // Materialise into WorkspaceData and feed the existing writer.
        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.map { bucket in
            let displayName = bucket.cwd.flatMap { (URL(fileURLWithPath: $0).lastPathComponent.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent) } ?? bucket.workspaceID
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd,
                    gitBranch: nil,
                    version: nil
                )
            )
        }

        progress?(0.85, "Writing \(workspaceData.count) workspaces")
        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .codex, into: db)
            }
        }

        // Populate transcript_fts so /full: search works for codex
        // sessions just like it does for claude. Re-parses each file
        // (cheap — already in OS file cache from the first parse) to
        // extract user+assistant text. Tool calls excluded as noise.
        try await databaseForTests.write { db in
            for bucket in buckets.values {
                for entry in bucket.entries {
                    Self.writeFtsRowFromCodex(
                        entry: entry,
                        workspaceID: bucket.workspaceID,
                        db: db
                    )
                }
            }
        }

        // Smart-folder built-ins are per-provider since v9; ensure
        // they exist for Codex too.
        try await ensureBuiltInSmartFolders()
        progress?(1.0, "Indexed \(workspaceData.count) Codex workspaces")
    }

    /// Catch-up reindex for Codex. Walks `~/.codex/sessions/` like the
    /// full bootstrap but skips files already in `sessions_index.file_path`.
    /// Invoked on provider-switch into a Codex provider that was already
    /// bootstrapped earlier in the session — ensures sessions created
    /// while Codex was inactive (i.e. its watcher wasn't running) land
    /// in the DB without requiring an app restart. Idempotent.
    func catchupCodex(
        sessionsRoot: URL = CodexProvider.sessionsRoot()
    ) async throws {
        let known = await knownFilePaths(provider: .codex)
        let fm = FileManager.default
        let parser = CodexParser()

        var rolloutFiles: [URL] = []
        if let years = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for year in years where Self.isDirectory(year) {
                guard let months = try? fm.contentsOfDirectory(
                    at: year, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for month in months where Self.isDirectory(month) {
                    guard let days = try? fm.contentsOfDirectory(
                        at: month, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for day in days where Self.isDirectory(day) {
                        guard let entries = try? fm.contentsOfDirectory(
                            at: day, includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        ) else { continue }
                        for entry in entries
                        where entry.pathExtension == "jsonl"
                            && entry.lastPathComponent.hasPrefix("rollout-") {
                            guard !known.contains(entry.path) else { continue }
                            rolloutFiles.append(entry)
                        }
                    }
                }
            }
        }
        guard !rolloutFiles.isEmpty else {
            AppLogger.parser.info("Codex catch-up: no new sessions")
            return
        }
        AppLogger.parser.info("Codex catch-up: \(rolloutFiles.count) new sessions to index")

        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]
        for file in rolloutFiles {
            let meta = parser.extractMetadata(url: file)
            let cwd = meta?.cwd
            let workspaceID = Self.codexWorkspaceID(forCwd: cwd)
            if buckets[workspaceID] == nil {
                buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
            }
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = attrs?.fileSize ?? 0
            let mtime = attrs?.contentModificationDate ?? Date()
            do {
                let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                buckets[workspaceID]?.entries.append(
                    ParsedSession(
                        metadata: sessionMeta,
                        size: size,
                        mtime: mtime,
                        flags: flags,
                        filePath: file.path
                    )
                )
            } catch {
                AppLogger.parser.error("Codex catch-up parse error for \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.map { bucket in
            let displayName = bucket.cwd.flatMap {
                URL(fileURLWithPath: $0).lastPathComponent.isEmpty
                    ? nil : URL(fileURLWithPath: $0).lastPathComponent
            } ?? bucket.workspaceID
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd, gitBranch: nil, version: nil
                )
            )
        }

        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .codex, into: db)
            }
        }

        // Catch-up: index each new Codex session into transcript_fts.
        try await databaseForTests.write { db in
            for bucket in buckets.values {
                for entry in bucket.entries {
                    Self.writeFtsRowFromCodex(
                        entry: entry,
                        workspaceID: bucket.workspaceID,
                        db: db
                    )
                }
            }
        }
    }

    /// Stable workspace_id for a Codex session keyed off cwd. Using
    /// the cwd directly keeps the join-friendly invariant intact —
    /// re-runs with the same cwd land in the same workspace row.
    private static func codexWorkspaceID(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "codex:(unknown)" }
        return "codex:\(cwd)"
    }

    // MARK: - Claude Desktop

    /// Walks Claude Desktop's `local-agent-mode-sessions/` tree and
    /// indexes every `local_<uuid>/audit.jsonl` under
    /// `provider = 'claudeDesktop'`.
    ///
    /// Workspace bucketing is the one genuinely awkward part. Desktop
    /// sessions have no working directory in the Claude Code sense — the
    /// sidecar's `cwd` points at the session's own sandboxed `outputs/`
    /// folder, which is unique per session and therefore useless for
    /// grouping. Two rules, in order:
    ///
    ///  1. If the user granted the session access to folders
    ///     (`userSelectedFolders`), bucket by the first one — that's the
    ///     project the session was actually about.
    ///  2. Otherwise bucket by the Desktop *space* the session lives in,
    ///     which at least separates unrelated bodies of work.
    func bootstrapClaudeDesktop(
        sessionsRoot: URL = ClaudeDesktopProvider.sessionsRoot(),
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async throws {
        await setActiveProvider(.claudeDesktop)
        progress?(0.0, "Scanning \(sessionsRoot.path)")

        let discovered = ClaudeDesktopProvider.enumerateSessions(under: sessionsRoot)
        AppLogger.parser.info("Claude Desktop walk: found=\(discovered.count) sessions")
        progress?(0.1, "Parsing \(discovered.count) Claude Desktop sessions")

        let buckets = Self.bucketClaudeDesktop(
            discovered,
            progress: { done, total in
                guard total > 0, done % 10 == 0 || done == total else { return }
                progress?(0.1 + (Double(done) / Double(total)) * 0.7,
                          "Parsed \(done) of \(total)")
            }
        )

        let workspaceData = Self.claudeDesktopWorkspaceData(buckets)
        progress?(0.85, "Writing \(workspaceData.count) workspaces")
        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .claudeDesktop, into: db)
            }
        }
        try await databaseForTests.write { db in
            for bucket in buckets.values {
                for entry in bucket.entries {
                    Self.writeFtsRowFromClaudeDesktop(
                        entry: entry, workspaceID: bucket.workspaceID, db: db
                    )
                }
            }
        }

        try await ensureBuiltInSmartFolders()
        progress?(1.0, "Indexed \(workspaceData.count) Claude Desktop workspaces")
    }

    /// Catch-up reindex for Claude Desktop — same walk as the bootstrap,
    /// skipping transcripts already recorded in `sessions_index.file_path`.
    /// Idempotent.
    func catchupClaudeDesktop(
        sessionsRoot: URL = ClaudeDesktopProvider.sessionsRoot()
    ) async throws {
        let known = await knownFilePaths(provider: .claudeDesktop)
        let fresh = ClaudeDesktopProvider.enumerateSessions(under: sessionsRoot)
            .filter { !known.contains($0.auditURL.path) }
        guard !fresh.isEmpty else {
            AppLogger.parser.info("Claude Desktop catch-up: no new sessions")
            return
        }
        AppLogger.parser.info("Claude Desktop catch-up: \(fresh.count) new sessions to index")

        let buckets = Self.bucketClaudeDesktop(fresh, progress: nil)
        let workspaceData = Self.claudeDesktopWorkspaceData(buckets)
        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .claudeDesktop, into: db)
            }
        }
        try await databaseForTests.write { db in
            for bucket in buckets.values {
                for entry in bucket.entries {
                    Self.writeFtsRowFromClaudeDesktop(
                        entry: entry, workspaceID: bucket.workspaceID, db: db
                    )
                }
            }
        }
    }

    /// Shared parse + group pass for the bootstrap and catch-up paths.
    internal struct ClaudeDesktopBucket {
        let workspaceID: String
        /// The user-selected folder this bucket represents, if any.
        let folder: String?
        /// Desktop space UUID, used for the display name when `folder` is nil.
        let spaceID: String
        var entries: [ParsedSession] = []
    }

    internal static func bucketClaudeDesktop(
        _ discovered: [ClaudeDesktopProvider.DiscoveredSession],
        progress: ((_ done: Int, _ total: Int) -> Void)?
    ) -> [String: ClaudeDesktopBucket] {
        let parser = ClaudeDesktopParser()
        var buckets: [String: ClaudeDesktopBucket] = [:]
        var errored = 0

        for (idx, session) in discovered.enumerated() {
            let sidecar = session.sidecarURL.flatMap { ClaudeDesktopParser.readSidecar(at: $0) }
            let folder = sidecar?.userSelectedFolders.first
            let workspaceID = claudeDesktopWorkspaceID(folder: folder, spaceID: session.spaceID)

            if buckets[workspaceID] == nil {
                buckets[workspaceID] = ClaudeDesktopBucket(
                    workspaceID: workspaceID, folder: folder, spaceID: session.spaceID
                )
            }

            let attrs = try? session.auditURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            do {
                let (meta, flags) = try parser.parse(
                    url: session.auditURL, workspaceID: workspaceID
                )
                buckets[workspaceID]?.entries.append(
                    ParsedSession(
                        metadata: meta,
                        size: attrs?.fileSize ?? 0,
                        mtime: attrs?.contentModificationDate ?? Date(),
                        flags: flags,
                        // Every transcript is named `audit.jsonl`, so the
                        // path is not reconstructible from (workspace,
                        // sessionID) — record it for TranscriptRepository.
                        filePath: session.auditURL.path
                    )
                )
            } catch {
                errored += 1
                AppLogger.parser.error(
                    "Claude Desktop parse error for \(session.sessionUUID): \(error.localizedDescription)"
                )
            }
            progress?(idx + 1, discovered.count)
        }

        AppLogger.parser.info(
            "Claude Desktop parse pass: parsed=\(discovered.count - errored), errored=\(errored)"
        )
        return buckets
    }

    internal static func claudeDesktopWorkspaceData(
        _ buckets: [String: ClaudeDesktopBucket]
    ) -> [WorkspaceData] {
        let now = Date()
        // Only disambiguate space-bucketed workspaces when there's more
        // than one — the common case is a single space, where a bare
        // "Claude Desktop" reads better than "Claude Desktop (a5d90d4a)".
        let spaceBuckets = buckets.values.filter { $0.folder == nil }
        let multipleSpaces = spaceBuckets.count > 1

        return buckets.values.map { bucket in
            let displayName: String
            if let folder = bucket.folder {
                let leaf = URL(fileURLWithPath: folder).lastPathComponent
                displayName = leaf.isEmpty ? folder : leaf
            } else if multipleSpaces {
                displayName = "Claude Desktop (\(bucket.spaceID.prefix(8)))"
            } else {
                displayName = "Claude Desktop"
            }
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.folder ?? "Claude Desktop",
                    group: Self.groupForCwd(bucket.folder),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.folder, gitBranch: nil, version: nil
                )
            )
        }
    }

    /// Namespaced like the Codex / Gemini workspace IDs so
    /// `cleanupCorruptProviderRows`-style prefix invariants hold.
    internal static func claudeDesktopWorkspaceID(folder: String?, spaceID: String) -> String {
        if let folder, !folder.isEmpty { return "claudeDesktop:\(folder)" }
        return "claudeDesktop:space:\(spaceID)"
    }

    // MARK: - Gemini

    /// Walks `~/.gemini/tmp/<project_dir>/chats/`, parses each session
    /// JSON, groups by project_dir, and upserts into the DB scoped as
    /// `provider = 'gemini'`. cwd is recovered via reverse lookup in
    /// `~/.gemini/projects.json` for friendly-named project dirs;
    /// hash-named dirs (newer Gemini builds) get a nil cwd and the
    /// metadata pane shows "—" for those.
    func bootstrapGemini(
        tmpRoot: URL = GeminiProvider.tmpRoot(),
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async throws {
        await setActiveProvider(.gemini)
        progress?(0.0, "Scanning \(tmpRoot.path)")

        let parser = GeminiParser()
        // Discover project subdirs under the supplied tmpRoot. When the
        // caller passes the default `GeminiProvider.tmpRoot()` this is
        // equivalent to `GeminiProvider.discoverProjectDirs()`; when a
        // test passes a synthetic root, we walk THAT root's children
        // directly so the catch-up tests can use a sandbox tmp dir.
        let projectDirs: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        } ?? []
        progress?(0.1, "Found \(projectDirs.count) Gemini projects")

        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]
        var totalFiles = 0

        // First pass: count files for progress reporting.
        for dir in projectDirs {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                totalFiles += files.filter { $0.lastPathComponent.hasPrefix("session-") }.count
            }
        }

        var processed = 0

        for dir in projectDirs {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            let workspaceID = "gemini:\(dir.lastPathComponent)"
            let cwd = GeminiProvider.cwd(forProjectDirName: dir.lastPathComponent)
            if buckets[workspaceID] == nil {
                buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
            }

            for file in files where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attrs?.fileSize ?? 0
                let mtime = attrs?.contentModificationDate ?? Date()

                do {
                    let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                    buckets[workspaceID]?.entries.append(
                        ParsedSession(
                            metadata: sessionMeta,
                            size: size,
                            mtime: mtime,
                            flags: flags,
                            // Gemini stores chats under
                            // `~/.gemini/tmp/<project_dir>/chats/...`
                            // — record the absolute path so
                            // TranscriptRepository can re-open it
                            // for the preview pane.
                            filePath: file.path
                        )
                    )
                } catch GeminiParser.ParseError.filtered {
                    // subagent / system-only — silently skipped.
                } catch {
                    AppLogger.parser.error(
                        "Gemini parse error for \(file.lastPathComponent): \(error.localizedDescription)"
                    )
                }

                processed += 1
                if totalFiles > 0 && (processed % 10 == 0 || processed == totalFiles) {
                    let frac = 0.1 + (Double(processed) / Double(totalFiles)) * 0.7
                    progress?(frac, "Parsed \(processed) of \(totalFiles)")
                }
            }
        }

        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.compactMap { bucket -> WorkspaceData? in
            // Drop empty workspaces (subagent-only project dirs).
            guard !bucket.entries.isEmpty else { return nil }
            let displayName = bucket.cwd
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? bucket.workspaceID.replacingOccurrences(of: "gemini:", with: "")
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd,
                    gitBranch: nil,
                    version: nil
                )
            )
        }

        progress?(0.85, "Writing \(workspaceData.count) workspaces")
        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .gemini, into: db)
            }
        }

        // Populate transcript_fts so /full: search works for gemini
        // sessions just like it does for claude.
        try await databaseForTests.write { db in
            for bucket in buckets.values {
                for entry in bucket.entries {
                    Self.writeFtsRowFromGemini(
                        entry: entry,
                        workspaceID: bucket.workspaceID,
                        db: db
                    )
                }
            }
        }

        try await ensureBuiltInSmartFolders()
        progress?(1.0, "Indexed \(workspaceData.count) Gemini workspaces")
    }

    /// Catch-up reindex for Gemini. Walks `~/.gemini/tmp/<project_dir>/chats/`
    /// like the full bootstrap but skips files already in
    /// `sessions_index.file_path`. Invoked on provider-switch into a
    /// Gemini provider that was already bootstrapped earlier in the
    /// session — sessions created while Gemini was inactive land in
    /// the DB without requiring an app restart. Idempotent.
    func catchupGemini(
        tmpRoot: URL = GeminiProvider.tmpRoot()
    ) async throws {
        let known = await knownFilePaths(provider: .gemini)
        let parser = GeminiParser()
        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]
        var newCount = 0
        for dir in projectDirs where Self.isDirectory(dir) {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            let workspaceID = "gemini:\(dir.lastPathComponent)"
            let cwd = GeminiProvider.cwd(forProjectDirName: dir.lastPathComponent)
            for file in files
            where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
                guard !known.contains(file.path) else { continue }
                newCount += 1
                if buckets[workspaceID] == nil {
                    buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
                }
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attrs?.fileSize ?? 0
                let mtime = attrs?.contentModificationDate ?? Date()
                do {
                    let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                    buckets[workspaceID]?.entries.append(
                        ParsedSession(
                            metadata: sessionMeta,
                            size: size,
                            mtime: mtime,
                            flags: flags,
                            filePath: file.path
                        )
                    )
                } catch GeminiParser.ParseError.filtered(_) {
                    continue
                } catch {
                    AppLogger.parser.error("Gemini catch-up parse error for \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        guard newCount > 0 else {
            AppLogger.parser.info("Gemini catch-up: no new sessions")
            return
        }
        AppLogger.parser.info("Gemini catch-up: \(newCount) new sessions to index")

        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.map { bucket in
            let displayName = bucket.cwd.flatMap {
                URL(fileURLWithPath: $0).lastPathComponent.isEmpty
                    ? nil : URL(fileURLWithPath: $0).lastPathComponent
            } ?? bucket.workspaceID
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd, gitBranch: nil, version: nil
                )
            )
        }

        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .gemini, into: db)
            }
        }

        // Catch-up: index each new Gemini session into transcript_fts.
        try await databaseForTests.write { db in
            for bucket in buckets.values {
                for entry in bucket.entries {
                    Self.writeFtsRowFromGemini(
                        entry: entry,
                        workspaceID: bucket.workspaceID,
                        db: db
                    )
                }
            }
        }
    }

    // MARK: - FTS row writers (Phase 6b)

    /// Re-parse a Codex rollout file with `CodexTranscriptParser`,
    /// concatenate every user/assistant message body, and insert one
    /// row into `transcript_fts`. Tool-call payloads are excluded as
    /// they're noise for full-text search. Provider scoping happens
    /// at query time via JOIN to `sessions_index` (FTS5 virtual tables
    /// can't ALTER ADD COLUMN — see Migrations.swift v10 schema note).
    internal static func writeFtsRowFromCodex(
        entry: ParsedSession,
        workspaceID: String,
        db: GRDB.Database
    ) {
        guard let path = entry.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let parser = CodexTranscriptParser()
        let body = (try? parser.parse(
            url: url,
            sessionID: entry.metadata.sessionID,
            workspaceID: workspaceID
        )).map { ftsBody(from: $0) } ?? ""
        try? db.execute(
            sql: "INSERT INTO transcript_fts (session_id, workspace_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: [
                entry.metadata.sessionID.description,
                workspaceID,
                entry.metadata.title,
                body
            ]
        )
    }

    /// Re-parse a Gemini chat file with `GeminiTranscriptParser`, and
    /// insert one row into `transcript_fts`. Same shape as the Codex
    /// helper above.
    internal static func writeFtsRowFromGemini(
        entry: ParsedSession,
        workspaceID: String,
        db: GRDB.Database
    ) {
        guard let path = entry.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let parser = GeminiTranscriptParser()
        let body = (try? parser.parse(
            url: url,
            sessionID: entry.metadata.sessionID,
            workspaceID: workspaceID
        )).map { ftsBody(from: $0) } ?? ""
        try? db.execute(
            sql: "INSERT INTO transcript_fts (session_id, workspace_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: [
                entry.metadata.sessionID.description,
                workspaceID,
                entry.metadata.title,
                body
            ]
        )
    }

    /// Claude Desktop's transcripts are Claude Code's format, so the
    /// plain `TranscriptParser` produces the FTS body — the only
    /// difference from the Claude path is that the file is addressed by
    /// its recorded absolute path rather than reconstructed.
    internal static func writeFtsRowFromClaudeDesktop(
        entry: ParsedSession,
        workspaceID: String,
        db: GRDB.Database
    ) {
        guard let path = entry.filePath else { return }
        let parser = TranscriptParser()
        let body = (try? parser.parse(
            url: URL(fileURLWithPath: path),
            workspaceID: workspaceID,
            sessionIDOverride: entry.metadata.sessionID
        )).map { ftsBody(from: $0) } ?? ""
        try? db.execute(
            sql: "INSERT INTO transcript_fts (session_id, workspace_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: [
                entry.metadata.sessionID.description,
                workspaceID,
                entry.metadata.title,
                body
            ]
        )
    }

    /// Concatenate user + assistant message text with blank-line
    /// separators. ToolCall messages skipped — their args/results are
    /// noise for full-text search. Mirrors what Claude's FTS indexer
    /// stores per session.
    private static func ftsBody(from t: Transcript) -> String {
        var parts: [String] = []
        for msg in t.messages {
            switch msg {
            case .user(let u): parts.append(u.markdown)
            case .assistant(let a): parts.append(a.markdown)
            case .toolCall: continue
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Corrupt-row cleanup (Bug 1 / Bug 3)

    /// Drops Codex / Gemini rows whose `id` doesn't carry the canonical
    /// `<provider>:<...>` prefix. These rows can only have been written
    /// by the pre-fix `incrementalReindex` path, which tagged the active
    /// provider rather than the watcher's bound provider — leaving
    /// Claude folder-encoded workspace IDs (e.g. `-Users-…`) under
    /// `provider='codex'`. Cascades to dependent `sessions_index` and
    /// `session_flags` rows via the FK relationship.
    ///
    /// Idempotent: safe to call repeatedly. Gated behind the
    /// `HistoryClaude.bootstrapDataVersion` bump at call sites so it runs
    /// at most once per upgrade.
    func cleanupCorruptProviderRows() async throws {
        try await databaseForTests.write { db in
            // workspaces FK has ON DELETE CASCADE for sessions_index, but
            // session_flags is keyed only by session_id (no FK), so we
            // delete its rows explicitly first using the same WHERE
            // predicate to avoid orphan flag rows surviving the cleanup.
            for provider in [ProviderID.codex, ProviderID.gemini] {
                let prefix = "\(provider.rawValue):"
                let providerKey = provider.rawValue

                // Drop session_flags whose owning workspace is corrupt.
                try db.execute(
                    sql: """
                    DELETE FROM session_flags
                    WHERE provider = ?
                      AND session_id IN (
                          SELECT session_id FROM sessions_index
                          WHERE provider = ?
                            AND workspace_id NOT LIKE ?
                      )
                    """,
                    arguments: [providerKey, providerKey, "\(prefix)%"]
                )

                // Drop sessions_index rows whose workspace_id isn't
                // namespaced with the provider prefix.
                try db.execute(
                    sql: """
                    DELETE FROM sessions_index
                    WHERE provider = ? AND workspace_id NOT LIKE ?
                    """,
                    arguments: [providerKey, "\(prefix)%"]
                )

                // Drop workspaces rows whose id isn't namespaced.
                try db.execute(
                    sql: """
                    DELETE FROM workspaces
                    WHERE provider = ? AND id NOT LIKE ?
                    """,
                    arguments: [providerKey, "\(prefix)%"]
                )
            }
        }
    }

    // MARK: - Parse-cache invalidation

    /// Zeroes the `(file_size_bytes, file_mtime)` pair every bootstrap uses to
    /// skip unchanged transcripts, forcing the next pass to re-read and
    /// re-derive every indexed session. Needed when the *parser* changes rather
    /// than the files — a mtime-based cache can't tell that the meaning of a
    /// transcript's bytes has changed. Metadata rows (`user_metadata`, tags,
    /// pins) are keyed separately and untouched.
    ///
    /// Gated behind the `HistoryClaude.bootstrapDataVersion` bump at call sites
    /// so it costs one slow bootstrap per upgrade rather than one per launch.
    func invalidateParseCache() async throws {
        try await databaseForTests.write { db in
            try db.execute(
                sql: "UPDATE sessions_index SET file_size_bytes = 0, file_mtime = 0"
            )
        }
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Neutral, provider-agnostic sidebar grouping for a cwd. The
    /// previous version pattern-matched substrings like "claude" and
    /// "/ai/" which polluted the Codex / Gemini sidebars whenever the
    /// user's project name happened to contain those tokens (e.g. a
    /// repo called `claude-history-manager`). The Claude provider has
    /// its own decoder-driven grouping path; this method only runs
    /// for the Codex / Gemini bootstraps.
    ///
    /// Rules:
    ///   1. Strip a leading `~/Code/`, `~/Desktop/`, `~/Documents/`
    ///      prefix (absolute or tilde form) so the group key isn't
    ///      "users" for everyone.
    ///   2. After stripping, take the second-to-last directory of the
    ///      remaining path (the "parent project group") if one
    ///      exists, else the last component.
    ///   3. Capitalize the first letter for display so the sidebar
    ///      reads "Apps" / "Security" / "StealthZero" rather than
    ///      shouty all-caps.
    ///
    /// Examples:
    ///   - `/Users/foo/Code/swift/apps/history-claude`     → "Apps"
    ///   - `/Users/foo/Code/security/pentest`         → "Security"
    ///   - `/Users/foo/Desktop/StealthZero/turnitin`  → "StealthZero"
    ///   - `/Users/foo/Documents/notes/diary`         → "Notes"
    ///   - `/Users/foo`                               → "home"
    ///   - `/`                                        → "Other"
    static func groupForCwd(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Other" }

        // Normalize: trim trailing slashes (but preserve a single "/").
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }

        // Resolve "~" so the home check below works regardless of form.
        let home = NSHomeDirectory()
        let expanded: String = {
            if path == "~" || path == "~/" { return home }
            if path.hasPrefix("~/") {
                return home + String(path.dropFirst(1))
            }
            return path
        }()

        // The user's home directory itself groups as "home" — both
        // shells and macOS treat it as a special root, and there's
        // no parent directory to derive a name from.
        if expanded == home { return "home" }

        // Strip the well-known top-level prefixes so the group name
        // is the FIRST meaningful subdirectory under them (or the
        // project itself if there's nothing deeper).
        let prefixes = [
            home + "/Code/",
            home + "/Desktop/",
            home + "/Documents/",
        ]
        var remainder = expanded
        for prefix in prefixes {
            if remainder.hasPrefix(prefix) {
                remainder = String(remainder.dropFirst(prefix.count))
                break
            }
        }

        let components = remainder.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return "Other" }

        // Second-to-last component if it exists (the parent project
        // group), else the last component.
        let chosen: String
        if components.count >= 2 {
            chosen = components[components.count - 2]
        } else {
            chosen = components[0]
        }

        return Self.capitalizeFirstLetter(chosen)
    }

    /// Uppercase the first character only, leaving the rest of the
    /// string untouched. Preserves CamelCase repo names like
    /// "StealthZero" while still tidying lowercase tokens like "apps"
    /// → "Apps". Falls back to "Other" for empty strings.
    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let first = s.first else { return "Other" }
        return first.uppercased() + s.dropFirst()
    }
}
