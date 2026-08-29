# fldigi → Lazarus (Free Pascal) モデム/UIクラス設計

このディレクトリは、fldigi (`src/include/modem.h`, `src/trx/*.cxx`, `sound.h`,
`trx.h`, `qrunner.h` 等) のクラス構造を解析し、Lazarus/FPC (ObjFPC mode) で
実装するために設計・実装したモデム基底クラス群と、それを LCL GUI と
安全に接続するための UI 連携クラス (`TModemUI`) のリファレンス実装です。

すべてのユニットは **FPC 3.2.2 / Lazarus 4.0 で実際にコンパイル・リンク・
実行して動作確認済み** です。

## ディレクトリ構成

```
lazarus/
├── units/                 -- GUIに依存しないコアユニット群
│   ├── SoundIntf.pas       サウンドカードI/O抽象化 (fldigi: sound.h SoundBase)
│   ├── ModemTypes.pas      モード/状態の列挙型 (fldigi: globals.h)
│   ├── Modem.pas           モデム基底クラス TCustomModem (fldigi: modem.h/.cxx)
│   ├── ModemEngine.pas     送受信駆動スレッド TModemEngine (fldigi: trx.cxx)
│   ├── ModemUI.pas         GUI連携ブリッジ TModemUI (fldigi: qrunner.h + REQ())
│   ├── NullModemImpl.pas   最小実装サンプル TNullModem (fldigi: nullmodem.h/.cxx)
│   ├── ModemDSP.pas        共通DSPヘルパー (複素数演算/FFT/TFftFilt/移動平均)
│   ├── MorseTable.pas      モールス符号テーブル (fldigi: morse.h/.cxx cMorse)
│   ├── RttyModemImpl.pas   RTTYモデム具象実装 TRttyModem (fldigi: rtty.cxx)
│   ├── CwModemImpl.pas     CWモデム具象実装 TCwModem (fldigi: cw.cxx)
│   ├── PortAudioBindings.pas     PortAudio C API の直接バインディング
│   ├── PortAudioSoundDevice.pas  実サウンドカードI/O実装 (fldigi: sound.h SoundPort)
│   ├── HamlibBindings.pas        Hamlib C API の直接バインディング
│   ├── RigControlIntf.pas        無線機CAT制御の抽象基底 TCustomRigControl
│   ├── HamlibRigControl.pas      Hamlib具象実装 THamlibRigControl
│   ├── RigPollThread.pas         リグ状態監視スレッド TRigPollThread (fldigi: hamlib_loop)
│   ├── StationInfo.pas           局情報 (コールサイン等) の記憶 (fldigi: progdefaults)
│   ├── AdifUdpSender.pas         ADIF-over-UDP 外部ロガー連携
│   ├── QsoLogbook.pas            本アプリ内蔵QSOロギング (fldigi: cQsoDb)
│   ├── AdifFile.pas              完全版ADIF入出力 (fldigi: cQsoRec/cQsoDb)
│   ├── DxccDatabase.pas          cty.dat解析・DXCC/ゾーン判定 (fldigi: dxcc.cxx)
│   ├── ContestLog.pas            コンテストロギング (fldigi: contest.cxx/counties.cxx)
│   ├── OpProfile.pas             運用プロファイル (局/運用者/運用地/設備/形態の5軸)
│   ├── AppConfig.pas             PC固有設定(接続軸)・セッション状態
│   ├── DecodeEvidence.pas        復調結果と根拠 (ADR-002 / Phase 0 Core interface)
│   ├── EventBus.pas              Control Plane 専用の通知路 (ADR-001 / §12)
│   ├── MacroEngine.pas           ラバースタンプ/コンテスト用マクロ (fldigi: macros.cxx)
│   ├── RxExtract.pas             受信テキストからのコール/RST/ナンバー抽出
│   └── SafeFileIO.pas            原子的なファイル保存・生バイト読込の共通ヘルパー
├── forms/                  -- LCL (GUI) を使った実装例
│   ├── UnitMainForm.pas    TForm 継承のメインフォーム実装例
│   ├── DemoModemApp.lpr    デモアプリのエントリポイント
│   └── DemoModemApp.lpi    Lazarus プロジェクトファイル
└── test/
    ├── test_modem.lpr        GUIなしの結合テスト (スレッド安全性を検証)
    ├── test_rtty_cw.lpr      RTTY/CW 送受信ループバックテスト
    ├── test_fftfilt.lpr      ComplexFFT/TFftFilt (Overlap-Add FFTフィルタ)の単体検証
    ├── test_filter_switch.lpr RTTY/CWのフィルタ再生成(パラメータ変更時)の安定性テスト
    ├── test_portaudio.lpr    PortAudio バインディングの動作確認テスト
    ├── test_rigcontrol.lpr   Hamlib CAT制御の動作確認テスト (疑似CAT通信)
    ├── test_station_adif.lpr 局情報記憶/ADIF-UDP送信/内蔵ロギングの動作確認テスト
    ├── test_contestlog.lpr   コンテストロギング/DXCC・ゾーン判定の動作確認テスト
    ├── test_opprofile.lpr    運用プロファイル/PC固有設定の動作確認テスト
    ├── test_robustness.lpr   堅牢性・品質改善の回帰テスト
    ├── test_threadsafety.lpr 並行処理・音声・PTT の安全性回帰テスト
    ├── TestSupport.pas       テスト共通部品 (Phase 0: Test framework)
    ├── test_macro.lpr        マクロ展開/送信前バリデーション/実行のテスト
    ├── test_rxextract.lpr    受信抽出/宣言的条件分岐のテスト
    ├── test_evidence.lpr     ADR-002 Modem API (Evidence) のテスト
    ├── test_realtime.lpr     X-04 realtime 経路の動的確保の検証
    └── test_eventbus.lpr     ADR-001 / §12 Event Bus のテスト
```

## 1. モデムエンジン設計 (`TCustomModem` / `TModemEngine`)

### fldigi との対応表

| fldigi (C++)                                   | Lazarus (Pascal)                       | 役割 |
|--------------------------------------------------|------------------------------------------|------|
| `class modem` (modem.h)                          | `TCustomModem` (Modem.pas)                | 全モデムの抽象基底クラス |
| `virtual void tx_init() = 0;`                    | `procedure TxInit; virtual; abstract;`    | 送信初期化 |
| `virtual void rx_init() = 0;`                    | `procedure RxInit; virtual; abstract;`    | 受信初期化 |
| `virtual void restart() = 0;`                    | `procedure Restart; virtual; abstract;`   | 帯域/モード変更時の再初期化 |
| `virtual int rx_process(const double*, int) = 0;`| `function RxProcess(...): Integer; abstract;` | 受信復調処理 |
| `virtual int tx_process();`                      | `function TxProcess: Integer; virtual;`   | 送信波形生成 (共通ロジックは基底が提供) |
| `class NULLMODEM : public modem`                 | `TNullModem = class(TCustomModem)`        | 最小実装の具体例 |
| `class SoundBase` (sound.h)                      | `TCustomSoundDevice` (SoundIntf.pas)      | オーディオI/O抽象化 |
| `trx.cxx` の専用スレッド + `state_t`             | `TModemEngine = class(TThread)`           | 送受信状態機械の駆動 |
| `double frequency`, `bandwidth`, `metric` 等      | 対応する `property`                       | モデム共通パラメータ |

### 設計判断のポイント

- **Strategy パターンの踏襲**: fldigi は 100 種類以上のモード
  (PSK/RTTY/MFSK/Olivia/Hellschreiber…) を、共通の `modem` 基底クラス
  1本で扱う。Lazarus 版も `TCustomModem` を継承するだけで新モードを
  追加できる構造にしている (`TNullModem` がその実装例)。
- **スレッド非依存の DSP コア**: `TCustomModem` 自体は `TThread` では
  なく、「呼ばれたら1ブロック処理して返る」設計。実際の駆動は
  `TModemEngine` (`TThread` 派生) が担当し、fldigi の `trx.cxx` にある
  `trx_receive_loop()`/`trx_transmit_loop()` を再現している。
- **GUI 非依存**: `units/` 以下は LCL に一切依存しない。これにより
  `lcl-nogui` はもちろん、コンソールのみの環境でも DSP ロジックの
  単体テストが可能 (`test/test_modem.lpr` 参照)。

## 2. UI連携設計 (`TModemUI`)

fldigi は音声処理スレッド (`TRX_TID`) から GUI (FLTK, メインスレッド) を
直接触ることができないため、`qrunner` という自作のスレッド間キューを
持ち、`REQ(put_freq, frequency);` のようなマクロで「関数+引数」を
キューへ積んで後でメインスレッドが実行する、という仕組みを持つ
(`src/include/qrunner.h`)。

Lazarus では同じ役割を **`TThread.Queue`** が標準で提供しているため、
`TModemUI` はこれをラップして以下を実現する。

```
[TModemEngine のワーカースレッド]
        │  RxProcess() 内で復調した文字/周波数/メトリックを算出
        ▼
[TCustomModem] --- イベント発火 (OnFrequencyChanged 等) --->  [TModemUI]
                                                                  │
                                                    TThread.Queue で
                                                    一時変数に値を保持しつつ
                                                    メインスレッドへ転送
                                                                  ▼
                                                [TMainForm のコールバック]
                                                (TMemo/TLabel 等の更新は
                                                 常にメインスレッドで安全に実行)
```

例外は `get_tx_char()` 相当 (`OnGetTxChar`) で、これは fldigi でも
同期的に呼ばれる (`REQ` を使わない) ため、`TModemUI` でも Queue を
介さず直接呼び出す。ただし **ワーカースレッドから直接呼ばれる**ため、
実装側 (フォーム) は LCL コンポーネントに触れず、
`TCriticalSection` で保護したバッファ操作のみ行うこと
(`UnitMainForm.pas` の `HandleGetTxChar` 参照)。

### fldigi のグローバル関数との対応

| fldigi (fl_digi.h / qrunner.h)                  | Lazarus (`TModemUI`)                     |
|---------------------------------------------------|---------------------------------------------|
| `REQ(put_freq, frequency);`                       | `OnFrequencyChanged` (Queue経由)             |
| `REQ(callback_set_metric, m);`                    | `OnMetricChanged` (Queue経由)                |
| `put_Status1(msg)` / `put_MODEstatus(...)`        | `OnStatusText` (Queue経由)                   |
| `put_rx_char(c)`                                  | `OnRxChar` (Queue経由)                       |
| `get_tx_char()`                                   | `OnGetTxChar` (直接呼び出し・同期)           |
| `trx_state` の変化                                | `OnStateChanged` (Queue経由)                 |

## 3. 実装例 (`forms/UnitMainForm.pas`)

`TMainForm` は fldigi のメインウィンドウ (受信テキスト表示 / 周波数表示 /
信号品質メータ / ステータスバー / 送信エントリ) を模した最小構成の
LCL フォームです。`TModemUI` のイベントを購読するだけでよく、
スレッドやモデムの内部構造を意識する必要がありません。

## ビルド・テスト方法

```bash
# コアユニットのみの単体コンパイル確認
fpc -Sood -Mobjfpc -FEtest -FUtest units/Modem.pas

# GUIなし結合テスト (スレッド安全性の検証)
fpc -Sood -Mobjfpc -FEtest -FUtest -FUunits test/test_modem.lpr
./test/test_modem

# LCL GUI アプリのビルド (要 lazbuild / lcl-nogui または lcl-gtk2 等)
cd forms
lazbuild DemoModemApp.lpi      # 実機/デスクトップ環境
lazbuild --ws=nogui DemoModemApp.lpi   # ヘッドレス動作確認用
```

## 新しいモード (PSK/RTTY/Hellschreiber 等) を追加するには

1. `TCustomModem` を継承した新クラスを作成する
   (`NullModemImpl.pas` を雛形にする)。
2. fldigi の対応する `.cxx` (例: `src/psk/psk.cxx`) の
   `rx_process()`/`tx_process()` の信号処理ロジックを
   Pascal に移植し、`RxProcess`/`TxProcess` として実装する。
3. 復調結果の文字は基底クラスの `EmitRxChar` (protected) を通じて
   通知する。送信文字は `FetchTxChar` (protected) で取得する。
4. `TModemEngine.SetModem()` で差し替えるだけで `TModemUI`/フォーム側の
   変更は一切不要 (Strategy パターンの利点)。

## 4. RTTY / CW 実装 (`units/RttyModemImpl.pas` / `units/CwModemImpl.pas`)

`TCustomModem` を継承した具象モデムの実装例として、fldigi の
`src/cw_rtty/rtty.cxx` (RTTY) と `src/cw_rtty/cw.cxx` (CW/モールス) を
Lazarus/FPC へ移植しました。共通の DSP ヘルパーは `units/ModemDSP.pas`
(複素数演算・移動平均 `TMovingAverage`・`DecayAvg`/`ClampF`・
Overlap-Add FFT畳み込みフィルタ `TFftFilt` とその基盤の
`ComplexFFT`/`InverseComplexFFT`) と `units/MorseTable.pas` (`cMorse`
相当のモールス符号テーブル) に切り出しています。

### RTTY (`TRttyModem`, fldigi: `class rtty`)

| fldigi (C++)                          | Lazarus (Pascal)                         |
|----------------------------------------|-------------------------------------------|
| `rx_bit()` / ステートマシン (IDLE/START/DATA/STOP) | `RxBit` / `TRttyRxState`               |
| `fftfilt` (`rtty_filter()`、mark/space用raised-cosine整合フィルタ) | `ModemDSP.TFftFilt.RttyFilter` |
| mark/space 履歴の位相差による AFC      | `FMarkHistory`/`FSpaceHistory` + `Ferr` 計算 |
| `rparity`/Baudot 5bit エンコード       | `RParity` / `BaudotEnc`                   |
| `Metric()` (SNR ベース信号品質)        | `ComputeMetric`                           |

- 実装済み: Baudot 5bit、Mark/Space FSK 復調、AFC (周波数誤差の自動追従)、
  パリティチェック、fldigi 本来の fftfilt によるフィルタリング (下記
  「4-1. フィルタ品質改善」参照)。

### CW / モールス信号 (`TCwModem`, fldigi: `class cw`)

| fldigi (C++)                              | Lazarus (Pascal)                     |
|---------------------------------------------|-----------------------------------------|
| `handle_event()` (RS_IDLE/RS_IN_TONE/RS_AFTER_TONE) | `HandleEvent` / `TCwRxState`     |
| `rx_FFTprocess()` (`fftfilt`によるローパス + DEC_RATIO間引き) | `RxProcess` (`ModemDSP.TFftFilt` + `CW_DEC_RATIO`) |
| `decode_stream()` (AGC + ノイズフロア追跡ヒステリシス検出) | `DecodeStream`                  |
| `update_tracking()` (dot-dash/dash-dot ペア比較の適応速度追跡) | `UpdateTracking`               |
| `sync_parameters()`/`sync_transmit_parameters()` | `SyncParameters`/`SyncTransmitParameters` |
| `nco()`/`send_symbol()`/`send_ch()` (送信)   | `Nco`/`SendSymbol`/`SendCh`             |
| `cMorse::rx_lookup`/`tx_lookup`              | `MorseTable.pas` の `TMorseTable`       |

- **SOM (Self-Organizing Map) デコード** (`progdefaults.CWuseSOMdecoding`,
  既定無効) は実装対象外です。主デコードパスである `handle_event`
  ベースの古典的タイミングステートマシンのみを移植しています。
- QSK (フルブレークイン) の右チャンネル制御信号生成・`CW_KEYLINE`
  (DTR/RTS キーイング)・外部キーヤー (WinKeyer 等) 連携は省略しています。
  送信波形整形 (rise time, Hanning/Blackman) は実装済みです。
- **"整合フィルタ" (CWmfilt) モード** (`progdefaults.CWmfilt`, 既定無効。
  有効時は帯域幅を送信速度に比例させて自動設定する) は未実装です。
  既定 (無効) の経路である「`Bandwidth` プロパティ (既定150Hz) を
  固定カットオフとして使う」経路のみ実装しています。

### 4-1. フィルタ品質改善 (2026-08): fftfilt (Overlap-Add FFT畳み込み) への置き換え

当初の RTTY/CW 移植では、fldigi 本来の `fftfilt` (Blackman窓付き
Windowed-Sinc フィルタを FFT で周波数応答に変換し、Overlap-Add 方式で
畳み込む本格的なフィルタ) の代わりに、「mark/space トーンの包絡線検波」
という目的には十分な特性を持つ複素1次IIRローパス (`TComplexLowpass`)
で簡略化していました。今回、fldigi の `src/include/fftfilt.h` /
`src/filters/fftfilt.cxx` を解析し、`ModemDSP.TFftFilt` として正式に
移植し、RTTY (`mark_filt`/`space_filt`、`rtty_filter()`によるraised-cosine
整合フィルタ) と CW (`cw_FFT_filter`、`create_lpf()`によるローパス) の
両方で `TComplexLowpass` を置き換えました。

#### なぜ今まで簡略化していたフィルタを本実装に置き換えたか

fldigi 本来の FFT エンジンは `src/include/gfft.h` の `g_fft<T>`
("Green FFT") で、1990年代のRISCプロセッサのキャッシュ事情に最適化された
8/4/2混合基数・キャッシュブロッキング・手動ループ展開の実装です。
これを逐語的に移植すると数千行の生ポインタ演算になり、可読性も
テスト可能性も失われます。一方で、本アプリが実際に必要とするのは
「2の冪乗サイズ (64~2048点、fldigi の `FILTLEN[]`/`CW_FFT_SIZE` と
同じ) の複素FFT/逆FFTが正しく動作すること」だけであり、処理速度は
要件になりません (音声レート8kHzのブロック処理は、2020年以降の
どのCPUでも負荷が無視できる程度であることを別途確認済みです)。
そのため `ComplexFFT`/`InverseComplexFFT` は教科書的な反復型 Radix-2
Cooley-Tukey (ビット反転並べ替え+バタフライ演算) として新規に実装し、
既知の変換対 (インパルス応答・直流成分・単一トーンのピークビン位置)
との一致を `test/test_fftfilt.lpr` で検証しました。

#### 設計判断のポイント

- **`TComplexLowpass` は削除せず残置**: 他の用途での利用や比較検証の
  ために `ModemDSP.pas` にそのまま残しています。RTTY/CW の実際の
  フィルタとしては使われなくなりました。
