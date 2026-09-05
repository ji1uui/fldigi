---
name: lazarus-data-compat
description: QSOログ、設定、キャッシュ、Replay metadata、Plugin manifest、event schema、外部ABIの互換性とschema evolution。migration、破損耐性、決定性、設定項目の管理。
when_to_use: 保存形式、設定項目、ログファイル、ADIF、シリアライズ、schema version、migration、plugin API、DLL・dylibの公開インターフェースを変更するとき。
paths:
  # 保存形式・設定・スキーマ・Plugin 境界。
  - "lazarus/units/*Adif*.pas"
  - "lazarus/units/AppConfig.pas"
  - "lazarus/units/Qso*.pas"
  - "lazarus/units/ContestLog.pas"
  - "lazarus/units/ContextMemory.pas"
  - "lazarus/units/StationInfo.pas"
  - "lazarus/units/OpProfile.pas"
  - "lazarus/units/DxccDatabase.pas"
  - "lazarus/units/Plugin*.pas"
  - "lazarus/units/SafeFileIO.pas"
  - "lazarus/units/MacroEngine.pas"
  - "lazarus/docs/adr/**"
  - "lazarus/test/test_adif*.lpr"
  - "lazarus/test/test_qsomodel.lpr"
  - "lazarus/test/test_station_adif.lpr"
  - "lazarus/test/test_contestlog.lpr"
  - "lazarus/test/test_plugin.lpr"
  - "lazarus/test/test_context_memory.lpr"
user-invocable: true
---

# Data & Compatibility

## Principle

> 新バージョンが古い利用者データを壊さないことを優先する。

## Versioned Data

settings / QSO logs / cache / replay metadata / plugin manifest /
event schema / exported files。必要に応じschema versionを持つ。

## Migration

source version確認 / validation / atomic write / backup・rollback /
partial failure handling / idempotency を検討する。

## Corruption Tolerance

malformed input / truncated file / unknown field / unsupported future version
を安全に扱う。落とさず、黙って捨てない。

## API / ABI Stability

public Pascal interface / plugin API / DLL・dylib interface / calling convention /
serialized event / provider contract。

breaking changeはversioningとmigration方針を伴う。

## Configuration Management

default / range / dependency / deprecated setting / migration / expert-only setting を管理する。
設定項目を無制限に増やさず、Autoで吸収可能な複雑さはUIへ露出しない。

## Determinism

同一input + same settings + same algorithm versionで可能な限り再現可能な結果を得る。
OS/CPU差で完全一致不能な場合は許容差を定義する。

## このリポジトリでの実体

| 概念 | 実装 |
| --- | --- |
| QSO データモデル | `lazarus/units/QsoModel.pas`, `QsoLogbook.pas` (ADR-011) |
| ADIF | `AdifFile.pas`, `QsoAdifAdapter.pas`, `AdifUdpSender.pas` |
| 設定 | `lazarus/units/AppConfig.pas` |
| 安全な保存 | `lazarus/units/SafeFileIO.pas` |
| Plugin 境界 | `PluginApi.pas`, `PluginHost.pas` (ADR-004 / ADR-005) |
| 要求の表 | `lazarus/units/Requirements.pas` (§18。`docs/requirements-matrix.md` は生成物) |

ADR は `lazarus/docs/adr/` にある。schema や境界を変えるときは、
**該当する ADR を先に読み**、決定を覆すなら ADR も更新する。

## DoD

- schema/API影響を説明
- migration必要性を判断
- backward compatibility確認
- malformed/old dataを必要に応じて検証
