{ ============================================================================
  MfskModemImpl.pas

  MFSK16 / MFSK32 のモデム本体。部品を繋いでモードとして成立させる。

  これまでに独立して固めてきた層をここで組む。

      送信  文字 -> Varicode -> 畳み込み符号 -> インタリーバ -> トーン -> 音
            MfskVaricode      ConvCodec      Interleaver    Gray

      受信  音 -> トーン検出 -> 戻し -> Viterbi -> Varicode -> 文字
            MfskTones        Interleaver ConvCodec MfskVaricode

  各層は単体で試験してある (MDM-009 / MDM-010 / MDM-012 / MDM-013)。
  ここが主張するのは**繋がること**だけである。

  層の間の約束
  ----------------------------------------------------------------------------
  ビットの向きが層をまたぐたびに変わるので、ここに書き出しておく。

  - 畳み込み符号は 1 ビット入れると 2 ビット出る。bit0 が poly1、
    bit1 が poly2 の出力。送信はこの順 (0 -> 1) にシフトレジスタへ入れる。
  - シンボルのビット並びは**最上位が先**。SymBits=4 なら、最初に入れた
    符号ビットがトーン番号の bit3 になる。
  - 受信の軟判定 SoftBit(0) が最上位 = 最初に送った符号ビットである。
    だから軟判定を 0,1,2,3 の順に Viterbi へ渡せば、送った順に戻る。
  - インタリーバは送信ではビット (0/1)、受信では軟判定 (0..255) を通す。
    同じ表・同じ手順で、値の幅だけが違う。

  流し込みと吐き出し
  ----------------------------------------------------------------------------
  この鎖には**遅れ**がある。受信側で最初の文字が出てくるまでに、
  インタリーバと Viterbi を通り抜けるぶんの空回しが要る。

      インタリーバ往復  30 区画 = 120 符号ビット = 60 入力ビット
      Viterbi の遡り    45 ビット
      符号器の記憶      K-1 = 6 ビット
      ------------------------------------------------ 合計 111 ビット

  送信の頭と尻尾にこれだけ流す。上流は 107 ビット (preamble) を使っているが、
  値の出どころは書かれていない。こちらは**鎖の遅れから出した**。

  頭に流すものを 0 のビット列にしていない
  ----------------------------------------------------------------------------
  0 を並べると符号器の出力も一定になり、**同じトーンが鳴り続ける**。
  シンボル同期の追尾は「隣り合うシンボルが同じトーンなら見送る」ので、
  一定のトーンでは一度も効かない (MDM-013)。つまり 0 の前置きは同期の
  役に立たない。そこで上流の sendidle() ―― NUL 文字 + 1 + 0 を 32 個 ――
  を繰り返す。トーンが動くので、本文が始まる前に同期が掴める。

  実装していないもの
  ----------------------------------------------------------------------------
  - **AFC** (周波数のずれの追尾)。Phase 3。
  - 画像送受信 (MFSK Picture)。上流の cap |= CAP_IMG の枝。
  - Hilbert 変換と帯域通過フィルタの前段。MfskTones の見出しに理由がある。
  - 奇数ビット/シンボルのモード (MFSK4/8 など) が要る 2 系統 Viterbi の
    投票。MFSK16/32 は SymBits=4 なので 1 系統で足りる。
  ============================================================================ }
unit MfskModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP,
  DecodeEvidence, MfskTones, MfskVaricode, ConvCodec, Interleaver;

