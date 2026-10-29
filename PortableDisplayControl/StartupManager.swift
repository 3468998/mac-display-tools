import Foundation

private let label = "com.local.portable-display-auo"
private let preloginLabel = "com.local.portable-display-auo.prelogin"
private let preloginMarkerText = "PortableDisplayControl AUO pre-login helper v1"

private struct ManagerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct StartupManager {
    let home: URL
    var root: URL { home.appendingPathComponent("Library/Application Support/PortableDisplayControl") }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    var logs: URL { home.appendingPathComponent("Library/Logs/PortableDisplayControl") }
    var preloginRoot: URL {
        URL(fileURLWithPath: "/Library/Application Support/PortableDisplayControl/PreLogin", isDirectory: true)
    }
    var preloginAgent: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/com.local.portable-display-auo-prelogin.plist")
    }
    var stagedPreloginAgent: URL { root.appendingPathComponent("com.local.portable-display-auo-prelogin.plist") }
    var stagedPreloginMarker: URL { root.appendingPathComponent("prelogin-managed-marker") }
    private let files = FileManager.default

    func configuration() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [
                root.appendingPathComponent("portable-edid").path, "ensure",
                root.appendingPathComponent("panel-selected.bin").path,
                root.appendingPathComponent("panel-factory.bin").path
            ],
            "RunAtLoad": true,
            "StartInterval": 15,
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("repair.log").path,
            "StandardErrorPath": logs.appendingPathComponent("repair.log").path
        ]
    }

    func preloginConfiguration() -> [String: Any] {
        [
            "Label": preloginLabel,
            "ProgramArguments": [
                preloginRoot.appendingPathComponent("portable-edid").path,
                "boot-ensure",
                preloginRoot.appendingPathComponent("panel-compatible-120hz.bin").path,
                preloginRoot.appendingPathComponent("panel-factory.bin").path
            ],
            "RunAtLoad": true,
            "StartInterval": 15,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
    }

    func stagePreloginConfiguration() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let edid = try Data(contentsOf: root.appendingPathComponent("panel-compatible-120hz.bin"))
        let bytes = [UInt8](edid)
        guard bytes.count == 256,
              bytes[8] == 0x06, bytes[9] == 0xaf,
              bytes[10] == 0x94, bytes[11] == 0xb3,
              bytes[126] == 1,
              stride(from: 0, to: bytes.count, by: 128).allSatisfy({ start in
                  bytes[start..<(start + 128)].reduce(0) { $0 + Int($1) } % 256 == 0
              }) else {
            throw ManagerError(message: "The prepared AUO 120 Hz EDID is invalid.")
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: preloginConfiguration(),
            format: .xml,
            options: 0
        )
        try plist.write(to: stagedPreloginAgent, options: .atomic)
        try Data(preloginMarkerText.utf8).write(to: stagedPreloginMarker, options: .atomic)
    }

    func preloginSupportStatus() -> String {
        guard files.fileExists(atPath: preloginAgent.path) else { return "notInstalled" }
        guard let settings = plist(at: preloginAgent),
              settings["Label"] as? String == preloginLabel,
              settings["ProgramArguments"] as? [String] == preloginConfiguration()["ProgramArguments"] as? [String],
              let marker = try? String(contentsOf: preloginRoot.appendingPathComponent(".managed-by-portable-display-control"), encoding: .utf8),
              marker == preloginMarkerText,
              files.isExecutableFile(atPath: preloginRoot.appendingPathComponent("portable-edid").path),
              files.fileExists(atPath: preloginRoot.appendingPathComponent("panel-compatible-120hz.bin").path),
              files.fileExists(atPath: preloginRoot.appendingPathComponent("panel-factory.bin").path) else {
            return "differentConfiguration"
        }
        guard let loaded = try? run(["print", "system/\(preloginLabel)"]),
              loaded.status == 0,
              loaded.output.contains(preloginRoot.appendingPathComponent("portable-edid").path) else {
            return "installed"
        }
        return "loaded"
    }

    func enablePreloginSupport() throws {
        try stagePreloginConfiguration()
        let markerPath = preloginRoot.appendingPathComponent(".managed-by-portable-display-control")
        if files.fileExists(atPath: preloginRoot.path) {
            guard let marker = try? String(contentsOf: markerPath, encoding: .utf8),
                  marker == preloginMarkerText else {
                throw ManagerError(message: "The system helper directory already exists and is not managed by this app.")
            }
        }
        if files.fileExists(atPath: preloginAgent.path),
           (plist(at: preloginAgent)?["Label"] as? String != preloginLabel ||
            plist(at: preloginAgent)?["ProgramArguments"] as? [String] != preloginConfiguration()["ProgramArguments"] as? [String]) {
            throw ManagerError(message: "A different system launch daemon already uses the target path.")
        }

        let system = shellQuote(preloginRoot.path)
        let source = shellQuote(root.path)
        let daemon = shellQuote(preloginAgent.path)
        let marker = shellQuote(markerPath.path)
        let markerContents = shellQuote(preloginMarkerText)
        let parent = shellQuote(preloginRoot.deletingLastPathComponent().path)
        let command = """
        if [ -e \(system) ] && { [ ! -f \(marker) ] || [ "$(/bin/cat \(marker))" != \(markerContents) ]; }; then echo 'Unmanaged system helper directory exists.' >&2; exit 1; fi && \
        /usr/bin/install -d -o root -g wheel -m 755 \(parent) && \
        /usr/bin/install -d -o root -g wheel -m 755 \(system) && \
        /usr/bin/install -o root -g wheel -m 755 \(source)/portable-edid \(system)/portable-edid && \
        /usr/bin/install -o root -g wheel -m 644 \(source)/panel-factory.bin \(system)/panel-factory.bin && \
        /usr/bin/install -o root -g wheel -m 644 \(source)/panel-compatible-120hz.bin \(system)/panel-compatible-120hz.bin && \
        /usr/bin/install -o root -g wheel -m 644 \(shellQuote(stagedPreloginMarker.path)) \(marker) && \
        /usr/bin/install -o root -g wheel -m 644 \(shellQuote(stagedPreloginAgent.path)) \(daemon) && \
        ( /bin/launchctl bootout system/\(preloginLabel) >/dev/null 2>&1 || true ) && \
        /bin/launchctl enable system/\(preloginLabel) && \
        /bin/launchctl bootstrap system \(daemon)
        """
        try runWithAdministratorAuthorization(
            command,
            prompt: "安装开机阶段 AUO 屏幕恢复任务。需管理员授权；不启用自动登录。"
        )
        guard preloginSupportStatus() == "loaded" else {
            throw ManagerError(message: "The pre-login display helper was installed but is not loaded.")
        }
    }

    func disablePreloginSupport() throws {
        let state = preloginSupportStatus()
        guard state == "loaded" || state == "installed" else {
            if state == "differentConfiguration" {
                throw ManagerError(message: "A different system display helper exists; it was left untouched.")
            }
            return
        }
        let daemon = shellQuote(preloginAgent.path)
        let command = "( /bin/launchctl bootout system/\(preloginLabel) >/dev/null 2>&1 || true ) && /bin/launchctl disable system/\(preloginLabel) && /bin/rm \(daemon)"
        try runWithAdministratorAuthorization(
            command,
            prompt: "移除本程序安装的开机阶段 AUO 屏幕恢复任务。"
        )
        guard preloginSupportStatus() == "notInstalled" else {
            throw ManagerError(message: "The pre-login display helper could not be fully removed.")
        }
    }

    private func runWithAdministratorAuthorization(_ shellCommand: String, prompt: String) throws {
        let script = "do shell script \"\(appleScriptQuote(shellCommand))\" with administrator privileges with prompt \"\(appleScriptQuote(prompt))\""
        let result = try runExecutable("/usr/bin/osascript", arguments: ["-e", script])
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("user canceled") ||
               message.localizedCaseInsensitiveContains("user cancelled") {
                throw ManagerError(message: "管理员授权已取消，系统设置未更改。")
            }
            throw ManagerError(message: message.isEmpty ? "管理员授权或系统配置安装失败。" : message)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    func installed() -> Bool {
        guard (try? files.destinationOfSymbolicLink(atPath: agent.path)) == nil,
              let settings = plist(at: agent),
              settings["Label"] as? String == label,
              settings["ProgramArguments"] as? [String] == configuration()["ProgramArguments"] as? [String] else {
            return false
        }
        return true
    }

    func loaded() throws -> Bool {
        let response = try run(["print", "gui/\(getuid())/\(label)"])
        return installed() && response.status == 0 &&
            response.output.contains(root.appendingPathComponent("portable-edid").path)
    }

    // Only migrate an agent belonging to this repair, never replace unrelated jobs.
    func checkOwnership(legacyRoot: URL? = nil) throws {
        let link = try? files.destinationOfSymbolicLink(atPath: agent.path)
        if !files.fileExists(atPath: agent.path) && link == nil { return }
        guard let existing = plist(at: agent),
              existing["Label"] as? String == label,
              let arguments = existing["ProgramArguments"] as? [String] else {
            throw ManagerError(message: "An unrelated or unreadable launch agent occupies \(agent.path).")
        }
        let allowedRoots = [root, legacyRoot].compactMap { $0 }
        guard allowedRoots.contains(where: {
            arguments == [
                $0.appendingPathComponent("portable-edid").path, "ensure",
                $0.appendingPathComponent("panel-selected.bin").path,
                $0.appendingPathComponent("panel-factory.bin").path
            ]
        }) else {
            throw ManagerError(message: "Launch agent ownership check failed; no changes made.")
        }
    }

    func deployResources(from source: URL) throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let executables = ["portable-edid", "display-mode", "startup-manager"]
        let resources = ["panel-factory.bin", "panel-compatible-60hz.bin", "panel-compatible-120hz.bin"]
        let bundled = source.pathExtension == "app"
        let executableDirectory = bundled ? source.appendingPathComponent("Contents/MacOS") : source
        let resourceDirectory = bundled ? source.appendingPathComponent("Contents/Resources/DisplayProfiles") : source
        for name in executables + resources {
            let input = (executables.contains(name) ? executableDirectory : resourceDirectory).appendingPathComponent(name)
            let output = root.appendingPathComponent(name)
            let data = try Data(contentsOf: input)
            guard !data.isEmpty else { throw ManagerError(message: "Empty installation asset: \(name)") }
            if (try? Data(contentsOf: output)) != data {
                try data.write(to: output, options: .atomic)
            }
            if executables.contains(name) {
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            }
        }
        let selected = root.appendingPathComponent("panel-selected.bin")
        if !files.fileExists(atPath: selected.path) {
            let selectedData = try Data(contentsOf: bundled
                ? resourceDirectory.appendingPathComponent("panel-compatible-120hz.bin")
                : source.appendingPathComponent("panel-selected.bin"))
            let known = try resources.filter { $0 != "panel-factory.bin" }.map {
                try Data(contentsOf: root.appendingPathComponent($0))
            }
            guard known.contains(selectedData) else {
                throw ManagerError(message: "Selected EDID is not a known repair profile.")
            }
            try selectedData.write(to: selected, options: .atomic)
        } else {
            let current = try Data(contentsOf: selected)
            let knownProfiles = try resources.filter { $0 != "panel-factory.bin" }.map {
                try Data(contentsOf: root.appendingPathComponent($0))
            }
            if !knownProfiles.contains(current) {
                throw ManagerError(message: "The selected profile is not recognized; refusing to replace it.")
            }
        }
    }

    func install(from source: URL) throws {
        try checkOwnership(legacyRoot: source)
        try deployResources(from: source)
        try enable(legacyRoot: source)
    }

    func syncBundle(_ source: URL) throws {
        guard source.pathExtension == "app" else {
            throw ManagerError(message: "Expected a complete app bundle.")
        }
        guard installed() else { return }
        try checkOwnership()
        try deployResources(from: source)
        try enable()
    }

    func prepareBundle(_ source: URL) throws {
        guard source.pathExtension == "app" else {
            throw ManagerError(message: "Expected a complete app bundle.")
        }
        try deployResources(from: source)
    }

    func selectProfile(_ hz: Int) throws {
        guard hz == 60 || hz == 120 else {
            throw ManagerError(message: "Only 60 and 120 Hz profiles are supported.")
        }
        guard files.isExecutableFile(atPath: root.appendingPathComponent("portable-edid").path) else { return }
        let profile = try Data(contentsOf: root.appendingPathComponent("panel-compatible-\(hz)hz.bin"))
        try profile.write(to: root.appendingPathComponent("panel-selected.bin"), options: .atomic)
    }

    func enable(legacyRoot: URL? = nil) throws {
        try checkOwnership(legacyRoot: legacyRoot)
        guard files.isExecutableFile(atPath: root.appendingPathComponent("portable-edid").path),
              files.fileExists(atPath: root.appendingPathComponent("panel-selected.bin").path),
              files.fileExists(atPath: root.appendingPathComponent("panel-factory.bin").path) else {
            throw ManagerError(message: "The repair runtime is not installed.")
        }
        if try loaded() { return }
        _ = try run(["bootout", "gui/\(getuid())/\(label)"])
        try files.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: logs, withIntermediateDirectories: true)
        if (try? files.destinationOfSymbolicLink(atPath: agent.path)) != nil {
            try files.removeItem(at: agent)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: configuration(), format: .xml, options: 0)
        try data.write(to: agent, options: .atomic)
        let enabled = try run(["enable", "gui/\(getuid())/\(label)"])
        guard enabled.status == 0 else { throw ManagerError(message: enabled.output) }
        let bootstrapped = try run(["bootstrap", "gui/\(getuid())", agent.path])
        guard bootstrapped.status == 0, try loaded() else {
            throw ManagerError(message: "Unable to load the startup repair: \(bootstrapped.output)")
        }
    }

    func disable() throws {
        try checkOwnership()
        let result = try run(["bootout", "gui/\(getuid())/\(label)"])
        if result.status != 0 {
            let present = try run(["print", "gui/\(getuid())/\(label)"])
            guard present.status != 0 else { throw ManagerError(message: result.output) }
        }
        if files.fileExists(atPath: agent.path) {
            try files.removeItem(at: agent)
        }
    }

    func status() throws -> [String: Any] {
        [
            "installed": installed(),
            "loaded": try loaded(),
            "runtime": root.path,
            "agent": agent.path,
            "preLoginSupport": preloginSupportStatus()
        ]
    }

    func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try runExecutable("/bin/launchctl", arguments: arguments)
    }

    private func runExecutable(_ path: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private let manager = StartupManager(home: FileManager.default.homeDirectoryForCurrentUser)
do {
    guard CommandLine.arguments.count > 1 else {
        throw ManagerError(message: "Usage: startup-manager install SOURCE | sync-bundle APP | prepare-bundle APP | select-profile HZ | enable | disable | prepare-prelogin | enable-prelogin | disable-prelogin | status")
    }
    switch CommandLine.arguments[1] {
    case "install" where CommandLine.arguments.count == 3:
        try manager.install(from: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    case "sync-bundle" where CommandLine.arguments.count == 3:
        try manager.syncBundle(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    case "prepare-bundle" where CommandLine.arguments.count == 3:
        try manager.prepareBundle(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    case "select-profile" where CommandLine.arguments.count == 3:
        guard let hz = Int(CommandLine.arguments[2]) else {
            throw ManagerError(message: "Invalid refresh rate.")
        }
        try manager.selectProfile(hz)
    case "enable": try manager.enable()
    case "disable": try manager.disable()
    case "prepare-prelogin": try manager.stagePreloginConfiguration()
    case "enable-prelogin": try manager.enablePreloginSupport()
    case "disable-prelogin": try manager.disablePreloginSupport()
    case "status": break
    default: throw ManagerError(message: "Unknown startup-manager command.")
    }
    let data = try JSONSerialization.data(withJSONObject: manager.status(), options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
