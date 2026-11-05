import WorkroomDomain
import XCTest

@testable import Workroom

/// How a host option's choices read and what each saves (#575): the same rules in Settings and
/// Project Settings, so Inherit and Provider default never read as two ways to the same thing.
final class HostOptionChoicesTests: XCTestCase {
  typealias Choices = HostOptionChoices<Int>

  /// Value: protects=the provider's default reads "(default)" and, at Settings, saves nothing;
  /// fails_when=it is listed twice or saved as a value; why_new=new rules; seam=none;
  /// no_claim=the picker's rendering
  func testAtSettingsTheDefaultIsItsOwnRowAndSavesNothing() {
    let choices = Choices(providerDefault: 2, below: nil)
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertNil(choices.mark(for: 4))
    XCTAssertEqual(choices.stored(for: 2), .inherit)
    XCTAssertEqual(choices.stored(for: 4), .value(4))
    XCTAssertFalse(choices.needsProviderDefaultRow(among: [1, 2, 4]))
  }

  /// A project that Settings leaves alone gets the provider's default: one "(default)" row, which
  /// saves nothing, and no second Provider default choice.
  func testWithNothingInSettingsTheDefaultRowFollowsSettings() {
    let choices = Choices(providerDefault: 2, below: .init(value: nil, source: nil))
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertEqual(choices.stored(for: 2), .inherit)
    XCTAssertEqual(choices.selection(of: .providerDefault), .inherit)
  }

  /// Settings' own value reads "(app)" and saves nothing, so the project follows Settings; the
  /// provider's default is then a real choice of its own.
  func testSettingsValueReadsAppAndTheDefaultIsAChoice() {
    let choices = Choices(providerDefault: 2, below: .init(value: 4, source: .settings))
    XCTAssertEqual(choices.mark(for: 4), "app")
    XCTAssertEqual(choices.stored(for: 4), .inherit)
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertEqual(choices.stored(for: 2), .providerDefault)
    XCTAssertEqual(choices.selection(of: .providerDefault), .providerDefault)
    XCTAssertEqual(choices.selection(of: .value(4)), .inherit)
  }

  /// A Settings value that is also the provider's default reads only "(default)".
  func testASettingsValueThatIsTheDefaultReadsOnlyDefault() {
    let choices = Choices(providerDefault: 2, below: .init(value: 2, source: .settings))
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertEqual(choices.stored(for: 2), .inherit)
  }

  /// A default the provider doesn't say (exe.dev memory) keeps a Provider default row: saving
  /// nothing when nothing is inherited, and Provider default when Settings names a value.
  func testAnUnknownDefaultKeepsItsOwnRow() {
    XCTAssertTrue(Choices(providerDefault: nil, below: nil).needsProviderDefaultRow(among: [4]))
    XCTAssertEqual(
      Choices(providerDefault: nil, below: .init(value: nil, source: nil)).providerDefaultStored,
      .inherit)
    let choices = Choices(providerDefault: nil, below: .init(value: 4, source: .project))
    XCTAssertEqual(choices.providerDefaultStored, .providerDefault)
    XCTAssertEqual(choices.mark(for: 4), "project")
  }
}
