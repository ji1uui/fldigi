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
  - 複数搬送波 (PSK125R 系)、AFC、IMD 測定、PSK ブラウザ。
  ============================================================================ }
unit PskModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP,
  PskVaricode, DecodeEvidence;

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

type
  EPskModemError = class(Exception);

  { TPskModem
    ---------------------------------------------------------------------
    fldigi: class psk : public modem (BPSK 経路のみ) }
  TPskModem = class(TCustomModem)
  private
    // --- 諸元 (モードで決まる) ---
    FSymbolLen: Integer;         // fldigi: symbollen (1 記号のサンプル数)
    { fldigi: dcdbits。あちらでは AFC と位相品質の表示に使う。どちらも
      未実装なので今は読まないが、モードごとの諸元として持っておく
      (AFC を足すときにこの値が要る)。 }
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
    { fldigi: phase。直前の記号との位相差。フィールドに持っているのは
      fldigi が AFC からも読むためで、こちらは今 RxSymbol の中だけで
      使う。AFC を足すときにそのまま使える。 }
    FPhase: Double;
    FBits: Integer;              // fldigi: bits (0 または 2)
    FDcdShreg: LongWord;         // fldigi: dcdshreg
    FDcd: Boolean;               // fldigi: dcd
    FDcdOffCounter: Integer;     // fldigi: dcdOFFcounter
    FQuality: TComplex;          // fldigi: quality
    FAverageAmp: Double;         // fldigi: averageamp

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
  { mcSquelch: RxSymbol が Squelch を実際に見る (DCD の既定判定)。 }
  Capabilities := Capabilities + [mcRx, mcTx, mcSquelch];

  SetupForMode(AMode);
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
  FAverageAmp := 0;
  FCharMinMargin := 1.0;
  FCharHasBits := False;
  SetMetric(0);

  if FFir1 <> nil then FFir1.Reset;
  if FFir2 <> nil then FFir2.Reset;

  EmitStatus(Format('PSK %.0f Rx', [BaudRate]));
end;

procedure TPskModem.Restart;
begin
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
  ev.HasFreqOffset := False;
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

  { 位相が変わらない = 1、反転した = 0。 }
  RxBit(FBits = 0, margin);
end;

function TPskModem.RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
var
  i, k, idx, symSteps, bitSteps: Integer;
  z, z1, z2: TComplex;
  delta, sum, ampSum: Double;
begin
  { Replay / 再現のために通算サンプル位置を進める (X-06)。 }
  AdvanceStreamPos(ALen);

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
    end;
  end;

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
