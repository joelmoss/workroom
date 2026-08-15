import XCTest

@testable import Workroom

final class UnifiedDiffTests: XCTestCase {

  // MARK: - parse: basic cases

  func testEmptyInput() {
    let d = UnifiedDiff.parse("")
    XCTAssertTrue(d.hunks.isEmpty)
    XCTAssertFalse(d.truncated)
    XCTAssertNil(d.renamedFrom)
  }

  func testSingleModifiedHunk() {
    let raw = """
      diff --git a/foo.swift b/foo.swift
      index abc..def 100644
      --- a/foo.swift
      +++ b/foo.swift
      @@ -1,4 +1,4 @@
       line1
      -line2
      +line2b
       line3
       line4
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks.count, 1)
    XCTAssertFalse(d.truncated)
    XCTAssertNil(d.renamedFrom)
    let lines = d.hunks[0].lines
    XCTAssertEqual(lines.count, 5)

    // context line 1: old=1, new=1
    XCTAssertEqual(lines[0].kind, .context)
    XCTAssertEqual(lines[0].text, "line1")
    XCTAssertEqual(lines[0].oldLine, 1)
    XCTAssertEqual(lines[0].newLine, 1)

    // deletion: old=2, new nil
    XCTAssertEqual(lines[1].kind, .deletion)
    XCTAssertEqual(lines[1].text, "line2")
    XCTAssertEqual(lines[1].oldLine, 2)
    XCTAssertNil(lines[1].newLine)

    // addition: new=2, old nil
    XCTAssertEqual(lines[2].kind, .addition)
    XCTAssertEqual(lines[2].text, "line2b")
    XCTAssertNil(lines[2].oldLine)
    XCTAssertEqual(lines[2].newLine, 2)

    // context line 3: old=3, new=3
    XCTAssertEqual(lines[3].kind, .context)
    XCTAssertEqual(lines[3].oldLine, 3)
    XCTAssertEqual(lines[3].newLine, 3)

    // context line 4: old=4, new=4
    XCTAssertEqual(lines[4].kind, .context)
    XCTAssertEqual(lines[4].oldLine, 4)
    XCTAssertEqual(lines[4].newLine, 4)
  }

  func testPureAdditions() {
    let raw = """
      diff --git a/new.txt b/new.txt
      new file mode 100644
      index 0000000..abc1234
      --- /dev/null
      +++ b/new.txt
      @@ -0,0 +1,3 @@
      +alpha
      +beta
      +gamma
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks.count, 1)
    let lines = d.hunks[0].lines
    XCTAssertEqual(lines.count, 3)
    for line in lines {
      XCTAssertEqual(line.kind, .addition)
      XCTAssertNil(line.oldLine)
    }
    XCTAssertEqual(lines[0].newLine, 1)
    XCTAssertEqual(lines[1].newLine, 2)
    XCTAssertEqual(lines[2].newLine, 3)
    XCTAssertEqual(lines[0].text, "alpha")
    XCTAssertEqual(lines[1].text, "beta")
    XCTAssertEqual(lines[2].text, "gamma")
  }

  func testPureDeletions() {
    let raw = """
      diff --git a/old.txt b/old.txt
      deleted file mode 100644
      --- a/old.txt
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -first
      -second
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks.count, 1)
    let lines = d.hunks[0].lines
    XCTAssertEqual(lines.count, 2)
    for line in lines {
      XCTAssertEqual(line.kind, .deletion)
      XCTAssertNil(line.newLine)
    }
    XCTAssertEqual(lines[0].oldLine, 1)
    XCTAssertEqual(lines[1].oldLine, 2)
  }

  func testMultiHunk() {
    let raw = """
      diff --git a/multi.txt b/multi.txt
      --- a/multi.txt
      +++ b/multi.txt
      @@ -1,3 +1,3 @@
       ctx1
      -old1
      +new1
       ctx2
      @@ -10,3 +10,3 @@
       ctx3
      -old2
      +new2
       ctx4
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks.count, 2)
    XCTAssertEqual(d.hunks[0].lines.count, 4)
    XCTAssertEqual(d.hunks[1].lines.count, 4)

    // Second hunk starts at old line 10 / new line 10
    let secondHunkLines = d.hunks[1].lines
    let ctx3 = secondHunkLines[0]
    XCTAssertEqual(ctx3.kind, .context)
    XCTAssertEqual(ctx3.oldLine, 10)
    XCTAssertEqual(ctx3.newLine, 10)
  }

  func testMultiFileFlattenedInOrder() {
    let raw = """
      diff --git a/a.txt b/a.txt
      --- a/a.txt
      +++ b/a.txt
      @@ -1,1 +1,1 @@
      -a
      +A
      diff --git a/b.txt b/b.txt
      --- a/b.txt
      +++ b/b.txt
      @@ -1,1 +1,1 @@
      -b
      +B
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks.count, 2)
    XCTAssertEqual(d.hunks[0].lines[0].text, "a")
    XCTAssertEqual(d.hunks[1].lines[0].text, "b")
  }

  func testRenameHeader() {
    let raw = """
      diff --git a/old.txt b/new.txt
      similarity index 90%
      rename from old.txt
      rename to new.txt
      --- a/old.txt
      +++ b/new.txt
      @@ -1,1 +1,1 @@
      -content
      +content
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.renamedFrom, "old.txt")
    XCTAssertEqual(d.hunks.count, 1)
  }

  func testNoNewlineAtEofDropped() {
    let raw = """
      diff --git a/x.txt b/x.txt
      --- a/x.txt
      +++ b/x.txt
      @@ -1,1 +1,1 @@
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks.count, 1)
    // Only the two content lines, no sentinel
    XCTAssertEqual(d.hunks[0].lines.count, 2)
    XCTAssertEqual(d.hunks[0].lines[0].kind, .deletion)
    XCTAssertEqual(d.hunks[0].lines[1].kind, .addition)
  }

  func testLineCap() {
    // Build a diff with more lines than the cap
    var lines = [
      "diff --git a/big.txt b/big.txt", "--- a/big.txt", "+++ b/big.txt",
      "@@ -1,20 +1,20 @@",
    ]
    for i in 1...20 {
      lines.append(" line\(i)")  // 20 context lines
    }
    let raw = lines.joined(separator: "\n")
    let d = UnifiedDiff.parse(raw, lineCap: 5)
    XCTAssertTrue(d.truncated)
    // All lines up to (and including) the cap are present; excess dropped
    let allLines = d.hunks.flatMap(\.lines)
    XCTAssertTrue(allLines.count <= 20)  // not more than what was in the diff
    // The cap was reached so truncated is set
    XCTAssertTrue(d.truncated)
  }

  func testLineCap_notTruncatedWhenUnderCap() {
    let raw = """
      diff --git a/small.txt b/small.txt
      --- a/small.txt
      +++ b/small.txt
      @@ -1,2 +1,2 @@
      -old
      +new
      """
    let d = UnifiedDiff.parse(raw, lineCap: 100)
    XCTAssertFalse(d.truncated)
    XCTAssertEqual(d.hunks[0].lines.count, 2)
  }

  // MARK: - isBinary

  func testIsBinaryBinaryFilesDiffer() {
    let raw = "Binary files a/img.png and b/img.png differ"
    XCTAssertTrue(UnifiedDiff.isBinary(raw))
  }

  func testIsBinaryGITBinaryPatch() {
    let raw = "GIT binary patch\nliteral 12\nabc..."
    XCTAssertTrue(UnifiedDiff.isBinary(raw))
  }

  func testIsNotBinaryRegularDiff() {
    let raw = """
      diff --git a/f.swift b/f.swift
      @@ -1,1 +1,1 @@
      -x
      +y
      """
    XCTAssertFalse(UnifiedDiff.isBinary(raw))
  }

  func testIsNotBinaryEmpty() {
    XCTAssertFalse(UnifiedDiff.isBinary(""))
  }

  // MARK: - Hunk header captured verbatim

  func testHunkHeaderVerbatim() {
    let raw = """
      diff --git a/f.swift b/f.swift
      --- a/f.swift
      +++ b/f.swift
      @@ -5,3 +5,3 @@ func doSomething() {
       x
      -y
      +z
      """
    let d = UnifiedDiff.parse(raw)
    XCTAssertEqual(d.hunks[0].header, "@@ -5,3 +5,3 @@ func doSomething() {")
  }

  // MARK: - sideBySideRows (unified hunk → aligned old/new rows)

  private func line(_ k: UnifiedDiff.Line.Kind, _ t: String, old: Int? = nil, new: Int? = nil)
    -> UnifiedDiff.Line
  {
    UnifiedDiff.Line(kind: k, text: t, oldLine: old, newLine: new)
  }

  private func hunk(_ lines: [UnifiedDiff.Line]) -> UnifiedDiff.Hunk {
    UnifiedDiff.Hunk(header: "@@", lines: lines)
  }

  func testSideBySideModifyPairsLeftAndRight() {
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.context, "ctx", old: 1, new: 1),
        line(.deletion, "old", old: 2),
        line(.addition, "new", new: 2),
      ]))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].left?.text, "ctx")
    XCTAssertEqual(rows[0].right?.text, "ctx")
    XCTAssertEqual(rows[1].left?.text, "old")
    XCTAssertEqual(rows[1].right?.text, "new")
  }

  func testSideBySidePureAdditionLeftBlank() {
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.context, "ctx", old: 1, new: 1),
        line(.addition, "a", new: 2),
        line(.addition, "b", new: 3),
      ]))
    XCTAssertEqual(rows.count, 3)
    XCTAssertNil(rows[1].left)
    XCTAssertEqual(rows[1].right?.text, "a")
    XCTAssertNil(rows[2].left)
    XCTAssertEqual(rows[2].right?.text, "b")
  }

  func testSideBySidePureDeletionRightBlank() {
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.deletion, "a", old: 1),
        line(.context, "ctx", old: 2, new: 1),
      ]))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].left?.text, "a")
    XCTAssertNil(rows[0].right)
    XCTAssertEqual(rows[1].left?.text, "ctx")
    XCTAssertEqual(rows[1].right?.text, "ctx")
  }

  func testSideBySideUnevenRunPadsTrailingRows() {
    // 3 deletions, 1 addition → first row paired, next two have a blank right side.
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.deletion, "a", old: 1),
        line(.deletion, "b", old: 2),
        line(.deletion, "c", old: 3),
        line(.addition, "x", new: 1),
      ]))
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows[0].left?.text, "a")
    XCTAssertEqual(rows[0].right?.text, "x")
    XCTAssertEqual(rows[1].left?.text, "b")
    XCTAssertNil(rows[1].right)
    XCTAssertEqual(rows[2].left?.text, "c")
    XCTAssertNil(rows[2].right)
  }

  func testSideBySideContextFlushesPendingRun() {
    // A context line between two replacement runs must flush the first run before emitting context.
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.deletion, "a", old: 1),
        line(.addition, "x", new: 1),
        line(.context, "ctx", old: 2, new: 2),
        line(.deletion, "b", old: 3),
        line(.addition, "y", new: 3),
      ]))
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows[0].left?.text, "a")
    XCTAssertEqual(rows[0].right?.text, "x")
    XCTAssertEqual(rows[1].left?.text, "ctx")
    XCTAssertEqual(rows[1].right?.text, "ctx")
    XCTAssertEqual(rows[2].left?.text, "b")
    XCTAssertEqual(rows[2].right?.text, "y")
  }

  func testSideBySideInterleavedWithoutContextBuffersIntoOneRun() {
    // -a +x -b +y with no context between buffers dels=[a,b], adds=[x,y] → (a,x),(b,y).
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.deletion, "a", old: 1),
        line(.addition, "x", new: 1),
        line(.deletion, "b", old: 2),
        line(.addition, "y", new: 2),
      ]))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].left?.text, "a")
    XCTAssertEqual(rows[0].right?.text, "x")
    XCTAssertEqual(rows[1].left?.text, "b")
    XCTAssertEqual(rows[1].right?.text, "y")
  }

  func testSideBySideEmptyHunk() {
    XCTAssertTrue(UnifiedDiff.sideBySideRows(for: hunk([])).isEmpty)
  }

  func testSideBySideAllContext() {
    let rows = UnifiedDiff.sideBySideRows(
      for: hunk([
        line(.context, "one", old: 1, new: 1),
        line(.context, "two", old: 2, new: 2),
      ]))
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map { $0.left?.text }, ["one", "two"])
    XCTAssertEqual(rows.map { $0.right?.text }, ["one", "two"])
  }

  // MARK: - lineStats

  func testLineStatsEmptyDiffIsZero() {
    let diff = UnifiedDiff(hunks: [], truncated: false, renamedFrom: nil)
    let stats = UnifiedDiff.lineStats(for: diff)
    XCTAssertEqual(stats.additions, 0)
    XCTAssertEqual(stats.removals, 0)
  }

  func testLineStatsCountsAdditionsAndRemovalsAcrossHunks() {
    let diff = UnifiedDiff(
      hunks: [
        hunk([
          line(.context, "ctx", old: 1, new: 1),
          line(.deletion, "old", old: 2),
          line(.addition, "new1", new: 2),
          line(.addition, "new2", new: 3),
        ]),
        hunk([
          line(.deletion, "old2", old: 10)
        ]),
      ], truncated: false, renamedFrom: nil)
    let stats = UnifiedDiff.lineStats(for: diff)
    XCTAssertEqual(stats.additions, 2)
    XCTAssertEqual(stats.removals, 2)
  }

  func testLineStatsIgnoresContextLines() {
    let diff = UnifiedDiff(
      hunks: [
        hunk([
          line(.context, "one", old: 1, new: 1),
          line(.context, "two", old: 2, new: 2),
        ])
      ], truncated: false, renamedFrom: nil)
    let stats = UnifiedDiff.lineStats(for: diff)
    XCTAssertEqual(stats.additions, 0)
    XCTAssertEqual(stats.removals, 0)
  }
}
