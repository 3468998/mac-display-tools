import CoreGraphics
import Foundation

func describe(_ id: CGDirectDisplayID) -> [String: Any] {
    var result: [String: Any] = [
        "id": id,
        "vendor": CGDisplayVendorNumber(id),
        "product": CGDisplayModelNumber(id),
        "online": CGDisplayIsOnline(id) != 0,
        "active": CGDisplayIsActive(id) != 0,
        "main": CGDisplayIsMain(id) != 0,
        "asleep": CGDisplayIsAsleep(id) != 0,
        "mirrored": CGDisplayIsInMirrorSet(id) != 0
    ]
    if let mode = CGDisplayCopyDisplayMode(id) {
        result["current"] = [
            "width": mode.width, "height": mode.height,
            "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight,
            "hz": mode.refreshRate, "ioModeID": mode.ioDisplayModeID,
            "ioFlags": mode.ioFlags
        ]
    }
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    if let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] {
        result["modes"] = modes.map {
            [
                "width": $0.width, "height": $0.height,
                "pixelWidth": $0.pixelWidth, "pixelHeight": $0.pixelHeight,
                "hz": $0.refreshRate, "ioModeID": $0.ioDisplayModeID,
                "ioFlags": $0.ioFlags,
                "usable": $0.isUsableForDesktopGUI()
            ] as [String: Any]
        }
    }
    return result
}

var modeRequest: (hz: Double, width: Int, height: Int)?
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--set-refresh",
   let hz = Double(CommandLine.arguments[2]) {
    modeRequest = (hz, 1920, 1080)
} else if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--set-mode",
          let hz = Double(CommandLine.arguments[2]),
          let width = Int(CommandLine.arguments[3]),
          let height = Int(CommandLine.arguments[4]) {
    modeRequest = (hz, width, height)
}

var ids = [CGDirectDisplayID](repeating: 0, count: 32)
var count: UInt32 = 0
let status = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
if let request = modeRequest {
    let targetHz = request.hz
    let panels = ids.prefix(Int(count)).filter {
        CGDisplayVendorNumber($0) == 1711 && CGDisplayModelNumber($0) == 45972
    }
    guard panels.count == 1,
          let modes = CGDisplayCopyAllDisplayModes(panels[0],
              [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else {
        fputs("The AUO panel is unavailable or ambiguous.\n", stderr)
        exit(2)
    }
    let usable = modes.filter {
        $0.width == request.width && $0.height == request.height &&
        abs($0.refreshRate - targetHz) < 0.2 && $0.isUsableForDesktopGUI()
    }
    let target = usable.sorted {
        if ($0.pixelWidth > $0.width) != ($1.pixelWidth > $1.width) {
            return $0.pixelWidth > $0.width
        }
        if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
        return ($0.ioFlags & 4) < ($1.ioFlags & 4)
    }.first
    guard let target else {
        fputs("No usable \(request.width)x\(request.height) \(targetHz) Hz mode is available for the AUO panel.\n", stderr)
        exit(2)
    }
    var config: CGDisplayConfigRef?
    var modeStatus = CGBeginDisplayConfiguration(&config)
    if modeStatus == .success {
        modeStatus = CGConfigureDisplayWithDisplayMode(config, panels[0], target, nil)
        if modeStatus == .success {
            modeStatus = CGCompleteDisplayConfiguration(config,
                CommandLine.arguments.contains("--permanent") ? .permanently : .forSession)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }
    print("Selected mode \(target.ioDisplayModeID): \(target.width)x\(target.height), \(target.pixelWidth)x\(target.pixelHeight) pixels, \(target.refreshRate) Hz")
    print("Display configuration result: \(modeStatus.rawValue)")
    exit(modeStatus == .success ? 0 : 3)
}
var result: [String: Any] = [
    "status": status.rawValue,
    "displays": ids.prefix(Int(count)).map(describe)
]
if CommandLine.arguments.count > 1,
   let extraID = UInt32(CommandLine.arguments[1]),
   !ids.prefix(Int(count)).contains(extraID) {
    result["extraDisplay"] = describe(extraID)
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
