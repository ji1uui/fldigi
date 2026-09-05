# 要求トレーサビリティ表 (Baseline v1.1 §18)

**この文書は `units/Requirements.pas` から生成されている。直接編集しないこと。**
生成しなおすには `./test/test_requirements` を実行する。

項目は §18 の定めるとおり REQ-ID / Experience / Objective /
Primary / Secondary / Extension / Priority / Phase /
Verification / Status。Primary Foundation は 1 つに限る。

「検証」欄の ✓ は、その REQ-ID を検証したと **試験が実行時に
申告した** ことを示す。表に書いてあるだけではこの印は付かない。

出典が `§18` の行は Baseline の表にそのまま載っているもの、
それ以外は Baseline 本文からこのプロジェクトで起こしたもの。

要求 60 件 (検証済 42 / 実装済 1 / 方針決定 3 / 起案 6 / 後送り 8)

## Phase 0

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ARC-001 | Audio/IQ/SpectrumをEvent Busに流さない | Communicate | B | Z | X | No | Must | test_eventbus / test_realtime | 検証済 | ✓ | §12, §19 ADR-001 | ADR-001 |
| ARC-002 | Modem APIが複数候補とEvidenceを返せる | Communicate | D | Y | Z | No | Must | test_evidence | 検証済 | ✓ | §6, §19 ADR-002 | ADR-002 |
| ARC-003 | Subscriber例外でEvent Bus全体を停止させない | Communicate | B | Z | - | No | Must | test_eventbus | 検証済 | ✓ | §12 | ADR-001 |
| ARC-004 | 高頻度イベントで復調文字を押し出さない (conflation) | Communicate | B | Z | X | No | Should | test_eventbus / test_observability | 検証済 | ✓ | §12 | ADR-001 |
| RT-001 | realtime経路で動的確保を行わない | Communicate | C | X | Z | No | Must | test_realtime (**全モデム**の送受信経路で確保回数を実測) | 検証済 | ✓ | §4 X-04。モデムを足したら試験も足すこと (PSK を足したとき漏れた) | ADR-009 |
| RT-002 | ブロック処理がdeadlineを守る | Communicate | C | X | Z | No | Must | test_realtime (**全モデム**の受信ブロックで deadline 比を実測) | 検証済 | ✓ | §14 Z-04。モデムを足したら試験も足すこと (PSK を足したとき漏れた) | ADR-009 |
| RT-003 | 並行性は要求から導き、並列性は実測から導く | Communicate | C | X | - | No | Should | 実測 (README §16) | 方針決定 |  | §4 X-03 | ADR-009 |
| OBS-001 | 障害診断のため出来事を時系列で残す | Communicate | B | Z | - | No | Must | test_observability | 検証済 | ✓ | §14 Z-01 | ADR-010 |
| OBS-002 | 観測の記録が動的確保を行わない | Communicate | C | Z | X | No | Must | test_observability (確保回数を実測) | 検証済 | ✓ | §14 Z-01, X-04 | ADR-010 |
| OBS-003 | アルゴリズム改善のため数値の分布を残す | Communicate | C | Z | - | No | Should | test_observability | 検証済 | ✓ | §14 Z-01 | ADR-010 |
| LOG-001 | 内部データモデルをADIFに制約しない | Collect | A | Z | - | No | Must | test_qsomodel (未知項目の往復) | 検証済 | ✓ | §13.4 | ADR-011 |
| LOG-002 | 値ごとに出所と確定段階を持つ | Communicate | D | Y | Z | No | Must | test_qsomodel | 検証済 | ✓ | §13.1 | ADR-011 |
| LOG-003 | 局所IDと改訂番号で同期の競合を判定できる | Collect | B | Z | - | Yes | Must | test_qsomodel | 検証済 | ✓ | §13.3 | ADR-011 |
| LOG-004 | 書き出しの順序が安定している | Collect | B | Z | - | No | Should | test_qsomodel | 検証済 | ✓ | §14 Z-05 | ADR-011 |
| PLG-001 | Plugin互換性をSemVerとCapability Negotiationで扱う | Experiment | D | Z | - | Yes | Must | test_plugin | 検証済 | ✓ | §11.1, §19 ADR-004 | ADR-004 |
| PLG-003 | Plugin障害をCoreや他Pluginへ波及させない | Experiment | B | Z | - | Yes | Must | test_plugin (壊れたPluginを実際に登録) | 検証済 | ✓ | §11.1 | ADR-005 |
| PLG-004 | APIが将来のサブプロセス化・Sandbox化を妨げない | Experiment | B | Z | X | Yes | Must | test_plugin (境界型のバイト列往復) | 検証済 | ✓ | §11.1, §19 ADR-005 | ADR-005 |
| PLG-005 | 外部Modem PluginはTest vectorsを必須提供する | Experiment | B | Z | - | Yes | Must | test_plugin (交渉で拒否) | 検証済 | ✓ | §11.1 | ADR-004 |
| SEC-001 | L6への保存はユーザー操作または明示的承認を前提とする | Communicate | D | Z | - | No | Must | test_context_memory | 検証済 | ✓ | §8.1 | ADR-003 |
| SEC-002 | 既定ではL5内で完結する | Communicate | D | Z | - | No | Must | test_context_memory | 検証済 | ✓ | §8, §8.1 | ADR-003 |
| SEC-003 | 保存内容をView/Edit/Delete/Export/Importできる | Communicate | D | Z | - | No | Must | test_context_memory | 検証済 | ✓ | §8.1 | ADR-003 |
| SEC-004 | 保存形式は将来暗号化を可能にする設計とする | Communicate | B | Z | - | No | Must | test_context_memory (容器の検査) | 検証済 | ✓ | §8.1 | ADR-003 |
| SEC-005 | Name/QTH等の個人情報は最小限保持を原則とする | Communicate | D | Z | - | No | Must | test_context_memory | 検証済 | ✓ | §8.1 | ADR-003 |
| SEC-006 | 暗号化の実装方式をPhase 0で決定する | Communicate | B | Z | - | No | Must | ADR-003 の記載 / 試験ベクタ照合 | 検証済 | ✓ | §8.1 | ADR-003 |
| CMP-001 | fldigi互換のADIF入出力を行う | Collect | A | Z | - | No | Must | test_adif_full / test_station_adif | 検証済 | ✓ | §3 A Compatibility |  |
| CMP-003 | CW受信で先頭文字が失われない | Communicate | B | Y | Z | No | Must | test_cw_leading (速度/雑音/符号種を振って全文一致) | 検証済 | ✓ | §3 A Compatibility (fldigi 由来の欠陥の是正) |  |
| CMP-002 | RTTY/CWの送受信がfldigi相当に成立する | Communicate | A | Y | - | No | Must | test_rtty_cw (ループバック) | 検証済 | ✓ | §3 A Compatibility |  |
| MAC-001 | マクロがQSOの文脈と手順に沿って展開される | Communicate | D | Y | Z | No | Should | test_macro | 検証済 | ✓ | §9 |  |
| CTX-001 | 受信テキストからコール/RST/ナンバーを抽出する | Communicate | D | Y | - | No | Should | test_rxextract | 検証済 | ✓ | §8 L2/L3 |  |

