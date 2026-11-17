import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest

@testable import Workroom

/// The shortcut registry (#148, ADR 0076): the catalog, matching, conflicts, recording rules,
/// saved changes, migration and search.
@MainActor
final class ShortcutRegistryTests: XCTestCase {
  private var suite: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "ShortcutRegistryTests.\(UUID().uuidString)"
    suite = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    suite.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func registry(systemSettings: [String: KeyChord] = [:]) -> Shortcuts {
    Shortcuts(suite: suite, systemSettings: { systemSettings })
  }

  private func chord(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ unshifted: String?)
    -> KeyChord?
  {
    KeyChord(keyCode: keyCode, flags: flags, unshifted: unshifted)
  }

  // MARK: Catalog

  func testNoTwoDefaultsShareKeys() {
    var holders: [KeyChord: ShortcutAction] = [:]
    for action in ShortcutAction.allCases {
      guard let binding = action.defaultBinding else { continue }
      XCTAssertTrue(ShortcutTable.fits(binding, action), "\(action)'s default has the wrong shape")
      for chord in ShortcutTable.chords(for: action, binding) {
        if let other = holders[chord] {
          XCTFail("\(chord.label) is the default of both \(other) and \(action)")
        }
        holders[chord] = action
      }
    }
  }

  func testNoDefaultTakesAStandardMacOSKey() {
    for action in ShortcutAction.allCases {
      guard let binding = action.defaultBinding else { continue }
      for chord in ShortcutTable.chords(for: action, binding) {
        XCTAssertFalse(
          StandardShortcut.all.contains { $0.chord == chord },
          "\(action) defaults to \(chord.label), a standard macOS key")
      }
    }
  }

  func testEveryActionHasALabelASummaryAndAGroup() {
    for action in ShortcutAction.allCases {
      XCTAssertFalse(action.label.isEmpty)
      XCTAssertFalse(action.summary.isEmpty)
      XCTAssertTrue(action.group.actions.contains(action))
    }
    XCTAssertEqual(ShortcutGroup.allCases.first, .global)
    XCTAssertEqual(ShortcutGroup.global.actions, [.showHideWorkroom, .quickTerminal])
    XCTAssertEqual(ShortcutGroup.allCases.count, 13)
  }

  func testOnlyTheTwoGlobalShortcutsAreGlobal() {
    XCTAssertEqual(
      ShortcutAction.allCases.filter(\.isGlobal), [.showHideWorkroom, .quickTerminal])
  }

  // MARK: Chords

  func testAKeyPressReadsAsItsUnshiftedCharacter() throws {
    let splitDown = try XCTUnwrap(chord(kVK_ANSI_D, [.command, .shift], "d"))
    XCTAssertEqual(splitDown, .key("d", [.command, .shift]))
    XCTAssertEqual(splitDown.label, "⇧⌘D")
    // ⇧⌘[ is still [ unshifted, where `charactersIgnoringModifiers` would say {.
    XCTAssertEqual(
      chord(kVK_ANSI_LeftBracket, [.command, .shift], "["), .key("[", [.command, .shift]))
  }

  func testCharacterKeysMatchByCharacterNotPosition() throws {
    // AZERTY's A key sits where US has Q: it still reads as A.
    let azertyA = try XCTUnwrap(chord(kVK_ANSI_Q, .command, "a"))
    XCTAssertEqual(azertyA, .key("a", .command))
    XCTAssertNotEqual(azertyA, .key("q", .command))
  }

  func testNamedKeysMatchByKeyCode() throws {
    let left = try XCTUnwrap(chord(kVK_LeftArrow, [.command, .option, .function], "\u{F702}"))
    XCTAssertEqual(left, .named(kVK_LeftArrow, [.command, .option]))
    XCTAssertEqual(left.label, "⌥⌘←")
    XCTAssertEqual(chord(kVK_F5, [], "\u{F708}")?.label, "F5")
    XCTAssertTrue(try XCTUnwrap(chord(kVK_F5, [], nil)).isFunctionKey)
    XCTAssertEqual(chord(kVK_Tab, .option, "\t"), .named(kVK_Tab, .option))
  }

