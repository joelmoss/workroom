import Combine
import Defaults
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI can drive it: the "Check for Updates…" menu command
/// and the Settings toggle bind here. The controller starts the updater at launch, so (with
/// SUEnableAutomaticChecks on) it runs scheduled background checks against the appcast feed declared
/// by SUFeedURL in Info.plist, verifying downloads against SUPublicEDKey.
///
/// It also surfaces a quiet toolbar "Update" pill (`availableVersionString`) whenever an update is
/// available: `SPUUpdaterDelegate.updater(_:didFindValidUpdate:)` sets it for *any* check — manual
/// "Check for Updates…" included — and the `SPUStandardUserDriverDelegate` gentle-reminder path keeps
/// background checks from forcing a window. The pill is cleared when the update is installed or no
/// longer offered — but NOT on cancel/Later, so after the user dismisses Sparkle's prompt a
/// still-available update keeps its affordance.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  private var controller: SPUStandardUpdaterController!

  /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item disables itself while a check is
  /// already in flight.
  @Published var canCheckForUpdates = false

  /// The version of an update Sparkle found in the background but is NOT itself presenting (a gentle
  /// reminder) — drives the toolbar "Update" pill. nil means nothing to surface. Deliberately a
  /// `String` (not `SUAppcastItem`) so views don't depend on Sparkle types.
  @Published private(set) var availableVersionString: String?

  override init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    controller.updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)

    // Visual-QA seam: surface a fake pending update so the pill renders without a live Sparkle check.
    if let fake = UITestFixture.updateAvailableVersion { setAvailable(fake) }

    migrateReleaseChannelIfNeeded()  // before the first check, so it honors the migrated channel

    #if DEBUG
      // The "Workroom Dev" build shares the release appcast feed but carries a dev version, so a
      // scheduled check would offer to "update" it to the release DMG and replace the running dev
      // build. Force scheduled checks off for Debug (the manual "Check for Updates…" menu item still
      // works if you explicitly want it). Release is unaffected.
      controller.updater.automaticallyChecksForUpdates = false
    #else
      // Surface a previously-found update promptly on launch instead of waiting for the next
      // scheduled check (the pill would otherwise stay empty until then). Silent unless one is found.
      controller.updater.checkForUpdatesInBackground()
    #endif
  }

  /// Show the updater UI now — the user-initiated "Check for Updates…" path (also the pill's action,
  /// which presents the already-found update).
  func checkForUpdates() {
    controller.updater.checkForUpdates()
  }

  // MARK: - Release-channel migration (issue #91)

  /// One-time migration for users upgrading from a pre-channels build. The app has only ever
  /// shipped betas, so an existing install is running a prerelease and was receiving beta updates.
  /// Defaulting everyone to `.stable` would silently freeze those users on their current beta until
  /// GA — so when the preference has never been set AND the running build is a prerelease, opt them
  /// into `.pre` to preserve their update stream. Fresh/stable installs fall through to `.stable`.
  private func migrateReleaseChannelIfNeeded() {
    // The nightly build's channel is fixed by identity — there's no stable/pre pref to migrate.
    if ReleaseChannel.isNightlyBuild { return }

    // A first-pass build let the picker choose `.nightly`; that's no longer a main-app channel
    // (nightly is the separate Workroom Nightly product), so coerce a legacy selection to stable.
    if Defaults[.releaseChannel] == .nightly {
      Defaults[.releaseChannel] = .stable
      return
    }

    let keyIsSet = UserDefaults.standard.object(forKey: Defaults.Keys.releaseChannel.name) != nil
    if Self.shouldDefaultToPre(channelKeyIsSet: keyIsSet, currentVersion: AppVersion.current) {
      Defaults[.releaseChannel] = .pre
    }
  }

  /// Pure decision for the migration above (factored out so it's unit-testable without touching
  /// UserDefaults or a live Sparkle session): migrate to `.pre` only when the channel has never
  /// been chosen and the running version parses as a prerelease.
  nonisolated static func shouldDefaultToPre(channelKeyIsSet: Bool, currentVersion: String?) -> Bool
  {
    guard !channelKeyIsSet else { return false }
    guard let v = currentVersion, let semver = SemanticVersion(v) else { return false }
    return !semver.prerelease.isEmpty
  }

  /// Whether Sparkle runs scheduled background checks. Bound to the Settings toggle; Sparkle persists
  /// it under SUEnableAutomaticChecks in UserDefaults.
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  // MARK: - Pill state

  /// Set/clear the pill's version. Sparkle's delegate callbacks run on the main thread, but route the
  /// `@Published` mutation through here so it's always main-thread even if that ever changes.
  /// Factored out (not inlined in the callbacks) so the state transitions are unit-testable.
  func setAvailable(_ version: String?) {
    if Thread.isMainThread {
      availableVersionString = version
    } else {
      DispatchQueue.main.async { [weak self] in self?.availableVersionString = version }
    }
  }

  func clearAvailable() { setAvailable(nil) }

  // MARK: - SPUStandardUserDriverDelegate (gentle scheduled update reminders)

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // Let Sparkle present updates it wants to show in immediate focus (e.g. just after launch);
    // we handle quieter background ones ourselves via the pill.
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    // Only surface the pill for updates Sparkle ISN'T itself showing (background / gentle); when
    // Sparkle handles the presentation (manual checks, immediate focus) the pill would be redundant.
    guard !handleShowingUpdate else { return }
    setAvailable(update.displayVersionString)
  }

  // MARK: - SPUUpdaterDelegate (release channels — issue #91)

  /// Restrict update checks to the user's chosen release channel. Sparkle always includes the
  /// default (untagged = stable) channel, so this returns only the EXTRA channels a pre/nightly
  /// subscriber opts into. Read live from Defaults, so changing the Settings picker takes effect on
  /// the next check without restarting.
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    Self.allowedChannels(
      isNightlyBuild: ReleaseChannel.isNightlyBuild, picked: Defaults[.releaseChannel])
  }

  /// Pure mapping (unit-testable without a live Sparkle session or the Info.plist marker): the
  /// pinned nightly build always tracks `nightly`; the main app uses the picked channel's floor.
  nonisolated static func allowedChannels(isNightlyBuild: Bool, picked: ReleaseChannel) -> Set<
    String
  > {
    isNightlyBuild ? [ReleaseChannel.nightly.rawValue] : picked.allowedSparkleChannels
  }

  // MARK: - SPUUpdaterDelegate (pill clear policy — D7)

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    // Surface the pill for ANY found update — including a manual "Check for Updates…" — so that once
    // the user dismisses Sparkle's prompt (Later / close) the affordance stays. Fires for both manual
    // and scheduled checks, unlike the gentle-reminder driver path, which only sees updates Sparkle
    // isn't itself presenting.
    setAvailable(item.displayVersionString)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    // A later check confirmed no update is available → the pill is stale, clear it.
    clearAvailable()
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    // Installing now; the relaunch resets state anyway, but clear so the pill doesn't linger.
    clearAvailable()
  }
}
