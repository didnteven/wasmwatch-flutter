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
        work(result) {
          let store = try self.prepare()
          try store.saveState(next, name: "identity.json")
          self.identity = next
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
      for diagnostic in payload.hangDiagnostics ?? [] {
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