  /// A real key event: ⇧ is left out of the character (⇧⌘` is "`", not "~"), ⌘ is kept so a
  /// non-Latin layout reads its ⌘ layer's Latin letter. Reads the host's layout, a US one.
  func testAKeyEventReadsItsCharacterWithoutShift() throws {
    func press(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ typed: String) -> KeyChord? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false,
        keyCode: UInt16(keyCode)
      ).flatMap(KeyChord.init)
    }
    XCTAssertEqual(press(kVK_ANSI_Grave, [.command, .shift], "~"), .key("`", [.command, .shift]))
    XCTAssertEqual(press(kVK_ANSI_T, .command, "t"), .key("t", .command))
  }

  func testAKeyWithNoCharacterIsNoChord() {
    XCTAssertNil(chord(kVK_ANSI_A, .command, nil))
    XCTAssertNil(chord(kVK_ANSI_A, .command, "\u{F700}"))
  }

  func testAChordBecomesTheMenusKeyEquivalent() {
    XCTAssertEqual(
      KeyChord.key("t", .command).keyboardShortcut, KeyboardShortcut("t", modifiers: .command))
    XCTAssertEqual(
      KeyChord.named(kVK_UpArrow, .command).keyboardShortcut,
      KeyboardShortcut(.upArrow, modifiers: .command))
    XCTAssertEqual(
      KeyChord.named(kVK_Return, [.command, .option]).keyboardShortcut,
      KeyboardShortcut(.return, modifiers: [.command, .option]))
  }

  func testAChordRoundTripsThroughJSON() throws {
    let chord = KeyChord(modifiers: [.control, .shift], keyCode: kVK_ANSI_T, character: "t")
    let data = try JSONEncoder().encode(ShortcutOverride.bound(.chord(chord)))
    XCTAssertEqual(
      try JSONDecoder().decode(ShortcutOverride.self, from: data), .bound(.chord(chord)))
  }

  func testCarbonMasksRoundTrip() {
    let modifiers: KeyModifiers = [.command, .option, .control, .shift]
    XCTAssertEqual(KeyModifiers(carbon: modifiers.carbon), modifiers)
    XCTAssertEqual(KeyModifiers.option.carbon, optionKey)
  }

  // MARK: The table

  func testDefaultsMatchTheirKeys() {
    let table = ShortcutTable.defaults
    XCTAssertEqual(table.match(.key("t", .command)), ShortcutMatch(.newTerminal))
    XCTAssertEqual(table.match(.key("3", .command)), ShortcutMatch(.focusTerminalTab3))
    XCTAssertEqual(
      table.match(.key("9", [.command, .option])), ShortcutMatch(.switchToWorkroomTab9))
    XCTAssertEqual(
      table.match(.named(kVK_UpArrow, [.command, .control])), ShortcutMatch(.focusPaneUp))
    XCTAssertEqual(table.match(.named(kVK_Tab, .option)), ShortcutMatch(.lastUsedWorkroom))
    XCTAssertEqual(
      table.match(.named(kVK_Tab, [.control, .shift])),
      ShortcutMatch(.lastUsedPane, reverse: true))
    XCTAssertEqual(table.match(.key("`", [.command, .shift])), ShortcutMatch(.previousWindow))
    XCTAssertNil(table.match(.key("t", .control)))
    XCTAssertEqual(table.label(for: .focusTerminalTab1), "⌘1")
    XCTAssertEqual(table.label(for: .lastUsedWorkroom), "⌥⇥")
    XCTAssertEqual(table.hint(for: .run), " (⌘R)")
    XCTAssertEqual(table.hint(for: .newProject), "")
  }

  func testReservedKeysOnTheDefaults() {
    let table = ShortcutTable.defaults
    XCTAssertTrue(table.isReserved(.key("r", .command)))
    XCTAssertTrue(table.isReserved(.key("q", .command)), "Quit reaches its menu")
    XCTAssertTrue(table.isReserved(.key("s", [.command, .option])), "Toggle Sidebar is caught")
    XCTAssertFalse(table.isReserved(.key("c", .command)), "the terminal copies")
    XCTAssertFalse(table.isReserved(.named(kVK_LeftArrow, [.command, .control])))
    XCTAssertFalse(table.isReserved(.named(kVK_Tab, .control)))
    XCTAssertFalse(table.isReserved(.key("1", [.command, .option])))
    XCTAssertFalse(table.isReserved(.key("b", [.command, .option])), "⌥⌘B is no longer bound")
  }

  func testAnUnsetShortcutGivesItsKeysBack() {
    let table = ShortcutTable(overrides: ["run": .unset])
    XCTAssertNil(table.binding(for: .run))
    XCTAssertNil(table.match(.key("r", .command)))
    XCTAssertFalse(table.isReserved(.key("r", .command)))
    XCTAssertEqual(table.resolved[.run]?.source, .user)
  }

  func testARebindMovesTheMatchAndTheReservation() {
    let table = ShortcutTable(overrides: ["fetch": .bound(.chord(.key("r", .control)))])
    XCTAssertEqual(table.match(.key("r", .control)), ShortcutMatch(.fetch))
    XCTAssertTrue(table.isReserved(.key("r", .control)))
    XCTAssertNil(table.match(.key("f", [.command, .option, .shift])))
  }

  /// Each tab position and pane direction is a shortcut of its own: moving one leaves the rest.
  func testATabPositionRebindsAlone() {
    let table = ShortcutTable(overrides: ["focusTerminalTab5": .bound(.chord(.key("5", .control)))])
    XCTAssertEqual(table.match(.key("5", .control)), ShortcutMatch(.focusTerminalTab5))
    XCTAssertNil(table.match(.key("5", .command)))
    XCTAssertEqual(table.match(.key("4", .command)), ShortcutMatch(.focusTerminalTab4))
    XCTAssertEqual(ShortcutAction.focusTerminalTab5.terminalTabIndex, 4)
    XCTAssertEqual(ShortcutAction.focusPaneDown.paneDirection, .down)
    XCTAssertEqual(ShortcutAction.switchToWorkroomTab9.label, "Switch to Workroom Tab 9")
  }

  func testANewDefaultTheUserAlreadyHoldsStartsUnset() {
    // The user put Fetch on ⌘T; a later version's New Terminal default is ⌘T too.
    let table = ShortcutTable(overrides: ["fetch": .bound(.chord(.key("t", .command)))])
    XCTAssertEqual(table.match(.key("t", .command)), ShortcutMatch(.fetch))
    XCTAssertNil(table.binding(for: .newTerminal))
    XCTAssertEqual(table.resolved[.newTerminal]?.displacedBy, .fetch)
  }

  func testASavedChangeOfTheWrongShapeIsIgnored() {
    let table = ShortcutTable(overrides: [
      "lastUsedPane": .bound(.chord(.key("t", .command))), "noSuchAction": .unset,
    ])
    XCTAssertEqual(table.binding(for: .lastUsedPane), .modifiers(.control))
  }

  // MARK: System Settings

  func testSystemSettingsKeyEquivalentsParse() {
    XCTAssertEqual(KeyChord(userKeyEquivalent: "@$k"), .key("k", [.command, .shift]))
    XCTAssertEqual(KeyChord(userKeyEquivalent: "^~t"), .key("t", [.control, .option]))
    XCTAssertEqual(KeyChord(userKeyEquivalent: "@\u{F702}"), .named(kVK_LeftArrow, .command))
    XCTAssertEqual(KeyChord(userKeyEquivalent: "@T"), .key("t", [.command, .shift]))
    XCTAssertNil(KeyChord(userKeyEquivalent: ""))
  }

  func testASystemSettingsShortcutWinsAndPinsItsKeys() {
    let table = ShortcutTable(
      overrides: [:],
      systemSettings: ["Theme…": .key("t", .command), "Not Ours": .key("j", .command)])
    XCTAssertEqual(table.resolved[.theme]?.source, .systemSettings)
    XCTAssertEqual(table.match(.key("t", .command)), ShortcutMatch(.theme))
    XCTAssertEqual(table.resolved[.newTerminal]?.displacedBy, .theme)
  }

  /// All Applications' App Shortcuts count even when Workroom has one of its own, which wins.
  func testSystemSettingsMergesTheAppsShortcutsOverAllApplications() {
    let merged = Shortcuts.mergeSystemSettings(
      app: ["Theme…": "@j", "Bad": 5], global: ["Theme…": "@k", "Fetch": "@^f"])
    XCTAssertEqual(
      merged, ["Theme…": .key("j", .command), "Fetch": .key("f", [.command, .control])])
    XCTAssertEqual(Shortcuts.mergeSystemSettings(app: nil, global: "not a dictionary"), [:])
  }

  /// The real Carbon probe behind "Another app uses that shortcut.": keys this test holds are
  /// taken, and free once let go.
  func testTheAvailabilityProbeSeesAHeldShortcut() {
    let chord = KeyChord.named(kVK_F19, [.command, .option, .control, .shift])
    XCTAssertTrue(GlobalHotkey.isAvailable(chord), "nothing holds ⌃⌥⇧⌘F19")
    var held = GlobalHotkey.register(chord, id: 2) {}
    XCTAssertNotNil(held)
    XCTAssertFalse(GlobalHotkey.isAvailable(chord), "held by us now")
    held = nil
    XCTAssertTrue(GlobalHotkey.isAvailable(chord), "let go again")
    _ = held
  }

  func testRecordingKeysSystemSettingsHoldsIsRefused() {
    let table = ShortcutTable(overrides: [:], systemSettings: ["Theme…": .key("j", .command)])
    XCTAssertEqual(
      verdict(.push, .key("j", .command), table), .refuse("System Settings sets that for Theme…."))
  }

  // MARK: Recording

  private func verdict(
    _ action: ShortcutAction, _ chord: KeyChord?, _ table: ShortcutTable = .defaults,
    available: Bool = true
  ) -> ShortcutRecording.Verdict {
    ShortcutRecording.verdict(
      for: action, chord: chord, table: table, isGloballyAvailable: { _ in available })
  }

  func testEscapeCancels() {
    XCTAssertEqual(verdict(.run, .named(kVK_Escape, [])), .cancel)
  }

  func testAShortcutNeedsCommandOptionOrControlUnlessItIsAnFKey() {
    XCTAssertEqual(verdict(.run, .key("r", [])), .refuse("Include ⌘, ⌥ or ⌃."))
    XCTAssertEqual(verdict(.run, .key("r", .shift)), .refuse("Include ⌘, ⌥ or ⌃."))
    XCTAssertEqual(
      verdict(.run, .named(kVK_F5, [])), .accept(.chord(.named(kVK_F5, [])), conflicts: []))
    XCTAssertEqual(
      verdict(.run, .key("e", .option)), .accept(.chord(.key("e", .option)), conflicts: []))
  }

  func testStandardMacOSKeysAreRefused() {
    XCTAssertEqual(
      verdict(.run, .key("c", .command)), .refuse("⌘C is Copy, a standard macOS shortcut."))
    XCTAssertEqual(
      verdict(.run, .key("q", .command)), .refuse("⌘Q is Quit, a standard macOS shortcut."))
  }

  func testKeysAnotherActionHoldsComeBackAsAConflict() {
    XCTAssertEqual(
      verdict(.fetch, .key("t", .command)),
      .accept(.chord(.key("t", .command)), conflicts: [.newTerminal]))
  }

  func testRecordingTheCurrentKeysChangesNothing() {
    XCTAssertEqual(
      verdict(.quickTerminal, .key("§", .option), available: false),
      .accept(.chord(.key("§", .option)), conflicts: []))
  }

  func testAGlobalShortcutAnotherAppHoldsIsRefused() {
    XCTAssertEqual(
      verdict(.quickTerminal, .key("k", .option), available: false),
      .refuse("Another app uses that shortcut."))
    XCTAssertEqual(
      verdict(.quickTerminal, .key("k", .option)),
      .accept(.chord(.key("k", .option)), conflicts: []))
    // ⌘§ is Show/Hide's: an ordinary conflict, not a refusal by name.
    XCTAssertEqual(
      verdict(.quickTerminal, .key("§", .command), available: false),
      .accept(.chord(.key("§", .command)), conflicts: [.showHideWorkroom]))
  }

  func testASwitcherTakesOnlyModifiersAndTab() {
    XCTAssertEqual(
      verdict(.lastUsedWorkroom, .key("k", .option)),
      .refuse("This switcher steps with Tab; choose its modifiers."))
    XCTAssertEqual(
      verdict(.lastUsedWorkroom, .named(kVK_Tab, [.command, .control, .shift])),
      .accept(.modifiers([.command, .control]), conflicts: []))
    XCTAssertEqual(
      verdict(.lastUsedWorkroom, .named(kVK_Tab, .command)), .refuse("⌘⇥ switches apps in macOS."))
    XCTAssertEqual(
      verdict(.lastUsedWorkroom, .named(kVK_Tab, .shift)), .refuse("Include ⌘, ⌥ or ⌃."))
    XCTAssertEqual(
      verdict(.lastUsedWorkroom, .named(kVK_Tab, .control)),
      .accept(.modifiers(.control), conflicts: [.lastUsedPane]))
  }

  func testATabPositionTakesAnyKeys() {
    XCTAssertEqual(
      verdict(.focusTerminalTab2, .key("t", [.control, .option])),
      .accept(.chord(.key("t", [.control, .option])), conflicts: []))
    XCTAssertEqual(
      verdict(.focusPaneUp, .named(kVK_UpArrow, [.command, .option])),
      .accept(.chord(.named(kVK_UpArrow, [.command, .option])), conflicts: []))
    XCTAssertEqual(
      verdict(.focusPaneLeft, .named(kVK_LeftArrow, [.command, .option])),
      .accept(
        .chord(.named(kVK_LeftArrow, [.command, .option])), conflicts: [.previousTerminalTab]))
  }

  func testTheTerminalNoteIsForInAppKeysWithoutCommand() {
    XCTAssertEqual(
      ShortcutRecording.terminalNote(for: .run, .chord(.key("r", .control))),
      "Terminal programs will no longer get ⌃R.")
    XCTAssertNil(ShortcutRecording.terminalNote(for: .run, .chord(.key("r", .command))))
    XCTAssertNil(ShortcutRecording.terminalNote(for: .quickTerminal, .chord(.key("k", .option))))
    XCTAssertEqual(
      ShortcutRecording.terminalNote(for: .lastUsedWorkroom, .modifiers(.option)),
      "Terminal programs get ⌥⇥ only when Last-Used Workroom has nothing to do.")
    XCTAssertEqual(
      ShortcutRecording.terminalNote(for: .focusTerminalTab1, .chord(.key("1", .control))),
      "Terminal programs will no longer get ⌃1.")
  }

  func testTheConflictMessageNamesWhatLosesItsShortcut() {
    XCTAssertEqual(
      ShortcutRecording.conflictMessage(
        for: .theme, .chord(.key("p", [.command, .shift])), conflicts: [.push]),
      "⇧⌘P is used by Push. Use it for Theme… instead? Push will have no shortcut.")
  }

  // MARK: The registry

  func testATestsRegistryLeavesTheAppsAlone() {
    let shortcuts = registry()
    shortcuts.unset(.newTerminal)
    shortcuts.isRecording = true
    XCTAssertEqual(Shortcuts.current, Shortcuts.shared.table)
    XCTAssertFalse(Shortcuts.recording)
    shortcuts.isRecording = false
  }

  func testChangesAreSavedAndSurviveARelaunch() {
    let shortcuts = registry()
    shortcuts.set(.chord(.key("j", .command)), for: .run)
    XCTAssertEqual(shortcuts.table.binding(for: .run), .chord(.key("j", .command)))
    XCTAssertEqual(registry().table.binding(for: .run), .chord(.key("j", .command)))
    XCTAssertEqual(registry().customCount, 1)
  }

  func testUsingConflictingKeysUnsetsTheirHolder() {
    let shortcuts = registry()
    shortcuts.set(.chord(.key("t", .command)), for: .fetch, unsetting: [.newTerminal])
    XCTAssertNil(shortcuts.table.binding(for: .newTerminal))
    XCTAssertNil(shortcuts.table.resolved[.newTerminal]?.displacedBy)
    XCTAssertEqual(shortcuts.table.match(.key("t", .command)), ShortcutMatch(.fetch))
  }

  func testRemoveResetAndRestoreDefaults() {
    let shortcuts = registry()
    shortcuts.unset(.run)
    XCTAssertNil(shortcuts.table.binding(for: .run))
    shortcuts.reset(.run)
    XCTAssertEqual(shortcuts.table.binding(for: .run), ShortcutAction.run.defaultBinding)
    XCTAssertEqual(shortcuts.customCount, 0)

    shortcuts.unset(.push)
    shortcuts.set(.chord(.key("1", .control)), for: .focusTerminalTab1)
    XCTAssertEqual(shortcuts.customCount, 2)
    shortcuts.restoreDefaults()
    XCTAssertEqual(shortcuts.table, .defaults)
  }

  func testSettingTheDefaultSavesNoChange() {
    let shortcuts = registry()
    shortcuts.set(.chord(.key("r", .command)), for: .run)
    XCTAssertEqual(shortcuts.customCount, 0)
  }

  func testUnsettingAnActionWithNoDefaultSavesNoChange() {
    let shortcuts = registry()
    shortcuts.set(.chord(.key("j", .command)), for: .newProject)
    shortcuts.unset(.newProject)
    XCTAssertEqual(shortcuts.customCount, 0)
    XCTAssertNil(shortcuts.table.binding(for: .newProject))
  }

  func testAGlobalChangeIsAnnounced() {
    let shortcuts = registry()
    let announced = expectation(forNotification: .shortcutsGlobalsChanged, object: nil)
    shortcuts.set(.chord(.key("k", .option)), for: .quickTerminal)
    wait(for: [announced], timeout: 1)
  }

  // MARK: Migration

  func testMigrationCarriesTheOldSettingsOver() {
    suite.set(
      #"{"keyCode":40,"carbonModifiers":\#(optionKey | controlKey),"key":"k"}"#,
      forKey: "quickTerminalShortcut")
    suite.set("commandControl", forKey: "switcher.workroomModifier")
    suite.set("control", forKey: "switcher.paneModifier")  // the default: no change
    let shortcuts = registry()
    XCTAssertEqual(
      shortcuts.table.binding(for: .quickTerminal),
      .chord(KeyChord(modifiers: [.control, .option], keyCode: 40, character: "k")))
    XCTAssertEqual(
      shortcuts.table.binding(for: .lastUsedWorkroom), .modifiers([.command, .control]))
    XCTAssertEqual(shortcuts.customCount, 2)
    XCTAssertNotNil(shortcuts.table.binding(for: .showHideWorkroom))
    XCTAssertNotNil(suite.object(forKey: "quickTerminalShortcut"), "kept for an older build")
    XCTAssertNotNil(suite.object(forKey: "switcher.workroomModifier"), "kept for an older build")
  }

  func testMigrationTurnsTheGlobalHotkeyToggleOffIntoUnsetGlobals() {
    suite.set(false, forKey: "globalHotkeyEnabled")
    let shortcuts = registry()
    XCTAssertNil(shortcuts.table.binding(for: .showHideWorkroom))
    XCTAssertNil(shortcuts.table.binding(for: .quickTerminal))
    XCTAssertEqual(
      suite.object(forKey: "globalHotkeyEnabled") as? Bool, false,
      "kept, so an older build still leaves its global hotkey off")
  }

  func testMigrationRunsOnce() {
    _ = registry()
    suite.set(false, forKey: "globalHotkeyEnabled")
    XCTAssertNotNil(registry().table.binding(for: .showHideWorkroom))
  }

  func testAToggleThatWasOnMigratesToNothing() {
    suite.set(true, forKey: "globalHotkeyEnabled")
    XCTAssertEqual(registry().customCount, 0)
  }

  // MARK: Search

  private func search(_ query: String) -> [ShortcutAction] {
    ShortcutAction.allCases.filter {
      Shortcuts.matches($0, query: query, table: .defaults)
    }
  }

  func testSearchMatchesLabelsDescriptionsAndKeys() {
    XCTAssertTrue(search("terminal").contains(.newTerminal))
    XCTAssertTrue(search("scrollback").contains(.find), "the description")
    XCTAssertTrue(search("⌘T").contains(.newTerminal))
    XCTAssertTrue(search("cmd t").contains(.newTerminal))
    XCTAssertFalse(search("cmd t").contains(.run), "a modifier makes it a search by keys")
    XCTAssertTrue(search("ctrl cmd").contains(.focusPaneLeft))
    XCTAssertTrue(search("shift").contains(.push))
    XCTAssertFalse(search("shift").contains(.run))
    XCTAssertEqual(search(""), ShortcutAction.allCases)
    XCTAssertTrue(search("zzzz").isEmpty)
  }
}

