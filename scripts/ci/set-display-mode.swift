// Raises the main display to its largest mode, for nightly-uitests.yml: a hosted macOS runner
// boots at 1024x768, which clamps the UI-test fixture's 1450x780 windows and refuses every split
// (the Tart VM that `make app-uitest-vm` uses is 1920x1200). Prints every mode the display
// offers and the mode before and after, so a run that cannot go larger shows why.
//
//   swift scripts/ci/set-display-mode.swift [--dry-run]
//
// Exits 0 when the display ends at least MIN_WIDTH x MIN_HEIGHT (default 1920x1080), else 1.
import CoreGraphics
import Foundation

let dryRun = CommandLine.arguments.contains("--dry-run")
let env = ProcessInfo.processInfo.environment
let minWidth = Int(env["MIN_WIDTH"] ?? "") ?? 1920
let minHeight = Int(env["MIN_HEIGHT"] ?? "") ?? 1080

func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)x\(mode.height) (pixels \(mode.pixelWidth)x\(mode.pixelHeight), "
        + "\(mode.refreshRate) Hz, usable for desktop: \(mode.isUsableForDesktopGUI()))"
}

let display = CGMainDisplayID()
guard let current = CGDisplayCopyDisplayMode(display) else {
    print("No mode for the main display \(display)")
    exit(1)
}
print("Main display \(display), current mode: \(describe(current))")

// The duplicate low-resolution option lists the non-HiDPI variants too, as displayplacer does.
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
print("Available modes (\(modes.count)):")
for mode in modes {
    print("  \(describe(mode))")
}

// The largest desktop mode in points, then the one with more pixels behind it (1x over 2x is
// what keeps the point size up; a 2x mode of the same pixels halves it).
let best = modes.filter { $0.isUsableForDesktopGUI() }.max { lhs, rhs in
    (lhs.width * lhs.height, lhs.pixelWidth) < (rhs.width * rhs.height, rhs.pixelWidth)
}

if let best, best.width * best.height > current.width * current.height {
    if dryRun {
        print("Would switch to: \(describe(best))")
    } else {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        if err == .success {
            err = CGConfigureDisplayWithDisplayMode(config, display, best, nil)
        }
        if err == .success {
            err = CGCompleteDisplayConfiguration(config, .permanently)
        } else {
            CGCancelDisplayConfiguration(config)
        }
        print("Switching to \(describe(best)): \(err == .success ? "done" : "failed (\(err.rawValue))")")
    }
} else {
    print("No larger desktop mode than the current one")
}

let after = CGDisplayCopyDisplayMode(display)!
let bounds = CGDisplayBounds(display)
print("Main display now: \(describe(after)), bounds \(Int(bounds.width))x\(Int(bounds.height))")
if after.width < minWidth || after.height < minHeight {
    print("Below \(minWidth)x\(minHeight)")
    exit(1)
}
