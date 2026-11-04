import Foundation
import XCTest
@testable import WasmWatchNativeCore

final class HangWatchdogTests: XCTestCase {
  private let identity: [String: Any] = ["release": "build", "install_id": "install"]
  private let uuid = "DE4E052B-925D-3077-B5A7-B90C1A2D4B84"

  private func stackImages() -> HangImages {
    HangImages(images: [
      HangImage(header: 0x1000, end: 0x2000, path: "/usr/lib/system/libsystem_kernel.dylib", uuid: uuid),
      HangImage(header: 0x2000, end: 0x3000, path: "/usr/lib/system/libsystem_c.dylib", uuid: uuid),
      HangImage(header: 0x3000, end: 0x4000, path: "/Runner.app/Frameworks/App.framework/App", uuid: uuid),
      HangImage(header: 0x4000, end: 0x5000, path: "/System/UIKitCore.framework/UIKitCore", uuid: uuid),
      HangImage(header: 0x5000, end: 0x6000, path: "/Runner.app/Runner", uuid: uuid),
      HangImage(header: 0x6000, end: 0x7000, path: "/usr/lib/dyld", uuid: uuid),
    ])
  }

  func testLinkRegisterKeptOnlyForSyscallLeaves() {
    let images = stackImages()
    // pc in a kernel trap: lr (libsystem_c) is the real caller.
    XCTAssertEqual(IOSHangReport.frames([0x1010, 0x2010, 0x3010], images: images, mainExecutable: "Runner"),
                   [0x1010, 0x2010, 0x3010])
    // pc in Dart code: lr may be stale, so it is dropped.
    XCTAssertEqual(IOSHangReport.frames([0x3010, 0x3999, 0x3020], images: images, mainExecutable: "Runner"),
                   [0x3010, 0x3020])
    // A chain entry equal to lr (the frame saved it) is not repeated.
    XCTAssertEqual(IOSHangReport.frames([0x1010, 0x2010, 0x2010, 0x3010], images: images, mainExecutable: "Runner"),
                   [0x1010, 0x2010, 0x3010])
  }

  func testMainThreadStackEndsAtDyldStart() {
    let images = stackImages()
    let raw: [UInt64] = [0x3010, 0, 0x3020, 0x4010, 0x4020, 0x5010, 0x6010, 0x3030, 0x3040]
    XCTAssertEqual(IOSHangReport.frames(raw, images: images, mainExecutable: "Runner"),
                   [0x3010, 0x3020, 0x4010, 0x4020, 0x5010, 0x6010])
    // Junk directly after main, without a dyld frame, is dropped too.
    XCTAssertEqual(IOSHangReport.frames([0x3010, 0, 0x4010, 0x5010, 0x3030], images: images, mainExecutable: "Runner"),
                   [0x3010, 0x4010, 0x5010])
    // Without UIKit frames nothing is trimmed.
    XCTAssertEqual(IOSHangReport.frames([0x3010, 0, 0x3020, 0x3030], images: images, mainExecutable: "Runner"),
                   [0x3010, 0x3020, 0x3030])
  }

  func testImagesAndMetricKitTreeKeepInnermostFirst() throws {
    let images = HangImages(images: [
      HangImage(header: 4096, end: 8192, path: "/Runner.app/Runner", uuid: uuid),
      HangImage(header: 8192, end: 12288, path: "/Runner.app/Frameworks/App.framework/App", uuid: uuid),
    ])
    XCTAssertNil(images.image(at: 4095))
    XCTAssertEqual(images.image(at: 8192)?.path, "/Runner.app/Frameworks/App.framework/App")
    XCTAssertNil(images.image(at: 12288))
    let diagnostic = IOSHangReport.diagnostic(addresses: [8208, 4112, 1], images: images,
        seconds: 2.4, pid: 7, captureID: "unique")
    XCTAssertEqual(diagnostic["hangDuration"] as? String, "2.4 sec")
    let tree = diagnostic["callStackTree"] as! [String: Any]
    let stack = (tree["callStacks"] as! [[String: Any]]).first!
    XCTAssertEqual(stack["threadAttributed"] as? Bool, true)
    let root = (stack["callStackRootFrames"] as! [[String: Any]]).first!
    XCTAssertEqual(root["address"] as? UInt64, 8208)
    XCTAssertEqual(root["binaryName"] as? String, "App")
    XCTAssertEqual(root["binaryUUID"] as? String, uuid)
    XCTAssertEqual(root["offsetIntoBinaryTextSegment"] as? UInt64, 16)
    XCTAssertEqual(root["sampleCount"] as? Int, 1)
    let caller = (root["subFrames"] as! [[String: Any]]).first!
    XCTAssertEqual(caller["address"] as? UInt64, 4112)
    XCTAssertEqual(caller["binaryName"] as? String, "Runner")
    let unknown = (caller["subFrames"] as! [[String: Any]]).first!
    XCTAssertNil(unknown["binaryUUID"])
    XCTAssertNil(unknown["subFrames"])
    XCTAssertNoThrow(try NativeJSON.encode(diagnostic))
  }

  func testLoadedImageLookupResolvesAndCachesUUID() {
    // A system function is always loaded, including in the offline macOS harness.
    let function: @convention(c) () -> pid_t = getpid
    let pointer = UInt64(unsafeBitCast(function, to: UInt.self))
    #if arch(arm64)
    let address = pointer & 0x0000000FFFFFFFFF
    #else
    let address = pointer
    #endif
    let images = HangImages()
    let image = images.image(at: address)
    XCTAssertNotNil(image)
    XCTAssertFalse(image?.uuid.isEmpty ?? true)
    XCTAssertEqual(images.image(at: address)?.header, image?.header)
  }

