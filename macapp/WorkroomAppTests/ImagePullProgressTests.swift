import XCTest

@testable import Workroom

/// Reading how far an image pull has got from what each runtime's CLI prints (#309).
final class ImagePullProgressTests: XCTestCase {
  /// Docker: the layers done of those seen, counting one already present as done, and ignoring
  /// lines that aren't a layer's.
  func testDockerProgressIsLayersDoneOfThoseSeen() {
    var progress = ImagePullProgress()
    progress.read("1.36: Pulling from containerd/busybox\n")
    XCTAssertNil(progress.fraction)
    progress.read(
      "f78e6840ded1: Pulling fs layer\naaaaaaaaaaaa: Already exists\nbbbbbbbbbbbb: Pulling fs layer\n"
        + "cccccccccccc: Pulling fs layer\n")
    XCTAssertEqual(progress.fraction, 0.25)
    // A line split across two pieces of output.
    progress.read("f78e6840ded1: Download complete\nf78e6840ded1: Pull ")
    XCTAssertEqual(progress.fraction, 0.25)
    progress.read("complete\n")
    XCTAssertEqual(progress.fraction, 0.5)
    progress.read(
      "bbbbbbbbbbbb: Pull complete\ncccccccccccc: Pull complete\nDigest: sha256:7b3c\n"
        + "Status: Downloaded newer image for x\n")
    XCTAssertEqual(progress.fraction, 1)
  }

  /// Apple: each step's share, plus its percent of that, as the lines `container` prints.
  func testAppleProgressIsTheStepAndItsPercent() {
    var progress = ImagePullProgress()
    progress.read("[1/2] Fetching image 50% (10 of 20 blobs)\n")
    XCTAssertEqual(progress.fraction, 0.25)
    progress.read(
      "[2/2] Unpacking image for platform linux/arm64 100% (440 of 440 entries, 3.9/3.9 MB) [3s]\r")
    XCTAssertEqual(progress.fraction, 1)
    var odd = ImagePullProgress()
    odd.read("[3/2] nonsense 40%\n[x/y] 10%\n")
    XCTAssertNil(odd.fraction)
  }
}
