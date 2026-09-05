---
name: lazarus-cross-platform
description: Windows / macOS、x86_64 / ARM64の差異管理。Platform Boundary、Platform Matrix、ファイルシステムとUnicode、ネイティブライブラリ、オーディオデバイス、LCLのUI差異、CI Matrix、パッケージング。
when_to_use: 条件コンパイル、DLL / dylib、パス処理、DPI、IME、ダークモード、署名、notarization、ビルド設定、ARM64対応に触れるとき。
paths:
  # ビルド設定と OS 境界。テストの .lpr は 30 本以上あり、ここで拾うと雑音になるので
  # 含めない (ビルド設定を持つのは .lpi と run_tests.sh である)。
  # Lazarus パッケージ (.lpk) を足したら "lazarus/**/*.lpk" をここに加えること。
  # 今は 1 つも無いので置いていない —— 当たらないグロブは
  # check-skill-paths.py が誤りとして報告する。
  - "lazarus/forms/**"
  - "lazarus/**/*.lpi"
  - "lazarus/run_tests.sh"
  - "lazarus/units/*Bindings.pas"
  - "lazarus/units/PortAudio*.pas"
  - "lazarus/units/CpuInfo.pas"
  - "lazarus/units/SoundIntf.pas"
  - "lazarus/units/SafeFileIO.pas"
user-invocable: true
---

# Cross-platform Engineering

## Principle

> OS依存性を排除するのではなく、OS依存性の存在箇所を限定し、検証可能にする。

Functional equivalenceを重視し、Pixel equivalenceを目的にしない。

## Platform Boundary

OS差分を各unitへ散在させない。

推奨インターフェース:
IAudioDevice / IHighResolutionTimer / ISharedLibrary / IFileSystemService /
ISystemInfo / IThreadPriorityService / INotificationService

条件コンパイルが増える場合はPlatform Adapterへ集約する。

## Platform Matrix

OSとCPU architectureを同一概念として扱わない。少なくとも4軸を別々に認識する。

- Windows x86_64
- Windows ARM64
- macOS x86_64
- macOS ARM64

## Filesystem / Unicode

separator / case sensitivity / Unicode normalization / forbidden characters /
filename encoding / long path / temp・config・user-dataディレクトリ / line endings

## Native Libraries

- Windows: DLL / search path / calling convention
- macOS: dylib / @rpath / @loader_path / architecture / signing

## Audio

sample rate negotiation / buffer size / exclusive・shared差 / device hot-plug /
default device change / suspend・resume / device loss / latency / clock drift

## LCL / UX Differences

DPI・Retina / font metrics / menu conventions / Ctrl・Command / focus /
dialog behavior / resize / IME / dark mode / accessibility

## CI Matrix

cross-platform verifiedを名乗るには対象matrixの実行結果が必要。
実行不能なplatformは NOT VERIFIED とする。現在の実行OSでの成功をもって全platformの成功としない。

## Packaging

- Windows: installer / DLL deployment / signing / Defender interaction
- macOS: .app bundle / dylib placement / entitlements / microphone permission / code signing / notarization / Gatekeeper

## このリポジトリでの実体

| 概念 | 実装 |
| --- | --- |
| 音声デバイス境界 | `SoundIntf.pas`, `PortAudioSoundDevice.pas`, `PortAudioBindings.pas` |
| Rig 境界 | `RigControlIntf.pas`, `HamlibBindings.pas` |
| CPU 情報 | `lazarus/units/CpuInfo.pas` |
| ファイル I/O 境界 | `lazarus/units/SafeFileIO.pas` |
| アプリのビルド設定 | `lazarus/forms/DemoModemApp.lpi` |
| 試験のビルド設定 | `lazarus/run_tests.sh` (`FPC_CHECKS`) |

**この環境には LCL が入っていない。** `lazarus/forms/` は建たず、
`run_tests.sh` も建てない。画面に関わる変更は検証できないので
**NOT VERIFIED と明記する**。

外部ライブラリ (PortAudio / hamlib) を要するスイートは `run_tests.sh` の
`OPTIONAL_SUITES` にあり、未導入の環境では省略される。
省略されたものを「成功」と数えない。

## Definition of Done

- OS依存コードが境界化されている
- platform-specific behaviorを文書化している
- 少なくともtarget matrixのBuild結果を把握している
- Audio / Device / UI / Packaging差異を必要に応じて検証している
