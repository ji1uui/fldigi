{ ============================================================================
  OliviaModemImpl.pas

  Olivia / Contestia のモデム本体。部品を繋いでモードとして成立させる。

      送信  文字 -> [符号の層] -> シンボル -> [音の層] -> 音
            OliviaBlock          Gray        OliviaTones
      受信  音 -> [頭出し] -> ブロック -> 文字
            OliviaSync (中で音の層と符号の層を回している)

  各層は単体で試験してある (OLV-001 / OLV-003 / OLV-004)。
  ここが主張するのは**繋がること**だけである。

  前置きと押し出しが要る
  ----------------------------------------------------------------------------
  Olivia の受信は「復号してみた結果の良さ」から切れ目を決める。掴むまでに
  良さの記録がならし終わるだけの時間が要る (実測で 12 文字ぶん)。だから
  本文の前に**空のブロック**を流す。無音ではなく NUL を符号化したブロックで
  あることが肝心で、無音では良さが立たず、掴む材料にならない。

  尻尾も要る。頭出しは最良の位相から半ブロック進んでから、しかも管の
  いちばん古いものを出すので、最後の文字が出てくるまでに遅れがある。
  その遅れぶん空のブロックを流し込んで押し出す。

  どちらの長さも `TOliviaSync.LatencySymbols` から出している。数えられる
  ものを定数で置かない。

  確定位置について
  ----------------------------------------------------------------------------
  Olivia は**文字が確定するのが、その文字を生んだ音より 9 秒ほど後**になる。
  そのまま「確定したときに処理していた区画」を名乗ると、そこから流し直しても
  その文字は二度と出てこない ―― `TDecodeEvidence.SamplePos` が避けたかった
  ことそのものである (末尾ではなく先頭を名乗る理由と同じ)。

  そこで**鎖の遅れを引いた位置**を名乗る。流し直しの起点として使える値に
  なり、Phase 3 で複数の戦略を並べたときも「同じ音」で並ぶ。
  遅れより前に出た結果 (立ち上がりの数ブロック) は 0 に丸める。

  実装していないもの
  ----------------------------------------------------------------------------
  - **AFC**。頭出しの `FreqOffset` が窓口として空いている (Phase 3)。
  - 上流の入力段の雑音・混信制限 (MFSK_InputProcessor)。Phase 3 の
    Noise Estimator と合わせて扱う。
  - RSID による諸元の自動判別。Phase 5 の領分である。
  ============================================================================ }
unit OliviaModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP,
  DecodeEvidence, OliviaBlock, OliviaTones, OliviaSync;

