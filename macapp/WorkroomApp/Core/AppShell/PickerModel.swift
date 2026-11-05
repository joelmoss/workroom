import Foundation

/// Generic filter + keyboard-highlight core shared by every searchable list-picker (New Workroom's
/// `ProjectPickerModel`, Open Workroom's `OpenPickerModel`, …). Pure value logic — no AppKit /
/// SwiftUI — so every branch runs headless. The view owns the `query` / `highlight` `@State`; this
/// just computes. Mirrors `EdgeRevealReducer` / `TabReorderMath`.
///
///   type ──► filtered(items, query, key:)  → the visible rows
///   ↑/↓  ──► move(highlight, by:, count:)   → clamped index, NO side effects
///   ⏎    ──► selection(filtered, highlight) → the row to act on, or nil (empty / out-of-range guard)
///
/// `key` projects each item to the string the query matches against, so the same logic serves a
/// list of `Project` (match on `displayName`) or `OpenTarget` (match on title + project name).
enum PickerModel {
  /// Items whose `key` contains `query` (case-insensitive, whitespace-trimmed). An empty query
  /// returns every item in the original order.
  static func filtered<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    return items.filter { key($0).localizedCaseInsensitiveContains(q) }
  }

  /// Fuzzy, multi-token variant of `filtered`. `query` is split on whitespace into tokens; an item
  /// matches only when **every** token is a case-insensitive *subsequence* of its `key` (tokens are
  /// AND-ed; their order relative to each other doesn't matter, but a token's own characters must
  /// appear in order). An empty / whitespace-only query returns everything, in original order.
  ///
  /// With a `key` of `"projectName title"`, this matches across the two fields: e.g. "proapp" hits
  /// project "projectA"'s workroom "apple" (pro→projectA, app→apple), and "A app" hits it via two
  /// tokens.
  static func fuzzyFiltered<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    return items.filter { fuzzyMatches(key($0), query: q) }
  }

  /// True when every whitespace-separated token of `query` is a case-insensitive subsequence of
  /// `candidate`. An empty / whitespace-only query matches.
  static func fuzzyMatches(_ candidate: String, query: String) -> Bool {
    let tokens = query.split(whereSeparator: { $0.isWhitespace })
    guard !tokens.isEmpty else { return true }
    let haystack = candidate.lowercased()
    return tokens.allSatisfy { isSubsequence(String($0).lowercased(), of: haystack) }
  }

  /// Case-insensitivity is the caller's job (both args pre-lowercased): are all of `needle`'s
  /// characters present in `haystack` in order? Empty needle is trivially a subsequence.
  private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var next = needle.startIndex
    guard next != needle.endIndex else { return true }
    for ch in haystack where ch == needle[next] {
      next = needle.index(after: next)
      if next == needle.endIndex { return true }
    }
    return false
  }

  /// Clamp `index` into a list of `count` items. Returns 0 for an empty list so callers always have a
  /// safe value; the `selection` guard still prevents acting on an empty list.
  static func clamped(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index, 0), count - 1)
  }

  /// Move `highlight` by `delta`, clamped to `[0, count-1]`. No side effects — ↑/↓ only move the
  /// selection; the action fires on click/Return, never on a keystroke.
  static func move(highlight: Int, by delta: Int, count: Int) -> Int {
    clamped(highlight + delta, count: count)
  }

  /// The item Return/click should act on: `filtered[highlight]`, or nil when the list is empty or
  /// the index is out of range — the guard that makes Return a no-op on an empty/no-match list.
  static func selection<T>(filtered: [T], highlight: Int) -> T? {
    guard filtered.indices.contains(highlight) else { return nil }
    return filtered[highlight]
  }
}
