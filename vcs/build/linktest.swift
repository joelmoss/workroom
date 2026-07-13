import Foundation
let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
print("probe:", probeRepo(root: root))
do {
  let page = try logPage(root: root, limit: 3)
  print("commits=\(page.commits.count) reachedEnd=\(page.reachedEnd)")
  for c in page.commits { print(" ", c.shortId, "wc=\(c.isWorkingCopy)", c.refs, "|", c.summary) }
} catch { print("error:", error) }
