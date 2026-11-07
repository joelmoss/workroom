import AppKit
import WorkroomDomain
import WorkroomVCS

/// ⌘-click in a remote pane resolves on the HOST (#254, C7): against the shell's directory there, as
/// its daemon reports it (`hostCwd`), and through the host's file service. The file opens in the
/// in-app viewer, since no editor on this Mac can open a file on another machine. Web URLs still
/// go to this Mac's browser. The click itself arrives as `.cmdClickFile`, which `TerminalPanes`
/// sends to `open`.
///
/// The ⌘-hover cursor is also the ⌘-click's gate (`GhosttySurfaceView.mouseDown`), and it is
/// synchronous, so it can't ask the host. It decides from the word alone
/// (`TerminalLinkOpener.looksLikeRemotePath`), and the click asks the host. Gating on a cache
/// of the host's answers regressed on every review of #254: it lost the click made straight
/// after pressing ⌘, took every click during an outage, and let hung probes pile up.
@MainActor
final class RemotePaneLinks {
  private let access: TerminalTabAccess
  /// Opens a file the host has in the window's in-app viewer, as a preview of `target`'s.
  private let openFilePreview: @MainActor (FileDescriptor, TerminalTarget) -> Void

  /// How a remote pane reaches its host's files: through the router, which connects the host, since
  /// only a click asks and a click is a deliberate act. Swapped by tests.
  var remoteFiles: (RepositoryLocation) async throws -> FileProviding = {
    try await RepositoryRouter.shared.files(for: $0)
  }

  /// Each workroom's click in flight. The host can take seconds to answer (a reconnect, then a
  /// probe per candidate), so a newer click replaces the one before it: a slow answer must not
  /// retarget the preview after a faster one, or open a tab in a workroom that has gone.
  private var opens: [TerminalTarget.ID: Task<Void, Never>] = [:]

  init(
    access: TerminalTabAccess,
    openFilePreview: @escaping @MainActor (FileDescriptor, TerminalTarget) -> Void
  ) {
    self.access = access
    self.openFilePreview = openFilePreview
  }

  /// Point a remote pane's ⌘-hover and link opening at its host.
  func wire(_ view: GhosttySurfaceView, tab tabID: TerminalTab.ID, target: TerminalTarget) {
    view.resolveCmdHoverFile = { [weak self] word in
      TerminalLinkOpener.looksLikeRemotePath(
        word, cwd: self?.hostCwd(of: tabID, in: target.id), root: target.path)
    }
    view.onOpenURL = { [weak self] url in
      if TerminalLinkOpener.isSystemHandledURL(url) {
        NSWorkspace.shared.open(url)
      } else {
        self?.open(TerminalLinkOpener.remoteLink(from: url), tab: tabID, target: target)
      }
      return true
    }
  }

  private func hostCwd(of tabID: TerminalTab.ID, in target: TerminalTarget.ID) -> String? {
    access.state(tabID, target)?.hostCwd
  }

  /// Open what `word` names on the host, from the pane `tabID`.
  func open(_ word: String, tab tabID: TerminalTab.ID, target: TerminalTarget) {
    let cwd = hostCwd(of: tabID, in: target.id)
    opens[target.id]?.cancel()
    opens[target.id] = Task { [weak self] in
      guard let self else { return }
      let file = await self.remoteFile(word, cwd: cwd, target: target)
      guard !Task.isCancelled else { return }
      self.opens[target.id] = nil
      guard let file else {
        // As `TerminalLinkOpener.handleOpenURL` does locally: a dropped click is otherwise
        // indistinguishable from a broken app.
        NSLog("Workroom: no file on the host for terminal link %@", word)
        return
      }
      // The pane that asked may have closed while the host answered. Tab IDs are never reused,
      // so a reopened workroom doesn't revive it.
      guard self.access.holds(tabID, target.id) else { return }
      self.openFilePreview(FileDescriptor(path: file.path, isPreview: true), target)
    }
  }

  /// The first of `word`'s candidates that is a file on the host, or nil. A read capped at one byte
  /// is the probe: it answers `.tooLarge` for any longer file without sending it, and fails for
  /// anything missing, refused or outside the workroom. A candidate written with a `..` is
  /// resolved on the host first (#327), so `link/../file.rb` is the file beside the link's target.
  func remoteFile(_ word: String, cwd: String?, target: TerminalTarget) async
    -> TerminalLinkOpener.PathCandidate?
  {
    guard let location = target.remoteLocation else { return nil }
    let candidates = TerminalLinkOpener.remoteCandidates(for: word, cwd: cwd, root: target.path)
    guard !candidates.isEmpty, let files = try? await remoteFiles(location) else { return nil }
    for candidate in candidates {
      var path = candidate.path
      do {
        if let onHost = candidate.onHost {
          do {
            path = try await files.resolve(path: onHost)
          } catch FileServiceError.failed(let message)
            where message == DaemonFileProvider.unknownMethod
          {
            // A daemon from before `resolve`: probe the lexical path, as every daemon did before
            // #327. Any other failure (busy, unreadable, a loop) skips the candidate below, since
            // the lexical path is the wrong file whenever the host's answer would differ.
          } catch FileServiceError.failed(let message)
            where message.hasPrefix(DaemonFileProvider.resolveTimedOut)
            || message == DaemonFileProvider.resolveWalksBusy
          {
            // The path walk hung on a mount, or earlier ones still are (#334). The other
            // candidates would resolve the same prefix or open through the same link, so nothing
            // more in this click goes to the host.
            NSLog("Workroom: resolving %@ on the host: %@", onHost, message)
            return nil
          }
        }
        let found = TerminalLinkOpener.PathCandidate(
          path: path, line: candidate.line, column: candidate.column)
        do {
          _ = try await files.read(path: path, symlinks: .followWithinRoot, maxBytes: 1)
        } catch FileServiceError.tooLarge {} catch FileServiceError.failed(let message)
          where message.hasPrefix(DaemonFileProvider.readOpenTimedOut)
          || message == DaemonFileProvider.filesystemOperationsBusy
        {
          // Another candidate could open through the same hung mount, so don't spend another
          // deadline or leave another filesystem worker behind for this click.
          NSLog("Workroom: opening %@ on the host: %@", path, message)
          return nil
        }
        return found
      } catch is FileServiceError {
        // About this path: missing, refused, or an error reading it (too long, not a directory
        // on the way). The next candidate, `file.rb` from `file.rb:12`, may still be there. An
        // daemon turning reads away as busy lands here too, and costs only the remaining probes.
        continue
      } catch {
        // The host or its connection, not the candidate: the next one would fail the same way.
        NSLog("Workroom: probing the host for %@: %@", candidate.path, "\(error)")
        return nil
      }
    }
    return nil
  }
}
