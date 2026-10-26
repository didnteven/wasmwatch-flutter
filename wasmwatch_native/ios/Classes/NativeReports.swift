import CryptoKit
import Foundation

// Foundation-only capture/storage logic; exercised by the offline XCTest suite.
struct ScopeRing {
  private(set) var entries: [[String: Any]] = []

  init(_ entries: [[String: Any]] = []) {
    for entry in entries {
      if let scope = entry["scope"] as? [String: Any] {
        update(scope: scope, identity: entry["identity"] as? [String: Any])
      }
    }
  }

  mutating func update(scope: [String: Any], identity: [String: Any]?) {
    guard let pid = scope["pid"] as? Int else { return }
    entries.removeAll { ($0["scope"] as? [String: Any])?["pid"] as? Int == pid }
    var entry: [String: Any] = ["scope": scope]
    if let identity = identity { entry["identity"] = identity }
    entries.append(entry)
    entries = Array(entries.suffix(8))
  }

  func matching(_ diagnostic: [String: Any]) -> [String: Any]? {
    guard let metadata = diagnostic["diagnosticMetaData"] as? [String: Any],
          let pid = metadata["pid"] as? Int else { return nil }
    return entries.last { ($0["scope"] as? [String: Any])?["pid"] as? Int == pid }
  }
}

enum NativeJSON {
  static func encode(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  static func object(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "wasmwatch_native", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected a JSON object"])
    }
    return object
  }

  static func boundedObject(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    guard data.count <= 64 * 1024 else { throw sizeError }
    // Match Android's JSON depth limit, ignoring brackets in quoted strings.
    var depth = 0, quoted = false, escaped = false
    for byte in data {
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
      } else if byte == 34 { quoted = true }
      else if byte == 123 || byte == 91 {
        depth += 1
        if depth > 64 { throw sizeError }
      } else if byte == 125 || byte == 93 { depth -= 1 }
    }
    return try object(data)
  }

  static var sizeError: NSError {
    NSError(domain: "wasmwatch_native", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "JSON exceeds capture bounds"])
  }
}

enum IOSReportBuilder {
  static let maximumBytes = 512 * 1024

  static func build(kind: String, diagnostic: [String: Any], begin: Int64, end: Int64,
                    binaries: [String: String], ring: ScopeRing,
                    identity: [String: Any]?, received: Int64) throws -> [String: Any] {
    // Canonical JSON makes callback/history dedup independent of key ordering.
    var hashInput = try NativeJSON.encode(diagnostic)
    if kind == "ios_exit_metrics" {
      // Equal daily counts in different time windows are separate payloads.
      hashInput = try NativeJSON.encode(["diagnostic": diagnostic,
                                        "payload_begin": begin, "payload_end": end])
    }
    let hash = SHA256.hash(data: hashInput).map { String(format: "%02x", $0) }.joined()
    var report: [String: Any] = [
      "v": 1, "id": "ios-\(hash)", "kind": kind, "received_ms": received,
      "payload_begin": begin, "payload_end": end, "diagnostic": diagnostic,
      "app_binaries": binaries,
    ]
    let match = ring.matching(diagnostic)
    if let scope = match?["scope"] { report["scope"] = scope }
    if let saved = (match?["identity"] as? [String: Any]) ?? identity {
      report.merge(saved) { _, new in new }
    }
    return report
  }

