import AppKit
import Combine

// Hover-preview state machine (plan: ~/.claude/plans/ethereal-inventing-wolf.md; eng-reviewed
// 2026-08-14, Stage 0 spike confirmed Candidate A live 2026-08-14).
//
//   idle
//     │ armHover(tab, target), hasSurface == true, not dragging
//     ▼
//   armed            — Scheduling.schedule(after: dwell), cancellable
//     │ cancelHover() / a newer armHover() → cancel, gen++, → idle
//     ▼
//   resolving        — dwell elapsed, gen captured
//     │
//     ├─ tab already in sessions.visibleTabIDs(for: target) → idle (v1: no preview for a visible tab)
//     └─ tab no longer exists (closed mid-dwell) → idle
//     ▼ (else) needsMount
//   mounting         — frameSource.mount(surface, host): frame.size/.autoresizingMask NEVER written,
//     │                only .frame.origin; sessions.beginPreview(tab, session: gen, for: target) —
//     │                the ONLY previewingTabID writer, never a direct surface.setVisible call
//     │  mount failure OR stale gen → teardown(gen) [cleans up whatever this step allocated]
//     ▼
//   presenting       — frameSource.startPresenting(onFirstFrame:)
//     │  start failure → teardown(gen)
//     ▼
//   visible          — onFirstFrame fired → overlay shown
//     │ hover ends / owning view disappears / window closes / app resigns active
//     ▼
//   tearingDown      — frameSource.stopPresenting(); frameSource.unmount(); restore the controller's
//     │                OWN retained surface/frame/superview (never re-derived via tab lookup — the
//     │                tab may already be gone); sessions.endPreview(tab, session: gen, for: target)
//     │                (session-token-guarded — a stale session's teardown can't clear a newer one)
//     ▼
//   idle
//
// Every step guards on `gen == generation` — a plain generation counter (not `.task(id:)`; this
// codebase has measured `.task(id:)` cancellation as unreliable at a reused view-identity slot,
// `Avatar.swift`). A stale generation at any allocating step must release what it already allocated,
// not just skip applying its result.

/// Something that can be cancelled — the result of `PreviewScheduling.schedule`.
protocol PreviewCancellable {
  func cancel()
}

/// Seam over `DispatchQueue.main.asyncAfter`, injectable so the dwell timer is fake-able in tests.
protocol PreviewScheduling {
  @discardableResult
  func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> PreviewCancellable
}

private struct DispatchWorkItemCancellable: PreviewCancellable {
  let item: DispatchWorkItem
  func cancel() { item.cancel() }
}

final class DispatchQueueScheduling: PreviewScheduling {
  func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> PreviewCancellable {
    let item = DispatchWorkItem(block: block)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return DispatchWorkItemCancellable(item: item)
  }
}

/// Seam over "how pixels get from the real surface to the preview host" — one production
/// conformance (`TransformScaleFrameSource`, Candidate A, confirmed live by the Stage 0 spike), one
/// fake for tests. Not a swappable-backend abstraction (D3 cut that on purpose) — purely for
/// testability, per the eng review's Tension 2 resolution.
protocol PreviewFrameSource: AnyObject {
  /// Re-homes `surface` into `host`. MUST NOT write `.frame.size`/`.autoresizingMask` on `surface` —
  /// only `.frame.origin` — per the critical finding (a size write triggers `viewDidMoveToWindow` →
  /// `updateMetalLayerSize` → a real `ghostty_surface_set_size`, an actual resize). Returns false on
  /// failure; the caller tears down through the normal teardown path either way.
  func mount(surface: GhosttySurfaceView, host: NSView) -> Bool
  /// Begins presenting the mounted surface; calls `onFirstFrame` once it should be considered ready to
  /// reveal. Continuous compositing (Candidate A) has no discrete "frame delivered" callback — this is
  /// a settle signal, not a proxy for engine-level freshness (Codex #5's open question).
  func startPresenting(onFirstFrame: @escaping () -> Void)
  func stopPresenting()
  /// Detaches the surface from the host. Does NOT restore the surface's original frame/superview —
  /// that's the controller's job, using its own retained record of what those were.
  func unmount()
}

/// Candidate A: CALayer `sublayerTransform` scale-compositing. Confirmed live against a real running
/// build (2026-08-14) — libghostty's internally-installed `CAMetalLayer` composites correctly through
/// an ancestor's `sublayerTransform`.
final class TransformScaleFrameSource: PreviewFrameSource {
  private let scheduling: PreviewScheduling
  private weak var mountedSurface: GhosttySurfaceView?
  private weak var mountedHost: NSView?
  private var settleWork: PreviewCancellable?

