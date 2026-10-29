# Mac Display Tools

两个独立的 Apple Silicon macOS 显示工具：**便携屏控制**和**虚拟显示器**。

## 下载

在 [Releases](../../releases) 下载压缩包，解压后打开其中的 `.app`。每个 `.app` 均已包含运行组件，可以整体拖到桌面或“应用程序”目录，无需安装开发工具。

| 程序 | 应用包 | 用途 |
| --- | --- | --- |
| 便携屏控制 2.0 | [PortableDisplayControl-v2.0-macOS-arm64.zip](dist/PortableDisplayControl-v2.0-macOS-arm64.zip) | 检测并控制指定 AUO 便携屏，修复兼容性，切换刷新率和 HiDPI |
| 虚拟显示器 1.1 | [VirtualDesk-v1.1-macOS-arm64.zip](dist/VirtualDesk-v1.1-macOS-arm64.zip) | 创建独立的软件显示器，无需连接实体屏幕 |

构建使用本地 ad-hoc 签名，尚未经过 Apple 公证。若下载后 macOS 阻止打开，可在系统设置的“隐私与安全性”中核对来源并选择“仍要打开”。

## 便携屏控制

针对 **AUO B156ZAN05.1，EDID 厂商/产品 ID `06af:b394`**，在 Mac mini M4 上验证。程序按屏幕身份匹配，不会将此 AUO 的修复参数应用到其他型号。

- 检测连接状态、桌面尺寸、渲染像素尺寸和刷新率。
- 切换 60 Hz / 120 Hz、HiDPI 和系统提供的桌面分辨率。
- 可选的用户级自动恢复，在登录后及重连时恢复配置。
- 可选的登录窗口阶段恢复，需要一次系统管理员授权。
- 所有修复使用运行时 EDID 覆盖，不写入显示器固件或 EEPROM。

原始 EDID 的横向后沿为零，修复配置保留原始像素时钟、总时序和同步宽度，调整前后沿并重新计算校验和。此配置不应被当作其他品牌或型号显示器的通用 EDID。

开启自动恢复后会把组件部署到当前用户的 `~/Library/Application Support/PortableDisplayControl`，并创建用户 LaunchAgent。登录窗口阶段恢复使用 `/Library/Application Support/PortableDisplayControl/PreLogin` 和相应的系统 LaunchDaemon；关闭开关会卸载对应任务。

登录窗口恢复属于 macOS 启动后的阶段，不覆盖 FileVault 预启动解锁界面，也不启用自动登录。不同设备重启后的显示效果需要实际验证。

## 虚拟显示器

创建名称为 **Virtual Desk** 的软件显示器，可供远程桌面、录屏和窗口使用。不依赖实体显示器或其品牌，也不向物理 DP / USB-C 接口发送信号。

| 项目 | 默认值 / 可选值 |
| --- | --- |
| 默认桌面尺寸 | 1920 × 1080 |
| 默认渲染像素尺寸 | 3840 × 2160 |
| 刷新率 | 60 Hz / 120 Hz，默认 120 Hz |
| 自定义刷新率 | 24–240 Hz，实际模式受 macOS 支持情况限制 |
| HiDPI | 默认开启；宽高各按两倍像素渲染 |
| 桌面尺寸 | 1920 × 1080、2304 × 1296、2560 × 1440、3008 × 1692、3840 × 2160，或自定义尺寸 |

点击“启动虚拟显示器”创建屏幕。修改后点击“应用模式”；可设为主屏，也可从菜单栏管理。程序保存上次成功的设置，并在 Mac 从睡眠唤醒后尝试重建虚拟屏；退出时移除虚拟屏。控制窗口可复制当前状态和可用显示模式的诊断信息。默认保留现有实体主屏并将虚拟屏放在右侧。

自定义桌面宽度至少 800、高度至少 600；开启 HiDPI 时最大 3840 × 2160，关闭时最大 7680 × 4320。刷新率支持小数。无效参数会在创建或切换前被拒绝；系统拒绝新模式时尝试恢复上次成功的模式。

在用户登录后的图形会话运行，不提供登录前输出或开机自动启动。远程软件实际帧率取决于其自身配置、网络和客户端，系统报告的 120 Hz 不等于远程传输必然达到 120 fps。

## 兼容性与验证

已在 **Mac mini M4 / macOS 26.7.1** 验证，下载包为 **arm64**。便携屏控制声明最低 macOS 13，虚拟显示器声明最低 macOS 15；其他版本未逐一验证。两者使用私有系统显示接口，系统升级后需要重新验证兼容性。

虚拟显示器的运行验证覆盖了 19 项检查：内置及自定义尺寸、自定义 144 Hz、HiDPI 开关、60/120 Hz、非法输入拒绝、主屏切换、关闭移除、重新创建，以及测试前后实体屏状态一致。唤醒恢复以重建流程验证；没有将真实睡眠/唤醒过程作为已验证项目。独立系统查询确认实体 AUO 屏与 Virtual Desk 可同时以 3840 × 2160 渲染、1920 × 1080 桌面、120 Hz 在线，镜像关闭。没有实际拔线测试。

## 从源码构建

需要 Apple Silicon Mac 和 Xcode Command Line Tools。构建仅生成应用，不修改显示设置或安装后台任务。目标输出目录必须尚不存在。

```zsh
zsh PortableDisplayControl/build.zsh "$PWD/build/便携屏控制.app"
zsh VirtualDesk/build-virtualdesk.zsh "$PWD/build/虚拟显示器.app"
```

应用代码分别位于 [PortableDisplayControl](PortableDisplayControl) 和 [VirtualDesk](VirtualDesk)。下载包是上传时桌面应用的快照；重新构建的应用会生成新的本地签名。

`dist/SHA256SUMS.txt` 提供下载包校验值：

```zsh
cd dist
shasum -a 256 -c SHA256SUMS.txt
```

## 参考项目

1.1 版本参考 [youngyunxing/VirtualDisplay](https://github.com/youngyunxing/VirtualDisplay)（`1776f70`）的唤醒重建、模式管理和诊断思路，结合现有单虚拟屏架构实现。
