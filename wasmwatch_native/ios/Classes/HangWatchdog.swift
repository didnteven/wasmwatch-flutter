import Darwin
import Foundation
import MachO
#if canImport(UIKit)
import UIKit
#endif

// The clock and active-state input are injectable; all times are monotonic seconds.
// The runtime serializes access with its lock, never held during stack capture.
struct HangTiming {
  enum Event: Equatable {
    case began(Double)
    case ongoing(Double)
    case ended(Double)
  }

  var timeout: Double
  private let clock: () -> Double
  private let isActive: () -> Bool
  private var lastResponse: Double
  private var active = false
  private var began: Double?
  private var recovered: Double?
  private var count = 0

  init(timeout: Double, clock: @escaping () -> Double, isActive: @escaping () -> Bool) {
    self.timeout = timeout
    self.clock = clock
    self.isActive = isActive
    lastResponse = clock()
  }

  mutating func respond() {
    let now = clock()
    if began != nil && recovered == nil { recovered = now }
    lastResponse = now
  }

  mutating func appStateChanged() {
    // A lifecycle callback itself proves that the main thread responded. End any
    // detected hang here, before suspension, and discard the inactive interval.
    respond()
    active = isActive()
  }

  mutating func poll() -> Event? {
    let now = clock()
    if let start = began, let end = recovered {
      began = nil
      recovered = nil
      return .ended(max(0, end - start))
    }
    guard active, timeout > 0 else { return nil }
    if let start = began { return .ongoing(max(0, now - start)) }
    guard count < 10, now - lastResponse >= timeout else { return nil }
    began = lastResponse
    count += 1
    return .began(now - lastResponse)
  }
}

struct HangImage {
  let header: UInt64
  let end: UInt64
  let path: String
  let uuid: String
}

final class HangImages {
  private var cache: [UInt64: HangImage] = [:]
  private let injected: [HangImage]?

  init(images: [HangImage]? = nil) { injected = images }

  func image(at address: UInt64) -> HangImage? {
    if let images = injected { return images.first { address >= $0.header && address < $0.end } }
    var info = Dl_info()
    guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0,
          let base = info.dli_fbase, let name = info.dli_fname else { return nil }
    let headerAddress = UInt64(UInt(bitPattern: base))
    if let saved = cache[headerAddress] { return saved }
    let header = base.assumingMemoryBound(to: mach_header_64.self).pointee
    guard header.magic == MH_MAGIC_64 else { return nil }
    var command = base.advanced(by: MemoryLayout<mach_header_64>.size)
    let end = command.advanced(by: Int(header.sizeofcmds))
    var uuid: String?
    for _ in 0..<header.ncmds {
      guard command + MemoryLayout<load_command>.size <= end else { break }
      let load = command.assumingMemoryBound(to: load_command.self).pointee
      guard load.cmdsize >= MemoryLayout<load_command>.size,
            command + Int(load.cmdsize) <= end else { break }
      if load.cmd == LC_UUID && load.cmdsize >= MemoryLayout<uuid_command>.size {
        uuid = UUID(uuid: command.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
        break
      }
      command = command.advanced(by: Int(load.cmdsize))
    }
    guard let uuid = uuid else { return nil }
    let image = HangImage(header: headerAddress, end: UInt64.max,
                          path: String(cString: name), uuid: uuid)
    cache[headerAddress] = image
    return image
  }
}

enum IOSHangReport {
  static func acceptsMetricHang(watchdogEnabled: Bool) -> Bool { !watchdogEnabled }