/// Settings ▸ Keyboard Shortcuts' recorder (#148): what a press does to a recording row.
@MainActor
final class ShortcutRecorderModelTests: XCTestCase {
  private var suite: UserDefaults!
  private var suiteName: String!
  private var shortcuts: Shortcuts!
  private var model: ShortcutRecorderModel!

  override func setUp() {
    super.setUp()
    suiteName = "ShortcutRecorderModelTests.\(UUID().uuidString)"
    suite = UserDefaults(suiteName: suiteName)
    shortcuts = Shortcuts(suite: suite, systemSettings: { [:] })
    model = ShortcutRecorderModel(shortcuts: shortcuts, isGloballyAvailable: { _ in true })
  }

  override func tearDown() {
    model.stop()
    suite.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testRecordingPausesTheAppsOwnShortcuts() {
    model.start(.action(.run))
    XCTAssertTrue(model.isRecording(.action(.run)))
    XCTAssertTrue(shortcuts.isRecording)
    model.stop()
    XCTAssertFalse(shortcuts.isRecording)
  }

  func testTheAppsRegistryTellsTheKeyMonitorItIsRecording() {
    let model = ShortcutRecorderModel(shortcuts: .shared, isGloballyAvailable: { _ in true })
    model.start(.action(.run))
    XCTAssertTrue(Shortcuts.recording, "the key monitor stands down")
    model.stop()
    XCTAssertFalse(Shortcuts.recording)
  }

  func testAFreeShortcutIsUsedAtOnce() {
    model.start(.action(.run))
    model.record(.key("j", .command))
    XCTAssertNil(model.pending)
    XCTAssertFalse(model.isRecording(.action(.run)))
    XCTAssertEqual(shortcuts.table.binding(for: .run), .chord(.key("j", .command)))
  }

  func testTakenKeysAskFirstAndUseForUnsetsTheirHolder() throws {
    model.start(.action(.fetch))
    model.record(.key("t", .command))
    let pending = try XCTUnwrap(model.pending)
    XCTAssertEqual(pending.conflicts, [.newTerminal])
    XCTAssertFalse(shortcuts.isRecording, "recording ends while the alert asks")
    XCTAssertEqual(
      shortcuts.table.binding(for: .fetch), ShortcutAction.fetch.defaultBinding,
      "nothing changes until the user says")
    model.confirm(pending)
    XCTAssertEqual(shortcuts.table.match(.key("t", .command)), ShortcutMatch(.fetch))
    XCTAssertNil(shortcuts.table.binding(for: .newTerminal))
    XCTAssertNil(model.pending)
  }

  func testARefusedPressKeepsRecordingAndSaysWhy() {
    model.start(.action(.run))
    model.record(.key("c", .command))
    XCTAssertTrue(model.isRecording(.action(.run)))
    XCTAssertEqual(model.problems[.run], "⌘C is Copy, a standard macOS shortcut.")
    model.record(.key("j", .command))
    XCTAssertNil(model.problems[.run])
  }

  func testEscapeCancelsAndChangesNothing() {
    model.start(.action(.run))
    model.record(.named(kVK_Escape, []))
    XCTAssertFalse(model.isRecording(.action(.run)))
    XCTAssertEqual(shortcuts.customCount, 0)
  }

  func testRecordingCloseTabsKeysRecordsThem() {
    // ⌘W and ⌘` act in the key monitor; while recording they're just keys.
    model.start(.action(.newWindow))
    model.record(.key("`", [.command, .option]))
    XCTAssertEqual(
      shortcuts.table.binding(for: .newWindow), .chord(.key("`", [.command, .option])))
  }

  func testResetOfAnUnsetRowWhoseDefaultIsTakenAsks() throws {
    shortcuts.unset(.newTerminal)
    shortcuts.set(.chord(.key("t", .command)), for: .fetch)
    model.reset(.newTerminal)
    let pending = try XCTUnwrap(model.pending, "Reset asks to take ⌘T back from Fetch")
    XCTAssertEqual(pending.conflicts, [.fetch])
  }

  func testCancellingResetKeepsAReboundRowsKeys() throws {
    shortcuts.set(.chord(.key("y", .command)), for: .newTerminal)
    shortcuts.set(.chord(.key("t", .command)), for: .fetch)
    model.reset(.newTerminal)
    XCTAssertNotNil(model.pending, "Reset asks to take ⌘T back from Fetch")
    model.pending = nil  // the alert's Cancel
    XCTAssertEqual(shortcuts.table.binding(for: .newTerminal), .chord(.key("y", .command)))
    XCTAssertEqual(shortcuts.table.binding(for: .fetch), .chord(.key("t", .command)))
  }

  func testResetTakesBackADefaultOtherKeysHoldByAsking() throws {
    shortcuts.set(.chord(.key("t", .command)), for: .fetch, unsetting: [.newTerminal])
    shortcuts.reset(.newTerminal)
    XCTAssertEqual(shortcuts.table.resolved[.newTerminal]?.displacedBy, .fetch)
    model.reset(.newTerminal)
    let pending = try XCTUnwrap(model.pending, "Reset asks to take ⌘T back from Fetch")
    XCTAssertEqual(pending.conflicts, [.fetch])
    model.confirm(pending)
    XCTAssertEqual(shortcuts.table.match(.key("t", .command)), ShortcutMatch(.newTerminal))
    XCTAssertNil(shortcuts.table.binding(for: .fetch))
  }

  func testTheSearchButtonCatchesKeys() {
    model.start(.search)
    model.record(.key("t", .command))
    XCTAssertEqual(model.searchChord, .key("t", .command))
    XCTAssertFalse(model.isRecording(.search))
  }
}

/// Every key equivalent in the app's real menu bar is a Workroom shortcut the registry knows, or a
/// standard macOS item's (#148). A menu item with keys of its own, outside both, would be keys the
/// recorder hands out without a conflict, and a terminal swallows.
@MainActor
final class MenuKeyEquivalentAuditTests: XCTestCase {
  func testEveryMenuKeyEquivalentIsTheRegistrysOrStandard() throws {
    let menu = try XCTUnwrap(NSApp.mainMenu, "the hosted app has a menu bar")
    var seen = 0
    var unknown: [String] = []
    func walk(_ menu: NSMenu, path: String) {
      menu.update()
      for item in menu.items {
        let here = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
        if let submenu = item.submenu { walk(submenu, path: here) }
        // Keys the recorder refuses anyway (no ⌘, ⌥ or ⌃, and no F-key) can't collide with one.
        guard let chord = Self.chord(of: item), chord.modifiers.hasPrimary || chord.isFunctionKey
        else { continue }
        seen += 1
        let known =
          Shortcuts.current.match(chord) != nil
          || StandardShortcut.all.contains { $0.chord == chord }
        if !known { unknown.append("\(here) \(chord.label)") }
      }
    }
    walk(menu, path: "")
    try XCTSkipIf(seen == 0, "the menu bar has no key equivalents yet in this host")
    XCTAssertEqual(unknown, [], "key equivalents outside the registry and the standard list")
  }

