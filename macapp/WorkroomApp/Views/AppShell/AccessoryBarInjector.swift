import SwiftUI

/// Hosts the window's title-bar bar (`RootView`'s leading controls, workroom tabs and trailing
/// controls) in the `.left` titlebar accessory, and re-injects the environment objects it reads:
/// the accessory is a separate AppKit hosting tree, so nothing crosses into it on its own.
///
/// Its own view so the objects only the bar needs are observed here, not by `RootView`: the
/// updater (the "Update" pill) and the notification list would otherwise re-run the whole window
/// body on every publish (`RootInvalidationTests`). Each publish still re-runs this, which hands the
/// accessory a fresh root as `RootView` re-running did, so the bar keeps the transparency
/// `TitlebarAccessoryHost` re-asserts on every update.
struct AccessoryBarInjector: ViewModifier {
  #if DEBUG
    /// How many times the body has run, read by `RootInvalidationTests`.
    static var bodyPasses = 0
  #endif
  let store: AppStore
  /// The bar, built by `RootView` from the selection, the tab drag and the dialog dim it owns.
  let bar: AnyView
  @EnvironmentObject private var updater: Updater
  @EnvironmentObject private var runCommands: RunCommands
  @EnvironmentObject private var notifications: NotificationCenterStore

  func body(content: Content) -> some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    return content.background(
      TitlebarAccessoryHost {
        bar
          .environmentObject(store)
          .environmentObject(store.modals)
          .environmentObject(store.runCommand)
          .environmentObject(runCommands)
          .environmentObject(store.projectStore)
          .environmentObject(store.vcsStatus)
          .environmentObject(store.lifecycle)
          .environmentObject(notifications)
          .environmentObject(updater)
      })
  }
}