type
  EMfskModemError = class(Exception);

  { TMfskModem
    ---------------------------------------------------------------------
    fldigi: class mfsk : public modem (mfsk.h / mfsk.cxx) }
  TMfskModem = class(TCustomModem)
  private
    FMfskMode: TMfskMode;

    { --- 受信 --- }
    FTones: TMfskToneDetector;
    FRxInlv: TInterleaver;
    FViterbi: TViterbiDecoder;
    FSoftBuf: array[0..MFSK_MAX_SYMBITS - 1] of Byte;
    FSymPair: array[0..1] of Byte;
    FSymCounter: Integer;
    FDataShreg: LongWord;
    FBitMetric: Double;        // 道の尺度の減衰平均 (fldigi: met2)
    FS2N: Double;              // fldigi: s2n
    FPrev1Tone: Integer;
    FPrev2Tone: Integer;
    FRxSymbols: Int64;

    { --- 送信 --- }
    FEncoder: TConvEncoder;
    FTxInlv: TInterleaver;
    FBitShreg: LongWord;
    FBitState: Integer;
    FTxPhase: Double;
    FPreamblePending: Boolean;

    FFlushBits: Integer;

    procedure BuildChain;
    procedure DecodeSoftBit(ASoft: Byte);
    procedure RecvBit(ABit: Integer);
    procedure EmitChar(ACh: Integer);
    procedure UpdateS2N;

    procedure SendSymbol(ASymbol: LongWord);
    procedure SendBit(ABit: Integer);
    procedure SendChar(ACh: Byte);
    procedure SendIdle;
    procedure SendFill;
  public
    constructor Create(ASound: TCustomSoundDevice;
      AMode: TModemMode = mmMFSK16); reintroduce;
    destructor Destroy; override;

    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
      override;
    function TxProcess: Integer; override;

    function DecoderName: string; override;

    { モードの諸元。呼び手が帯域や速度を知るために使う。 }
    property MfskMode: TMfskMode read FMfskMode;
    { 鎖を通り抜けるのに要る空回しのビット数。送信の頭と尻尾に流す量で、
      受信側が最初の文字を出せるようになるまでの目安でもある。 }
    property FlushBits: Integer read FFlushBits;
    { シンボル同期のずれ [サンプル]。Z-01 の観測点。 }
    function SyncErrorSamples: Double;
    { これまでに切り出したシンボル数。 }
    function RxSymbolCount: Int64;
  end;

implementation

{ fldigi: mfsk.cxx の TRACEPAIR(45, 352) と setchunksize(1)。
  1 ビットずつ確定させるのは、Varicode のシフトレジスタが 1 ビット
  単位で区切りを見るからである。 }
const
  MFSK_TRACEBACK = 45;
  MFSK_CHUNK = 1;

  { 尺度を 0..100 に写すときの平行移動と倍率 (fldigi: mfsk::decodesymbol)。 }
  MFSK_METRIC_OFFSET = 60.0;
  MFSK_METRIC_SCALE = 0.5;

  { 尺度と S/N の減衰平均の重み (fldigi: decayavg(..., 50) と 64)。 }
  MFSK_METRIC_DECAY = 50;
  MFSK_S2N_DECAY = 64;

  { S/N の申告範囲 [dB]。二つのトーンの大きさの比から出した**目安**で、
    帯域を決めて測った値ではない。無雑音の音を入れると雑音側が 0 に
    近づき 150 dB を超える ―― そのまま上げると、Phase 3 の
    Reception State Estimator が有り得ない材料を受け取る。
    短波で意味を持つ範囲に切り、切ったことを申告する。 }
  MFSK_S2N_MIN_DB = -40.0;
  MFSK_S2N_MAX_DB = 60.0;

constructor TMfskModem.Create(ASound: TCustomSoundDevice; AMode: TModemMode);
begin
  case AMode of
    mmMFSK16: FMfskMode := MFSK16_MODE;
    mmMFSK32: FMfskMode := MFSK32_MODE;
  else
    raise EMfskModemError.CreateFmt(
      'このモデムが扱えるのは MFSK16 / MFSK32 です (指定: %s)',
      [ModemModeToStr(AMode)]);
  end;

  inherited Create(ASound, AMode);
  SampleRate := FMfskMode.SampleRate;
  Capabilities := Capabilities + [mcRx, mcTx];

  Bandwidth := FMfskMode.BandwidthHz;
  { 待ち受け周波数はモードの中心。上流の初期値と同じ考え方である。 }
  Frequency := FMfskMode.CentreFreqHz;

  BuildChain;
  Restart;
