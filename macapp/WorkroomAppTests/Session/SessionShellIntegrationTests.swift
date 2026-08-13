import XCTest

@testable import WorkroomSessionProtocol

final class SessionShellIntegrationTests: XCTestCase {
  func testZshSetsZDOTDIR() {
    let invocation = SessionShellIntegration.invocation(
      command: "",
      shell: "/bin/zsh",
      resourcesDirectory: "/res",
      environment: [SessionEnvironmentEntry(key: "ZDOTDIR", value: "/old")])
    XCTAssertEqual(invocation.executable, "/bin/zsh")
    XCTAssertEqual(value("ZDOTDIR", in: invocation), "/res/shell-integration/zsh")
    XCTAssertEqual(value("GHOSTTY_ZSH_ZDOTDIR", in: invocation), "/old")
  }

  func testBashInjectsPosixAndENV() {
    let invocation = SessionShellIntegration.invocation(
      command: "",
      shell: "/bin/bash",
      resourcesDirectory: "/res",
      environment: [SessionEnvironmentEntry(key: "HOME", value: "/Users/dev")])
    XCTAssertTrue(invocation.arguments.contains("--posix"))
    XCTAssertEqual(value("ENV", in: invocation), "/res/shell-integration/bash/ghostty.bash")
    XCTAssertEqual(value("GHOSTTY_BASH_INJECT", in: invocation), "1")
    XCTAssertEqual(value("HISTFILE", in: invocation), "/Users/dev/.bash_history")
  }

  func testStartupCommandUsesPosixExec() {
    let invocation = SessionShellIntegration.invocation(
      command: "true",
      shell: "/bin/zsh",
      resourcesDirectory: "",
      environment: [])
    XCTAssertEqual(invocation.executable, "/bin/sh")
    XCTAssertEqual(invocation.arguments, ["/bin/sh", "-c", "exec true"])
  }

  func testFishPrefixesXDGDataDirs() {
    let invocation = SessionShellIntegration.invocation(
      command: "",
      shell: "/opt/homebrew/bin/fish",
      resourcesDirectory: "/res",
      environment: [SessionEnvironmentEntry(key: "XDG_DATA_DIRS", value: "/usr/share")])
    XCTAssertEqual(
      value("XDG_DATA_DIRS", in: invocation),
      "/res/shell-integration:/usr/share")
  }

  private func value(_ key: String, in invocation: SessionShellInvocation) -> String? {
    invocation.environment.first { $0.key == key }?.value
  }
}
