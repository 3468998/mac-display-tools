便携屏控制 2.0 和虚拟显示器 1.0，适用于 Apple Silicon Mac。

- **PortableDisplayControl-v2.0-macOS-arm64.zip**：指定 AUO `06af:b394` 便携屏的检测、60/120 Hz、HiDPI、自动恢复和可选登录窗口恢复。
- **VirtualDesk-v1.0-macOS-arm64.zip**：创建独立的 Virtual Desk，默认 3840 × 2160 渲染、1920 × 1080 桌面、120 Hz、HiDPI。
- **SHA256SUMS.txt**：下载包 SHA-256 校验值。

解压后打开 `.app`，整个应用包可移动到其他文件夹，无需相邻运行文件。应用采用本地 ad-hoc 签名，未经过 Apple 公证。

便携屏修复针对指定 AUO 型号；虚拟显示器不依赖屏幕品牌，只在登录后的用户会话运行。两者均使用私有系统接口，系统升级后兼容性需要重新验证。完整限制和构建方法见仓库 README。