end;

procedure TMfskModem.BuildChain;
begin
  FTones := TMfskToneDetector.Create(FMfskMode, Frequency);
  FRxInlv := TInterleaver.Create(FMfskMode.SymBits, FMfskMode.Depth,
    idReverse);
  FViterbi := TViterbiDecoder.Create;
  FViterbi.TracebackLen := MFSK_TRACEBACK;
  FViterbi.ChunkSize := MFSK_CHUNK;

  FEncoder := TConvEncoder.Create;
  FTxInlv := TInterleaver.Create(FMfskMode.SymBits, FMfskMode.Depth,
    idForward);

  { 鎖を通り抜けるのに要る空回し。見出しの表のとおり。
    インタリーバの往復は「区画数 x 1 区画あたりの符号ビット数」で、
    1 区画 = 1 シンボル = SymBits 本の符号ビット。符号化率 1/2 なので
    入力ビットに直すと半分になる。 }
  FFlushBits :=
    (FRxInlv.RoundTripDelayBlocks * FMfskMode.SymBits) div 2
    + FViterbi.TracebackLen
    + (FEncoder.K - 1);
end;

destructor TMfskModem.Destroy;
begin
  FTxInlv.Free;
  FEncoder.Free;
  FViterbi.Free;
  FRxInlv.Free;
  FTones.Free;
  inherited Destroy;
end;

function TMfskModem.DecoderName: string;
begin
  Result := FMfskMode.Name;
end;

function TMfskModem.SyncErrorSamples: Double;
begin
  Result := FTones.SyncError;
end;

function TMfskModem.RxSymbolCount: Int64;
begin
  Result := FRxSymbols;
end;

{ ==========================================================================
  受信
  ========================================================================== }

procedure TMfskModem.RxInit;
var
  i: Integer;
begin
  { 前の音を一切持ち越さない。同じインスタンスへ別の音を流し直しても
    同じ結果になること (X-06 Replay / Z-05 再現性) を担保する。 }
  FTones.Reset;
  FRxInlv.Reset;
  FViterbi.Reset;
  for i := 0 to MFSK_MAX_SYMBITS - 1 do FSoftBuf[i] := CONV_SOFT_ERASURE;
  FSymPair[0] := CONV_SOFT_ERASURE;
  FSymPair[1] := CONV_SOFT_ERASURE;
  FSymCounter := 0;
  FDataShreg := 0;
  FBitMetric := 0;
  FS2N := 0;
  FPrev1Tone := 0;
  FPrev2Tone := 0;
  FRxSymbols := 0;
  Metric := 0;
end;

procedure TMfskModem.UpdateS2N;
var
  sig, noise: Double;
begin
  { fldigi: mfsk::eval_s2n()。いま鳴っているトーンの大きさを信号、
    二つ前に鳴っていたトーン (もう鳴っていないはず) の大きさを
    雑音の代表値として、残り全トーンぶんに引き伸ばす。 }
  sig := FTones.ToneMagnitude(FTones.Symbol);
  noise := (FMfskMode.NumTones - 1) * FTones.ToneMagnitude(FPrev2Tone);
  if noise > 0 then
    FS2N := DecayAvg(FS2N, sig / noise, MFSK_S2N_DECAY);
end;

procedure TMfskModem.EmitChar(ACh: Integer);
var
  ev: TDecodeEvidence;
begin
  { ADR-002: 確定文字ではなく候補と根拠を上げる。
    尺度は Viterbi が選んだ道の伸び ―― 対数尤度そのものではないが
    「大きいほど確からしい」量なので emkLogLikelihood で運ぶ。 }
  ev := ScoredCandidateEvidence(ACh, FBitMetric, emkLogLikelihood,
    DecoderName);
  ev.SamplePos := StreamPosition;
  if FS2N > 0 then
  begin
    ev.HasSnr := True;
    ev.SnrDb := ClampF(20 * Log10(FS2N), MFSK_S2N_MIN_DB, MFSK_S2N_MAX_DB);
  end;
  { シンボル同期のずれは「受信状態」として持っておく価値がある。
    周波数のずれではないので FreqOffsetHz には入れない ―― 混ぜると
    Phase 3 の Reception State Estimator が誤った材料を受け取る。 }
  EmitDecode(ev);
  EmitEchoChar(ACh);
