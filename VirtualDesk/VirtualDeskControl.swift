import AppKit
import CoreGraphics
import SwiftUI

private struct VirtualState {
    var online = false
    var active = false
    var main = false
    var logicalWidth = 0
    var logicalHeight = 0
    var pixelWidth = 0
    var pixelHeight = 0
    var refresh = 0.0

    var pixels: String { online ? "\(pixelWidth) × \(pixelHeight)" : "未运行" }
    var desktop: String { online ? "\(logicalWidth) × \(logicalHeight)" : "未运行" }
    var matchesHiDPI: Bool { online && pixelWidth == logicalWidth * 2 && pixelHeight == logicalHeight * 2 }
}

private struct VirtualSize: Identifiable, Hashable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var title: String { "\(width) × \(height)" }

    static let options = [
        Self(width: 1920, height: 1080),
        Self(width: 2304, height: 1296),
        Self(width: 2560, height: 1440),
        Self(width: 3008, height: 1692),
        Self(width: 3840, height: 2160)
    ]
}

private struct DisplayConfiguration: Equatable {
    var size = VirtualSize.options[0]
    var refresh = 120.0
    var hiDPI = true
}

@MainActor
private final class VirtualDisplayController: ObservableObject {
    @Published var sizeID: String
    @Published var refresh: Double
    @Published var hiDPI: Bool
    @Published private(set) var state = VirtualState()
    @Published private(set) var busy = false
    @Published private(set) var status = "准备就绪"
    @Published private(set) var errorText: String?

    private let bridge = VirtualDeskBridge(serial: 0x56445431)
    private var poll: Timer?
    private var configured: DisplayConfiguration?
    private var attemptedAutostart = false

    init() {
        let defaults = UserDefaults.standard
        let savedSize = defaults.string(forKey: "desktopSize") ?? "1920x1080"
        sizeID = VirtualSize.options.contains(where: { $0.id == savedSize }) ? savedSize : "1920x1080"
        refresh = defaults.double(forKey: "refreshRate") == 60 ? 60 : 120
        hiDPI = defaults.object(forKey: "hiDPI") as? Bool ?? true
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        refreshStatus()
    }

    deinit { poll?.invalidate() }

    var selected: DisplayConfiguration {
        DisplayConfiguration(size: VirtualSize.options.first(where: { $0.id == sizeID }) ?? VirtualSize.options[0],
                             refresh: refresh, hiDPI: hiDPI)
    }

    var pendingChanges: Bool { configured != selected }
    var requestedPixels: String {
        let scale = hiDPI ? 2 : 1
        return "\(selected.size.width * scale) × \(selected.size.height * scale)"
    }

    func autostartIfRequested() async {
        guard !attemptedAutostart else { return }
        attemptedAutostart = true
        if let index = CommandLine.arguments.firstIndex(of: "--verify"),
           CommandLine.arguments.indices.contains(index + 1) {
            await verify(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if CommandLine.arguments.contains("--start") { await start() }
    }

    private func verify(to reportURL: URL) async {
        let before = connectedDisplays()
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed, "displays": connectedDisplays()])
        }
        sizeID = "1920x1080"
        refresh = 120
        hiDPI = true
        await start()
        record("start-4k120-hidpi", state.online && state.active && state.pixelWidth == 3840 &&
               state.pixelHeight == 2160 && state.matchesHiDPI && abs(state.refresh - 120) < 0.2)
        if state.online {
            for size in VirtualSize.options {
                for scale in [false, true] {
                    sizeID = size.id
                    hiDPI = scale
                    refresh = scale ? 120 : 60
                    await apply()
                    record("apply-\(size.id)-hidpi-\(scale)", errorText == nil && state.online &&
                           state.logicalWidth == size.width && state.logicalHeight == size.height &&
                           state.matchesHiDPI == scale && abs(state.refresh - refresh) < 0.2)
                }
            }
            sizeID = "1920x1080"
            refresh = 120
            hiDPI = true
            await apply()
            makeMain()
            record("make-main", state.main && errorText == nil)
        }
        stop()
        try? await Task.sleep(for: .seconds(4))
        record("stop-removes-display", !connectedDisplays().contains { ($0["vendor"] as? UInt32) == 0x56d0 })
        await start()
        record("restart", state.online && state.matchesHiDPI && state.pixelWidth == 3840 && abs(state.refresh - 120) < 0.2)
        stop()
        try? await Task.sleep(for: .seconds(4))
        let after = connectedDisplays()
        record("physical-displays-preserved", NSDictionary(dictionary: ["displays": before]) == NSDictionary(dictionary: ["displays": after]))
        let report: [String: Any] = [
            "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "checks": checks, "before": before, "after": after
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch {
            errorText = error.localizedDescription
        }
        status = report["passed"] as? Bool == true ? "运行验证通过" : "运行验证发现问题"
    }

