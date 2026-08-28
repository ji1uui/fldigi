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
│   ├── PortAudioSoundDevice.pas  実サウンドカードI/O実装 (fldigi: sound.h SoundPort)
│   ├── HamlibBindings.pas        Hamlib C API の直接バインディング
│   ├── RigControlIntf.pas        無線機CAT制御の抽象基底 TCustomRigControl
│   ├── HamlibRigControl.pas      Hamlib具象実装 THamlibRigControl
│   └── RigPollThread.pas         リグ状態監視スレッド TRigPollThread (fldigi: hamlib_loop)
├── forms/                  -- LCL (GUI) を使った実装例
│   ├── UnitMainForm.pas    TForm 継承のメインフォーム実装例
│   ├── DemoModemApp.lpr    デモアプリのエントリポイント
│   └── DemoModemApp.lpi    Lazarus プロジェクトファイル
└── test/
    ├── test_modem.lpr       GUIなしの結合テスト (スレッド安全性を検証)
    ├── test_rtty_cw.lpr     RTTY/CW 送受信ループバックテスト
    ├── test_portaudio.lpr   PortAudio バインディングの動作確認テスト
    └── test_rigcontrol.lpr  Hamlib CAT制御の動作確認テスト (疑似CAT通信)
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
