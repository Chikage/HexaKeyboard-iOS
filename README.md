# Hexa Key for iOS

Hexa Key 是基于 Swift 6、SwiftUI 与 UIKit 的横屏六边形密铺微分音键盘。本工程已按 Android 端 `HexaKeyboard-Android` 的界面、触摸、文件播放和乐谱可视化行为迁移到 iPhone 与 iPad。

最低系统版本为 iOS 16.0，应用显示名为 `Hexa Key`，bundle identifier 为 `icu.ringona.hexakeyboard`。

## 默认布局

- 35 列 × 8 行，共 280 键
- 53-EDO
- `gq = 9`、`gr = 4`
- 键帽半径固定为 24，键盘与键帽固定旋转 12°
- 边界平行四边形锐角为 72°
- 默认旋转重采样统计为 `+56 / -56`
- 默认最短独立周期向量为 `(-5,-2)`、`(-4,9)`

音级与轴坐标的关系为：

```text
step = q × gq + r × gr
pitchClass = step mod EDO
frequency = C4 × 2^(step/EDO)
```

## 界面与演奏

主界面由单行工具栏和自适应键盘画布组成。工具栏包含：

- 打开乐谱、播放/暂停、复位、终止
- 列数、行数、EDO、q 轴音程、r 轴音程
- 触摸灵敏度、MIDI Program Number、伪压感设置

在工具栏上拖动可平移键盘，双指捏合可在 `0.84...3.0` 范围内缩放；键盘画布本身始终用于多点演奏。

触摸实现包含键缝最近键捕获、跨键滞回、coalesced touch 历史样本、160ms 和弦合并窗口，以及 Apple Pencil/设备压力和伪压感。伪压感根据落点、按住时间与滑动稳定度计算起音 velocity 和持续 Expression。

## 文件与播放

文件选择器支持 64MB 以内的：

- Standard MIDI：`.mid`、`.midi`
- MIDX/MIDIX 微分音 MIDI：`.midx`、`.midix`
- MIDI 2.0 Clip：`.midi2`
- MuseScore：`.mscz`、`.mscx`

Standard MIDI/MIDX 解析器支持 Format 0/1、running status、tempo、拍号、Program/Bank、sustain、pitch bend、RPN 弯音范围与 MIDX 微分音偏移。MIDI 2.0 Clip 支持 DCTPQ、Delta Clockstamp、Note On/Off、音高属性、Program/Bank、sustain 与 Flex Data tempo。

MuseScore 转换器完全在内存中读取 MSCX/MSCZ，并支持多声部、Tuplet、Tie、Grace、Swing、Ornament、Trill、Tremolo、Arpeggio、Glissando、Bend、Ottava、Pedal、Let Ring、Palm Mute、Slur、Vibrato、Hairpin、Articulation 和简单 Repeat 等演奏语义。

播放采用 180ms 预排程。键盘会显示 1.8 秒未来音符预告、当前音符提亮、多轨描边、重复音闪烁、持续粒子和 0.34 秒结束爆裂；视觉位置吸附到最近可见键，实际音频音高不会被吸附。

## 音频

音频后端使用 `AVAudioEngine` 与 `AVAudioUnitSampler`。每个同时发声的音符占用独立旋律 MIDI 通道，并在 Note On 前设置 Program、Bank、Expression 与 14 位 pitch bend，确保微分音和弦中的各音独立调律。应用会处理音频中断、路由变化和媒体服务重置。

默认 SoundFont 位于 `App/Resources/Audio/DefaultSoundFont.sf2`，来源与权利信息见 [`SOUNDFONT_NOTICE.md`](SOUNDFONT_NOTICE.md)。

## 工程结构

- `Sources/HexaKeyboardCore`：轴坐标、几何、旋转重采样、EDO 音高、触摸动力学、MIDI/MIDI2 解析、MuseScore 转换和播放视觉时间线。
- `App/Audio`：SoundFont 多音微分音引擎。
- `App/Playback`：播放状态机与音频预排程。
- `App/Views`：Android 风格工具栏和 UIKit 多点触控画布。
- `Tests/HexaKeyboardTests`：布局、音高、触摸、MIDI、MIDI2、MuseScore 与时间线测试。

## 打开与验证

仓库包含生成后的 `HexaKeyboard.xcodeproj`：

```sh
open HexaKeyboard.xcodeproj
```

命令行构建和测试：

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

`project.yml` 是工程配置的生成源。新增或移动源码后运行：

```sh
brew install xcodegen
xcodegen generate
```