  init(scheduling: PreviewScheduling) {
    self.scheduling = scheduling
  }

  func mount(surface: GhosttySurfaceView, host: NSView) -> Bool {
    let originalSize = surface.frame.size
    guard originalSize.width > 0, originalSize.height > 0 else { return false }
    // `host` arrives sized to the MAX envelope (`TerminalHoverPreviewController.maxHostSize`) — treated
    // here as a bounding box, not a fixed box to letterbox into. Most terminal panes are far closer to
    // square than the envelope's landscape aspect (found via real-mouse QA: a ~933×925 pane fit into a
    // fixed 260×160 box left the content occupying well under half the box, height-constrained with
    // big empty side bars). Shrinking `host` itself to hug the scaled content exactly removes the bars
    // entirely — resizing `host` is fine, it's a private helper view this feature owns outright; only
    // the `GhosttySurfaceView`'s own frame must never be resized (the critical finding).
    let maxSize = host.bounds.size
    guard maxSize.width > 0, maxSize.height > 0 else { return false }

    let scale = min(maxSize.width / originalSize.width, maxSize.height / originalSize.height)
    guard scale.isFinite, scale > 0 else { return false }

    host.frame = NSRect(
      origin: host.frame.origin,
      size: CGSize(width: originalSize.width * scale, height: originalSize.height * scale))
    host.wantsLayer = true
    host.layer?.masksToBounds = true

    // The surface fills the (now tightly-sized) host exactly, so no centering offset is needed —
    // reposition ONLY the origin (never the size) to the host's own origin.
    surface.frame = NSRect(origin: .zero, size: originalSize)
    surface.autoresizingMask = []
    // `wantsFocus` is only ever written by `TerminalContainerView.mount(in:)` on whichever surface is
    // CURRENTLY its `view:` — a backgrounded tab's surface keeps whatever stale value it had from when
    // it was last actually active (usually `true`, from having been the newly-focused tab at creation;
    // nothing resets it when a solo tab is swapped away entirely, unlike a co-displayed non-focused
    // split member, which gets its own live `isFocusedPane: false` render). Left stale `true`,
    // `addSubview` below triggers `viewDidMoveToWindow()`'s `if wantsFocus, window.firstResponder !==
    // self { window.makeFirstResponder(self) }` — silently stealing first responder from the real
    // active tab the moment a background tab is hovered (found via real-mouse QA: "hover selected the
    // tab, detail pane went empty"). Force it false before this surface ever enters the window again.
    surface.wantsFocus = false
    host.addSubview(surface)
    host.layer?.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)

    mountedSurface = surface
    mountedHost = host
    return true
  }

  func startPresenting(onFirstFrame: @escaping () -> Void) {
    settleWork = scheduling.schedule(after: 0.05, onFirstFrame)
  }

  func stopPresenting() {
    settleWork?.cancel()
    settleWork = nil
  }

  func unmount() {
    // Only detach if the surface is STILL our host's child — a real focus/tab switch can re-home it
    // elsewhere (`TerminalContainerView.mount(in:)`) before this preview session tears down (found via
    // real-mouse QA: clicking the previewed tab re-homed its surface into the real container, then
    // teardown's unconditional `removeFromSuperview()` yanked it straight back out, blanking the pane
    // the user had just switched to). If someone else already took it, leave it alone.
    if mountedSurface?.superview === mountedHost {
      mountedSurface?.removeFromSuperview()
    }
    mountedSurface = nil
    mountedHost = nil
  }
}

