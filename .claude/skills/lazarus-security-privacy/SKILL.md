---
name: lazarus-security-privacy
description: 認証情報の取り扱い、コールサインや位置情報などのプライバシー、telemetry、Plugin信頼境界、依存関係とサプライチェーン、Rig/CAT制御の送信安全性。Receiveはfail-soft、Transmitはfail-safe。
when_to_use: PTT、CAT制御、hamlib、送信系、APIキー、トークン、クラウド連携、telemetry、新規依存ライブラリの追加、plugin読み込みに触れるとき。
paths:
  # 送信制御・認証情報・プライバシー・Plugin 信頼境界。
  - "lazarus/units/Secure*.pas"
  - "lazarus/units/Crypto*.pas"
  - "lazarus/units/*Rig*.pas"
  - "lazarus/units/Hamlib*.pas"
  - "lazarus/units/Plugin*.pas"
  - "lazarus/units/AdifUdpSender.pas"
  - "lazarus/units/StationInfo.pas"
  - "lazarus/test/test_rigcontrol.lpr"
  - "lazarus/test/test_plugin.lpr"
user-invocable: true
---

# Security & Privacy

## Secrets

API key / password / token / private credential を
source、log、test fixtureへ埋め込まない。

## Privacy-sensitive Data

callsign / locator / precise location / contact history /
cloud account / network credential / telemetry。

収集・保存・送信は最小限にする。

## Telemetry

導入する場合、opt-in・opt-out / purpose limitation / data minimization /
retention / anonymization where meaningful を定義する。

## Plugin Trust

pluginを信頼しすぎない。built-in trusted / signed third-party / untrusted external を区別する。
例外隔離、timeout、subprocess化を検討する。

## Dependency Governance

新依存では license / maintenance / CVE・security history /
supported OS・arch / update policy / provenance を確認する。

## Supply Chain

releaseでは必要に応じ artifact signing / checksum / dependency integrity /
reproducible build metadata / provenance を管理する。

## Rig / CAT Safety

送信系は高リスク境界として扱う。

確認: unintended PTT / stale command / frequency・mode・split変更 /
retry duplication / reconnect時の古い状態

原則: Receive = fail-soft、Transmit = fail-safe

## このリポジトリでの実体

| 概念 | 実装 |
| --- | --- |
| 認証情報の保管 | `lazarus/units/SecureStore.pas` |
| 暗号プリミティブ | `lazarus/units/CryptoPrimitives.pas` |
| Rig / CAT | `RigControlIntf.pas`, `HamlibRigControl.pas`, `RigPollThread.pas` |
| Plugin 信頼境界 | `PluginApi.pas`, `PluginHost.pas` (ADR-005) |
| 局情報 (プライバシー) | `lazarus/units/StationInfo.pas` |
| 外部送出 | `lazarus/units/AdifUdpSender.pas` |

L6 の暗号化は ADR-003 で Phase 4 へ送ってある (ARC-005 / ARC-006)。
`CryptoPrimitives.pas` は意図した桁あふれを `{$push}{$Q-}{$R-}` で囲ってある。
**この囲いを interface 側に置かない** —— 実装部の該当関数だけを囲う。

## DoD

- secret漏えいなし
- privacy impact確認
- plugin/dependency trust boundary確認
- TX変更時はfail-safeを検証
