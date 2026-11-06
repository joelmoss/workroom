import HostDrivers
import SwiftUI
import WorkroomDomain

/// What the host option fields learn from the provider (#575): a boxd account's snapshots and its
/// org's default size and quota, and an exe.dev plan's limits and default disk. Read when the
/// fields appear, off the main path; a create never waits on them. Nil until read, and still nil
/// when the read failed, which `failure` says.
///
/// One for the app, so Remote Hosts, Projects and Configure… share what was read. A good read is
/// kept for two minutes, and a failed one not at all; the Settings window reads afresh as it opens,
/// so a snapshot saved meanwhile shows. A provider's fields keep showing what was read while a new
/// read is under way.
@MainActor
final class HostOptionsCatalog: ObservableObject {
  static let shared = HostOptionsCatalog()
  /// How long a good read is used before the provider is asked again.
  static let freshFor: TimeInterval = 120

  /// Everything the reads found, in one value, so a read's findings change the catalog once.
  struct Found {
    var snapshots: [String]?
    var boxdSize: BoxdHostDriver.DefaultSize?
    var plan: ExeDevHostDriver.PlanLimits?
    var failure: [HostKind: String] = [:]
    /// The providers whose read is over, whether it worked or not.
    var finished: Set<HostKind> = []
  }

  @Published private(set) var found = Found()
  var snapshots: [String]? { found.snapshots }
  var boxdSize: BoxdHostDriver.DefaultSize? { found.boxdSize }
  var plan: ExeDevHostDriver.PlanLimits? { found.plan }
  var failure: [HostKind: String] { found.failure }
  var finished: Set<HostKind> { found.finished }
  /// When each provider was last read well.
  private var readAt: [HostKind: Date] = [:]
  /// Each provider's read under way, which every screen asking for it waits on.
  private var reading: [HostKind: Task<Reading, Never>] = [:]

  /// What one provider's read found.
  enum Reading {
    case boxd(snapshots: [String], size: BoxdHostDriver.DefaultSize?)
    case exeDev(ExeDevHostDriver.PlanLimits)
    /// What to say instead: the provider isn't installed, set up or reachable.
    case failed(String)
  }

  /// Seams for tests: the clock, and the read itself.
  var now: () -> Date = Date.init
  var fetch: ((HostKind) async -> Reading)?

  /// Reads `provider` unless it was read well under `freshFor` ago; a read already under way is
  /// waited on instead. The read is the catalog's, not the asking screen's, so a screen going away
  /// doesn't cut it short for another still waiting. What it found is set all at once, so its
  /// sections redraw once.
  func load(_ provider: HostKind) async {
    if let at = readAt[provider], now().timeIntervalSince(at) < Self.freshFor { return }
    if let running = reading[provider] {
      _ = await running.value
      return
    }
    let fetch = fetch ?? read
    let task = Task { await fetch(provider) }
    reading[provider] = task
    let reading = await task.value
    self.reading[provider] = nil
    var next = found
    switch reading {
    case .boxd(let names, let size):
      next.snapshots = names
      next.boxdSize = size
    case .exeDev(let limits):
      next.plan = limits
    case .failed:
      break
    }
    if case .failed(let message) = reading {
      next.failure[provider] = message
      readAt[provider] = nil
    } else {
      next.failure[provider] = nil
      readAt[provider] = now()
    }
    next.finished.insert(provider)
    found = next
  }

  /// Makes every provider's next read a fresh one, as the Settings window opens. Nothing is read
  /// here: a provider is asked only when one of its sections shows (Remote Hosts, a project's
  /// settings, Configure…), so opening Settings on another pane asks none (exe.dev's read is an
  /// ssh login).
  func markStale() {
    readAt = [:]
  }