## Phase 1

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| RT-004 | 取り込みと復調をRing Bufferで分離する | Communicate | B | X | Z | No | Must | test_audioring (2スレッド通し番号照合) | 検証済 | ✓ | §4 X-01, §5.1 |  |
| RT-005 | Audio History Bufferを保持しReplay Decodeを可能とする | Experiment | D | X | Y | No | Must | test_audioring (並行書込下の整合性) / test_replay (流し直しの再現性) | 検証済 | ✓ | §4 X-06 |  |
| RT-006 | CPU core数を正しく検出しWorker数の根拠にする | Communicate | C | X | - | No | Must | test_audioring (TThread比較) | 検証済 | ✓ | §4 X-03, X-07 | ADR-009 |
| RT-007 | Audio I/O専用経路をDSP重処理から分離する | Communicate | B | X | Z | No | Must | test_capture (実時間デバイスで欠落を実測) | 検証済 | ✓ | §4 X-01 |  |
| RT-008 | FFTの係数表を共有サービス化し資源の重複を無くす | Communicate | C | X | Z | No | Should | test_fftshared (直接DFTとの照合・並行使用) | 検証済 | ✓ | §4 X-05 |  |
| SPC-001 | スペクトルを共有サービス化し複数の読み手に同じ枠を配る | Communicate | C | X | Y | No | Must | test_spectrum (既知正弦波の絶対値・複数読み手の一致・取りこぼしの申告・窓とFFT長に依らない雑音密度) | 検証済 | ✓ | §4 X-05, §5.1 | ADR-001 |
| MDM-002 | CW受信の整定過渡で先頭要素を失わない | Communicate | B | Y | Z | No | Should | test_cw_leading (整定過渡・低S/N・雑音のみ) / test_cw_tone | 検証済 | ✓ | §3 A / §16。README §28 |  |