  /// The menu bar follows the registry by itself: a save re-runs the `Commands` body, with nothing
  /// else happening to. (That the key equivalent itself moves is `KeyboardShortcutsSettingsUITests`'
  /// to show: a hosted test's app is never active, and AppKit brings its menus up to date only then.)
  func testASaveReRunsTheMenuBar() async throws {
    try XCTSkipIf(NSApp.mainMenu?.items.isEmpty ?? true, "no menu bar in this host")
    defer { Shortcuts.shared.restoreDefaults() }
    let passes = WorkroomCommands.bodyPasses
    Shortcuts.shared.set(.chord(.key("j", [.control, .option])), for: .run)
    let deadline = Date().addingTimeInterval(5)
    while WorkroomCommands.bodyPasses == passes, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertGreaterThan(WorkroomCommands.bodyPasses, passes)
  }

  /// An item's key equivalent as a chord: AppKit writes a shifted letter as its capital.
  /// Nil for one held with Fn (🌐), such as Start Dictation: the recorder never takes Fn.
  private static func chord(of item: NSMenuItem) -> KeyChord? {
    guard let key = item.keyEquivalent.first, !item.keyEquivalentModifierMask.contains(.function)
    else { return nil }
    var modifiers = KeyModifiers(item.keyEquivalentModifierMask)
    if let code = KeyChord.namedKeyCode(forEquivalent: key) {
      return .named(code, modifiers)
    }
    let character = String(key)
    if character != character.lowercased() { modifiers.insert(.shift) }
    return .key(character, modifiers)
  }
}
