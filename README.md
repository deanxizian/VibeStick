# VibeStick

[English](README.en.md)

![VibeStick 语音输入流程，显示 StickS3 录音状态和 Mac HUD](assets/brand/voice-input-preview.png)

VibeStick 把 M5Stack StickS3 变成一个 Codex 桌面终端：显示任务状态、运行中对话数量、5H/7D 用量和提醒，并支持语音转写到 Mac。

本项目面向 M5Stack StickS3，不是 M5Stack 官方项目。

## 快速安装

普通用户只需使用 macOS 安装器，无需手动配置 Python、ESP-IDF、串口、固件或 LaunchAgent。

准备：

- macOS 14 或更高版本。
- M5Stack StickS3 和 USB-C 数据线。
- 2.4 GHz Wi-Fi 名称和密码。
- 可选的语音转写 API Key；推荐 [SiliconFlow](https://cloud.siliconflow.cn)，也支持其他 OpenAI 兼容服务。

推荐直接下载 [VibeStickSetup v0.1.6 macOS 通用安装器](https://github.com/deanxizian/VibeStick/releases/download/v0.1.6/VibeStickSetup-v0.1.6-macos-universal.zip)。它同时支持 Apple Silicon 和 Intel；解压后打开 App 即可。安装器已签名并启用 hardened runtime，但尚未经过 Apple 公证，若首次打开被 macOS 阻止，请右键 App 后选择“打开”。

也可以从源码构建：

```sh
git clone https://github.com/deanxizian/VibeStick.git
cd VibeStick
./script/build_and_run.sh
```

安装器会自动打开，并保存在 `dist/VibeStickSetup.app`。之后可以直接打开这个 App，或将它移到“应用程序”。首次从源码构建需要 Xcode Command Line Tools；其余运行环境由安装器自动准备。

安装只有三步：

1. 填写 Wi-Fi，并按需配置和检测语音 API。
2. 连接 StickS3，按界面提示进入安装模式。
3. 确认安装；客户端会自动准备组件、烧录固件、安装 Mac 服务并检查设备联网。

首次安装会下载约 1 GB 的 ESP-IDF。安装期间请保持 Mac 联网并且不要拔掉数据线。

## 使用

- 长按正面蓝键说话，松开后转写并粘贴。
- 录音成功后的 30 秒内，单击蓝键发送当前草稿。
- 录音成功后的 30 秒内，双击蓝键暂停当前 Codex 任务。
- 单击右侧大矩形键，在 Codex 监控面板与 Roxy 宠物页面之间切换；宠物动作会跟随 Codex 状态。
- 修改 Wi-Fi、语音 API 或重新烧录时，再次打开安装器并重新安装。

Bridge 和 HUD 会随当前用户登录自动启动。Mac 与 StickS3 需要连接同一局域网。

## 常见问题

- **检测不到设备**：确认使用 USB-C 数据线而不是仅充电线，重新插拔并按安装器提示进入安装模式。
- **无法连接 Wi-Fi**：StickS3 只支持 2.4 GHz Wi-Fi。
- **语音 API 检测失败**：检查 API 地址、Key、模型和当前网络。
- **能转写但没有粘贴**：在“系统设置 → 隐私与安全性”中允许麦克风和辅助功能权限。
- **安装中断或失败**：保持数据线连接，重新打开安装器安装即可。

## 卸载 Mac 服务

```sh
./scripts/uninstall.sh
```

加上 `--purge` 会同时删除 `~/Library/Application Support/VibeStick/` 中的配置、日志和运行数据。

## 开发者文档

- [macOS 安装器构建、测试与打包](app/macos/README.md)
- [硬件与固件](docs/HARDWARE.md)
- [架构](docs/ARCHITECTURE.md) 与 [通信协议](docs/PROTOCOL.md)
- [环境变量示例](.env.example)
- [贡献指南](CONTRIBUTING.md) 与 [安全报告](SECURITY.md)

请勿提交真实 API Key、Wi-Fi 密码、本地 token、录音或日志。

## 当前限制

- 仅支持 M5Stack StickS3 和 macOS 14 或更高版本。
- 安装器尚未作为经过公证的 DMG 发布。
- StickS3 与 Bridge 使用明文 HTTP，请仅在可信局域网使用，不要将端口 `8765` 暴露到互联网。
- Codex 用量来自本机 session 数据，并非官方 quota API。
- 使用云端语音服务时，录音会离开本机 Mac。

## 许可证

VibeStick 使用 [MIT License](LICENSE)。

Roxy 是为本项目创建的 Codex 自定义宠物。仓库与安装器只包含针对 StickS3 生成并压缩的固件资源，不包含本机 Codex 原始图集。
