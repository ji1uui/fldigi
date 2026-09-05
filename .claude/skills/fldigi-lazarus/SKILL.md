---
name: fldigi-lazarus
description: このリポジトリ (fldigi fork の lazarus/ 以下で開発している Lazarus / Free Pascal の無線通信アプリ) で作業するときの中核 Skill。調査・計画・実装・検証・レビュー・報告の手順、Object Pascal のリソース所有権、LCL とスレッド、そしてこのリポジトリ固有の規律 (要求トレーサビリティ §18、反証、run_tests.sh、範囲検査、units に LCL を持ち込まない、共有サービス) を含む。lazarus/ 以下の .pas / .lpr / .inc / run_tests.sh を読む・変更する・レビューするとき、および作業結果を報告するときに使う。
when_to_use: lazarus/ 以下のコードを読む前、変更方針を立てるとき、試験を書くとき、レビューを求められたとき、作業結果を報告するとき。
allowed-tools: Bash(git status *) Bash(git branch *) Bash(git log *) Bash(git diff *) Bash(fpc -i*) Bash(uname *) Bash(grep -m1 *)
---

# fldigi-lazarus — このリポジトリの中核 Skill

## 現在の作業状態

- ブランチ: !`git branch --show-current 2>&1 || true`
- 変更ファイル: !`git status --short 2>&1 || true`
- 直近コミット: !`git log --oneline -3 2>&1 || true`
- コンパイラ: !`fpc -iV 2>&1 || true`
- 実行環境: !`uname -srm 2>&1 || true`
- 現在フェーズ: !`grep -m1 'CURRENT_PHASE' lazarus/units/Requirements.pas 2>&1 || true`

上の未コミット変更は利用者の作業中の内容である。破棄も上書きもしない。
`fpc -iV` が空、または実行環境が想定と異なる場合、ビルド結果を cross-platform verified と報告しない。

## このリポジトリの形

```
src/            上流 fldigi の C++。**参照専用。変更しない**
                アルゴリズムと定数の出どころとして読む
lazarus/        作業対象。ここに新しいアプリを書いている
  units/        製品ユニット。**LCL に依存しない** (無画面で試験できる)
  forms/        LCL に依存してよい唯一の場所。run_tests.sh は建てない
  test/         スイートごとに 1 つの .lpr
  docs/adr/     Architecture Decision Record
  docs/requirements-matrix.md   生成物。手で編集しない
  README.md     **連番の節が作業記録**。実装の経緯・実測値・反証を残す
  run_tests.sh  全スイートの実行
```

C++ からの移植は**行単位の移植ではない**。ロジックとアルゴリズムを参照し、
Object Pascal として自然な形に書き直す。fldigi のどこを見たかはコメントに残す。

## Operating Model

> Inspect → Model → Plan → Implement → Verify → Falsify → Report

## Inspect

対象 unit、caller/callee、関連型、test、build 設定、類似実装を確認する。
事実・推測・提案を区別して述べる。

Baseline (要求文書) と `lazarus/units/Requirements.pas` を先に見る。
**次に何をするかは一覧から選ぶのではなく、Baseline と進捗の突き合わせで決める。**
過去に「等」「全モードの」といった語で覆われた要求が、覆う範囲が広がったのに
検証済のまま残っていた例が複数ある (README §36 §37)。

## Model

変更対象について最低限以下を把握する。

- responsibility
- input / output
- ownership / lifetime
- thread context
- state transitions
- failure boundary
- externally observable behavior

## Scope Control

- 要求に必要な最小変更
- 将来用途だけの抽象化禁止
- 新依存は必要性、license、platform、maintenance、security、performance を確認

## Object Pascal

- resource ownership は原則 try..finally
- try..except は回復境界で使用し、握りつぶさない
- interface 公開範囲を最小化
- Integer / Int64 / NativeInt / Single / Double / signedness を確認
- thread 終了前の参照先破棄を防ぐ
- FreeAndNil を機械的に使用しない
- `{$mode objfpc}{$H+}`、必要なら `{$modeswitch advancedrecords}`
- **文字列を含む record に `FillChar` をかけない** (参照カウントが壊れる)

### 置換のとき interface と implementation を取り違えない

同じ宣言が interface と implementation の両方にあるため、テキスト置換が
**宣言のほうに当たる**事故が繰り返し起きている (README §32 で 3 回)。
本体を編集するときは先に `implementation` の位置を取り、それ以降で置換する。

## 範囲検査つきでビルドする

試験もアプリも `-Crio` (範囲・IO・オーバーフロー検査) で建てる。
意図した桁あふれ (検査和、PRNG) は**その関数だけ**検査を外す。

```pascal
{$push}{$Q-}{$R-}
function Fnv1a(...): QWord;
...
end;
{$pop}
```

64 bit の即値は `$9E3779B97F4A7C15` のように書くと 2^63 を超えて弾かれる。
`(QWord($9E3779B9) shl 32) or QWord($7F4A7C15)` の形にする。

## UI / Threading

- UI thread を block しない
- worker から LCL を直接操作しない。原則 `TThread.Queue`
- **`units/` に LCL を持ち込まない。** 具象コンポーネントへの依存はコールバック
  注入にとどめる (`ModemUI.pas` の方針)。表示の**論理**は units 側に置き、
  無画面で試験する。描画だけを `forms/` に残す (`WaterfallModel.pas` が例)
- lock 中の I/O、UI 通知、未知 callback を避ける
- subscriber 例外を障害分離する

## Data Plane と Event Bus を混ぜない

ADR-001 / Baseline §5.1。Audio / IQ / **Spectrum** / DSP Frame は Data Plane
(Ring Buffer / bounded queue / 共有バッファ) で扱い、**Event Bus に載せない**。
Event Bus は状態変化・制御・結果通知の Control Plane 専用。

