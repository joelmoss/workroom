import AppKit
import Defaults
import DesignSystem
import SwiftUI

/// Settings ▸ Terminal's Font and Cursor sections: a live preview in the active theme, then the
/// font's family, weight, style, size and line height, and the cursor's shape and blink.
///
/// Each control writes its `Defaults` key, and `GhosttyApp` rebuilds the generated `ghostty.conf`
/// on the change (`observeTerminalSettings`), which reaches every open terminal: libghostty re-lays
/// a live surface out for a new font, size or line height, and takes the cursor's new shape.
struct TerminalTypographySections: View {
  @Default(.terminalFontFamily) private var family
  @Default(.terminalFontWeight) private var weight
  @Default(.terminalFontItalic) private var italic
  @Default(.terminalFontSize) private var size
  @Default(.terminalLineHeight) private var lineHeight
  @Default(.terminalCursorShape) private var cursorShape
  @Default(.terminalCursorBlinks) private var cursorBlinks

  /// The monospaced families on this Mac, found off the main thread when the pane opens.
  @State private var families: [String] = []
  /// The chosen family's faces (the built-in font's when `family` is "").
  @State private var faces: [TerminalFontFace] = []
  /// What the Size field holds while it is being typed in. It commits on Return or when the field
  /// loses focus: committed per keystroke, "15" went in as 1, was clamped to 6, and then read "65".
  @State private var sizeDraft: Double = TerminalTypography.defaults.size
  @FocusState private var sizeFieldFocused: Bool

  private var typography: TerminalTypography {
    TerminalTypography(
      family: family, weight: weight, italic: italic, size: size, lineHeight: lineHeight,
      cursorShape: cursorShape, cursorBlinks: cursorBlinks)
  }

  private var weights: [Int] { typography.offeredWeights(in: faces) }

  private var hasItalic: Bool { faces.contains(where: \.italic) }

  private var isDefault: Bool { typography == TerminalTypography() }

