import Foundation

public struct SessionIdentifier: Hashable, Sendable {
  public static let byteCount = 16

  private static let hexDigits: [Character] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]

  public let bytes: [UInt8]

  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }

  public init?(uuidString: String) {
    var parsed: [UInt8] = []
    parsed.reserveCapacity(Self.byteCount)
    var pendingHighNibble: UInt8?
    for character in uuidString {
      if character == "-" { continue }
      guard let nibble = Self.nibble(character) else { return nil }
      guard let high = pendingHighNibble else {
        pendingHighNibble = nibble
        continue
      }
      guard parsed.count < Self.byteCount else { return nil }
      parsed.append(high << 4 | nibble)
      pendingHighNibble = nil
    }
    guard pendingHighNibble == nil, parsed.count == Self.byteCount else { return nil }
    bytes = parsed
  }

  public init(_ uuid: UUID) {
    let u = uuid.uuid
    bytes = [
      u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
      u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
    ]
  }

  public var uuid: UUID? {
    UUID(uuidString: uuidString)
  }

  public var uuidString: String {
    var result = ""
    result.reserveCapacity(36)
    for (index, byte) in bytes.enumerated() {
      if index == 4 || index == 6 || index == 8 || index == 10 {
        result.append("-")
      }
      result.append(Self.hexDigits[Int(byte >> 4)])
      result.append(Self.hexDigits[Int(byte & 0x0F)])
    }
    return result
  }

  private static func nibble(_ character: Character) -> UInt8? {
    switch character {
    case "0"..."9":
      UInt8(character.asciiValue ?? 0) - UInt8(ascii: "0")
    case "a"..."f":
      UInt8(character.asciiValue ?? 0) - UInt8(ascii: "a") + 10
    case "A"..."F":
      UInt8(character.asciiValue ?? 0) - UInt8(ascii: "A") + 10
    default:
      nil
    }
  }
}
