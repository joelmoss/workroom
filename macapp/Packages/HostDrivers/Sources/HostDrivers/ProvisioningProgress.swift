import Foundation

/// What a remote create tells the user while it runs (#356): the drivers report their machine work,
/// `RemoteProvisioning` (in the app) its git, and the app shows each step on the project row.
public enum ProvisioningProgress {
  /// A step of a remote create that takes long enough to say (#356): the boxd driver's machine work
  /// and the sequence's own git.
  public enum Step: String, CaseIterable, Sendable {
    case machine = "Creating the workroom's machine"
    case setup = "Setting it up"
    case clone = "Cloning the repository"
    case checkout = "Checking out the workroom's branch"
  }

  /// Told each `Step` as it starts, for a create's progress on its project row. Set with
  /// `ProvisioningProgress.$reportStep.withValue`: a task-local, so the driver's methods keep their
  /// shape, as `ContainerHostDriver.$pullProgress` does for an image pull.
  @TaskLocal public static var reportStep: (@Sendable (Step) -> Void)?
}
