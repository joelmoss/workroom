import XCTest

@testable import Workroom

/// Run-tab output extraction (issue #49, A1/X3): detecting the supervisor's in-band exit trailer and
/// carving the command's output out of the full surface. Pure — exercised with fixture surface text.
final class RunCaptureSupportTests: XCTestCase {
  private let trailer = RunCaptureSupport.exitTrailer

  func testTrailerDetection() {
    XCTAssertTrue(RunCaptureSupport.hasRenderedTrailer("npm ERR! boom\n\(trailer)\n"))
    XCTAssertFalse(RunCaptureSupport.hasRenderedTrailer("still running…\nweb server up"))
  }

  func testExtractOutputStopsAtTrailer() {
    let surface = """
      > rspec
      F.F

      Failures:
        1) User is invalid
      \(trailer)
      """
    let output = RunCaptureSupport.extractOutput(fromSurface: surface)
    XCTAssertNotNil(output)
    XCTAssertTrue(output!.contains("Failures:"))
    XCTAssertTrue(output!.contains("1) User is invalid"))
    XCTAssertFalse(output!.contains("Press any key"), "the trailer must be stripped")
  }

  func testExtractOutputWithoutTrailerReturnsAll() {
    let output = RunCaptureSupport.extractOutput(fromSurface: "Error: port 3000 in use")
    XCTAssertEqual(output, "Error: port 3000 in use")
  }

  func testExtractOutputTrimsTrailingBlanksBeforeTrailer() {
    let surface = "boom\n\n   \n\(trailer)\n"
    XCTAssertEqual(RunCaptureSupport.extractOutput(fromSurface: surface), "boom")
  }

  func testExtractOutputEmptyBeforeTrailerIsNil() {
    XCTAssertNil(RunCaptureSupport.extractOutput(fromSurface: "\(trailer)\n"))
  }
}