  private func report() throws -> [String: Any] {
    var ring = ScopeRing()
    ring.update(scope: ["pid": 7, "session_id": "same-session"], identity: identity)
    let diagnostic = IOSHangReport.diagnostic(addresses: [4112], images: HangImages(images: []),
        seconds: 2, pid: 7, captureID: "unique")
    let report = try IOSReportBuilder.build(kind: "ios_hang", diagnostic: diagnostic,
        begin: 1000, end: 3000, binaries: ["App": "/App"], ring: ring,
        identity: identity, received: 3000)
    return IOSHangReport.updating(report, seconds: 2, ended: false, end: 3000)
  }

  func testUnfinishedHiddenThenFinalizedSameIDAndNeverReadded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try IOSPendingStore(root: root)
    let pending = try report()
    XCTAssertTrue(try store.putWatchdog(pending, ended: false))
    XCTAssertTrue(try store.reports(identity: identity).isEmpty)
    let finished = IOSHangReport.updating(pending, seconds: 5.4, ended: true, end: 6400)
    XCTAssertTrue(try store.putWatchdog(finished, ended: true))
    let reports = try store.reports(identity: identity)
    XCTAssertEqual(reports.count, 1)
    let saved = try NativeJSON.object(Data(reports[0].utf8))
    XCTAssertEqual(saved["id"] as? String, pending["id"] as? String)
    XCTAssertEqual(saved["ended"] as? Bool, true)
    XCTAssertEqual(saved["source"] as? String, "watchdog")
    XCTAssertEqual((saved["diagnostic"] as? [String: Any])?["hangDuration"] as? String, "5.4 sec")
    XCTAssertEqual((saved["scope"] as? [String: Any])?["session_id"] as? String, "same-session")
    XCTAssertEqual(saved["release"] as? String, "build")
    XCTAssertEqual(saved["app_binaries"] as? [String: String], ["App": "/App"])
    XCTAssertFalse(try store.putWatchdog(pending, ended: false)) // delivered
    try store.ack([saved["id"] as! String])
    XCTAssertFalse(try store.putWatchdog(finished, ended: true)) // acknowledged
    XCTAssertTrue(try store.reports(identity: identity).isEmpty)
  }

  func testKilledProcessRecoversUnfinishedLowerBound() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try IOSPendingStore(root: root)
    let pending = try report()
    XCTAssertTrue(try store.putWatchdog(pending, ended: false))
    let progress = IOSHangReport.updating(pending, seconds: 5, ended: false, end: 6000)
    XCTAssertTrue(try store.putWatchdog(progress, ended: false))
    XCTAssertTrue(try store.reports(identity: identity).isEmpty)
    let restarted = try IOSPendingStore(root: root)
    let recovered = try restarted.reports(identity: ["release": "next-build"])
    XCTAssertEqual(recovered.count, 1)
    let saved = try NativeJSON.object(Data(recovered[0].utf8))
    XCTAssertEqual(saved["ended"] as? Bool, false)
    XCTAssertEqual(saved["release"] as? String, "build")
    XCTAssertEqual((saved["diagnostic"] as? [String: Any])?["hangDuration"] as? String, "5.0 sec")
    XCTAssertFalse(try restarted.putWatchdog(progress, ended: true))
    try restarted.ack([saved["id"] as! String])
    XCTAssertFalse(try restarted.put(progress))
  }

  func testClockActiveStateThresholdAndFirstResponseDuration() {
    var now = 0.0
    var active = true
    var timing = HangTiming(timeout: 2, clock: { now }, isActive: { active })
    timing.appStateChanged()
    now = 1
    XCTAssertNil(timing.poll()) // short hang
    timing.respond()
    now = 2.99
    XCTAssertNil(timing.poll())
    now = 3
    XCTAssertEqual(timing.poll(), .began(2))
    now = 4
    XCTAssertEqual(timing.poll(), .ongoing(3))
    now = 4.5
    timing.respond()
    now = 4.75
    timing.respond()
    XCTAssertEqual(timing.poll(), .ended(3.5)) // first response, not poll time
    active = false
    timing.appStateChanged()
    now = 1000
    XCTAssertNil(timing.poll())
    active = true
    timing.appStateChanged()
    now = 1001
    XCTAssertNil(timing.poll()) // suspension wasn't counted
    now = 1002
    XCTAssertEqual(timing.poll(), .began(2))
    now = 1003
    active = false
    timing.appStateChanged()
    now = 2000
    XCTAssertEqual(timing.poll(), .ended(3)) // lifecycle callback proved recovery
    XCTAssertNil(timing.poll())
  }

  func testDisabledAndTenReportProcessCapAndMetricKitPolicy() {
    var now = 0.0
    var timing = HangTiming(timeout: 0, clock: { now }, isActive: { true })
    timing.appStateChanged()
    now = 100
    XCTAssertNil(timing.poll())
    timing.timeout = 2
    timing.appStateChanged()
    for _ in 0..<10 {
      now += 2
      XCTAssertEqual(timing.poll(), .began(2))
      now += 1
      timing.respond()
      XCTAssertEqual(timing.poll(), .ended(3))
    }
    now += 100
    XCTAssertNil(timing.poll())
    XCTAssertFalse(IOSHangReport.acceptsMetricHang(watchdogEnabled: true))
    XCTAssertTrue(IOSHangReport.acceptsMetricHang(watchdogEnabled: false))
  }
}
