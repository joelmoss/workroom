import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The regression net for **WORKROOM-2B** — the ≥2000 ms App Hang whose main-thread sample landed in
/// `HistoryRow.body` → `AvatarSubject.gravatar` → `String(format:)`.
///
/// The format string was only where the single watchdog sample happened to land. The hang was an
/// invalidation storm: `HistoryRow` observed `AppStore` + `TerminalSessions` purely to answer
/// "is my commit the focused changeset?", and `TerminalSessions` republishes on every terminal
/// title update and activity pulse — so while an agent streamed, EVERY row body re-ran, over an
/// eager `VStack` holding the whole loaded window.
///
/// So this suite asserts the two properties the fix is actually about, at the view layer where a
/// model test cannot see them:
///
/// 1. **A terminal pulse rebuilds nothing.** `testTerminalPulseBurstRebuildsNoRows` fails on the
///    pre-fix code (one rebuild per row per pulse) and is the test that would have caught the hang.
/// 2. **Selection and content changes still DO rebuild.** The equality gate that gives us (1) can
///    just as easily freeze a row's contents; `testSelectionChangeRebuildsRows` and
///    `testCommitContentChangeRebuildsRows` are the positive half, and they are what stops the fix
///    from trading a hang for stale rows.
///
/// Plus the two scale properties: a large page must not build every row
/// (`testLargePageDoesNotBuildEveryRow`), and building it must not cost main-thread seconds
/// (`testLargePageRendersUnderTimeCeiling` — a body-pass count proves the mechanism changed, only
/// wall clock proves the thread stayed free).
///
/// Harness: the offscreen-`NSWindow` hosting pattern from `PaneRenderingTests` plus the
/// inspector-gating store setup from `HistoryLiveRefreshTests.activeHistoryStore` (both pinned per
/// store, never via the shared inspector prefs — parallel workers share one UserDefaults domain).
@MainActor
final class HistoryRowInvalidationTests: XCTestCase {

  // MARK: harness

