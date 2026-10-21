import AppKit
import CoreAudio

@MainActor
final class RouterModel: ObservableObject {
    struct AudioApp: Identifiable, Equatable {
        let id: String  // bundle identifier, used to remember the choice across launches
        let name: String
        let icon: NSImage
        let processes: Set<AudioObjectID>
        let isPlaying: Bool

        static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.processes == rhs.processes && lhs.isPlaying == rhs.isPlaying
        }
    }

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultDeviceUID: String?
    @Published private(set) var assignments: [String: String]  // app id → device UID
    @Published private(set) var errors: [String: String] = [:]

    /// Names of devices that were ever chosen, so a disconnected one can still be shown.
    private var deviceNames: [String: String]
    private var routes: [String: AudioRoute] = [:]
    private var failedRoutes: [String: AudioRoute.Key] = [:]
    private var timer: Timer?

    init() {
        assignments = UserDefaults.standard.dictionary(forKey: "assignments") as? [String: String] ?? [:]
        deviceNames = UserDefaults.standard.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        refresh()

        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            AudioSystem.observe(selector) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // There is no system-wide notification for "a process started playing", so poll for the indicator.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setDevice(_ uid: String?, for app: AudioApp) {
        assignments[app.id] = uid
        if let uid, let device = devices.first(where: { $0.id == uid }) {
            deviceNames[uid] = device.name
        }
        failedRoutes[app.id] = nil
        errors[app.id] = nil
        UserDefaults.standard.set(assignments, forKey: "assignments")
        UserDefaults.standard.set(deviceNames, forKey: "deviceNames")
        reconcile()
    }

    func deviceName(_ uid: String?) -> String {
        guard let uid else { return "None" }
        return devices.first { $0.id == uid }?.name ?? deviceNames[uid] ?? uid
    }

    func isConnected(_ uid: String) -> Bool {
        devices.contains { $0.id == uid }
    }

    func refresh() {
        let devices = AudioSystem.outputDevices()
        if devices != self.devices { self.devices = devices }
        let defaultUID = AudioSystem.defaultOutputDeviceUID()
        if defaultUID != defaultDeviceUID { defaultDeviceUID = defaultUID }
        let apps = currentApps()
        if apps != self.apps { self.apps = apps }
        reconcile()
    }

    /// Starts, rebuilds or stops routes so they match the current choices, apps and devices.
    private func reconcile() {
        var wanted: [String: AudioRoute.Key] = [:]
        for app in apps {
            if let uid = assignments[app.id], isConnected(uid) {
                wanted[app.id] = AudioRoute.Key(processes: app.processes, deviceUID: uid)
            }
        }

        for (id, route) in routes where wanted[id] != route.key {
            route.stop()
            routes[id] = nil
        }
        for (id, key) in wanted where routes[id] == nil && failedRoutes[id] != key {
            let name = apps.first { $0.id == id }?.name ?? id
            do {
                routes[id] = try AudioRoute(key, name: name)
                failedRoutes[id] = nil
                if errors[id] != nil { errors[id] = nil }
            } catch {
                failedRoutes[id] = key
                errors[id] = error.localizedDescription
            }
        }
    }

    /// Audio processes grouped by the app they belong to, so that e.g. Firefox's
    /// and Chrome's helper processes are routed together with the browser.
    private func currentApps() -> [AudioApp] {
        var groups: [String: (app: NSRunningApplication, processes: Set<AudioObjectID>, isPlaying: Bool)] = [:]
        for process in AudioSystem.processes() {
            guard let app = owningApplication(of: process.pid), app != .current else { continue }
            let id = app.bundleIdentifier ?? app.bundleURL?.path ?? String(app.processIdentifier)
            groups[id, default: (app, [], false)].processes.insert(process.objectID)
            groups[id]!.isPlaying = groups[id]!.isPlaying || process.isPlaying
        }
        return groups
            .map { id, group in
                AudioApp(id: id, name: group.app.localizedName ?? id, icon: group.app.icon ?? NSImage(),
                         processes: group.processes, isPlaying: group.isPlaying)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

/// Private libsystem function that maps e.g. Safari's WebKit GPU process to Safari.
private let responsiblePID: ResponsiblePIDFunction? = {
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()

private func owningApplication(of pid: pid_t) -> NSRunningApplication? {
    if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
        return app
    }
    if let responsible = responsiblePID?(pid), responsible != pid,
       let app = NSRunningApplication(processIdentifier: responsible), app.activationPolicy == .regular {
        return app
    }
    // Fall back to the outermost .app bundle that contains the executable.
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(cString: buffer)
    guard let range = path.range(of: ".app/") else { return nil }
    let bundlePath = String(path[..<range.lowerBound]) + ".app"
    return NSWorkspace.shared.runningApplications.first {
        $0.activationPolicy == .regular && $0.bundleURL?.path == bundlePath
    }
}
