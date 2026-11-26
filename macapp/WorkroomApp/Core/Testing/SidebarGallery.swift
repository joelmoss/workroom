#if DEBUG
  import AppKit
  import DaemonConnection
  import Foundation
  import WorkroomDomain

  /// `-WorkroomUITestSidebarGallery 1`, with `-WorkroomUITestFixture 1`: the sidebar showing every
  /// kind of row in every state its marks can take, for looking at, not for asserting on
  /// (`make app-sidebar-gallery`). Projects, roots, workrooms, a create's own row and terminal rows
  /// in the Projects section; every workroom tab they open, standalone terminals and groups among
  /// them, in the Open section (#819), its rows unfolded where the tree's are expanded.
  ///
  /// Everything is seeded as model state: no program runs, no run command starts and no host is
  /// reached. Only the selected workroom's terminal mounts, and it is a plain idle one. The table
  /// below is the gallery: each entry says what a row shows, and `SidebarGalleryTests` checks that
  /// each one reached the row's model.
  enum SidebarGallery {
    static var isOn: Bool {
      UITestFixture.fixtureFlag
        && UserDefaults.standard.bool(forKey: "WorkroomUITestSidebarGallery")
    }

    // MARK: The table

    /// The one mark a terminal's program shows; the stale ones on a host whose link is down.
    enum Mark: Equatable {
      case idle, busy, waiting, waitingStale, failed, done, doneStale

      var isStale: Bool { self == .waitingStale || self == .doneStale }
    }

    /// One terminal: its live title, its mark, the tool its foreground is recognised as (a logo in
    /// place of its glyph), the name a user gave it, and whether it has an unread notification.
    struct Terminal {
      var title: String
      var mark: Mark = .idle
      var tool: String? = nil
      var name: String? = nil
      var unread = false
    }

    enum Run { case running, stopping }
    enum Create { case running, failed }

    /// A root's or workroom's terminals and the rest of what its row shows.
    struct Target {
      var terminals: [Terminal] = [Terminal(title: "zsh")]
      var run: Run? = nil
      var unread = false
      /// Its terminals listed under it (needs two or more).
      var expanded = false
      /// Uncommitted changes: the glyph's orange tint.
      var dirty = false
      var create: Create? = nil

      /// What its row's marks should read (`AppStore.sidebarActivity(of:)`).
      var waiting: Int { terminals.count { $0.mark == .waiting || $0.mark == .waitingStale } }
      /// Disconnected only when every waiting terminal is.
      var waitingStale: Bool {
        waiting > 0 && terminals.allSatisfy { $0.mark != .waiting }
      }
      var failed: Bool { terminals.contains { $0.mark == .failed } }
      var running: Bool { terminals.contains { $0.mark == .busy } }
    }

    struct Host {
      var kind: HostKind
      /// Its provider says it no longer exists (#629).
      var gone = false
      /// Its setup script never ran (#363).
      var setupPending = false
    }

    struct Room {
      var name: String
      var label: String? = nil
      var host: Host? = nil
      /// A warning the CLI lists for it, shown as the row's warning glyph.
      var warning: String? = nil
      /// Its folder is gone.
      var missing = false
      var target = Target()
    }

    struct ProjectEntry {
      var name: String
      var collapsed = false
      /// The project's own folder is gone.
      var rootMissing = false
      var root = Target()
      var rooms: [Room]
      /// A create still unnamed, on its own row (#483).
      var provisionalCreate: HostKind? = nil
    }

    struct Group {
      var name: String?
      var folded = false
      var terminals: [Terminal]
    }

    static let longName = "everything-at-once-with-a-name-long-enough-to-truncate"

    static let projectEntries: [ProjectEntry] = [
      ProjectEntry(
        name: "Activity",
        root: Target(terminals: [Terminal(title: "npm run dev", mark: .busy)], run: .running),
        rooms: [
          // First: the fixture selects it, so it is the one terminal that mounts a shell.
          Room(name: "selected", target: Target(dirty: true)),
          Room(name: "quiet"),
          Room(
            name: "busy", target: Target(terminals: [Terminal(title: "cargo build", mark: .busy)])),
          Room(
            name: "waiting",
            target: Target(terminals: [Terminal(title: "claude", mark: .waiting, tool: "claude")])),
          Room(
            name: "disconnected",
            target: Target(terminals: [
              Terminal(title: "claude", mark: .waitingStale, tool: "claude"),
              Terminal(title: "claude", mark: .waitingStale, tool: "claude"),
            ])),
          // One of its two can be answered, so it keeps the hand.
          Room(
            name: "waiting-one-disconnected",
            target: Target(terminals: [
              Terminal(title: "claude", mark: .waiting, tool: "claude"),
              Terminal(title: "claude", mark: .waitingStale, tool: "claude"),
            ])),
          Room(
            name: "failed",
            target: Target(terminals: [Terminal(title: "pytest", mark: .failed)])),
          Room(name: "unread", target: Target(unread: true)),
          Room(
            name: longName, warning: "Its branch was deleted on the remote.",
            target: Target(
              terminals: [
                Terminal(title: "claude", mark: .waiting, tool: "claude"),
                Terminal(title: "codex", mark: .waiting),
              ], run: .running, unread: true, dirty: true)),
        ]),
      ProjectEntry(
        name: "Runs and creates",
        root: Target(terminals: [Terminal(title: "claude", mark: .waiting, tool: "claude")]),
        rooms: [
          Room(
            name: "dev-server",
            target: Target(
              terminals: [Terminal(title: "bin/dev", mark: .busy), Terminal(title: "zsh")],
              run: .running)),
          Room(name: "stopping", target: Target(run: .stopping)),
          Room(name: "creating", target: Target(create: .running)),
          Room(name: "create-failed", target: Target(create: .failed)),
        ],
        provisionalCreate: .container(.docker)),
      ProjectEntry(
        name: "Hosts",
        root: Target(terminals: [Terminal(title: "make deploy", mark: .failed)]),
        rooms: [
          Room(name: "docker", host: Host(kind: .container(.docker))),
          Room(name: "apple-container", host: Host(kind: .container(.apple))),
          Room(
            name: "boxd", host: Host(kind: .boxd),
            target: Target(terminals: [Terminal(title: "go test ./...", mark: .busy)])),
          Room(name: "exe-dev", host: Host(kind: .exeDev)),
          Room(name: "ssh", host: Host(kind: .ssh)),
          Room(name: "railway", host: Host(kind: .railway)),
          Room(name: "railway-gone", host: Host(kind: .railway, gone: true)),
          Room(name: "setup-pending", host: Host(kind: .container(.docker), setupPending: true)),
        ]),
      ProjectEntry(
        name: "Edge cases", rootMissing: true,
        rooms: [
          Room(name: "dirty", target: Target(dirty: true)),
          Room(name: "warning", warning: "Its branch was deleted on the remote."),
          Room(name: "missing-folder", missing: true),
          Room(name: "labelled-workroom", label: "Payments refactor"),
          Room(name: "a-quiet-workroom-whose-name-is-long-enough-to-truncate"),
        ]),
      ProjectEntry(
        name: "Terminals",
        root: Target(
          terminals: [
            Terminal(title: "zsh"),
            Terminal(title: "npm run dev", mark: .busy),
            Terminal(title: "claude", mark: .waiting, tool: "claude"),
            Terminal(title: "claude", mark: .waitingStale, tool: "claude"),
            Terminal(title: "cargo test", mark: .failed),
            Terminal(title: "make build", mark: .done),
            Terminal(title: "make release", mark: .doneStale),
            Terminal(title: "tail -f log/development.log", unread: true),
            Terminal(title: "zsh", name: "Release notes"),
            Terminal(
              title: "bundle exec rspec spec/models/user_spec.rb spec/requests/sessions_spec.rb"),
          ], expanded: true),
        rooms: [
          Room(
            name: "split-work",
            target: Target(
              terminals: [
                Terminal(title: "htop", mark: .busy, tool: "htop"),
                Terminal(title: "make lint", mark: .done),
              ], expanded: true))
        ]),
      ProjectEntry(
        name: "Collapsed with news", collapsed: true, root: Target(dirty: true),
        rooms: [
          Room(
            name: "pending",
            target: Target(
              terminals: [
                Terminal(title: "claude", mark: .waitingStale, tool: "claude"),
                Terminal(title: "claude", mark: .waiting, tool: "claude"),
              ], unread: true))
        ]),
      ProjectEntry(name: "Collapsed", collapsed: true, rooms: [Room(name: "resting")]),
    ]

    static let quickTerminals: [Terminal] = [
      Terminal(title: "htop", mark: .busy, tool: "htop"),
      Terminal(title: "claude", mark: .waiting, tool: "claude"),
    ]

    static let standaloneTerminals: [Terminal] = [
      Terminal(title: "zsh"),
      Terminal(title: "npm run dev", mark: .busy),
      Terminal(title: "claude", mark: .waiting, tool: "claude"),
      Terminal(title: "claude", mark: .waitingStale, tool: "claude"),
      Terminal(title: "pytest", mark: .failed),
      Terminal(title: "make", mark: .done),
      Terminal(title: "make release", mark: .doneStale),
      Terminal(title: "ssh prod", unread: true),
      Terminal(title: "zsh", name: "Scratchpad"),
      Terminal(title: "docker compose logs --follow --tail=200 web worker scheduler"),
    ]

    static let groups: [Group] = [
      Group(
        name: "Ops",
        terminals: [
          Terminal(title: "kubectl get pods -w", mark: .busy),
          Terminal(title: "claude", mark: .waiting, tool: "claude"),
          Terminal(title: "terraform plan", mark: .done),
        ]),
      Group(
        name: "Deploys", folded: true,
        terminals: [
          Terminal(title: "claude", mark: .waiting, tool: "claude"),
          Terminal(title: "fly deploy", mark: .busy),
        ]),
      // Unnamed: its row is numbered ("Group 1").
      Group(name: nil, terminals: [Terminal(title: "zsh"), Terminal(title: "htop", tool: "htop")]),
      Group(name: "Failing", terminals: [Terminal(title: "go test ./...", mark: .failed)]),
      Group(name: "Empty", terminals: []),
    ]

    // MARK: Projects

    static var base: URL {
      URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("workroom-uitest/sidebar-gallery", isDirectory: true)
    }

    static func projectPath(_ entry: ProjectEntry) -> String {
      base.appendingPathComponent(entry.name, isDirectory: true).path
    }

    /// Each remote host's fixed id, so a host gone stays gone across a reload.
    static func hostID(_ project: ProjectEntry, _ room: Room) -> UUID {
      let p = projectEntries.firstIndex { $0.name == project.name } ?? 0
      let r = project.rooms.firstIndex { $0.name == room.name } ?? 0
      return UUID(uuidString: String(format: "5DEB%04X-0000-4000-8000-%012X", p, r))!
    }

    private static func descriptor(_ host: Host, id: UUID) -> HostDescriptor {
      var descriptor = HostDescriptor(
        driver: host.kind.driver, provisioner: RemoteWorkrooms.provisioner, id: id, workroomID: id,
        setupPending: host.setupPending ? true : nil)
      switch host.kind {
      case .container:
        descriptor.container = ContainerHostRecord(user: "workroom", image: "workroom/gallery")
      case .ssh:
        // A destination no resolver answers.
        descriptor.sshDestination = "gallery@gallery.invalid"
        descriptor.sshHome = "/home/gallery"
      case .railway:
        descriptor.railway = RailwayHostRecord(
          projectID: "prj-gallery", environmentID: "env-gallery", sandboxID: "sbx-\(id)",
          hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGalleryGalleryGalleryGalleryGalleryGall")
      case .boxd, .exeDev:
        break
      }
      return descriptor
    }

    /// The gallery's projects, their folders made (all but the missing ones).
    static func projects() -> [Project] {
      projectEntries.map { entry in
        let path = projectPath(entry)
        if !entry.rootMissing {
          try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        }
        let workrooms = entry.rooms.map { room -> Workroom in
          if let host = room.host {
            return Workroom(
              name: room.name, path: "/home/workroom/\(entry.name)/\(room.name)", vcsName: "git",
              warnings: [], host: descriptor(host, id: hostID(entry, room)), label: room.label)
          }
          let dir = base.appendingPathComponent("workrooms/\(entry.name)/\(room.name)").path
          if !room.missing {
            try? FileManager.default.createDirectory(
              atPath: dir, withIntermediateDirectories: true)
          }
          var warnings: [Warning] = []
          if let warning = room.warning {
            warnings.append(Warning(kind: "BranchMissing", message: warning, path: dir, vcs: "git"))
          }
          if room.missing {
            warnings.append(
              Warning(
                kind: "DirectoryMissing", message: "Its folder is gone.", path: dir, vcs: "git"))
          }
          return Workroom(
            name: room.name, path: dir, vcsName: "git", warnings: warnings, label: room.label)
        }
        return Project(path: path, vcs: "git", workrooms: workrooms)
      }
    }

    static var collapsedPaths: Set<String> {
      Set(projectEntries.filter(\.collapsed).map(projectPath))
    }

    // MARK: Seeding

    /// Seeds `store`'s window once: the fixture's launch window, after its own first load.
    @MainActor
    static func seed(_ store: AppStore) {
      var notes: [WorkroomNotification] = []
      for entry in projectEntries {
        let path = projectPath(entry)
        guard let project = store.projectStore.project(at: path) else { continue }
        store.runCommands.setRunConfig(
          RunConfig(command: "bin/dev", autoRun: false), forProject: path)
        seed(entry.root, target: project.rootTarget, sid: .root(project: path), in: store, &notes)
        for room in entry.rooms {
          guard let workroom = project.workrooms.first(where: { $0.name == room.name }) else {
            continue
          }
          let target = workroom.target(inProject: path)
          if let host = room.host, host.gone {
            GoneHosts.record(.remote(hostID(entry, room)), gone: true)
          }
          seed(
            room.target, target: target, sid: .workroom(project: path, name: room.name), in: store,
            &notes)
          if let create = room.target.create {
            seedCreate(create, workroom: workroom, project: project, in: store)
          }
        }
        if let kind = entry.provisionalCreate {
          let run = CreationRun(
            project: project, kind: kind, splitAnchor: nil, previousSelection: nil)
          run.begin("repository")
          run.begin("image")
          run.pullFraction = 0.42
          store.lifecycle.register(run)
        }
      }
      // Again on every load (`AppStore.loadFixture`), which unfolds every fixture project.
      store.collapsedProjects.formUnion(collapsedPaths)
      seedSection(in: store, &notes)
      store.notifications.seedForTesting(notes)
      seedQuickTerminals()
    }

    /// The statuses the gallery's rows show. Again on every load: the fixture's own seed writes its
    /// first project's root and first workroom each time.
    @MainActor
    static func seedStatuses(_ store: AppStore) {
      for entry in projectEntries {
        let path = projectPath(entry)
        store.vcsStatus.workroomStatuses[.root(project: path)] =
          entry.root.dirty ? UITestFixture.workroomStatus : UITestFixture.rootStatus
        for room in entry.rooms where room.host == nil {
          store.vcsStatus.workroomStatuses[.workroom(project: path, name: room.name)] =
            room.target.dirty ? UITestFixture.workroomStatus : UITestFixture.rootStatus
        }
      }
    }

    @MainActor
    private static func seed(
      _ seed: Target, target: TerminalTarget, sid: SidebarID, in store: AppStore,
      _ notes: inout [WorkroomNotification]
    ) {
      let tabs = seedTerminals(seed.terminals, target: target, in: store.terminals, &notes)
      if seed.expanded {
        store.expandedTerminalTargets.insert(target.id)
        store.unfoldedOpenTargets.insert(target.id)
      }
      if seed.unread { notes.append(note(target: target.id, tab: UUID(), title: "Build finished")) }
      if let run = seed.run, let tab = tabs.first {
        store.runCommand.runStates[target.id] = .running(tab: tab, interrupted: run == .stopping)
      }
    }

    /// Opens `terminals` in `target` (unmounted, so no shell starts), each with its title and mark.
    @MainActor
    @discardableResult
    static func seedTerminals(
      _ terminals: [Terminal], target: TerminalTarget, in panes: TerminalPanes,
      _ notes: inout [WorkroomNotification]
    ) -> [TerminalTab.ID] {
      let existing = panes.tabs(for: target).map(\.id)
      var ids = existing
      while ids.count < terminals.count {
        ids.append(panes.addTab(for: target, focus: false).id)
      }
      for (terminal, id) in zip(terminals, ids) {
        panes.seedTerminalForFixture(
          tab: id, target: target.id, title: terminal.title,
          tool: terminal.tool.flatMap(ToolLogoRegistry.tool(forExecutableName:)),
          name: terminal.name)
        if let record = record(for: terminal.mark) {
          let stale = terminal.mark.isStale
          panes.seedProgramStatusForFixture(
            tab: id, target: target.id,
            host: stale ? UITestFixture.staleProgramStatusHost : .local, records: [record],
            stale: stale)
        }
        if terminal.unread {
          notes.append(note(target: target.id, tab: id, title: "\(terminal.title) printed a bell"))
        }
      }
      if let first = ids.first { panes.select(first, for: target) }
      return ids
    }

    static func record(for mark: Mark) -> ProgramStatusRecord? {
      switch mark {
      case .idle: nil
      case .busy: ProgramStatusRecord(id: "", state: .working)
      case .waiting:
        ProgramStatusRecord(
          id: "", state: .blocked, kind: .permission, message: "Apply the edit?", episode: 1)
      case .waitingStale:
        ProgramStatusRecord(
          id: "", state: .blocked, kind: .question, message: "Red or blue?", episode: 1)
      case .failed: ProgramStatusRecord(id: "", state: .error, message: "Tests failed")
      case .done, .doneStale: ProgramStatusRecord(id: "", state: .done)
      }
    }

    private static func note(target: TerminalTarget.ID, tab: UUID, title: String)
      -> WorkroomNotification
    {
      WorkroomNotification(
        id: UUID(), targetID: target, tabID: tab, source: "Sidebar gallery", title: title,
        body: nil, date: Date(), count: 1)
    }

    @MainActor
    private static func seedCreate(
      _ create: Create, workroom: Workroom, project: Project, in store: AppStore
    ) {
      let run = CreationRun(project: project, kind: nil, splitAnchor: nil, previousSelection: nil)
      run.finish("fetch", as: .skipped(reason: "No remote to fetch from"))
      run.begin("worktree")
      run.setName(workroom.name)
      let id = workroom.target(inProject: project.path).id
      store.lifecycle.creationRuns[run.id] = run
      store.lifecycle.creationRunForTarget[id] = run.id
      switch create {
      case .running:
        store.lifecycle.creatingWorkrooms.insert(id)
      case .failed:
        run.fail(.setupScriptFailed(message: "bin/setup exited with status 1"))
      }
    }

    @MainActor
    private static func seedSection(in store: AppStore, _ notes: inout [WorkroomNotification]) {
      let section = store.terminalsSection
      for terminal in standaloneTerminals {
        guard let sid = section.addStandalone().sidebarID, let target = store.target(for: sid)
        else { continue }
        seedTerminals([terminal], target: target, in: store.terminals, &notes)
      }
      for group in groups {
        let id = section.addGroup(named: group.name)
        if group.folded {
          section.setFolded(id, true)
        } else {
          store.unfoldedOpenTargets.insert(id)
        }
        guard let sid = id.sidebarID, let target = store.target(for: sid),
          !group.terminals.isEmpty
        else { continue }
        seedTerminals(group.terminals, target: target, in: store.terminals, &notes)
      }
    }

    /// The Quick Terminal's panel exists once the app has finished launching, which may be after
    /// the first window's first load.
    @MainActor
    private static func seedQuickTerminals(attempts: Int = 20) {
      guard let controller = WindowRegistry.shared.quickTerminal else {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          MainActor.assumeIsolated { seedQuickTerminals(attempts: attempts - 1) }
        }
        return
      }
      let host = controller.ensureHost()
      let target = QuickTerminalController.target()
      guard host.terminals.tabs(for: target).isEmpty else { return }
      var notes: [WorkroomNotification] = []
      seedTerminals(quickTerminals, target: target, in: host.terminals, &notes)
    }
  }
#endif