  private func read(_ provider: HostKind) async -> Reading {
    // The shared driver for whoever is signed in now: a create's key also names the account,
    // which would cost a sign-in read before every read here.
    let key: RemoteHosts.DriverKey
    switch provider {
    case .boxd:
      guard RemoteHosts.boxdExecutable() != nil else {
        return .failed("boxd isn't installed yet. Creating a boxd workroom sets it up.")
      }
      key = .boxd(org: nil, account: nil)
    case .exeDev:
      key = .exeDev(account: nil)
    case .container, .ssh:
      return .failed("\(provider.displayName) hosts take no host options.")
    }
    do {
      guard let reading = try RemoteHosts.shared.driver(key) as? any HostOptionsReading else {
        return .failed("\(provider.displayName) couldn't be reached.")
      }
      switch try await reading.readHostOptions() {
      case .boxd(let snapshots, let size): return .boxd(snapshots: snapshots, size: size)
      case .exeDev(let limits): return .exeDev(limits)
      }
    } catch {
      // Usually a provider not set up yet (story 40): options can still be saved before signing up.
      let name = provider.displayName
      let reason = error.localizedDescription
      return .failed(
        "\(name) isn't set up, or couldn't be reached: \(reason)\(reason.hasSuffix(".") ? "" : ".")"
          + " Creating a \(name) workroom sets it up.")
    }
  }
}

/// A provider's host options as a form section, in Settings ▸ Remote Hosts, Settings ▸ Projects
/// and the Configure… panel.
/// Its fields wait for this provider's read only, so their lists and labels don't change under you
/// and nothing else waits on it. Until then they are laid out but hidden, with a spinner by the
/// heading, so the section already has its height and nothing moves when they show.
struct HostOptionsSection: View {
  let provider: HostKind
  @Binding var options: HostOptions
  let inherited: HostOptions.Resolution?
  @ObservedObject var catalog: HostOptionsCatalog
  /// The heading, when not the Settings one.
  var title: String?

  var body: some View {
    let loading = !catalog.finished.contains(provider)
    Section {
      HostOptionsFields(
        provider: provider, options: $options, inherited: inherited, catalog: catalog
      )
      .opacity(loading ? 0 : 1)
      .disabled(loading)
      .accessibilityHidden(loading)
    } header: {
      HStack {
        if let title { Text(title) } else { HostOptionsHeader(provider: provider) }
        Spacer()
        if loading { ProgressView().controlSize(.small) }
      }
    } footer: {
      if let failure = catalog.failure[provider] { Text(failure) }
    }
    .task { await catalog.load(provider) }
  }
}

/// A provider's host options heading in Settings (#575): what the group is for, with "info"
/// linking to how host options work.
struct HostOptionsHeader: View {
  let provider: HostKind

  private static let subtitle: AttributedString = {
    var text = AttributedString("Override the default options used during creation - ")
    var info = AttributedString("info")
    info.link = URL(
      string: "https://codaset.dev/workroom/docs/remote/overview#choose-a-hosts-image-and-size")
    text.append(info)
    return text
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("New \(provider.displayName) Workrooms")
      Text(Self.subtitle)
        .font(.caption)
        .fontWeight(.regular)
        .foregroundStyle(ThemeService.shared.tokens.fgMuted)
    }
    .textCase(nil)
  }
}

/// How one host option's choices read and what each saves (#575), the same at every level. The
/// value this level gets when it chooses nothing saves nothing; the provider's own default is marked
/// "(default)", and a value from the level below "(app)" (Settings) or "(project)". A value that is
/// both is marked only "(default)". Provider default is a choice of its own only where it differs
/// from what this level gets anyway, so it never reads as a second way to the same thing.
struct HostOptionChoices<Value: Hashable & Codable & Sendable> {
  enum Stored: Hashable {
    case inherit, providerDefault
    case value(Value)
  }

  /// The provider's default, when it says.
  let providerDefault: Value?
  /// What the levels below give, or nil at Settings, which is the last level.
  let below: HostOptions.Resolved<Value>?

  /// What choosing nothing gets here.
  var fallsTo: Value? { below?.value ?? providerDefault }

  /// What choosing `value` saves.
  func stored(for value: Value) -> Stored {
    if value == fallsTo { return .inherit }
    if value == providerDefault { return .providerDefault }
    return .value(value)
  }

  /// The word in brackets after `value`, if any.
  func mark(for value: Value) -> String? {
    if value == providerDefault { return "default" }
    guard let below, below.value == value, let source = below.source else { return nil }
    return source.mark
  }

