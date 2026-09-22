{ ============================================================================
  PskModemImpl.pas

  BPSK (PSK31 / PSK63 / PSK125) モデム。
  fldigi の src/psk/psk.cxx (class psk) の BPSK 経路を移植した。

  PSK31 とは何をしているか
  ----------------------------------------------------------------------------
  搬送波の**位相を反転させるかどうか**で 1 ビットを送る差動 BPSK である。

      位相が変わらない -> 1
      位相が反転する   -> 0

  差動にしてあるので、受信側は搬送波の絶対位相を知らなくてよい。
  直前の記号との位相差だけを見る。

  文字は varicode (PskVaricode.pas) で符号化する。0 が 2 つ続くのが
  文字の区切りなので、符号そのものには 00 が現れない。連続した 0 は
  「位相反転が続く」= 送信が続いていることを意味し、これが待機信号にも
  文字境界にもなっている。

  受信経路
  ----------------------------------------------------------------------------
      入力 -> NCO で中心周波数へ移す
           -> fir1 (間引き。symbollen/16 に 1 個へ落とす)
           -> fir2 (整合フィルタ。1 記号 16 標本のまま)
           -> ビットクロック復元 (下記)
           -> 記号ごとに位相差を取り、ビットへ
           -> varicode を組み立てて文字へ

  ビットクロック復元
  ----------------------------------------------------------------------------
  整合フィルタを通った信号の**大きさ**は、記号の中央で山になり境目で
  谷になる。この形を 16 個の桶 (FSyncBuf) に繰り返し描き、前半の山と
  後半の山の差を取る。差が正なら前半が大きい = 位置がずれているので
  クロックを遅らせ、負なら速める。差を和で割っているので、信号の
  大きさそのものには依存しない。

  fldigi と変えたところ / 変えなかったところ
  ----------------------------------------------------------------------------
  - 変えていない: フィルタ係数、ビットクロック復元、位相からビットへの
    変換、DCD の判定、品質 (metric) の計算。
  - 変えた: 復号結果を文字ではなく Evidence として上げる (ADR-002)。
    軟判定の尺度として、その文字を構成したビットのうち **最も判定境界に
    近かったもの**の余裕 |cos(位相差)| を載せる。1 に近いほど確か、
    0 に近いほど際どい。文字は 1 ビットでも誤ると壊れるので、
    最も弱いビットが文字全体の確からしさを決める。
  - SNR は載せていない。fldigi の metric は品質ベクトルの二乗ノルムを
    100 倍したもので、dB の SNR ではない。根拠のない値を Evidence に
    流すと Phase 4 の校正が成り立たなくなるので、持っていないものは
    持っていないと表明する (README 14 章と同じ方針)。

  未実装 (意図的)
  ----------------------------------------------------------------------------
  - QPSK / PSKR (FEC 付き) / 8PSK / 16PSK。畳み込み符号と Viterbi 復号が
    要る。Baseline の Phase 2 が求めているのは PSK31/63 なので、
    ここでは BPSK に絞った。
  - 複数搬送波 (PSK125R 系)、IMD 測定、PSK ブラウザ。

  AFC (MDM-006)
  ----------------------------------------------------------------------------
  記号間の位相差から周波数誤差を測る。判定した位相 (0 か Pi) からのずれが
  そのまま「1 記号のあいだに余計に回った角度」なので、標本化速度と記号長で
  割れば Hz になる。効かせ方は `FreqTracker` に預ける。

  **fldigi と違うところが 1 つある。** あちらは

      error = phase - bits * M_PI / 2;
      if (error < -M_PI/2 || error > M_PI/2) return;

  と書く。phase は [0, 2*Pi) に畳んであるので、位相が変わらない記号
  (bits = 0) で誤差がわずかに負のとき phase は 2*Pi - e となり、
  error = 2*Pi - e が門に掛かって **捨てられる**。同じ記号で誤差が正なら
  通る。つまり bits = 0 の測定は片側しか採らない。

  これは単に測定を減らすだけではない。誤差がゼロでも、雑音で正に振れた
  ぶんだけが採られるので、**周波数が下へ引かれ続ける**。
  ここでは誤差を (-Pi, Pi] へ畳んでから使う。畳めば判定の規則そのものが
  誤差を [-Pi/2, Pi/2) に閉じ込めるので、fldigi の門は不要になる
  (門の残り半分 `fabs(error) < sc_bw` も、測れる上限が sc_bw/4 なので
  最初から当たらない)。

  「ずれが無いときに動かない」ことは試験で見る。畳みを外すと落ちる。

  捕捉範囲は sc_bw/4 で頭打ちになる (実測)
  ----------------------------------------------------------------------------
  1 記号で測れる誤差の上限は、位相の折り返しの都合で sc_bw/4 = 記号速度/4
  である (PSK31 で 7.8 Hz、PSK63 で 15.6 Hz)。**これは追尾を速くしても
  超えられない** ―― 大きく外れた静的な周波数差 (0 サンプル目から一定) は、
  AFC の有無にかかわらずそこで復号そのものが壊れる。実測 (PSK31、無雑音):

      静的なずれ    AFC 無し        AFC 有り
      6 Hz         CER 0.000       CER 0.000  (AFC は要らない)
      7 Hz         CER 0.643       CER 0.000  (**AFC が肩代わりする** 唯一の帯)
      8 Hz 以上     CER 0.857      CER 0.857  (両方とも壊れる。同じ文字化け)

  AFC が効くのは「復号はぎりぎり保てるが、そのままでは少しずつ外れて壊れる」
  という狭い帯だけである。8 Hz を境に、復号自体が最初の記号から壊れるので
  AFC には誤差を測る材料が無い。PSK63 でも同じ形で境目が 14→15 Hz に伸びる
  (境目は sc_bw/4 に比例する)。

  一方、**ロックした状態からのゆっくりしたドリフトには強い** ―― 瞬間ごとの
  変化が sc_bw/4 の中に収まっていれば、頭出しの静的なずれとは別の問題になる。
  実測では 7.86 秒で 40 Hz (5.1 Hz/秒) までは本文が割れずに読めたが、
  50 Hz (6.4 Hz/秒) で読めなくなった。この 60 Hz ドリフト条件
  (test_regression / test_vectors の vkFrequencyDrift、7.6 Hz/秒) は
  この上限のすぐ外側にあり、**AFC を入れても入れなくても CER は変わらない
  (実測 0.786)** ―― PSK に AFC が無いからではなく、位相差判別器という
  方式そのものの捕捉限界である。RTTY のように周波数領域で探す AFC を
  持たない fldigi の PSK と同じ制約なので、既知の限界として扱う
  (test_regression.lpr の CeilingFor を参照)。
  ============================================================================ }
