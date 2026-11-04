import Flutter
import Foundation
import MetricKit

public final class WasmWatchNativePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "wasmwatch/native", binaryMessenger: registrar.messenger())
    let plugin = WasmWatchNativePlugin()
    registrar.addMethodCallDelegate(plugin, channel: channel)
    if #available(iOS 14.0, *) { MetricCapture.shared.attach(channel) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if #available(iOS 14.0, *) {
      MetricCapture.shared.handle(call, result: result)
    } else {
      switch call.method {
      case "start": result([String]())
      case "setScope", "ack": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

@available(iOS 14.0, *)
private final class MetricCapture: NSObject, MXMetricManagerSubscriber {
  static let shared = MetricCapture()
  private let queue = DispatchQueue(label: "dev.wasmwatch.native.disk")
  // Channel/subscription and currentScope belong to the main thread. All other
  // mutable state and all filesystem/MetricKit JSON work belong to queue.
  private var channels: [FlutterMethodChannel] = []
  private var subscribed = false
  private var currentScope: [String: Any]?
  private var store: IOSPendingStore?
  private var ring = ScopeRing()
  private var identity: [String: Any]?
  private var binaries: [String: String] = [:]
  private var started = false
  private var watchdogEnabled = false // disk queue; controls MetricKit filtering
  private var hangReport: [String: Any]?
  private var lastHangWrite: Double = 0
  private let hangImages = HangImages()
  #if arch(arm64)
  private var watchdog: IOSHangWatchdog? // main thread, retained for the process
  #endif

  func attach(_ channel: FlutterMethodChannel) {
    channels.append(channel)
    if !subscribed {
      subscribed = true
      MXMetricManager.shared.add(self)
    }
  }

  private func prepare() throws -> IOSPendingStore {
    if let store = store { return store }
    let support = try FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
    let newStore = try IOSPendingStore(root: support.appendingPathComponent("wasmwatch", isDirectory: true))
    if let data = try newStore.read("scopes.json"),
       let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      ring = ScopeRing(entries)
    }
    binaries = appBinaries()
    store = newStore
    return newStore
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "start":
        guard let input = call.arguments as? [String: Any],
              let release = input["release"] as? String, !release.isEmpty,
              let install = input["install_id"] as? String, !install.isEmpty,
              input["environment"] == nil || input["environment"] is String else {
          throw NativeJSON.sizeError
        }
        let next = try NativeJSON.boundedObject(String(decoding: NativeJSON.encode(
            input.filter { ["release", "environment", "install_id"].contains($0.key) }), as: UTF8.self))
        let scope = currentScope
        let timeout = max(0, (input["app_hang_timeout_ms"] as? NSNumber)?.doubleValue ?? 2000) / 1000
        let enabled = configureWatchdog(timeout: timeout)
        work(result) {
          let store = try self.prepare()
          try store.saveState(next, name: "identity.json")
          self.identity = next
          self.watchdogEnabled = enabled
          // Dart may send its first scope before start. Bind it to this start's
          // identity, never the identity of the preceding process.
          if let scope = scope { try self.saveScope(scope, store: store) }
          try self.receive(MXMetricManager.shared.pastDiagnosticPayloads, store: store)
          let reports = try store.reports(identity: next)
          self.started = true
          return reports
        }
      case "setScope":
        guard let text = call.arguments as? String else { throw NativeJSON.sizeError }
        let scope = try NativeJSON.boundedObject(text)
        currentScope = scope
        work(result) {
          let store = try self.prepare()
          try self.saveScope(scope, store: store)
          return nil
        }
      case "ack":
        guard let ids = call.arguments as? [String] else { throw NativeJSON.sizeError }
        work(result) { try self.prepare().ack(ids); return nil }
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(platformError(error)) }
  }

  private func configureWatchdog(timeout: Double) -> Bool {
    #if arch(arm64)
    if let watchdog = watchdog {
      watchdog.configure(timeout: timeout)
      return timeout > 0 && !IOSHangWatchdog.debuggerAttached
    }
    guard timeout > 0, !IOSHangWatchdog.debuggerAttached else { return false }
    watchdog = IOSHangWatchdog(timeout: timeout) { event, addresses in
      self.queue.async {
        do { try self.saveHang(event, addresses: addresses) }
        catch { NSLog("WasmWatch hang watchdog: %@", error.localizedDescription) }
      }
    }
    return watchdog != nil
    #else
    return false
    #endif
  }

  private func saveHang(_ event: HangTiming.Event, addresses: [UInt64]) throws {
    let store = try prepare()
    switch event {
    case .began(let seconds):
      let end = milliseconds(Date())
      let diagnostic = IOSHangReport.diagnostic(
          addresses: IOSHangReport.frames(addresses, images: hangImages), images: hangImages,
          seconds: seconds, pid: Int(getpid()), captureID: UUID().uuidString)
      let report = try IOSReportBuilder.build(kind: "ios_hang", diagnostic: diagnostic,
          begin: end - Int64(seconds * 1000), end: end, binaries: binaries,
          ring: ring, identity: identity, received: end)
      let pending = IOSHangReport.updating(report, seconds: seconds, ended: false, end: end)
      if try store.putWatchdog(pending, ended: false) { hangReport = pending }
      lastHangWrite = seconds
    case .ongoing(let seconds):
      // Refresh the lower bound once a second without taking another stack.
      guard seconds - lastHangWrite >= 1, let report = hangReport else { return }
      let begin = report["payload_begin"] as? Int64 ?? 0
      let pending = IOSHangReport.updating(report, seconds: seconds, ended: false,
          end: begin + Int64(seconds * 1000))
      try store.putWatchdog(pending, ended: false)
      lastHangWrite = seconds
    case .ended(let seconds):
      guard let report = hangReport else { return }
      let begin = report["payload_begin"] as? Int64 ?? 0
      let finished = IOSHangReport.updating(report, seconds: seconds, ended: true,
          end: begin + Int64(seconds * 1000))
      if try store.putWatchdog(finished, ended: true) { notify() }
      hangReport = nil
    }
  }

  private func saveScope(_ scope: [String: Any], store: IOSPendingStore) throws {
    var next = ring
    next.update(scope: scope, identity: identity)
    try store.saveState(next.entries, name: "scopes.json")
    ring = next
  }

  private func work(_ result: @escaping FlutterResult, _ action: @escaping () throws -> Any?) {
    queue.async {
      do {
        let value = try action()
        DispatchQueue.main.async { result(value) }
      } catch {
        let failure = self.platformError(error)
        DispatchQueue.main.async { result(failure) }
      }
    }
  }

  private func platformError(_ error: Error) -> FlutterError {
    FlutterError(code: "native_capture", message: error.localizedDescription, details: nil)
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    queue.async {
      do {
        let store = try self.prepare()
        let added = try self.receive(payloads, store: store)
        if added && self.started { self.notify() }
      } catch { NSLog("WasmWatch MetricKit diagnostics: %@", error.localizedDescription) }
    }
  }

  @discardableResult private func receive(_ payloads: [MXDiagnosticPayload], store: IOSPendingStore) throws -> Bool {
    var added = false
    for payload in payloads {
      for diagnostic in payload.crashDiagnostics ?? [] {
        added = try save(diagnostic.jsonRepresentation(), kind: "ios_crash",
            begin: payload.timeStampBegin, end: payload.timeStampEnd, store: store) || added
      }
      for diagnostic in payload.hangDiagnostics ?? [] where IOSHangReport.acceptsMetricHang(watchdogEnabled: watchdogEnabled) {
        added = try save(diagnostic.jsonRepresentation(), kind: "ios_hang",
            begin: payload.timeStampBegin, end: payload.timeStampEnd, store: store) || added
      }
    }
    return added
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    queue.async {
      do {
        let store = try self.prepare()
        var added = false
        for payload in payloads {
          let data = payload.applicationExitMetrics?.jsonRepresentation() ?? Data("{}".utf8)
          added = try self.save(data, kind: "ios_exit_metrics", begin: payload.timeStampBegin,
              end: payload.timeStampEnd, store: store) || added
        }
        if added && self.started { self.notify() }
      } catch { NSLog("WasmWatch MetricKit metrics: %@", error.localizedDescription) }
    }
  }

  private func save(_ data: Data, kind: String, begin: Date, end: Date,
                    store: IOSPendingStore) throws -> Bool {
    let report = try IOSReportBuilder.build(kind: kind, diagnostic: NativeJSON.object(data),
        begin: milliseconds(begin), end: milliseconds(end), binaries: binaries,
        ring: ring, identity: identity, received: milliseconds(Date()))
    return try store.put(report)
  }

  private func notify() {
    DispatchQueue.main.async {
      for channel in self.channels { channel.invokeMethod("reportsAvailable", arguments: nil) }
    }
  }

  private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

  private func appBinaries() -> [String: String] {
    var result: [String: String] = [:]
    if let executable = Bundle.main.executableURL {
      result[executable.lastPathComponent] = executable.path
    }
    if let frameworks = Bundle.main.privateFrameworksURL,
       let paths = FileManager.default.enumerator(at: frameworks,
           includingPropertiesForKeys: [.isRegularFileKey]) {
      for case let url as URL in paths {
        // One unreadable file must not disable capture: skip it, it just stays a bare name.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let file = try? FileHandle(forReadingFrom: url) else { continue }
        let magic = try? file.read(upToCount: 4)
        try? file.close()
        // Mach-O (both endiannesses) and universal/fat binaries.
        if let magic = magic, [
          [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe],
          [0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf],
          [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
          [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ].contains(Array(magic).map(Int.init)) {
          result[url.lastPathComponent] = url.path
        }
      }
    }
    return result
  }
}
