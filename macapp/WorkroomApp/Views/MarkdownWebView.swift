import AppKit
import DesignSystem
import SwiftUI
import WebKit

/// Read-only rendered-Markdown view (preview mode of the file viewer). Hosts a `WKWebView` that
/// loads a bundled offline template (`Resources/markdown/template.html`) and drives it with the
/// file's Markdown source. Unlike the old `NSAttributedString` renderer this supports GFM **tables**,
/// task lists, and **mermaid diagrams** — the page runs bundled `marked` + `DOMPurify` + `mermaid`,
/// all `file:`-local with a strict CSP, so nothing reaches the network.
///
/// The Markdown is untrusted workroom content, so it is defended in depth: DOMPurify strips any
/// executable HTML before it hits the DOM, the CSP blocks remote script/connect/frame loads, and the
/// navigation delegate lets only `http`/`https`/`mailto` links open (in the user's browser) — every
/// other scheme, and any attempt to navigate the frame away from the template, is dropped.
struct MarkdownWebView: NSViewRepresentable {
  /// The raw Markdown source to render.
  let markdown: String
  let tokens: ThemeTokens
  /// The theme generation; a change recolours the page (CSS variables + mermaid theme) in place.
  let generation: Int
  /// Called once, on the main actor, when the first Markdown render has actually *painted*.
  ///
  /// Booting the page is not instant — the bundled scripts are ~3.5 MB (mermaid alone is 3.4 MB and
  /// ~104 ms of the ~117 ms script parse), on top of spawning a fresh WebContent process. Until
  /// `didFinish` lands and `__render` runs, the web view is an empty themed rectangle, which read as
  /// "the panel is blank for a short while". The owner uses this to cover that window with a loader.
  var onFirstRender: () -> Void = {}

  /// The bundled template and the directory the web assets live in (read-access scope for the load).
  static let assetDirectory = Bundle.main.url(
    forResource: "markdown", withExtension: nil, subdirectory: nil)
  static let templateURL = assetDirectory?.appendingPathComponent("template.html")

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    // The pool's page is already booted (or booting), so the preview skips WebKit's page load and,
    // for the first preview after launch, its WebContent spawn. Its theme lands through
    // `applyTheme` below, behind `PlainFileViewer`'s loader, so its stale boot colours never show.
    let pooled = MarkdownWebViewPool.shared.take()
    let webView = pooled?.webView ?? Self.makeWebView(bootThemeVars: themeVars(tokens))
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = tokens.nsBg  // no white flash before first paint
    context.coordinator.webView = webView
    context.coordinator.templateURL = Self.templateURL
    context.coordinator.assetDirectory = Self.assetDirectory
    context.coordinator.onFirstRender = onFirstRender
    context.coordinator.pendingMarkdown = markdown
    context.coordinator.pendingThemeVars = themeVars(tokens)

