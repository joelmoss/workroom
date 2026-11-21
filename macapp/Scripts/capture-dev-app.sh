#!/bin/sh
#
# Captures this checkout's running dev app as it really looks on screen: the screen region under its
# main window, so a translucent window (Glass) shows what is behind it. A window capture (⌘⇧4 then
# Space, `screencapture -l`) holds only the window's own pixels, and the VM runs a different macOS
# than the host, so neither shows translucency or Liquid Glass as the owner sees it.
#
# It brings the app forward for about a second, captures, and gives the front back to whichever app
# had it. It drives the owner's screen, so an agent asks before running it, every time.
#
# Usage: capture-dev-app.sh <bundle-id> <out.png>
#   `make app-capture` passes this checkout's id (`make app-identity`) and CAPTURE as the path.
# Exits non-zero when the app isn't running or has no window on screen. Needs Screen Recording
# for the terminal running it, and the command sandbox off.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: capture-dev-app.sh <bundle-id> <out.png>" >&2
  exit 2
fi
bundle_id="$1"
out="$2"

# Prints the previous front app's pid, then the app's main window frame as x,y,w,h in screen points,
# top-left origin (what `screencapture -R` takes). JXA reaches CoreGraphics' window list, which
# needs no Accessibility grant, unlike System Events' window properties.
frame="$(osascript -l JavaScript - "$bundle_id" <<'EOF'
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
function run(argv) {
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
  if (Number(apps.count) === 0) throw new Error('not running: ' + argv[0]);
  const app = apps.objectAtIndex(0);
  const previous = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  app.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
  for (let i = 0; i < 30 && !app.active; i++) delay(0.1);
  delay(0.6); // the window server finishes compositing the newly front window
  const list = ObjC.deepUnwrap(
    ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
  let best = null;
  for (const w of list) {
    if (w.kCGWindowOwnerPID !== app.processIdentifier || w.kCGWindowLayer !== 0) continue;
    const b = w.kCGWindowBounds;
    if (!best || b.Width * b.Height > best.Width * best.Height) best = b;
  }
  if (!best) throw new Error('no window on screen for ' + argv[0]);
  return [previous.processIdentifier, [best.X, best.Y, best.Width, best.Height].join(',')].join(' ');
}
EOF
)"
previous_pid="${frame%% *}"
region="${frame#* }"

status=0
screencapture -x -R "$region" "$out" || status=$?

# Give the front back, whatever the capture did.
osascript -l JavaScript - "$previous_pid" <<'EOF' >/dev/null 2>&1 || true
ObjC.import('AppKit');
function run(argv) {
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
  if (app && !app.isNil()) app.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
}
EOF

if [ "$status" -ne 0 ]; then
  echo "capture-dev-app: screencapture failed ($status); does the terminal have Screen Recording?" >&2
  exit "$status"
fi
echo "Captured ${bundle_id} (${region}) to ${out}"
