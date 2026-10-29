import AppKit
import Combine
import CoreGraphics
import SwiftUI

private let panelVendor: UInt32 = 1711
private let panelProduct: UInt32 = 45972

private struct BundledDisplayTools {
    let bundle: Bundle

    var appURL: URL { bundle.bundleURL }
    var toolsURL: URL { appURL.appendingPathComponent("Contents/MacOS", isDirectory: true) }
    var profilesURL: URL {
        appURL.appendingPathComponent("Contents/Resources/DisplayProfiles", isDirectory: true)
    }

    func executable(_ name: String) -> URL { toolsURL.appendingPathComponent(name) }
    func profile(_ hz: Int) -> URL { profilesURL.appendingPathComponent("panel-compatible-\(hz)hz.bin") }
    var factoryProfile: URL { profilesURL.appendingPathComponent("panel-factory.bin") }

    func validate() throws {
        for name in ["portable-edid", "display-mode", "startup-manager"] {
            guard FileManager.default.isExecutableFile(atPath: executable(name).path) else {
                throw ControlError.commandFailed("应用内缺少显示控制工具：\(name)")
            }
        }
        for file in [profile(60), profile(120), factoryProfile] {
            guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else {
                throw ControlError.commandFailed("应用内缺少屏幕参数：\(file.lastPathComponent)")
            }
        }
    }
}

private struct ScreenSnapshot {
    let id: CGDirectDisplayID
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let displayModeID: Int32

    var scaleFactor: Double {
        Double(pixelWidth) / Double(max(logicalWidth, 1))
    }

    var isHiDPI: Bool {
        scaleFactor > 1.25
    }
}

private struct ResolutionOption: Identifiable, Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int

    var id: String { "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)" }
    var scale: Double { Double(pixelWidth) / Double(max(width, 1)) }
    var hiDPI: Bool { scale > 1.25 }
    var label: String {
        if hiDPI {
            return "\(width) x \(height)  (HiDPI \(scale.formatted(.number.precision(.fractionLength(1))))x)"
        }
        return "\(width) x \(height)  (1x)"
    }
}

@MainActor
private final class DisplayController: ObservableObject {
    @Published private(set) var screen: ScreenSnapshot?
    @Published private(set) var resolutionOptions: [ResolutionOption] = []
    @Published private(set) var selectedResolutionID = ""
    @Published private(set) var autoReapply = false
    @Published private(set) var preLoginSupportState = "notInstalled"
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "正在检测显示器…"
    @Published private(set) var lastUpdated = Date()

    private let tools = BundledDisplayTools(bundle: .main)
    private var timer: Timer?
    private var isUpdatingSelection = false
    private var bundledToolsAvailable = false