end;

procedure TMfskModem.RecvBit(ABit: Integer);
var
  c: Integer;
begin
  { fldigi: mfsk::recvbit()。1 を先頭に、00 で終わる符号なので
    下 3 ビットが 001 になった時点が区切りである。 }
  FDataShreg := ((FDataShreg shl 1) or LongWord(ABit and 1)) and $7FFFFFFF;
  if MfskVaricodeIsBoundary(FDataShreg) then
  begin
    c := MfskVaricodeDecode(MfskVaricodeSymbolOf(FDataShreg));
    if c >= 0 then
      EmitChar(c);
    FDataShreg := 1;
  end;
end;

procedure TMfskModem.DecodeSoftBit(ASoft: Byte);
var
  c, met: Integer;
  m: Double;
begin
  { fldigi: mfsk::decodesymbol()。符号化率 1/2 なので軟判定を 2 つ
    揃えてから Viterbi へ渡す。SymBits が偶数のモードでは 1 系統で
    足り、上流の 2 系統投票 (symbits=3/5 用) は要らない。 }
  FSymPair[0] := FSymPair[1];
  FSymPair[1] := ASoft;
  FSymCounter := 1 - FSymCounter;
  if FSymCounter <> 0 then Exit;

  c := FViterbi.Decode(FSymPair[0], FSymPair[1], met);
  if c = CONV_NO_OUTPUT then Exit;

  FBitMetric := DecayAvg(FBitMetric, met, MFSK_METRIC_DECAY);

  { 0..100 の表示用尺度。Squelch の判定にも使われる値なので、
    上流と同じ写し方にしてある。 }
  m := (FBitMetric - MFSK_METRIC_OFFSET) * MFSK_METRIC_SCALE;
  Metric := ClampF(m, 0, 100);

  RecvBit(c);
end;

function TMfskModem.RxProcess(const ABuf: array of Double;
  ALen: Integer): Integer;
var
  i, k: Integer;
begin
  for i := 0 to ALen - 1 do
    if FTones.Feed(ABuf[i]) then
    begin
      Inc(FRxSymbols);
      UpdateS2N;

      for k := 0 to FMfskMode.SymBits - 1 do
        FSoftBuf[k] := FTones.SoftBit(k);

      { 戻し。送信でかき混ぜたのと対になる。 }
      FRxInlv.Process(FSoftBuf);

      for k := 0 to FMfskMode.SymBits - 1 do
        DecodeSoftBit(FSoftBuf[k]);

      FPrev2Tone := FPrev1Tone;
      FPrev1Tone := FTones.Symbol;
    end;

  { 通算サンプル位置を進めるのは最後。この区画の中で確定した結果が
    「区画の先頭」を名乗るようにする (DecodeEvidence.SamplePos)。 }
  AdvanceStreamPos(ALen);
  Result := 0;
end;

{ ==========================================================================
  送信
  ========================================================================== }

procedure TMfskModem.TxInit;
begin
  FEncoder.Reset;
  FTxInlv.Reset;
  FBitShreg := 0;
  FBitState := 0;
  FTxPhase := 0;
  FPreamblePending := True;
end;

procedure TMfskModem.Restart;
begin
  RestoreCommandedFreq;
  RxInit;
  TxInit;
end;

procedure TMfskModem.SendSymbol(ASymbol: LongWord);
var
  i, tone: Integer;
  f, step: Double;
