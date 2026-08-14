import Foundation

@MainActor
final class ClaudeUsageBridge: ObservableObject {
  enum State: Equatable {
    case disabled
    case enabled
    case needsRepair
  }

  enum BridgeError: LocalizedError, Equatable {
    case invalidSettings
    case missingMetadata
    case settingChanged

    var errorDescription: String? {
      switch self {
      case .invalidSettings: return "Claude settings could not be read."
      case .missingMetadata:
        return "Workroom's saved Claude status-line metadata is missing."
      case .settingChanged:
        return
          "Claude's status-line setting changed after Workroom enabled usage. It was not overwritten."
      }
    }
  }

  nonisolated static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Workroom/Agent Usage", isDirectory: true)

  @Published private(set) var state: State = .disabled
  @Published private(set) var lastError: String?

  let settingsURL: URL
  let directoryURL: URL
  var wrapperURL: URL { directoryURL.appendingPathComponent("claude-status-line-bridge.sh") }
  var metadataURL: URL { directoryURL.appendingPathComponent("claude-status-line-metadata.json") }
  var cacheURL: URL { directoryURL.appendingPathComponent("claude-rate-limits.json") }
  /// Scratch space for the wrapper's per-invocation temp files, kept OUT of `directoryURL` itself.
  /// `AgentUsageMonitor` watches `directoryURL` for `cacheURL` updates; every create/delete in a
  /// watched directory fires that watch, so if the wrapper's transient files lived there too, every
  /// status-line invocation (not just ones that change the cached rate limits) would trigger a
  /// refresh for as long as an agent session runs.
  private var scratchDirectoryURL: URL {
    directoryURL.appendingPathComponent("tmp", isDirectory: true)
  }

  private let fileManager: FileManager
  private let writer: (Data, URL, Int) throws -> Void