unit PskModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP,
  PskVaricode, DecodeEvidence, FreqTracker;

const
  PSK_SAMPLE_RATE = 8000;        // fldigi: samplerate = 8000
  PSK_FIRLEN = 64;               // fldigi: #define FIRLEN 64
  { ビットクロック復元に使う桶の数。fldigi: syncbuf[16] }
  PSK_SYNC_BUCKETS = 16;
  { 品質の平滑化。fldigi: #define SQLDECAY 20 }
  PSK_SQL_DECAY = 20;
  { 送信の頭と尻尾に置く記号の数。 }
  PSK_PREAMBLE_SYMBOLS = 32;
  PSK_POSTAMBLE_SYMBOLS = 32;

  { AFC が指令周波数から離れてよい上限 [Hz] (両側)。

    PSK31 の占有幅は 31 Hz なので、100 Hz は隣の隣まで離れる量である。
    追尾に要るぶんは十分あり、乗り移りは防げる。送信周波数も一緒に動く
    (周波数ロックが無ければ) ので、これは **送信が指令からどこまで
    離れうるかの上限**でもある。 }
  PSK_AFC_RANGE_HZ = 100.0;

  { 追尾を許す品質の下限。fldigi: if (afcmetric < 0.05) return。
    品質は位相差が 0 か Pi に揃っている度合い (|quality|^2) で、
    雑音だけなら 0 に近い。**これが無いと雑音だけの区間でも周波数が
    酔歩する。** DCD は Squelch の既定 (0 = スケルチなし) では
    ほぼ立ちっぱなしになるので、DCD だけでは止められない。

    実測 (速い設定、5 秒の雑音のみ、Z-05 のため乱数種固定):
    この門を外すと 155 回補正がかかり −12.8 Hz 動く。門があれば
    品質が一度も 0.05 に届かず、補正 0 回・0.0000 Hz のまま
    (test_afc の TestNoiseNoWander)。

    **この門はただの安全装置ではなく、捕捉範囲とのぶつかり合いでもある。**
    門を外すと、PSK31 は既知の限界の条件 (60 Hz ドリフト、sc_bw/4 を
    大きく超える) でもこの特定の試行では読めてしまう (CER 0.786→0.000)。
    品質の低い測定まで拾うことで捕捉範囲の外にも手が伸びる、ということ
    だが、その代償が上の雑音の酔歩である。つまり「門を緩めれば捕捉範囲が
    広がる」は事実だが、雑音免疫と引き換えになる ―― ここでは雑音免疫を
    優先した (無信号時に周波数が動くほうが実害が大きい)。将来もっと
    広い捕捉範囲が要るなら、品質の門を緩めるのではなく、RTTY のような
    周波数領域の探索を別の手段として足すべきである。 }
  PSK_AFC_MIN_QUALITY = 0.05;

  { 追尾の速さ。0 = 遅い / 1 = ふつう / 2 = 速い。
    利得は 1 / (dcdbits / 2^speed) で、時定数はおよそ
    1.024 / 2^speed 秒になる (dcdbits / 記号速度 がどのモードでも 1.024 秒)。 }
  { その品質のならし段数。fldigi: decayavg(afcmetric, norm(quality), 50) }
  PSK_AFC_METRIC_DECAY = 50;

  PSK_AFC_SPEED_SLOW = 0;
  PSK_AFC_SPEED_MEDIUM = 1;
  PSK_AFC_SPEED_FAST = 2;
  PSK_AFC_DEFAULT_SPEED = PSK_AFC_SPEED_MEDIUM;

type
  EPskModemError = class(Exception);

  { TPskModem
    ---------------------------------------------------------------------
    fldigi: class psk : public modem (BPSK 経路のみ) }
  TPskModem = class(TCustomModem)
  private
    // --- 諸元 (モードで決まる) ---
    FSymbolLen: Integer;         // fldigi: symbollen (1 記号のサンプル数)
    { fldigi: dcdbits。DCD の窓であると同時に **AFC の利得の逆数** でもある
      (あちらは freqerr = error / dcdbits)。モードごとに 32 / 64 / 128 で、
      記号速度 31.25 / 62.5 / 125 ボーに対して dcdbits / 記号速度 は
      どれも 1.024 秒になる ―― 値の本体は「約 1 秒の時定数」である。 }
    FDcdBits: Integer;
    FUseCoreFilter: Boolean;     // fldigi: fir_type == PSK_CORE

    // --- 受信 ---
    FRxPhaseAcc: Double;         // fldigi: phaseacc[0] (rx 側 NCO)
    FFir1: TFirFilter;           // fldigi: fir1[0] (間引き)
    FFir2: TFirFilter;           // fldigi: fir2[0] (整合)
    FPrevSymbol: TComplex;       // fldigi: prevsymbol[0]
    FShreg: LongWord;            // fldigi: shreg (varicode 組み立て)
    FBitClk: Double;             // fldigi: bitclk
    FSyncBuf: array[0..PSK_SYNC_BUCKETS-1] of Double;  // fldigi: syncbuf[16]
    { fldigi: phase。直前の記号との位相差。AFC もここから誤差を作る。 }
    FPhase: Double;
    FBits: Integer;              // fldigi: bits (0 または 2)
    FDcdShreg: LongWord;         // fldigi: dcdshreg
    FDcd: Boolean;               // fldigi: dcd
    FDcdOffCounter: Integer;     // fldigi: dcdOFFcounter
    FQuality: TComplex;          // fldigi: quality
    FAverageAmp: Double;         // fldigi: averageamp

    // --- AFC (MDM-006) ---
    FAfc: TFreqTracker;
    FAfcOn: Boolean;
    FAfcSpeed: Integer;
    FAfcMetric: Double;          // fldigi: afcmetric

    // --- Evidence 用 (ADR-002) ---
    FCharMinMargin: Double;      // 文字を構成したビットの最小余裕
    FCharHasBits: Boolean;

    // --- 送信 ---
    FTxPhaseAcc: Double;         // fldigi: phaseacc[0] (tx 側 NCO)
    FTxPrevSymbol: TComplex;     // fldigi: prevsymbol[0] (tx 側)
    FTxShape: array of Double;   // fldigi: tx_shape
    FTxPreamble: Boolean;

    procedure SetupForMode(AMode: TModemMode);
    procedure BuildFilters;
    procedure BuildTxShape;
    procedure RxSymbol(const ASymbol: TComplex);
    procedure RxBit(ABit: Boolean; AMargin: Double);
    procedure EmitPskChar(ACh: Integer);
    procedure TxSymbolBits(ABit: Integer);
    procedure TxSendSymbol(ASym: Integer);
    procedure TxSendChar(ACh: Byte);
    procedure Afc;
    procedure SetAfcSpeed(AValue: Integer);
    function GetAfcOffset: Double;
    function GetAfcClamps: Int64;
    function GetAfcUpdates: Int64;
  public
    constructor Create(ASound: TCustomSoundDevice; AMode: TModemMode); reintroduce;
    destructor Destroy; override;

    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer; override;
    function TxProcess: Integer; override;

    { 1 記号のサンプル数。速度の指標にもなる (8000/FSymbolLen ボー)。 }
    property SymbolLen: Integer read FSymbolLen;
    { 搬送波を捕まえているか。fldigi: dcd }
    property Dcd: Boolean read FDcd;

    { --- AFC (MDM-006) ---
      切っても、それまでに動いた周波数はそこに留まる (RTTY と同じ分担)。
      指令された周波数へ戻したいときは `Restart` を呼ぶ ―― 指令値は
      追尾では壊れないので、いつでも戻せる。 }
    property AfcOn: Boolean read FAfcOn write FAfcOn;
    { 追尾の速さ。RTTY の AfcSpeed と同じ考え方で 0=遅い / 1=ふつう /
      2=速い。速いほどドリフトに追うが、雑音で周波数が揺れる。
      途中で変えても、いま合っているところは動かない。 }
    property AfcSpeed: Integer read FAfcSpeed write SetAfcSpeed;
    { 指令周波数からいま何 Hz ずれて見ているか。Evidence にも載せる。 }
    property AfcOffsetHz: Double read GetAfcOffset;
    { 追尾が上限に当たった回数。0 でなければ信号を見失っている疑いがある。 }
    property AfcClamps: Int64 read GetAfcClamps;
    { 追尾を許すかどうかを決めている品質 (fldigi: afcmetric)。 }
    property AfcMetric: Double read FAfcMetric;
    { 実際に補正を適用した回数。品質の門を通った回数でもある。
      0 のまま増えなければ、DCD は立っていても追尾していない
      (雑音や弱い信号で品質が門に届かない状態)。 }
    property AfcUpdates: Int64 read GetAfcUpdates;
    { このモードが 1 秒あたり何ビット送るか。 }
    function BaudRate: Double;
  end;

{ このユニットが扱えるモードか。 }
function IsBpskMode(AMode: TModemMode): Boolean;

implementation

const
  { fldigi: sym_vec_pos[16]。BPSK が使うのは [0] (180 度) と [8] (0 度)。
    16 分割の表をそのまま持っているのは fldigi と同じ添字で引けるように
    するためで、QPSK 以上を足すときにこの表がそのまま効く。 }
  SymVecPos: array[0..15, 0..1] of Double = (
    (-1.0, 0.0), (-0.9238, -0.3826), (-0.7071, -0.7071), (-0.3826, -0.9238),
    (0.0, -1.0), (0.3826, -0.9238), (0.7071, -0.7071), (0.9238, -0.3826),
    (1.0, 0.0), (0.9238, 0.3826), (0.7071, 0.7071), (0.3826, 0.9238),
    (0.0, 1.0), (-0.3826, 0.9238), (-0.7071, 0.7071), (-0.9238, 0.3826)
  );

{$I pskcore_filter.inc}

function IsBpskMode(AMode: TModemMode): Boolean;
begin
  Result := AMode in [mmPSK31, mmPSK63, mmPSK125];
end;

{ TPskModem }

constructor TPskModem.Create(ASound: TCustomSoundDevice; AMode: TModemMode);
begin
  if not IsBpskMode(AMode) then
    raise EPskModemError.CreateFmt(
      'このモデムが扱えるのは BPSK (PSK31/63/125) だけです (指定: %d)',
      [Ord(AMode)]);

  inherited Create(ASound, AMode);
  SampleRate := PSK_SAMPLE_RATE;
  { mcSquelch: RxSymbol が Squelch を実際に見る (DCD の既定判定)。
    mcAFC: 周波数追尾を持つ (MDM-006)。 }
  Capabilities := Capabilities + [mcRx, mcTx, mcSquelch, mcAFC];

  SetupForMode(AMode);

  { 利得は fldigi と同じ 1/dcdbits。どのモードでも時定数は約 1.024 秒で、
    31.25 ボーなら 32 記号、125 ボーなら 128 記号ぶんになる。 }
  FAfc.Init(PSK_AFC_RANGE_HZ, 1.0 / FDcdBits);
  FAfcOn := True;
  AfcSpeed := PSK_AFC_DEFAULT_SPEED;
  BuildFilters;
  BuildTxShape;

  { fldigi 既定の待ち受け周波数 (progdefaults.PSKsweetspot)。 }
  Frequency := 1000;
  Bandwidth := BaudRate * 2;

  Restart;
end;

destructor TPskModem.Destroy;
begin
  FFir1.Free;
  FFir2.Free;
  inherited Destroy;
end;

procedure TPskModem.SetupForMode(AMode: TModemMode);
begin
  { fldigi: psk::psk() の switch(mode)。samplerate 8000 のときの値。 }
  case AMode of
    mmPSK31:  begin FSymbolLen := 256; FDcdBits := 32;  FUseCoreFilter := True;  end;
    mmPSK63:  begin FSymbolLen := 128; FDcdBits := 64;  FUseCoreFilter := True;  end;
    mmPSK125: begin FSymbolLen := 64;  FDcdBits := 128; FUseCoreFilter := False; end;
  else
    raise EPskModemError.Create('扱えないモードです');
  end;
end;

function TPskModem.BaudRate: Double;
begin
  Result := SampleRate / FSymbolLen;
end;

procedure TPskModem.BuildFilters;
var
  c1, c2: array[0..PSK_FIRLEN] of Double;
  i, dec1: Integer;
begin
  { fldigi: psk.cxx の fir_type による分岐。
    fir1 は間引き、fir2 は整合フィルタ。間引き後は 1 記号 16 標本になる。 }
  { 係数生成は var の開放配列を取るのでコンパイラが「初期化されて
    いない」と言う。実際は 0..PSK_FIRLEN が必ず埋まるが、
    ここで潰しておけば読む側が迷わない。 }
  for i := 0 to PSK_FIRLEN do
  begin
    c1[i] := 0;
    c2[i] := 0;
  end;

  if FSymbolLen > 15 then
    dec1 := FSymbolLen div 16
  else
    dec1 := 1;

  if FUseCoreFilter then
  begin
    { PSK_CORE: fir1 = 二乗余弦、fir2 = pskcore の係数表。長さ FIRLEN+1。 }
    RaisedCosFilter(c1, PSK_FIRLEN);
    for i := 0 to PSK_FIRLEN do
      c2[i] := PskCoreFilter[i];
    FFir1 := TFirFilter.Create(PSK_FIRLEN + 1, dec1, c1, c1);
    FFir2 := TFirFilter.Create(PSK_FIRLEN + 1, 1, c2, c2);
  end
  else
  begin
    { SINC: 両方とも窓つき sinc。長さ FIRLEN (fldigi と同じく +1 しない)。 }
    WSincFilter(c1, 1.0 / FSymbolLen, PSK_FIRLEN);
    WSincFilter(c2, 1.0 / 16.0, PSK_FIRLEN);
    FFir1 := TFirFilter.Create(PSK_FIRLEN, dec1, c1, c1);
    FFir2 := TFirFilter.Create(PSK_FIRLEN, 1, c2, c2);
  end;
end;

procedure TPskModem.BuildTxShape;
var
  i: Integer;
  symPh: Double;
begin
  { fldigi: tx_shape[i] = 0.5 * cos(sym_ph) + 0.5  (二乗余弦の立ち上がり)。
    記号の境目で振幅を絞ることで、帯域外への広がりを抑える。 }
  SetLength(FTxShape, FSymbolLen);
  for i := 0 to FSymbolLen - 1 do
  begin
    symPh := i * Pi / FSymbolLen;
    FTxShape[i] := 0.5 * Cos(symPh) + 0.5;
  end;
end;

procedure TPskModem.TxInit;
begin
  FTxPhaseAcc := 0;
  FTxPrevSymbol := CplxMake(1.0, 0.0);
  FTxPreamble := True;
end;

procedure TPskModem.RxInit;
var
  i: Integer;
begin
  { 受信系を初期状態に戻す。フィルタの遅延線まで消すのは、同じ
    インスタンスに別の音を流し直したときに前の音が混ざらないように
    するためである (X-06 Replay / Z-05 再現性。README 29 章)。 }
  FRxPhaseAcc := 0;
  FPrevSymbol := CplxMake(0, 0);
  FShreg := 0;
  FBitClk := 0;
  for i := 0 to PSK_SYNC_BUCKETS - 1 do
    FSyncBuf[i] := 0;
  FPhase := 0;
  FBits := 0;
  FDcdShreg := 0;
  FDcd := False;
  FDcdOffCounter := 0;
  FQuality := CplxMake(0, 0);
  FAfcMetric := 0;
  FAverageAmp := 0;
  FCharMinMargin := 1.0;
  FCharHasBits := False;
  SetMetric(0);

  { 追尾で溜めたずれを捨てる。残すと前の音に引かれた周波数から始まり、
    同じ音から同じ結果が出ない (Z-05)。周波数そのものを戻すのは
    Restart の仕事で、ここではやらない (RxInit と Restart の分担は
    Modem.pas の TrackFreq の説明を参照)。 }
  FAfc.Reset;

  if FFir1 <> nil then FFir1.Reset;
  if FFir2 <> nil then FFir2.Reset;

  EmitStatus(Format('PSK %.0f Rx', [BaudRate]));
end;

procedure TPskModem.Restart;
begin
  RestoreCommandedFreq;
  RxInit;
  TxInit;
end;

procedure TPskModem.EmitPskChar(ACh: Integer);
var
  ev: TDecodeEvidence;
begin
  { ADR-002: 復号文字を Evidence として上げる。 }
  ev := SingleCandidateEvidence(ACh, DecoderName);
  ev.MetricKind := emkSoftMargin;
  ev.Candidates[0].Metric := FCharMinMargin;
  ev.SamplePos := StreamPosition;
  { SNR は持っていない。fldigi の metric は品質ベクトルのノルムであって
    dB の SNR ではないので、名乗らない (ユニット冒頭の説明を参照)。 }
  ev.HasSnr := False;
  { 指令された周波数から見て、いまどれだけずれたところを見ているか。
    最初から切ったままなら 0。追尾のあとで切った場合は、AfcOn の
    説明のとおり最後に合わせた値がそのまま残る (0 に戻さない)。 }
  ev.HasFreqOffset := True;
  ev.FreqOffsetHz := FAfc.Offset;
  EmitDecode(ev);
end;

procedure TPskModem.RxBit(ABit: Boolean; AMargin: Double);
var
  c: Integer;
begin
  { fldigi: void psk::rx_bit(int bit) }
  if ABit then
    FShreg := (FShreg shl 1) or 1
  else
    FShreg := FShreg shl 1;

  { この文字を構成したビットのうち、最も判定境界に近かったものを覚える。
    文字は 1 ビットでも誤ると壊れるので、最も弱いビットが文字全体の
    確からしさを決める。 }
  if not FCharHasBits then
  begin
    FCharMinMargin := AMargin;
    FCharHasBits := True;
  end
  else if AMargin < FCharMinMargin then
    FCharMinMargin := AMargin;

  { 下位 2 bit が 00 になったら文字の区切り。 }
  if (FShreg and 3) = 0 then
  begin
    c := PskVaricodeDecode(FShreg shr 2);
    if (c <> PSKVC_NO_CHAR) and FDcd then
      EmitPskChar(c);
    FShreg := 0;
    FCharMinMargin := 1.0;
    FCharHasBits := False;
  end;
end;

procedure TPskModem.RxSymbol(const ASymbol: TComplex);
var
  sigamp, cval, sval, margin: Double;
  diff: TComplex;
  setDcd: Integer;
begin
  { fldigi: void psk::rx_symbol(cmplx symbol, int car) の BPSK 経路 }
  sigamp := ASymbol.Re * ASymbol.Re + ASymbol.Im * ASymbol.Im;  // norm()

  diff := CplxConj(FPrevSymbol) * ASymbol;
  FPhase := CplxArg(diff);
  FPrevSymbol := ASymbol;

  if FPhase < 0 then
    FPhase := FPhase + 2 * Pi;

  { 位相差が 0 付近なら「変わっていない」、Pi 付近なら「反転した」。
    fldigi: bits = (((int)(phase / M_PI + 0.5)) & 1) << 1 }
  FBits := (Trunc(FPhase / Pi + 0.5) and 1) shl 1;

  { 軟判定の余裕。判定境界 (Pi/2, 3Pi/2) から遠いほど 1 に近い。 }
  margin := Abs(Cos(FPhase));

  FAverageAmp := DecayAvg(FAverageAmp, sigamp, PSK_SQL_DECAY);

  { 品質。位相差が 0 か Pi に揃っていれば cos(2*phase) が 1 に寄る。

    fldigi はここで attack と decay を使い分ける形に書いているが、
    BPSK では両方とも SQLDECAY で同じ値なので、分岐しても結果は
    変わらない (使い分けるのは 8PSK だけ)。分岐そのものを落とした。 }
  cval := Cos(2 * FPhase);
  sval := Sin(2 * FPhase);
  FQuality.Re := DecayAvg(FQuality.Re, cval, PSK_SQL_DECAY);
  FQuality.Im := DecayAvg(FQuality.Im, sval, PSK_SQL_DECAY);

  SetMetric(Min(100.0,
    100.0 * (FQuality.Re * FQuality.Re + FQuality.Im * FQuality.Im)));

  { 追尾を許すかどうかの品質。表示用の metric より長くならす
    (fldigi: decayavg(afcmetric, norm(quality), 50))。 }
  FAfcMetric := DecayAvg(FAfcMetric,
    FQuality.Re * FQuality.Re + FQuality.Im * FQuality.Im,
    PSK_AFC_METRIC_DECAY);

  { DCD: 直近の記号列が待機信号の並びかどうかを見る。
    BPSK は symbits=1 なので 2 bit ずつ詰める。
      0xAAAAAAAA = 位相反転が続いている = 送信の頭 (preamble)
      0x00000000 = 位相が変わらない     = 送信の尻尾 (postamble) }
  FDcdShreg := (FDcdShreg shl 2) or LongWord(FBits);
  setDcd := -1;
  if FDcdShreg = $AAAAAAAA then
    setDcd := 1
  else if FDcdShreg = $00000000 then
    setDcd := 0
  else
  begin
    { 並びに当てはまらないときはスケルチで決める。
      Squelch <= 0 は「スケルチなし」とみなす。 }
    if (Squelch <= 0) or (Metric > Squelch) then
      FDcd := True
    else
      FDcd := False;
    Dec(FDcdOffCounter);
    if FDcdOffCounter < 0 then
      FDcdOffCounter := 0;
  end;

  if setDcd = 1 then
  begin
    FDcdOffCounter := 0;
    FDcd := True;
    FQuality := CplxMake(1.0, 0.0);
  end
  else if setDcd = 0 then
  begin
    { 6 回続けて見えたときだけ落とす。1 回で落とすと、たまたま
      その並びになった本物のデータで受信が切れる。 }
    Inc(FDcdOffCounter);
    if FDcdOffCounter > 5 then
    begin
      FDcdOffCounter := 0;
      FDcd := False;
      FQuality := CplxMake(0, 0);
    end;
  end;

  { 周波数の追尾。**信号を捕まえていて、かつ位相が揃っているときだけ。**
    雑音の位相差は一様なので、測れば当たり前に酔歩する。 }
  if FAfcOn and FDcd and (FAfcMetric >= PSK_AFC_MIN_QUALITY) then
    Afc;

  { 位相が変わらない = 1、反転した = 0。 }
  RxBit(FBits = 0, margin);
end;

procedure TPskModem.Afc;
var
  err, errHz: Double;
begin
  { 判定した位相 (FBits = 0 なら 0、2 なら Pi) からのずれが、
    1 記号のあいだに余計に回った角度である。 }
  err := FPhase - FBits * Pi / 2;

  { (-Pi, Pi] へ畳む。FPhase は [0, 2*Pi) なので err は (-Pi, 2*Pi) に
    入り、1 回引けば足りる。**畳まないと片側しか採らない** ――
    ユニット冒頭の説明を参照。 }
  if err > Pi then
    err := err - 2 * Pi;

  { 角度 [rad/記号] を Hz へ。1 記号は FSymbolLen サンプル。 }
  errHz := err * SampleRate / (2 * Pi * FSymbolLen);

  { 指令された周波数は壊さない。動かすのは「いま見ている周波数」だけ。 }
  TrackFreq(FAfc.Track(CommandedFrequency, errHz));
end;

procedure TPskModem.SetAfcSpeed(AValue: Integer);
begin
  if AValue < PSK_AFC_SPEED_SLOW then AValue := PSK_AFC_SPEED_SLOW;
  if AValue > PSK_AFC_SPEED_FAST then AValue := PSK_AFC_SPEED_FAST;
  FAfcSpeed := AValue;
  { ずれはそのまま。速さだけ変える。 }
  FAfc.SetGain((1 shl AValue) / FDcdBits);
end;

function TPskModem.GetAfcOffset: Double;
begin
  Result := FAfc.Offset;
end;

function TPskModem.GetAfcClamps: Int64;
begin
  Result := FAfc.Clamps;
end;

function TPskModem.GetAfcUpdates: Int64;
begin
  Result := FAfc.Updates;
end;

function TPskModem.RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
var
  i, k, idx, symSteps, bitSteps: Integer;
  z, z1, z2: TComplex;
  delta, sum, ampSum: Double;
begin

  delta := 2 * Pi * Frequency / SampleRate;

  if FSymbolLen >= PSK_SYNC_BUCKETS then
    bitSteps := PSK_SYNC_BUCKETS
  else
    bitSteps := FSymbolLen;
  symSteps := bitSteps div 2;

  for i := 0 to ALen - 1 do
  begin
    { NCO で中心周波数へ移す。fldigi: z = cmplx(buf*cos(ph), buf*sin(ph)) }
    z := CplxMake(ABuf[i] * Cos(FRxPhaseAcc), ABuf[i] * Sin(FRxPhaseAcc));
    FRxPhaseAcc := FRxPhaseAcc + delta;
    if FRxPhaseAcc > 2 * Pi then
      FRxPhaseAcc := FRxPhaseAcc - 2 * Pi;

    if not FFir1.Run(z, z1) then
      Continue;
    if not FFir2.Run(z1, z2) then
      Continue;

    { --- ビットクロック復元 ---
      整合フィルタ出力の大きさを 16 個の桶に繰り返し描く。 }
    idx := Trunc(FBitClk);
    if idx < 0 then idx := 0;
    if idx >= PSK_SYNC_BUCKETS then idx := PSK_SYNC_BUCKETS - 1;
    FSyncBuf[idx] := 0.8 * FSyncBuf[idx] + 0.2 * CplxAbs(z2);

    { 前半と後半の差。和で割るので信号の大きさに依存しない。 }
    sum := 0;
    ampSum := 0;
    for k := 0 to symSteps - 1 do
    begin
      sum := sum + (FSyncBuf[k] - FSyncBuf[k + symSteps]);
      ampSum := ampSum + (FSyncBuf[k] + FSyncBuf[k + symSteps]);
    end;
    if ampSum = 0 then
      sum := 0
    else
      sum := sum / ampSum;

    { 前半が大きければ位置が遅れているので速める。 }
    FBitClk := FBitClk - sum / (5.0 * 16 / bitSteps);
    FBitClk := FBitClk + 1;

    if FBitClk < 0 then
      FBitClk := FBitClk + bitSteps;
    if FBitClk >= bitSteps then
    begin
      FBitClk := FBitClk - bitSteps;
      RxSymbol(z2);
      { AFC が周波数を動かしたかもしれない。NCO の刻みを取り直す
        (位相そのものは連続のままなので、飛びは起きない)。 }
      delta := 2 * Pi * Frequency / SampleRate;
    end;
  end;

  { --- 通算サンプル位置を進めるのは **最後** ---
    先に進めると、この区画の中で確定した結果がすべて「区画の末尾」を
    名乗ることになる。末尾はその文字を生んだ音より後ろなので、そこから
    流し直しても同じ文字は出ない ―― Replay Decode にも障害再現にも使えない。
    最後に進めれば、区画の処理中 FStreamPos は **その区画の先頭** を指す。
    詳しくは DecodeEvidence.SamplePos の説明。 }
  AdvanceStreamPos(ALen);
  Result := 0;
end;

{ ---- 送信 ---- }

procedure TPskModem.TxSendSymbol(ASym: Integer);
var
  i, vi: Integer;
  symbol: TComplex;
  shapeA, shapeB, ival, qval, delta, maxAmp: Double;
begin
  { fldigi: psk::tx_carriers() の 1 搬送波・BPSK 経路 }
  vi := (ASym * 4) and 15;
  symbol := FTxPrevSymbol * CplxMake(SymVecPos[vi, 0], SymVecPos[vi, 1]);

  delta := 2 * Pi * TxFrequency / SampleRate;
  EnsureTxBuf(FSymbolLen);

  for i := 0 to FSymbolLen - 1 do
  begin
    { 記号の境目で前の記号から新しい記号へなめらかに渡す。 }
    shapeA := FTxShape[i];
    shapeB := 1.0 - shapeA;
    ival := shapeA * FTxPrevSymbol.Re + shapeB * symbol.Re;
    qval := shapeA * FTxPrevSymbol.Im + shapeB * symbol.Im;
    FTxSymbolBuf[i] := ival * Cos(FTxPhaseAcc) + qval * Sin(FTxPhaseAcc);
    FTxPhaseAcc := FTxPhaseAcc + delta;
    if FTxPhaseAcc > 2 * Pi then
      FTxPhaseAcc := FTxPhaseAcc - 2 * Pi;
  end;
  FTxPrevSymbol := symbol;

  { fldigi と同じく記号ごとに山を 1 へ揃える。 }
  maxAmp := 0;
  for i := 0 to FSymbolLen - 1 do
    if Abs(FTxSymbolBuf[i]) > maxAmp then
      maxAmp := Abs(FTxSymbolBuf[i]);
  if maxAmp > 0 then
    for i := 0 to FSymbolLen - 1 do
      FTxSymbolBuf[i] := FTxSymbolBuf[i] / maxAmp;

  if Sound <> nil then
    Sound.WriteSamples(FTxSymbolBuf, FSymbolLen);
end;

procedure TPskModem.TxSymbolBits(ABit: Integer);
begin
  { fldigi: psk::tx_bit()。BPSK は bit を 1 つ左へ寄せて 0 か 2 にする。 }
  TxSendSymbol(ABit shl 1);
end;

procedure TPskModem.TxSendChar(ACh: Byte);
var
  code: string;
  i: Integer;
begin
  { fldigi: psk::tx_char() }
  code := PskVaricodeEncode(ACh);
  for i := 1 to Length(code) do
    TxSymbolBits(Ord(code[i]) - Ord('0'));
  { 文字の区切り: 0 を 2 つ。 }
  TxSymbolBits(0);
  TxSymbolBits(0);
end;

function TPskModem.TxProcess: Integer;
var
  c, i: Integer;
begin
  { 送信の頭に位相反転の連続を置く。受信側の DCD と
    ビットクロック復元がこれで噛み合う (fldigi: preamble)。 }
  if FTxPreamble then
  begin
    FTxPreamble := False;
    for i := 1 to PSK_PREAMBLE_SYMBOLS do
      TxSymbolBits(0);
  end;

  c := FetchTxChar;

  if (c = MODEM_TX_CHAR_ETX) or StopFlag then
  begin
    StopFlag := False;
    { 送信の尻尾に無反転の連続を置く。受信側はこれで DCD を落とす。 }
    for i := 1 to PSK_POSTAMBLE_SYMBOLS do
      TxSymbolBits(1);
    Exit(-1);
  end;

  if c = MODEM_TX_CHAR_NODATA then
  begin
    { 送るものが無い間も搬送波を保つ (位相反転を続ける)。 }
    TxSymbolBits(0);
    Exit(0);
  end;

  EmitEchoChar(c);
  TxSendChar(Byte(c));
  Result := 0;
end;

end.