type
  EOliviaModemError = class(Exception);

  { TOliviaModem
    ---------------------------------------------------------------------
    fldigi: class olivia / class contestia (src/olivia, src/contestia) }
  TOliviaModem = class(TCustomModem)
  private
    FTone: TOliviaToneMode;
    FBlock: TOliviaMode;

    { --- 受信 --- }
    FSync: TOliviaSync;
    FAccum: array of Double;    // SymbolSepar 溜まったら 1 回渡す
    FAccumLen: Integer;
    FLatencySamples: Int64;

    { --- 送信 --- }
    FEncoder: TOliviaBlockEncoder;
    FModulator: TOliviaModulator;
    FTxChars: array of Byte;
    FTxFill: Integer;
    FTxSyms: array of Byte;
    FTxBuf: array of Double;
    FPreamblePending: Boolean;
    FTunedHz: Double;           // いま鎖に入れてある同調
    FPreBlocks: Integer;        // 前置きのブロック数
    FFlushBlocks: Integer;      // 押し出しのブロック数

    procedure BuildChain(ACentreHz: Double);
    procedure SendBlockOf(const AChars: array of Byte);
    procedure SendIdleBlock;
    procedure FlushTx;
    procedure EmitBlock;
  public
    constructor Create(ASound: TCustomSoundDevice;
      AMode: TModemMode = mmOlivia;
      ABitsPerSymbol: Integer = 5; ABandwidthHz: Integer = 1000);
      reintroduce;
    destructor Destroy; override;

    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
      override;
    function TxProcess: Integer; override;

    function DecoderName: string; override;
    function PipelineDelaySamples: Int64; override;
    { 同調し直す。Olivia はトーンの置き場所を bin で持っているので、
      周波数が変わったら鎖に伝えないと**指令だけ変わって音は動かない**。
      ほかのモデムは送受のたびに Frequency を読んでいるので要らないが、
      こちらは持ち方が違う。 }
    procedure SetFreq(AFreq: Double); override;

    property ToneMode: TOliviaToneMode read FTone;
    property BlockMode: TOliviaMode read FBlock;
    { 音を入れてから文字が出るまでの遅れ [サンプル]。 }
    property LatencySamples: Int64 read FLatencySamples;
    { 前置きに流す空きブロック数。受信側が切れ目を掴む材料になる。 }
    property PreambleBlocks: Integer read FPreBlocks;
    { 押し出しに流す空きブロック数。受信側の管を空にする。 }
    property FlushBlocks: Integer read FFlushBlocks;
    { いま掴んでいる切れ目。Z-01 の観測点。 }
    function SyncPhase: Integer;
    { 直近の同期 S/N。 }
    function SyncSnr: Double;
  end;

implementation

const
  { S/N を 0..100 の尺度に写す係数。fldigi olivia.cxx:
      metric = clamp(5.0 * (rx_snr - 3.0), 0, 100) }
  OLIVIA_METRIC_SCALE = 5.0;
  OLIVIA_METRIC_OFFSET = 3.0;

  { Evidence に載せる S/N の申告範囲 [dB]。頭出しが出す比は
    「山の高さ / 雑音の二乗平均の平方根」で、帯域を決めて測った値では
    ない。短波で意味を持つ範囲に切り、切ったことを申告する
    (MFSK 側と同じ扱い)。 }
  OLIVIA_SNR_MIN_DB = -20.0;
  OLIVIA_SNR_MAX_DB = 60.0;

  { 前置きのブロック数。掴み直しの実測 (2.4 ブロック) に 1 つ足した値。
    交信は交互になるので、前の局と切れ目が違うのが普通である。 }
  OLIVIA_PREAMBLE_BLOCKS = 4;

constructor TOliviaModem.Create(ASound: TCustomSoundDevice; AMode: TModemMode;
  ABitsPerSymbol, ABandwidthHz: Integer);
begin
  case AMode of
    mmOlivia: FTone.Variant_ := ovOlivia;
    mmContestia: FTone.Variant_ := ovContestia;
  else
    raise EOliviaModemError.CreateFmt(
      'このモデムが扱えるのは Olivia / Contestia です (指定: %s)',
      [ModemModeToStr(AMode)]);
  end;
  FTone.BitsPerSymbol := ABitsPerSymbol;
  FTone.BandwidthHz := ABandwidthHz;
  FTone.SampleRate := 8000;
  FBlock := FTone.BlockMode;

  inherited Create(ASound, AMode);
  SampleRate := FTone.SampleRate;
  Capabilities := Capabilities + [mcRx, mcTx, mcSquelch];

  Bandwidth := FTone.OccupiedBandwidthHz;
  Frequency := OLIVIA_DEFAULT_CENTRE_HZ;

  BuildChain(Frequency);
  FTunedHz := Frequency;
  Restart;
end;

procedure TOliviaModem.BuildChain(ACentreHz: Double);
var
  latSyms: Integer;