  var body: some View {
    Section {
      TerminalTypographyPreview(typography: typography)
        .listRowInsets(
          EdgeInsets(top: Spacing.m, leading: Spacing.m, bottom: Spacing.m, trailing: Spacing.m)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal preview")
        .accessibilityIdentifier("settings.terminal.preview")

      Picker("Font", selection: $family) {
        Text("\(TerminalFontCatalog.builtInFamily) (Built-in)").tag("")
        Divider()
        if !family.isEmpty, !families.contains(family) {
          // Until the list loads, the saved font still has a row to show.
          Text(families.isEmpty ? family : "\(family) (Not Installed)").tag(family)
        }
        ForEach(families.filter { $0 != TerminalFontCatalog.builtInFamily }, id: \.self) {
          Text($0).tag($0)
        }
      }
      .help("The terminal's font. Only monospaced fonts are listed.")
      .accessibilityIdentifier("settings.control.terminalFontFamily")
      .onChange(of: family) { _, family in
        loadFaces(for: family)
        snapToFont()
      }

      Picker("Weight", selection: $weight) {
        ForEach(weights, id: \.self) { weight in
          Text(TerminalFontCatalog.weightName(weight)).tag(weight)
        }
      }
      .disabled(weights.count < 2)
      .help(
        weights.count < 2
          ? "This font comes in one weight."
          : "How heavy the terminal's text is. Bold text is drawn heavier still."
      )
      .accessibilityIdentifier("settings.control.terminalFontWeight")

      Picker("Style", selection: $italic) {
        Text("Normal").tag(false)
        Text("Italic").tag(true)
      }
      .pickerStyle(.segmented)
      .disabled(!hasItalic && !italic)
      .help(
        hasItalic
          ? "Draw the terminal's text upright or italic. Text a program makes italic stays italic."
          : "This font has no italic."
      )
      .accessibilityIdentifier("settings.control.terminalFontItalic")
      .onChange(of: italic) { snapToFont() }

      LabeledContent("Size") {
        HStack(spacing: Spacing.s) {
          TextField(
            "Size", value: $sizeDraft, format: .number.precision(.fractionLength(0...1))
          )
          .labelsHidden()
          .focused($sizeFieldFocused)
          .onSubmit(commitSizeDraft)
          .onChange(of: sizeFieldFocused) { _, focused in
            if !focused { commitSizeDraft() }
          }
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 44)
          .help(
            "The font size in points, \(TerminalTypography.format(TerminalTypography.sizeRange.lowerBound))–"
              + "\(TerminalTypography.format(TerminalTypography.sizeRange.upperBound))."
          )
          .accessibilityIdentifier("settings.control.terminalFontSize")
          Text("pt").foregroundStyle(.secondary)
          Stepper(
            "Size", value: $size, in: TerminalTypography.sizeRange, step: 1
          )
          .labelsHidden()
          .help("Make the terminal's text larger or smaller.")
        }
      }
      .onChange(of: size) { _, size in sizeDraft = size }

      LabeledContent("Line height") {
        HStack(spacing: Spacing.m) {
          Slider(value: $lineHeight, in: TerminalTypography.lineHeightRange, step: 0.05)
            .frame(minWidth: 140)
            .help("The space each line of the terminal takes, as a multiple of the font's own.")
            .accessibilityIdentifier("settings.control.terminalLineHeight")
          Text(lineHeight, format: .number.precision(.fractionLength(2)))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
            .accessibilityHidden(true)
        }
      }

      HStack {
        Spacer()
        Button("Restore Defaults") { restoreDefaults() }
          .disabled(isDefault)
          .help("Put the terminal's font and cursor back to Workroom's defaults.")
          .accessibilityIdentifier("settings.control.terminalTypographyRestoreDefaults")
      }
    } header: {
      Text("Font")
    }
    .task { await loadFamilies() }
    .onAppear {
      loadFaces(for: family)
      // A weight saved for a font that has since changed shows as a selection the menu has.
      snapToFont()
      sizeDraft = size
    }

    Section {
      Picker("Shape", selection: $cursorShape) {
        ForEach(TerminalCursorShape.allCases) { shape in
          Text(shape.label).tag(shape)
          if shape == .automatic { Divider() }
        }
      }
      .help("The cursor's shape. Automatic shows a bar at the shell prompt and a block elsewhere.")
      .accessibilityIdentifier("settings.control.terminalCursorShape")

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Toggle("Blink", isOn: $cursorBlinks)
          .help("Make the cursor blink.")
          .accessibilityIdentifier("settings.control.terminalCursorBlinks")
        Text(
          "Programs such as Vim can still change the cursor while they run. At the shell "
            + "prompt, the shape and blinking apply to terminals you open after changing them. "
            + "Remote workrooms keep a blinking bar at their prompt."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

    } header: {
      Text("Cursor")
    }
  }

  /// A weight or italic the font doesn't have moves to the nearest it does
  /// (`TerminalTypography.snapped`). Each is written only when it changes.
  private func snapToFont() {
    let snapped = typography.snapped(to: faces)
    if snapped.italic != italic { italic = snapped.italic }
    if snapped.weight != weight { weight = snapped.weight }
  }

  /// The typed size, clamped to the range, rounded to a tenth of a point (what the field shows).
  private func commitSizeDraft() {
    let clamped = TerminalTypography.clamp(sizeDraft, to: TerminalTypography.sizeRange)
    let committed = (clamped * 10).rounded() / 10
    sizeDraft = committed
    if committed != size { size = committed }
  }

  private func loadFaces(for family: String) {
    faces = TerminalFontCatalog.faces(of: TerminalTypography(family: family).effectiveFamily)
  }

  private func loadFamilies() async {
    let found = await Task.detached(priority: .userInitiated) {
      TerminalFontCatalog.monospacedFamilies()
    }.value
    families = found
  }

  private func restoreDefaults() {
    Defaults.reset(TerminalTypography.keys)
  }
}
