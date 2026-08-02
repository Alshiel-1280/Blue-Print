import CArgon2
import Foundation

public enum Argon2KeyDerivationError: Error, Equatable, Sendable {
  case invalidParameters
  case derivationFailed(Int32)
}

public struct Argon2KeyDeriver: Sendable {
  public static let version = 19
  public static let defaultMemoryKiB = 65_536
  public static let defaultIterations = 3
  public static let defaultParallelism = 1
  public static let outputBytes = 32

  public static let minimumMemoryKiB = 8 * 1_024
  public static let maximumMemoryKiB = 256 * 1_024
  public static let minimumIterations = 2
  public static let maximumIterations = 6
  public static let minimumParallelism = 1
  public static let maximumParallelism = 4

  public init() {}

  public func derive(
    passphrase: String,
    salt: Data,
    memoryKiB: Int = Self.defaultMemoryKiB,
    iterations: Int = Self.defaultIterations,
    parallelism: Int = Self.defaultParallelism,
    outputBytes: Int = Self.outputBytes
  ) throws -> Data {
    guard salt.count >= 8 && salt.count <= 64,
      memoryKiB >= Self.minimumMemoryKiB,
      memoryKiB <= Self.maximumMemoryKiB,
      iterations >= Self.minimumIterations,
      iterations <= Self.maximumIterations,
      parallelism >= Self.minimumParallelism,
      parallelism <= Self.maximumParallelism,
      outputBytes == Self.outputBytes
    else {
      throw Argon2KeyDerivationError.invalidParameters
    }

    var password = Array(passphrase.utf8)
    defer { password.resetBytes(in: password.indices) }
    let saltBytes = Array(salt)
    var output = [UInt8](repeating: 0, count: outputBytes)
    let result = output.withUnsafeMutableBytes { outputBuffer in
      password.withUnsafeBytes { passwordBuffer in
        saltBytes.withUnsafeBytes { saltBuffer in
          argon2id_hash_raw(
            UInt32(iterations),
            UInt32(memoryKiB),
            UInt32(parallelism),
            passwordBuffer.baseAddress,
            passwordBuffer.count,
            saltBuffer.baseAddress,
            saltBuffer.count,
            outputBuffer.baseAddress,
            outputBuffer.count
          )
        }
      }
    }
    guard result == ARGON2_OK.rawValue else {
      throw Argon2KeyDerivationError.derivationFailed(result)
    }
    return Data(output)
  }
}