  /// Whether Provider default needs a row of its own: when the provider doesn't say what it is,
  /// or it isn't one of `values`.
  func needsProviderDefaultRow(among values: [Value]) -> Bool {
    providerDefault.map { !values.contains($0) } ?? true
  }

  /// What that row saves: nothing, where nothing below names a value.
  var providerDefaultStored: Stored { below?.value == nil ? .inherit : .providerDefault }

  /// The choice a saved option shows as.
  func selection(of option: HostOption<Value>?) -> Stored {
    switch option {
    case nil: .inherit
    case .providerDefault: providerDefaultStored
    case .value(let value): stored(for: value)
    }
  }
}

extension HostOptions.Level {
  /// How a value from this level is marked in a level above it.
  var mark: String {
    switch self {
    case .settings: "app"
    case .project: "project"
    case .create: "this workroom"
    }
  }
}

/// One provider's host option fields at one level (#575): Settings, a project, or one create.
/// Each field shows what choosing nothing gets, marked with where it comes from
/// (`HostOptionChoices`). Settings is the last level, so there choosing nothing is the provider's
/// default.
struct HostOptionsFields: View {
  /// A kind that takes host options (`HostKind.takesHostOptions`).
  let provider: HostKind
  @Binding var options: HostOptions
  /// What this level inherits from the levels below it, or nil at Settings.
  let inherited: HostOptions.Resolution?
  @ObservedObject var catalog: HostOptionsCatalog

  /// exe.dev's disk sizes, in GB, up to the plan's maximum.
  private static let diskSizes = [10, 25, 50, 100, 250, 500, 1024]

  var body: some View {
    imageField
    switch provider {
    case .boxd:
      boxdSize
    case .exeDev:
      if let plan = catalog.plan {
        OptionPicker(
          "CPU", option: $options.cpu, values: Array(1...max(plan.maxCPUs, 1)),
          label: { "\($0)" },
          choices: HostOptionChoices(providerDefault: defaults.cpu, below: inherited?.cpu))
        OptionPicker(
          "Memory", option: $options.memory,
          values: (1...max(plan.maxMemoryGB, 1)).map { "\($0)GB" }, label: { $0 },
          choices: HostOptionChoices(providerDefault: nil, below: inherited?.memory))
        OptionPicker(
          "Disk", option: $options.disk, values: diskSizes(plan).map { "\($0)GB" },
          label: { $0 },
          choices: HostOptionChoices(providerDefault: defaults.disk, below: inherited?.disk))
      } else {
        OptionTextField(
          "CPU", option: cpuText,
          choices: HostOptionChoices(
            providerDefault: defaults.cpu.map { "\($0)" },
            below: inherited.map {
              HostOptions.Resolved(value: $0.cpu.value.map { "\($0)" }, source: $0.cpu.source)
            }))
        OptionTextField(
          "Memory", option: $options.memory,
          choices: HostOptionChoices(providerDefault: nil, below: inherited?.memory))
        OptionTextField(
          "Disk", option: $options.disk,
          choices: HostOptionChoices(providerDefault: nil, below: inherited?.disk))
      }
    case .container, .ssh:
      EmptyView()
    }
  }

  /// The host image, called what it is for the provider: a snapshot lists the account's own.
  @ViewBuilder private var imageField: some View {
    let snapshots = provider.hostImageKind == .snapshot ? catalog.snapshots : nil
    if let imageKind = provider.hostImageKind {
      OptionTextField(
        imageKind.fieldLabel, option: $options.image,
        choices: HostOptionChoices(providerDefault: nil, below: inherited?.image),
        suggestions: snapshots ?? [])
    }
    if case .value(let name)? = options.image, let snapshots, !snapshots.contains(name) {
      Text(Self.missingSnapshot)
        .font(.footnote)
        .foregroundStyle(ThemeService.shared.tokens.warning)
    }
  }

  /// A saved snapshot name the signed-in boxd account doesn't have, with "help" linking to how
  /// snapshots are made and listed.
  private static let missingSnapshot: AttributedString = {
    var text = AttributedString("No snapshot of that name in this boxd account - ")
    var help = AttributedString("help")
    help.link = URL(string: "https://codaset.dev/workroom/docs/remote/boxd#start-from-a-snapshot")
    text.append(help)
    return text
  }()

