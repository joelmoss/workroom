// Writes a video's last <seconds> as PNGs, one every half second, named by their time in the video:
// swift video_frames.swift <video> <out-dir> [seconds, default 4]. Used by uitest_evidence.py on
// XCUITest screen recordings.
import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
  FileHandle.standardError.write("usage: video_frames.swift <video> <out-dir> [seconds]\n".data(using: .utf8)!)
  exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let keep = args.count > 3 ? Double(args[3]) ?? 4 : 4
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let duration = CMTimeGetSeconds(try await asset.load(.duration))
var time = max(0, duration - keep)
while time < duration {
  let at = CMTime(seconds: time, preferredTimescale: 600)
  if let image = try? await generator.image(at: at).image,
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  {
    try png.write(to: URL(fileURLWithPath: "\(args[2])/t\(String(format: "%06.1f", time)).png"))
  }
  time += 0.5
}