    private func connectedDisplays() -> [[String: Any]] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).sorted().map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            return ["id": id, "vendor": CGDisplayVendorNumber(id), "product": CGDisplayModelNumber(id),
                    "main": CGDisplayIsMain(id) != 0, "active": CGDisplayIsActive(id) != 0,
                    "mirror": CGDisplayIsInMirrorSet(id) != 0, "x": bounds.origin.x, "y": bounds.origin.y,
                    "width": mode?.width ?? 0, "height": mode?.height ?? 0,
                    "pixelWidth": mode?.pixelWidth ?? 0, "pixelHeight": mode?.pixelHeight ?? 0,
                    "refresh": mode?.refreshRate ?? 0]
        }
    }

    func start() async {
        guard !busy, !state.online else { return }
        let request = selected
        begin("正在创建虚拟显示器…")
        do {
            bridge.stop()
            try await configure(request)
            remember(request)
            status = "虚拟显示器已启动"
        } catch {
            bridge.stop()
            configured = nil
            errorText = error.localizedDescription
            status = "启动失败"
        }
        finish()
    }

    func apply() async {
        guard !busy, state.online else { return }
        let request = selected
        let previous = configured
        begin("正在应用显示模式…")
        do {
            try await configure(request)
            remember(request)
            status = "显示模式已更新"
        } catch {
            let failure = error.localizedDescription
            if let previous {
                do {
                    try await configure(previous)
                    errorText = failure
                    status = "已恢复上次模式"
                } catch {
                    bridge.stop()
                    configured = nil
                    errorText = "\(failure)；恢复失败：\(error.localizedDescription)"
                    status = "虚拟显示器已关闭"
                }
            } else {
                errorText = failure
                status = "应用失败"
            }
        }
        finish()
    }

    func stop() {
        guard !busy else { return }
        bridge.stop()
        configured = nil
        refreshStatus()
        status = "虚拟显示器已关闭"
        errorText = nil
    }

    func makeMain() {
        guard !busy, state.online else { return }
        begin("正在设置主显示器…")
        do {
            try bridge.makeMain()
            status = "虚拟显示器已设为主屏"
        } catch {
            errorText = error.localizedDescription
            status = "设置失败"
        }
        finish()
    }

    func refreshStatus() {
        let raw = bridge.snapshot()
        state = VirtualState(
            online: raw["online"] as? Bool ?? false,
            active: raw["active"] as? Bool ?? false,
            main: raw["main"] as? Bool ?? false,
            logicalWidth: raw["width"] as? Int ?? 0,
            logicalHeight: raw["height"] as? Int ?? 0,
            pixelWidth: raw["pixelWidth"] as? Int ?? 0,
            pixelHeight: raw["pixelHeight"] as? Int ?? 0,
            refresh: raw["refreshRate"] as? Double ?? 0
        )
        if !state.online && configured != nil && !busy { status = "虚拟显示器已断开" }
    }

    private func configure(_ request: DisplayConfiguration) async throws {
        try bridge.configureWidth(UInt(request.size.width), height: UInt(request.size.height),
                                  refresh: request.refresh, hiDPI: request.hiDPI)
        var lastError: Error?
        // WindowServer publishes the new display and mode list asynchronously.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            do {
                try bridge.selectConfiguredMode()
                refreshStatus()
                let scale = request.hiDPI ? 2 : 1
                if state.online && state.active && state.logicalWidth == request.size.width &&
                    state.logicalHeight == request.size.height && state.pixelWidth == request.size.width * scale &&
                    state.pixelHeight == request.size.height * scale && abs(state.refresh - request.refresh) < 0.2 {
                    try await Task.sleep(for: .milliseconds(500))
                    return
                }
            } catch { lastError = error }
        }
        throw lastError ?? NSError(domain: "local.virtualdesk", code: 10,
            userInfo: [NSLocalizedDescriptionKey: "macOS 未在预期时间内启用所选显示模式。"])
    }

    private func remember(_ request: DisplayConfiguration) {
        configured = request
        let defaults = UserDefaults.standard
        defaults.set(request.size.id, forKey: "desktopSize")
        defaults.set(request.refresh, forKey: "refreshRate")
        defaults.set(request.hiDPI, forKey: "hiDPI")
    }

    private func begin(_ text: String) {
        busy = true
        status = text
        errorText = nil
    }

    private func finish() {
        busy = false
        refreshStatus()
    }
}

