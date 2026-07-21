import CSQLite
import Foundation

public enum SQLiteValue: Equatable, Sendable {
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)
  case null

  public var int64: Int64? {
    if case .integer(let value) = self { return value }
    return nil
  }

  public var string: String? {
    if case .text(let value) = self { return value }
    return nil
  }

  public var double: Double? {
    switch self {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }
}

public typealias SQLiteRow = [String: SQLiteValue]

public struct SQLiteFailure: Error, Equatable, CustomStringConvertible, Sendable {
  public let code: Int32
  public let message: String
  public let statement: String?

  public init(code: Int32, message: String, statement: String? = nil) {
    self.code = code
    self.message = message
    self.statement = statement
  }

  public var description: String {
    if let statement {
      return "SQLite error \(code): \(message) [\(statement)]"
    }
    return "SQLite error \(code): \(message)"
  }
}

public final class SQLiteConnection: @unchecked Sendable {
  public let databaseURL: URL

  private let lock = NSRecursiveLock()
  private var handle: OpaquePointer?

  public init(databaseURL: URL) throws {
    self.databaseURL = databaseURL

    if !databaseURL.path.isEmpty && databaseURL.path != ":memory:" {
      try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
      let message =
        database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
      if let database { sqlite3_close(database) }
      throw SQLiteFailure(code: result, message: message)
    }
    handle = database
    try execute("PRAGMA foreign_keys = ON")
    try execute("PRAGMA busy_timeout = 5000")
  }

  deinit {
    if let handle { sqlite3_close(handle) }
  }

  public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
    lock.lock()
    defer { lock.unlock() }
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement, sql: sql)

    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      throw failure(code: result, statement: sql)
    }
  }

  public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
    lock.lock()
    defer { lock.unlock() }
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement, sql: sql)

    var rows: [SQLiteRow] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw failure(code: result, statement: sql)
      }

      var row: SQLiteRow = [:]
      for index in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, index))
        row[name] = value(statement: statement, index: index)
      }
      rows.append(row)
    }
    return rows
  }

  public func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64? {
    try query(sql, bindings: bindings).first?.values.first?.int64
  }

  public func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  public func checkpoint() throws {
    try execute("PRAGMA wal_checkpoint(FULL)")
  }

  public func enableWriteAheadLogging() throws {
    _ = try query("PRAGMA journal_mode = WAL")
    try execute("PRAGMA synchronous = FULL")
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let handle else {
      throw SQLiteFailure(code: SQLITE_MISUSE, message: "Database is closed", statement: sql)
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw failure(code: result, statement: sql)
    }
    return statement
  }

  private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer, sql: String) throws {
    guard bindings.count == Int(sqlite3_bind_parameter_count(statement)) else {
      throw SQLiteFailure(
        code: SQLITE_MISUSE,
        message:
          "Expected \(sqlite3_bind_parameter_count(statement)) bindings, received \(bindings.count)",
        statement: sql
      )
    }

    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case .integer(let value):
        result = sqlite3_bind_int64(statement, index, value)
      case .real(let value):
        result = sqlite3_bind_double(statement, index, value)
      case .text(let value):
        result = value.withCString {
          sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
      case .blob(let data):
        result = data.withUnsafeBytes { bytes in
          sqlite3_bind_blob(
            statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else {
        throw failure(code: result, statement: sql)
      }
    }
  }

  private func value(statement: OpaquePointer, index: Int32) -> SQLiteValue {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER:
      .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT:
      .real(sqlite3_column_double(statement, index))
    case SQLITE_TEXT:
      .text(String(cString: sqlite3_column_text(statement, index)))
    case SQLITE_BLOB:
      if let bytes = sqlite3_column_blob(statement, index) {
        .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
      } else {
        .blob(Data())
      }
    default:
      .null
    }
  }

  private func failure(code: Int32, statement: String?) -> SQLiteFailure {
    let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite failure"
    return SQLiteFailure(code: code, message: message, statement: statement)
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