    if pooled == nil {
      Self.loadTemplate(webView)
    } else if pooled?.isLoaded == true {
      // Next turn, once SwiftUI has put the view in its window. Rendered here instead, before that,
      // a 370 KB file took ~50 ms longer to paint (measured with `make app-bench-markdown`).
      // Skipped if the preview closed first and its page went back to the pool.
      let coordinator = context.coordinator
      Task { @MainActor in
        if webView.navigationDelegate === coordinator { coordinator.pageDidLoad() }
      }
    }
    return webView
  }

  /// The page goes back to the pool for the next preview, unless its WebContent process died.
  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    guard !coordinator.processTerminated else { return }
    MarkdownWebViewPool.shared.give(webView)
  }

  /// A web view configured for an untrusted preview, not yet loaded. With `bootThemeVars`, the
  /// theme's CSS variables are set at document start, before styles.css first paints: without them
  /// the page paints one frame with the stylesheet's light `--bg` default (a white flash over the
  /// panel in dark mode) until `didFinish`'s applyTheme lands.
  static func makeWebView(bootThemeVars: [String: String]?) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()  // no cache/cookies for untrusted content
    if let vars = bootThemeVars, let boot = themeBootScript(vars) {
      config.userContentController.addUserScript(boot)
    }
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.setValue(false, forKey: "drawsBackground")  // let the page's themed background show
    return webView
  }

  static func loadTemplate(_ webView: WKWebView) {
    if let template = templateURL, let dir = assetDirectory {
      webView.loadFileURL(template, allowingReadAccessTo: dir)
    }
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    webView.underPageBackgroundColor = tokens.nsBg
    let coordinator = context.coordinator
    coordinator.onFirstRender = onFirstRender  // the closure captures a fresh view each update
    // Re-render only when the source actually changed; recolour when the theme generation moves.
    if markdown != coordinator.appliedMarkdown {
      coordinator.render(markdown)
    }
    if generation != coordinator.appliedGeneration {
      coordinator.appliedGeneration = generation
      coordinator.applyTheme(themeVars(tokens))
    }
  }

  /// The theme colours pushed into the page's CSS variables (and the mermaid theme name). Each is a
  /// `rgba()` string so alpha-based tokens (borders, code fill) composite over the page background.
  private func themeVars(_ t: ThemeTokens) -> [String: String] {
    [
      "bg": Self.css(t.nsBg),
      "fg": Self.css(t.nsFg),
      "muted": Self.css(NSColor(t.fgMuted)),
      "dim": Self.css(NSColor(t.fgDim)),
      "border": Self.css(NSColor(t.border)),
      "code-bg": Self.css(NSColor(t.surface)),
      "table-header-bg": Self.css(NSColor(t.surface)),
      "accent": Self.css(NSColor(t.accent)),
      "accent-soft": Self.css(NSColor(t.accentSoft)),
      "mermaidTheme": t.colorScheme == .dark ? "dark" : "default",
    ]
  }

  /// A user script that writes the theme's CSS variables onto `documentElement` at document start —
  /// before `styles.css` paints — so the first frame is themed instead of flashing the stylesheet's
  /// light `--bg` default. Skips `mermaidTheme` (not a CSS var; mermaid is themed in JS). Mirrors the
  /// variable-setting half of `render.js`'s `__applyTheme`, but runs pre-paint and needs no bundled JS.
  private static func themeBootScript(_ vars: [String: String]) -> WKUserScript? {
    guard let data = try? JSONSerialization.data(withJSONObject: vars),
      let json = String(data: data, encoding: .utf8)
    else { return nil }
    let source = """
      (function () {
        var v = \(json), s = document.documentElement.style;
        for (var k in v) { if (k !== "mermaidTheme") s.setProperty("--" + k, v[k]); }
      })();
      """
    return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
  }

  /// An `NSColor` as a CSS `rgba(r, g, b, a)` string (sRGB, 0–255 channels). Falls back to the
  /// foreground-ish grey if the colour can't be resolved into sRGB.
  private static func css(_ color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { return "rgba(128,128,128,1)" }
    let r = Int((c.redComponent * 255).rounded())
    let g = Int((c.greenComponent * 255).rounded())
    let b = Int((c.blueComponent * 255).rounded())
    let a = String(format: "%.3f", c.alphaComponent)
    return "rgba(\(r), \(g), \(b), \(a))"
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    var templateURL: URL?
    /// The bundled markdown asset directory; in-frame navigation is scoped to files under it.
    var assetDirectory: URL?
    /// Loaded flag + the values to flush once the template's `didFinish` fires (JS isn't callable
    /// before then). After load, `render`/`applyTheme` run immediately.
    private var isLoaded = false
    var pendingMarkdown: String?
    var pendingThemeVars: [String: String]?
    /// What has actually been pushed to the page, so `updateNSView` doesn't re-render needlessly.
    var appliedMarkdown: String?
    var appliedGeneration = Int.min
    /// Fired once, after the first render paints — see `MarkdownWebView.onFirstRender`.
    var onFirstRender: () -> Void = {}
    private var hasReportedFirstRender = false

    /// How long the render round-trip waits for an animation frame before giving up on paint timing
    /// and reporting anyway. Only reached when WebKit isn't animating the view (not displayed), so it
    /// bounds the loader's lifetime rather than adding delay to the normal path.
    static let paintFallbackMilliseconds = 250

    /// Web/mail schemes a rendered link may open in the user's browser. A workroom Markdown file is
    /// untrusted, so `file:`/`javascript:`/custom-scheme links must never navigate or reach an app.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// The gate's decision for a navigation, with no side effects — so the security logic can be unit
    /// tested without a live `WKWebView`/`WKNavigationAction`. Applied by `decidePolicyFor` below.
    enum NavigationDecision: Equatable {
      case allow  // keep it in the frame
      case openExternally(URL)  // hand to the user's browser, cancel the in-frame load
      case cancel  // drop it
    }

    /// Set when WebKit reports the page's WebContent process gone; such a page is not reused.
    private(set) var processTerminated = false

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      processTerminated = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      pageDidLoad()
    }

    /// The template is loaded: flush what was queued. Called from `didFinish`, or straight away for
    /// a page the pool hands over already loaded.
    func pageDidLoad() {
      isLoaded = true
      if let vars = pendingThemeVars {
        applyTheme(vars)
        pendingThemeVars = nil
      }
      if let md = pendingMarkdown {
        render(md)
        pendingMarkdown = nil
      }
    }

    func render(_ markdown: String) {
      appliedMarkdown = markdown
      guard isLoaded, let webView else {
        pendingMarkdown = markdown
        return
      }
      // The source travels as a `callAsyncJavaScript` *argument*, not interpolated into the script —
      // WebKit marshals it, so no JSON-in-string escaping of untrusted file content is involved.
      //
      // Report failures instead of swallowing them: a silent `__render` throw is indistinguishable
      // from a file that renders blank/short, which is exactly how a truncating render bug hides.
      //
      // The double `requestAnimationFrame` is what makes `onFirstRender` mean *painted* rather than
      // *in the DOM*: the first callback runs before the frame that includes the new content, the
      // second after it. Hiding the loader on DOM-insertion alone would uncover one blank frame.
      //
      // The `setTimeout` is not belt-and-braces, it is load-bearing. WebKit does not run animation
      // frames for a web view that isn't being displayed — zero-sized, off-screen, in an occluded
      // window, or in a pane the user has switched away from. Waiting on rAF alone would leave the
      // loader spinning forever in exactly those cases (caught by MarkdownFirstRenderTests, where the
      // web view has no window at all). Whichever fires first wins; `resolve` is idempotent.
      webView.callAsyncJavaScript(
        """
        window.__render(source);
        await new Promise((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(resolve));
          setTimeout(resolve, \(Self.paintFallbackMilliseconds));
        });
        """,
        arguments: ["source": markdown], in: nil, in: .page
      ) { [weak self] result in
        switch result {
        case .failure(let error):
          NSLog("MarkdownWebView: render failed — \(error.localizedDescription)")
        case .success:
          self?.reportFirstRender()
        }
      }
    }

    /// Fire `onFirstRender` exactly once. Later renders (file edits, theme re-render) must not
    /// re-trigger it — the loader belongs to the initial boot, not to every subsequent update.
    private func reportFirstRender() {
      guard !hasReportedFirstRender else { return }
      hasReportedFirstRender = true
      onFirstRender()
    }

    func applyTheme(_ vars: [String: String]) {
      guard isLoaded, let webView else {
        pendingThemeVars = vars
        return
      }
      guard let data = try? JSONSerialization.data(withJSONObject: vars),
        let json = String(data: data, encoding: .utf8)
      else { return }
      webView.evaluateJavaScript("window.__applyTheme(\(json));", completionHandler: nil)
    }

    /// Gate navigations. The initial template load (and in-page `#anchor` scrolls) stay in the frame;
    /// a clicked link opens externally only for allowlisted schemes; everything else is dropped.
    /// The handler's type must match WebKit's exactly: a near miss is not a witness, so WebKit never
    /// calls this and every navigation goes through ungated.
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      switch Self.navigationDecision(
        url: navigationAction.request.url,
        isLinkActivated: navigationAction.navigationType == .linkActivated,
        templateURL: templateURL, assetDirectory: assetDirectory)
      {
      case .allow:
        decisionHandler(.allow)
      case .openExternally(let url):
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      case .cancel:
        decisionHandler(.cancel)
      }
    }

    /// Pure navigation-gate policy (no side effects). `isLinkActivated` is
    /// `navigationType == .linkActivated`; `templateURL` / `assetDirectory` are the bundled page and
    /// its read-access directory. Unit-tested in `MarkdownWebViewNavigationTests`.
    static func navigationDecision(
      url: URL?, isLinkActivated: Bool, templateURL: URL?, assetDirectory: URL?
    ) -> NavigationDecision {
      guard let url else { return .cancel }
      if !isLinkActivated {
        // Template load / same-document fragment scroll — allow only our own bundled asset files.
        return isBundledAsset(url, assetDirectory: assetDirectory) ? .allow : .cancel
      }
      // In-page anchor: same file, differing only by fragment — allow the scroll.
      if url.isFileURL, let template = templateURL,
        url.deletingFragment() == template.deletingFragment()
      {
        return .allow
      }
      // A real outbound link opens in the user's browser, but only for web/mail schemes.
      if let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) {
        return .openExternally(url)
      }
      return .cancel
    }

    /// True if `url` is a `file:` URL inside the bundled markdown asset directory (the template and
    /// its sibling JS/CSS). Scopes in-frame navigation to our own assets, not any local file.
    static func isBundledAsset(_ url: URL, assetDirectory: URL?) -> Bool {
      guard url.isFileURL, let dir = assetDirectory else { return false }
      let target = url.deletingFragment().standardizedFileURL.path
      let base = dir.standardizedFileURL.path
      return target == base || target.hasPrefix(base + "/")
    }
  }
}

