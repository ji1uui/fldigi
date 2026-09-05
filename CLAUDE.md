# CLAUDE.md — Project Constitution

このファイルは常にコンテキストに載る。ここには「変わらない事実」と「禁止事項」だけを置く。
「どう進めるか」の手順は `.claude/skills/` の Skill に置き、必要なときだけ読み込む。

## このリポジトリは二つの木を持つ

| 場所 | 何か | 扱い |
| --- | --- | --- |
| `src/`, `doc/`, `po/` ほか | 上流 fldigi の C++ | **参照専用。変更しない** |
| `lazarus/` | Lazarus / Free Pascal で書いている新しいアプリ | **作業対象** |

上流の C++ は、アルゴリズムと定数の出どころとして読む。
**行単位の移植ではない。** ロジックを参照し、Object Pascal として自然な形に書き直す。

`lazarus/` の外を変更しない。上流に手を入れる必要が生じたら、まず理由を述べる。

## Mission

このアプリケーションの最上位目的は「復調器を実装すること」ではない。
利用者が信号を見つけ、状況を理解し、適切に判断し、交信を成立させ、
記録し、振り返り、学び、試行できることを支援する。

技術的最適化は、利用者価値、正しさ、安全性、可逆性、互換性を損なってはならない。

## Target

- Language: Object Pascal (`{$mode objfpc}{$H+}`)
- Compiler: Free Pascal 3.2.2 / Lazarus 4.x
- Platforms: Windows / macOS
- CPU architectures: x86_64 / ARM64 where supported
- Baseline PC: Intel N150 相当
- Architecture: UI / Application / Modem / DSP / Audio-IQ
- Cross-cutting foundations: X Computing / Y Intelligent Processing / Z Quality
- 要求の出どころ: Amateur Radio Experience Platform Architecture Requirements v1.1

## この環境について

- **LCL が入っていない。** `lazarus/forms/` は建たない。`run_tests.sh` も建てない
- したがって画面に関わる変更は検証できない。**NOT VERIFIED と明記する**
- `lazarus/units/` は LCL に依存しない。これは無画面で試験するための方針であって、
  偶然ではない

## Permanent Rules

Skill の記述がこれらと矛盾する場合、こちらが優先する。

- 実コード、caller/callee、test、build 設定、architecture docs を確認してから変更する。
- 存在しない API、型、unit、設定、仕様を推測しない。
- 要求に必要な最小範囲を変更する。
- 無関係な refactor、整形、改名を混在させない。
- Audio / IQ / Spectrum などの高頻度データを Event Bus へ流さない (ADR-001)。
- DSP hot path に blocking I/O、UI 同期、不要な heap allocation、長時間 lock を追加しない。
- Worker thread から LCL UI を直接操作しない。`units/` に LCL を持ち込まない。
- 輪バッファの取りこぼしと流し直しを黙って隠さない。必ず呼び手に申告する。
- Raw Observation / Physical Confidence / Decoder Consensus / FEC Evidence /
  Context Support を混同しない。
- Auto / AI / Context 補正は利用者が Reject / Undo / Restore Raw できる設計を優先する。
- Receive は fail-soft、Transmit は fail-safe を基本方針とする。
- OS 依存性は散在させず、Platform Boundary へ限定する。
- データ形式・Plugin API・外部 ABI の互換性を意識する。
- **試験を通すために assertion を弱めたり skip したりしない。**
- **実行していない検証を成功と報告しない。** 実測していない数値を書かない。
- 現在の実行 OS だけで成功しても cross-platform verified と報告しない。
- 要求されていない commit / PR を行わない。push 先は指定されたブランチのみ。

## 検証の最低線

```bash
cd lazarus && ./run_tests.sh     # 全スイート。-Crio (範囲・IO・オーバーフロー) + heaptrc
```

- 2 回続けて走らせて結果が完全に同一であること
- 新しいスイートは `run_tests.sh` の `SUITES` と `.gitignore` の両方に登録する
- 試験が通ったら**実装を意図的に壊し、狙った主張が落ちることを確認する** (反証)
- `rsVerified` の要求には、それを検証したと申告した試験が必ず要る (`test_requirements`)

## Skill Map

| Skill | 発動 |
| --- | --- |
| `/fldigi-lazarus` | すべての変更。手順、Object Pascal、このリポジトリの規律、報告形式 |
| `/lazarus-radio-dsp` | DSP / モデム / スペクトルのファイルを触ったとき (自動) |
| `/lazarus-cross-platform` | ビルド設定 / OS 境界のファイルを触ったとき (自動) |
| `/lazarus-data-compat` | schema / 設定 / ログ / Plugin 境界を触ったとき (自動) |
| `/lazarus-security-privacy` | 送信制御 / 認証情報 / telemetry を触ったとき (自動) |
| `/lazarus-release` | リリース判定。手動呼び出しのみ |

中核 Skill を `lazarus-engineering` ではなく `fldigi-lazarus` と名付けてあるのは、
**personal skill (`~/.claude/skills/`) が project skill を上書きする**ためである。
同名にすると、利用者が個人用に入れている汎用版に隠れてこのリポジトリ版が読まれない。

## Documentation Rule

- `CLAUDE.md` = 変わらない事実と禁止事項
- `.claude/skills/` = どう考え、どう実装・検証するか
- `lazarus/docs/adr/` = なぜその構造にしたか
- `lazarus/README.md` = **連番の節が作業記録**。経緯・実測値・反証を残す
- Task Prompt = 今回何を変えるか