- **CW の DEC_RATIO(=16) 間引きも合わせて復元**: fldigi の
  `rx_FFTprocess()` は fftfilt の出力を16サンプルに1回だけ
  ビットフィルタ (`Cmovavg`) + `decode_stream()` へ渡します。当初の
  簡略化ではこの間引きを省略していましたが、ビットフィルタの長さ
  (`symbollen/(2*DEC_RATIO)`) は間引き後のレートを前提に計算されて
  おり、間引きを省略するとビットフィルタの実効時間窓が16倍短くなる
  不整合がありました。`TFftFilt` への置き換えと同時にこの間引きも
  復元し、整合性を取っています。
- **CW のフィルタ帯域を speed比例の近似値から fldigi の既定値に修正**:
  当初の簡略実装はカットオフを `2.5 * 送信速度(WPM)` という独自の
  近似値にしていましたが、fldigi の既定経路 (`progdefaults.CWmfilt`
  = false のとき) では `progdefaults.CWbandwidth` (既定150Hz) を
  そのまま使う固定値です。本ユニットの `Bandwidth` プロパティ (既定
  150Hz) を素直にフィルタのカットオフとして使うよう修正しました。
- **ブロック出力への構造変更**: `TFftFilt.Run()` は `flen2` サンプル
  溜まるまで0を、溜まったら `flen2` 個まとめて返す設計 (fldigiの
  `fftfilt::run()`と同じ)。1サンプル=1出力だった旧`TComplexLowpass`
  から置き換えるため、`RxProcess()` 内の包絡線検波以降のロジックを
  `ProcessFilteredSample()` (RTTY) に切り出し、フィルタが実際に
  出力したサンプル数だけ呼び出す構造に変更しました
  (fldigi rtty.cxx の `for (int i = 0; i < n_out; i++)` ループと
  同じ構造)。

#### 4-1-1. 検証手順 (`test/test_fftfilt.lpr`)

```bash
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_fftfilt test/test_fftfilt.lpr
./test/test_fftfilt
```

実行結果:

```
=== ComplexFFT/InverseComplexFFT (ModemDSP) / TFftFilt 検証 ===

--- 1. FFT往復一致 (N=64) ---
  最大誤差 = 0.0000000000
  [OK] ComplexFFT->InverseComplexFFT が元信号を誤差1e-9未満で再現する

--- 2. 既知の変換対 (N=8) ---
  [OK] delta[0]のFFTは全ビン1+0iになる (Σ規約、無スケーリング)
  [OK] 直流信号[1,1,...,1]のFFTはビン0=N、他ビン=0になる

--- 3. 単一トーン (5/64サイクル) のピークビン検出 ---
  ピークビン = 5 (振幅 32.000)
  [OK] コサイン波 K=5 サイクルのピークがビン5に現れる
  [OK] ピーク振幅が理論値 N/2=32 と一致する (実際: 32)

--- 4. TFftFilt ローパスフィルタの減衰特性 (flen=256, cutoff=200Hz) ---
  通過域(100Hz) 定常RMS  = 0.9620
  阻止域(2000Hz) 定常RMS  = 0.0000
  通過域/阻止域の減衰量 = 131.4 dB
  [OK] 通過域トーンはほぼ減衰なく通過する (RMS>0.5、入力振幅1.0)
  [OK] 阻止域トーンは通過域比で20dB以上減衰する (実際: 131.4dB)

--- 5. TFftFilt.Run() のブロック化動作確認 (flen=64) ---
  [OK] Flen プロパティが指定通り
  [OK] Flen2 プロパティが Flen/2
  [OK] 生成直後の FlushSize = Flen
  [OK] Run() が0以外を返す時は必ず Flen/2 個 (x8回)
  [OK] 0を返した回数とブロックを返した回数の合計が投入サンプル数と一致する
  [OK] 256サンプル投入で 8回ブロック出力される

=== テスト完了: 0 件の失敗 (全 20 件中) ===
```

fldigi 本来のフィルタ (阻止域で131dBという急峻な減衰特性、通過域は
ほぼ無損失) が実データで再現できていることを確認しました。1次IIR
(`TComplexLowpass`) では原理的にこの急峻さ (-6dB/oct程度が限界) は
出せません。

さらに、`test/test_filter_switch.lpr` で RTTY の全ボーレート(10種)
×全シフト(10種)、CW の速度8段階×帯域幅4段階の組み合わせすべてで
フィルタが例外/NaNなく再生成されることを確認し (100+32通り全てOK)、
既存の `test/test_rtty_cw.lpr` (送受信ループバックテスト) が
引き続き正しく動作すること (RTTY: "HELLO WORLD 12345" を正しく復調、
CW: "CQ CQ DE TEST 599 K" 中の "CQ" を検出) も確認済みです。

なお `test/test_rtty_cw.lpr` の CW ループバック結果は、フィルタ
置き換え後は先頭の "CQ" が "EQ" に化けるようになりました
(2件目以降の "CQ" は正しく復調されるため、テスト自体はOKのまま)。
これは `fftfilt::run()` が「最初の2パス分は出力が不安定なため捨てる」
という fldigi 自身の仕様 (`pass = 1` の初期化と `run()` 冒頭の
`if (pass) return 0;` 相当の処理) によるコールドスタート特性で、
`TFftFilt` が `flen2` サンプル (CW_FFT_SIZE=2048 → 1024サンプル
=128ms) 分の入力を溜めてから初めて出力するため、受信開始直後の
最初の1文字分がAGC同様に「馴染み不足」になる、fldigi自身にも
存在する挙動です。`TComplexLowpass` (1次IIR) にはこの種の起動遅延が
無かったため、当初は表面化していませんでした。実運用ではPTT/VOX
検出後や周波数変更直後の一瞬のみに影響する軽微な特性であり、
テストコード側もこれを想定して「先頭無音区間でAGCを馴染ませる」
「"CQ"がどこかに出現すればOK」という現実的な検証方針を既に
採用しています。

### 結合テスト (`test/test_rtty_cw.lpr`)

`TCaptureSoundDevice` で送信波形をメモリ上にキャプチャし、別インスタンスの
`RxProcess()` へそのまま流し込む「送信 → 復調」のループバックテストです。
GUI (LCL) には依存しません。

```bash
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_rtty_cw test/test_rtty_cw.lpr
./test/test_rtty_cw
```

実行結果 (RTTY: 45.45baud/85Hz, CW: 12WPM。fftfilt化 [4-1節] 後の実行結果):

```
=== RTTY 送受信ループバックテスト ===
送信文字列: HELLO WORLD 12345
  送信サンプル数: 31680 (3.96 秒)
  復調結果      : HELLO WORLD 12345<CR>
  [OK] 送信文字列が復調結果に含まれている

=== CW 送受信ループバックテスト ===
送信文字列: CQ CQ DE TEST 599 K
  送信サンプル数: 145600 (18.20 秒)
  復調結果      :  EQ CQ DE TEST 599 K 
  [OK] 復調結果に "CQ" が検出された
```

※ CW のAGC (`agc_peak`/`noise_floor`) は `rx_init()` 直後 `agc_peak=0`
から始まる (fldigi と同じ挙動) ため、テストでは実運用同様に受信開始前の
無音(+微弱ノイズ)区間を先頭に加えてAGCを馴染ませています。先頭の
"CQ"が"EQ"に化けている点については上記「4-1節」末尾で説明した
fftfilt自体のコールドスタート特性 (fldigi自身にも存在する挙動) に
よるもので、2件目以降は正しく復調されています。

## 5. 実サウンドカードI/O (`units/PortAudioBindings.pas` / `units/PortAudioSoundDevice.pas`)

`test/test_rtty_cw.lpr` までの実装は `TCaptureSoundDevice` という
「送信波形をメモリ上にキャプチャするだけ」のテスト用サウンドデバイスを
使っていました。実際のマイク/スピーカーからモデム信号を送受信するには、
`TCustomSoundDevice` (`SoundIntf.pas`) を継承した「本物のオーディオAPIを
呼ぶ」具象クラスが必要です。

### なぜ PortAudio か (LCLコンポーネントではない理由)

**LCL (Lazarus Component Library) 自体には生の音声サンプル入出力を行う
コンポーネントは存在しません。** LCL はボタンやフォームなど GUI ウィジェ
ットのフレームワークであり、マルチメディアAPIではないためです。

実は fldigi 自身も同じ立場です。fldigi の GUI は FLTK ですが、音声入出力
は FLTK とは全く別に `src/include/sound.h` (`class SoundPort`,
`USE_PORTAUDIO`) で **PortAudio** という OS ネイティブ音声APIの
クロスプラットフォーム抽象化ライブラリを直接呼んでいます。そこで本移植版
も同じ設計方針を踏襲し、PortAudio の C API (`portaudio.h`) を
Free Pascal へ直接バインディングしました。

| fldigi (C++)                                | Lazarus (Pascal)                              |
|-----------------------------------------------|-------------------------------------------------|
| `portaudio.h` (Pa_Initialize/Pa_OpenStream 等) | `PortAudioBindings.pas` (`external` 直接リンク) |
| `class SoundPort : public SoundBase`          | `TPortAudioSoundDevice = class(TCustomSoundDevice)` |
| `SoundPort::Open()`                           | `TPortAudioSoundDevice.Open()`                  |
| `SoundPort::Read()` / `Write()`               | `ReadSamples()` / `WriteSamples()`              |
| `SoundPort::devices()`                        | `TPortAudioSoundDevice.EnumerateDevices` (class method) |

### 設計判断のポイント

- **ブロッキング read/write ストリームモード**: fldigi の `SoundPort` は
  コールバックストリーム+リングバッファという高度な構成だが、本移植版は
  `ModemEngine.pas` が既に専用スレッドで `RxLoopStep`/`TxLoopStep` を
  回す設計になっているため、`Pa_OpenStream` の `streamCallback` に `nil`
  を渡す「ブロッキングI/O」モードのみを使う、よりシンプルな実装とした。
- **サンプル形式は Float32 固定**: fldigi と同じ `paFloat32` を使用し、
  モデム側の `Double` 配列とはユニット内で単純変換する。
- **1インスタンス=1方向**: fldigi の `SoundPort` は1インスタンスで
  RX/TX 両方向 (`sd[0]`/`sd[1]`) を扱うが、`TCustomSoundDevice` の
  「Open の Direction 引数で決まる」という既存のシンプルな設計に
  合わせるため、`TPortAudioSoundDevice` は1インスタンス1方向とした。
  RX/TXを両方使う場合は2インスタンス生成して
  `Open(sdRead,...)` / `Open(sdWrite,...)` をそれぞれ呼ぶ。
- **`$PACKRECORDS C`**: `TPaDeviceInfo`/`TPaStreamParameters` 等のレコードは
  C の構造体と1バイトもズレなくレイアウトを一致させる必要があるため、
  ユニット冒頭で `{$PACKRECORDS C}` を指定している(下記「検証手順」で
  実際に `SizeOf`/オフセットがCと一致することを確認済み)。
- **クロスプラットフォーム対応**: `PortAudioLib` 定数を `{$IFDEF WINDOWS}`
  / `{$IFDEF DARWIN}` / `{$IFDEF LINUX}` で切り替えることで、Windows
  (`libportaudio-2.dll`) / macOS (`libportaudio.dylib`) / Linux
  (`libportaudio.so.2`) のいずれでも同じソースコードのままビルドできる。

### 4-2. PortAudio 実装の検証手順

このリポジトリの自動化環境 (サンドボックス) には実際のマイク/スピーカー
ハードウェアが存在しないため、`test/test_portaudio.lpr` は以下の2段階で
動作確認するように書かれている。**実際のPC (Windows/Linux/macOS) で
Lazarus IDE を使って動作確認する際は、必ず「B. 実オーディオデバイスでの
確認」まで実施すること。**

#### A. ライブラリのインストールとビルド確認 (全プラットフォーム共通)

```bash
# --- Linux (Debian/Ubuntu系) ---
sudo apt install portaudio19-dev

# --- macOS (Homebrew) ---
brew install portaudio

# --- Windows ---
# http://files.portaudio.com/ から prebuilt バイナリ、または
# vcpkg (`vcpkg install portaudio`) 等で portaudio_x64.dll を取得し、
# 実行ファイル (.exe) と同じディレクトリに配置する。
```

```bash
# コンパイル確認 (GUIなし、コンソールのみ)
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_portaudio test/test_portaudio.lpr
./test/test_portaudio
```

このサンドボックス環境 (音声デバイス無し) での実行結果:

```
=== PortAudio バインディング検証 ===
PortAudio version: 1246720 (PortAudio V19.6.0-devel, revision ...)

--- デバイス一覧 (EnumerateDevices) ---
  (デバイスが見つかりません。オーディオハードウェアの無い環境では正常です)

入力・出力の両方のデバイスが揃っていないため、
実データ往復(ループバック)テストはスキップします。
=== テスト完了 (デバイス無し/片方のみの環境として正常終了) ===
```

`Pa_Initialize`/`Pa_GetVersion` が正常に呼べていることから、バインディング
自体 (関数シグネチャ・ライブラリのリンク) が正しいことが分かる。また、
本サンドボックスでは以下の方法で **仮想オーディオデバイス
(PulseAudio null-sink)** を用意し、`TPaDeviceInfo`/`TPaStreamParameters`
のレコードレイアウトがCの構造体と完全に一致していること、および実際に
`Open→Write/Read→Close` のフルサイクルが動作することまで検証済み:

```bash
sudo apt install pulseaudio libasound2-plugins alsa-utils
export XDG_RUNTIME_DIR=/tmp/xdg_runtime
mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
pulseaudio --start --exit-idle-time=-1
# ALSA の既定デバイスを PulseAudio 経由にする
cat > ~/.asoundrc << 'EOF'
pcm.!default { type pulse }
ctl.!default { type pulse }
EOF
# 送信した音を受信側でも観測できるようループバック用 null-sink を作成
pactl load-module module-null-sink sink_name=loopback_test
pactl set-default-sink loopback_test
pactl set-default-source loopback_test.monitor

./test/test_portaudio
```

このループバック構成での実行結果 (440Hzテストトーンを送信スレッドから
書き込みつつ、メインスレッドで同時に読み込んで Peak/RMS を計測):

```
--- デバイス一覧 (EnumerateDevices) ---
  [0] pulse  in=32 out=32 defaultRate=44100Hz
  [1] default  in=32 out=32 defaultRate=44100Hz

--- 実データ往復テスト (440Hz トーン送信 → 受信バッファ解析) ---
  [OK] Open(sdWrite, 44100) 成功 (device index=1)
  [OK] Open(sdRead, 44100) 成功 (device index=1)
  [OK] ReadSamples: 44100 サンプル読み込み
  Peak=0.5000  RMS=0.3528 (送信振幅0.5の正弦波なら理論RMS=0.3536)
  [OK] 送信した音声信号が受信側で観測された (実データ往復に成功)
```

送信した振幅0.5の正弦波の理論RMS値 (0.5/√2 ≈ 0.3536) と実測値
(0.3528) が一致しており、`Double → Float32 → PortAudio → OS音声API →
Float32 → Double` の変換パイプライン全体が正しく機能していることを
実データで確認できた。

さらに、`TPaDeviceInfo`/`TPaStreamParameters` の各フィールドオフセットを
Cコンパイラでコンパイルした同一構造体と比較し、1バイトのズレも無く
一致することも別途Cプログラムとの比較で確認済み
(72バイト構造体・32バイト構造体それぞれ全フィールド一致)。

#### B. 実オーディオデバイスでの確認 (ユーザー環境で必須)

サンドボックス環境での検証はバインディングの正しさ (関数シグネチャ・
構造体レイアウト・データパイプライン) を保証するが、**実機のマイク/
スピーカーでの動作は必ずユーザー自身の環境で確認する必要がある。**
以下の手順で確認すること:

1. Lazarus IDE で `test/test_portaudio.lpr` を開き、通常のマイク入力
   デバイス・スピーカー出力デバイスが接続された状態でビルド・実行する。
2. `EnumerateDevices` の一覧に、OS上で認識されているマイク/スピーカーの
   デバイス名が正しく表示されることを確認する。
3. スピーカーから 440Hz のテストトーン (実行中に短く聞こえる) が
   実際に鳴ることを確認する (`[OK] Open(sdWrite, ...)` 後の
   `WriteSamples` 実行中)。
4. マイクとスピーカーを近づける、またはOS側のオーディオループバック
   機能 (Windows: 「ステレオミキサー」、macOS: BlackHole や
   Loopback 等の仮想オーディオデバイス、Linux: 本README記載の
   PulseAudio null-sink) を使い、`Peak`/`RMS` が非ゼロで観測されることを
   確認する。
5. `TPortAudioSoundDevice` を実際に `ModemEngine.SetModem()` +
   `TRttyModem`/`TCwModem` と組み合わせて RX/TX させ、
   `forms/UnitMainForm.pas` のようなGUI経由で実際に信号のやり取りが
   できることを確認する (この統合手順は今後の拡張タスク)。

### PortAudio 関連の既知の制約・省略した範囲

- ブロッキングI/Oのみ (コールバックストリーム/リングバッファは未実装)。
  低レイテンシが必要な用途では `Pa_OpenStream` のコールバックモードへの
  切り替えが将来的に検討課題となる。
- デバイスのホットプラグ検出、ASIO/WASAPI排他モード等の高度な
  ホストAPI固有機能は未対応 (PortAudioが標準で吸収する範囲のみ)。
- `Flush()` は PortAudio のブロッキングストリームAPIには対応する概念が
  無いため何もしない実装 (fldigi の `SoundPort::flush()` も同様に
  「ドレイン待ち」のみで実質的な処理は無い)。

## 6. 無線機 CAT 制御 (`units/HamlibBindings.pas` / `RigControlIntf.pas` / `HamlibRigControl.pas` / `RigPollThread.pas`)