@MainActor
final class TerminalHoverPreviewController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case armed(tabID: TerminalTab.ID)
    case visible(tabID: TerminalTab.ID)
  }

  /// The max bounding box a preview may occupy — `TransformScaleFrameSource.mount()` shrinks the host
  /// to hug the scaled content's own aspect ratio within this envelope, rather than letterboxing a
  /// fixed-size box (most terminal panes are far closer to square than this landscape envelope).
  static let maxHostSize = CGSize(width: 520, height: 320)

  @Published private(set) var phase: Phase = .idle
  /// The host view currently showing the preview, once `.visible` — the SwiftUI overlay reads this to
  /// decide what to render. `nil` in every other phase.
  @Published private(set) var previewHost: NSView?

  private(set) var generation = 0

  private let sessions: TerminalSessions
  private let scheduling: PreviewScheduling
  private let makeFrameSource: () -> PreviewFrameSource
  private let dwell: TimeInterval

  private var armWork: PreviewCancellable?
  private var activeFrameSource: PreviewFrameSource?
  /// The controller's OWN record of what it mounted — teardown uses this, never a fresh tab lookup
  /// (the tab may already be closed by the time teardown runs). Codex #4.
  private var mountedSurface: GhosttySurfaceView?
  private var originalSuperview: NSView?
  private var originalFrame: NSRect?
  private var activeTarget: TerminalTarget?
  private var activeTabID: TerminalTab.ID?
  /// The session token `beginPreview` was actually called with — NOT the live `generation` counter,
  /// which `cancelHover` bumps BEFORE `teardown()` runs. Reading the live counter at teardown time
  /// would call `endPreview` with the wrong (already-incremented) token, silently failing its
  /// session-match guard and leaving the surface un-occluded forever — caught by
  /// `testFullHoverCycleMountsPresentsAndTearsDown`.
  private var activeSession: Int?
  private var resignActiveObserver: NSObjectProtocol?

  init(
    sessions: TerminalSessions,
    scheduling: PreviewScheduling = DispatchQueueScheduling(),
    dwell: TimeInterval = 0.4,
    makeFrameSource: @escaping () -> PreviewFrameSource = {
      TransformScaleFrameSource(scheduling: DispatchQueueScheduling())
    }
  ) {
    self.sessions = sessions
    self.scheduling = scheduling
    self.dwell = dwell
    self.makeFrameSource = makeFrameSource

    // "Hover ends" alone isn't a reliable teardown signal (Codex #8) — the app backgrounding while a
    // preview is up (⌘-Tab away) is the case `.onHover`/`.onDisappear` can both miss.
    resignActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.forceTeardown() }
    }
  }

  deinit {
    if let resignActiveObserver {
      NotificationCenter.default.removeObserver(resignActiveObserver)
    }
  }

  // MARK: Entry points (called from TerminalTabStrip's hover handling)

  /// Arm a hover for `tab` — call only when not dragging (the caller's job; `isPreviewEligible` is
  /// re-checked here too since it's cheap and correctness shouldn't rest solely on the caller
  /// remembering).
  func armHover(tab: TerminalTab, target: TerminalTarget) {
    guard sessions.isPreviewEligible(tab, for: target) else { return }
    cancelHover()  // supersede any in-flight hover, gen++ happens inside
    let gen = generation
    phase = .armed(tabID: tab.id)
    armWork = scheduling.schedule(after: dwell) { [weak self] in
      self?.resolve(tabID: tab.id, target: target, gen: gen)
    }
  }

  /// Hover ended, a drag started, or a different chip is now hovered — cancel whatever's in flight and
  /// tear down if a preview was already showing.
  func cancelHover() {
    armWork?.cancel()
    armWork = nil
    generation += 1
    if case .visible = phase {
      teardown()
    } else {
      phase = .idle
    }
  }

  /// Call from the owning view's `.onDisappear`, and on window-close/app-resign-active — `.onHover`
  /// ending is not a reliable signal for all of these (Codex #8).
  func forceTeardown() {
    cancelHover()
  }

  // MARK: State machine internals

  private func resolve(tabID: TerminalTab.ID, target: TerminalTarget, gen: Int) {
    guard gen == generation else { return }
    // Every early-return below must reset `phase` back to `.idle` — otherwise a dwell that resolves to
    // "nothing to do" (tab closed, or it became visible during the dwell) leaves `phase` stuck at
    // `.armed` forever, which is wrong for anything observing it.
    guard let tab = sessions.tab(tabID, for: target) else {  // closed mid-dwell
      phase = .idle
      return
    }
    // Now visible, or its surface is gone.
    guard sessions.isPreviewEligible(tab, for: target) else {
      phase = .idle
      return
    }
    guard let surface = tab.surface else {
      phase = .idle
      return
    }

    mount(surface: surface, tabID: tabID, target: target, gen: gen)
  }

  private func mount(
    surface: GhosttySurfaceView, tabID: TerminalTab.ID, target: TerminalTarget, gen: Int
  ) {
    // Capture the surface's REAL current superview/frame BEFORE frameSource.mount() runs — that call
    // repositions the surface's frame origin into the host's own coordinate space, so capturing this
    // after mount() would record the wrong (tiny, host-relative) frame instead of the real one to
    // restore on teardown.
    //
    // `superview` is a plain optional, NOT unwrapped here — this was a real bug (found via a real-mouse
    // hover test showing nothing, no crash, no log): a genuinely backgrounded tab's surface has ALREADY
    // been detached from any container (`TerminalContainerView`'s mount/detach behavior, the entire
    // reason this feature needs to re-home the surface at all), so `surface.superview` is normally nil
    // for exactly the tabs this feature targets. A `guard let ... else { return }` here silently bailed
    // on every real hover. Restoring later already handled a nil superview correctly
    // (`teardownAllocatedState`'s `if let ... superview ...` is a no-op when there's nothing to restore
    // to) — only this capture site needed the fix. The test suite didn't catch this because its
    // `makeSessions()` fixture attached every surface to a shared window unconditionally, unlike
    // production; see `TerminalHoverPreviewControllerTests`'s updated fixture.
    let superview = surface.superview
    let preMountFrame = surface.frame

    let host = PreviewHostView(frame: NSRect(origin: .zero, size: Self.maxHostSize))
    let frameSource = makeFrameSource()

    guard frameSource.mount(surface: surface, host: host) else {
      // Nothing was actually attached — restore isn't needed, just bail to idle.
      phase = .idle
      return
    }

    // Retain everything THIS session mounted before doing anything else, so a stale-generation
    // cleanup (below) or a normal teardown always has what it needs, never a tab-model lookup. Also
    // retain `gen` itself as `activeSession`: `cancelHover` bumps the LIVE `generation` counter before
    // calling teardown, so reading that live counter at cleanup time (instead of the token actually
    // used for `beginPreview`) would call `endPreview` with the wrong session and silently fail its
    // match guard — caught by `testFullHoverCycleMountsPresentsAndTearsDown`.
    activeFrameSource = frameSource
    mountedSurface = surface
    originalSuperview = superview
    originalFrame = preMountFrame
    activeTarget = target
    activeTabID = tabID
    activeSession = gen

    sessions.beginPreview(tabID, session: gen, for: target)

    guard gen == generation else {
      // Superseded while mounting — clean up what THIS step allocated (including the just-registered
      // preview claim), don't just no-op (Codex #3).
      teardownAllocatedState()
      return
    }

    previewHost = host
    frameSource.startPresenting { [weak self] in
      guard let self, gen == self.generation else { return }
      self.phase = .visible(tabID: tabID)
    }
  }

  private func teardown() {
    teardownAllocatedState()
    phase = .idle
  }

  /// Releases whatever the current session allocated (frame source, mounted surface/host, and the
  /// `TerminalSessions` preview claim), restoring the surface to its original superview/frame. The
  /// ONE cleanup path for both a normal teardown and a superseded-mid-mount cleanup (Codex #3 — a
  /// stale generation must release resources, not merely skip applying its result) — uses
  /// `activeSession`, not the live `generation` counter, for the exact reason `mount()`'s comment
  /// above explains.
  private func teardownAllocatedState() {
    activeFrameSource?.stopPresenting()
    // `unmount()` itself guards against detaching a surface that's since been legitimately re-homed
    // elsewhere (a real focus/tab switch, `TerminalContainerView.mount(in:)`) — found via real-mouse
    // QA: clicking the previewed tab re-homed its surface into the real container before this
    // teardown ran; an unconditional `removeFromSuperview()` yanked it straight back out, blanking the
    // pane the user had just switched to. See `TransformScaleFrameSource.unmount()`.
    activeFrameSource?.unmount()
    activeFrameSource = nil

    // Nil-safe by construction: a preview-eligible tab is, by `isPreviewEligible`'s own definition,
    // already detached (`superview == nil`) before a hover ever starts, so `originalSuperview` is
    // always nil in production and this never actually restores anything today. Kept as a defensive
    // no-op for any future case where a preview could start from a non-detached surface.
    if let surface = mountedSurface, let superview = originalSuperview, let frame = originalFrame {
      surface.frame = frame
      surface.autoresizingMask = [.width, .height]
      superview.addSubview(surface)
    }
    if let target = activeTarget, let tabID = activeTabID, let session = activeSession {
      sessions.endPreview(tabID, session: session, for: target)
    }
    mountedSurface = nil
    originalSuperview = nil
    originalFrame = nil
    previewHost = nil
    activeTarget = nil
    activeTabID = nil
    activeSession = nil
  }
}

/// The floating preview's host container — hit-testing disabled unconditionally (Codex #12): a real,
/// live, merely-scaled `GhosttySurfaceView` sitting on screen must never receive accidental clicks or
/// route input to the real terminal it's a preview of.
final class PreviewHostView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
