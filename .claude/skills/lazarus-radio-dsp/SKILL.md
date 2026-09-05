---
name: lazarus-radio-dsp
description: 無線DSP、モデム、デコーダの変更に適用する専門知識。Signal Contract、リアルタイム経路、hot pathの禁止事項、Evidence Model、受信状態推定、Algorithm Portfolio、Golden WAV、モード別（CW/RTTY/PSK/Olivia/FT8/FT4）の要点。
when_to_use: 復調、フィルタ、AGC、同期、AFC、FEC、デコーダ、モデム、リングバッファ、FFT、サンプルレート、Golden WAVに触れるとき。
paths:
  # DSP・モデム・スペクトルの実装。glob は **プロジェクトルート相対・大文字小文字を区別する**
  # ので、このリポジトリの PascalCase に合わせてある (小文字 *modem* では ModemDSP.pas に
  # 当たらない)。上流の C++ (src/) は参照専用なので含めない。
  - "lazarus/units/*Modem*.pas"
  - "lazarus/units/*Audio*.pas"
  - "lazarus/units/Spectrum*.pas"
  - "lazarus/units/Waterfall*.pas"
  - "lazarus/units/*Tone*.pas"
  - "lazarus/units/*Varicode*.pas"
  - "lazarus/units/Morse*.pas"
  - "lazarus/units/Wave*.pas"
  - "lazarus/units/TestVectors.pas"
  - "lazarus/units/ErrorRate.pas"
  - "lazarus/units/DecodeEvidence.pas"
  - "lazarus/units/*.inc"
  - "lazarus/test/test_cw*.lpr"
  - "lazarus/test/test_psk*.lpr"
  - "lazarus/test/test_rtty*.lpr"
  - "lazarus/test/test_modem.lpr"
  - "lazarus/test/test_fft*.lpr"
  - "lazarus/test/test_filter*.lpr"
  - "lazarus/test/test_spectrum.lpr"
  - "lazarus/test/test_waterfall.lpr"
  - "lazarus/test/test_regression.lpr"
  - "lazarus/test/test_audioring.lpr"
  - "lazarus/test/test_capture.lpr"
  - "lazarus/test/test_replay.lpr"
  - "lazarus/test/test_realtime.lpr"
user-invocable: true
---

# Radio / DSP

## Signal Contract

変更前に必要な値を確認する。
Sample rate / block size / FFT size / window / overlap / center frequency /
baud or symbol rate / filter bandwidth / AFC range / buffer length / latency budget.

不明な値を仮定して実装しない。確認できない場合はその旨を述べる。

## Real-time Path

Audio Capture → Ring Buffer → DSP Worker → Decoder → Result Queue → Application/UI

Audio/IQ/sample-level dataをEvent Busへ流さない。

## DSP Hot Path

- per-block heap allocation回避
- blocking I/O禁止
- UI同期禁止
- 長時間lock禁止
- NaN / Infinity / divide-by-zero / overflow防止
- silenceでも安定状態を維持

## Evidence Model

分離して保持する。混同や不可逆な上書きをしない。

- Raw Observation
- Physical Confidence
- Decoder Consensus
- FEC Evidence
- Context Support

ContextでRaw/Physical結果を不可逆に上書きしない。

## Reception State Estimation

必要に応じ:
S/N / noise floor / drift / QSB / impulsive noise /
adjacent QRM / co-channel QRM / clipping / AGC instability.

Observation → State Estimation → Portfolio Selection → Decode

## Algorithm Portfolio

Normal / Robust / Low-SNR / QRM-resistant / Drift-tolerant等を
state / confidence / CPU budgetに応じて選択する。

## Golden WAV

最低:
Strong / Medium / Weak / Very Weak / QSB / Drift /
Adjacent QRM / Co-channel QRM / Impulse / Clipping / Silence / Truncated.

期待値:
- decode result
- max errors
- no-crash
- false decode
- latency where relevant

## Replay

LiveAudioSourceとWavReplaySourceを同一DSP pipelineへ入力する。

## Performance

Intel N150相当を基準に可能な範囲で:
CPU / processing time / max processing time / queue depth /
dropped samples / memory / allocation.

原則: processing_time < audio_block_duration

## Mode Specific

- CW: tone / threshold / timing / speed / segmentation / AFC / overlap
- RTTY: Mark/Space / shift / baud / polarity / ATC / AFC / selective fading / QRM
- PSK: carrier recovery / symbol timing / phase / AFC
- Olivia: multi-tone / synchronization / interleaving / FEC / latency
- FT8/FT4: preprocess → sync → candidate → refine → demod → LLR → LDPC → CRC → unpack

## このリポジトリでの実体

| 概念 | 実装 |
| --- | --- |
| Ring Buffer / Audio History | `lazarus/units/AudioRing.pas` |
| 共有 FFT プラン | `ModemDSP.SharedFftPlan` (X-05。各所で作り直さない) |
| 共有スペクトル | `lazarus/units/SpectrumService.pas` (Event Bus に載せない) |
| Waterfall の表示論理 | `lazarus/units/WaterfallModel.pas` (LCL に依存しない) |
| Golden WAV / 劣化条件 | `lazarus/units/TestVectors.pas` (Baseline §14.1 の 10 分類) |
| BER / CER | `lazarus/units/ErrorRate.pas` |
| Evidence | `lazarus/units/DecodeEvidence.pas` |
| モデム | `Cw/Rtty/Psk/NullModemImpl.pas`, `ModemEngine.pas` |
| 回帰試験 | `lazarus/test/test_regression.lpr` (MDM-001) |

Golden WAV の分類はこのリポジトリでは Baseline §14.1 の 10 種
(Clean / AWGN / Extreme QSB / Adjacent QRM / Impulse / Frequency drift /
Timing mismatch / Selective fading / Clipping / Silence) を実装してある。
上の一般論と食い違うときは **Baseline と TestVectors.pas が優先**する。

モデムを足したら、そのモデムを **RT-001 / RT-002 (realtime 経路) と
MDM-001 (回帰) の試験にも足す**。過去に PSK を足したとき漏れた (README §36)。

## DoD

Signal Contractを確認した / hot pathの禁止事項に違反していない /
Evidence Modelの分離を壊していない / 関連するGolden WAVの想定を述べた。
未実行のGolden WAV検証は NOT VERIFIED と明記する。
