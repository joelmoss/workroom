import SwiftUI

/// The "What's New" auto-check and the dialog it opens. Only the launch window runs it, so restored
/// ⌘N windows don't each pop the dialog. Silent: it opens straight to the notes when there are any.
///
/// Its own view so the service and the dialog's content stay out of `RootView`, which renders from
/// neither. `presented` mirrors whether the dialog is up, for `RootView`'s count of its view-local
/// sheets (`ModalState.auxSheetPresented`).
struct WhatsNewLaunchCheck: ViewModifier {
  let store: AppStore
  @Binding var presented: Bool
  @EnvironmentObject private var whatsNew: WhatsNewService
  /// The dialog's content, or nil when closed. Window-local so multiple windows never stack
  /// duplicate dialogs.
  @State private var sheet: WhatsNewSheetContent?

  func body(content: Content) -> some View {
    content
      .task {
        // Read when the check runs, not when the view is built: `attachWindow` gives a window the
        // launch role once it has one, after this body first runs.
        guard store.isRestoreWindow else { return }
        if let notes = await whatsNew.checkOnLaunch() {
          sheet = WhatsNewSheetContent(notes: notes)
        }
      }
      .sheet(item: $sheet) { notes in
        WhatsNewSheet(content: notes) { sheet = nil }
      }
      .onChange(of: sheet != nil) { _, shown in presented = shown }
  }
}
