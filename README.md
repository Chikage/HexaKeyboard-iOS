# HexaKeyboard

基于 Swift 6 和 SwiftUI 的 iOS 六边形密铺微分音键盘。最低系统版本为 iOS 16.0，支持 iPhone 与 iPad，界面固定为横屏。

应用显示名为 `Hexa Key`，bundle identifier 为 `icu.ringona.hexakeyboard`。

默认参数为 `35 × 8` 键、`N = 26`、`gq = 9`、`gr = 4`、72° 边界平行四边形和绕原点 12° 旋转。旋转后会从无限轴坐标网格重新采样，因此始终保留 280 个键；默认新增和略过数量均为 56。

音频使用 `AVAudioEngine` 与 `AVAudioUnitSampler`。每个同时按下的键占用独立 MIDI 通道，并在 Note On 前发送 14 位 pitch bend，确保微分音和弦互不改调。工程按用户确认引用 XenSynth 的 SoundFont，来源与权利信息见 [`SOUNDFONT_NOTICE.md`](SOUNDFONT_NOTICE.md)。

## 工程结构

- `Sources/HexaKeyboardCore`：轴坐标、72° 边界、旋转重采样、EDO 音高和周期向量算法。
- `App`：SwiftUI 参数界面、UIKit 多点触控键盘和 SoundFont 音频引擎。
- `Tests/HexaKeyboardTests`：默认 280 键布局、边界角、周期向量、音高与负数取模测试。

## 打开工程

仓库已包含生成后的 `HexaKeyboard.xcodeproj`，无需安装额外工具：

```sh
open HexaKeyboard.xcodeproj
```

在 Xcode 中选择 `HexaKeyboard` scheme 和一个 iOS 模拟器后运行。

## 命令行验证

```sh
xcodebuild \
  -project HexaKeyboard.xcodeproj \
  -scheme HexaKeyboard \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project HexaKeyboard.xcodeproj \
  -scheme HexaKeyboard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## 重新生成 Xcode 工程

`project.yml` 是工程配置的唯一生成源。仅在调整 target 或构建设置后需要重新生成：

```sh
brew install xcodegen
xcodegen generate
```

重新生成后应一并提交 `project.yml` 与 `HexaKeyboard.xcodeproj` 的变化。