  // `raw` is [pc, lr, frame-pointer chain…] from the capture, innermost first.
  static func frames(_ raw: [UInt64], images: HangImages,
                     mainExecutable: String? = Bundle.main.executableURL?.lastPathComponent) -> [UInt64] {
    func name(_ address: UInt64) -> String? {
      images.image(at: address).map { ($0.path as NSString).lastPathComponent }
    }
    var out: [UInt64] = []
    if let pc = raw.first, pc != 0 { out.append(pc) }
    // LR is the caller only while the top function has no frame of its own. Syscall
    // traps in libsystem_kernel are such leaves; elsewhere LR is often stale.
    if raw.count > 1, let pc = out.first, raw[1] != 0, raw[1] != pc,
       name(pc) == "libsystem_kernel.dylib" {
      out.append(raw[1])
    }
    for address in raw.dropFirst(2) where address != 0 && address != out.last { out.append(address) }
    // The main thread bottoms out in UIKit → the app's main → dyld's start; frame
    // records read past that are leftover stack memory.
    if let mainExecutable = mainExecutable,
       let last = out.lastIndex(where: { name($0) == "UIKitCore" }) {
      var end = last + 1
      while end < out.count && name(out[end]) == mainExecutable { end += 1 }
      if end < out.count && name(out[end]) == "dyld" { end += 1 }
      out.removeSubrange(end...)
    }
    return out
  }

  static func duration(_ seconds: Double) -> String {
    String(format: "%.1f sec", locale: Locale(identifier: "en_US_POSIX"), seconds)
  }

  // MetricKit roots are innermost. Each caller is nested in subFrames.
  static func diagnostic(addresses: [UInt64], images: HangImages, seconds: Double,
                         pid: Int, captureID: String) -> [String: Any] {
    var child: [String: Any]?
    for address in addresses.reversed() {
      var frame: [String: Any] = ["address": address, "sampleCount": 1]
      if let image = images.image(at: address) {
        frame["binaryName"] = (image.path as NSString).lastPathComponent
        frame["binaryUUID"] = image.uuid
        frame["offsetIntoBinaryTextSegment"] = address - image.header
      }
      if let child = child { frame["subFrames"] = [child] }
      child = frame
    }
    return ["hangDuration": duration(seconds),
            "diagnosticMetaData": ["pid": pid, "watchdogHangID": captureID],
            "callStackTree": ["callStacks": [["threadAttributed": true,
                "callStackRootFrames": child.map { [$0] } ?? []]]]]
  }

  static func updating(_ original: [String: Any], seconds: Double, ended: Bool,
                       end: Int64) -> [String: Any] {
    var report = original
    var diagnostic = report["diagnostic"] as? [String: Any] ?? [:]
    diagnostic["hangDuration"] = duration(seconds)
    report["diagnostic"] = diagnostic
    report["source"] = "watchdog"
    report["ended"] = ended
    report["payload_end"] = end
    return report
  }
}

#if canImport(UIKit) && arch(arm64)
// Only scalar operations and Mach calls in this function while suspended. All
// storage, including thread state and the two-word frame record, is preallocated.
// In particular, no Swift collections, closures, locks, logging or ObjC calls.
private func captureMainStack(port: thread_t, low: UInt64, high: UInt64,
                              state: UnsafeMutablePointer<arm_thread_state64_t>,
                              record: UnsafeMutablePointer<UInt64>,
                              addresses: UnsafeMutablePointer<UInt64>) -> Int {
  guard thread_suspend(port) == KERN_SUCCESS else { return 0 }
  defer { thread_resume(port) }
  var words = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
  let rawState = UnsafeMutableRawPointer(state).assumingMemoryBound(to: UInt32.self)
  guard thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), rawState, &words) == KERN_SUCCESS else {
    return 0
  }
  let mask: UInt64 = 0x0000000FFFFFFFFF
  let pc = state.pointee.__pc & mask
  let lr = state.pointee.__lr & mask
  var fp = state.pointee.__fp & mask
  // [0] = pc, [1] = lr (IOSHangReport.frames decides whether lr is a real caller).
  addresses[0] = pc
  addresses[1] = lr
  var count = 2
  // Dart AOT frames keep their own stack pointer, so their frame records are only
  // 8-byte aligned; requiring 16 stopped the walk at the first Dart frame.
  while count < 128 && high >= 16 && fp >= low && fp <= high - 16 && fp & 7 == 0 {
    var copied: vm_size_t = 0
    let result = vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16,
        vm_address_t(UInt(bitPattern: record)), &copied)
    if result != KERN_SUCCESS || copied != 16 { break }
    let caller = record[0] & mask
    let address = record[1] & mask
    if address == 0 { break }
    if address != addresses[count - 1] { addresses[count] = address; count += 1 }
    if caller <= fp || caller & 7 != 0 { break }
    fp = caller
  }
  return count
}

