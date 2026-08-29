# ADR-002: Modem API は複数候補と Evidence を返せる型にする

- 状態: 採用 (Phase 0)
- 対応する Baseline: Architecture & Requirements Baseline v1.1 §19 ADR-002
- 実装: `units/DecodeEvidence.pas`, `units/Modem.pas`
- 検証: `test/test_evidence.lpr`

## 背景

従来の復調器は「確定した1文字」を1つずつ上位へ push していた。

```pascal
procedure PutRxChar(ACh: Integer);
property OnPutRxChar: TPutRxCharEvent;
```

この形は原理的に次を運べない。

- 第2候補（「E かもしれないし I かもしれない」）
- その判断の根拠（軟判定の余裕、尤度、相関）
- どの復調戦略が出したのか（v1.1 Phase 3 の Algorithm Portfolio）
- 入力のどの位置から出たのか（Phase 3 以降の Replay Decode / X-06）

v1.1 の Phase 4（Confidence & Context）と第10章（Confidence-aware GUI）は
これらを前提にしている。復調器を増やしてから型を変えると全モデムの
書き換えになるため、Phase 0 のうちに確定させる。

## 決定

復調結果を `TDecodeEvidence` として渡す。

```pascal
TDecodeEvidence = record
  Candidates: TDecodeCandidateArray;   // [0] が最有力。空なら候補なし
  MetricKind: TEvidenceMetricKind;     // 尺度の種類
  DecoderName: string;                 // どの戦略が出したか
  SamplePos: Int64;                    // 入力のどの位置から出たか
  HasSnr: Boolean;   SnrDb: Double;
  HasFreqOffset: Boolean; FreqOffsetHz: Double;
end;
```

上位への出口は `OnDecode` ひとつに統一し、`OnPutRxChar` は廃止した。
軟判定を持たない復調器は `EmitRxChar` を使えばよく、内部で
候補1件・`emkNone` の Evidence が組み立てられる。

## Evidence と Confidence を区別する（§7 CF-01）

本 ADR が運ぶのは **Evidence** であって Confidence ではない。

| | 内容 |
|---|---|
| Evidence | 復調器の内部尺度。モードごとに意味も尺度も違い、校正されていない |
| Confidence | ユーザーに見せる校正済みの確からしさ。`P(correct \| c) ≈ c` |

混同すると「Confidence 90%」と表示しながら実際の正答率が 60% という、
不確実性を誤解させる表示になる。校正は Phase 4 の責務であり、
本層は生の Evidence を素直に運ぶことに徹する。

`MetricKind` を値と一緒に運ぶのは、尺度の意味がモードごとに違うためである。
「大きいほど良い」という向きだけを共通の約束とし、値の比較は同じ
`MetricKind` どうしでのみ意味を持つ。

## 実装した Evidence（型だけでなく中身を入れた）

型を広げただけで中身が空なら、Phase 4 は結局作れない。そこで既存の
2 モデムに実際の値を載せた。

### RTTY — 軟判定の余裕と第2候補

ATC（Automatic Threshold Correction）の判定変数 `V3` は、符号がビット値、
大きさが判定境界からの距離にあたる。包絡線エネルギーで正規化すると
`-1..+1` の無次元量になり、0 に近いほど「どちらとも言えない」ビットになる。

- 文字の尺度 = その文字を構成したデータビットのうち最も余裕が小さいもの
  （弱いビットが1つでもあれば文字全体が危うい）
- 第2候補 = 最も弱いビットを反転した文字

実測（無雑音ループバック、22文字）: 尺度つき 22 / 第2候補あり 11 /
余裕の範囲 0.471〜0.501。

### CW — 尺度は載せない

CW の復号は「短点・長点の時間パターンをモールス表と照合する」方式で、
一致しなければ何も出さない。候補に順位をつけるには照合を距離つきの
近傍探索に作り替える必要があり、それは Phase 3 の Algorithm Portfolio の
仕事になる。**持っていない尺度をでっち上げると、根拠のない値が Evidence
として流れ、Phase 4 の校正が成り立たなくなる**ので、`emkNone` のままにした。
SNR は持っているので載せている。

## 作業中に踏んだ罠

第2候補を作るために「ビットを反転したらどの文字か」を仮復号したところ、
`BaudotDec` が文字/数字シフト状態（`FRxMode`）を書き換えるため、
**仮の計算の副作用で本物のシフト状態が壊れた**。`12345` が `WERT` になった
（Baudot では 2=W, 3=E, 4=R, 5=T）。

仮復号は必ず状態を保存・復元する `SpeculativeDecode` に閉じ込め、
回帰テスト（test_evidence の 3 番）で固定した。

## 影響範囲

| 変更 | 対象 |
|---|---|
| API 置き換え | `Modem.pas`（`OnPutRxChar` → `OnDecode`） |
| Evidence 生成 | `RttyModemImpl.pas`（軟判定＋第2候補）、`CwModemImpl.pas`（SNR のみ） |
| 受け側 | `ModemUI.pas`（`TUIRxCharEvent` に尺度を追加）、`forms/UnitMainForm.pas` |
| テスト | `test_evidence.lpr`（新規）、`test_rtty_cw` / `test_modem` / `test_threadsafety` |

UI の有界 FIFO には候補の配列そのものを載せていない。要素を固定長に保つ
必要があり（受信文字ごとに確保が走ると X-04 の趣旨に反する）、
最有力候補の文字・尺度・第2候補の件数という要約だけを運ぶ。
補正候補の提示が要る Phase 4 で、候補列を別経路で渡す形に拡張する。

## 代替案と却下理由

**`OnPutRxChar` を残して並存させる。** 移行は楽だが、2 つの出口が並ぶと
新しい復調器がどちらを使うか揺れ、結局 Evidence が空のまま Phase 4 を
迎える。出口は 1 つにした。

**Confidence をこの層で計算する。** 校正には実測データが要る（§17.1 の
ECE / Brier）。データが無い段階で数値を出すと、その数値が既成事実になる。
Phase 4 まで持ち込まない。
