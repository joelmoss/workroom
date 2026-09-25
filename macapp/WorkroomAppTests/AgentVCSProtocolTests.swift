import XCTest

@testable import Workroom

final class AgentVCSProtocolTests: XCTestCase {
  func testAbsentContentIsDifferentFromMissingResult() throws {
    let content = try AgentVCSReply<String?>.decode(Data(#"{"version":1,"result":null}"#.utf8))
    XCTAssertNil(content)
    XCTAssertThrowsError(try AgentVCSReply<String?>.decode(Data(#"{"version":1}"#.utf8))) {
      XCTAssertTrue($0 is HostConnectionError)
    }
  }

  func testMalformedAndWrongVersionRepliesAreServiceFailures() {
    for text in [
      "not JSON", #"{"version":99,"result":"text"}"#, #"{"version":1,"result":[]}"#,
      #"{"version":1,"error":"Unknown"}"#, #"{"version":1,"error":{}}"#,
      #"{"version":1,"error":{"Unknown":"failure"}}"#,
    ] {
      XCTAssertThrowsError(try AgentVCSReply<String>.decode(Data(text.utf8))) {
        XCTAssertTrue($0 is HostConnectionError)
      }
    }
  }

  func testNativeErrorMeaningsSurviveTheWire() {
    let cases: [(String, VCSError)] = [
      (#"{"version":1,"error":"LockContention"}"#, .lockContention),
      (#"{"version":1,"error":"StaleSnapshot"}"#, .staleSnapshot),
      (#"{"version":1,"error":{"UnsupportedRepo":"gone"}}"#, .unsupportedRepo("gone")),
      (#"{"version":1,"error":{"PartialData":"retry"}}"#, .partialData("retry")),
      (#"{"version":1,"error":{"Io":"gone"}}"#, .io("gone")),
    ]
    for (text, expected) in cases {
      XCTAssertThrowsError(try AgentVCSReply<String>.decode(Data(text.utf8))) {
        XCTAssertEqual($0 as? VCSError, expected)
      }
    }
  }

  /// `launchFailed` means "the command never ran", and `CLIVCSWriter.classify` checks it before
  /// everything else. A transport failure does NOT know that: there is no cancel message in the
  /// protocol, so a cancelled or disconnected `git push` runs to completion host-side. Reporting it
  /// as `launchFailed` told the user nothing had happened and invited a retry that double-applies.
  func testTransportFailureIsNotReportedAsNeverHavingRun() {
    let lost = AgentCommandRunner.outcomeUnknown(HostConnectionError.connectionLost)
    XCTAssertEqual(lost.exitCode, CommandResult.outcomeUnknown)
    XCTAssertNotEqual(lost.exitCode, CommandResult.launchFailed)
    // `signaled` makes `exitCode` a signal number, and the sentinel isn't one. It used to be true,
    // which made this indistinguishable from a genuinely SIGTERMed git and sent it to `.other`.
    XCTAssertFalse(lost.signaled)
    // Not `timedOut`: that offers Retry, and nobody knows the outcome.
    XCTAssertFalse(lost.timedOut)
    // The existing error already says the right thing; it used to be discarded.
    XCTAssertTrue(lost.stderr.contains("may have completed"))

    let cancelled = AgentCommandRunner.outcomeUnknown(CancellationError())
    XCTAssertEqual(cancelled.exitCode, CommandResult.outcomeUnknown)
    XCTAssertTrue(cancelled.stderr.contains("may have completed"))

    // A request refused before it left this process genuinely never ran, and keeps the old value.
    XCTAssertEqual(
      AgentCommandRunner.neverRan("too large").exitCode, CommandResult.launchFailed)
  }

  /// A full request pool or agent lock contention used to read as `launchFailed`: "This workroom's
  /// folder is no longer there", and no Retry. Nothing ran and the workroom is fine, so both write
  /// taxonomies say what happened and offer the retry. The one reply error sent AFTER the command
  /// ran (the agent's reply-size guard) stays an unknown outcome.
  func testRefusalsBeforeRunningAreRetryableNotAMissingFolder() {
    let refusals = [
      AgentCommandRunner.replyRefusal(VCSError.lockContention),
      AgentCommandRunner.replyRefusal(
        VCSError.partialData("too many large VCS requests in flight")),
      AgentCommandRunner.refused(HostConnectionError.notDispatched.localizedDescription),
    ]
    for refused in refusals {
      XCTAssertEqual(refused.exitCode, CommandResult.refused)
      guard case .other(let reason) = CLIVCSWriter.classifyCommit(refused, tool: "git") else {
        return XCTFail("a refusal is a plain, retryable failure: \(refused)")
      }
      XCTAssertFalse(reason.isEmpty)
      guard case .other = CLIVCSWriter.classify(refused, action: .push, tool: "git") else {
        return XCTFail("a refused push is a plain, retryable failure: \(refused)")
      }
    }
    XCTAssertEqual(
      AgentCommandRunner.replyRefusal(VCSError.partialData("VCS reply exceeds 16 MiB")).exitCode,
      CommandResult.outcomeUnknown)
    // Fails safe: a message this side does not know is an unknown outcome, never a free retry.
    XCTAssertEqual(
      AgentCommandRunner.replyRefusal(VCSError.partialData("a reworded message")).exitCode,
      CommandResult.outcomeUnknown)
    XCTAssertEqual(
      AgentCommandRunner.replyRefusal(VCSError.unsupportedRepo("no dir")).exitCode,
      CommandResult.launchFailed)
  }

  /// The sentinel has to survive the whole way to the button, on both write taxonomies. This is the
  /// end-to-end form of the defect: an honest message with a Retry beside it is still a retry that
  /// double-applies the push.
  func testAnUnknownOutcomeNeverOffersARetryOfTheActionThatFailed() {
    let lost = AgentCommandRunner.outcomeUnknown(HostConnectionError.connectionLost)

    guard case .outcomeUnknown(let reason) = CLIVCSWriter.classify(lost, action: .push, tool: "git")
    else { return XCTFail("push did not classify as outcomeUnknown") }
    XCTAssertTrue(reason.contains("may have completed"))

    guard case .outcomeUnknown = CLIVCSWriter.classifyCommit(lost, tool: "git") else {
      return XCTFail("commit did not classify as outcomeUnknown")
    }

    // Fetch, never Push: idempotent, and the ahead/behind it returns is what resolves the unknown.
    XCTAssertEqual(
      VCSSyncPresenter.retryAction(for: .outcomeUnknown(reason), lastAction: .push), .fetch)
    XCTAssertEqual(
      VCSSyncPresenter.retryAction(for: .outcomeUnknown(reason), lastAction: .pull), .fetch)
    // A READ that lost contact wrote nothing, so tier [13b]'s `lastAction: nil` question must fall
    // through to its own "Try Again" re-read rather than being handed a network action.
    XCTAssertNil(VCSSyncPresenter.retryAction(for: .outcomeUnknown(reason), lastAction: nil))
    XCTAssertTrue(VCSSyncPresenter.readRetryIsWorthwhile(.outcomeUnknown(reason)))
    // The copy must carry the doubt. A user who reads "failed" repeats the action.
    XCTAssertTrue(VCSSyncPresenter.describe(.outcomeUnknown(reason)).contains("may have"))
    XCTAssertTrue(
      VCSSyncPresenter.describeCommit(.outcomeUnknown(reason)).contains("may have"))
    // The heading too: for VoiceOver it is the whole message.
    XCTAssertEqual(
      VCSSyncPresenter.commitFailureDialog(.outcomeUnknown(reason), mode: .commit).title,
      "Commit may not have completed")
    XCTAssertEqual(
      VCSSyncPresenter.commitFailureDialog(.other("x"), mode: .commit).title, "Commit failed")
  }

  /// The recovery rule is IDEMPOTENCE, not "never the failed verb". A lost `abortRebase` used to be
  /// answered with Fetch, which resolves nothing about a parked rebase — and `perform` allows an
  /// abort with no remote, so that click would have replaced the doubt with an unrelated `.noRemote`.
  func testOnlyNonIdempotentVerbsAreSwappedForFetch() {
    let reason = "An operation may have completed; refresh before retrying"
    for verb in [VCSRemoteAction.fetch, .abortRebase] {
      XCTAssertEqual(
        VCSSyncPresenter.retryAction(for: .outcomeUnknown(reason), lastAction: verb), verb,
        "\(verb.label) is idempotent and should be offered back")
    }
    for verb in [VCSRemoteAction.push, .pull] {
      XCTAssertEqual(
        VCSSyncPresenter.retryAction(for: .outcomeUnknown(reason), lastAction: verb), .fetch,
        "\(verb.label) is not idempotent and must not be offered back")
    }
  }

  /// The disk is not output, so it survives never hearing back. A pull whose reply was lost after git
  /// wrote `rebase-merge` leaves the same parked rebase a killed one does, and the same Abort fixes
  /// it — checking the sentinel first discarded the only positive evidence available.
  func testALostPullStillFindsAParkedRebaseOnDisk() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wr-rebase-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("rebase-merge"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let lost = AgentCommandRunner.outcomeUnknown(HostConnectionError.connectionLost)
    guard
      case .rebaseInProgress = CLIVCSWriter.classify(
        lost, action: .pull, tool: "git", gitDir: dir)
    else { return XCTFail("the parked rebase was discarded") }

    // Only for a pull, and only when the directory is actually there.
    guard
      case .outcomeUnknown = CLIVCSWriter.classify(
        lost, action: .push, tool: "git", gitDir: dir)
    else { return XCTFail("a push must not be upgraded to rebaseInProgress") }
  }

  /// `describe`'s own rule — never "failed" over a state that may have succeeded — has to hold for the
  /// heading too. For a VoiceOver user the heading IS the whole message.
  func testTheHeadingDoesNotAssertAVerdictItDoesNotHave() {
    let unknown = VCSRemoteFailure.outcomeUnknown("dropped")
    XCTAssertEqual(
      VCSSyncPresenter.headline(unknown, action: .push), "Push may not have completed")
    XCTAssertFalse(VCSSyncPresenter.headline(unknown, action: .push).contains("failed"))
    // Every other failure keeps the plain verdict.
    XCTAssertEqual(VCSSyncPresenter.headline(.noRemote, action: .push), "Push failed")
  }

  /// The remedy is rendered for push, pull, fetch, an abort AND for read failures (tier [13b] routes
  /// a read through the same `describe`/`remedy` pair), so naming one verb was wrong advice for the
  /// rest — "push again" to someone whose rebase may be half-applied most of all.
  func testTheUnknownOutcomeRemedyNamesNoVerb() throws {
    let remedy = try XCTUnwrap(VCSSyncPresenter.remedy(for: .outcomeUnknown("dropped")))
    for verb in ["push again", "pull again", "the push landed"] {
      XCTAssertFalse(remedy.lowercased().contains(verb), "remedy assumes a verb: \(verb)")
    }
  }

  /// The sentinel is a claim about the round trip, so it must beat every output-shaped check — a
  /// transport message that happened to contain git's prose must not be classified as git's failure.
  func testTheUnknownSentinelOutranksOutputMatching() {
    let misleading = CommandResult(
      stdout: "",
      stderr: "Updates were rejected. Host key verification failed. fatal: Cannot autostash",
      exitCode: CommandResult.outcomeUnknown, timedOut: false)
    guard case .outcomeUnknown = CLIVCSWriter.classify(misleading, action: .push, tool: "git")
    else {
      return XCTFail("output matching won over the sentinel")
    }
  }

  /// Both paths must hand the child the SAME environment. Forwarding only `PATH` let the child
  /// inherit the rest from a daemon "negotiated with, never replaced", so an agent-routed commit
  /// could be authored under the identity of whichever app launch first spawned it.
  func testAgentAndNativeSendTheSameChildEnvironment() {
    for network in [false, true] {
      let env = StatusCommandRunner.childEnvironment(network: network)
      // The subprocess baseline every consumer's stderr classification depends on.
      XCTAssertEqual(env["LC_ALL"], "C")
      XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
      XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
      XCTAssertNil(env["GIT_EXTERNAL_DIFF"])
      XCTAssertEqual(env["PATH"], ShellEnvironment.path())
      // Identity/config carriers reach the child on EVERY command, not just network ones.
      for key in ["HOME", "USER"] where ProcessInfo.processInfo.environment[key] != nil {
        XCTAssertEqual(env[key], ProcessInfo.processInfo.environment[key])
      }
    }
    // The fail-fast ssh invariant is still network-only.
    XCTAssertNil(StatusCommandRunner.childEnvironment(network: false)["SSH_ASKPASS_REQUIRE"])
    XCTAssertEqual(
      StatusCommandRunner.childEnvironment(network: true)["SSH_ASKPASS_REQUIRE"], "never")
  }

  /// These OUTRANK the working directory, so an inherited one silently redirects a command aimed at
  /// one repository into another — a commit requested in workroom A landing in repo B, reported as
  /// success. Every caller addresses a repository by `directory`, so inheriting them is only ever
  /// wrong. Asserted for both paths because they now share one environment: sending the app's whole
  /// environment to the agent would otherwise have carried these across too.
  func testRepositoryOverridesNeverReachTheChild() {
    let keys = [
      "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
      "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ]
    // Not `setenv`: see `childEnvironment`'s `inherited` — mutating this process's environment
    // crashes a later libghostty surface in the same test host.
    var inherited = ProcessInfo.processInfo.environment
    for key in keys { inherited[key] = "/tmp/some-other-repo" }
    for network in [false, true] {
      let env = StatusCommandRunner.childEnvironment(network: network, inherited: inherited)
      for key in keys {
        XCTAssertNil(env[key], "\(key) reached the child (network: \(network))")
      }
    }
  }

  /// `AgentVCSConnection.execVersion` and `AgentExecRequest.version` are the same number declared
  /// twice — the capability the client checks, and the version it actually sends. Nothing in the
  /// compiler ties them together, and a doc comment claiming they "cannot drift" was simply wrong.
  func testTheAdvertisedExecVersionIsTheOneActuallySent() {
    let request = AgentExecRequest(
      executable: "git", args: [], dir: "/tmp", timeoutMs: 1000, stdin: nil, env: [:])
    XCTAssertEqual(request.version, 1)
    XCTAssertEqual(request.kind, "exec")
  }

  /// Nothing from the Mac's environment reaches a remote host's exec request (#229): its `HOME` and
  /// `PATH` name nothing there, and its `SSH_AUTH_SOCK` is a Mac credential. Checked on the encoded
  /// wire bytes, which are what crosses.
  func testARemoteExecRequestCarriesNothingFromTheMacsEnvironment() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    for network in [false, true] {
      let local = AgentCommandRunner.request(
        "git", ["push"], in: "/r", timeout: 1, stdin: nil, network: network, host: .local)
      // The control: locally the Mac's environment is the point.
      XCTAssertNotNil(local.env["PATH"])
      let localWire = String(decoding: try encoder.encode(local), as: UTF8.self)
      // An agent that predates the field rejects a request carrying it, and a local one may.
      XCTAssertFalse(localWire.contains("host_environment"), localWire)

      let remote = AgentCommandRunner.request(
        "git", ["push"], in: "/r", timeout: 1, stdin: nil, network: network,
        host: .remote(UUID()))
      XCTAssertEqual(remote.env, StatusCommandRunner.remoteEnvironment)
      let wire = String(decoding: try encoder.encode(remote), as: UTF8.self)
      for key in ["HOME", "PATH", "SSH_AUTH_SOCK", "USER", "GIT_SSH_COMMAND"] {
        XCTAssertFalse(wire.contains("\"\(key)\""), "\(key) crossed (network: \(network)): \(wire)")
      }
      XCTAssertTrue(wire.contains("\"host_environment\":true"), wire)
    }
    // The jj barrier the agent takes for a remote command must never be asked of a local agent,
    // whose caller already holds it for the whole operation: taken again, it would deadlock.
    let local = AgentCommandRunner.request(
      "jj", ["commit"], in: "/r", timeout: 1, stdin: nil, network: false, host: .local,
      barrierRoot: "/r")
    XCTAssertFalse(
      String(decoding: try encoder.encode(local), as: UTF8.self).contains("barrier_root"))
    let remote = AgentCommandRunner.request(
      "jj", ["commit"], in: "/r", timeout: 1, stdin: nil, network: false, host: .remote(UUID()),
      barrierRoot: "/r")
    XCTAssertTrue(
      String(decoding: try encoder.encode(remote), as: UTF8.self).contains(
        "\"barrier_root\":\"\\/r\""))
    // Nor for a network command, whose detached git helpers would inherit it.
    let fetch = AgentCommandRunner.request(
      "jj", ["git", "fetch"], in: "/r", timeout: 1, stdin: nil, network: true,
      host: .remote(UUID()), barrierRoot: "/r")
    XCTAssertNil(fetch.barrierRoot)
  }

  // MARK: File service (#211)

  /// The client's five version constants are the agent's `PROTOCOL_VERSION`, `MIN_VCS_VERSION`,
  /// `MIN_FILE_VERSION`, `MIN_STATUS_VERSION` and `MIN_FORWARD_VERSION` declared a second time, in a
  /// second language. Checked against the shipped binary's own report so a bump on one side alone
  /// fails here rather than as a dead File, Status or Forward service.
  func testTheClientsProtocolConstantsMatchTheShippedAgent() throws {
    XCTAssertEqual(AgentControlClient.protocolVersion, 6)
    XCTAssertEqual(AgentControlClient.minVCSVersion, 2)
    XCTAssertEqual(AgentControlClient.minFileVersion, 3)
    XCTAssertEqual(AgentControlClient.minStatusVersion, 4)
    XCTAssertEqual(AgentControlClient.minForwardVersion, 5)
    let process = Process()
    process.executableURL = try AgentHarness.binaryURL()
    process.arguments = ["protocol"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    XCTAssertTrue(
      output.contains("protocol \(AgentControlClient.protocolVersion) "),
      "the agent reports a different protocol version than this client speaks: \(output)")
    // The minimums too, from the agent's own report rather than the literals above alone: a bump
    // on the agent side would otherwise leave this client sending envelopes an agent drops.
    let tokens = output.split(separator: "\n").first.map { $0.split(separator: " ") } ?? []
    func reported(_ name: String) -> UInt16? {
      guard let index = tokens.firstIndex(of: Substring(name)), index + 1 < tokens.count else {
        return nil
      }
      return UInt16(tokens[index + 1])
    }
    XCTAssertEqual(reported("min-vcs"), AgentControlClient.minVCSVersion, output)
    XCTAssertEqual(reported("min-file"), AgentControlClient.minFileVersion, output)
    XCTAssertEqual(reported("min-status"), AgentControlClient.minStatusVersion, output)
    XCTAssertEqual(reported("min-forward"), AgentControlClient.minForwardVersion, output)
  }

  /// Every failure the agent's `FileError` can produce keeps its meaning across the wire.
  func testFileErrorsSurviveTheWire() {
    let cases: [(String, Error)] = [
      (
        #"{"Refused":"outside the repository root"}"#,
        FileServiceError.refused("outside the repository root")
      ),
      (#"{"TooLarge":"9 bytes exceeds 8"}"#, FileServiceError.tooLarge),
      (#"{"NotFound":"gone"}"#, FileServiceError.notFound("gone")),
      (#"{"ListingTruncated":"cap"}"#, FileServiceError.listingTruncated),
      (#"{"Unsupported":"bad"}"#, FileServiceError.failed("bad")),
      (#"{"Io":"disk"}"#, FileServiceError.failed("disk")),
      (#"{"Busy":"full"}"#, FileServiceError.failed("full")),
      (#"{"LockContention":"held"}"#, VCSError.lockContention),
      (#"{"Registration":"needed"}"#, RepositoryRoutingError.registrationRequired),
    ]
    for (failure, expected) in cases {
      let text = #"{"version":1,"error":"# + failure + "}"
      XCTAssertThrowsError(try AgentFileReply<String>.decode(Data(text.utf8)), failure) {
        XCTAssertEqual("\($0)", "\(expected)", failure)
      }
    }
    for text in [
      "not JSON", #"{"version":2,"result":"x"}"#, #"{"version":1,"error":{"Mystery":"?"}}"#,
      #"{"version":1,"error":{}}"#, #"{"version":1}"#,
    ] {
      XCTAssertThrowsError(try AgentFileReply<String>.decode(Data(text.utf8)), text) {
        XCTAssertTrue($0 is HostConnectionError, "\($0)")
      }
    }
  }

  /// The agent's `Request` is `deny_unknown_fields`, so a stray or misspelled key is a refused
  /// request, not an ignored one. Pinned to the exact key sets the four methods send.
  func testFileRequestsEncodeExactlyTheFieldsTheAgentAccepts() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    func keys(_ request: AgentFileRequest) throws -> Set<String> {
      let object = try JSONSerialization.jsonObject(with: try encoder.encode(request))
      return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }
    XCTAssertEqual(
      try keys(AgentFileRequest(method: "list", backend: "git", root: "/r", sharedRoot: "/s")),
      ["version", "method", "backend", "root", "shared_root"])
    XCTAssertEqual(
      try keys(
        AgentFileRequest(
          method: "read", root: "/r", path: "a", symlinks: "refuse", maxBytes: 1)),
      ["version", "method", "root", "path", "symlinks", "max_bytes"])
    XCTAssertEqual(
      try keys(AgentFileRequest(method: "watch", root: "/r", subscription: 7)),
      ["version", "method", "root", "subscription"])
    XCTAssertEqual(
      try keys(AgentFileRequest(method: "unwatch", subscription: 7)),
      ["version", "method", "subscription"])
    XCTAssertEqual(FileSymlinkPolicy.followWithinRoot.rawValue, "follow_within_root")
    XCTAssertEqual(FileSymlinkPolicy.refuse.rawValue, "refuse")
  }

  /// Events are unsolicited and versioned by nothing but their `event` tag, so an unknown kind must
  /// be dropped, not fail the connection of an older client.
  func testFileEventsDecodeAndUnknownKindsAreDropped() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    func model(_ json: String) throws -> FileWatchEvent? {
      try decoder.decode(AgentFileEvent.self, from: Data(json.utf8)).model
    }
    XCTAssertEqual(
      try model(#"{"event":"changed","subscription":7,"paths":["/a","/b"],"overflow":true}"#),
      .changed(paths: ["/a", "/b"], overflow: true))
    XCTAssertEqual(
      try model(#"{"event":"ended","subscription":7,"reason":"root_removed"}"#),
      .ended(reason: "root_removed"))
    XCTAssertNil(try model(#"{"event":"from-the-future","subscription":7}"#))
  }
}
