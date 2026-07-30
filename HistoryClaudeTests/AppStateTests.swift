import XCTest
@testable import HistoryClaude

@MainActor
final class AppStateTests: XCTestCase {
    func test_initialState_emptyWorkspaces() {
        let state = AppState()
        XCTAssertTrue(state.workspaces.isEmpty)
        XCTAssertNil(state.selectedWorkspace)
        XCTAssertTrue(state.sessionsForSelected.isEmpty)
    }

    func test_selectWorkspace_updatesSelection() {
        let state = AppState()
        let ws = Workspace(id: "x", decodedPath: "/x", group: "g", displayName: "d")
        state.workspaces = [ws]
        state.select(workspace: ws)
        XCTAssertEqual(state.selectedWorkspace?.id, "x")
    }

    // MARK: - Search-state derivations

    private func sample(_ title: String, wsID: String = "ws", id: String = UUID().uuidString) throws -> SessionMetadata {
        SessionMetadata(
            sessionID: try SessionID(string: id),
            workspaceID: wsID,
            title: title,
            createdAt: Date(),
            lastModifiedAt: Date(),
            messageCount: 1,
            tokenCount: 1,
            isLive: false
        )
    }

    func test_isSearching_falseAtRest() {
        let s = AppState()
        XCTAssertFalse(s.isSearching)
    }

    func test_isSearching_trueWhenQueryTyped() {
        let s = AppState()
        s.searchQuery = "stripe"
        XCTAssertTrue(s.isSearching)
    }

    func test_isSearching_trueWhenTimeWindowActive() {
        let s = AppState()
        s.activeTimeWindow = .last30Days
        XCTAssertTrue(s.isSearching)
    }

    func test_isSearching_trueWhenWorkspaceNarrowed() {
        let s = AppState()
        s.showAllWorkspaces = false
        XCTAssertTrue(s.isSearching)
    }

    func test_displayedSessions_usesSessionsForSelectedWhenNotSearching() throws {
        let s = AppState()
        let a = try sample("first")
        let b = try sample("second")
        s.sessionsForSelected = [a, b]
        s.searchResults = [try sample("other")]
        XCTAssertEqual(s.displayedSessions.map(\.title), ["first", "second"])
    }

    func test_displayedSessions_usesSearchResultsWhenSearching() throws {
        let s = AppState()
        s.sessionsForSelected = [try sample("a")]
        s.searchResults = [try sample("hit")]
        s.searchQuery = "hit"
        XCTAssertEqual(s.displayedSessions.map(\.title), ["hit"])
    }

    func test_displayedSessions_appliesListFilterCaseInsensitively() throws {
        let s = AppState()
        s.sessionsForSelected = [try sample("Stripe checkout"),
                                 try sample("Rust refactor")]
        s.listFilter = "rust"
        XCTAssertEqual(s.displayedSessions.map(\.title), ["Rust refactor"])
    }

    func test_displayedWorkspaceCount_reflectsDistinctWorkspaces() throws {
        let s = AppState()
        s.searchQuery = "anything"
        s.searchResults = [
            try sample("a", wsID: "ws-1"),
            try sample("b", wsID: "ws-2"),
            try sample("c", wsID: "ws-1"),
        ]
        XCTAssertEqual(s.displayedWorkspaceCount, 2)
    }

    // MARK: - runSearch end-to-end

    /// Stub repository whose `search` returns a preconfigured set of rows
    /// so we can exercise AppState's search publishing pipeline without
    /// involving GRDB.
    private final class SearchStub: SessionsRepositoryProtocol, @unchecked Sendable {
        let rows: [SessionMetadata]
        var lastQuery: SearchQuery? = nil
        init(rows: [SessionMetadata]) { self.rows = rows }

        func bootstrap(rootURL: URL) async throws {}
        func allWorkspaces() async throws -> [Workspace] { [] }
        func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata] { [] }
        func allSessions(limit: Int) async throws -> [SessionMetadata] { rows }
        func search(query: SearchQuery) async throws -> [SessionMetadata] {
            lastQuery = query
            // Case-insensitive substring over titleText.
            if query.titleText.isEmpty { return rows }
            let needle = query.titleText.lowercased()
            return rows.filter { $0.title.lowercased().contains(needle) }
        }
        func recentSessions(days: Int, limit: Int) async throws -> [SessionMetadata] { [] }
        func liveSessions() async throws -> [SessionMetadata] { [] }

