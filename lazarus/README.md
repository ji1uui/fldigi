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
│   ├── ModemDSP.pas        共通DSPヘルパー (複素数演算/IIRフィルタ/移動平均)
│   ├── MorseTable.pas      モールス符号テーブル (fldigi: morse.h/.cxx cMorse)
│   ├── RttyModemImpl.pas   RTTYモデム具象実装 TRttyModem (fldigi: rtty.cxx)
│   ├── CwModemImpl.pas     CWモデム具象実装 TCwModem (fldigi: cw.cxx)
│   ├── PortAudioBindings.pas     PortAudio C API の直接バインディング
│   └── PortAudioSoundDevice.pas  実サウンドカードI/O実装 (fldigi: sound.h SoundPort)
├── forms/                  -- LCL (GUI) を使った実装例
│   ├── UnitMainForm.pas    TForm 継承のメインフォーム実装例
│   ├── DemoModemApp.lpr    デモアプリのエントリポイント
│   └── DemoModemApp.lpi    Lazarus プロジェクトファイル
└── test/
    ├── test_modem.lpr      GUIなしの結合テスト (スレッド安全性を検証)
    ├── test_rtty_cw.lpr    RTTY/CW 送受信ループバックテスト
    └── test_portaudio.lpr  PortAudio バインディングの動作確認テスト
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