  init(
    settingsURL: URL? = nil,
    directoryURL: URL? = nil,
    fileManager: FileManager = .default,
    writer: ((Data, URL, Int) throws -> Void)? = nil
  ) {
    if UITestFixture.isActive {
      let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "workroom-agent-usage-ui-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
      self.settingsURL = settingsURL ?? fixtureRoot.appendingPathComponent(".claude/settings.json")
      self.directoryURL = directoryURL ?? fixtureRoot.appendingPathComponent("Agent Usage")
    } else {
      self.settingsURL =
        settingsURL
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
      self.directoryURL = directoryURL ?? ClaudeUsageBridge.defaultDirectory
    }
    self.fileManager = fileManager
    self.writer =
      writer ?? { data, url, permissions in
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: permissions], ofItemAtPath: url.path)
      }
    refreshState()
  }

  func refreshState() {
    lastError = nil
    guard let settings = try? readObject(at: settingsURL),
      let current = settings["statusLine"] as? [String: Any],
      current["command"] as? String == installedCommand
    else {
      state = .disabled
      return
    }
    guard let metadata = try? readMetadata(),
      equalJSON(current, metadata.installed),
      fileManager.isExecutableFile(atPath: wrapperURL.path)
    else {
      state = .needsRepair
      return
    }
    state = .enabled
  }

  func enable() throws {
    try prepareDirectory()
    var settings = try readSettingsAllowingMissing()

    if let current = settings["statusLine"] as? [String: Any],
      current["command"] as? String == installedCommand
    {
      guard let metadata = try? readMetadata(), equalJSON(current, metadata.installed) else {
        state = .needsRepair
        throw BridgeError.missingMetadata
      }
      try writeWrapper()
      state = .enabled
      return
    }

    let prior = settings["statusLine"]
    let installed: [String: Any] = ["type": "command", "command": installedCommand]
    let metadata: [String: Any] = [
      "version": 1,
      "priorStatusLine": prior ?? NSNull(),
      "installedStatusLine": installed,
    ]
    try writeJSON(metadata, to: metadataURL, permissions: 0o600)
    try writeWrapper()
    settings["statusLine"] = installed
    try writeJSON(settings, to: settingsURL, permissions: settingsPermissions())
    state = .enabled
  }

  func repair() throws {
    let settings = try readSettingsAllowingMissing()
    guard let current = settings["statusLine"] as? [String: Any],
      current["command"] as? String == installedCommand
    else {
      throw BridgeError.settingChanged
    }
    try prepareDirectory()
    // Workroom's own command is still installed. If the metadata that lets `disable()` restore the
    // prior status line is missing or stale (e.g. the Agent Usage directory was cleared), rebuild it
    // rather than getting permanently stuck: the true prior is unrecoverable at this point, so record
    // none — a later disable clears the setting instead of guessing.
    if let metadata = try? readMetadata(), equalJSON(current, metadata.installed) {
      // Metadata already matches what's installed — nothing to rebuild.
    } else {
      let rebuilt: [String: Any] = [
        "version": 1,
        "priorStatusLine": NSNull(),
        "installedStatusLine": current,
      ]
      try writeJSON(rebuilt, to: metadataURL, permissions: 0o600)
    }
    try writeWrapper()
    state = .enabled
  }

  func disable() throws {
    let metadata = try readMetadata()
    var settings = try readSettingsAllowingMissing()
    guard let current = settings["statusLine"] as? [String: Any],
      equalJSON(current, metadata.installed)
    else {
      state = .needsRepair
      lastError = BridgeError.settingChanged.localizedDescription
      throw BridgeError.settingChanged
    }

    if metadata.prior is NSNull {
      settings.removeValue(forKey: "statusLine")
    } else {
      settings["statusLine"] = metadata.prior
    }
    // Restore first. Cleanup happens only after that atomic write succeeds, so a failure leaves the
    // wrapper and its metadata intact and Claude's configured status line remains runnable.
    try writeJSON(settings, to: settingsURL, permissions: settingsPermissions())
    try? fileManager.removeItem(at: metadataURL)
    try? fileManager.removeItem(at: cacheURL)
    try? fileManager.removeItem(at: wrapperURL)
    try? fileManager.removeItem(at: scratchDirectoryURL)
    state = .disabled
    lastError = nil
  }

  private var installedCommand: String { shellQuote(wrapperURL.path) }

  private func writeWrapper() throws {
    let cache = shellQuote(cacheURL.path)
    let metadata = shellQuote(metadataURL.path)
    let scratch = shellQuote(scratchDirectoryURL.path)
    let script = """
      #!/bin/sh
      set -u
      umask 077
      scratch_dir=\(scratch)
      cache_file=\(cache)
      metadata_file=\(metadata)
      /bin/mkdir -p "$scratch_dir" || exit $?
      input_file="$scratch_dir/input.$$"
      cache_tmp="$scratch_dir/rate-limits.$$"
      cleanup() { /bin/rm -f "$input_file" "$cache_tmp"; }
      trap cleanup EXIT HUP INT TERM
      /bin/cat > "$input_file" || exit $?
      if /usr/bin/plutil -extract rate_limits json -o "$cache_tmp" "$input_file" 2>/dev/null; then
        /bin/chmod 600 "$cache_tmp" || exit $?
        /bin/mv -f "$cache_tmp" "$cache_file" || exit $?
      fi
      prior=$(/usr/bin/plutil -extract priorStatusLine.command raw -o - "$metadata_file" 2>/dev/null) || exit 0
      /bin/sh -c "$prior" < "$input_file"
      exit $?
      """
    try writer(Data(script.utf8), wrapperURL, 0o700)
  }

  private func prepareDirectory() throws {
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    try fileManager.createDirectory(at: scratchDirectoryURL, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: scratchDirectoryURL.path)
    let settingsDirectory = settingsURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
  }

  private func readSettingsAllowingMissing() throws -> [String: Any] {
    guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
    return try readObject(at: settingsURL)
  }

  private func readObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BridgeError.invalidSettings
    }
    return object
  }

  private func readMetadata() throws -> (prior: Any, installed: [String: Any]) {
    let object = try readObject(at: metadataURL)
    guard let prior = object["priorStatusLine"],
      let installed = object["installedStatusLine"] as? [String: Any]
    else { throw BridgeError.missingMetadata }
    return (prior, installed)
  }

  private func writeJSON(_ object: Any, to url: URL, permissions: Int) throws {
    guard JSONSerialization.isValidJSONObject(object) else { throw BridgeError.invalidSettings }
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try writer(data, url, permissions)
  }

  private func settingsPermissions() -> Int {
    let attributes = try? fileManager.attributesOfItem(atPath: settingsURL.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
  }

  private func equalJSON(_ lhs: Any, _ rhs: Any) -> Bool {
    guard JSONSerialization.isValidJSONObject([lhs]), JSONSerialization.isValidJSONObject([rhs]),
      let left = try? JSONSerialization.data(withJSONObject: [lhs], options: [.sortedKeys]),
      let right = try? JSONSerialization.data(withJSONObject: [rhs], options: [.sortedKeys])
    else { return false }
    return left == right
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
