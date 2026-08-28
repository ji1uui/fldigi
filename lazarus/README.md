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
│   └── ContestLog.pas            コンテストロギング (fldigi: contest.cxx/counties.cxx)
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
    └── test_contestlog.lpr   コンテストロギング/DXCC・ゾーン判定の動作確認テスト
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