/// Keeps one booted preview page ready. A fresh `WKWebView` costs ~100 ms to load the template
/// before it can render, and the first one in the app 0.4–0.9 s more to spawn its WebContent process;
/// a page taken from here renders at once. Prewarmed at launch, refilled whenever its page is taken,
/// and a closed preview's page comes back here when the pool is empty or still booting its own.
///
/// Reuse means a later file can render in the process an earlier file's preview used. Every file is
/// equally untrusted and goes through the same DOMPurify pass and CSP, the page has no cookies or
/// network, and a returned page is emptied before it is handed out again.
@MainActor
final class MarkdownWebViewPool: NSObject, WKNavigationDelegate {
  static let shared = MarkdownWebViewPool()

  /// The page the next preview gets, and whether its template has finished loading.
  private(set) var spare: WKWebView?
  private(set) var spareIsLoaded = false

  /// Starts booting the spare page, if there isn't one.
  func prewarm() {
    guard spare == nil else { return }
    let webView = MarkdownWebView.makeWebView(bootThemeVars: nil)
    webView.navigationDelegate = self
    spare = webView
    spareIsLoaded = false
    MarkdownWebView.loadTemplate(webView)
  }

  /// The spare page, loaded or still loading (the caller becomes its navigation delegate either
  /// way, so a load still in flight reaches it), and a new spare starts booting behind it.
  func take() -> (webView: WKWebView, isLoaded: Bool)? {
    guard let webView = spare else { return nil }
    let isLoaded = spareIsLoaded
    spare = nil
    prewarm()
    return (webView, isLoaded)
  }

  /// Takes back a closed preview's page, emptied, when it beats what the pool holds: nothing, or a
  /// spare still booting. Otherwise the page is let go.
  func give(_ webView: WKWebView) {
    guard spare == nil || !spareIsLoaded else { return }
    webView.navigationDelegate = self
    webView.evaluateJavaScript(
      "window.__render(''); window.scrollTo(0, 0); getSelection().removeAllRanges();",
      completionHandler: nil)
    spare = webView
    spareIsLoaded = true
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if webView === spare { spareIsLoaded = true }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if webView === spare { spare = nil }
  }

  /// The same gate a preview applies, for the template load and anything after it while pooled.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let decision = MarkdownWebView.Coordinator.navigationDecision(
      url: navigationAction.request.url,
      isLinkActivated: navigationAction.navigationType == .linkActivated,
      templateURL: MarkdownWebView.templateURL, assetDirectory: MarkdownWebView.assetDirectory)
    decisionHandler(decision == .allow ? .allow : .cancel)
  }
}

extension URL {
  /// The URL with any `#fragment` removed — for comparing an in-page anchor link to the page itself.
  fileprivate func deletingFragment() -> URL {
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
      return self
    }
    components.fragment = nil
    return components.url ?? self
  }
}
