/// What a content pane shows for the keyed content it reads: the content, or why there is none.
///
/// One shape for every reader that classifies what it got (`DiffLoader`, `FileContentLoader`):
/// still reading, the content itself, or one of the reasons it cannot be shown — nothing there, not
/// text, too big to lay out, or the read failed with a short human-readable reason.
enum LoadState<Content> {
  case loading
  case loaded(Content)
  case empty
  case binary
  case tooLarge
  case failed(String)
}

extension LoadState: Equatable where Content: Equatable {}
extension LoadState: Sendable where Content: Sendable {}
