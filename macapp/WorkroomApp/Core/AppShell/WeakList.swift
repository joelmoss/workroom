/// Objects held weakly, in the order they first registered: how the app-scoped owners list the
/// windows they serve (ADR 0068). A window that has gone drops out by itself.
///
/// `Element` is a class or a class-bound protocol. It is not constrained to `AnyObject` because a
/// protocol's existential (`any LifecycleWindow`) doesn't satisfy that constraint, so each element is
/// held as the object it is.
struct WeakList<Element> {
  private struct Entry {
    weak var object: AnyObject?
  }

  private var entries: [Entry] = []

  /// Adds `element` unless it is already here, where it keeps its place.
  mutating func insert(_ element: Element) {
    let object = element as AnyObject
    entries.removeAll { $0.object == nil }
    guard !entries.contains(where: { $0.object === object }) else { return }
    entries.append(Entry(object: object))
  }

  mutating func remove(_ element: Element) {
    let object = element as AnyObject
    entries.removeAll { $0.object == nil || $0.object === object }
  }

  /// The ones still alive, in order.
  var elements: [Element] { entries.compactMap { $0.object as? Element } }
}