@main
struct VirtualDeskControlApp: App {
    @StateObject private var controller = VirtualDisplayController()

    var body: some Scene {
        Window("虚拟显示器", id: "control") {
            VirtualDisplayView()
                .environmentObject(controller)
                .frame(minWidth: 520, maxWidth: 640, minHeight: 580)
                .task { await controller.autostartIfRequested() }
        }
        .defaultSize(width: 540, height: 620)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra("虚拟显示器", systemImage: "display.2") {
            VirtualDisplayMenu().environmentObject(controller)
        }
    }
}

private struct VirtualDisplayMenu: View {
    @EnvironmentObject private var controller: VirtualDisplayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.state.online ? "\(controller.state.pixels) · \(Int(controller.state.refresh.rounded())) Hz" : "未启动")
        Button("打开控制面板", systemImage: "slider.horizontal.3") {
            openWindow(id: "control")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        if controller.state.online {
            Button("关闭虚拟显示器", systemImage: "stop.fill") { controller.stop() }
                .disabled(controller.busy)
        } else {
            Button("启动虚拟显示器", systemImage: "play.fill") { Task { await controller.start() } }
                .disabled(controller.busy)
        }
        Divider()
        Button("退出虚拟显示器") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct VirtualDisplayView: View {
    @EnvironmentObject private var controller: VirtualDisplayController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "display.2")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("虚拟显示器").font(.title3.weight(.semibold))
                Spacer()
                Label(controller.state.online ? "运行中" : "未启动", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(controller.state.online ? Color.green : Color.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("当前状态").font(.headline)
                    Grid(horizontalSpacing: 20, verticalSpacing: 14) {
                        stateRow("桌面尺寸", controller.state.desktop)
                        stateRow("像素尺寸", controller.state.pixels)
                        stateRow("刷新率", controller.state.online ? "\(Int(controller.state.refresh.rounded())) Hz" : "未运行")
                        stateRow("HiDPI", controller.state.online ? (controller.state.matchesHiDPI ? "已启用" : "已关闭") : "未运行")
                        stateRow("显示器角色", controller.state.online ? (controller.state.main ? "主显示器" : "扩展桌面") : "未运行")
                    }
                    Divider()
                    Text("显示模式").font(.headline)
                    Grid(horizontalSpacing: 20, verticalSpacing: 16) {
                        GridRow {
                            Text("桌面尺寸")
                            Picker("桌面尺寸", selection: $controller.sizeID) {
                                ForEach(VirtualSize.options) { option in Text(option.title).tag(option.id) }
                            }.labelsHidden().frame(width: 180).gridColumnAlignment(.trailing)
                        }
                        GridRow {
                            Text("刷新率")
                            Picker("刷新率", selection: $controller.refresh) {
                                Text("60 Hz").tag(60.0)
                                Text("120 Hz").tag(120.0)
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                        }
                        GridRow {
                            Text("HiDPI")
                            Toggle("HiDPI", isOn: $controller.hiDPI).labelsHidden().toggleStyle(.switch)
                        }
                        stateRow("目标像素尺寸", controller.requestedPixels)
                    }.disabled(controller.busy)
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if controller.busy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: controller.errorText == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(controller.errorText == nil ? Color.green : Color.red)
                    }
                    Text(controller.status).font(.callout)
                }
                if let error = controller.errorText {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if controller.state.online {
                        Button("设为主屏", systemImage: "macwindow.on.rectangle") { controller.makeMain() }
                            .disabled(controller.state.main)
                        Spacer()
                        Button("关闭", systemImage: "stop.fill") { controller.stop() }
                        Button("应用模式", systemImage: "checkmark") { Task { await controller.apply() } }
                            .disabled(!controller.pendingChanges)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Spacer()
                        Button("启动虚拟显示器", systemImage: "play.fill") { Task { await controller.start() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }.disabled(controller.busy)
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func stateRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
