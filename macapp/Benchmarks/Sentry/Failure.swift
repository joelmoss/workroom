import Darwin
import Foundation

#if canImport(Sentry)
  import Sentry
#endif

/// Invalid measurements are ordinary failures, never crash reports or native crash dialogs.
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("Sentry benchmark: \(message)\n".utf8))
  if CommandLine.arguments.count > 2,
    let data = try? JSONSerialization.data(withJSONObject: ["error": message])
  {
    try? data.write(
      to: URL(fileURLWithPath: CommandLine.arguments[2] + ".error.json"), options: .atomic)
  }
  #if canImport(Sentry)
    if SentrySDK.isEnabled { SentrySDK.close() }
  #endif
  Darwin.exit(2)
}

func require(_ condition: Bool, _ message: String) {
  if !condition { fail(message) }
}
