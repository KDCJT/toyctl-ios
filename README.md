# ToyCtl iOS App(SwiftUI 蓝牙原生版)

通过 **蓝牙直连** ESP32(不需要 WiFi),协议与网页版完全一致(JSON over BLE)。

## 现实说明(先看这个)

- 本 App 是**完整可编译的 SwiftUI 源码**,但编写时**没有 Mac 环境实测**——首次编译可能遇到个别小 API 修正(都是一行级)。
- 编译 iOS App **必须有 Mac + Xcode**(Apple 的硬性要求,Windows 上无法绕过)。
- 不想折腾 Mac?**不用它也完全行**——ESP32 的网页控制台已经做了 iPhone 适配:
  **Safari 打开 http://192.168.4.1 → 分享 → 添加到主屏幕**,即得到独立全屏 App(PWA),功能齐全。

## 固件侧(已完成)

固件已内置 BLE 控制服务(与网页 WebSocket 共用同一套 JSON 指令):

| 项 | UUID |
|---|---|
| 服务 | `B0B0C0DE-F00D-4A11-B1E5-5EED00000001` |
| CMD(写指令) | `B0B0C0DE-F00D-4A11-B1E5-5EED00000002` |
| OUT(订阅应答) | `B0B0C0DE-F00D-4A11-B1E5-5EED00000003` |

OUT 采用分帧协议应对 MTU 分片:`[0x01][seqId][seqIdx][seqTotal][payload...]`。

## 编译步骤

1. Mac 上 `git clone`/拷贝本目录,用 Xcode 打开:新建 iOS App 工程,把 `ToyCtlApp.swift` 放进去
2. **在 target 的 Info 标签添加权限键**(必须,否则闪退):
   `NSBluetoothAlwaysUsageDescription` = "连接并控制 ToyCtl 设备"
3. Signing & Capabilities:登录你的 Apple ID(免费个人签名即可,7 天有效期,到期重装)
4. iPhone 用数据线连 Mac,选择设备,Run
5. 首次启动 iOS 会弹蓝牙权限,允许

## 已知限制

- 首次编译如报 SwiftUI/Combine 小错,按提示修正即可(源码按 iOS 16 API 写)
- SiYu 家族的马达/方向细分控制在 App 端做了精简(网页版更全)
- 状态推送 2 秒一次,由 ESP32 主动 notify
