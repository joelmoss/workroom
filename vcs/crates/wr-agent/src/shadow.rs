//! One name for the shadow terminal whether or not it is compiled in.
//!
//! `terminal-state` is off by default because it pulls a pinned Zig toolchain and a Ghostty
//! checkout into the build. Rather than scatter `#[cfg]` through the session layer — where it
//! would obscure the actual logic and rot the moment someone edits the wrong arm — the feature is
//! resolved exactly once, here. `session.rs` calls the same methods either way; without the
//! feature they do nothing and `replay()` returns no bytes, which is precisely the behaviour
//! before the shadow existed.

#[cfg(feature = "terminal-state")]
pub struct Shadow(Option<crate::terminal::ShadowTerminal>);

#[cfg(not(feature = "terminal-state"))]
pub struct Shadow;

#[cfg(feature = "terminal-state")]
impl Shadow {
    pub fn new(columns: u16, rows: u16) -> Shadow {
        Shadow(crate::terminal::ShadowTerminal::new(columns, rows))
    }

    /// Every byte the client receives also goes here. Cheap enough to do inline on the output
    /// path: it is the same parse the client's own terminal is doing anyway.
    pub fn write(&mut self, bytes: &[u8]) {
        if let Some(terminal) = self.0.as_mut() {
            terminal.write(bytes);
        }
    }

    pub fn resize(&mut self, columns: u16, rows: u16) {
        if let Some(terminal) = self.0.as_mut() {
            terminal.resize(columns, rows);
        }
    }

    /// What to send a client that has just attached, so it sees the session rather than a blank
    /// screen. Empty when there is nothing to show yet.
    pub fn replay(&self) -> Vec<u8> {
        self.0.as_ref().map(|t| t.replay()).unwrap_or_default()
    }

    /// What to keep on disk for this screen (`crate::screens`): `replay()` without the parser
    /// continuation.
    pub fn record(&self) -> Vec<u8> {
        self.0.as_ref().map(|t| t.record()).unwrap_or_default()
    }

    pub fn visible_text(&self) -> String {
        self.0
            .as_ref()
            .map(|t| t.visible_text())
            .unwrap_or_default()
    }
}

#[cfg(not(feature = "terminal-state"))]
impl Shadow {
    pub fn new(_columns: u16, _rows: u16) -> Shadow {
        Shadow
    }
    pub fn write(&mut self, _bytes: &[u8]) {}
    pub fn resize(&mut self, _columns: u16, _rows: u16) {}
    /// No shadow, so nothing to repaint: a reattaching client resumes the live stream, which is
    /// how the agent behaved before terminal state existed.
    pub fn replay(&self) -> Vec<u8> {
        Vec::new()
    }
    pub fn record(&self) -> Vec<u8> {
        Vec::new()
    }
    pub fn visible_text(&self) -> String {
        String::new()
    }
}