    init() {
        do {
            try tools.validate()
            bundledToolsAvailable = true
            _ = try Self.run(tools.executable("startup-manager"), arguments: ["prepare-bundle", tools.appURL.path])
        } catch {
            statusMessage = "操作失败：\(error.localizedDescription)"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if CommandLine.arguments.contains("--enable-prelogin") {
            Task { @MainActor [weak self] in
                guard let self, self.preLoginSupportState != "loaded" else { return }
                self.setLoginWindowSupport(true)
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    var detected: Bool { screen != nil }
    var refreshChoice: Int { (screen?.refreshRate ?? 60) >= 90 ? 120 : 60 }
    var hiDPIEnabled: Bool { screen?.isHiDPI ?? false }
    var loginWindowSupportInstalled: Bool {
        preLoginSupportState == "loaded" || preLoginSupportState == "installed"
    }
    var loginWindowSupportConflict: Bool { preLoginSupportState == "differentConfiguration" }
    var statusIsFailure: Bool {
        let message = statusMessage.lowercased()
        return message.hasPrefix("操作失败") ||
            message.contains("未能启用") ||
            message.contains("找不到") ||
            message.contains("失败") ||
            message.contains("execution error") ||
            message.contains("denied") ||
            message.contains("cancel")
    }

    var currentResolutionSummary: String {
        guard let screen else { return "未连接" }
        let scale = screen.scaleFactor
        let scaleText = screen.isHiDPI
            ? "HiDPI \(scale.formatted(.number.precision(.fractionLength(1))))x"
            : "标准 1x"
        return "\(screen.logicalWidth) x \(screen.logicalHeight)  ·  \(scaleText)"
    }

    var outputSummary: String {
        guard let screen else { return "等待连接" }
        return "\(screen.pixelWidth) x \(screen.pixelHeight) @ \(Int(screen.refreshRate.rounded())) Hz"
    }

    func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard result == .success,
              let id = ids.prefix(Int(count)).first(where: {
                  CGDisplayVendorNumber($0) == panelVendor &&
                  CGDisplayModelNumber($0) == panelProduct
              }),
              CGDisplayIsOnline(id) != 0,
              let current = CGDisplayCopyDisplayMode(id) else {
            screen = nil
            resolutionOptions = []
            selectedResolutionID = ""
            refreshSystemSettingsStatus()
            statusMessage = "未检测到指定便携屏"
            lastUpdated = Date()
            return
        }

        let newScreen = ScreenSnapshot(
            id: id,
            logicalWidth: current.width,
            logicalHeight: current.height,
            pixelWidth: current.pixelWidth,
            pixelHeight: current.pixelHeight,
            refreshRate: current.refreshRate,
            displayModeID: current.ioDisplayModeID
        )
        screen = newScreen
        resolutionOptions = fetchResolutionOptions(displayID: id, refreshRate: current.refreshRate)
        let matching = resolutionOptions.first(where: {
            $0.width == current.width && $0.height == current.height
        })
        isUpdatingSelection = true
        selectedResolutionID = matching?.id ?? resolutionOptions.first?.id ?? ""
        isUpdatingSelection = false
        refreshSystemSettingsStatus()
        if !isBusy && (statusMessage == "正在检测显示器…" || statusMessage == "未检测到指定便携屏") {
            statusMessage = "显示器已连接"
        }
        lastUpdated = Date()
    }

    func selectRefresh(_ hz: Int) {
        guard !isBusy, bundledToolsAvailable, let screen else { return }
        let size = (screen.logicalWidth, screen.logicalHeight)
        perform("正在切换到 \(hz) Hz…") {
            try Self.applyProfile(hz: hz, tools: self.tools)
            try Self.setMode(hz: hz, width: size.0, height: size.1, tools: self.tools)
            return "已切换到 \(hz) Hz"
        } onFailure: { error in
            if hz == 120 {
                do {
                    try Self.applyProfile(hz: 60, tools: self.tools)
                    try Self.setMode(hz: 60, width: size.0, height: size.1, tools: self.tools)
                    return "120 Hz 未能启用，已恢复 60 Hz"
                } catch {
                    return "切换失败：\(error.localizedDescription)"
                }
            }
            return "切换失败：\(error.localizedDescription)"
        }
    }

    func selectResolution(_ id: String) {
        guard !isBusy, bundledToolsAvailable, !isUpdatingSelection,
              let option = resolutionOptions.first(where: { $0.id == id }),
              let screen else { return }
        perform("正在调整 HiDPI 分辨率…") {
            try Self.setMode(
                hz: Int(screen.refreshRate.rounded()),
                width: option.width,
                height: option.height,
                tools: self.tools
            )
            return "桌面分辨率已更新"
        }
    }

    func toggleHiDPI(_ enabled: Bool) {
        guard !isBusy, bundledToolsAvailable, let screen else { return }
        let target = if enabled {
            resolutionOptions.first(where: { $0.width == 1920 && $0.height == 1080 && $0.hiDPI })
        } else {
            resolutionOptions.first(where: { $0.width == 3840 && $0.height == 2160 && !$0.hiDPI })
        }
        guard let target else {
            statusMessage = enabled ? "找不到可用的 HiDPI 模式" : "找不到原生 1x 模式"
            return
        }
        perform(enabled ? "正在开启 HiDPI…" : "正在关闭 HiDPI…") {
            try Self.setMode(
                hz: Int(screen.refreshRate.rounded()),
                width: target.width,
                height: target.height,
                tools: self.tools
            )
            return enabled ? "HiDPI 已开启" : "已切换到原生 1x"
        }
    }

    func reapplyCurrentSettings() {
        guard !isBusy, bundledToolsAvailable else { return }
        guard let screen else {
            perform("正在恢复便携屏识别…") {
                let hz = UserDefaults.standard.integer(forKey: "selectedRefreshRate") == 60 ? 60 : 120
                _ = try Self.run(self.tools.executable("portable-edid"), arguments: ["inspect"])
                _ = try Self.run(self.tools.executable("portable-edid"), arguments: [
                    "ensure", self.tools.profile(hz).path, self.tools.factoryProfile.path
                ])
                return "兼容配置已重新应用"
            }
            return
        }
        let hz = Int(screen.refreshRate.rounded()) >= 90 ? 120 : 60
        let width = screen.logicalWidth
        let height = screen.logicalHeight
        perform("正在重新应用当前设置…") {
            try Self.applyProfile(hz: hz, tools: self.tools)
            try Self.setMode(hz: hz, width: width, height: height, tools: self.tools)
            return "当前设置已重新应用"
        }
    }

    func setAutomaticRepair(_ enabled: Bool) {
        guard !isBusy, bundledToolsAvailable else { return }
        perform(enabled ? "正在开启重连自动恢复…" : "正在关闭重连自动恢复…") {
            try Self.setLaunchAgent(enabled, tools: self.tools)
            return enabled ? "重连自动恢复已开启" : "重连自动恢复已关闭"
        }
    }

    func setLoginWindowSupport(_ enabled: Bool) {
        guard !isBusy, bundledToolsAvailable else { return }
        guard !loginWindowSupportConflict else {
            statusMessage = "检测到同名系统启动任务不属于本程序，未作修改"
            return
        }
        let executable = tools.executable("startup-manager")
        let bundlePath = tools.appURL.path
        let arguments = [enabled ? "enable-prelogin" : "disable-prelogin"]
        isBusy = true
        statusMessage = enabled ? "等待 macOS 管理员授权…" : "等待 macOS 管理员授权移除…"
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    if enabled {
                        _ = try runPortableDisplayCommand(executable, arguments: ["prepare-bundle", bundlePath])
                    }
                    _ = try runPortableDisplayCommand(executable, arguments: arguments)
                    return (true, enabled
                        ? "开机显示支持已安装；下次启动时生效"
                        : "开机显示支持已移除")
                } catch {
                    return (false, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            self.isBusy = false
            self.statusMessage = result.0 ? result.1 : "操作失败：\(result.1)"
            self.refreshSystemSettingsStatus()
        }
    }

    private func perform(
        _ startingMessage: String,
        operation: () throws -> String,
        onFailure: ((Error) -> String)? = nil
    ) {
        isBusy = true
        statusMessage = startingMessage
        do {
            statusMessage = try operation()
        } catch {
            statusMessage = onFailure?(error) ?? "操作失败：\(error.localizedDescription)"
        }
        isBusy = false
        refresh()
    }

    private func fetchResolutionOptions(displayID: CGDirectDisplayID, refreshRate: Double) -> [ResolutionOption] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return [] }
        var choices: [String: ResolutionOption] = [:]
        for mode in modes where mode.isUsableForDesktopGUI() && abs(mode.refreshRate - refreshRate) < 0.2 {
            let scale = Double(mode.pixelWidth) / Double(max(mode.width, 1))
            let nativeMode = mode.width == 3840 && mode.height == 2160 &&
                mode.pixelWidth == 3840 && mode.pixelHeight == 2160
            guard nativeMode || (mode.pixelWidth > mode.width && mode.pixelHeight > mode.height && scale > 1.25) else {
                continue
            }
            let choice = ResolutionOption(
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight
            )
            if let existing = choices[choice.id] {
                if existing.scale < choice.scale { choices[choice.id] = choice }
            } else {
                choices[choice.id] = choice
            }
        }
        return choices.values.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.height > $1.height
        }
    }