  static func bounded(_ original: [String: Any]) throws -> Data {
    var report = original
    var encoded = try NativeJSON.encode(report)
    if encoded.count <= maximumBytes { return encoded }
    var diagnostic = report["diagnostic"] as? [String: Any] ?? [:]
    if var tree = diagnostic["callStackTree"] as? [String: Any] {
      let stacks = tree["callStacks"] as? [[String: Any]] ?? []
      tree["callStacks"] = stacks.filter { $0["threadAttributed"] as? Bool == true }
      diagnostic["callStackTree"] = tree
      report["diagnostic"] = diagnostic
      report["truncated"] = "attributed_stack_only"
      encoded = try NativeJSON.encode(report)
      if encoded.count <= maximumBytes { return encoded }
    }
    // Keep the metadata and an explicit marker when the stack itself is too big.
    diagnostic.removeValue(forKey: "callStackTree")
    report["diagnostic"] = diagnostic
    report["truncated"] = "call_stack_dropped"
    encoded = try NativeJSON.encode(report)
    if encoded.count <= maximumBytes { return encoded }
    // Unexpected oversized optional fields must not erase the crash metadata.
    report.removeValue(forKey: "scope")
    report["app_binaries"] = [String: String]()
    report["diagnostic"] = ["diagnosticMetaData": diagnostic["diagnosticMetaData"] ?? [:]]
    report["truncated"] = "metadata_only"
    encoded = try NativeJSON.encode(report)
    if encoded.count <= maximumBytes { return encoded }
    // Bound even pathological metadata while preserving scalar evidence that fits.
    let metadata = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
    let kept = metadata.filter { key, value in
      key.utf8.count <= 256 && (value is String || value is NSNumber || value is NSNull) &&
        ((try? NativeJSON.encode([key: value]).count) ?? Int.max) <= 8192
    }.sorted { $0.key < $1.key }.prefix(32)
    report["diagnostic"] = ["diagnosticMetaData": Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })]
    encoded = try NativeJSON.encode(report)
    guard encoded.count <= maximumBytes else { throw NativeJSON.sizeError }
    return encoded
  }
}

// Every call is made on the plugin's one serial disk queue.
final class IOSPendingStore {
  let root: URL
  let pending: URL
  private let files = FileManager.default
  private var seen: [String]

  init(root: URL) throws {
    self.root = root
    pending = root.appendingPathComponent("pending", isDirectory: true)
    try files.createDirectory(at: pending, withIntermediateDirectories: true)
    seen = (try? Data(contentsOf: root.appendingPathComponent("seen.json")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
    for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) +
      files.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil) {
      if url.lastPathComponent.hasSuffix(".tmp") { try files.removeItem(at: url) }
    }
    try evict()
    // Recover the write/journal gap after a process kill: existing pending IDs
    // must be remembered before Dart can acknowledge their files.
    for url in try orderedFiles() {
      let id = url.deletingPathExtension().lastPathComponent
      if valid(id) && !seen.contains(id) { seen.append(id) }
    }
    seen = Array(seen.suffix(512))
    try saveState(seen, name: "seen.json")
  }

  func read(_ name: String) throws -> Data? {
    let url = root.appendingPathComponent(name)
    return files.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
  }

  func atomic(_ data: Data, to url: URL) throws {
    let temporary = url.appendingPathExtension("tmp")
    try data.write(to: temporary)
    let handle = try FileHandle(forWritingTo: temporary)
    defer { try? handle.close() }
    try handle.synchronize()
    // POSIX rename atomically replaces an existing sibling on Apple platforms.
    guard rename(temporary.path, url.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  func saveState(_ value: Any, name: String) throws {
    try atomic(NativeJSON.encode(value), to: root.appendingPathComponent(name))
  }

  @discardableResult func put(_ report: [String: Any]) throws -> Bool {
    guard let id = report["id"] as? String, valid(id) else { throw NativeJSON.sizeError }
    let url = pending.appendingPathComponent(id + ".json")
    if seen.contains(id) || files.fileExists(atPath: url.path) { return false }
    try atomic(IOSReportBuilder.bounded(report), to: url)
    seen.append(id)
    seen = Array(seen.suffix(512))
    try saveState(seen, name: "seen.json")
    try evict()
    return true
  }

  func reports(identity: [String: Any]) throws -> [String] {
    var result: [String] = []
    for url in try orderedFiles() {
      let data = try Data(contentsOf: url)
      guard var report = try? NativeJSON.object(data) else { continue }
      if report["release"] == nil {
        report.merge(identity) { old, _ in old }
        try atomic(IOSReportBuilder.bounded(report), to: url)
      }
      result.append(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }
    return result
  }

  func ack(_ ids: [String]) throws {
    for id in ids where valid(id) {
      let url = pending.appendingPathComponent(id + ".json")
      if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }
  }

  private func valid(_ id: String) -> Bool {
    id.range(of: "^ios-[0-9a-f]{64}$", options: .regularExpression) != nil
  }

  private func orderedFiles() throws -> [URL] {
    try files.contentsOfDirectory(at: pending, includingPropertiesForKeys: [.contentModificationDateKey])
      .filter { $0.pathExtension == "json" }
      .sorted {
        let a = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let b = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
      }
  }

  private func evict() throws {
    let urls = try orderedFiles()
    for url in urls.prefix(max(0, urls.count - 32)) { try files.removeItem(at: url) }
  }
}