begin
  FSync := TOliviaSync.Create(FTone, ACentreHz);
  FEncoder := TOliviaBlockEncoder.Create(FBlock);
  FModulator := TOliviaModulator.Create(FTone, ACentreHz);

  SetLength(FAccum, FTone.SymbolSepar);
  SetLength(FTxChars, FBlock.CharsPerBlock);
  SetLength(FTxSyms, FBlock.SymbolsPerBlock);
  SetLength(FTxBuf, FTone.SymbolSepar);

  latSyms := FSync.LatencySymbols;
  FLatencySamples := Int64(latSyms) * FTone.SymbolSepar;

  { --- 押し出し ---
    受信側の管を空にするのに要る長さ。鎖の遅れ (4.5 ブロック) を
    切り上げた値で、実測の下限 (4 ブロック) より 1 つ多い。
    短くすると**最後のブロックが受信側から出てこない**。 }
  FFlushBlocks := (latSyms + FBlock.SymbolsPerBlock - 1)
                  div FBlock.SymbolsPerBlock;

  { --- 前置き ---
    無音から始めるだけなら 0 で足りる (実測)。**要るのは前の局が
    別の切れ目で喋ったあと**で、記録がその位相に寄っているところから
    掴み直すのに 2.4 ブロックかかる (README 47 章の実測)。
    交信は必ず交互になるので、そちらを前提に置く。
    押し出しと違って長さの根拠が「掴み直し」なので、別の値である。 }
  FPreBlocks := OLIVIA_PREAMBLE_BLOCKS;
end;

destructor TOliviaModem.Destroy;
begin
  FModulator.Free;
  FEncoder.Free;
  FSync.Free;
  inherited Destroy;
end;

function TOliviaModem.DecoderName: string;
begin
  if FTone.Variant_ = ovContestia then
    Result := Format('Contestia %d/%d', [FTone.Tones, FTone.BandwidthHz])
  else
    Result := Format('Olivia %d/%d', [FTone.Tones, FTone.BandwidthHz]);
end;

procedure TOliviaModem.SetFreq(AFreq: Double);
begin
  inherited SetFreq(AFreq);
  { 構築の途中はまだ鎖が無い。 }
  if FSync = nil then Exit;
  if AFreq = FTunedHz then Exit;
  FTunedHz := AFreq;
  FModulator.SetCentre(AFreq);
  FSync.SetCentre(AFreq);
  { 溜めかけの音は前の同調のものなので捨てる。 }
  FAccumLen := 0;
end;

function TOliviaModem.PipelineDelaySamples: Int64;
begin
  Result := FLatencySamples;
end;

function TOliviaModem.SyncPhase: Integer;
begin
  Result := FSync.BestPhase;
end;

function TOliviaModem.SyncSnr: Double;
begin
  Result := FSync.SyncSnr;
end;

{ ==========================================================================
  受信
  ========================================================================== }

procedure TOliviaModem.RxInit;
begin
  FSync.Reset;
  FAccumLen := 0;
  Metric := 0;
end;

procedure TOliviaModem.EmitBlock;
var
  i, c: Integer;
  ev: TDecodeEvidence;
  snr, pos: Double;
  samplePos: Int64;
begin
  snr := FSync.SyncSnr;
  Metric := ClampF(OLIVIA_METRIC_SCALE * (snr - OLIVIA_METRIC_OFFSET),
    0, 100);

  { 鎖の遅れを引いた位置を名乗る (見出しの説明を参照)。
    立ち上がりで遅れより前に出た結果は 0 に丸める。 }
  samplePos := StreamPosition - FLatencySamples;
  if samplePos < 0 then samplePos := 0;

  if snr > 0 then pos := 20 * Log10(snr) else pos := OLIVIA_SNR_MIN_DB;

  for i := 0 to FBlock.CharsPerBlock - 1 do
  begin
    c := FSync.OutputChar(i);
    { NUL は前置き・押し出し・詰め物である。出さない ―― 上流も
      画面には出さない。 }
    if c = 0 then Continue;

    { ADR-002: 確定文字ではなく候補と根拠を上げる。
      尺度はブロック単位の同期 S/N なので、**同じブロックの文字は
      同じ値を持つ**。文字ごとの確からしさではないことを、
      種類 (emkCorrelation) と合わせて読む側に伝える。 }
    ev := ScoredCandidateEvidence(c, snr, emkCorrelation, DecoderName);
    ev.SamplePos := samplePos;
    ev.HasSnr := True;
    ev.SnrDb := ClampF(pos, OLIVIA_SNR_MIN_DB, OLIVIA_SNR_MAX_DB);
    EmitDecode(ev);
    EmitEchoChar(c);
  end;