  /// boxd's four sizes, up to the org's quota, which a snapshot doesn't take: it keeps its
  /// source's.
  @ViewBuilder private var boxdSize: some View {
    let snapshot = resolvedHere?.sizeTakenBySnapshot == true
    OptionPicker(
      "Size", option: $options.cpu,
      values: [1, 2, 4, 8].filter { $0 <= (catalog.boxdSize?.maxVCPU ?? 8) },
      label: Self.boxdSize,
      choices: HostOptionChoices(providerDefault: defaults.cpu, below: inherited?.cpu),
      fadesAll: snapshot
    )
    .disabled(snapshot)
    if snapshot {
      Text("A snapshot keeps its own size.")
        .font(.footnote)
        .foregroundStyle(ThemeService.shared.tokens.fgMuted)
    }
  }

  /// One of boxd's sizes, by its vCPUs: memory follows, 4 GB a vCPU.
  private static func boxdSize(_ vcpu: Int) -> String { "\(vcpu) vCPU, \(vcpu * 4) GB" }

  /// What the provider gives each option when none is chosen, where it says.
  private var defaults: (cpu: Int?, disk: String?) {
    switch provider {
    case .boxd: (catalog.boxdSize?.vcpu, nil)
    case .exeDev: (ExeDevHostDriver.defaultCPUs, catalog.plan?.defaultDiskGB.map { "\($0)GB" })
    case .container, .ssh: (nil, nil)
    }
  }

  /// The disk sizes up to the plan's maximum, with the plan's default among them.
  private func diskSizes(_ plan: ExeDevHostDriver.PlanLimits) -> [Int] {
    let sizes = Self.diskSizes.filter { $0 <= (plan.maxDiskGB ?? Int.max) }
    return Set(sizes + [plan.defaultDiskGB].compactMap { $0 }).sorted()
  }

  /// This level's options over what it inherits, for what follows from them here.
  private var resolvedHere: HostOptions.Resolution? {
    HostOptions.resolve(
      for: provider, create: options, project: nil,
      settings: inherited.map { HostOptions(resolved: $0) })
  }

  /// CPU as text, when the plan can't be read.
  private var cpuText: Binding<HostOption<String>?> {
    Binding(
      get: {
        switch options.cpu {
        case .value(let cpu): .value(String(cpu))
        case .providerDefault: .providerDefault
        case nil: nil
        }
      },
      set: { text in
        switch text {
        case .value(let typed):
          options.cpu = Int(typed.trimmingCharacters(in: .whitespaces)).map { .value($0) }
        case .providerDefault: options.cpu = .providerDefault
        case nil: options.cpu = nil
        }
      })
  }
}

extension HostOptions {
  /// A level that sets every option as `resolution` resolved it: what the levels below one look
  /// like to it.
  init(resolved resolution: Resolution) {
    func option<V>(_ resolved: Resolved<V>) -> HostOption<V>? {
      guard resolved.source != nil else { return nil }
      return resolved.value.map { .value($0) } ?? .providerDefault
    }
    self.init(
      image: option(resolution.image), cpu: option(resolution.cpu),
      memory: option(resolution.memory), disk: option(resolution.disk))
  }
}

/// `text`, then its mark in brackets, faded: "2 (default)".
private func marked(_ text: String, _ mark: String) -> Text {
  Text("\(text) \(Text("(\(mark))").foregroundStyle(.secondary))")
}

/// A picked option: each of `values`, marked as `choices` says, and Provider default as a row of
/// its own only where the provider's default isn't one of them.
private struct OptionPicker<Value: Hashable & Codable & Sendable>: View {
  let title: String
  @Binding var option: HostOption<Value>?
  let values: [Value]
  let label: (Value) -> String
  let choices: HostOptionChoices<Value>
  /// Fades every row whole: a boxd size a snapshot decides, so the value shown isn't one chosen.
  let fadesAll: Bool