begin
  { Gray を挟んでからトーン番号にする。隣のトーンと取り違えても
    ビット誤りが 1 本で済むようにするためである (MDM-010)。 }
  tone := MfskSymbolToTone(Integer(ASymbol) and (FMfskMode.NumTones - 1));
  if Reverse then
    tone := (FMfskMode.NumTones - 1) - tone;

  { 送信周波数は「中心」を指す約束なので、最低トーンはそこから
    帯域の半分だけ下になる。 }
  f := TxFrequency - FMfskMode.BandwidthHz / 2
       + tone * FMfskMode.ToneSpacingHz;
  step := 2 * Pi * f / SampleRate;

  if Assigned(Sound) then
  begin
    EnsureTxBuf(FMfskMode.SymLen);   { X-04: 通常は既に足りている }
    for i := 0 to FMfskMode.SymLen - 1 do
    begin
      FTxSymbolBuf[i] := Cos(FTxPhase);
      FTxPhase := FTxPhase + step;
      if FTxPhase > 2 * Pi then FTxPhase := FTxPhase - 2 * Pi;
    end;
    Sound.WriteSamples(FTxSymbolBuf, FMfskMode.SymLen);
  end
  else
    for i := 0 to FMfskMode.SymLen - 1 do
    begin
      { 音を出さないときも位相だけは進める。途中で音を繋いでも
        位相が飛ばないようにするためである。 }
      FTxPhase := FTxPhase + step;
      if FTxPhase > 2 * Pi then FTxPhase := FTxPhase - 2 * Pi;
    end;
end;

procedure TMfskModem.SendBit(ABit: Integer);
var
  data, i: Integer;
begin
  { fldigi: mfsk::sendbit()。1 ビット入れて 2 ビット出す。
    bit0 (poly1) を先に、bit1 (poly2) を後に入れる。受信側の
    Viterbi.Decode(ASym0, ASym1) と同じ並びである。 }
  data := FEncoder.Encode(ABit);
  for i := 0 to 1 do
  begin
    FBitShreg := (FBitShreg shl 1) or LongWord((data shr i) and 1);
    Inc(FBitState);
    if FBitState = FMfskMode.SymBits then
    begin
      FTxInlv.ProcessBits(FBitShreg);
      SendSymbol(FBitShreg);
      FBitState := 0;
      FBitShreg := 0;
    end;
  end;
end;

procedure TMfskModem.SendChar(ACh: Byte);
var
  code: string;
  i: Integer;
begin
  code := MfskVaricodeEncode(ACh);
  for i := 1 to Length(code) do
    SendBit(Ord(code[i]) - Ord('0'));
end;

procedure TMfskModem.SendIdle;
var
  i: Integer;
begin
  { fldigi: mfsk::sendidle()。NUL の符号 + 1 + 0 を 32 個。
    トーンが動くので、これを前置きに使えば同期も掴める。 }
  SendChar(0);
  SendBit(1);
  for i := 0 to 31 do
    SendBit(0);
end;

procedure TMfskModem.SendFill;
var
  sent: Integer;
begin
  { 鎖の遅れぶんを空回しする。SendIdle 1 回が何ビットかは Varicode の
    表しだいなので、**送ったビット数で数える**。 }
  sent := 0;
  while sent < FFlushBits do
  begin
    SendIdle;
    Inc(sent, Length(MfskVaricodeEncode(0)) + 33);
  end;
end;

function TMfskModem.TxProcess: Integer;
var
  c: Integer;
begin
  if FPreamblePending then
  begin
    { 頭出し。受信側のインタリーバと Viterbi を満たし、同時に
      シンボル同期を掴ませる。 }
    SendFill;
    FPreamblePending := False;
  end;

  c := FetchTxChar;

  if (c = MODEM_TX_CHAR_ETX) or StopFlag then
  begin
    StopFlag := False;
    { 尻尾。最後の文字を受信側から押し出す。上流と同じく 1 を一つ
      置いてから 0 を流す ―― 受信側の Varicode を区切らせるためである。 }
    SendBit(1);
    for c := 1 to FFlushBits do
      SendBit(0);
    FPreamblePending := True;
    Exit(-1);
  end;

  if c = MODEM_TX_CHAR_NODATA then
  begin
    SendIdle;
    Exit(0);
  end;

  SendChar(Byte(c));
  Result := 0;
end;

end.