        // Plan 06 / 07 stubs — unused by these tests.
        func pinnedSessions(limit: Int) async throws -> [SessionWithMetadata] { [] }
        func archivedSessions(limit: Int) async throws -> [SessionWithMetadata] { [] }
        func sessionsForTag(_ tag: Tag, limit: Int) async throws -> [SessionWithMetadata] { [] }
        func userMetadata(for sessionID: SessionID) async throws -> UserMetadata {
            UserMetadata.empty(for: sessionID)
        }
        func tags(for sessionID: SessionID) async throws -> [Tag] { [] }
        func allTags() async throws -> [Tag] { [] }
        func tagCounts() async throws -> [Int64: Int] { [:] }
        func setPinned(_ pinned: Bool, for sessionID: SessionID) async throws { }
        func setArchived(_ archived: Bool, for sessionID: SessionID) async throws { }
        func setCustomTitle(_ title: String?, for sessionID: SessionID) async throws { }
        func setNote(_ note: String?, for sessionID: SessionID) async throws { }
        func softDelete(_ sessionID: SessionID, workspaceID: String?) async throws { }
        func undelete(_ sessionID: SessionID) async throws { }
        func hardPurgeExpiredDeletes(olderThan days: Int) async throws { }
        func createTag(name: String, colorHue: Int) async throws -> Tag {
            Tag(id: 1, name: name, colorHue: colorHue)
        }
        func renameTag(_ id: Int64, to name: String) async throws { }
        func deleteTag(_ id: Int64) async throws { }
        func setTags(_ tagIDs: [Int64], for sessionID: SessionID) async throws { }
        func smartFolders() async throws -> [SmartFolder] { [] }
        func createSmartFolder(name: String, query: SmartFolderQuery) async throws -> SmartFolder {
            SmartFolder(id: 1, name: name, query: query)
        }
        func deleteSmartFolder(_ id: Int64) async throws { }
        func renameSmartFolder(_ id: Int64, to name: String) async throws { }
        func sessionsForSmartFolder(_ folder: SmartFolder, limit: Int) async throws -> [SessionWithMetadata] { [] }
        func smartFolderCounts() async throws -> [Int64: Int] { [:] }
        func incrementalReindex(paths: Set<URL>,
                                workspaces: Set<String>,
                                removedPaths: Set<URL>) async throws { }
    }

    func test_runSearch_populatesSearchResults_forTitleText() async throws {
        let state = AppState()
        let stub = SearchStub(rows: [
            try sample("Stripe checkout refactor"),
            try sample("Rust async task leak"),
        ])
        state.searchQuery = "stripe"

        await state.runSearch(using: stub)

        XCTAssertEqual(state.searchResults.map(\.title), ["Stripe checkout refactor"])
        XCTAssertEqual(state.searchState, .ready)
        // Verify the query reached the repository.
        XCTAssertEqual(stub.lastQuery?.titleText, "stripe")
        // displayedSessions should now reflect the search hits.
        XCTAssertEqual(state.displayedSessions.map(\.title), ["Stripe checkout refactor"])
    }

    func test_runSearch_resetsResults_onEmptyQuery() async throws {
        let state = AppState()
        let stub = SearchStub(rows: [try sample("a")])
        state.searchQuery = ""   // empty

        await state.runSearch(using: stub)

        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertEqual(state.searchState, .idle)
    }

    func test_runSearch_transitionsToReady_afterSuccess() async throws {
        let state = AppState()
        let stub = SearchStub(rows: [try sample("hello world")])
        state.searchQuery = "hello"

        await state.runSearch(using: stub)

        XCTAssertEqual(state.searchState, .ready)
    }

    func test_composeSearchQuery_appliesTimeWindow() {
        let state = AppState()
        state.searchQuery = "foo"
        state.activeTimeWindow = .last30Days
        let q = state.composeSearchQuery()
        XCTAssertEqual(q.timeWindow, .last30Days)
        XCTAssertEqual(q.titleText, "foo")
    }

    func test_composeSearchQuery_appliesWorkspaceScope_whenNarrowed() {
        let state = AppState()
        let ws = Workspace(id: "x", decodedPath: "/x/y/z",
                            group: "y", displayName: "my-proj")
        state.workspaces = [ws]
        state.selectedWorkspace = ws
        state.showAllWorkspaces = false
        state.searchQuery = "bar"
        let q = state.composeSearchQuery()
        XCTAssertEqual(q.workspaces, ["my-proj"])
    }

    // MARK: - Search vs. sidebar navigation

    private func workspace(_ id: String) -> Workspace {
        Workspace(id: id, decodedPath: "/\(id)", group: "g", displayName: id)
    }

    /// The scope pill alone must not read as "the user is searching" — that
    /// distinction is what lets a workspace click narrow rather than be masked.
    func test_hasSearchInput_ignoresWorkspaceScopePill() {
        let s = AppState()
        s.showAllWorkspaces = false
        XCTAssertFalse(s.hasSearchInput)
        XCTAssertTrue(s.isSearching)
    }

    func test_clearSearch_dropsEverySearchSignal() throws {
        let s = AppState()
        s.searchQuery = "stripe"
        s.activeTimeWindow = .last30Days
        s.showAllWorkspaces = false
        s.searchResults = [try sample("a")]
        s.searchState = .ready

        s.clearSearch()

        XCTAssertEqual(s.searchQuery, "")
        XCTAssertNil(s.activeTimeWindow)
        XCTAssertTrue(s.showAllWorkspaces)
        XCTAssertTrue(s.searchResults.isEmpty)
        XCTAssertEqual(s.searchState, .idle)
        XCTAssertFalse(s.isSearching)
    }

    /// With a query running, clicking a workspace narrows the query to it
    /// instead of leaving the (global) result set on screen.
    func test_focusWorkspace_narrowsScope_whenQueryActive() {
        let s = AppState()
        let ws = workspace("proj")
        s.workspaces = [ws]
        s.searchQuery = "stripe"

        s.focusWorkspace(ws)

        XCTAssertEqual(s.selectedWorkspace?.id, "proj")
        XCTAssertFalse(s.showAllWorkspaces)
        XCTAssertEqual(s.searchQuery, "stripe", "the query itself is kept")
        XCTAssertEqual(s.composeSearchQuery().workspaces, ["proj"])
    }

    /// Without a query it's plain navigation — it must not silently flip the
    /// list into search mode and retitle the column "Search results".
    func test_focusWorkspace_doesNotEnterSearchMode_whenIdle() {
        let s = AppState()
        let ws = workspace("proj")
        s.workspaces = [ws]

        s.focusWorkspace(ws)

        XCTAssertEqual(s.selectedWorkspace?.id, "proj")
        XCTAssertTrue(s.showAllWorkspaces)
        XCTAssertFalse(s.isSearching)
    }

    func test_focusWorkspace_leavesTagAndArchiveModes() {
        let s = AppState()
        let ws = workspace("proj")
        s.showingArchive = true
        s.activeTag = Tag(id: 1, name: "t", colorHue: 0)

        s.focusWorkspace(ws)

        XCTAssertFalse(s.showingArchive)
        XCTAssertNil(s.activeTag)
        XCTAssertNil(s.activeSmartFolder)
    }

    /// Tag / archive / smart-folder modes load their own rows, so an active
    /// search would simply hide them.
    func test_focusNonWorkspaceMode_clearsSearchThenApplies() {
        let s = AppState()
        s.searchQuery = "stripe"

        s.focusNonWorkspaceMode { s.showingArchive = true }

        XCTAssertTrue(s.showingArchive)
        XCTAssertFalse(s.isSearching)
    }

    /// A provider switch must not leave the previous provider's results on
    /// screen — `isSearching` gives them precedence over the reloaded list,
    /// which is what made the two providers look interleaved.
    func test_switchTo_dropsOutgoingProviderResults() throws {
        let s = AppState()
        s.availableProviders = [.claude, .claudeDesktop]
        s.searchQuery = "stripe"
        s.searchResults = [try sample("claude-side hit")]
        s.searchState = .ready
        s.showAllWorkspaces = false

        s.switchTo(.claudeDesktop)

        XCTAssertEqual(s.activeProvider, .claudeDesktop)
        XCTAssertTrue(s.searchResults.isEmpty)
        XCTAssertEqual(s.searchState, .idle)
        XCTAssertTrue(s.showAllWorkspaces, "scope named a workspace of the old provider")
        XCTAssertEqual(s.searchQuery, "stripe", "the query is re-run, not discarded")
    }
}
