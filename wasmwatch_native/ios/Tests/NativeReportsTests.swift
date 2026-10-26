import Foundation
import XCTest
@testable import WasmWatchNativeCore

final class NativeReportsTests: XCTestCase {
  private let old: [String: Any] = ["release": "old", "install_id": "install", "environment": "test"]
  private var diagnostic: [String: Any] { ["diagnosticMetaData": ["pid": 7, "signal": 6]] }

  private func report(_ diagnostic: [String: Any], ring: ScopeRing = ScopeRing(),
                      kind: String = "ios_crash", begin: Int64 = 1) throws -> [String: Any] {
    try IOSReportBuilder.build(kind: kind, diagnostic: diagnostic, begin: begin, end: 2,
        binaries: ["Runner": "/test/Runner.app/Runner"], ring: ring,
        identity: ["release": "new", "install_id": "install"], received: 3)
  }

  func testPIDRingKeepsEightDistinctProcessesAndTheirIdentity() throws {
    var ring = ScopeRing()
    for pid in 0..<10 { ring.update(scope: ["pid": pid, "session_id": "s\(pid)"], identity: old) }
    ring.update(scope: ["pid": 7, "session_id": "latest"], identity: old)
    XCTAssertEqual(ring.entries.count, 8)
    XCTAssertNil(ring.matching(["diagnosticMetaData": ["pid": 1]]))
    let captured = try report(diagnostic, ring: ScopeRing(ring.entries))
    XCTAssertEqual(captured["release"] as? String, "old")
    XCTAssertEqual((captured["scope"] as? [String: Any])?["session_id"] as? String, "latest")
    let unmatched = try report(["diagnosticMetaData": ["pid": 77]], ring: ring)
    XCTAssertEqual(unmatched["release"] as? String, "new")
    XCTAssertNil(unmatched["scope"])
    XCTAssertNil(try report([:])["scope"])
    var beforeStart = ScopeRing()
    beforeStart.update(scope: ["pid": 7, "session_id": "pre-start"], identity: nil)
    let restored = ScopeRing(beforeStart.entries)
    let pending = try report(diagnostic, ring: restored)
    XCTAssertEqual((pending["scope"] as? [String: Any])?["session_id"] as? String, "pre-start")
    XCTAssertEqual(pending["release"] as? String, "new")
  }

  func testCanonicalIdentityAndMetricWindows() throws {
    let first = try report(diagnostic)
    let second = try report(["diagnosticMetaData": ["signal": 6, "pid": 7]])
    XCTAssertEqual(first["id"] as? String, second["id"] as? String)
    XCTAssertNotEqual(try report([:], kind: "ios_exit_metrics", begin: 1)["id"] as? String,
                      try report([:], kind: "ios_exit_metrics", begin: 2)["id"] as? String)
  }

  func testShrinksOtherThreadsThenDropsOversizedAttributedStack() throws {
    let huge = String(repeating: "x", count: 530000)
    var data = diagnostic
    data["callStackTree"] = ["callStacks": [
      ["threadAttributed": true, "callStackRootFrames": [["address": 42]]],
      ["threadAttributed": false, "large": huge],
    ]]
    let reduced = try NativeJSON.object(IOSReportBuilder.bounded(report(data)))
    XCTAssertEqual(reduced["truncated"] as? String, "attributed_stack_only")
    let tree = (reduced["diagnostic"] as? [String: Any])?["callStackTree"] as? [String: Any]
    XCTAssertEqual((tree?["callStacks"] as? [Any])?.count, 1)
    data["callStackTree"] = ["callStacks": [["threadAttributed": true, "large": huge]]]
    let minimal = try NativeJSON.object(IOSReportBuilder.bounded(report(data)))
    XCTAssertEqual(minimal["truncated"] as? String, "call_stack_dropped")
    let kept = minimal["diagnostic"] as? [String: Any]
    XCTAssertNil(kept?["callStackTree"])
    XCTAssertNotNil(kept?["diagnosticMetaData"])
  }

  func testStoreBoundAtomicRestartAckAndDedup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try IOSPendingStore(root: root)
    var ids: [String] = []
    for pid in 0..<40 {
      let item = try report(["diagnosticMetaData": ["pid": pid]])
      ids.append(item["id"] as! String)
      XCTAssertTrue(try store.put(item))
      // Explicit file dates make oldest-first eviction deterministic.
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(pid))],
          ofItemAtPath: store.pending.appendingPathComponent(ids.last! + ".json").path)
    }
    let pending = try store.reports(identity: old)
    XCTAssertEqual(pending.count, 32)
    XCTAssertEqual(try NativeJSON.object(Data(pending[0].utf8))["id"] as? String, ids[8])
    try Data().write(to: store.pending.appendingPathComponent("orphan.tmp"))
    let restarted = try IOSPendingStore(root: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.pending.appendingPathComponent("orphan.tmp").path))
    try restarted.ack([ids[39], "../identity", ids[39]])
    XCTAssertEqual(try restarted.reports(identity: old).count, 31)
    XCTAssertFalse(try restarted.put(report(["diagnosticMetaData": ["pid": 39]])))
    XCTAssertTrue(try restarted.reports(identity: old).allSatisfy { $0.utf8.count <= 512 * 1024 })
    // Simulate a kill between the report rename and the journal write.
    try FileManager.default.removeItem(at: root.appendingPathComponent("seen.json"))
    let recovered = try IOSPendingStore(root: root)
    try recovered.ack([ids[38]])
    XCTAssertFalse(try recovered.put(report(["diagnosticMetaData": ["pid": 38]])))
  }

  func testScopeValidationUsesEncodedSizeAndDepth() throws {
    XCTAssertThrowsError(try NativeJSON.boundedObject("{\"x\":\"" + String(repeating: "x", count: 65536) + "\"}"))
    XCTAssertThrowsError(try NativeJSON.boundedObject(String(repeating: "{\"x\":", count: 65) + "0" + String(repeating: "}", count: 65)))
    XCTAssertThrowsError(try NativeJSON.boundedObject("[]"))
    XCTAssertEqual(try NativeJSON.boundedObject("{\"x\":\"[{}]\\\"\"}")["x"] as? String, "[{}]\"")
  }
}