  init(
    _ title: String, option: Binding<HostOption<Value>?>, values: [Value],
    label: @escaping (Value) -> String, choices: HostOptionChoices<Value>, fadesAll: Bool = false
  ) {
    self.title = title
    _option = option
    self.values = values
    self.label = label
    self.choices = choices
    self.fadesAll = fadesAll
  }

  var body: some View {
    Picker(title, selection: selection) {
      if choices.needsProviderDefaultRow(among: values) {
        Group {
          if let value = choices.providerDefault {
            row(label(value), mark: "default")
          } else {
            // The provider's own choice, whose value it doesn't say: faded, as a mark is.
            Text("Provider default").foregroundStyle(.secondary)
          }
        }
        .tag(choices.providerDefaultStored)
      }
      ForEach(shown, id: \.self) { value in
        row(label(value), mark: choices.mark(for: value))
          .tag(choices.stored(for: value))
      }
    }
  }

  /// One row: its value, then its mark faded, or all of it faded where `fadesAll`.
  private func row(_ text: String, mark: String?) -> Text {
    if fadesAll { return Text(mark.map { "\(text) (\($0))" } ?? text).foregroundStyle(.secondary) }
    return mark.map { marked(text, $0) } ?? Text(text)
  }

  /// The values, with any saved here or below that the list doesn't have, so the picker never
  /// goes blank (a plan since made smaller).
  private var shown: [Value] {
    var shown = values
    var extra: [Value] = []
    if case .value(let saved)? = option { extra.append(saved) }
    if let below = choices.below?.value { extra.append(below) }
    for value in extra where !shown.contains(value) && value != choices.providerDefault {
      shown.append(value)
    }
    return shown
  }

  private var selection: Binding<HostOptionChoices<Value>.Stored> {
    Binding(
      get: { choices.selection(of: option) },
      set: {
        switch $0 {
        case .inherit: option = nil
        case .providerDefault: option = .providerDefault
        case .value(let value): option = .value(value)
        }
      })
  }
}

/// A typed option: empty gets what `choices` falls to, which its placeholder names and marks. Its
/// menu offers `suggestions` (a boxd account's snapshots), and, where the level below names a value
/// of its own, both that value and the provider's default.
private struct OptionTextField: View {
  let title: String
  @Binding var option: HostOption<String>?
  let choices: HostOptionChoices<String>
  let suggestions: [String]

  init(
    _ title: String, option: Binding<HostOption<String>?>, choices: HostOptionChoices<String>,
    suggestions: [String] = []
  ) {
    self.title = title
    _option = option
    self.choices = choices
    self.suggestions = suggestions
  }

  /// The level below's own value, when it names one other than the provider's default.
  private var belowsOwn: (value: String, mark: String)? {
    guard let below = choices.below, let value = below.value, let source = below.source,
      value != choices.providerDefault
    else { return nil }
    return (value, source.mark)
  }

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 6) {
        TextField(title, text: text, prompt: Text(placeholder))
          .labelsHidden()
          .disabled(option == .providerDefault)
        if !suggestions.isEmpty || belowsOwn != nil || option == .providerDefault {
          Menu {
            ForEach(suggestions, id: \.self) { name in Button(name) { option = .value(name) } }
            if !suggestions.isEmpty, belowsOwn != nil || option == .providerDefault { Divider() }
            if let belowsOwn {
              Button("\(belowsOwn.value) (\(belowsOwn.mark))") { option = nil }
              Button("Provider Default") { option = .providerDefault }
            } else if option == .providerDefault {
              Button("Clear") { option = nil }
            }
          } label: {
            Image(systemName: "chevron.down")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("\(title) choices")
        }
      }
    }
  }

  private var placeholder: String {
    if option == .providerDefault {
      return choices.providerDefault.map { "\($0) (default)" } ?? "Provider default"
    }
    guard let value = choices.fallsTo else { return "" }
    return choices.mark(for: value).map { "\(value) (\($0))" } ?? value
  }

  private var text: Binding<String> {
    Binding(
      get: {
        if case .value(let value)? = option { return value }
        return ""
      },
      set: { typed in
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        option = value.isEmpty ? nil : .value(value)
      })
  }
}