  /// Serves a fixed page. `@unchecked Sendable` + lock because `HistoryModel` reads it off-main via
  /// `runBlocking`; the tests serialize on `awaitCurrentLoad`.
  private final class FixedPageProvider: VCSProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var page: VCSHistoryPage
    init(commits: [VCSCommit]) {
      page = VCSHistoryPage(commits: commits, reachedEnd: true)
    }
    func replace(commits: [VCSCommit]) {
      lock.withLock { page = VCSHistoryPage(commits: commits, reachedEnd: true) }
    }
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
      lock.withLock { page }
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("unused")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
      throw VCSError.io("unused")
    }
    func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
      throw VCSError.io("unused")
    }
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private static let projectPath = "/history-invalidation"
  private static let workroomName = "solo"

  /// `count` commits, two authors each (this repo's own `Co-Authored-By` convention is what made the
  /// per-row avatar work 32 format calls rather than 16), newest first.
  private func commits(_ count: Int) -> [VCSCommit] {
    (0..<count).map { i in
      VCSCommit(
        commitID: String(format: "%040x", i), shortID: String(format: "%08x", i), changeID: nil,
        summary: "commit \(i)", body: "",
        authors: [
          VCSAuthor(name: "Grace Hopper", email: "grace\(i % 7)@example.com"),
          VCSAuthor(name: "Ada Lovelace", email: "ada\(i % 3)@example.com"),
        ],
        timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 - i * 60)),
        refs: [], parentIDs: [], isWorkingCopy: false)
    }
  }

  private func target(in store: AppStore) -> TerminalTarget {
    store.target(for: .workroom(project: Self.projectPath, name: Self.workroomName))!
  }

  /// A store whose History pane is genuinely active (inspector visible, Changes pane, History section
  /// expanded, a selected workroom that has a tab) with `commitHistory` served by `provider`.
  private func makeStore(_ provider: FixedPageProvider) async -> AppStore {
    let store = AppStore(commitHistory: HistoryModel(debounce: 0, resolve: { _ in provider }))
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: Self.projectPath, vcs: "git",
        workrooms: [
          Workroom(
            name: Self.workroomName, path: "\(Self.projectPath)/\(Self.workroomName)",
            vcsName: "workroom/\(Self.workroomName)", warnings: [])
        ])
    ]
    store.inspectorVisibleOverrideForTesting = true
    store.isolatesInspectorSectionForTesting = true
    store.isolatesInspectorLayoutForTesting = true
    store.activeInspectorSection = .changes
    store.historySectionCollapsed = false
    _ = store.terminals.addTab(for: target(in: store))
    store.selectedTargetID = .workroom(project: Self.projectPath, name: Self.workroomName)
    await store.commitHistory.awaitCurrentLoad()
    return store
  }

  /// Host the real History pane offscreen. Height is deliberately small (a realistic inspector
  /// section, ~8 rows' worth) so "how many rows does it build" is a meaningful question.
  private func host(_ store: AppStore) -> (NSWindow, NSView) {
    let root = HistoryPanel(model: store.commitHistory, sessions: store.terminals)
      .environmentObject(store)
      .environmentObject(store.notifications)
      .frame(width: 320, height: 360)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // A programmatic NSWindow defaults `isReleasedWhenClosed` to true, which would over-release on
    // top of ARC — same reasoning as `PaneRenderingTests.host`.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  // MARK: the hang itself

  func testTerminalPulseBurstRebuildsNoRows() async throws {
    let provider = FixedPageProvider(commits: commits(60))
    let store = await makeStore(provider)
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    settle(view)
    guard let tab = store.terminals.focusedTab(for: target(in: store)) else {
      return XCTFail("the fixture workroom must have a focused tab")
    }
    // Anti-vacuity guard: "0 rebuilds" is only meaningful if rows rendered at all. A pane stuck in a
    // loading/placeholder state would otherwise pass this test having drawn nothing (which is exactly
    // how the Changes-panel version of this test first passed for the wrong reason).
    XCTAssertGreaterThan(HistoryRow.bodyPasses, 0, "the fixture must actually render commit rows")

    HistoryRow.bodyPasses = 0
    for _ in 0..<25 { store.terminals.pulsePaneActivity(tab.id) }
    settle(view)

    XCTAssertEqual(
      HistoryRow.bodyPasses, 0,
      "a terminal activity pulse says nothing about any commit, so it must not rebuild a single "
        + "History row — this is WORKROOM-2B: 25 pulses × every loaded row of avatar/MD5/format work "
        + "on the main thread")
  }

  // The other half of the storm — an agent's OSC title writes — is deliberately NOT a separate test:
  // `TerminalSessions.updateTitle` is private (it is driven by libghostty callbacks) and it lands on
  // the same `@Published tabsByTarget` reassignment that `pulsePaneActivity` exercises above. Asserting
  // it would mean widening production access purely for a duplicate of this test.

  // MARK: the positive half — the equality gate must not freeze the rows

  func testSelectionChangeRebuildsRows() async throws {
    let provider = FixedPageProvider(commits: commits(20))
    let store = await makeStore(provider)
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    settle(view)

    HistoryRow.bodyPasses = 0
    let first = store.commitHistory.commits[0]
    store.openChangesetPreview(commitID: first.commitID, title: first.summary)
    settle(view, until: { HistoryRow.bodyPasses > 0 })

    XCTAssertGreaterThan(
      HistoryRow.bodyPasses, 0,
      "opening a commit's changeset changes which row reads as selected, so at least the affected "
        + "rows MUST rebuild — an equality gate that swallowed this would trade the hang for a row "
        + "whose highlight never moves")
  }

  func testCommitContentChangeRebuildsRows() async throws {
    let provider = FixedPageProvider(commits: commits(20))
    let store = await makeStore(provider)
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    settle(view)

    HistoryRow.bodyPasses = 0
    // A rewritten page (amend, new commits, a bookmark move) must reach the rows.
    var rewritten = commits(20)
    rewritten[0] = VCSCommit(
      commitID: rewritten[0].commitID, shortID: rewritten[0].shortID, changeID: nil,
      summary: "AMENDED SUMMARY", body: "", authors: rewritten[0].authors,
      timestamp: rewritten[0].timestamp, refs: ["main"], parentIDs: [], isWorkingCopy: false)
    provider.replace(commits: rewritten)
    store.commitHistory.refresh()
    await store.commitHistory.awaitCurrentLoad()
    settle(view, until: { HistoryRow.bodyPasses > 0 })

    XCTAssertGreaterThan(
      HistoryRow.bodyPasses, 0,
      "a refreshed page with changed commit content must rebuild rows — this is the assertion that "
        + "keeps the hand-written `==` honest as fields are added to HistoryRow")
  }

  /// The equality gate must not swallow a THEME repaint.
  ///
  /// This is the one regression `.equatable()` could plausibly cause, and the reasoning that says it
  /// can't is subtle enough to be worth pinning: rows read `ThemeService.shared.tokens`, and Observation
  /// registers that dependency per body evaluation against the body attribute itself — so an
  /// observation-driven invalidation re-runs the body regardless of the row values comparing equal.
  /// If SwiftUI ever changed that, every History row would keep its old colours after a theme switch
  /// until something else happened to change a row value.
  func testThemeChangeRebuildsRows() async throws {
    let provider = FixedPageProvider(commits: commits(20))
    let store = await makeStore(provider)
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    settle(view)
    XCTAssertGreaterThan(HistoryRow.bodyPasses, 0, "the fixture must actually render commit rows")

    HistoryRow.bodyPasses = 0
    ThemeService.shared.applyActiveTheme(force: true)
    settle(view, until: { HistoryRow.bodyPasses > 0 })

    XCTAssertGreaterThan(
      HistoryRow.bodyPasses, 0,
      "a theme change must repaint the rows even though none of their values changed — Observation "
        + "invalidates the body past the equality gate")
  }

  // MARK: scale

  func testLargePageDoesNotBuildEveryRow() async throws {
    let provider = FixedPageProvider(commits: commits(200))
    let store = await makeStore(provider)
    HistoryRow.bodyPasses = 0
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    settle(view)

    XCTAssertGreaterThan(HistoryRow.bodyPasses, 0, "the pane must render some rows")
    // Deliberately not an exact number: how far past the viewport SwiftUI realizes is its business
    // and changes between OS releases. "Far fewer than all of them" is the property that matters.
    XCTAssertLessThan(
      HistoryRow.bodyPasses, 200,
      "a 320×360 pane shows ~8 rows, so building all 200 means the list is eager — the amplifier "
        + "that turned per-row avatar work into a 2-second stall")
  }

  func testLargePageRendersUnderTimeCeiling() async throws {
    let provider = FixedPageProvider(commits: commits(200))
    let store = await makeStore(provider)
    let started = Date()
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    view.layoutSubtreeIfNeeded()
    let elapsed = Date().timeIntervalSince(started)

    // A count proves the mechanism changed; only wall clock proves the main thread stayed free. The
    // ceiling is deliberately generous — 8× under the 2 s app-hang watchdog and far above the
    // handful of milliseconds this costs once the list is lazy — so a loaded CI machine can't flake
    // it while a genuine regression (all 200 rows × 2 authors × MD5 + format) still fails it.
    XCTAssertLessThan(
      elapsed, 0.25,
      "first layout of a 200-commit page took \(String(format: "%.3f", elapsed))s on the main thread"
    )
  }
}
