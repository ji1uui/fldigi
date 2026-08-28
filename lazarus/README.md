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
│   └── NullModemImpl.pas   最小実装サンプル TNullModem (fldigi: nullmodem.h/.cxx)
├── forms/                  -- LCL (GUI) を使った実装例
│   ├── UnitMainForm.pas    TForm 継承のメインフォーム実装例
│   ├── DemoModemApp.lpr    デモアプリのエントリポイント
│   └── DemoModemApp.lpi    Lazarus プロジェクトファイル
└── test/
    └── test_modem.lpr      GUIなしの結合テスト (スレッド安全性を検証)
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
(複素数演算・1次IIRローパス `TComplexLowpass`・移動平均 `TMovingAverage`・
`DecayAvg`/`ClampF`) と `units/MorseTable.pas` (`cMorse` 相当の
モールス符号テーブル) に切り出しています。

### RTTY (`TRttyModem`, fldigi: `class rtty`)

| fldigi (C++)                          | Lazarus (Pascal)                         |
|----------------------------------------|-------------------------------------------|
| `rx_bit()` / ステートマシン (IDLE/START/DATA/STOP) | `RxBit` / `TRttyRxState`               |
| mark/space 履歴の位相差による AFC      | `FMarkHistory`/`FSpaceHistory` + `Ferr` 計算 |
| `rparity`/Baudot 5bit エンコード       | `RParity` / `BaudotEnc`                   |
| `Metric()` (SNR ベース信号品質)        | `ComputeMetric`                           |

- fftfilt (FFTオーバーラップ加算フィルタ) は移植スコープ外とし、
  `TComplexLowpass` (1次IIR) で代替しています。
- 実装済み: Baudot 5bit、Mark/Space FSK 復調、AFC (周波数誤差の自動追従)、
  パリティチェック。

### CW / モールス信号 (`TCwModem`, fldigi: `class cw`)

| fldigi (C++)                              | Lazarus (Pascal)                     |
|---------------------------------------------|-----------------------------------------|
| `handle_event()` (RS_IDLE/RS_IN_TONE/RS_AFTER_TONE) | `HandleEvent` / `TCwRxState`     |
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

### 結合テスト (`test/test_rtty_cw.lpr`)

`TCaptureSoundDevice` で送信波形をメモリ上にキャプチャし、別インスタンスの
`RxProcess()` へそのまま流し込む「送信 → 復調」のループバックテストです。
GUI (LCL) には依存しません。

```bash
fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_rtty_cw test/test_rtty_cw.lpr
./test/test_rtty_cw
```

実行結果 (RTTY: 45.45baud/85Hz, CW: 12WPM):

```
=== RTTY 送受信ループバックテスト ===
送信文字列: HELLO WORLD 12345
  復調結果      : HELLO WORLD 12345<CR><LF>
  [OK] 送信文字列が復調結果に含まれている

=== CW 送受信ループバックテスト ===
送信文字列: CQ CQ DE TEST 599 K
  復調結果      :  CQ CQ DE TEST 599 K 
  [OK] 復調結果に "CQ" が検出された
```

※ CW のAGC (`agc_peak`/`noise_floor`) は `rx_init()` 直後 `agc_peak=0`
から始まる (fldigi と同じ挙動) ため、テストでは実運用同様に受信開始前の
無音(+微弱ノイズ)区間を先頭に加えてAGCを馴染ませています。
