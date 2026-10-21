import SwiftUI

@main
struct AudioRouterApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = RouterModel()

    var body: some Scene {
        Window("Audio Router", id: "main") {
            ContentView(inMenuBar: false)
                .environmentObject(model)
        }

        MenuBarExtra("Audio Router", systemImage: "hifispeaker.2") {
            ContentView(inMenuBar: true)
                .environmentObject(model)
                .frame(width: 480, height: 360)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Routes only work while the app runs, so keep it alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @EnvironmentObject private var model: RouterModel
    @Environment(\.openWindow) private var openWindow
    let inMenuBar: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.apps.isEmpty {
                ContentUnavailableView("No Apps Using Audio", systemImage: "speaker.slash",
                                       description: Text("Apps show up here once they open an audio connection."))
            } else {
                List(model.apps) { app in
                    AppRow(app: app)
                }
            }
            Divider()
            HStack {
                Text("System output: \(model.deviceName(model.defaultDeviceUID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if inMenuBar {
                    Button("Open Window") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

private struct AppRow: View {
    @EnvironmentObject private var model: RouterModel
    let app: RouterModel.AudioApp

    private var selection: Binding<String?> {
        Binding(get: { model.assignments[app.id] }, set: { model.setDevice($0, for: app) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                    if app.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.errors[app.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let uid = model.assignments[app.id], !model.isConnected(uid) {
                    Text("Waiting for \(model.deviceName(uid)); using system output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Output", selection: selection) {
                Text("System Output").tag(String?.none)
                Divider()
                ForEach(model.devices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
                if let uid = model.assignments[app.id], !model.isConnected(uid) {
                    Text("\(model.deviceName(uid)) (disconnected)").tag(String?.some(uid))
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(.vertical, 4)
    }
}
