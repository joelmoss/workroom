import XCTest

/// Allows macOS's Local Network prompt for every UI test: *Allow "Workroom Dev" to find devices on
/// local networks?*. An ad-hoc-signed build (a hosted CI runner's) is a new app to TCC, so the
/// prompt can come up mid-run. It then stays up, covers the middle of the screen and takes the
/// clicks of every later test. XCTest's own permission handler doesn't match its wording (it looks
/// for "would like to …"), so without this monitor the prompt is never dismissed.
///
/// Registered as the UI-test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass` in
/// `project.yml`), so every test case gets the monitor, including ones that build their own
/// `XCUIApplication`. A monitor runs only when XCTest finds an element in the way of an interaction,
/// and this one handles only the Local Network prompt. It returns false for anything else, such
/// as the app's own Quick Terminal panel, which XCTest also reports as interrupting.
@objc(LocalNetworkPromptObserver)
final class LocalNetworkPromptObserver: NSObject, XCTestObservation {
  override init() {
    super.init()
    XCTestObservationCenter.shared.addTestObserver(self)
  }

  func testCaseWillStart(_ testCase: XCTestCase) {
    testCase.addUIInterruptionMonitor(withDescription: "Local Network prompt") { dialog in
      Self.allowLocalNetwork(in: dialog)
    }
  }

  /// Clicks Allow when `dialog` is the Local Network prompt. Returns whether it handled it.
  static func allowLocalNetwork(in dialog: XCUIElement) -> Bool {
    let wording = NSPredicate(
      format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR title CONTAINS[c] %@",
      "local network", "local network", "local network")
    guard dialog.staticTexts.matching(wording).firstMatch.exists else { return false }
    let allow = dialog.buttons.matching(
      NSPredicate(format: "label == %@ OR title == %@", "Allow", "Allow")
    )
    .firstMatch
    guard allow.exists else { return false }
    allow.click()
    return true
  }
}
