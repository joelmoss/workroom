import DaemonConnection
import XCTest

/// Reads the terminal API's `events.subscribe` replies (ADR 0079) the way the app keeps them: a
/// `session.input` names who typed into which session, and every other event is passed over.
final class TerminalInputWireTests: XCTestCase {
  private let session = UUID(uuidString: "c0ffee00-1111-4222-8333-44445555beef")!
  private let sender = UUID(uuidString: "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11")!

  private func reply(_ json: String) throws -> TerminalInputEvent.Reply {
    try TerminalInputEvent.decode(reply: Data(json.utf8))
  }

  /// The example `events.subscribe`'s schema gives for `session.input`, in a live reply.
  func testASendFromAPaneNamesItsSender() throws {
    let decoded = try reply(
      """
      {"revision":1,"more":true,"result":{"event":"session.input","boot":"b","revision":45,\
      "session":"c0ffee00-1111-4222-8333-44445555beef",\
      "scope":{"kind":"workroom","id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e"},\
      "sender":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11","bytes":14}}
      """)
    XCTAssertEqual(decoded, .event(.input(session: session, sender: sender), more: true))
  }

  /// A send from no pane (a script outside Workroom) has a null sender.
  func testASendFromNoPaneHasNoSender() throws {
    let decoded = try reply(
      """
      {"revision":1,"more":true,"result":{"event":"session.input","boot":"b","revision":46,\
      "session":"c0ffee00-1111-4222-8333-44445555beef","scope":null,"sender":null,"bytes":3}}
      """)
    XCTAssertEqual(decoded, .event(.input(session: session, sender: nil), more: true))
  }

  /// A snapshot's sessions, its end, a filtered stream's place and an event this build doesn't
  /// know are replies all the same, with nothing in them the app reads.
  func testEveryOtherEventIsAReplyWithNothingToRead() throws {
    let id = session.uuidString.lowercased()
    for event in [
      #"{"event":"session","boot":"b","revision":3,"session":"\#(id)"}"#,
      #"{"event":"snapshot-complete","boot":"b","revision":3,"sessions":[]}"#,
      #"{"event":"place","boot":"b","revision":90}"#,
      #"{"event":"session.someday","boot":"b","revision":91}"#,
    ] {
      XCTAssertEqual(
        try reply(#"{"revision":1,"more":true,"result":\#(event)}"#), .event(nil, more: true),
        event)
    }
  }

  /// A refusal ends the stream with its error.
  func testARefusalCarriesItsKindAndMessage() throws {
    let decoded = try reply(
      #"{"revision":1,"more":false,"error":{"kind":"Busy","message":"too many subscriptions"}}"#)
    XCTAssertEqual(decoded, .refused(kind: "Busy", message: "too many subscriptions"))
  }

  func testAPayloadThatIsNoReplyThrows() {
    XCTAssertThrowsError(try reply("not json"))
    XCTAssertThrowsError(try reply(#"{"revision":1,"more":true}"#))
  }

  /// Ending a subscription names it by the stream it was asked on.
  func testTheUnsubscribeRequestNamesTheStream() throws {
    let request = try XCTUnwrap(
      JSONSerialization.jsonObject(with: TerminalInputEvent.unsubscribeRequest(stream: 42))
        as? [String: Any])
    XCTAssertEqual(request["method"] as? String, "events.unsubscribe")
    XCTAssertEqual((request["params"] as? [String: Any])?["stream"] as? Int, 42)
  }

  /// The daemon's answer to it is a reply like any other, with no event in it.
  func testTheUnsubscribeReplyIsAReplyWithNothingToRead() throws {
    XCTAssertEqual(
      try reply(#"{"revision":1,"more":false,"result":{"stream":42,"ended":true}}"#),
      .event(nil, more: false))
  }

  /// Every session's typing, creations and ends, whatever scope the daemon finds the app in, and
  /// nothing replayed.
  func testTheSubscribeRequestAsksForEverySessionsTypingAndNoReplay() throws {
    let request = try XCTUnwrap(
      JSONSerialization.jsonObject(with: TerminalInputEvent.subscribeRequest) as? [String: Any])
    XCTAssertEqual(request["method"] as? String, "events.subscribe")
    let params = try XCTUnwrap(request["params"] as? [String: Any])
    XCTAssertEqual(params["all"] as? Bool, true)
    XCTAssertEqual(
      params["types"] as? [String], ["session.input", "session.created", "session.ended"])
    XCTAssertNil(params["since"])
  }

  /// A `session.created` that `workroom new` made (#693) asks the app to show it: who asked, the
  /// split, the Mac, and the session's workroom, label and run.
  func testANewSessionAsksTheAppToShowIt() throws {
    let decoded = try reply(
      """
      {"revision":1,"more":true,"result":{"event":"session.created","boot":"b","revision":47,\
      "session":"c0ffee00-1111-4222-8333-44445555beef",\
      "scope":{"kind":"workroom","id":"standalone:4C0F5F2E-2B49-4C4D-9C1E-6A1B2B3C0D4E"},\
      "label":"dev server","title":null,"run":true,"cwd":"/w","coding_agent":null,\
      "run_state":null,"exit_code":null,"clients":[],\
      "opened":{"by":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11","split":"down",\
      "hostname":"joels-macbook.local"}}}
      """)
    XCTAssertEqual(
      decoded,
      .event(
        .opened(
          TerminalOpenRequest(
            session: session, by: sender, split: .down, hostname: "joels-macbook.local",
            workroom: "standalone:4C0F5F2E-2B49-4C4D-9C1E-6A1B2B3C0D4E", label: "dev server",
            run: true)),
        more: true))
  }

  /// From no pane, nobody asked and no Mac shows it; a split this build doesn't know is a tab.
  func testANewSessionFromNoPaneNamesNoCallerAndNoMac() throws {
    let decoded = try reply(
      """
      {"revision":1,"more":true,"result":{"event":"session.created","boot":"b","revision":48,\
      "session":"c0ffee00-1111-4222-8333-44445555beef","scope":null,"label":null,"run":false,\
      "opened":{"by":null,"split":"diagonal","hostname":null}}}
      """)
    XCTAssertEqual(
      decoded,
      .event(
        .opened(
          TerminalOpenRequest(
            session: session, by: nil, split: nil, hostname: nil, workroom: nil, label: nil,
            run: false)),
        more: true))
  }

  /// The app's own sessions say nothing of `opened`, and a shell that exits keeps its pane: only
  /// a `session.ended` that `workroom close` caused closes one.
  func testOnlyANewOpensAndOnlyACloseCloses() throws {
    let id = session.uuidString.lowercased()
    for (event, expected) in [
      (
        #"{"event":"session.created","boot":"b","revision":4,"session":"\#(id)","opened":null}"#,
        nil
      ),
      (#"{"event":"session.created","boot":"b","revision":5,"session":"\#(id)"}"#, nil),
      (
        #"{"event":"session.ended","boot":"b","revision":6,"session":"\#(id)","closed":false}"#,
        nil
      ),
      (#"{"event":"session.ended","boot":"b","revision":7,"session":"\#(id)"}"#, nil),
      (
        #"{"event":"session.ended","boot":"b","revision":8,"session":"\#(id)","closed":true}"#,
        TerminalInputEvent.closed(session: session)
      ),
    ] {
      XCTAssertEqual(
        try reply(#"{"revision":1,"more":true,"result":\#(event)}"#),
        .event(expected, more: true), event)
    }
  }
}