## 取りこぼしは黙って飛ばさない

輪バッファの読み手が追い越されたら、黙って飛ばさず**何枠飛ばしたかを返す**
(`srMissed`)。流し直し (Replay) をまたいだら**そうと知らせる** (`srReset`)。

表示だけなら取りこぼしても困らないが、統計を取る側は取りこぼしに気づけないと
**自分が偏っていることが分からない**。`AudioRing` / `SpectrumService` /
`WaterfallModel` で同じ規律を敷いている。

## 共有サービスを重複させない

FFT の係数表と Spectrum は共有サービスにしてある (X-05)。DSP の基本部品を
leaf ユニットに書き足すと二本になり、いずれ食い違う。順位統計 (`PercentileInPlace`)
のように複数の利用者が要るものは `ModemDSP.pas` に置く。

## Testing

1. changed-unit test
2. related integration test
3. build
4. regression
5. diff review

**試験を通すために assertion を弱めたり skip したりしない。**

### 走らせ方

```bash
cd lazarus && ./run_tests.sh          # 全スイート。-Crio + heaptrc つき
```

新しいスイートを足したら `run_tests.sh` の `SUITES` と `.gitignore` の両方に
登録する。`test_requirements` は材料が揃ってから走るので**必ず最後**。

単体で建てるとき:

```bash
cd lazarus && rm -f test/*.ppu test/*.o \
  && fpc -Crio -gl -Fuunits -Futest -FEtest -otest_X test/test_X.lpr && ./test/test_X
```

`.ppu` / `.o` を消すのを忘れると、同じ秒内の再ビルドが飛ばされて
**古いバイナリを試験してしまう**。

### 決定性と解放漏れ

- 2 回続けて走らせて結果が完全に同一であること (Z-05)
- heaptrc で解放漏れを見る。既知の基準値は `run_tests.sh` の `leak_baseline`
- 乱数は系統の `Random` ではなく `TestVectors.TVectorRandom` を使う

### 期待値を先に固定する

試験を書く順序を間違えると、壊れているものを「正しい」として固定してしまう。
検査設定を変えるときは **先に現在の値を数字で固定し**、それから設定を変える。

## 反証 (Falsification)

**試験が通っただけでは、その試験が何かを守っている証拠にならない。**

実装を意図的に壊し、狙った主張が落ちることを確認する。復旧して通ることも
確認する。壊し方を変えたら**別の**主張が落ちるのが望ましい。

反証は「試験が正しいか」を試す唯一の手段である。この規律で実際に穴が
見つかっている ―― `ColumnFrequency` が列の中心ではなく左端を返すようにしても
86 件すべてが通った (README §38)。往復の試験は左端でも中心でも成り立つため。

## 要求トレーサビリティ (§18)

`lazarus/units/Requirements.pas` が要求の表、`test_requirements` が突き合わせ。

- 試験は通ったときだけ `CoverReq('REQ-ID')` を申告する
- `rsVerified` なのに申告した試験が無ければ**落ちる**
- 表に無い ID を申告しても落ちる
- `CURRENT_PHASE` より後のフェーズを `rsVerified` にできない
- `docs/requirements-matrix.md` は生成物。手で編集しない

要求の文面が実態より広いときは**要求を割る**。試験できる半分だけを見て
「検証済」と書かない。まだやっていない分は `rsProposed` / `rsDeferred` で
**見えるように残す** (例: GUI-001 検証済 / GUI-002 起案)。

## 書き方

- コメントは日本語。**何をしているかではなく、なぜそうしたかを書く**
- 周囲のコメント密度・命名・語り口に合わせる
- 捨てた選択肢とその理由を残すと、次に同じ検討を繰り返さずに済む
- 実測値は数字で残す。「速くなった」ではなく「62.5 → 40.7 us」

## Git

- 既存の未 commit 変更を保護する
- `reset --hard`、`clean -fd`、force push 等を無断で行わない
- 要求されていない commit / PR を行わない
- push 先は指定されたブランチのみ

## Quality Gates

変更内容に応じて組み合わせる。

Build / Unit Test / Integration Test / Golden WAV / Replay / Performance /
Cross-platform / UX Scenario / Compatibility / Security / Privacy / Packaging / Smoke Test

この環境には **LCL が入っていない**。`forms/` は建たない。
画面に関わる変更は **NOT VERIFIED** と明記する。

## Completion Report

作業の最後に、以下の見出しで報告する。

- Changes
- Design / Root cause
- Verification
- UX / Behavioral impact
- Compatibility impact
- Performance impact
- Remaining risks
- Not verified

実行していない検証は **NOT VERIFIED** と明記する。
実測していない数値を書かない。

作業がひと区切りついたら `lazarus/README.md` に連番の節を足す。
経緯・設計判断・実測値・反証の表を残す。**これがこのリポジトリの作業記録である。**

## References

必要になったときだけ読む。

- 状態遷移、イベント順序、時刻、クロック → [references/state-and-time.md](references/state-and-time.md)
- ログ出力、診断、計測、再現性 → [references/observability.md](references/observability.md)
- 機能設計、UI、自動化、AI 補正、エラー提示 → [references/user-experience.md](references/user-experience.md)
- タスク定義の雛形 → [references/task-prompt-template.md](references/task-prompt-template.md)
- 製品固有仕様の置き場所 → [references/architecture-docs.md](references/architecture-docs.md), [references/quality-model.md](references/quality-model.md)

専門領域は別 Skill が `paths` で自動的に載る (DSP / cross-platform /
data-compat / security-privacy)。リリース判定は `/lazarus-release`。