end;

function TOliviaModem.RxProcess(const ABuf: array of Double;
  ALen: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to ALen - 1 do
  begin
    FAccum[FAccumLen] := ABuf[i];
    Inc(FAccumLen);
    if FAccumLen >= FTone.SymbolSepar then
    begin
      FAccumLen := 0;
      if FSync.Process(FAccum) then
        EmitBlock;
    end;
  end;

  { 通算サンプル位置を進めるのは最後。この区画の中で確定した結果が
    「その区画の先頭」を基準にできるようにする。 }
  AdvanceStreamPos(ALen);
  Result := 0;
end;

{ ==========================================================================
  送信
  ========================================================================== }

procedure TOliviaModem.TxInit;
begin
  { 符号化器は状態を持たない (1 ブロックを入れたら 1 ブロック出るだけ)
    ので戻すものが無い。変調器は重ね合わせの環と位相を持つので戻す。 }
  FModulator.Reset;
  FTxFill := 0;
  FPreamblePending := True;
end;

procedure TOliviaModem.Restart;
begin
  RestoreCommandedFreq;
  RxInit;
  TxInit;
end;

procedure TOliviaModem.SendBlockOf(const AChars: array of Byte);
var
  i: Integer;
begin
  FEncoder.EncodeBlock(AChars, FTxSyms);
  for i := 0 to FBlock.SymbolsPerBlock - 1 do
  begin
    { Send は音を出さないときでも位相と環を進めるので、
      ここでは書き出しの有無だけを分ければよい。 }
    FModulator.Send(FTxSyms[i], FTxBuf);
    if Assigned(Sound) then
      Sound.WriteSamples(FTxBuf, FTone.SymbolSepar);
  end;
end;

procedure TOliviaModem.SendIdleBlock;
var
  i: Integer;
begin
  for i := 0 to FBlock.CharsPerBlock - 1 do FTxChars[i] := 0;
  SendBlockOf(FTxChars);
  FTxFill := 0;
end;

procedure TOliviaModem.FlushTx;
var
  i: Integer;
begin
  { 書きかけのブロックを NUL で埋めて出す。 }
  if FTxFill > 0 then
  begin
    for i := FTxFill to FBlock.CharsPerBlock - 1 do FTxChars[i] := 0;
    SendBlockOf(FTxChars);
    FTxFill := 0;
  end;
  { 受信側の管から最後の文字を押し出す。 }
  for i := 1 to FFlushBlocks do
    SendIdleBlock;
end;

function TOliviaModem.TxProcess: Integer;
var
  c, i: Integer;
begin
  if FPreamblePending then
  begin
    { 頭出し。受信側が切れ目を掴むまでの材料になる。 }
    for i := 1 to FPreBlocks do
      SendIdleBlock;
    FPreamblePending := False;
  end;

  c := FetchTxChar;

  if (c = MODEM_TX_CHAR_ETX) or StopFlag then
  begin
    StopFlag := False;
    FlushTx;
    FPreamblePending := True;
    Exit(-1);
  end;

  if c = MODEM_TX_CHAR_NODATA then
  begin
    SendIdleBlock;
    Exit(0);
  end;

  FTxChars[FTxFill] := Byte(c);
  Inc(FTxFill);
  if FTxFill >= FBlock.CharsPerBlock then
  begin
    SendBlockOf(FTxChars);
    FTxFill := 0;
  end;
  Result := 0;
end;

end.
