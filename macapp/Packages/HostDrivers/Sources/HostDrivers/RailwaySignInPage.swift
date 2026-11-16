/// The page the loopback redirect (ADR 0073) shows in the browser once Railway sends it back:
/// Workroom's icon joined to Railway by a line that breaks when the sign-in didn't finish. It is one
/// self-contained document (system fonts, inline SVG, no scripts) because nothing else is served.
public enum RailwaySignInPage {
  /// How the sign-in ended, as the browser is told.
  public enum Outcome: Sendable, Equatable {
    /// The tokens were exchanged and kept.
    case connected
    /// The user declined on Railway's page.
    case declined
    /// Anything else: a forged state, a failed exchange or keep, a cancelled sign-in.
    case failed
  }

  static func html(_ outcome: Outcome) -> String {
    let check = #"<path d="M5 12.5l4.5 4.5L19 7.5" stroke-linejoin="round"/>"#
    let cross = #"<path d="M6 6l12 12M18 6L6 18"/>"#
    let notConnected = "Workroom isn't connected to Railway"
    let (title, detail, mark, body) =
      switch outcome {
      case .connected:
        (
          "Workroom is connected to Railway", "You can close this tab and go back to Workroom.",
          check, "<body>"
        )
      case .declined:
        (
          notConnected,
          "Railway didn't approve the sign-in. Close this tab and try again from Workroom.",
          cross, "<body class=\"off\">"
        )
      case .failed:
        (
          notConnected,
          "Workroom couldn't finish signing in to Railway. Close this tab and try again from Workroom.",
          cross, "<body class=\"off\">"
        )
      }
    return """
      <!doctype html><html lang="en"><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta name="color-scheme" content="light dark"><title>\(title)</title>
      <style>
      :root{--bg:#fff;--fg:#17181c;--muted:#5d6170;--line:#d9dbe1;--tile:#f3f4f6;--ok:#1f9d55;--bad:#c2410c}
      @media (prefers-color-scheme:dark){:root{--bg:#191b20;--fg:#eceef2;--muted:#9a9fac;--line:#2c2e36;--tile:#121317;--ok:#3ccf7c;--bad:#fb8a4c}}
      *{box-sizing:border-box}
      body{margin:0;min-height:100vh;display:grid;place-items:center;align-content:center;gap:22px;padding:24px 16px 72px;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;text-align:center}
      .link{display:flex;align-items:center}
      .link>svg{display:block;flex:none}
      .tile{width:64px;height:64px;border-radius:16px;display:grid;place-items:center;font-weight:600;font-size:13px;border:1px solid var(--line);background:var(--tile)}
      .line{width:84px;height:2px;position:relative;background:var(--ok)}
      .off .line{background:repeating-linear-gradient(90deg,var(--bad) 0 6px,transparent 6px 11px)}
      .knot{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:26px;height:26px;border-radius:50%;display:grid;place-items:center;color:#fff;background:var(--ok);box-shadow:0 0 0 4px var(--bg)}
      .off .knot{background:var(--bad)}
      h1{margin:0 0 4px;font-size:20px;letter-spacing:-.01em;text-wrap:balance}
      p{margin:0;color:var(--muted);font-size:14px;max-width:44ch}
      footer{position:fixed;left:0;right:0;bottom:18px;font-size:12px;color:var(--muted)}
      </style>
      \(body)
      <div class="link">
      <svg width="64" height="64" viewBox="0 0 100 100" role="img" aria-label="Workroom"><rect width="100" height="100" rx="23" fill="#000"/><g fill="#ffe01b"><rect x="13.5" y="13.5" width="20" height="20"/><rect x="40" y="13.5" width="20" height="20"/><rect x="66.5" y="13.5" width="20" height="20"/><rect x="13.5" y="40" width="20" height="20"/><rect x="66.5" y="40" width="20" height="20"/><rect x="13.5" y="66.5" width="20" height="20"/><rect x="40" y="66.5" width="20" height="20"/><rect x="66.5" y="66.5" width="20" height="20"/></g></svg>
      <div class="line"><div class="knot"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" aria-hidden="true">\(mark)</svg></div></div>
      <div class="tile">Railway</div>
      </div>
      <div><h1>\(title)</h1><p>\(detail)</p></div>
      <footer>Workroom by Codaset</footer>
      </body></html>
      """
  }
}
