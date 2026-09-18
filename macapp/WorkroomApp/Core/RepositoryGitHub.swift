import Foundation

/// GitHub support remains local in this phase. Construct before cache lookup or optimistic edits.
/// A remote location fails before filesystem inspection, provider construction, or any gh command.
struct RepositoryGitHub: Sendable {
  let context: RepositoryContext
  let resolver: WorkroomStatusResolver
  private let path: String
  private let sharedPath: String

  init(context: RepositoryContext, resolver: WorkroomStatusResolver = WorkroomStatusResolver())
    throws
  {
    _ = try context.location.requireLocalURL()
    self.context = context
    self.resolver = resolver
    path = context.location.path
    if context.backend == .jj {
      sharedPath = try context.requireOwnership().path
    } else {
      sharedPath = context.sharedLocation?.path ?? path
    }
  }

  func nameWithOwner() async -> String? {
    await resolver.resolveNameWithOwner(in: sharedPath)
  }
  func ci(branch: String?, nameWithOwner: String? = nil) async -> CIResolution {
    await resolver.resolveCI(
      path: path, vcs: context.backend.rawValue, projectRoot: sharedPath,
      branch: branch, nameWithOwner: nameWithOwner)
  }
  func pullRequest(branch: String?) async -> PRResolution {
    await resolver.resolvePRRaw(
      path: path, vcs: context.backend.rawValue,
      projectRoot: sharedPath, branch: branch)
  }
  func enrich(_ resolution: PRResolution) async -> PRResolution {
    await resolver.enrichPR(
      resolution, path: path, vcs: context.backend.rawValue,
      projectRoot: sharedPath)
  }
  func checks(number: Int) async -> ChecksResolution {
    await resolver.resolveChecks(
      path: path, vcs: context.backend.rawValue,
      projectRoot: sharedPath, number: number)
  }
  func run(_ arguments: [String]) async -> CommandResult {
    await resolver.runPRCommand(
      arguments,
      in: WorkroomStatusResolver.ghProbeDirectory(
        path: path, vcs: context.backend.rawValue, projectRoot: sharedPath))
  }
}