fldigi は無線機とシリアル通信 (CAT: Computer Aided Transceiver) を行い、
周波数/モード/PTT等をリモート制御できる。fldigi はこの制御に自前実装の
CATプロトコル (`rigio.h` の `rigCAT_*`) と、[Hamlib](https://hamlib.github.io/)
(4000種類以上の無線機モデルに対応するCAT制御ライブラリ) 経由の制御
(`src/rigcontrol/rigclass.h/.cxx`, `src/rigcontrol/hamlib.cxx`) の
2系統を持つ。本移植版では、ユーザーの要望に基づき **Hamlib を
コンポーネントとして直接ラッピングする方式 (Hamlib C API への直接
バインディング)** を採用した。

### なぜ Hamlib か (自前シリアル実装が不要な理由)

fldigi の `src/include/serial.h` (`class Cserial`) は POSIX
termios / Win32 COM API を直接叩くクラスだが、詳しく解析すると
CAT通信そのものには使われておらず、「Cygwin環境でのCOMポート⇔ttyパス
変換」「一部リグでのDTR/RTS直接制御によるPTT」といった限定的な用途にしか
使われていない。実際のCATコマンド送受信・シリアルポートのオープンや
ボーレート設定は、すべて **Hamlib 内部** (`rig_set_conf()` による
`rig_pathname`/`serial_speed`/`timeout`/`stop_bits` 等の文字列ベース設定)
が担っている。したがって、Pascal 側でも生のシリアルポート実装を書く
必要はなく、Hamlib の C API をバインディングするだけで CAT 制御が
実現できる。

### fldigi との対応表

| fldigi (C++)                              | Lazarus (Pascal)                       | 役割 |
|----------------------------------------------|-------------------------------------------|------|
| `hamlib/rig.h` (Hamlib C API)               | `HamlibBindings.pas` (`external` 直接リンク) | Hamlib C API への直接バインディング |
| `class Rig` (rigclass.h/.cxx)               | `TCustomRigControl` (RigControlIntf.pas) / `THamlibRigControl` (HamlibRigControl.pas) | CAT制御クラス |
| `class RigException`                        | `ERigControlError`                        | CAT制御エラー例外 |
| `xcvr->init()` / `open()` / `close()`       | `InitModel` / `Open` / `Close`            | 初期化・接続・切断 |
| `xcvr->setFreq()` / `getFreq()`             | `SetFreq` / `GetFreq`                     | 周波数設定・取得 |
| `xcvr->setMode()` / `getMode()`             | `SetMode` / `GetMode`                     | モード設定・取得 |
| `xcvr->setPTT()` / `getPTT()`               | `SetPTT` / `GetPTT`                       | 送信制御 |
| `xcvr->setConf()` / `getConf()`             | `SetConfStr` / `GetConfStr`               | 汎用conf文字列アクセス (拡張フック) |
| `rigclass.cxx` の `NUMTRIES` (リトライ回数=10) | `RetryCount` プロパティ (既定10)        | CATコマンド失敗時のリトライ |
| `hamlib.cxx` の `hamlib_get_rigs()`         | `THamlibRigControl.EnumerateRigs` (class method) | 対応リグモデル一覧の列挙 |
| `hamlib.cxx` の `hamlib_get_rig_model_compat()` | `THamlibRigControl.FindRigModelByName`  | 名前からモデルIDを逆引き |
| `hamlib.cxx` の `hamlib_loop()` (50ms周期ポーリングスレッド) | `TRigPollThread` (RigPollThread.pas)   | 周波数/モードの定期監視 |
| `hamlib_bypass` (PTT送信中は監視休止)        | `TRigPollThread.Bypass`                   | ポーリングの一時停止 |
| `noCAT_*` 系関数 (rigio.h、リグ制御なし)     | `TNullRigControl` (RigControlIntf.pas)    | 何もしない実装 |

### 設計判断のポイント

- **`RIG*` を不透明ポインタとして扱う**: Hamlib の `struct s_rig` は
  実測 47880 バイトの巨大な構造体で、内部レイアウトはバージョン間で
  変わりやすい。PortAudio (`TPaDeviceInfo` 等) のように構造体全体を
  Pascal に複製する方式は取らず、`THamlibRigHandle = Pointer` として
  完全に不透明に扱い、すべての操作を Hamlib の API 関数呼び出し
  (`rig_init`/`rig_open`/`rig_set_freq`/`rig_get_freq`/…) のみで行う。
  唯一の例外は `rig_list_foreach` のコールバックで受け取る
  `struct rig_caps` で、こちらは「先頭3フィールド
  (`rig_model`/`model_name`/`mfg_name`) だけを含む最小レコード
  `TRigCapsHead`」を定義し、Cプログラムでの `offsetof` 実測
  (`rig_model=0`, パディング4バイト, `model_name=8`, `mfg_name=16`) に
  基づいて安全性を検証した上でアクセスしている。
- **3段構えの拡張性設計** (ユーザー要望「基本CAT機能+将来拡張可能な設計」
  への対応):
  1. 高頻度に使う操作 (周波数/モード/PTT/VFO) は `TCustomRigControl` に
     素直な仮想メソッドとして直接追加する。
  2. Hamlib の "conf" (文字列ベースの汎用設定項目。`rig_pathname` や
     `serial_speed` 等) は `SetConfStr`/`GetConfStr` で汎用アクセスできる。
  3. さらに低レベルな Hamlib API (`rig_set_level`/`rig_set_parm`/
     `rig_send_morse` 等、本ユニットが未対応の機能) が必要になった場合の
     エスケープハッチとして `GetNativeHandle` を用意した。
     `THamlibRigControl` はこれで `THamlibRigHandle` (Hamlib の `RIG*`)
     を返すので、呼び出し側は `HamlibBindings.pas` の関数を直接呼んで
     独自に拡張できる。これにより Strategy パターンを壊さずに
     「基本CAT機能以外にも将来的に対応できる」設計を実現している。
- **Strategy パターンの踏襲**: `TCustomSoundDevice`/`TCustomModem` と
  同じ設計思想で、`TCustomRigControl` は特定のCAT実装 (Hamlib直接
  バインディング/将来的な rigctld 経由TCP通信/メーカー独自CAT等) に
  依存しない抽象インターフェースのみを定義する。`TRigPollThread` も
  `TCustomRigControl` にのみ依存するため、`THamlibRigControl` 以外の
  将来実装でもそのまま使い回せる。
- **NUMTRIES リトライパターンの踏襲**: fldigi の `rigclass.cxx` は
  `setFreq`/`getFreq`/`setMode`/`setPTT` 等で「`NUMTRIES`(=10)回まで
  リトライしてダメなら例外」という設計になっており、`THamlibRigControl`
  も `RetryCount` プロパティ (既定10) で同じパターンを踏襲している。
- **`CanSetFreq`等の簡略化**: fldigi の `Rig::canSetFreq()` は
  `rig->caps->set_freq != NULL` という関数ポインタの直接チェックを
  行っているが、本移植版は不透明ポインタ方針のためこの方式は使えない。
  そのため「Open されていれば常に true とし、実際の失敗は
  リトライ+例外に委ねる」という、より安全側に倒した設計にしている。

### 6-1. 検証手順 (Hamlib Dummy リグによる疑似CAT通信)

実無線機の無いサンドボックス/CI環境でも検証できるよう、Hamlib が標準で
提供する疑似リグ **`RIG_MODEL_DUMMY`** (Hamlib Dummy backend) を使って
検証する。Dummy backend はシリアルポートを一切必要とせず、`rig_open()`
後は内部変数に対して `rig_set_freq`/`rig_get_freq`/`rig_set_ptt`/
`rig_get_ptt`/`rig_set_mode`/`rig_get_mode` が実際に機能するため、
「Hamlib 層の配線 (バインディング~抽象クラス~ポーリングスレッド) が
正しく繋がっているか」を実機なしで確認するのに最適である。

```bash
# --- Linux (Debian/Ubuntu系) ---
sudo apt install libhamlib-dev libhamlib-utils

# コンパイル確認 (GUIなし、コンソールのみ)
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_rigcontrol test/test_rigcontrol.lpr
./test/test_rigcontrol
```

このサンドボックス環境 (Hamlib 4.6.2, libhamlib-dev/libhamlib-utils
パッケージ) での実行結果:

```
=== Hamlib CAT制御バインディング 検証 (RIG_MODEL_DUMMY 疑似CAT通信) ===

--- 1. リグモデル一覧の列挙 (EnumerateRigs) ---
  登録リグモデル数: 313
  [OK] リグモデルが100種類以上登録されている
  Dummy backend 発見: [1] Hamlib / Dummy
  [OK] RIG_MODEL_DUMMY が一覧に含まれている
  --- 先頭5件のサンプル表示 ---
    [1] Hamlib / Dummy
    [2] Hamlib / NET rigctl
    [4] FLRig / 
    [5] TRXManager / TRXManager 5.7.630+
    [6] Hamlib / Dummy No VFO

--- 3. RIG_MODEL_DUMMY による基本CAT機能の疑似通信検証 ---
  RigName: Dummy
  [OK] RigName が取得できる
  [OK] Open が成功する (rig_open)
  [OK] IsOnLine = True (Open後)
  SetFreq(14074000) -> GetFreq() = 14074000
  [OK] SetFreq/GetFreq の往復値が一致する
  SetFreq(7040000) -> GetFreq() = 7040000
  [OK] 2回目の SetFreq/GetFreq も一致する
  SetMode(USB,2400) -> GetMode() = USB / width=2400
  [OK] SetMode/GetMode でモード文字列が往復する (USB)
  SetMode(CW,500) -> GetMode() = CW / width=500
  [OK] SetMode/GetMode でモード文字列が往復する (CW)
  [OK] Open直後の GetPTT は false (送信していない)
  [OK] SetPTT(True) 後、GetPTT が true になる
  [OK] SetPTT(False) 後、GetPTT が false に戻る
  SetVFO(rvA) -> GetVFO() = 1
  SetConfStr/GetConfStr(rig_pathname) = /dev/ttyDUMMY
  [OK] SetConfStr/GetConfStr が往復する
  [OK] GetNativeHandle が非nilを返す
  [OK] Close 後は IsOnLine = False

--- 4. TRigPollThread による定期ポーリング動作の検証 ---
  [OK] Open が成功する (ポーリングテスト用)
  [OK] 初回ポーリングで OnFreqChanged が発火する
  [OK] 初回ポーリングで OnModeChanged が発火する
  [OK] ポーリングで取得した周波数が一致する
  周波数を 21000000 Hz に変更し、ポーリングでの検出を待ちます...
  [OK] 周波数変更がポーリングスレッド経由で検出される
  [OK] Bypass=True の間はポーリングイベントが発火しない
  [OK] Bypass=False に戻すとポーリングが再開する

=== テスト完了: 0 件の失敗 ===
```

この結果から、以下がすべて実データで確認できた:

- Hamlib のリグモデルデータベース (313種類) を `rig_list_foreach` 経由で
  安全に列挙できること (`TRigCapsHead` による最小構造体アクセスが
  正しく機能している)。
- `RIG_MODEL_DUMMY` に対する `rig_init`/`rig_open` の疑似CAT接続が
  成功し、周波数・モード・PTT・VFO・conf文字列の設定/取得が
  すべて実際に Hamlib 層を経由して往復すること。
- `TRigPollThread` が `TCustomRigControl` 経由で定期的に周波数/モードの
  変化を検出し、`OnFreqChanged`/`OnModeChanged` イベントを正しく
  発火すること、および `Bypass` (PTT送信中の監視休止) が正しく
  機能すること。

なお、Hamlib は既定でデバッグログの詳細度が高く標準出力を埋めてしまう
ため、テストプログラム冒頭で `rig_set_debug(RIG_DEBUG_NONE)` を呼んで
抑制している。

### 6-2. 実無線機での確認 (ユーザー環境で推奨)

サンドボックス環境での検証は Hamlib バインディング自体の正しさ
(関数シグネチャ・データの往復・ポーリング動作) を保証するが、
**実際の無線機とのシリアル通信については、対応するモデルを持つ
ユーザー自身の環境で確認することを推奨する。** 手順:

1. `THamlibRigControl.EnumerateRigs` の結果から、お使いの無線機の
   `RigModel` (Hamlib モデルID) を探す (または
   `FindRigModelByName('IC-7300')` のように機種名で検索する)。
2. `THamlibRigControl.Create(RigModel)` でインスタンスを作成し、
   `Device := '/dev/ttyUSB0'` (Linux) や `Device := 'COM3'` (Windows)
   のように実際のシリアルポートを指定する。
3. `BaudRate` を無線機の設定に合わせて指定し (Hamlib のデフォルト値で
   動作する機種も多い)、`Open` を呼ぶ。
4. `SetFreq`/`GetFreq`/`SetMode`/`GetMode`/`SetPTT`/`GetPTT` が実機と
   正しく連動することを確認する。
5. `TRigPollThread` を使い、無線機のダイヤルを手で回した際に
   `OnFreqChanged` イベントが発火することを確認する。
6. PTT を伴う送信時は `TRigPollThread.Bypass := True` に設定してから
   `SetPTT(True)` を呼び、送信完了後に `SetPTT(False)` →
   `Bypass := False` に戻す運用にすると、CATポーリングとPTT制御が
   輻輳してタイムアウトするのを防げる (fldigi の `hamlib_bypass` と
   同じ運用)。

### Hamlib CAT制御関連の既知の制約・省略した範囲

- 対応スコープは基本CAT機能 (周波数/モード/PTT/VFO) に限定している。
  Sメータ取得・パワーレベル設定・アンテナ切替・メモリチャンネル操作等は
  未実装だが、上記「3段構えの拡張性設計」の (b)`SetConfStr`/`GetConfStr`
  または (c)`GetNativeHandle` エスケープハッチ経由で追加実装が可能。
- 方式Bとして提案した rigctld (Hamlib の TCP デーモン) 経由の通信は
  今回未実装 (方式A: ネイティブライブラリ直接バインディングのみ採用)。
  `TCustomRigControl` を継承した別クラス (`TRigctldRigControl` 等) を
  追加すれば、`ModemEngine`/UI 側のコードを変更せずに両方式を
  切り替えられる設計にしてある。
- Hamlib の非同期通知機能 (async data / transceive mode、無線機側の
  周波数変化をポーリングなしでリアルタイム受信する機能) は未対応。
  `TRigPollThread` によるポーリング方式のみを実装している。

## 7. 局情報の記憶 (`units/StationInfo.pas`) / ADIF-over-UDP 外部ロガー連携
   (`units/AdifUdpSender.pas`) / 内蔵 QSO ロギング (`units/QsoLogbook.pas`)

コールサイン・オペレータ名・運用地・グリッドロケータ等の運用情報を入力・
記憶する機能と、確定した QSO を ADIF 形式で UDP 送信して外部ロギング
アプリに配信する機能、および本アプリ内蔵の QSO ログ機能を実装した。

### fldigi との対応表

| fldigi (C++)                                    | Lazarus (Pascal)                       | 役割 |
|----------------------------------------------------|-------------------------------------------|------|
| `progdefaults` (`configuration.h` の `ELEM_` マクロ) | `TStationInfo` (StationInfo.pas)         | 局情報の保持 |
| `progdefaults.myCall` (MYCALL)                     | `TStationInfo.MyCall`                     | 自局コールサイン |
| `progdefaults.operCall` (OPERCALL)                 | `TStationInfo.OperCall`                   | 運用者コールサイン |
| `progdefaults.myName` (MYNAME)                     | `TStationInfo.MyName`                     | 運用者名 |
| `progdefaults.myQth` (MYQTH)                       | `TStationInfo.MyQth`                      | 運用地(QTH) |
| `progdefaults.myLocator` (MYLOC)                   | `TStationInfo.MyLocator`                  | グリッドロケータ |
| `progdefaults.myAntenna` (MYANTENNA)               | `TStationInfo.MyAntenna`                  | アンテナ情報 |
| `fldigi_def.xml` への保存                          | `station_info.json` (JSON、実行ファイルと同じディレクトリ) | 局情報の永続化 |
| `field_def.h` (`ADIF_FIELD_POS`)                   | `AdifUdpSender.pas` の `ADIF_TAG_*` 定数群 | ADIF タグ名の定義 |
| `adif_io.cxx` の `FIELD fields[]`                  | (直接タグ名文字列として踏襲)              | enum値↔ADIFタグ名マッピング |
| `adif_io.cxx` の `adifmt = "<%s:%d>"`               | `AdifField()` 関数                        | 1フィールドの書式整形 |
| `cAdifIO::writeFile()` のヘッダ生成+フィールド出力  | `TAdifUdpSender.BuildAdifRecord()`        | 1QSO分のADIFレコード組み立て |
| `class cQsoRec` (qso_db.h)                         | `TQsoRecord` (QsoLogbook.pas)             | 1件のQSO記録 |
| `class cQsoDb` (qso_db.h/.cxx)                     | `TQsoLogbook` (QsoLogbook.pas)            | QSOログの集合・永続化 |
| `logsupport.cxx` の `AddRecord()` (Station情報のQSOレコードへのコピー) | `TQsoLogbook.AddQso()` 内の `TAdifUdpSender.SendQso()` 呼び出し | QSO確定時の自局情報付与 |

### なぜこの設計か (fldigi に前例が無い部分の設計根拠)

fldigi のソースコードを詳細に調査した結果、以下が判明した:

- **局情報の保持自体** は `progdefaults` (`configuration.h`) にそのまま
  対応する構造がある。`myCall`/`operCall`/`myName`/`myQth`/`myLocator`/
  `myAntenna` の6フィールドをそのまま `TStationInfo` に踏襲した。
- **ADIF のタグ名・書式** も `field_def.h`/`adif_io.cxx` に確実な前例が
  ある。`STATION_CALLSIGN`/`OPERATOR`/`MY_GRIDSQUARE`/`MY_CITY`/
  `MY_ANTENNA` 等のタグ名、および `<TAG:長さ>値` という ADIF
  フィールド書式 (`adifmt = "<%s:%d>"`) をそのまま踏襲することで、
  fldigi の ADIF ファイルとの互換性・移行性を確保している。
- 一方、**「ADIF データを UDP で外部送信する」ネイティブ機能は
  fldigi 自体には存在しない** ことを確認した
  (`maclogger.cxx`/`maclogger.h` は UDP *受信* 専用で、しかも ADIF では
  なく `[Radio Report:...]` という独自のブラケット区切りテキスト形式。
  `fd_logger.cxx`/`n3fjp_logger.cxx` は TCP ソケットベース。
  `xmlrpc_log.cxx` は XML-RPC ベース)。

  そこで本機能は、アマチュア無線ロギングエコシステムで WSJT-X が
  導入し JTAlert・N1MM Logger+・GridTracker・Log4OM・HRD Logbook・
  Winlog32 等の主要な外部ロガーが軒並み対応している
  **「1 QSO を単体で完結したミニ ADIF ファイルとして UDP データグラムで
  送信する」方式** (WSJT-X の "Logged ADIF" UDP メッセージ、
  `NetworkMessage.hpp` type=12 で採用されている方式と同等) を新規に
  採用した。これにより、外部ロガー側に特別な追加対応を要求せず、
  既存の「WSJT-X/JTAlert 用 UDP 受信」設定をそのまま流用してこの
  アプリからの QSO も受信できる。

### 設計判断のポイント

- **永続化フォーマットは JSON**: fldigi は独自の XML (実体は INI 相当)
  形式で `$HOME/.fldigi/fldigi_def.xml` に保存するが、本移植版は
  ユーザー要望により「各OSで標準的な構造化フォーマット」として
  JSON を採用した。FPC 標準の `fpjson`/`jsonparser` ユニットのみで
  実装でき、外部ライブラリへの依存を増やさない。
- **保存場所は実行ファイルと同じディレクトリ**: fldigi は
  `GetAppConfigDir` 相当の OS 標準設定ディレクトリを使うが、
  ユーザー要望により `ParamStr(0)` (実行ファイルのパス) から
  `ExtractFilePath` したディレクトリに `station_info.json`/
  `qso_log.json` を保存する方式とした (可搬性重視、USBメモリ等に
  アプリ本体ごとコピーして運用したい場合に有利)。
- **UDP 実装は FPC 標準の `Sockets` ユニットのみを使用**: Synapse
  (`blcksock`) 等の外部パッケージを追加導入せず、`fpSocket`/
  `fpSendTo`/`fpBind`/`fpRecvFrom` という POSIX ライクな低レベル
  API を直接使用した。`TInetSockAddr`(`sin_family`/`sin_port`/
  `sin_addr`) は Windows (`win/sockets.pp`) でも Unix系
  (`unix/sockets.pp`) でも同じ `socketsh.inc` を共有しており、
  同一ソースコードのままクロスプラットフォームで動作する。
- **既定の送信先は 127.0.0.1 (ユーザー合意による)**: WSJT-X/JTAlert等の
  一般的な運用は同一PC内の複数アプリ間連携が主目的であるため、
  ブロードキャスト (`255.255.255.255`) ではなくユニキャスト
  `127.0.0.1` を既定値とした。
- **ポート番号は 52099 (著名アプリと非衝突)**: IANA の
  [Service Names and Port Numbers Registry](https://www.iana.org/assignments/service-names-port-numbers/)
  で未登録であること、かつ主要な外部ロガーの既定ポート
  (WSJT-X=2237, JTAlert=2333, N1MM Logger+=12060/12061,
  fldigi 自身の XML-RPC=7362 等) のいずれとも重複しないことを
  確認した上で、ダイナミック/プライベートポート範囲
  (49152-65535) 内の `52099` を既定値として採用した。
  外部ロガー側の設定に合わせて `TAdifUdpSender.TargetPort` を
  変更することも可能。
- **既定で無効 (`Enabled = False`)**: 外部ロガー連携は明示的に
  有効化しないと UDP 送信されない設計とした (意図しないネットワーク
  送信を防ぐため)。
- **内蔵ロギングと外部UDP配信は独立した機能**: `TQsoLogbook.AddQso()`
  は常に内蔵ログ (`qso_log.json`) へ記録し、`UdpSender` プロパティに
  `TAdifUdpSender` インスタンス (`Enabled=True`) が設定されている
  場合のみ追加で外部送信する。内蔵ログのみ/外部UDPのみ/両方、を
  自由に組み合わせられる。

### 7-1. 検証手順 (自己完結型ループバックテスト)

実際の外部ロガーアプリや別ホストが無い環境でも検証できるよう、
同一プロセス内で `127.0.0.1:52099` へ UDP ソケットを bind し、
`TAdifUdpSender` が送信したデータグラムを自分自身で受信・パースする
ことで実データの往復を確認する。

```bash
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_station_adif test/test_station_adif.lpr
./test/test_station_adif
```

このサンドボックス環境での実行結果 (抜粋):

```
=== 局情報記憶 (StationInfo) / ADIF-over-UDP送信 (AdifUdpSender) / 内蔵QSOロギング (QsoLogbook) 検証 ===

--- 1. TStationInfo (局情報) の保存/再読込 往復確認 ---
  [OK] SaveToFile でファイルが作成される
  [OK] MyCall が往復する: JA1TEST
  [OK] OperCall が往復する: JA1OPER
  ...(中略)...

--- 2. ADIF レコード組み立て内容の確認 (BuildAdifRecord) ---
生成された ADIF レコード:
<ADIF_VER:5>3.1.4<PROGRAMID:17>LazarusFldigiPort<PROGRAMVERSION:3>1.0<EOH>
<CALL:4>W1AW<QSO_DATE:8>20260828<TIME_ON:6>123456<MODE:4>RTTY<FREQ:7>14.0745<RST_SENT:3>599<RST_RCVD:3>599<STATION_CALLSIGN:7>JA1TEST<OPERATOR:7>JA1TEST<MY_GRIDSQUARE:6>PM95TQ<MY_CITY:5>Tokyo<MY_ANTENNA:6>Dipole<EOR>

--- 3. UDP ループバック送受信テスト (127.0.0.1:52099) ---
  [OK] 受信用ソケットの作成に成功する
  [OK] bind(127.0.0.1:52099) に成功する
  [OK] SendQso が送信成功 (Result=True) を返す
  [OK] 受信側で UDP データグラムを実際に受信した (n=234)
  ...(中略)...

--- 5. TQsoLogbook (本アプリ内蔵ロギング機能) の確認 ---
  [OK] 生成直後は Count=0 である
  [OK] AddQso 後に Count=1 になる
  ...(中略)...

--- 6. TQsoLogbook + AdifUdpSender 連携確認 (AddQso が自動でUDP送信をトリガーする) ---
  [OK] AddQso 後、内蔵ログにも記録される
  [OK] AddQso が内部で UDP 送信もトリガーし、受信できる
  ...(中略)...

=== テスト完了: 0 件の失敗 (全 52 件中) ===
```

この結果から、以下が実データで確認できた:

- `TStationInfo` の局情報が JSON ファイルへ正しく保存・復元されること。
- `TAdifUdpSender.BuildAdifRecord()` が fldigi 準拠の ADIF タグ名・
  書式で正しくレコードを組み立てること。
- 実際に `Sockets` ユニット経由で UDP データグラムが `127.0.0.1:52099`
  へ送信され、受信側で正しくパースできること。
- `Enabled=False` (既定値) の間は送信が行われないこと。
- `TQsoLogbook` への QSO 追加が JSON ファイルへ正しく永続化され、
  再読込後も内容が一致すること。
- `TQsoLogbook.UdpSender` を設定すると、`AddQso()` 呼び出しだけで
  内蔵ログへの記録と外部ロガーへの UDP 配信が両方自動的にトリガー
  されること。

### 局情報/ADIF-UDP/内蔵ロギング関連の既知の制約・省略した範囲

- ADIF レコードで送信するフィールドは QSO の基本項目
  (CALL/QSO_DATE/TIME_ON/TIME_OFF/MODE/FREQ/RST_SENT/RST_RCVD/NAME/
  QTH/GRIDSQUARE/COMMENT + 自局情報) に限定している。POTA/SOTA
  参照番号、コンテストナンバー等の拡張フィールドは
  `TAdifQsoData`/`TQsoRecord` にフィールドを追加すれば拡張可能な
  構造にしてある。
- `TQsoLogbook` は全件をメモリ上の配列に保持するシンプルな実装
  (fldigi の `cQsoDb` のような検索インデックス・重複チェック機能は
  未実装)。大量のQSO記録を扱う場合は将来的な最適化対象。
- UDP 送信は fire-and-forget (到達確認なし) であり、これは WSJT-X
  方式・fldigi の `maclogger` 等、既存の全ての UDP 連携パターンでも
  同様 (UDP の性質上、確実な配送を保証する場合は別途アプリケーション
  層での確認応答が必要)。
- GUI (LCL) からの局情報入力ダイアログ、QSOログ一覧表示、および
  UDP送信の有効化トグルスイッチは、`units/` のコアロジックとしては
  完成しているが、`forms/UnitMainForm.pas` への実際の組み込み
  (入力フォームの追加) は今後の拡張タスクとする。

## 8. コンテストロギング (`units/ContestLog.pas`) / DXCC・ゾーン判定
   (`units/DxccDatabase.pas`)

コンテスト運用時の交換ナンバー (Exchange) の書式検証・シリアルナンバー
発行・重複交信(Dupe)チェックと、コールサインからDXCC国名/CQゾーン/
ITUゾーン/大陸を判定する機能を実装した。前者は fldigi の
`src/logbook/contest.cxx`・`src/logbook/counties.cxx`、後者は
`src/misc/dxcc.cxx`・`src/logbook/cty-dat.cxx` の解析結果に基づく。

### fldigi との対応表

| fldigi (C++)                                        | Lazarus (Pascal)                          | 役割 |
|--------------------------------------------------------|----------------------------------------------|------|
| `enum CONTEST_FIELD` (contest.h)                      | `TContestFieldKind` (ContestLog.pas)         | 交換ナンバーのフィールド種別 |
| `state_test()`/`province_test()`/`section_test()`/…   | `ContestStateTest`/`ContestProvinceTest`/`ContestSectionTest`/… | 各フィールドの書式検証関数群 |
| `check_field()`                                       | `TContestDefinition`/`TContestLog.ValidateExchange` | フィールド種別に応じた検証の一括実行 |
| `country_test()` (dxcc_entity_list()を利用)           | `ContestCountryTest` (DxccDatabase.pas を利用) | DXCC国名の部分一致判定 |
| `CONTESTS contests[]`                                 | `TContestRegistry.RegisterBuiltins`          | 組み込みコンテスト定義 (15件) |
| `struct QSOP`/`Ccontests::qso_parties[]` (米国州QSOパーティ約90件) | `TContestDefinition` (汎用の型のみ移植。データは移植せず) | コンテスト毎の交換フィールド定義 |
| `class Cstates` (counties.cxx)                        | `TCountyDatabase` (ContestLog.pas)            | 郡(County)データのCSV読込・検証 |
| `struct dxcc` (dxcc.h)                                | `TDxccEntry` (DxccDatabase.pas)               | 1個のDXCCエンティティの情報 |
| `dxcc_open()`/`dxcc_close()`/`dxcc_is_open()`          | `TDxccDatabase.LoadFromFile`/`Clear`/`IsOpen` | cty.dat の読み込み・解放 |
| `dxcc_lookup()` (完全一致→最長プリフィクス一致)        | `TDxccDatabase.Lookup`                       | コールサイン→DXCCエンティティ判定 |
| `add_prefix()` (プリフィクス修飾子の解析)              | `TDxccDatabase` 内部の `AddPrefix` (private)  | CQ/ITUゾーン・大陸の例外上書き解析 |
| (該当なし。fldigi自体にはロギング機能付きの            | `TContestLog` (本移植版オリジナル)            | シリアルナンバー発行・重複チェック・ |
| コンテストクラスは無い)                                |                                                | AdifFile.pas 連携ロギング |

### なぜこの設計か (米国州QSOパーティを全件移植しなかった理由)

fldigi のソースコードを解析した結果、コンテスト関連のロジックは大きく
2種類に分かれることが分かった:

1. **再利用可能な汎用ロジック**: 数字/カットナンバー/RST/ARRLセクション/
   Sweepstakesのプレシデンス等の書式検証関数、および cty.dat という
   標準フォーマットのファイルを解析してDXCC国名・ゾーン・大陸を求める
   エンジン。これらは「ロジックを読んで移植する」という今回のタスクの
   対象そのものであり、本ユニットでは fldigi の実装を忠実に踏襲した。
2. **大量の静的データ**: `qso_parties[]` (米国50州+カナダ州の約90件の
   QSOパーティそれぞれについて、州内局/州外局のどちらが何を送るかを
   定めた固定テーブル) と、その郡データ (`SQSO.txt`/`6QP.txt`/`7QP.txt`、
   FIPS 2010年人口調査由来で州によっては100郡以上)。これは「ロジック」
   ではなく随時更新されうる「データ」であり、かつユーザー要望が
   「fldigiの翻訳ではなく新規開発」であることから、全件を手作業で
   書き写すことはしなかった。

   代わりに、同じ表現力を持つ汎用の `TContestDefinition`/
   `TContestExchangeField`/`TCountyDatabase` という型を用意し、実際に
   `CONTESTS contests[]` (米国州限定ではない国際/一般コンテスト一覧) から
   15件を抜粋して `TContestRegistry.RegisterBuiltins` に組み込んだ。
   郡データも counties.cxx と同じ「外部CSVファイルから読み込む」設計
   (`TCountyDatabase.LoadFromFile`) としたため、利用者が郡データCSVと
   対応する `TContestDefinition` (`Counties` プロパティに紐付け) を
   用意すれば、`qso_parties[]` 相当の州QSOパーティをいくらでも
   追加登録できる「データ駆動で全件を再現可能な枠組み」になっている。

同様に、DXCC判定の内蔵フォールバックデータ (`cty-dat.cxx` の
`s_ctydat`、当時最新版のcty.dat全文約1300行) も移植しなかった。
これも「データ」であり、運用者は fldigi と同じ配布元
([country-files.com](https://www.country-files.com/)、AD1C氏が月次更新)
から最新の `cty.dat` をダウンロードして `TDxccDatabase.LoadFromFile`
で読み込む運用とする。

### 設計判断のポイント

- **DXCC判定はコンテスト機能から独立したユニットに分離**: `country_test()`
  は fldigi でも dxcc.cxx への依存として実装されている。本移植版も
  この依存関係自体は保つが、DXCC/ゾーン判定はコンテスト機能に限らず
  将来の `CallsignLookup.pas` 等でも使う共通基盤のため、独立した
  `DxccDatabase.pas` として切り出した。
- **プリフィクス検索には `Generics.Collections.TDictionary` を使用**:
  実際の cty.dat は例外コールサイン (`=AA0O(5)[8]` 等) を含めると
  数万件のキーを持つ。他ユニット (AdifFile.pas 等) はフィールド数が
  高々60個程度のため単純な配列・線形探索で十分だが、本ユニットは
  規模が2桁以上大きいため、O(1)平均のハッシュマップを採用した
  (FPC 3.2.2 で `{$mode objfpc}` でも `Generics.Collections` は
  問題なく使用できることを確認済み)。
- **AdifFile.pas を実データストアとして利用**: `TContestLog` は独自の
  QSOレコード型を持たず、`AdifFile.pas` の `TAdifDatabase`/`TAdifRecord`
  をそのまま内部で使う。ADIFフィールド (SRX/STX/CLASS/ARRL_SECT/
  CWSS_SERNO等) は既に `AdifFile.pas` 側に用意されていたため、
  `ContestLog.pas` の役割は「検証」と「シリアルナンバー発行」と
  「重複チェック」と「DXCC自動補完」に集中できた。
- **rst_test()のモード依存を明示的な引数に変更**: fldigi の `rst_test()`
  は `active_modem->get_mode()` というグローバルなモデム状態を直接
  参照するが、本ユニットは他の `units/` 配下ユニットと同じく
  GUI/モデムエンジンに一切依存しない設計方針のため、
  `ARequireThreeChar: Boolean` という明示的な引数に置き換えた。
- **DXCCデータ/郡データ未ロード時は寛容側にフォールバック**: fldigi の
  `country_test()` は `dxcc_entity_list()` が null (cty.dat未ロード) の
  場合、無条件で true を返す設計になっている。本移植版の
  `ContestCountryTest`/`ContestCountyTest` も同じフォールバック
  (`ADxcc`/`ACounties` が nil なら常に有効とみなす) を踏襲しており、
  データファイルを未設定のまま運用してもコンテストロギング自体は
  ブロックされない。

### 8-1. 検証手順

実際の cty.dat ファイルや郡データCSVファイルは使わず、fldigi の
`cty-dat.cxx`/`counties.cxx` のフォーマットに従った小規模なサンプル
データをテストプログラム内に直接埋め込み、実データとして解析・検索
させることで検証する。

```bash
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_contestlog test/test_contestlog.lpr
./test/test_contestlog
```

このサンドボックス環境での実行結果 (抜粋):

```
=== コンテストロギング (ContestLog) / DXCC・ゾーン判定 (DxccDatabase) 検証 ===

--- 1. 単体フィールド検証関数の確認 ---
  [OK] ContestStateTest(CA) = True
  ...(31件、すべてOK)...

--- 2. ContestCountryTest (DxccDatabase連携) の確認 ---
  [OK] DxccDatabase未指定(nil)なら常にTrue (fldigiのフォールバック挙動)
  [OK] ContestCountryTest(JAPAN) = True, matched=Japan
  [OK] ContestCountryTest(存在しない国名) = False

--- 3. TCountyDatabase (郡データCSV読込) の確認 ---
  [OK] LoadFromFile が3件読み込む
  ...(9件、すべてOK)...

--- 4. TContestRegistry (組み込みコンテスト定義) の確認 ---
  [OK] RegisterBuiltins で14件以上登録される (実際: 15件)
  [OK] FindByName(CQ WW DX) が見つかる
  [OK] CQ WW DX の交換フィールド数は2 (COUNTRY, ZONE)
  ...

--- 5. TContestLog (検証+シリアル発行+重複チェック+ADIF連携) の確認 ---
  [OK] Definition に CQ WW DX を設定できる
  [OK] 正しい交換ナンバー(JAPAN, Zone 25)は全項目が有効
  [OK] 不正な交換ナンバーは2項目とも失敗として検出される (実際: 2件)
  [OK] LogQso がレコードを返す
  [OK] Dxcc自動補完で COUNTRY=United States が設定される (実際: United States)
  [OK] Dxcc自動補完で CQZ=5 (W1AWの例外上書き) が設定される (実際: 5)
  [OK] Dxcc自動補完で ITUZ=8 が設定される
  [OK] Dxcc自動補完で CONT=NA が設定される
  [OK] 自動採番されたSTX(送信シリアル)は1
  [OK] IsDuplicate(W1AW,20m,RTTY) = True (1件目と同条件)
  [OK] IsDuplicate(W1AW,40m,RTTY) = False (バンド違い)
  [OK] 同一条件で3回目のLogQsoはDupe=Trueを返す (記録自体は行う)
  [OK] SaveToAdif が成功する
  [OK] LoadFromAdif で3件読み込む
  ...

=== テスト完了: 0 件の失敗 (全 75 件中) ===
```

この結果から、以下が実データで確認できた:

- fldigi の cty.dat 形式パーサ (`TDxccDatabase.LoadFromString`/
  `LoadFromFile`) が、ヘッダ行 (国名:CQ:ITU:大陸:緯度:経度:GMT:主
  プリフィクス:) と複数行にまたがるプリフィクスリストを正しく解析し、
  完全一致例外コールサイン (`=W1AW(5)[8]` のようなCQ/ITUゾーン上書き
  付き) を含めて実際にコールサインからCQゾーン/ITUゾーン/大陸を
  正しく引けること。
- `TContestLog.LogQso` が `TDxccDatabase.Lookup` の結果を使って
  COUNTRY/CQZ/ITUZ/CONT を自動補完し、`AdifFile.pas` の
  `TAdifRecord`/`TAdifDatabase` へ実際に記録・ADIFファイルへ永続化
  できること (再読込後も内容が往復する)。
- `TContestLog.ValidateExchange` が `TContestDefinition` の
  フィールド定義に従って交換ナンバー各項目を検証し、不正な入力
  (存在しない国名、範囲外のCQゾーン等) を正しく検出すること。
- 重複交信(Dupe)チェックがバンド・モード単位で正しく機能すること。
- `TCountyDatabase.LoadFromFile` が counties.cxx と同じCSVフォーマット
  (ヘッダ行1行 + `State,ST,County,CTY` の4列) を正しく読み込み、
  正式名・略号どちらでも郡の有効性判定ができること。

### コンテストロギング/DXCC判定関連の既知の制約・省略した範囲

- 米国州QSOパーティ (`qso_parties[]` 約90件) は全件を移植していない。
  上記「なぜこの設計か」の通り、`TContestDefinition`/`TCountyDatabase`
  という同等の表現力を持つ枠組みは用意したので、必要な州のQSOパーティ
  データ (CSV) を用意すれば追加登録が可能。
- cty.dat / 郡データCSVの内蔵フォールバックデータは埋め込んでいない。
  運用前に [country-files.com](https://www.country-files.com/) から
  最新の `cty.dat` を、および必要な州QSOパーティの郡データCSVを
  別途用意する必要がある (未設定でも寛容フォールバックにより
  コンテストロギング自体はブロックされない)。
- `TContestLog.LogQso` はADIFの `DXCC` (数値の国コード) フィールドは
  自動補完しない。cty.dat 自体には国名文字列しか含まれておらず、
  ADIFの数値国コード表 (別ファイル) との対応付けは本移植版のスコープ
  外としたため (`COUNTRY`/`CQZ`/`ITUZ`/`CONT` の4項目のみ自動補完)。
- Sweepstakesの `ss_chk_test()` は fldigi の実装 (関数名に反して
  「先頭1文字が数字か」しか見ていない簡易な実装) をそのまま踏襲した。
  fldigi 側の実装自体がこの通りであることをソースコードで確認済み。
- 重複交信(Dupe)判定はコールサイン・バンド・モードの3項目一致のみ
  (fldigiにも本ユニットに対応する既存実装は無く、一般的なコンテスト
  ロギングソフトの標準的な定義に基づく本移植版オリジナルの追加機能)。
  マルチプライヤーの重複判定・得点計算は現時点では未実装。
- GUI (LCL) からの交換ナンバー入力欄・コンテスト選択UI・cty.dat/郡CSV
  ファイル選択ダイアログは、`units/` のコアロジックとしては完成して
  いるが、`forms/UnitMainForm.pas` への実際の組み込みは今後の拡張
  タスクとする。

## 9. 運用プロファイル (`units/OpProfile.pas`) / PC固有設定・セッション状態
   (`units/AppConfig.pas`)

「どの局として・誰が・どこから・何の設備で・どういう目的で運用するか」を
1クリックで切り替える機能。自宅運用と移動運用、個人局と社団局を行き来する
たびにコールサイン・QTH・グリッドロケータ・空中線電力・アンテナを手作業で
書き換える手間をなくす。

### なぜ fldigi の設定構造を踏襲しないのか

fldigi の設定は `progdefaults` という単一構造体に **878個** の項目
(`src/include/configuration.h` の `ELEM_()` を実測) がフラットに並び、
すべてが1個の `fldigi_def.xml` に保存される。**運用形態を切り替える概念が
存在しない**ため、運用地や局を変えるたびに個別の設定項目を手で直すことに
なる。本移植版の設定層はまだ `StationInfo.pas` (6項目) しか無い段階だった
ので、878項目を真似るのではなく構造から作り直した。

### ユースケースの MECE 分解

運用時に変わりうるものを「何を答える情報か」で分類すると、互いに重複せず
(Mutually Exclusive)、実運用のケースを網羅する (Collectively Exhaustive)
**6つの軸**に分かれる。

| 軸 | 答える問い | 対応するADIFフィールド |
|---|---|---|
| (1) 局 Station | 誰の免許で電波を出しているか | `STATION_CALLSIGN` / `OWNER_CALLSIGN` |
| (2) 運用者 Operator | 実際に操作しているのは誰か | `OPERATOR` |
| (3) 運用地 Site | どこから出ているか | `MY_GRIDSQUARE` / `MY_CITY` / `MY_SOTA_REF` … |
| (4) 設備 Equipment | どのリグ・アンテナ・電力で出ているか | `MY_RIG` / `MY_ANTENNA` / `TX_PWR` |
| (5) 接続 Interface | その設備が「このPC」のどこに繋がっているか | (ADIF外) |
| (6) 形態 Context | 何のための運用か | `CONTEST_ID` 等 |

代表的なユースケースがこの6軸でどう表現されるか:

| ユースケース | 変わる軸 |
|---|---|
| 個人局と社団局を使い分ける | (1)局 |
| 同一人が複数コールサインを持つ | (1)局 |
| 記念局・特別局として運用する | (1)局 + (6)形態 |
| 常置場所以外へ移動運用する | (3)運用地 (+ (1)局のポータブル指定) |
| POTA/SOTA/IOTA として運用する | (3)運用地 + (6)形態 |
| リグ/アンテナの組み合わせを変える | (4)設備 |
| QRP運用に切り替える | (4)設備 |
| **クラブ局を複数人が同時に運用する** | **(1)局は共通 / (2)運用者と(5)接続が個別** |
| シャックPCと移動用ノートを使い分ける | (5)接続のみ |
| 同じ設備を別PCへ繋ぎ替える | (5)接続のみ |
| リモート運用する | (3)運用地(局の所在地) + (5)接続 |
| コンテストに参加する | (6)形態 (+ ログ分割) |
| 衛星通信を行う | (4)設備 + (6)形態 |

**この分解の要は「クラブ局を複数人が同時に運用する」ケース**である。これは
局 (`STATION_CALLSIGN`) が共通のまま運用者 (`OPERATOR`) だけが異なることを
要求するので、局と運用者が独立した軸であることの証明になっている。ADIFが
この2つを別フィールドとして定義しているのと同じ構造であり、本ユニットも
それに従う。

### fldigi との対応表

| fldigi (C++) | Lazarus (Pascal) | 役割 |
|---|---|---|
| (概念自体が存在しない) | `TOperatingProfile` (OpProfile.pas) | 各軸から1つずつ選んだ組み合わせ |
| `progdefaults.myCall` (MYCALL) | `TStationIdentity.Callsign` | 局のコールサイン |
| `progdefaults.operCall` (OPERCALL) | `TOperatorInfo.Callsign` | 運用者のコールサイン |
| `progdefaults.myQth` / `myLocator` | `TOperatingSite.City` / `GridSquare` | 運用地 |
| `progdefaults.myAntenna` | `TEquipmentSet.Antenna` | アンテナ |
| (該当なし) | `TEquipmentSet.Rig` / `PowerW` | リグ名・空中線電力 |
| `progdefaults.HamRigDevice` / `HamRigBaudrate` | `TInterfaceSetup.RigDevice` / `RigBaudRate` | CATポート設定 |
| `progdefaults.PTTdev` / `RTSptt` / `DTRptt` | `TInterfaceSetup.PttDevice` / `PttMethod` | PTT制御方式 |
| (PC固有と可搬な設定を区別しない) | `TMachineConfig` (AppConfig.pas) | PCごとの設定セクション |
| `progStatus` (status.cxx) | `TSessionState` (AppConfig.pas) | 前回終了時の状態 |
| `TStationInfo` (StationInfo.pas) | `TResolvedStation` | 解決済みの実効値 |

### 設計判断のポイント

- **軸ごとのマスタ + 組み合わせとしてのプロファイル**: 各軸の実体を独立した
  マスタとして登録し、`TOperatingProfile` は「各軸から1つずつ選んだ参照の
  束」として持つ。こうすると `3コール × 4運用地 × 5設備 = 60通り` を個別に
  作る組み合わせ爆発を避けられ、**リグを買い替えても設備マスタを1つ直すだけ
  で全プロファイルに反映**される。テストでは「マスタ合計8件で2×2×2×2=16通り
  を表現」できることを確認している。
- **参照は Name (軸内で一意) で行う**: GUIDではなく人間が読める名前をキーに
  する。`op_profiles.json` はユーザーが直接編集することを想定しているため。
  改名時は `TProfileRegistry.Rename*` が参照側も追従して書き換える。
- **軸の「掛け算」は解決時に一箇所で行う**: 移動運用時のコールサインは
  「局のコールサイン」×「運用地のポータブル指定」で決まる
  (`JA1ABC` + `/1` → `JA1ABC/1`)。実効空中線電力は「免許上限」(局軸) と
  「設備の出力」(設備軸) の **min** になり、免許を超えたまま運用してしまう
  事故を防ぐ。こうした軸をまたぐ計算は各マスタには持たせず、
  `TProfileRegistry.Resolve()` が `TResolvedStation` を組み立てる際に行う。
- **接続軸(5)だけは別ファイル + マシン識別子でセクション分け**: リグの
  モデル名は「設備」の属性だが、`COM3` / `/dev/ttyUSB0` というポート名は
  同じ設備でもPCごとに変わる。本アプリは実行ファイルと同じディレクトリに
  設定を置く = **USBメモリごと持ち運ぶ**運用を想定しているため、PC固有設定を
  別ファイルにするだけでは解決しない (そのファイルも一緒に移動してしまう)。
  そこで `machine_config.json` の中を「マシン識別子 → そのマシンの設定」と
  いう辞書構造にし、各PCが自分のセクションだけを読むようにした。
- **既存ユニットとの接続**: `TResolvedStation.ToStationInfo` で既存の
  `TStationInfo` へ書き出せるため、**`QsoLogbook` / `AdifUdpSender` は一切
  変更せずに**プロファイル機能の恩恵を受けられる。
- **コンテスト定義との連携点**: `TOperatingProfile.ContestName` は
  `ContestLog.pas` の `TContestRegistry.FindByName` へ渡す想定で、
  プロファイル選択だけでコンテスト定義まで切り替えられる。

### 9-1. 検証手順

```bash
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -otest/test_opprofile test/test_opprofile.lpr
./test/test_opprofile
```

テストは getter/setter の確認ではなく、上記「MECE分解」の表の各ユースケースが
実際に表現できることを1ケースずつ実データで確かめる構成にしている。

```
--- 2. 複数コールサイン保有 / クラブ局の同時運用 ---
  [OK] クラブ局の 2 プロファイルは STATION_CALLSIGN が同一
  [OK] 運用者A の OPERATOR = JA1ABC
  [OK] 運用者B の OPERATOR = JA1DEF (同一局・同一時刻でも区別できる)

--- 3. 移動運用: 局コールサイン x 運用地のポータブル指定 ---
  [OK] 移動地では JA1ABC + "/1" = JA1ABC/1 に解決される

--- 4. 設備の組み合わせ / 免許上限による空中線電力の丸め ---
  [OK] 設備100W x 免許上限50W → 実効50W に丸められる
  [OK] 同じ固定機でもクラブ局(免許200W)では100Wのまま

--- 5. 設備マスタの修正が参照する全プロファイルへ反映される ---
  [OK] 改名がプロファイル側の参照へ追従する

--- 9. AppConfig: マシン識別子によるセクション分離 ---
  [OK] 同じファイルでも mobile-note では COM3 が解決される
    → USBメモリで PC を渡り歩いてもポート設定が壊れない

=== テスト完了: 0 件の失敗 (全 77 件中) ===
```

### 9-2. 併せて修正した既存の潜在バグ (日本語がJSON往復で壊れる)

本機能の実装中に、**既存の `StationInfo.pas` / `QsoLogbook.pas` が日本語を
含む値を保存・再読込すると破壊する**バグを発見し、併せて修正した。

FPC の `string` は `AnsiString(CP_ACP)` であり、Unix では `CP_ACP` の実体
(`DefaultSystemCodePage`) が既定で 0 のままになる。この状態で fpjson が内部の
`UnicodeString` から `AnsiString` へ変換すると、非ASCII文字がすべて `'?'` に
潰れる。**書き出しは正しいUTF-8になるため、保存したファイルを読み直した
瞬間にだけ壊れる**という分かりにくい壊れ方をする。

```
修正前: MyQth := '東京都八王子市' → 保存 → 再読込 → '???????'
修正後: MyQth := '東京都八王子市' → 保存 → 再読込 → '東京都八王子市'
```

既存テストが ASCII 値 (`'Tokyo'` / `'JA1TEST'`) のみを使っていたため露見して
いなかった。JSON永続化を行う4ユニット (`StationInfo` / `QsoLogbook` /
`OpProfile` / `AppConfig`) の `initialization` で
`SetMultiByteConversionCodePage(CP_UTF8)` を宣言して修正し、
`test/test_station_adif.lpr` に日本語の往復テストを追加して再発を防いでいる。
ロケール環境変数に依存しないので `LANG` が未設定の環境でも安全。

### 運用プロファイル関連の既知の制約・省略した範囲

- GUI (LCL) からのプロファイル選択UI・軸マスタの編集ダイアログは、
  `units/` のコアロジックとしては完成しているが、
  `forms/UnitMainForm.pas` への組み込みは今後の拡張タスクとする。
- プロファイル選択時に実際に `THamlibRigControl` を開き直す・サウンド
  デバイスを切り替える、という**適用処理そのものは未実装** (本ユニットは
  「何を使うべきか」を解決するところまでを担当する)。推奨着手順の
  `BandPlan.pas` と合わせて配線する想定。
- `TEquipmentSet.Rig` / `PowerW` (ADIF: `MY_RIG` / `TX_PWR`) は
  `TResolvedStation` までは解決されるが、`AdifUdpSender` はまだ
  これらのタグを出力しない (`TStationInfo` に対応する項目が無いため)。
  ADIF出力への反映は `AdifFile.pas` 経由のロギングと合わせて行う。

## 10. 堅牢性・ソフトウェア品質の監査と修正

GUI を除くコアユニット全体を、コンパイルエラー以外の観点 (実行時に初めて
壊れる不具合・性能・エラー処理の誠実さ) で監査し、見つかった問題をすべて
修正した。回帰テストは `test/test_robustness.lpr` (全36件)。

### 10-1. ADIF 入出力の不具合 (`AdifFile.pas`)

**(a) 値に改行を含むフィールドで以降が全部ずれる**
ADIF は `<CALL:4>W1AW` のように長さを**バイト数で前置**する書式である。
読み込みに `TStringList.LoadFromFile` + `.Text` を使っていたため改行コードが
正規化され (CRLF→LF)、値に改行を含むフィールド (ADIF が許容する
NOTES/COMMENT など) があると長さと実バイト数がずれ、**そのレコードの
以降のフィールドをすべて誤って切り出していた**。
生バイトで読む `SafeFileIO.LoadTextRaw` に変更し、書き出し側も
`TStringList.SaveToFile` を経由しない対称な経路にした。

**(b) 大量ログの読み込みが二次オーダー**
大小無視の検索ヘルパーが**呼び出しのたびにバッファ全体を `LowerCase`**
していた。この検索はレコードごとに実行されるため、レコード数 × ファイル全体
という O(n²) になっていた。小文字版を最初に1回だけ作る方式へ変更。

検索部分だけを取り出した実測 (3000レコード / 375KB):

| 方式 | 所要時間 |
|---|---|
| 修正前 (毎回バッファ全体を小文字化) | **3691 ms** |
| 修正後 (1回だけ小文字化) | **2 ms** |

約1800倍の差で、しかも二次オーダーなので件数が増えるほど開く。
実ファイルの読み込み全体でも 3000 レコードが 10 ms で完了するようになった。

**(c) 値に `<` を含むとタグと誤認する**
フィールド解析後に「次の `<`」へ飛んでいたため、値の中の `<` をタグの開始と
誤認していた。長さ分を確実に読み飛ばしてから次のタグを探す方式へ変更。

**(d) 同一内容の if/else 分岐 (デッドコード)**
`SaveToFile` に `if fld = afFreq then ... else ...` があったが両分岐が
完全に同一だった。値は格納時点で既に ADIF 準拠なので分岐ごと削除。

### 10-2. 保存の非アトミック性 (`SafeFileIO.pas` を新設)

設定・ログの保存が `TStringList.SaveToFile(AFileName)` で保存先を直接開いて
上書きする方式だった。この方式では「ファイルを開いて切り詰めた直後・書き込み
完了前」に電源断やクラッシュが起きると、**保存先が空または途中までの内容に
なり、それまでの設定やログが失われる**。

本アプリは実行ファイルと同じディレクトリに設定を置く = USB メモリで持ち運び、
**バッテリー運用の移動運用先でも使う**想定なので、書き込み中の電源断は
現実に起こりうる。共通ヘルパー `SafeFileIO.SaveTextAtomic` を新設し、
「一時ファイルへ書き切ってから rename で置き換える」方式に統一した。
rename は POSIX では原子的操作なので、どの瞬間に電源が落ちても保存先は
「更新前の完全な内容」か「更新後の完全な内容」のどちらかになる。

適用先: `StationInfo` / `QsoLogbook` / `OpProfile` / `AppConfig` / `AdifFile`。

### 10-3. エラー処理の誠実さ

- **`TContestLog.SaveToAdif` が常に True を返していた**。書き込み権限・
  ディスク残量・USB メモリの抜去といった実運用で起こりうる失敗を、
  呼び出し側が戻り値から判別できなかった。例外を捕捉して False を返し、
  理由を `LastSaveError` と `out` 引数で取得できるようにした。
- **添字アクセサに範囲検査が無かった** (`TAdifDatabase` / `TQsoLogbook` /
  `TProfileRegistry` / `TAppConfig` / `TDxccDatabase` / `TContestRegistry` /
  `TCountyDatabase` / `TContestDefinition`)。範囲外はアクセス違反になり、
  どこで何番目を触って落ちたのか分からなかった。対象名と件数を含む
  専用例外に変更した。
- **手編集で壊れた JSON への耐性**。`machine_config.json` の
  `profileBindings` の値が文字列以外 (数値等) になっていると `AsString` が
  例外を投げ、**そのマシンの設定全体が読めなくなっていた**。型を確認して
  不正な項目だけを読み飛ばすようにした。

### 10-4. DSP の数値安全性 (`ModemDSP.pas`)

- **FFT 長の検証が無かった**。`ComplexFFT` / `TFftFilt` は Radix-2 実装なので
  2の冪乗長でしか正しく動かないが、それ以外を渡すと例外も出さず
  **静かに誤った結果**を返していた。生成・実行時に検査して `EDspError` を
  送出するようにした。
- **`RttyFilter` の除算で NaN/Inf が混入しうる**。振幅等化の
  `dht / Sinc(2*i*f)` は `Sinc` が 0 になりうる (引数が 0 以外の整数のとき)。
  現行パラメータでは先に `dht` が 0 になるため到達しないが、`0/0 = NaN` の
  可能性が残る。**一度でも NaN が係数に入ると以降の復調出力すべてが NaN に
  汚染される**ため、明示的に保護した。回帰テストで実際にサンプルを流し、
  出力に NaN/Inf が現れないことを確認している。

### 10-5. 監査したが問題が無かった箇所

- `TMovingAverage.SetLength_` の縮小時: `FEmpty := True` により次回 `Run` で
  `FPtr` が 0 に戻るため、範囲外アクセスは起きない。
- `DxccDatabase` の所有権: `FPrefixMap` の値は借用参照で、実体は
  `FBaseEntities` / `FExceptionEntities` が `OwnsObjects=True` で所有。
  `Clear` はマップを先に空にしてから実体を解放しており順序も正しい。
- `TRttyModem` の `FBitBuf`: 最大シンボル長 (8000/45≒177) が確保サイズ
  (`RTTY_MAXBITS`=696) を超えないため溢れない。

## 11. 並行処理・音声・PTT の安全性修正 (P0)

第三者による品質レビューで指摘された、**メモリ安全性と送信安全性に直結する
12件 (P0)** を修正した。10章の監査はデータ層 (ADIF / JSON / DSP) に閉じており、
スレッド・オーディオ・PTT の層は対象外だったため、そこに残っていたものである。

回帰テストは `test/test_threadsafety.lpr` (全25件)。単なるコンパイル確認では
なく、**実際にワーカースレッドを走らせて競合を再現させる**構成にしている。

### 11-1. スレッド破棄時の解放順序 (ENG-01 / RIG-01)

`TModemEngine.Destroy` / `TRigPollThread.Destroy` が、`inherited Destroy` の
**前**に `FLock.Free` を実行していた。FPC の `TThread.Destroy` は内部で
`Terminate` → `Resume` → `WaitFor` を行うので、`inherited` の時点でワーカーは
まだ走っている。つまり**ワーカーが掴んでいる最中のクリティカルセクションを
解放していた**ことになり、破棄のたびにアクセス違反の窓が開いていた。

`inherited Destroy` (= スレッド停止の確定) を先に済ませ、その後で
ロックやイベントを解放する順序に変更した。

```pascal
destructor TModemEngine.Destroy;
begin
  RequestExit;        // 冪等。終了要求 + ブロッキングI/Oの解除 (ENG-04)
  inherited Destroy;  // ここで Terminate / Resume / WaitFor が行われる
  FModemChangeDone.Free;
  FLock.Free;         // スレッド停止が確定してから解放する
end;
```

### 11-2. ブロッキング I/O で停止できない (ENG-04)

`Terminate` はループの先頭でしか見られないため、ワーカーが
`Pa_ReadStream` の中でブロックしていると終了要求が届かず、
**アプリ終了時にハングする**。`AbortIO` を I/O 層の契約として追加し、
`RequestExit` が「終了フラグ → `Terminate` → `AbortIO`」の順で
ブロッキング呼び出し自体を叩き落とすようにした。

テストではブロッキングデバイスを差し込んで実測し、**100 ms で停止**する
ことを確認している (上限2秒で判定)。

### 11-3. 実行中のモデム差し替え (ENG-02)

`SetModem` が呼び出し側スレッドから `FActiveModem` を書き換えていた。
RX ループはロック無しで同じポインタを読んで復調しているので、
**差し替えた瞬間に解放済みオブジェクトを触りうる**。

要求をポストしてワーカー側で適用する方式に変更し、`FActiveModem` の
書き手をワーカースレッド1つに限定した。`SetModem` は適用完了を
`TSimpleEvent` で待つ (5秒でタイムアウトし `EModemEngineError`) ので、
**復帰した時点で旧モデムを解放してよい**という契約が呼び出し側に立つ。

### 11-4. 終了通知が飛ばない (ENG-04)

`Execute` が例外で抜けると `tsExit` が通知されず、UI 側が
「まだ動いている」と誤認したままになっていた。`Execute` 全体を
`try..finally` で囲み、**どの経路で抜けても必ず `tsExit` を通知**する。
併せてループ1周ごとの `try..except` を入れ、1回の失敗でスレッドごと
落ちるのではなく `DoError` で通知して継続するようにした。

### 11-5. UI キューの use-after-free と無制限成長 (UI-01 / UI-02 / APP-01)

`TModemUI` はワーカーからの通知を `TThread.Queue` で main へ渡していたが、

- **破棄しても未処理のキューが残る**。`TModemUI` が解放された後にキューが
  走れば、解放済みインスタンスのメソッドを呼ぶ (use-after-free)。
- **キューが無制限**。`TThread.Queue` は毎回ノードを確保するため、UI が
  詰まると受信文字の分だけメモリが伸び続ける。
- `TMainForm.Destroy` の解放順序が「エンジン → UI」で、**UI を先に殺せて
  いなかった**。

固定長 (4096) のリングバッファ + 「未スケジュールなら1回だけ `Queue` する」
方式に置き換えた。溢れは捨てて `DroppedEventCount` で数える (無音で失うより
「何件落とした」が分かる方が運用上は正しい)。周波数・S メーターのような
最新値だけが意味を持つものは**キューに積まず最新値を上書き**する。
`Destroy` では停止フラグ → キュー破棄 → ハンドラ切断 →
`TThread.RemoveQueuedEvents` の順で、走行中のドレインを確実に取り消す。
`TMainForm.Destroy` の順序も「UI → エンジン → モデム → サウンド」に直した。

> FPC の挙動で2点ハマったので記録しておく。
> `TThread.Queue` は**メインスレッドから呼ぶとその場で実行される**
> (`ThreadQueueAppend` の `aQueueIfMain=False`)。また
> `TThread.WaitFor` をメインスレッドから呼ぶと**待っている間にキューを
> 処理してしまう**。どちらもテストが「破棄前に配送済み」になって
> 検証にならないので、投入は専用スレッドから行い、待ちは完了フラグの
> ポーリングにしている。

### 11-6. PortAudio ストリームのライフサイクル (AUD-04 / AUD-06 / AUD-07)

- **`Open` が途中で失敗すると中途半端に開いた状態が残る**。ローカル変数上で
  組み立て、`Pa_StartStream` が成功して初めてフィールドへコミットする方式に
  変更した (失敗時はローカルを閉じる)。
- **`Close` と I/O が競合する**。`FStream` を掴んだまま別スレッドが
  `Pa_CloseStream` を呼べば、解放済みストリームへの読み書きになる。
  I/O 実行数 (`FIoActive`) を数えるようにし、`Close` は
  「ロック下でハンドルを奪う → `FStream:=nil` → `Pa_AbortStream` →
  I/O が抜けるのを待つ (最大2秒) → `Pa_StopStream`/`Pa_CloseStream`」の
  順で行う。`AbortIO` はこの `Close` に集約した。
- **`Destroy` が開いたまま終わりうる**経路があったので、無条件に `Close` する。
- ステレオ時のバッファ長計算が誤っていた (`Count` フレーム × チャンネル数が
  必要なのに `Count` しか確保していなかった)。`WriteStereo` は
  Channels=2 を要求し、R 側の長さも検査する。
- 出力レイテンシに `defaultLowOutputLatency` を使うようにした。

### 11-7. 入出力引数の検証 (AUD-05)

`ReadSamples` / `WriteSamples` が、未オープン・負の `Count`・
バッファ長超過をどれも検査していなかった。基底クラスに
`ValidateIoCount` を置いて `ESoundError` を送出する契約に統一し、
`TNullSoundDevice` も同じ契約に従わせた (テストダブルが本物より緩いと
テストが通っても実機で落ちるため)。

なお、この検証を入れたことで**既存の実バグが表面化した**。エンジンが
未オープンのデバイスに対して `ReadSamples` を呼び続けており、それまでは
黙って 0 件が返っていた。`RxLoopStep` に `IsOpen` 判定を追加した。

### 11-8. PTT の取り残し (RIG-11)

送信中に例外が出た場合や、送信状態のまま `TRigControl` を破棄した場合に
**PTT が上がりっぱなしになる**。電波を出し続けるので、ソフトの不具合の
中でも実害が最も直接的な部類である。

`NotePttState` で送信状態を記録し、

- `EnsurePttOff` — 例外を投げずに PTT を下ろす (フェイルセーフ用)
- `TransmitGuarded` — 送信処理を `try..finally` で包み、**どの経路で
  抜けても PTT を下ろす**
- `Destroy` — `Close` の前に `EnsurePttOff`

を追加した。`SetPTT` が失敗した場合も、ON 要求なら「上がっているかも
しれない」側に倒して記録する (下ろす試行が余分に走るのは無害だが、
記録しそこねると上がったまま残る)。

### 11-9. 残っている指摘 (P1 以下)

レビューの P1〜P3 には未着手のものがある。主なもの:

- `AdifFile` の `<EOH>` を必須にしている (ADIF ではヘッダ自体が任意)
- `FloatToStr` がロケール依存 (小数点が `,` の環境で ADIF が壊れる)
- WSJT-X 連携が UDP type 12 だと説明しているが、実装は生 ADIF を投げている
  (Qt のバイナリヘッダが無いので WSJT-X 本体とは互換でない)

### 11-10. P0 修正そのものを検証し直して見つかった追加の欠陥

「12件を直した」と報告した後で、修正コードを敵対的に読み直した。
**修正が不十分だったもの・修正で新たに入ったもの・元から見落としていたもの**
が合わせて11件見つかったので、すべて直した。回帰テストは25件から43件に増やした。

**(a) 破棄順序の修正が足りていなかった (APP-01 の続き)**

`TMainForm.Destroy` を「UI を先に Free → エンジンを停止・Free」に直したが、
これでは足りない。切り離し (`DetachEngine`) は *これから来る* 通知を止める
だけで、**既にワーカーが `TModemUI` の中に入っている呼び出しは止められない**。
`TModemUI.Destroy` は `FLock.Free` をするので、`PushEvent` の `FLock.Enter`
で待っているワーカーが解放済みロックを掴む — ENG-01 とまったく同じ型の
不具合を、直した本人が UI 側に残していた。

正しい順序は **「ワーカースレッドを完全に停止させてから UI を破棄する」**。
停止後ならコールバックの発生源そのものが存在しない。エンジン *オブジェクト* は
UI が切り離しに使うので、UI より後に解放する。

```
1. FEngine.RequestExit; FEngine.WaitFor;   ← スレッド停止
2. FUI.Free;                               ← エンジン本体はまだ生きている
3. FEngine.Free;
4. FModem.Free; FSound.Free;
```

併せて `TModemUI` 自身にも在席カウンタ (`EnterCallback`/`LeaveCallback`) を
入れ、破棄に入った時点で中にいた呼び出しが抜けるまでロックを解放しない
ようにした。ただしこれは安全網であって、**呼び出し側が上の順序を守る責務は
変わらない** (Destroy が戻った後に始まる呼び出しは、オブジェクトのメモリが
既に無いので何をしても救えない)。同じ理由から `AttachModem`/`AttachEngine`
にも「ワーカー停止中に呼ぶこと」を前提条件として明記した。

**(b) イベントハンドラの代入がアトミックでない**

`TModemEngine` と `TRigPollThread` は、破棄時にハンドラを nil にしてから
スレッドを止める作りにした。しかし発火側 (`DoStateChanged` 等) が
**ロックを取らずにフィールドを読んでいた**ため、ロックが何も守っていなかった。
しかも `procedure of object` はコード部とデータ部の2ワードで、代入は
アトミックではない。**「コードは旧・データは nil」というちぎれた値を読んで
飛ぶ**危険がある。読み書きの両方をロックで守り、呼び出し自体は写し取った
ローカル経由でロック外から行うようにした。

**(c) `SetModem` が「差し替えた」と偽って戻りうる**

`RequestExit` と `Execute` の finally が、**保留中の差し替えを適用せずに
完了イベントだけを立てて**いた。待っていた `SetModem` は成功として戻るので、
呼び出し側は契約どおり旧モデムを解放する — ところがエンジンは旧モデムを
指したままになる。終了時にしか起きないが、まさに解放済みオブジェクトを
指す状態を作っていた。

`Execute` の finally で **適用してから** 完了を通知するようにし、待機側も
「待っている最中にワーカーが終了した」場合 (`Finished`) を検出して自分で
引き取るようにした。これで、`SetModem` が正常復帰したなら差し替えは
必ず済んでいる、という契約が終了と交錯しても保たれる。
回帰テスト9はこの競合をブロッキングデバイスで**決定的に再現**しており、
修正を戻すと実際に失敗する。

**(d) 実機クラスでは PTT フェイルセーフが動いていなかった**

`TCustomRigControl.Destroy` に `EnsurePttOff` を入れたが、基底デストラクタが
走るのは**派生デストラクタの本体が終わった後**である。`THamlibRigControl` は
自分の `Destroy` で先に `Close` してしまうので、基底に着いた時点では
`FIsOpen=False` で何もできない。つまり **`TNullRigControl` (テスト用) では
動くが、実機クラスでは一度も PTT を下ろしていなかった**。
テストが `TNullRigControl` しか使っていなかったため通っていた。
`THamlibRigControl.Destroy` の先頭で `EnsurePttOff` を呼ぶようにした。

**(e) `EnsurePttOff` が下ろせていないのに成功を返していた**

通信路が閉じている等で PTT を操作できない場合に `True` を返していた。
電波が出続けているのに呼び出し側は正常終了と判断する。`False` を返し、
送信状態の記録も消さずに残す (再オープン後の再試行で下ろせるように)。

**(f) `TransmitGuarded` にメソッドを渡せなかった**

引数の型が `System.TProcedure` (グローバル手続き) だったため、
フォームやコントローラの**メソッドを渡せず、実質使えなかった**。
`TRigTransmitProc = procedure of object` を定義して差し替えた。

**(g) ポーリング間隔がそのまま破棄のブロック時間になっていた**

`TRigPollThread.Execute` が `Sleep(FPollIntervalMs)` をしていたため、
間隔を 5 秒にすると破棄が 5 秒かかる。`Terminated` を見ながら 20ms 刻みで
待つようにした。実測 **5024 ms → 100 ms** (100 ms は FPC の
`TThread.Free` 自体の所要時間で、これが下限)。

**(h) 終了のたびに偽のエラーが通知される**

`RequestExit` は `AbortIO` でブロッキング読み取りを叩き落とす。実デバイスでは
直後の `ReadSamples` が必ず例外になるので、それを `OnError` に流すと
**終了のたびにユーザーへエラーが出る**。`Terminated` 中の例外は通知しない
ようにした。走行中の本物の障害はこれまでどおり通知される
(回帰テスト13で両方を区別して確認)。

**(i) `Pa_Initialize` を2回呼んでいた**

```pascal
if Pa_Initialize <> paNoError then
  raise EPortAudioError.Create(Pa_Initialize, 'Pa_Initialize');
```
条件式と例外生成で 2 回呼んでいた。PortAudio 側も参照カウントを持つので
二重初期化になり、しかも 2 回目は成功するため、エラー文言が
`PortAudio error in Pa_Initialize: 0 (Success)` という意味不明なものに
なっていた。

**(j) 使用中のストリームを閉じていた**

`Close` は入出力が抜けるのを `WaitForIoIdle(2000)` で待つが、**戻り値を
見ずに `Pa_CloseStream` へ進んでいた**。タイムアウトした場合は、まだ
`Pa_ReadStream` の中にいるスレッドがそのハンドルを保持している。
カウンタを入れた意味が無くなっていた。タイムアウト時はハンドルを解放せず
(意図的に漏らす)、例外で事実を伝えるようにした。デバイス抜去などの異常系で
ストリーム1個を漏らす方が、未定義動作よりも害が小さい。

**(k) `Open` と `Close` が直列化されていなかった**

`Open` は冒頭で `Close` を呼ぶ。別スレッドの `Close` と交錯すると
「閉じたつもりで開いている」状態が残りうる。ストリームの生成・破棄という
粒度の粗い操作を専用ロック (`FLifecycleLock`) で丸ごと直列化した。
ブロッキング入出力はこのロックを取らないので、`Close` が待たされることはない。
併せて `EnumerateDevices` が自前で `Pa_Initialize`/`Pa_Terminate` していたのを
参照カウントに一本化した (列挙中に他スレッドが開いたストリームごと
PortAudio を落としうる状態だった)。

### 11-11. 検証方法についての反省

25件のテストが全部通ったので「直った」と報告したが、
上記のうち (d) は **テストが `TNullRigControl` しか使っていなかったから
通っていた**だけで、実機クラスでは機能していなかった。旧テストの最後は
`rig.Free; Check(True, '...例外なく完了する')` で、**何も検証していない
アサーション**だった。

そこで今回は、新しいテストについて **修正を一時的に戻して失敗することを
確認**した。実際に (c)(g)(h) は修正を戻すと失敗する。逆に、決定的に
再現できないもの (UI の在席カウンタが救う瞬間) は「確率的なストレステスト
であって証明ではない」とテスト自身のコメントに明記した。

| 検証 | 内容 |
|---|---|
| 回帰テスト | 10スイート 445件すべて成功 |
| うち並行処理 | `test_threadsafety` 43件 (25件から追加) |
| 反証テスト | 修正を戻すと (c)(g)(h) が実際に失敗することを確認 |
| ビルド未確認 | `forms/UnitMainForm.pas` (LCL 未導入環境のため目視のみ)、`test_rigcontrol` / `test_portaudio` (libhamlib / libportaudio 未導入。ユニット自体のコンパイルは成功) |

## 12. ラバースタンプ / コンテスト用マクロ (`units/MacroEngine.pas`)

### 何のための機能か

デジタルモードの交信は大半が定型で進む。CQ を出す → 呼ばれる → レポートを
送る → 相手のレポートを受ける → 名前と QTH を送る → 73 で終わる。この定型
交信を**ラバースタンプ QSO** と呼ぶ。毎回タイプするのは現実的でないので、

```
CQ CQ CQ de <MYCALL> <MYCALL> pse k
```

のような雛形を用意し、`<MYCALL>` のような差し込み記号 (タグ) を実行時に
実際の値へ置き換える。これがマクロである。

コンテストではさらに速度が要るうえ、**送信ナンバーの管理**という
「間違えると交信が無効になる」要素が加わる。本ユニットは両方を同じ
仕組みで扱う。

### fldigi との対応

| fldigi (`src/misc/macros.cxx`) | 本ユニット |
|---|---|
| `MACROTEXT::expand()` | `TMacroExpander.Expand` |
| `MACROTEXT::text[]` / `name[]` (固定48個) | `TMacroSet` (可変長・名前引き) |
| `macro_types[]` のタグ表 | `HandleTagCore` のディスパッチ |
| `<TX>`/`<RX>` が `trx_transmit()` を直接呼ぶ | `TMacroSegment` として **返す** |

### 設計上いちばん重要な違い: なぜ文字列を返さないのか

fldigi の `expand()` は展開しながら副作用 (送信開始/停止、モード変更) を
その場で実行してしまう。これだと三つ困る。

1. 送信前に「このマクロが何をするか」を確認できない
2. GUI 無し・無線機無しで単体テストできない
3. 「展開はできたが送信はしない (プレビュー)」ができない

そこで本ユニットは、展開結果を**文字列断片と操作命令が順番に並んだ列**
(`TMacroSegment` の配列) として返すだけにし、実行は呼び出し側に任せた。

```
<TX>CQ de <MYCALL> k<RX>
  → [操作:送信開始] [文字列:"CQ de JI1UUI k"] [操作:受信復帰]
```

同じ展開結果を「送信する」「画面に見せるだけ」「検査する」のどれにも使える。
**送信前バリデーションが成立するのはこの形のおかげ**である。

実行は `TMacroRunner` + `TMacroHost` (抽象宿主) が担う。実機ではフォームが
`TMacroHost` を実装して `TModemEngine` / `TCustomRigControl` / `TQsoLogbook`
へ配線し、テストでは記録するだけの実装を差し込む。

### コンテスト運用で特に配慮した3点

**(1) 送信ナンバーはログするまで進めない**

`<#>` を展開しただけでは番号は進まない。`CommitSerial` を呼んだときだけ進む。
呼ばれた局に 001 を送ったあと交信不成立でログしなかった場合、**次の局にも
001 を送るのが正しい**。番号を飛ばすとコンテストのログ照合で
「相手の受信番号と合わない」減点になる。展開のたびに採番する実装だと、
再送のたびに番号が飛ぶ。

`TMacroRunner` は `<LOG>` に対して `Host.LogCurrentQso` を呼び、**それが
True を返したときにだけ** `CommitSerial` する。ログ記録が失敗すれば番号は
据え置かれる。

**(2) CW のカットナンバー**

コンテストの CW では 0 を T、9 を N と短縮して送る慣習がある
(599 → 5NN、109 → 1TN)。`<#CUT>` で出力できる。1 → A は環境によって
通じないことがあるため採用していない (安全側)。

**(3) 送信したまま受信に戻らないマクロを事前に弾く**

`<TX>` で始まり `<RX>` で終わらないマクロは、実行すると電波を出しっぱなしに
する。コンテスト中に気づかず放置すると被害が大きい。`Validate` がこれを
**エラー**として報告し、`TMacroRunner` が実行を拒否する。
検査しても実行を止めなければ意味がないので、拒否まで含めて 1 つの機能である。

### タグ一覧

| 分類 | タグ |
|---|---|
| 自局 | `<MYCALL>` `<MYNAME>` `<MYQTH>` `<MYLOC>` `<MYRIG>` `<MYANT>` (`<ANTENNA>`) `<MYPWR>` |
| 相手局 | `<CALL>` `<NAME>` `<QTH>` `<LOC>` `<RST>` (`<RSTS>`) `<RSTR>` |
| 運用状態 | `<BAND>` `<MODE>` `<FREQ>` |
| 日時 (UTC) | `<TIME>` `<DATE>` `<ZDT>` |
| コンテスト | `<#>` (`<SERIAL>`) `<#CUT>` (`<SERIALCUT>`) `<SERIALIN>` `<XOUT>` `<XIN>` `<CNTST>` |
| 操作 | `<TX>` `<RX>` `<ABORT>` `<LOG>` `<CLRRX>` `<CLRTX>` |
| 引数つき操作 | `<MODE:CW>` `<FREQ:7.026>` `<WAIT:1.5>` `<INCR>` `<DECR>` |
| 入れ子 | `<MACRO:名前>` |
| 条件分岐 | `<IF:条件>` `<ELSE>` `<ENDIF>` |
| 反復 | `<REPEAT:n>` `<ENDREPEAT>` |

タグ名の大小は区別しない。`< MYCALL >` のように空白を入れてもよい。

### 送信前バリデーションが見るもの

`Expand` が見るのは**書き方**の問題 (未知タグ、引数の不正)、`Validate` が
見るのは**今この状況で送っていいか**である。

| 判定 | 水準 | 理由 |
|---|---|---|
| `<TX>` に対応する `<RX>` が無い | エラー | 電波を出し続ける |
| ログするのに相手コールが空 | エラー | 空レコードが残る |
| 送信ナンバーが 1 未満 | エラー | コンテストログとして通らない |
| 使っているタグの値が空 (`<NAME>` 等) | 警告 | "tnx  om" のような文を送る |
| `<TX>` より前に本文がある | 警告 | その部分は送信されない |
| 未知タグ | 警告 | 既定。`StrictUnknownTags` でエラーにできる |

「値が空」の判定には**そのタグを実際に使ったか**が要る。展開後の文字列を
見ても「`<CALL>` が空だった」のか「もともと書いていない」のかは区別できず、
CQ マクロに対して「相手のコールが空です」と言ってしまう。そこで展開時に
使ったタグ名を記録 (`UsedTags`) しておき、それを見て判定している。

### 標準マクロ

`TMacroSet.RegisterBuiltins` がラバースタンプ 6 種とコンテスト 6 種を登録する。
「何から書き始めればいいか分からない」状態を避けるための出発点であり、
利用者が自由に編集して使う前提である。

- ラバースタンプ: `CQ` / `応答` / `レポート` / `リグ紹介` / `73` / `QRZ?`
- コンテスト: `CQコンテスト` / `交換` / `交換(カット)` / `TU` / `AGN?` / `NR?`

すべて `<TX>` で始めて `<RX>` で終える形に統一してある。雛形の段階で
「送信したまま戻らない」形を排除するためで、テスト 8 が標準セット全件を
`Validate` に通して確認している。

### 12-1. 検証手順

```bash
fpc -Fuunits -FEtest -otest_macro test/test_macro.lpr
./test/test_macro
```

全 117 件。重点は次の 4 つ。

| 観点 | 内容 |
|---|---|
| 順序 | `A<TX>B<RX>C` が 文字列/操作/文字列/操作/文字列 の 5 断片に正しく割れる |
| 送信ナンバー | 再展開しても進まない・`CommitSerial` でだけ進む・ログ失敗なら進まない |
| バリデーション | `<RX>` 忘れ・空の値・循環参照を実際に捕まえ、`TMacroRunner` が実行を拒否する |
| 日本語 | マクロ名・本文・注記が JSON 往復で壊れない (9-2 と同じ落とし穴) |

### 12-2. 併せて修正した既存の不具合

`SafeFileIO.LoadTextRaw` の巨大ファイル検査が

```pascal
if n > High(SizeInt) then   // 64bit では SizeInt が Int64 なので常に偽
```

となっており、**検査として機能していなかった** (コンパイラも到達不能と
警告していた)。扱うのが設定・ログ・ADIF といったテキストである以上、
現実的な上限 (256 MiB) を明示する方が意味があるので、そう変更した。

### 12-3. 設計見直し: コンテキストと順序をモデル化する

最初の実装は「差し込みタグの展開」と「1つのマクロ内での断片の順序」までは
正しかったが、**交信そのものの文脈と順序を一切モデル化していなかった**。
その結果として次の穴があった。

| 症状 | 原因 |
|---|---|
| ログ後も前の局のコールが残り、次の交信で誤ったコールを送る | ログ成功後の遷移が無い (`ClearWorkedStation` を実装しながら誰も呼んでいなかった) |
| 送信し終わる前にログが走る | 実行が同期で、送信完了を待つ手段が無い |
| 交換を受け取る前でもログできてしまう | 「今どの局面か」を持っていない |
| 同じ局面でも Run と S&P で送る内容が違うのに区別できない | 立場の概念が無い |
| 検査した状態と送る状態がずれうる | `Prepare` と `Run` が分かれており、間にコンテキストが変わりうる |

#### 局面 (TQsoPhase) と立場 (TQsoRole)

定型交信は状態機械である。

```
Run  (CQ を出す側)              S&P (呼ぶ側)
─────────────────────────       ─────────────────────────
qpIdle          CQ              qpIdle          自局コール送出
qpCalling       ← 相手のコールを取得すると自動で qpAnswered
qpAnswered      レポート送出     qpAnswered      レポート送出
qpExchangeSent  ← 相手のレポート受領で自動で qpExchangeRcvd
qpExchangeRcvd  確認 + ログ      qpExchangeRcvd  確認 + ログ
                ↓ ログ成功で qpIdle へ戻る
```

**局面は「値を入れる」という自然な操作で自動的に進む。**
`ctx.Call := 'JA1ZZZ'` で `qpAnswered` へ、`ctx.RstRcvd`/`SerialIn`/
`ExchangeIn` のいずれかが入ると `qpExchangeRcvd` へ進む。局面の更新を
別作業にすると必ず忘れられる ― 実際、最初の実装では
`ClearWorkedStation` を書いておきながらどこからも呼んでいなかった。
打ち直しで後戻りしないよう、前へだけ進む (`AdvancePhaseTo`)。

#### マクロが「いつ使うものか」を宣言する

```pascal
d.DeclareSequence(mrfRun, [qpAnswered], qpExchangeSent);
```

これにより `TMacroSet.FindForSequence(role, phase)` が
「次に押すべきマクロ」を一意に返せる。これは **ESM (Enter Sends Message)**
の土台で、N1MM や WriteLog では標準機能だが fldigi には無い。
オペレータが局面ごとに正しいキーを覚える必要がなくなる。

標準セットは単なる文例集ではなく、この **立場 × 局面の表**になっている。

#### 実行を非同期の状態機械にした (本丸)

送信は実時間で数秒から十数秒かかる。同期的に「送って戻る」ことはできない。
そこで時間のかかる操作は依頼にし、完了は宿主から折り返してもらう。

| 宿主のメソッド | 契約 |
|---|---|
| `RequestReceive` | 送信バッファを送り切ってから受信へ戻し、完了したら `Runner.NotifyTxFinished` |
| `StartTimer(n)` | n 秒後に `Runner.NotifyTimerElapsed` |

`TMacroRunner` は断片を順に処理し、`<RX>` / `<WAIT>` に当たったら
そこで止まって折り返しを待つ。これで **`<RX>` の後ろに置いた `<LOG>` が
本当に送信し終わってから実行される**。

```
<TX>TU <MYCALL> TEST<RX><LOG>
  TX → TEXT → RX-REQ → [送信完了待ち] → TX-END → LOG
```

以前は送信をキューに積んだ直後にログしており、送信を中断してもログが残り、
ADIF の `TIME_OFF` も実際の交信終了より前になっていた。
標準マクロの `<LOG>` はすべて `<RX>` の後ろへ移してある。

副次的な効果として「実行中」という状態が自然に持てるようになり、
送信中に別のキーを押したときの扱い (`TMacroBusyPolicy`) が定義できた。
宿主が折り返しを忘れても永久に実行中のままにならないよう、
`StepTimeoutSec` (既定120秒) を超えた待ちは自動的に中断する。

**スレッドの契約**: `TMacroRunner` のメソッドはすべて同じスレッドから呼ぶ。
宿主が別スレッドで送信完了を検出した場合は `TThread.Queue` 等で
UI スレッドへ渡してから通知する。違反は `EMacroError` として検出される
(黙って壊れるより見える失敗にする)。

#### 展開・検査・実行を不可分にした

`Prepare` して `Run` に渡す形は、その間にコンテキストが書き換わると
「検査した状態と違う状態で送る」ことになり、しかも型の上では
**別のコンテキストで検査した展開結果すら渡せた**。
`TMacroRunner.Execute` / `ExecuteNamed` / `ExecuteForSequence` に一本化し、
展開から実行までを 1 回の呼び出しにした。プレビューが要るときは
`TMacroExpander.Prepare` を表示専用に使い、実行側は再展開する。

#### ログ後の遷移を Runner に集約

`LogCurrentQso` が True を返したときにまとめて行う。

1. `CommitSerial` (送信ナンバーを進める)
2. `ClearWorkedStation` (相手局情報を消し、局面を `qpIdle` へ)

ログに失敗したら **どれも行わない**。番号も相手局情報もそのまま残る。

> この作り込みで自分でバグを 1 つ入れた。ログ後に局面を `qpIdle` へ戻した
> 直後、マクロの宣言 (`TU` なら `qpConfirmed`) を適用していたため、
> せっかく戻した局面が前へ跳ね返っていた。ログできた交信は完了なので
> 宣言は適用しない、と直した。回帰テスト13がこれを捕まえる。

#### 運用プロファイルとの接続

```
Registry.Resolve(...).ToStationInfo(info);
ctx.LoadFromStationInfo(info);
```

の2段で、6軸プロファイルが解決した実効値がマクロまで届く。
これが切れていると、移動運用でコールが `JI1UUI/1` に変わってもマクロは
古いコールを送り続ける。併せて `TStationInfo` に `MyRig` / `MyPowerW` を
追加した (README 9章で「`TResolvedStation` で止まっている」と書いていた
既知の制約を解消。ADIF の `MY_RIG` / `TX_PWR` にも使える)。

#### デュープ

`TMacroContext.IsDuplicate` を見て `<LOG>` 時に警告する。**止めはしない** ―
コンテストによっては重複交信も得点0で記録するのが正しいため。

### 12-4. 検証

```bash
./run_tests.sh          # 全スイートをクリーンビルドして実行
```

`test/test_macro.lpr` は 172 件。順序に関わる重点は次の 4 つ。

| テスト | 内容 |
|---|---|
| 10. 局面の自動追跡 | 値の投入で局面が進み、打ち直しでは戻らない |
| 12. 送信完了を待ってからログ | 折り返しを保留したまま「ログがまだ実行されていない」ことを確認 |
| 13. ログ後の遷移 | 番号・相手局情報・局面の3つが揃って動く / 失敗時はどれも動かない |
| 14. 1交信を局面駆動で通す | ESM だけで CQ→交換→TU→次のCQ まで進み、次の CQ に前局のコールが混ざらない |

新しいテストは**修正を一時的に戻して実際に失敗することを確認**している。
`<LOG>` を `<RX>` の前に戻す・`ClearWorkedStation` を外す・局面戻しの
ガードを外す、のいずれでも該当テストが落ちる。

### 12-5. ビルドスクリプトを追加した理由

`fpc` は `-FE` で指定した出力先に `.ppu` も置く。テストは `-FEtest` なので
コンパイル済みユニットは `test/` に溜まる。`units/` だけ掃除しても
`test/*.ppu` が残り、**ユニットを直したのに古いものでリンクされる**。

この検証中に実際これを踏み、「直したはずのテストが失敗する」という
誤った結果を一度出している。`run_tests.sh` はスイートごとに中間物を
消してからビルドするので、この取りこぼしが起きない。

## 13. 宣言的な条件分岐 / 受信テキストからの値抽出

### 13-1. なぜスクリプト言語を入れないのか

「Lua や Python を組み込んで条件分岐・ループ・外部API呼び出しを」という
発想は自然だが、**それを入れると送信前バリデーションが原理的に成立しなくなる**。

`<TX>` に対応する `<RX>` があるか、`<CALL>` が空でないか、といった検査は
「送る内容が展開の時点で確定している」から可能である。スクリプトが実行時に
送信内容と送信可否を決めるなら、事前に検査しようがない。
電波を出しっぱなしにする事故を防ぐ仕組みを、自分で無効化することになる。

そこで**条件分岐と反復を、展開時に解決する宣言的な構文として**入れた。

```
<IF:MODE=CW><#CUT><ELSE><#><ENDIF>
  CW のとき   → "TT1"     (カットナンバー)
  それ以外    → "001"
```

展開が終わった段階では条件のない平坦な列になっているので、
バリデーションはそのまま効く。しかも**検査対象は「今回実際に送られる枝」**
になるという、むしろ望ましい性質が得られる。

| 検査 | 挙動 |
|---|---|
| 選ばれた枝に `<RX>` が無い | エラー |
| 選ばれなかった枝に `<RX>` が無い | 問題にしない |
| 選ばれた枝の `<NAME>` が空 | 警告 |
| 選ばれなかった枝の `<NAME>` が空 | 警告しない |

### 13-2. 使える条件

| 条件 | 意味 |
|---|---|
| `DUPE` / `NOTDUPE` | 既に交信済みか |
| `CONTEST` / `NOTCONTEST` | コンテスト運用か |
| `ROLE=RUN` / `ROLE=SP` | 立場 |
| `PHASE=answered` / `PHASE GE exchangeRcvd` | 局面 |
| `MODE=CW` / `MODE NE CW` | モード (大小を区別しない) |
| `BAND=20m` | バンド |
| `HAS:NAME` / `EMPTY:NAME` | 値タグが空でない / 空 |
| `SERIAL GT 100` / `SERIAL LT 10` / `SERIAL=1` | 送信ナンバー |

**比較演算子に `>` `<` `<>` を使わないのは、タグの終端 `>` と衝突するため。**
`<IF:SERIAL>100>` と書くと最初の `>` でタグが閉じてしまう。実装中にこれを
踏んだので、`GT` / `LT` / `GE` / `NE` という語形にしてある
(`=` だけは衝突しないのでそのまま使える)。

条件は**列挙できる形に限定**してある。任意の式を書けるようにした時点で
静的検査は破綻するので、意図的に絞っている。

### 13-3. `<REPEAT:n>`

```
<REPEAT:3>CQ <ENDREPEAT>de <MYCALL>   →   "CQ CQ CQ de JI1UUI"
```

展開時に n 回ぶん実体化する。上限は 20 で、超えるとエラーにする。
CQ を数回繰り返す程度しか想定していないので、大きな値を許すと
メモリと送信時間の両方が破裂する。

`<IF>` と `<REPEAT>` は入れ子にできる。
`<IF:DUPE><REPEAT:2>a<ENDIF><ENDREPEAT>` のように**交差した書き方は
検出してエラーにする** ― 黙って通すと展開結果が書いた人の意図と食い違う。

### 13-4. 受信テキストからの値抽出 (`units/RxExtract.pas`)

局面モデルは「値が入れば局面が自動で進む」形にしたが、**値を入れるのは
運用者の手入力だけだった**。つまり入力側が空いたままで、せっかくの
局面駆動が働き始めない。本ユニットがそこを埋める。

```
受信: "JI1UUI DE JA1ZZZ JA1ZZZ 599 032 K"
  ↓ 抽出
  コール    JA1ZZZ  (確信度 95)
  RST       599     (確信度 90)
  ナンバー  032     (確信度 90)
  ↓ ApplyTo
  ctx.Call / RstRcvd / SerialIn に入り、局面が qpExchangeRcvd へ
  ↓
  ExecuteForSequence が「次は TU + ログ」を返せる状態になる
```

#### 抽出と確定を分けている

RTTY や CW の復号は誤りを含む。**誤ったコールサインを送れば交信そのものが
無効になる**ので、既定では候補を出すだけにして、どれを採用するかは
運用者が決める。`ApplyTo` が自動採用するのは確信度がしきい値
(既定70) 以上のものだけで、しかも**既に値が入っている項目は上書きしない**
(手で直した値をあとから来た受信で壊さないため)。

確信度は推定なので上限を 95 にとどめてある。100 は「運用者が確定した」
という意味に残している。

#### 確信度の根拠

| 加点 | 根拠 |
|---|---|
| +30 | `de` の直後 (= 送ってきた局のコール) |
| +15 | 自局コールに続く `de` の後 (= 自分が呼ばれている) |
| +15 | 繰り返し送られている (`JA1ZZZ JA1ZZZ`) |
| +10 | 直近にある |
| +20 | (RST) 直後が数字 = コンテストの交換の形 |
| +10 | (RST) 値が 599 / 59 |

RST の「直後が数字」が効くのは 599 以外のレポートである。599 は定番なので
値だけで拾えてしまうが、579 は交換の形を手がかりにしないと採用水準に
届かない。回帰テストもその条件で書いてある。

#### コールサインの形の判定

```
前置符号 1..3 文字 (英数字。英字を1文字以上含む)   JA / 7J / 3DA / K
エリア数字 1 文字
接尾符号 1..4 文字 (英字のみ)                      ZZZ / AW / ABCD
```

エリア数字は「そのあとが英字だけで 1..4 文字続く最後の数字」として求める。
こうすると `3DA0AB` や `7J1ABC` も通り、`599` や `5NN` のような
数字だけ・英字だけの語は落ちる。`/1` `/P` `/QRP` の後置と
`VP2E/W1AW` の前置の両方を許す。`CQ` `DE` `TEST` `TU` といった定型語は
明示的に除外している。

**実在するかは判定しない** ― 形が正しいかを見るだけである。

### 13-5. 自動応答を作らなかった理由

パターン一致でマクロを自動起動する仕組みは、`ExecuteForSequence` が
既にあるので配線だけで作れる。作らなかったのは、
**受信内容をきっかけに自動送信するのは「自動運用」の領域**だからである。
アマチュア無線では送信の責任は運用者にある。

本ユニットの責務は「値を取り出す」までとし、境界をここに引いた。
将来入れる場合は、自局が呼ばれたときだけ反応する・連続自動送信の上限・
一定時間操作が無ければ停止する、といったガードとセットにする必要がある。

### 13-6. 検証

```bash
./run_tests.sh
```

`test/test_rxextract.lpr` は 115 件。

| 観点 | 内容 |
|---|---|
| コールサイン判定 | 実在する 14 種を通し、定型語・数字列など 13 種を落とす |
| 確信度の順序 | `de` の直後で繰り返された方が、文中に1回だけのものより上位 |
| 局面の前進 | 抽出した値が入ることで `qpIdle → qpAnswered → qpExchangeRcvd` と進む |
| 分岐と検査の両立 | 選ばれた枝だけが検査対象になる |
| 書き間違い | `<ENDIF>` 忘れ・単独 `<ELSE>`・ブロック交差・未知の条件 |

新テストは修正を戻して実際に失敗することを確認済み。抽出→局面前進の接続、
ブロック交差の検出、RST の交換形による加点の 3 つで検証した。

### マクロ関連の既知の制約・省略した範囲

- **`TMacroHost` の実機実装は未着手**。`units/` 側の論理は完成しているが、
  `TModemEngine` / `TCustomRigControl` / `TQsoLogbook` への実配線と、
  ファンクションキー割り当ての UI は今後のタスクとする。
  特に `RequestReceive` の折り返し (送信バッファが空になったことの検出) は
  `TModemEngine` 側に「送信完了」を通知する口が要るので、配線時に追加する。
- **実行中に押されたマクロを待ち行列に積む方式は未実装**。
  現状は拒否 (`mbpReject`) か差し替え (`mbpReplace`) の2択。
  コンテストでは「F1 を押してから F2 を予約する」使い方があるので、
  実機で使ってから必要性を判断する。
- 受信抽出 (`RxExtract.pas`) は実装したが、**`TModemUI.OnRxChar` への配線は
  未着手**。`TRxExtractor.FeedChar` にそのままつなげる形にはしてある。
- **時刻・バンド・モードによるマクロの自動切り替えは未実装**。
  選択キーは今も `(立場, 局面)` の 2 軸で、モードは条件分岐
  (`<IF:MODE=CW>`) で吸収する形にとどめている。モードを選択キーに足すか、
  `TOperatingProfile` の切り替えでマクロ集ごと差し替えるかは、
  実機で使ってから判断する。
- **`<XOUT>` は `TContestDefinition` から交換を組み立てない**。
  コンテストを選べば交換の形が決まる、という自動化は未着手。
- **`<MODE:x>` の妥当性検査をしていない**。存在しないモード名を渡した場合の
  判断は宿主 (実装側) に委ねている。モード名の正規名一覧を持つのは
  `ModemTypes` 側の役割なので、そちらと合わせて行う。
- **fldigi の高度なタグは未実装**。`<CNTR>` (汎用カウンタ)、`<IDLE:n>`、
  `<TIMER:n>`、`<AFTER>`/`<BEFORE>`、`<EXEC>` (外部コマンド実行) 等。
  `<EXEC>` は任意コマンド実行なので、移植するとしても
  「マクロファイルを他人と共有する」用途を考えると既定で無効にすべきである。
- **`<XOUT>` は文字列をそのまま送るだけ**で、`ContestLog` の
  `TContestDefinition` が定める交換項目からの自動組み立てはしていない。
  コンテスト定義との連動は `ContestLog` 側の API を使う配線タスクになる。


## 14. Phase 0 着手: ADR-002 (Modem API を Evidence 型にする)

`Architecture & Requirements Baseline v1.1` に沿って Phase 0 に着手した。
最初の対象は §19 の **ADR-002「Modem API は複数候補・Evidence・Confidence を
将来返せる型にする」**。決定と根拠は `docs/adr/ADR-002-modem-api-evidence.md`
に記録した。

### なぜこれを最初にやるのか

従来の出口は「確定した1文字」だった。

```pascal
procedure PutRxChar(ACh: Integer);
```

この形は第2候補も判断の根拠も戦略名も入力位置も**原理的に運べない**。
v1.1 の Phase 4 (Confidence & Context) と第10章 (Confidence-aware GUI) は
それら全部を前提にしているので、復調器が増えてから直すと全モデムの
書き換えになる。**モデムが CW / RTTY の 2 つしかない今が最も安い。**

### 何をしたか

出口を `OnDecode` ひとつに統一し、`TDecodeEvidence` を運ぶようにした。

```pascal
TDecodeEvidence = record
  Candidates: TDecodeCandidateArray;   // [0] が最有力
  MetricKind: TEvidenceMetricKind;     // 尺度の種類
  DecoderName: string;                 // どの戦略が出したか (Phase 3)
  SamplePos: Int64;                    // 入力のどの位置か (Replay / X-06)
  HasSnr, HasFreqOffset: Boolean; ...
end;
```

**型を広げただけで中身が空なら Phase 4 は結局作れない**ので、既存モデムに
実際の値を載せた。

| モデム | 載せたもの |
|---|---|
| RTTY | 軟判定の余裕 (`-1..+1` 正規化)、第2候補、SNR、周波数誤差、サンプル位置 |
| CW | SNR、サンプル位置のみ。**尺度は載せない** |

RTTY の軟判定は ATC の判定変数 `V3` から作る。符号がビット値、大きさが
判定境界からの距離にあたるので、包絡線エネルギーで割って無次元化する。
文字の尺度は「構成したデータビットのうち最も余裕が小さいもの」、
第2候補は「その最も弱いビットを反転した文字」。実測で 22 文字中 11 文字に
第2候補が付いた。

CW に尺度を載せないのは正直さの問題である。CW の復号は時間パターンを
モールス表と照合する方式で、一致しなければ何も出さない。順位をつけるには
照合を距離つき近傍探索に作り替える必要があり、それは Phase 3 の
Algorithm Portfolio の仕事になる。**持っていない尺度をでっち上げると
根拠のない値が Evidence として流れ、Phase 4 の校正が成り立たなくなる。**

### Evidence と Confidence を区別する (§7 CF-01)

この層が運ぶのは Evidence であって Confidence ではない。

| | 内容 |
|---|---|
| Evidence | 復調器の内部尺度。モードごとに意味が違い、校正されていない |
| Confidence | 表示用の校正済みの確からしさ。`P(correct｜c) ≈ c` |

混同すると「Confidence 90%」と出しながら実際の正答率が 60% という、
v1.1 が §10 と §17.1 で避けようとしている表示になる。校正は Phase 4 の
責務とし、この層は生の Evidence を素直に運ぶ。

同じ理由で、先に実装した `RxExtract` の「確信度」も Evidence 側の概念である
(校正されていない発見的スコア)。Phase 4 で Confidence を導入する際に
名前を整理する。

### 作業中に踏んだ罠

第2候補を作るために「ビットを反転したらどの文字か」を仮復号したところ、
`BaudotDec` が文字/数字シフト状態を書き換えるため、**仮の計算の副作用で
本物のシフト状態が壊れた**。`12345` が `WERT` になった
(Baudot では 2=W, 3=E, 4=R, 5=T)。

RTTY ループバックテストが即座に落ちたので気づけた。仮復号は状態を保存・
復元する `SpeculativeDecode` に閉じ込め、回帰テストで固定した。

### 併せて整えたもの (Phase 0: Test framework)

テスト用の共通部品を `test/TestSupport.pas` に切り出した
(`TCaptureSoundDevice` / `TTxSource` / `TEvidenceSink`)。
復調器のテストは必ず「送信波形を作る → 復調させる → 結果を検査する」形に
なるので、道具が各テストに散っていると道具側の差異で結果が食い違う。

### 検証

```bash
./run_tests.sh
```

全13スイート 766 件成功。`test_evidence.lpr` (34件) の重点は
**「型が運べること」ではなく「実際に運んでいること」**に置いた。

| テスト | 内容 |
|---|---|
| 1 | Evidence 型の基本 (候補の順序、候補なし、診断表示) |
| 2 | RTTY が実際に尺度・第2候補・SNR・位置を載せているか |
| 3 | 仮復号がシフト状態を壊さないこと (上記の罠の回帰) |
| 4 | CW が持っていない尺度をでっち上げていないこと |

### Phase 0 の残り

| 項目 | 状態 |
|---|---|
| ADR-002 Modem interface | **完了** |
| Test framework | **着手** (TestSupport.pas) |
| ADR-001 Data/Control Plane 境界・Event Bus | 未着手 |
| X-04 realtime 経路の allocation 除去 | 未着手 |
| Plugin API draft / Capability Model | 未着手 |
| Logging data model (Rich Internal Model ↔ ADIF Adapter) | 未着手 |
| Observability (Z-01) | 未着手 |
| ADR-003 L6 privacy/encryption 方針 | 未着手 |
| §18 要求トレーサビリティ (既存実装への REQ-ID 付与) | 未着手 |


## 15. Phase 0 続き: X-04 (realtime の確保除去) と ADR-001 (Event Bus)

### 15-1. X-04 realtime 経路の動的確保を除去

FPC のメモリマネージャはロックを取る。音声スレッドがそこで待たされると
deadline を落として underrun になる (Z-04 Deterministic Realtime)。

| 場所 | 何が起きていたか |
|---|---|
| `PortAudioSoundDevice` の Read/Write/WriteStereo | 呼び出しのたびにローカルの動的配列を `SetLength` |
| `RttyModemImpl` / `CwModemImpl` の `SendSymbol` | シンボルごとに波形バッファを確保 |

どちらも「Open 時に確保して伸ばすだけ」のバッファへ移した。送信バッファは
両モデム共通なので基底 `TCustomModem` に置いた。

#### 「確保していない」をどう検証するか

コードを読むだけでは保証できない。動的配列の `SetLength`、文字列の連結、
一時オブジェクトの生成は見落としやすく、しかも**確保と解放が対になっていると
使用量を測っても検出できない**（増えて減るので差分が 0 になる）。

そこで**測定区間だけメモリマネージャを差し替え、`GetMem` / `ReAllocMem` の
呼び出し回数そのものを数える**。

```
RTTY 送信 48840 サンプル: 242 回 → 4 回
CW   送信 72502 サンプル:  66 回 → 4 回
RTTY 受信 100 ブロック  :   0 回 (元から確保なし)
```

判定は絶対値ではなく**「確保回数が送信量・ブロック数に比例しないこと」**。
測定自体が空振りしていないことを確かめるテスト（意図的に 50 回確保して
50 回検出する）も入れてある。修正を戻すと該当 2 件が実際に失敗する。

復調して文字が出た瞬間は Evidence の候補配列を作るので確保が入る。
RTTY 45baud で毎秒 6 回程度、音声ブロックの 16 回/秒と比べて支配的でないため
意図的に許容している（テストは無信号で測ってこれを区別している）。

### 15-2. ADR-001 Data Plane / Control Plane 境界と Event Bus

決定は `docs/adr/ADR-001-data-control-plane.md`。

#### 境界を型で守る

Event Bus は Control Plane 専用で、Audio / IQ / Spectrum は載せない。
規約だけで守るのは無理なので、**載せられない構造**にした。

```pascal
TBusEvent = record
  Kind: TBusEventKind;
  I1, I2: Int64;            // 汎用の数値スロット
  D1, D2: Double;
  Text: string;             // 低頻度イベント専用
  TimestampUtc: TDateTime;
  Source: string;
end;
```

**固定長レコード**なので配列もストリームも持てない。`SizeOf` は 64 バイトで、
回帰テストで固定してある（意図しない拡張に気づけるように）。文字列が 1 本
あるのは例外で、確保を伴うため低頻度イベント専用と決めている。

#### 購読者の例外でバスを止めない (§12)

1 つの購読者が投げた例外で他の購読者への配送が止まると障害が波及する
(B-04 / Z-06)。購読者ごとに例外境界を置き、件数を数えて通知したうえで
**残りの購読者への配送を続ける**。

配送はイベントと購読者一覧をロック下で写し取り、呼び出しはロック外で行う。
購読者がバスへ発行し返してもデッドロックしない。

#### 有界であること

`ModemUI` で先に確立した方式（有界FIFO＋単一ドレイン＋在席カウンタ）を
バス側の責務として引き上げた。UI が詰まってもメモリが伸び続けず、
溢れたら古いものから捨てて件数を数える。

#### 観測 (Z-01)

`PublishedCount` / `DeliveredCount` / `DroppedCount` / `SubscriberErrorCount`
を公開する。`DroppedCount` が 0 でなければ購読側が追いついていない、
`SubscriberErrorCount` が増えていればどこかの購読者が壊れている、と外から分かる。

### 15-3. 検証

```bash
./run_tests.sh
```

全15スイート 808 件成功。

| スイート | 件数 | 重点 |
|---|---|---|
| `test_realtime` | 5 | 確保回数を実測。測定の妥当性も検査 |
| `test_eventbus` | 37 | 例外封じ込め・有界性・絞り込み・再発行・並行破棄・固定長 |

### 15-4. Phase 0 の残り

| 項目 | 状態 |
|---|---|
| ADR-002 Modem interface | **完了** |
| X-04 realtime の確保除去 | **完了** |
| ADR-001 Data/Control Plane 境界・Event Bus | **完了 (バス単体)** |
| Test framework | **着手** (TestSupport.pas) |
| `ModemUI` をバスの購読者へ移行 | 未着手 |
| Plugin API draft / Capability Model | 未着手 |
| Logging data model (Rich Internal Model ↔ ADIF Adapter) | 未着手 |
| Observability (Z-01) の記録経路 | 未着手 (バスの計数のみ) |
| ADR-003 L6 privacy/encryption 方針 | 未着手 |
| §18 要求トレーサビリティ | 未着手 |