## Phase 2

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| GUI-001 | スペクトルの履歴を表示用の段階値に変換し列と周波数を対応づける | Discover | D | X | Z | No | Must | test_waterfall (細い信号の保存・利得変化への追従・拡大時の対応・流し直しでの履歴破棄・取りこぼしの申告) | 検証済 | ✓ | §12 Phase 2 |  |
| GUI-002 | Waterfallを画面に描画し操作できるようにする | Discover | D | X | - | No | Must | LCL 環境での描画結合試験と目視確認 | 起案 |  | §12 Phase 2 |  |
| MDM-003 | BPSK (PSK31/63/125) の送受信が成立する | Communicate | A | Y | Z | No | Must | test_psk (往復・雑音耐性・全印字文字) | 検証済 | ✓ | Baseline Phase 2 Practical Compatible Core |  |
| MDM-004 | PSK復調が軟判定の尺度をEvidenceに載せる | Communicate | D | Y | Z | No | Should | test_psk (本文と雑音の余裕が分離することを実測) | 検証済 | ✓ | ADR-002 / §7 Phase 4 の Confidence の材料 | ADR-002 |
| MDM-005 | PSK31 VaricodeがfldigiのTableと一致する | Communicate | A | Z | - | No | Must | test_psk_varicode (往復・符号の形・長さ分布・一意性) | 検証済 | ✓ | fldigi src/psk/pskvaricode.cxx |  |
| QLT-001 | 試験をアプリと同じ検査設定 (範囲/オーバーフロー) で実行する | Communicate | B | Z | - | No | Must | test_regression ({$IFOPT} でビルド指定そのものを検査) | 検証済 | ✓ | §14 Z-02。アプリ側 .lpi は有効、試験は無効という食い違いがあった |  |
| QLT-003 | 試験が解放漏れを起こさない | Communicate | B | Z | - | No | Must | run_tests.sh が heaptrc を常時有効にし、スイートごとの許容数と照合して超えたら失敗させる (試験バイナリからは申告できないため rsImplemented) | 実装済 |  | §14 Z-02。try..finally の欠落はこの言語で最も事故が多い形である |  |
| QLT-002 | Test vectorsの波形が版を越えて同一である | Experiment | B | Z | - | No | Must | test_regression (乱数列と10分類の検査和を既知解で固定) | 検証済 | ✓ | §14.1 Golden WAV。同一性を謳いながら固定していなかった |  |
| MDM-001 | 劣悪条件のTest vectorsで回帰試験を行う | Communicate | B | Z | Y | No | Must | test_regression (4モード×10条件×8種の乱数でCER/BER) | 検証済 | ✓ | §14 Z-02, §14.1, §16, §17 |  |

## Phase 3

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| RTTY-021 | QSB時に複数復調戦略を比較 | Communicate | C | Y | X/Z | No | Must | Golden WAV BER/CER | 起案 |  | §18 | ADR-002 |
| SPC-002 | 雑音推定を共有サービス化し全戦略が同じ雑音床を見る | Communicate | B | Y | X | No | Must | SPC-001 の電力密度を用いた雑音床推定の較正試験 (Phase 3) | 後送り |  | §4 X-05 |  |
| MDM-006 | PSKがAFCで周波数ドリフトに追従する | Communicate | B | Y | - | No | Should | test_regression (Frequency drift の上限を既知の限界から引き下げる) | 後送り |  | Baseline Phase 3 Adaptive Receiver の AFC。実測: 60Hz ドリフトで PSK31/63 は本文CER 0.79/0.86、CW と RTTY(AFC) は 0.00 |  |

## Phase 4

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| GUI-014 | 低Confidence文字を視覚表示 | Communicate | D | Y | Z | No | Must | UI検証・ユーザーテスト | 起案 |  | §18 |  |
| CTX-008 | Context補正をReject可能 | Communicate | D | Y | Z | No | Must | 機能・Undo回帰試験 | 起案 |  | §18 |  |
| ARC-005 | L6 Persistent Memoryを実際に暗号化する | Communicate | B | Z | - | No | Should | 外部ライブラリ導入後の往復試験 | 後送り |  | §8.1。方針は決定済み、実装のみ保留 (README §30) | ADR-003 |
| ARC-006 | OSの鍵保管と連携する | Communicate | B | X | - | No | Could | プラットフォーム別の結合試験 | 後送り |  | §8.1。ARC-005 の後でなければ意味がない (README §30) | ADR-003 |
| CTX-002 | Contextは強い物理Evidenceを安易に上書きしない | Communicate | D | Y | - | No | Must | Context回帰試験 | 後送り |  | §7 |  |
| CTX-003 | Confidenceを校正された確率として扱う | Communicate | D | Y | Z | No | Must | ECE / Brier Score / Reliability Diagram | 後送り |  | §7 CF-01, §17.1 | ADR-002 |
| CTX-004 | L5登録条件をHigh Physical Confidence AND Format Validityとする | Communicate | D | Y | - | No | Must | Context回帰試験 | 後送り |  | §8, §19 ADR-008 |  |

## Phase 5

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| PLG-002 | 外部Modem Pluginをロード | Experiment | D | Z | X | Yes | Must | RTTY Plugin Acceptance | 起案 |  | §18 | ADR-004/005 |
| MDM-007 | モードから復調器を作る窓口を一箇所に置く | Communicate | D | Z | - | Yes | Should | Plugin 登録機構と同じ表を使って全モードを生成できること | 後送り |  | 2026-09 の品質レビュー。PLG-002 の登録機構に合わせる | ADR-004 |

## Phase 6

| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| QSL-004 | 複数QSL Confirmationを保持 | Collect | D | Z | - | Yes | Must | Data model / sync test | 方針決定 |  | §18 | ADR-011 |
| AWD-003 | QSO後にAward進捗更新 | Collect | D | Z | - | Yes | Must | Rule test / regression | 起案 |  | §18 |  |
| CNT-010 | Contest Exchangeを構造化 | Compete | D | Y | Z | Yes | Must | Contest vector test | 方針決定 |  | §18 | ADR-011 |