    private func refreshSystemSettingsStatus() {
        guard bundledToolsAvailable,
              let output = try? Self.run(tools.executable("startup-manager"), arguments: ["status"]),
              let data = output.data(using: .utf8),
              let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            autoReapply = false
            preLoginSupportState = "notInstalled"
            return
        }
        autoReapply = status["loaded"] as? Bool == true
        preLoginSupportState = status["preLoginSupport"] as? String ?? "notInstalled"
    }

    private static func applyProfile(hz: Int, tools: BundledDisplayTools) throws {
        let rate = hz >= 90 ? 120 : 60
        // Save the selected background profile before a hotplug is generated.
        _ = try run(tools.executable("startup-manager"), arguments: ["select-profile", String(rate)])
        _ = try run(tools.executable("portable-edid"), arguments: ["apply", tools.profile(rate).path])
        UserDefaults.standard.set(rate, forKey: "selectedRefreshRate")
    }

    private static func setMode(hz: Int, width: Int, height: Int, tools: BundledDisplayTools) throws {
        _ = try run(
            tools.executable("display-mode"),
            arguments: ["--set-mode", String(hz), String(width), String(height), "--permanent"]
        )
    }

    private static func setLaunchAgent(_ enabled: Bool, tools: BundledDisplayTools) throws {
        if enabled {
            _ = try run(tools.executable("startup-manager"), arguments: ["install", tools.appURL.path])
            let preferred = UserDefaults.standard.integer(forKey: "selectedRefreshRate")
            if preferred == 60 || preferred == 120 {
                _ = try run(tools.executable("startup-manager"), arguments: ["select-profile", String(preferred)])
            }
        } else {
            _ = try run(tools.executable("startup-manager"), arguments: ["disable"])
        }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> String {
        let result = try runAllowFailure(executable.path, arguments: arguments)
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControlError.commandFailed(detail.isEmpty ? executable.lastPathComponent : detail)
        }
        return result.output
    }

    private static func runAllowFailure(_ path: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private enum ControlError: LocalizedError {
    case agentConflict
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .agentConflict:
            return "启动项路径已被其他文件占用，未作修改"
        case .commandFailed(let detail):
            return detail
        }
    }
}