final class IOSHangWatchdog {
  static var debuggerAttached: Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    return sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 &&
      (info.kp_proc.p_flag & P_TRACED) != 0
  }

  private let lock = NSLock()
  private var active: Bool
  private var timing: HangTiming!
  private var pingPending = false
  private var generation = 0
  private let tick: Double
  private let port: thread_t
  private let low: UInt64
  private let high: UInt64
  private let state = UnsafeMutablePointer<arm_thread_state64_t>.allocate(capacity: 1)
  private let record = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
  private let addresses = UnsafeMutablePointer<UInt64>.allocate(capacity: 128)
  private let onEvent: (HangTiming.Event, [UInt64]) -> Void
  private var observers: [NSObjectProtocol] = []

  // Main thread only (its port and stack bounds are taken here); nil elsewhere.
  // One instance/thread per process, configured by the first start.
  init?(timeout: Double, onEvent: @escaping (HangTiming.Event, [UInt64]) -> Void) {
    guard Thread.isMainThread else { return nil }
    active = UIApplication.shared.applicationState == .active
    port = pthread_mach_thread_np(pthread_self())
    high = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(pthread_self())))
    low = high - UInt64(pthread_get_stacksize_np(pthread_self()))
    tick = min(0.25, max(0.1, timeout / 8))
    self.onEvent = onEvent
    state.initialize(to: arm_thread_state64_t())
    record.initialize(repeating: 0, count: 2)
    addresses.initialize(repeating: 0, count: 128)
    timing = HangTiming(timeout: timeout, clock: { ProcessInfo.processInfo.systemUptime },
                        isActive: { [unowned self] in self.active })
    timing.appStateChanged()
    for name in [UIApplication.didBecomeActiveNotification,
                 UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] notification in
        guard let self = self else { return }
        self.lock.lock()
        self.active = notification.name == UIApplication.didBecomeActiveNotification
        self.generation += 1
        self.pingPending = false
        self.timing.appStateChanged()
        self.lock.unlock()
      })
    }
    let thread = Thread { [self] in run() }
    thread.name = "dev.wasmwatch.hang-watchdog"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  func configure(timeout: Double) {
    lock.lock()
    if timing.timeout != timeout {
      timing.timeout = timeout
      timing.appStateChanged()
    }
    lock.unlock()
  }

  private func run() {
    while true {
      autoreleasepool {
        let debugging = Self.debuggerAttached
        lock.lock()
        if debugging { timing.appStateChanged() }
        let event = debugging ? nil : timing.poll()
        let shouldPing = active && timing.timeout > 0 && !debugging && !pingPending
        let token = generation
        if shouldPing { pingPending = true }
        lock.unlock()
        if shouldPing {
          DispatchQueue.main.async { [self] in
            lock.lock()
            if token == generation {
              pingPending = false
              timing.respond()
            }
            lock.unlock()
          }
        }
        if let event = event {
          var captured: [UInt64] = []
          if case .began = event {
            let count = captureMainStack(port: port, low: low, high: high,
                state: state, record: record, addresses: addresses)
            // The main thread has resumed before any allocation/image lookup.
            captured = Array(UnsafeBufferPointer(start: addresses, count: count))
          }
          onEvent(event, captured)
        }
      }
      Thread.sleep(forTimeInterval: tick)
    }
  }
}
#endif
