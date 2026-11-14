import Foundation
import HostDrivers

// Debug only, as `UITestFixture` is (ADR 0022): a Release build ships no stand-in for Railway.
#if DEBUG

  /// Railway stubbed at HTTP (#627), for the setup sheet's unit tests and the UI test fixture: it
  /// answers the OAuth token endpoint and the GraphQL queries the sheet makes (`me { workspaces }`,
  /// a workspace's `customer { isTrialing }`), and stands in for the browser, approving on
  /// Railway's consent page by following the authorization request's redirect to the loopback
  /// listener, as a real browser does. Nothing reaches Railway or opens a browser.
  final class RailwayStub: RailwayHTTPTransport, @unchecked Sendable {
    static let refreshToken = "rt-stub"

    /// A refresh token store in memory, in place of the Keychain.
    final class MemoryStore: RailwayTokenStore, @unchecked Sendable {
      private let lock = NSLock()
      private var value: String?
      init(_ value: String? = nil) { self.value = value }
      func read() throws -> String? { lock.withLock { value } }
      func write(_ token: String) throws { lock.withLock { value = token } }
      func delete() throws { lock.withLock { value = nil } }
    }

    private let lock = NSLock()
    private var _workspaces: [RailwayWorkspace]
    private var _trialing: [String: Bool] = [:]
    private var _trialUnreadable: Set<String> = []
    private var _refreshRefused = false
    private var _declines = false
    private var _browserWaits = false
    private var _browserOpens = 0
    private var _tokenExchanges = 0
    private var _projects: [String: [RailwayProject]] = [:]
    private var _createdProjects: [String] = []
    private var _createdEnvironments: [String] = []

    init(workspaces: [RailwayWorkspace]) { _workspaces = workspaces }

    private func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }

    /// The workspaces granted on the consent page.
    var workspaces: [RailwayWorkspace] {
      get { locked { _workspaces } }
      set { locked { _workspaces = newValue } }
    }
    /// Each workspace's `customer.isTrialing`; absent is false.
    var trialing: [String: Bool] {
      get { locked { _trialing } }
      set { locked { _trialing = newValue } }
    }
    /// Workspaces whose customer the token may not read.
    var trialUnreadable: Set<String> {
      get { locked { _trialUnreadable } }
      set { locked { _trialUnreadable = newValue } }
    }
    /// Railway refuses every refresh token (`invalid_grant`).
    var refreshRefused: Bool {
      get { locked { _refreshRefused } }
      set { locked { _refreshRefused = newValue } }
    }
    /// The user declines on the consent page.
    var declines: Bool {
      get { locked { _declines } }
      set { locked { _declines = newValue } }
    }
    /// The user never answers the consent page.
    var browserWaits: Bool {
      get { locked { _browserWaits } }
      set { locked { _browserWaits = newValue } }
    }
    /// Each workspace's projects, which a `projectCreate` adds to.
    var projects: [String: [RailwayProject]] {
      get { locked { _projects } }
      set { locked { _projects = newValue } }
    }
    /// The projects made, as `<name> in <workspace>`.
    var createdProjects: [String] { locked { _createdProjects } }
    /// The environments made, as `<name> in <project>`.
    var createdEnvironments: [String] { locked { _createdEnvironments } }
    var browserOpens: Int { locked { _browserOpens } }
    var tokenExchanges: Int { locked { _tokenExchanges } }

    /// A Railway account over this stub, keeping its refresh token in `store`.
    func account(store: any RailwayTokenStore) -> RailwayAccount {
      RailwayAccount(
        transport: self, store: store, lock: InProcessRefreshLock(), clientID: "rlwy_oaci_stub",
        open: { [weak self] url in await self?.approve(url) })
    }

    /// The browser on Railway's consent page: approves (or declines) by following the redirect.
    private func approve(_ url: URL) async {
      let (declines, waits) = locked {
        _browserOpens += 1
        return (_declines, _browserWaits)
      }
      guard !waits else { return }
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
      guard var callback = value("redirect_uri").flatMap(URLComponents.init(string:)) else {
        return
      }
      callback.queryItems = [
        declines
          ? URLQueryItem(name: "error", value: "access_denied")
          : URLQueryItem(name: "code", value: "code-stub"),
        URLQueryItem(name: "state", value: value("state")),
      ]
      guard let target = callback.url else { return }
      _ = try? await URLSession(configuration: .ephemeral).data(from: target)
    }

    func send(_ request: URLRequest) async throws -> RailwayHTTPResponse {
      if request.url == RailwayOAuthClient.tokenEndpoint { return token(request) }
      let body =
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
      let query = body?["query"] as? String ?? ""
      if query.contains("me { workspaces") {
        let workspaces = self.workspaces.map { workspace -> [String: Any] in
          ["id": workspace.id, "name": workspace.name, "plan": Self.raw(workspace.plan)]
        }
        return Self.json(["data": ["me": ["workspaces": workspaces]]])
      }
      if query.contains("isTrialing") {
        let id = (body?["variables"] as? [String: Any])?["id"] as? String ?? ""
        if trialUnreadable.contains(id) {
          return Self.json(["data": NSNull(), "errors": [["message": "Not Authorized"]]])
        }
        return Self.json([
          "data": ["workspace": ["customer": ["isTrialing": trialing[id] ?? false]]]
        ])
      }
      if let placed = place(query, variables: body?["variables"] as? [String: Any] ?? [:]) {
        return Self.json(["data": placed])
      }
      return Self.json(["errors": [["message": "RailwayStub has no answer for \(query)"]]])
    }

    /// The setup's placement calls (#629): a workspace's projects, making a project or an
    /// environment, and an environment's sandboxes, of which a stub environment has none.
    private func place(_ query: String, variables: [String: Any]) -> [String: Any]? {
      let input = variables["input"] as? [String: Any] ?? [:]
      if query.contains("projectCreate(") {
        let workspace = input["workspaceId"] as? String ?? ""
        let name = input["name"] as? String ?? ""
        return locked {
          _createdProjects.append("\(name) in \(workspace)")
          let id = "prj-stub-\(_createdProjects.count)"
          _projects[workspace, default: []].append(RailwayProject(id: id, name: name))
          return ["projectCreate": ["id": id]]
        }
      }
      if query.contains("environmentCreate(") {
        let name = input["name"] as? String ?? ""
        let project = input["projectId"] as? String ?? ""
        return locked {
          _createdEnvironments.append("\(name) in \(project)")
          return ["environmentCreate": ["id": "env-stub-\(_createdEnvironments.count)"]]
        }
      }
      if query.contains("projects(") {
        let workspace = variables["workspaceId"] as? String ?? ""
        let edges = (projects[workspace] ?? []).map { ["node": ["id": $0.id, "name": $0.name]] }
        return ["projects": ["edges": edges]]
      }
      if query.contains("sandboxes(") {
        return ["sandboxes": ["edges": [Any](), "pageInfo": ["hasNextPage": false]]]
      }
      return nil
    }

    private func token(_ request: URLRequest) -> RailwayHTTPResponse {
      let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      if form.contains("grant_type=authorization_code") {
        locked { _tokenExchanges += 1 }
      } else if refreshRefused {
        return Self.json(["error": "invalid_grant"], status: 400)
      }
      return Self.json([
        "access_token": "at-stub", "refresh_token": Self.refreshToken, "expires_in": 3600,
        "token_type": "Bearer",
      ])
    }

    private static func raw(_ plan: RailwayPlan) -> String {
      switch plan {
      case .free: "FREE"
      case .hobby: "HOBBY"
      case .pro: "PRO"
      case .other(let raw): raw
      }
    }

    private static func json(_ object: Any, status: Int = 200) -> RailwayHTTPResponse {
      RailwayHTTPResponse(
        status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
  }

#endif