@main
struct PortableDisplayControlApp: App {
    @StateObject private var controller = DisplayController()

    var body: some Scene {
        WindowGroup {
            ControlView()
                .environmentObject(controller)
                .frame(minWidth: 520, idealWidth: 580, minHeight: 620, idealHeight: 690)
        }
        .windowResizability(.contentSize)
    }
}

private struct ControlView: View {
    @EnvironmentObject private var controller: DisplayController

    private var refreshBinding: Binding<Int> {
        Binding(
            get: { controller.refreshChoice },
            set: { controller.selectRefresh($0) }
        )
    }

    private var hiDPIBinding: Binding<Bool> {
        Binding(
            get: { controller.hiDPIEnabled },
            set: { controller.toggleHiDPI($0) }
        )
    }

    private var autoRepairBinding: Binding<Bool> {
        Binding(
            get: { controller.autoReapply },
            set: { controller.setAutomaticRepair($0) }
        )
    }

    private var loginWindowSupportBinding: Binding<Bool> {
        Binding(
            get: { controller.loginWindowSupportInstalled },
            set: { controller.setLoginWindowSupport($0) }
        )
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: { controller.selectedResolutionID },
            set: { controller.selectResolution($0) }
        )
    }

    private var visibleResolutionOptions: [ResolutionOption] {
        controller.resolutionOptions.filter { controller.hiDPIEnabled ? $0.hiDPI : !$0.hiDPI }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("屏幕") {
                    LabeledContent("检测", value: controller.detected ? "已连接" : "未连接")
                    LabeledContent("显示器", value: controller.detected ? "AUO B156ZAN05.1" : "等待连接")
                    LabeledContent("输出信号", value: controller.outputSummary)
                    LabeledContent("桌面", value: controller.currentResolutionSummary)
                }

                Section("刷新率") {
                    Picker("刷新率", selection: refreshBinding) {
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!controller.detected || controller.isBusy)
                }

                Section("HiDPI") {
                    Toggle("开启高分辨率缩放", isOn: hiDPIBinding)
                        .disabled(!controller.detected || controller.isBusy)
                    Picker("桌面分辨率", selection: resolutionBinding) {
                        ForEach(visibleResolutionOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .disabled(!controller.detected || controller.isBusy || !controller.hiDPIEnabled)
                }

                Section("连接恢复") {
                    Toggle("断开重连后自动恢复当前配置", isOn: autoRepairBinding)
                        .disabled(controller.isBusy)
                    Text("自动检测此 AUO 屏幕，仅在识别到原始屏幕参数时应用兼容设置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("开机显示") {
                    Toggle("在登录窗口阶段启用屏幕", isOn: loginWindowSupportBinding)
                        .disabled(controller.isBusy || controller.loginWindowSupportConflict)
                    Text(loginWindowSupportDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Label(
                            controller.statusMessage,
                            systemImage: controller.statusIsFailure
                                ? "exclamationmark.circle.fill"
                                : (controller.detected ? "checkmark.circle.fill" : "display")
                        )
                            .foregroundStyle(
                                controller.statusIsFailure
                                    ? Color.red
                                    : (controller.detected ? Color.green : Color.secondary)
                            )
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if controller.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("重新检测", systemImage: "arrow.clockwise") {
                            controller.refresh()
                        }
                        .disabled(controller.isBusy)
                        Spacer()
                        Button("重新应用设置", systemImage: "checkmark") {
                            controller.reapplyCurrentSettings()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.isBusy)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "display.2")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("便携屏控制")
                    .font(.title3.weight(.semibold))
                Text(controller.detected ? "Mac mini · AUO 4K" : "等待检测便携屏")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.detected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(controller.detected ? "在线" : "离线")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var loginWindowSupportDescription: String {
        if controller.loginWindowSupportConflict {
            return "检测到同名系统启动任务不属于本程序；为避免覆盖，本程序未作修改。"
        }
        if controller.loginWindowSupportInstalled {
            if controller.preLoginSupportState == "loaded" {
                return "开机恢复任务已加载。它会在登录前检查此 AUO 屏幕，不启用自动登录。"
            }
            return "开机恢复任务已安装，服务未加载；不会启用自动登录。"
        }
        return "需一次管理员授权。受限任务会在开机阶段检查此 AUO 屏幕并应用 4K120 兼容参数。"
    }
}

private func runPortableDisplayCommand(_ executable: URL, arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw ControlError.commandFailed(message.isEmpty ? "系统显示配置操作失败。" : message)
    }
    return message
}
