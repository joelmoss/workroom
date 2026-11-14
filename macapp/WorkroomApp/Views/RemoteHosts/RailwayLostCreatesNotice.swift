import HostDrivers
import SwiftUI

/// "A Railway create may have left a sandbox" (`RailwayLostCreatesModel`): one notice per create
/// of this Mac's whose reply Railway never sent, with the sandboxes it may have made, read fresh
/// each time it shows. Workroom never guesses which was the create's: the user destroys the one
/// they know was (confirmed, since it destroys whatever is on it) or dismisses the notice. Shown in
/// a Railway workroom's Details pane and in Settings ▸ Remote Hosts ▸ Railway. Draws nothing while
/// there is none.
struct RailwayLostCreatesNotice: View {
  @ObservedObject private var model = RailwayLostCreatesModel.shared

  var body: some View {
    // Something always drawn: with nothing to show yet, an empty view never appears, so its
    // `.task` would never read the ledger.
    VStack(alignment: .leading, spacing: 12) {
      Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      ForEach(model.creates) { create in
        RailwayLostCreateNotice(create: create)
      }
    }
    .task { await model.refresh() }
  }
}

/// One lost create's notice.
private struct RailwayLostCreateNotice: View {
  let create: RailwayLostCreates.Create
  @ObservedObject private var model = RailwayLostCreatesModel.shared
  /// Nil until read, and while a read is under way.
  @State private var candidates: [RailwaySandbox]?
  @State private var problem: String?
  @State private var confirming: RailwaySandbox?
  @State private var busy = false
  /// Bumped to read the candidates again.
  @State private var reads = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("A Railway create may have left a sandbox", systemImage: "exclamationmark.triangle")
        .font(.caption.weight(.semibold))
        .accessibilityIdentifier("railway.lostCreate.title")
      Text(
        "A create of this Mac's asked Railway for a sandbox on "
          + "\(create.started.formatted(date: .abbreviated, time: .shortened)), and Railway's "
          + "answer never arrived. Railway may have made a sandbox that no workroom uses, which "
          + "bills until it is destroyed. Workroom can't tell which one it was, so it destroys "
          + "none on its own."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      candidateList
      if let problem {
        Text(problem).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("railway.lostCreate.problem")
      }
      HStack {
        Button("Check Again") { reads += 1 }
          .disabled(busy)
          .help("Ask Railway again which sandboxes this create may have made.")
          .accessibilityIdentifier("railway.lostCreate.checkAgain")
        Button("Dismiss") { dismiss() }
          .disabled(busy)
          .help(
            "Stop showing this notice, once you've checked Railway's dashboard yourself. Nothing "
              + "on Railway is destroyed."
          )
          .accessibilityIdentifier("railway.lostCreate.dismiss")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("railway.lostCreate")
    .task(id: reads) { await read() }
    .confirmationDialog(
      confirming.map { "Destroy Railway sandbox \($0.id)?" } ?? "Destroy the Railway sandbox?",
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      presenting: confirming
    ) { sandbox in
      Button("Destroy Sandbox", role: .destructive) { destroy(sandbox) }
      Button("Cancel", role: .cancel) { confirming = nil }
    } message: { _ in
      Text(
        "Destroy it only if this create made it. If a workroom on another Mac uses it, that "
          + "workroom's changes and commits that aren't pushed are lost. This can't be undone.")
    }
  }

  @ViewBuilder
  private var candidateList: some View {
    if let candidates {
      if candidates.isEmpty {
        Text(
          "Railway lists no sandbox made around then that a workroom here doesn't use. If you "
            + "find one on Railway's dashboard, destroy it there, then dismiss this."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("railway.lostCreate.none")
      } else {
        Text("Railway made these around then, and no workroom here uses them:")
          .font(.caption).foregroundStyle(.secondary)
        ForEach(candidates, id: \.id) { sandbox in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
              Text(sandbox.id).font(.caption.monospaced())
              if let made = sandbox.createdAt.flatMap(RailwayLostCreates.date) {
                Text("Made \(made.formatted(date: .omitted, time: .standard))")
                  .font(.caption2).foregroundStyle(.secondary)
              }
            }
            .help("A Railway sandbox this create may have made.")
            .accessibilityIdentifier("railway.lostCreate.candidate.\(sandbox.id)")
            Spacer(minLength: 0)
            Button("Destroy…") { confirming = sandbox }
              .disabled(busy)
              .help(
                "Destroy this Railway sandbox, if it was this create's. Everything on it is lost."
              )
              .accessibilityIdentifier("railway.lostCreate.destroy.\(sandbox.id)")
          }
        }
      }
    } else if problem == nil {
      ProgressView().controlSize(.small)
        .help("Asking Railway which sandboxes this create may have made.")
    }
  }

  private func read() async {
    candidates = nil
    problem = nil
    do {
      candidates = try await model.candidates(of: create)
    } catch is CancellationError {
    } catch {
      problem = error.localizedDescription
    }
  }

  private func destroy(_ sandbox: RailwaySandbox) {
    confirming = nil
    busy = true
    problem = nil
    Task {
      do {
        try await model.destroy(sandbox.id, of: create)
      } catch {
        problem = error.localizedDescription
        reads += 1
      }
      busy = false
    }
  }

  private func dismiss() {
    busy = true
    problem = nil
    Task {
      do { try await model.dismiss(create) } catch { problem = error.localizedDescription }
      busy = false
    }
  }
}
