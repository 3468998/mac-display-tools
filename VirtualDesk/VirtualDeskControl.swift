import AppKit
import CoreGraphics
import Darwin
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
    @Published var refreshChoice: String
    @Published var customRefreshText: String
    @Published var hiDPI: Bool
    @Published var customWidthText: String
    @Published var customHeightText: String
    @Published private(set) var state = VirtualState()
    @Published private(set) var busy = false
    @Published private(set) var status = "准备就绪"
    @Published private(set) var errorText: String?

    private let bridge = VirtualDeskBridge(serial: 0x56445431)
    private var poll: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var configured: DisplayConfiguration?
    private var attemptedAutostart = false

    init() {
        let defaults = UserDefaults.standard
        let savedSize = defaults.string(forKey: "desktopSize") ?? "1920x1080"
        sizeID = VirtualSize.options.contains(where: { $0.id == savedSize }) || savedSize == "custom"
            ? savedSize : "1920x1080"
        customWidthText = String(defaults.object(forKey: "customWidth") as? Int ?? 1920)
        customHeightText = String(defaults.object(forKey: "customHeight") as? Int ?? 1080)
        let savedRefresh = defaults.double(forKey: "refreshRate")
        let initialRefresh = savedRefresh.isFinite && (24...240).contains(savedRefresh) ? savedRefresh : 120
        let initialRefreshChoice = initialRefresh == 60 ? "60" : (initialRefresh == 120 ? "120" : "custom")
        refreshChoice = initialRefreshChoice
        customRefreshText = String(initialRefreshChoice == "custom" ? initialRefresh : 144)
        hiDPI = defaults.object(forKey: "hiDPI") as? Bool ?? true
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleWakeRecovery() }
        }
        refreshStatus()
    }

    deinit {
        poll?.invalidate()
        recoveryTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    var selected: DisplayConfiguration {
        DisplayConfiguration(size: sizeID == "custom"
            ? VirtualSize(width: customWidth, height: customHeight)
            : (VirtualSize.options.first(where: { $0.id == sizeID }) ?? VirtualSize.options[0]),
                             refresh: refresh, hiDPI: hiDPI)
    }

    var customWidth: Int {
        get { Int(customWidthText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        set { customWidthText = String(newValue) }
    }

    var customHeight: Int {
        get { Int(customHeightText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        set { customHeightText = String(newValue) }
    }

    var refresh: Double {
        get {
            switch refreshChoice {
            case "60": return 60
            case "120": return 120
            default: return Double(customRefreshText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
            }
        }
        set {
            refreshChoice = newValue == 60 ? "60" : (newValue == 120 ? "120" : "custom")
            if refreshChoice == "custom" { customRefreshText = String(newValue) }
        }
    }

    var pendingChanges: Bool {
        configured != selected || (state.online && !matchesSelectedMode)
    }
    var validationError: String? {
        let request = selected
        let maxWidth = request.hiDPI ? 3840 : 7680
        let maxHeight = request.hiDPI ? 2160 : 4320
        guard request.size.width >= 800, request.size.height >= 600,
              request.size.width <= maxWidth, request.size.height <= maxHeight else {
            return "桌面尺寸需在 800 × 600 至 \(maxWidth) × \(maxHeight) 之间。"
        }
        guard request.refresh.isFinite, (24...240).contains(request.refresh) else {
            return "刷新率需为 24–240 Hz。"
        }
        return nil
    }
    private var matchesSelectedMode: Bool {
        guard validationError == nil else { return false }
        let scale = selected.hiDPI ? 2 : 1
        return state.logicalWidth == selected.size.width && state.logicalHeight == selected.size.height &&
            state.pixelWidth == selected.size.width * scale && state.pixelHeight == selected.size.height * scale &&
            abs(state.refresh - selected.refresh) < 0.2
    }
    var requestedPixels: String {
        guard validationError == nil else { return "无效配置" }
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
            var invalidRefreshRatesRejected = true
            for invalidRefresh in [23.0, 241.0, Double.nan, Double.infinity] {
                do {
                    try bridge.configureWidth(1920, height: 1080, refresh: invalidRefresh, hiDPI: true)
                    invalidRefreshRatesRejected = false
                } catch { }
            }
            refreshChoice = "custom"
            customRefreshText = "invalid"
            invalidRefreshRatesRejected = invalidRefreshRatesRejected && validationError != nil
            customRefreshText = "60"
            invalidRefreshRatesRejected = invalidRefreshRatesRejected && refreshChoice == "custom" && refresh == 60
            refresh = 120
            refreshStatus()
            record("reject-invalid-refresh-rates", invalidRefreshRatesRejected && state.online &&
                   state.logicalWidth == 1920 && state.logicalHeight == 1080 &&
                   state.matchesHiDPI && abs(state.refresh - 120) < 0.2)

            sizeID = "custom"
            customHeight = 1080
            var invalidSizesRejected = true
            for invalidWidth in ["799", "-1", "invalid", String(Int.max), "999999999999999999999999"] {
                customWidthText = invalidWidth
                await apply()
                invalidSizesRejected = invalidSizesRejected && validationError != nil && errorText != nil &&
                    requestedPixels == "无效配置" && state.online &&
                    state.logicalWidth == 1920 && state.logicalHeight == 1080
            }
            record("reject-invalid-custom-resolution", invalidSizesRejected)

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
            sizeID = "custom"
            customWidth = 2880
            customHeight = 1800
            refresh = 144
            hiDPI = true
            await apply()
            let restored = VirtualDisplayController()
            record("apply-custom-2880x1800-hidpi-144hz", errorText == nil && state.online &&
                   state.logicalWidth == 2880 && state.logicalHeight == 1800 && state.matchesHiDPI &&
                   abs(state.refresh - 144) < 0.2 &&
                   UserDefaults.standard.string(forKey: "desktopSize") == "custom" &&
                   UserDefaults.standard.integer(forKey: "customWidth") == 2880 &&
                   UserDefaults.standard.integer(forKey: "customHeight") == 1800 &&
                   restored.selected == selected)
            sizeID = "1920x1080"
            refresh = 120
            hiDPI = true
            await apply()
            await recoverAfterWake()
            record("wake-recovery-recreates-display", state.online && state.active &&
                   state.logicalWidth == 1920 && state.logicalHeight == 1080 && state.matchesHiDPI &&
                   abs(state.refresh - 120) < 0.2 && errorText == nil)
        }
        stop()
        let removedAndRestored = await waitForDisplayList(before)
        record("stop-removes-display", removedAndRestored &&
               !connectedDisplays().contains { ($0["vendor"] as? UInt32) == 0x56d0 })
        await start()
        record("restart", state.online && state.matchesHiDPI && state.pixelWidth == 3840 && abs(state.refresh - 120) < 0.2)
        stop()
        _ = await waitForDisplayList(before)
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
        let passed = report["passed"] as? Bool == true && errorText == nil
        status = passed ? "运行验证通过" : "运行验证发现问题"
        exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
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

    private func waitForDisplayList(_ expected: [[String: Any]]) async -> Bool {
        for _ in 0..<80 {
            let actual = connectedDisplays()
            if NSDictionary(dictionary: ["displays": expected]) ==
                NSDictionary(dictionary: ["displays": actual]) {
                return true
            }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return false }
        }
        return false
    }

    func start() async {
        guard !busy, !state.online else { return }
        guard validationError == nil else {
            errorText = validationError
            status = "显示模式无效"
            return
        }
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
        guard validationError == nil else {
            errorText = validationError
            status = "显示模式无效"
            return
        }
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
        recoveryTask?.cancel()
        recoveryTask = nil
        bridge.stop()
        configured = nil
        refreshStatus()
        status = "虚拟显示器已关闭"
        errorText = nil
    }

    func copyDiagnostics() {
        refreshStatus()
        var lines = [
            "Virtual Desk diagnostics",
            "App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Virtual display: \(state.online ? "online" : "offline"), active=\(state.active), main=\(state.main)",
            "Mode: desktop=\(state.logicalWidth)x\(state.logicalHeight), pixels=\(state.pixelWidth)x\(state.pixelHeight), refresh=\(state.refresh)",
            "Requested: \(selected.size.width)x\(selected.size.height), \(selected.refresh)Hz, HiDPI=\(selected.hiDPI)",
            "Vendor/Product: 0x56d0/0x0001",
            "Display modes: \(availableModesSummary())"
        ]
        if let errorText { lines.append("Last error: \(errorText)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        status = "诊断信息已复制"
    }

    private func scheduleWakeRecovery() {
        guard configured != nil else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            while self?.busy == true {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.recoverAfterWake()
        }
    }

    private func availableModesSummary() -> String {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success,
              let id = ids.prefix(Int(count)).first(where: {
                  CGDisplayVendorNumber($0) == 0x56d0 && CGDisplayModelNumber($0) == 1
              }) else { return "virtual display offline" }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }.map {
            "\($0.width)x\($0.height)/\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.refreshRate.rounded()))"
        }.joined(separator: ", ")
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
        if !state.online && configured != nil && !busy && errorText == nil {
            status = "虚拟显示器已断开"
        }
    }

    private func recoverAfterWake() async {
        guard !busy, let request = configured else { return }
        begin("正在从睡眠中恢复虚拟显示器…")
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else {
            finish()
            return
        }

        var lastError: Error?
        for attempt in 0..<2 {
            bridge.stop()
            state = VirtualState()
            do {
                try await configure(request)
                remember(request)
                status = "虚拟显示器已从睡眠中恢复"
                finish()
                return
            } catch {
                lastError = error
                bridge.stop()
                state = VirtualState()
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else {
                finish()
                return
            }
        }

        errorText = "唤醒后恢复失败：\(lastError?.localizedDescription ?? "未知错误")。可点击启动按钮重试。"
        status = "虚拟显示器恢复失败"
        finish()
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
        let isPreset = VirtualSize.options.contains(request.size)
        defaults.set(isPreset ? request.size.id : "custom", forKey: "desktopSize")
        if !isPreset {
            defaults.set(request.size.width, forKey: "customWidth")
            defaults.set(request.size.height, forKey: "customHeight")
        }
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
                .disabled(controller.busy || controller.validationError != nil)
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
                                Text("自定义…").tag("custom")
                            }.labelsHidden().frame(width: 180).gridColumnAlignment(.trailing)
                        }
                        GridRow {
                            Text("刷新率")
                            Picker("刷新率", selection: $controller.refreshChoice) {
                                Text("60 Hz").tag("60")
                                Text("120 Hz").tag("120")
                                Text("自定义").tag("custom")
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                        }
                        if controller.sizeID == "custom" {
                            GridRow {
                                Text("自定义桌面")
                                HStack(spacing: 8) {
                                    TextField("宽", text: $controller.customWidthText)
                                        .frame(width: 76)
                                        .accessibilityLabel("自定义桌面宽度")
                                    Text("×").foregroundStyle(.secondary)
                                    TextField("高", text: $controller.customHeightText)
                                        .frame(width: 76)
                                        .accessibilityLabel("自定义桌面高度")
                                }.textFieldStyle(.roundedBorder)
                            }
                        }
                        if controller.refreshChoice == "custom" {
                            GridRow {
                                Text("自定义刷新率")
                                HStack(spacing: 8) {
                                    TextField("Hz", text: $controller.customRefreshText)
                                        .frame(width: 76)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("自定义刷新率")
                                    Text("Hz").foregroundStyle(.secondary)
                                    Text("24–240").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        GridRow {
                            Text("HiDPI")
                            Toggle("HiDPI", isOn: $controller.hiDPI).labelsHidden().toggleStyle(.switch)
                        }
                        stateRow("目标像素尺寸", controller.requestedPixels)
                    }.disabled(controller.busy)
                    if let validationError = controller.validationError {
                        Text(validationError).font(.callout).foregroundStyle(.red)
                    }
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
                    Spacer()
                    Button("复制诊断信息", systemImage: "doc.on.doc") {
                        controller.copyDiagnostics()
                    }
                    .labelStyle(.iconOnly)
                    .help("复制诊断信息")
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
                            .disabled(!controller.pendingChanges || controller.validationError != nil)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Spacer()
                        Button("启动虚拟显示器", systemImage: "play.fill") { Task { await controller.start() } }
                            .disabled(controller.validationError != nil)
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
