import XCTest
@testable import HistoryClaude

/// Claude Desktop agent-mode sessions. The on-disk shape under test:
///
///     <root>/<account>/<space>/local_<uuid>.json
///     <root>/<account>/<space>/local_<uuid>/audit.jsonl
///
/// Fixtures are synthesized per-test rather than checked in — the layout
/// is four levels deep and the interesting variation is structural, so a
/// builder reads better than a tree of near-identical files.
final class ClaudeDesktopProviderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-desktop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture builder

    /// Writes one session. `sidecar` nil means the metadata file was
    /// never written (Desktop killed mid-start), which must still index.
    @discardableResult
    private func makeSession(
        account: String = "acct-0000",
        space: String,
        uuid: String,
        audit: String,
        sidecar: [String: Any]? = nil
    ) throws -> URL {
        let spaceDir = root
            .appendingPathComponent(account, isDirectory: true)
            .appendingPathComponent(space, isDirectory: true)
        let sessionDir = spaceDir.appendingPathComponent("local_\(uuid)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Desktop keeps sibling dirs full of non-transcript files; the
        // walker must ignore them.
        try FileManager.default.createDirectory(
            at: sessionDir.appendingPathComponent("outputs", isDirectory: true),
            withIntermediateDirectories: true
        )

        let auditURL = sessionDir.appendingPathComponent("audit.jsonl", isDirectory: false)
        try audit.write(to: auditURL, atomically: true, encoding: .utf8)

        if let sidecar {
            let data = try JSONSerialization.data(withJSONObject: sidecar)
            try data.write(
                to: spaceDir.appendingPathComponent("local_\(uuid).json", isDirectory: false)
            )
        }
        return auditURL
    }

    /// Minimal transcript in Desktop's envelope: `_audit_timestamp`
    /// instead of `timestamp`, `session_id` instead of `sessionId`, and
    /// an unmodified Claude Code `message` payload.
    private func auditJSONL(sessionID: String) -> String {
        """
        {"type":"system","subtype":"init","uuid":"11111111-1111-4111-8111-111111111111","session_id":"\(sessionID)","client_platform":"desktop_app","_audit_timestamp":"2026-06-12T06:00:00.000Z","_audit_hmac":"deadbeef","cwd":"/tmp/outputs"}
        {"type":"user","uuid":"22222222-2222-4222-8222-222222222222","session_id":"\(sessionID)","_audit_timestamp":"2026-06-12T06:00:10.000Z","message":{"role":"user","content":"summarise the quarterly report"}}
        {"type":"assistant","uuid":"33333333-3333-4333-8333-333333333333","session_id":"\(sessionID)","_audit_timestamp":"2026-06-12T06:05:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Here is the summary."}],"usage":{"input_tokens":120,"output_tokens":45}}}
        """
    }

    // MARK: - Discovery

    func test_enumerateSessions_findsTranscriptsAndPairsSidecars() throws {
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000001",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000001"),
                        sidecar: ["title": "First"])
        try makeSession(space: "space-b", uuid: "aaaaaaaa-0000-4000-8000-000000000002",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000002"))

        let found = ClaudeDesktopProvider.enumerateSessions(under: root)
            .sorted { $0.sessionUUID < $1.sessionUUID }

        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].spaceID, "space-a")
        XCTAssertNotNil(found[0].sidecarURL, "sidecar next to the session dir should be paired")
        XCTAssertEqual(found[1].spaceID, "space-b")
        XCTAssertNil(found[1].sidecarURL, "a session with no sidecar is still discoverable")
    }

    func test_enumerateSessions_skipsNonSessionDirectories() throws {
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000001",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000001"))
        // A `local_`-prefixed dir whose suffix isn't a UUID, and a
        // session dir with no transcript in it. Neither may be indexed:
        // the first can't produce a SessionID, the second has nothing to
        // show.
        let spaceDir = root.appendingPathComponent("acct-0000/space-a", isDirectory: true)
        try FileManager.default.createDirectory(
            at: spaceDir.appendingPathComponent("local_not-a-uuid/x", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: spaceDir.appendingPathComponent("local_bbbbbbbb-0000-4000-8000-000000000009",
                                                isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(ClaudeDesktopProvider.enumerateSessions(under: root).count, 1)
    }

    func test_enumerateSessions_limitShortCircuits() throws {
        for i in 1...3 {
            try makeSession(space: "space-a",
                            uuid: "aaaaaaaa-0000-4000-8000-00000000000\(i)",
                            audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-00000000000\(i)"))
        }
        XCTAssertEqual(ClaudeDesktopProvider.enumerateSessions(under: root, limit: 1).count, 1,
                       "the availability probe must stop at the first hit")
    }

    func test_isAvailable_falseForMissingRoot() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(ClaudeDesktopProvider.enumerateSessions(under: missing).isEmpty)
    }

    // MARK: - Parser

    func test_parse_usesDirectoryUUIDNotFilename() throws {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let audit = try makeSession(space: "space-a", uuid: uuid,
                                    audit: auditJSONL(sessionID: uuid))

        let (meta, _) = try ClaudeDesktopParser().parse(url: audit, workspaceID: "ws")
        XCTAssertEqual(meta.sessionID.description, uuid,
                       "every transcript is named audit.jsonl — the UUID is on the parent dir")
    }

    func test_parse_readsTimestampsFromAuditEnvelope() throws {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let audit = try makeSession(space: "space-a", uuid: uuid,
                                    audit: auditJSONL(sessionID: uuid))

        let (meta, _) = try ClaudeDesktopParser().parse(url: audit, workspaceID: "ws")
        // No sidecar here, so these can only have come from
        // `_audit_timestamp` — `timestamp` appears nowhere in the file.
        XCTAssertEqual(meta.createdAt.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-06-12T06:00:00Z")!.timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertEqual(meta.lastModifiedAt.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-06-12T06:05:00Z")!.timeIntervalSince1970,
                       accuracy: 1)
    }

    func test_parse_sidecarBeatsTranscriptDerivedFields() throws {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = Date(timeIntervalSince1970: 1_700_003_600)
        let audit = try makeSession(
            space: "space-a", uuid: uuid, audit: auditJSONL(sessionID: uuid),
            sidecar: [
                "title": "Quarterly report digest",
                "model": "claude-opus-4-8",
                "createdAt": created.timeIntervalSince1970 * 1000,
                "lastActivityAt": activity.timeIntervalSince1970 * 1000,
            ]
        )

        let (meta, _) = try ClaudeDesktopParser().parse(url: audit, workspaceID: "ws")
        XCTAssertEqual(meta.title, "Quarterly report digest",
                       "Desktop records a real title; don't infer one from the first message")
        XCTAssertEqual(meta.model, "claude-opus-4-8")
        XCTAssertEqual(meta.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(meta.lastModifiedAt.timeIntervalSince1970, activity.timeIntervalSince1970, accuracy: 1)
    }

    func test_parse_fallsBackToFirstUserMessageWhenSidecarAbsent() throws {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let audit = try makeSession(space: "space-a", uuid: uuid,
                                    audit: auditJSONL(sessionID: uuid))
        let (meta, _) = try ClaudeDesktopParser().parse(url: audit, workspaceID: "ws")
        XCTAssertEqual(meta.title, "summarise the quarterly report")
    }

    func test_parse_rejectsFileOutsideSessionDirectory() throws {
        let stray = root.appendingPathComponent("audit.jsonl", isDirectory: false)
        try auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000001")
            .write(to: stray, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeDesktopParser().parse(url: stray, workspaceID: "ws"))
    }

    func test_sidecar_epochMillisecondsDecodeAsDates() throws {
        let url = root.appendingPathComponent("s.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: [
            "title": "T",
            "createdAt": 1_782_492_393_532 as Int64,
            "isArchived": true,
            "userSelectedFolders": ["/Users/me/project"],
        ]).write(to: url)

        let sidecar = try XCTUnwrap(ClaudeDesktopParser.readSidecar(at: url))
        XCTAssertEqual(sidecar.createdAt?.timeIntervalSince1970 ?? 0, 1_782_492_393.532, accuracy: 0.01)
        XCTAssertTrue(sidecar.isArchived)
        XCTAssertEqual(sidecar.userSelectedFolders, ["/Users/me/project"])
        XCTAssertNil(sidecar.lastActivityAt, "absent keys stay nil rather than defaulting to epoch 0")
    }

    // MARK: - Workspace bucketing

    func test_workspaceID_prefersUserSelectedFolderOverSpace() {
        XCTAssertEqual(
            SessionsRepository.claudeDesktopWorkspaceID(folder: "/Users/me/proj", spaceID: "space-a"),
            "claudeDesktop:/Users/me/proj"
        )
        XCTAssertEqual(
            SessionsRepository.claudeDesktopWorkspaceID(folder: nil, spaceID: "space-a"),
            "claudeDesktop:space:space-a"
        )
        XCTAssertEqual(
            SessionsRepository.claudeDesktopWorkspaceID(folder: "", spaceID: "space-a"),
            "claudeDesktop:space:space-a",
            "an empty folder string must not produce a nameless workspace"
        )
    }

    func test_bucketing_groupsByFolderThenSpace() throws {
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000001",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000001"),
                        sidecar: ["userSelectedFolders": ["/Users/me/proj"]])
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000002",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000002"),
                        sidecar: ["userSelectedFolders": ["/Users/me/proj"]])
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000003",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000003"))

        let discovered = ClaudeDesktopProvider.enumerateSessions(under: root)
        let buckets = SessionsRepository.bucketClaudeDesktop(discovered, progress: nil)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets["claudeDesktop:/Users/me/proj"]?.entries.count, 2)
        XCTAssertEqual(buckets["claudeDesktop:space:space-a"]?.entries.count, 1)
    }

    func test_bucketing_recordsAbsolutePathForTranscriptLookup() throws {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let audit = try makeSession(space: "space-a", uuid: uuid,
                                    audit: auditJSONL(sessionID: uuid))
        let buckets = SessionsRepository.bucketClaudeDesktop(
            ClaudeDesktopProvider.enumerateSessions(under: root), progress: nil
        )
        let entry = try XCTUnwrap(buckets.values.first?.entries.first)
        XCTAssertEqual(entry.filePath, audit.path,
                       "audit.jsonl isn't reconstructible from (workspace, sessionID)")
    }

    func test_workspaceDisplayNames() throws {
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000001",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000001"),
                        sidecar: ["userSelectedFolders": ["/Users/me/deep/proj"]])
        try makeSession(space: "space-a", uuid: "aaaaaaaa-0000-4000-8000-000000000002",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000002"))

        let single = SessionsRepository.claudeDesktopWorkspaceData(
            SessionsRepository.bucketClaudeDesktop(
                ClaudeDesktopProvider.enumerateSessions(under: root), progress: nil
            )
        )
        XCTAssertEqual(
            single.first(where: { $0.id == "claudeDesktop:/Users/me/deep/proj" })?.decoded.displayName,
            "proj", "folder-backed workspaces show the folder leaf"
        )
        XCTAssertEqual(
            single.first(where: { $0.id == "claudeDesktop:space:space-a" })?.decoded.displayName,
            "Claude Desktop", "a lone space needs no disambiguating suffix"
        )

        // A second space appears — now both need to be distinguishable.
        try makeSession(space: "space-b", uuid: "aaaaaaaa-0000-4000-8000-000000000003",
                        audit: auditJSONL(sessionID: "aaaaaaaa-0000-4000-8000-000000000003"))
        let multi = SessionsRepository.claudeDesktopWorkspaceData(
            SessionsRepository.bucketClaudeDesktop(
                ClaudeDesktopProvider.enumerateSessions(under: root), progress: nil
            )
        )
        XCTAssertEqual(
            multi.first(where: { $0.id == "claudeDesktop:space:space-a" })?.decoded.displayName,
            "Claude Desktop (space-a)"
        )
    }

    // MARK: - Capabilities

    func test_claudeDesktopIsReadOnly() {
        XCTAssertFalse(ClaudeDesktopProvider().supportsResume)
        XCTAssertFalse(ProviderID.claudeDesktop.supportsResume)
        for other in [ProviderID.claude, .codex, .gemini] {
            XCTAssertTrue(other.supportsResume, "\(other) is CLI-backed and must stay resumable")
        }
    }

    func test_registryOrdersDesktopAfterClaudeCode() async {
        let registry = ProviderRegistry(candidates: [
            GeminiProvider(), ClaudeDesktopProvider(), ClaudeProvider(), CodexProvider(),
        ])
        let ordered = await registry.availableIDs()
        if let claude = ordered.firstIndex(of: .claude),
           let desktop = ordered.firstIndex(of: .claudeDesktop) {
            XCTAssertLessThan(claude, desktop)
        }
    }

    // MARK: - Transcript

    func test_transcriptParser_readsDesktopEnvelope() throws {
        let uuid = "aaaaaaaa-0000-4000-8000-000000000001"
        let audit = try makeSession(space: "space-a", uuid: uuid,
                                    audit: auditJSONL(sessionID: uuid))
        let sessionID = try SessionID(string: uuid)

        let transcript = try TranscriptParser().parse(
            url: audit, workspaceID: "ws", sessionIDOverride: sessionID
        )
        XCTAssertEqual(transcript.sessionID, sessionID)
        XCTAssertEqual(transcript.messages.count, 2, "one user turn + one assistant turn")
    }
}
