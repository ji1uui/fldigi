{ ============================================================================
  OliviaSync.pas

  Olivia / Contestia の**ブロックの頭出し**。音の層と符号の層の間に入り、
  「どこがブロックの切れ目か」を決める。

      音 -> [音の層] -> 軟判定 -> [ここ] -> [符号の層] -> 文字
            OliviaTones          頭出し    OliviaBlock

  なぜ難しいか
  ----------------------------------------------------------------------------
  Olivia には頭出しのための印が無い。前置き符号も、同期語も、無い。
  1 ブロック 64 シンボルのどこが先頭かを、**復号してみた結果の良さ**から
  逆に決めるしかない。

  やり方は単純である。考えられる切れ目を全部並べ、それぞれで復号を続け、
  **いちばん筋の通る切れ目**を採る。Walsh 関数は直交しているので、
  切れ目が合っていれば山が高く立ち、ずれていれば立たない。その差が
  そのまま選択の材料になる (§45 で 88.9 対 5.2..10.8 と実測してある)。

  切れ目の数
  ----------------------------------------------------------------------------
  音の層は 1 回の取り込みで半シンボルずれた 2 枚の spectrum を出す。
  したがって切れ目の候補は

      BlockPhases = 2 (spectrum の枚数) x SymbolsPerBlock

  で、Olivia 32/1000 なら 128 通りある。

  **復号器は 128 個も要らない。** 復号器は「直近 64 シンボル」を環に
  溜めていて、毎シンボル復号すれば *その時点を終わりとするブロック* が
  出る。つまり 1 つの復号器が全部の位相を順に出している。位相ごとに
  持つ必要があるのは、**出てきた結果と、その良さの記録**だけである。
  要るのは spectrum の枚数ぶん (2 個) だけ。

  いつ出すか
  ----------------------------------------------------------------------------
  最良の位相からちょうど半ブロック進んだ瞬間に、その位相の結果を出す。
  半ブロック待つのは、良さの記録がその位相を跨いで落ち着くまで待つため。

  出すのは管の**いちばん古い**もの (SyncIntegLen ブロック前) である。
  良さの記録は SyncIntegLen ブロックにわたってならしてあるので、
  そのブロックを含んだ記録で位相を選んだことになる。そのぶん遅れるが、
  **選ぶ前に出してしまうと、選び直したときに取り返せない。**

  上流と変えたところ
  ----------------------------------------------------------------------------
  - **周波数の探索をしていない。** 上流は位相と同時に周波数のずれも
    17 通り並べて探す。こちらは Phase 2 では扱わない (PSK の AFC を
    MDM-006 で Phase 3 に送ったのと同じ扱い) が、`FreqOffset` を外から
    与えられるようにしてある ―― Phase 3 の AFC がここを動かす。
  - **雑音の参照を現在の位相から取る。** 上流はこの場面で配列の添字を
    1 つ進め過ぎており、隣の位相の雑音を読んでいる。どちらも「最良から
    半ブロック離れた位相」なので実害は無いが、意図どおりのほうを採った。

  ここに無いもの
  ----------------------------------------------------------------------------
  モデムとしての繋ぎこみ (TCustomModem の実装) は次の層。
  ここが持つのは「音を入れるとブロックが出てくる」ところまでである。
  ============================================================================ }
unit OliviaSync;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemTypes, ModemDSP, OliviaBlock, OliviaTones;

const
  { 良さをならす長さ [ブロック]。上流 SyncIntegLen の既定。
    短いと雑音で位相が踊り、長いと本物の切れ目に追いつくのが遅くなる。 }
  OLIVIA_SYNC_INTEG_BLOCKS = 4;

  { 文字を出す S/N の下限。上流 SyncThreshold。これを下回る間は
    「まだ掴めていない」とみなして黙る。上流は 3.0 を下限としている。 }
  OLIVIA_SYNC_THRESHOLD = 3.0;

  { S/N がこれを超えたら記録を捨てて測り直す。上流と同じ。
    立ち上がりで一度だけ跳ね上がることがあり、そのまま居座らせない。 }
  OLIVIA_SYNC_SNR_RESET = 100.0;

type
  EOliviaSyncError = class(Exception);

  TOliviaSync = class
  private
    FMode: TOliviaToneMode;
    FBlockMode: TOliviaMode;
    FDemod: TOliviaDemodulator;
    FDec: array of TOliviaBlockDecoder;   // spectrum の枚数ぶん
    FSoft: array of Double;

    FPhases: Integer;         // 2 x SymbolsPerBlock
    FPhase: Integer;
    FWeight: Double;          // 1 / SyncIntegLen

    FSignal: array of TLowPass3;   // [FPhases]
    FNoise: array of TLowPass3;    // [FPhases]

    { 位相ごとの結果の管。[FPhases][IntegBlocks][CharsPerBlock] を平坦に。 }
    FPipe: array of Byte;
    FPipePtr: array of Integer;    // [FPhases]

    FBestPhase: Integer;
    FBestSignal: Double;
    FSyncSnr: Double;
    FChars: array of Byte;         // 直近に確定したブロック
    FHasOutput: Boolean;
    FThreshold: Double;
    FFreqOffset: Integer;
    FBlocksOut: Int64;
    FSymbolsIn: Int64;

    function PipeSlot(APhase, AIndex: Integer): Integer; inline;
    procedure StoreBlock(APhase: Integer; ADec: TOliviaBlockDecoder);
    procedure LoadBlock(APhase: Integer);
  public
    constructor Create(const AMode: TOliviaToneMode; ACentreHz: Double = 0);
    destructor Destroy; override;

    { 受信状態を初期に戻す。前の音を持ち越さない (X-06 / Z-05)。 }
    procedure Reset;

    { 同調し直す。復調器の bin を決め直し、掴んでいた切れ目も捨てる ――
      別の周波数を聞くのだから、前の切れ目に意味は無い。 }
    procedure SetCentre(AHz: Double);

    { 1 シンボルぶんの音 (SymbolSepar サンプル)。ブロックが確定したら
      True を返し、OutputChar が読める。確保しない (X-04)。 }
    function Process(const ABuf: array of Double): Boolean;

    { 直近に確定したブロックの文字。添字は 0..CharsPerBlock-1。 }
    function OutputChar(AIndex: Integer): Byte;

    { いま掴んでいる切れ目。0..BlockPhases-1。 }
    property BestPhase: Integer read FBestPhase;
    { 直近に測った S/N。文字を出すかどうかの判断そのものである。 }
    property SyncSnr: Double read FSyncSnr;
    { 文字を出す下限。運用では Squelch がここを動かす。 }
    property Threshold: Double read FThreshold write FThreshold;
    { 周波数のずれ [bin]。Phase 3 の AFC がここを動かす。
      **DecodeMargin を超える値を入れると Process で例外になる。**
      動かす側が範囲を知れるように、その幅もここから見えるようにしてある。 }
    property FreqOffset: Integer read FFreqOffset write FFreqOffset;
    { FreqOffset に入れてよい幅 [bin]。-DecodeMargin..+DecodeMargin。 }
    function DecodeMargin: Integer;

    property Mode: TOliviaToneMode read FMode;
    property BlockMode: TOliviaMode read FBlockMode;
    { 切れ目の候補の数。 }
    property BlockPhases: Integer read FPhases;
    { 出したブロックの数。 }
    function BlocksOut: Int64;
    { 入れたシンボルの数。遅れを数えるのに使う。 }
    function SymbolsIn: Int64;
    { 音を入れてから文字が出るまでの遅れ [シンボル]。
      管の深さと半ブロックぶんの待ちから決まる値で、実測ではない。 }
    function LatencySymbols: Integer;
  end;

implementation

constructor TOliviaSync.Create(const AMode: TOliviaToneMode;
  ACentreHz: Double);
var
  i: Integer;
begin
  inherited Create;
  FMode := AMode;
  FBlockMode := AMode.BlockMode;
  FDemod := TOliviaDemodulator.Create(AMode, ACentreHz);

  SetLength(FDec, OLIVIA_SLICES);
  for i := 0 to OLIVIA_SLICES - 1 do
    FDec[i] := TOliviaBlockDecoder.Create(FBlockMode);

  SetLength(FSoft, AMode.BitsPerSymbol);
  FPhases := OLIVIA_SLICES * FBlockMode.SymbolsPerBlock;
  FWeight := 1.0 / OLIVIA_SYNC_INTEG_BLOCKS;

  SetLength(FSignal, FPhases);
  SetLength(FNoise, FPhases);
  SetLength(FPipe,
    FPhases * OLIVIA_SYNC_INTEG_BLOCKS * FBlockMode.CharsPerBlock);
  SetLength(FPipePtr, FPhases);
  SetLength(FChars, FBlockMode.CharsPerBlock);

  FThreshold := OLIVIA_SYNC_THRESHOLD;
  FFreqOffset := 0;
  Reset;
end;

destructor TOliviaSync.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FDec) do FDec[i].Free;
  FDemod.Free;
  inherited Destroy;
end;

procedure TOliviaSync.Reset;
var
  i: Integer;
begin
  FDemod.Reset;
  for i := 0 to High(FDec) do FDec[i].Reset;
  for i := 0 to FPhases - 1 do
  begin
    FSignal[i].Reset(0);
    FNoise[i].Reset(0);
    FPipePtr[i] := 0;
  end;
  for i := 0 to High(FPipe) do FPipe[i] := 0;
  for i := 0 to High(FChars) do FChars[i] := 0;
  FPhase := 0;
  FBestPhase := 0;
  FBestSignal := 0;
  FSyncSnr := 0;
  FHasOutput := False;
  FBlocksOut := 0;
  FSymbolsIn := 0;
end;

procedure TOliviaSync.SetCentre(AHz: Double);
begin
  FDemod.SetCentre(AHz);
  Reset;
end;

function TOliviaSync.PipeSlot(APhase, AIndex: Integer): Integer;
begin
  Result := (APhase * OLIVIA_SYNC_INTEG_BLOCKS + AIndex)
            * FBlockMode.CharsPerBlock;
end;

procedure TOliviaSync.StoreBlock(APhase: Integer;
  ADec: TOliviaBlockDecoder);
var
  i, slot: Integer;
begin
  slot := PipeSlot(APhase, FPipePtr[APhase]);
  for i := 0 to FBlockMode.CharsPerBlock - 1 do
    FPipe[slot + i] := ADec.OutputChar(i);
  Inc(FPipePtr[APhase]);
  if FPipePtr[APhase] >= OLIVIA_SYNC_INTEG_BLOCKS then FPipePtr[APhase] := 0;
end;

procedure TOliviaSync.LoadBlock(APhase: Integer);
var
  i, slot: Integer;
begin
  { 次に書く場所 = 環でいちばん古いもの。良さの記録がならし終えた
    ぶんだけ遡ることになる。 }
  slot := PipeSlot(APhase, FPipePtr[APhase]);
  for i := 0 to FBlockMode.CharsPerBlock - 1 do
    FChars[i] := FPipe[slot + i];
end;

function TOliviaSync.Process(const ABuf: array of Double): Boolean;
var
  slice, dist: Integer;
  sig, noise: Double;
begin
  Result := False;
  FHasOutput := False;
  FDemod.Process(ABuf);
  Inc(FSymbolsIn);

  for slice := 0 to OLIVIA_SLICES - 1 do
  begin
    FDemod.SoftDecode(slice, FSoft, FFreqOffset);
    FDec[slice].Input(FSoft);
    FDec[slice].Process;

    { この位相の良さを記録する。 }
    FSignal[FPhase].Process(FDec[slice].Signal, FWeight);
    FNoise[FPhase].Process(FDec[slice].NoiseEnergy, FWeight);
    StoreBlock(FPhase, FDec[slice]);

    { 最良の位相を追う。いま居るのが最良の位相なら、記録をそのまま
      更新する ―― 下がったときに下がったと分かるようにするためで、
      これをしないと一度上がった位相に張り付いて動かなくなる。 }
    sig := FSignal[FPhase].Output;
    if FPhase = FBestPhase then
      FBestSignal := sig
    else if sig > FBestSignal then
    begin
      FBestSignal := sig;
      FBestPhase := FPhase;
    end;

    { 最良からちょうど半ブロック進んだら出す。 }
    dist := FPhase - FBestPhase;
    if dist < 0 then Inc(dist, FPhases);
    if dist = FPhases div 2 then
    begin
      noise := Sqrt(FNoise[FPhase].Output);
      if noise = 0 then FSyncSnr := 0
      else FSyncSnr := FBestSignal / noise;

      if FSyncSnr >= FThreshold then
      begin
        LoadBlock(FBestPhase);
        FHasOutput := True;
        Result := True;
        Inc(FBlocksOut);
      end;

      { 立ち上がりで跳ね上がった記録を居座らせない (上流と同じ)。 }
      if FSyncSnr > OLIVIA_SYNC_SNR_RESET then FSyncSnr := 0;
    end;

    Inc(FPhase);
    if FPhase >= FPhases then Dec(FPhase, FPhases);
  end;
end;

function TOliviaSync.OutputChar(AIndex: Integer): Byte;
begin
  if not FHasOutput then
    raise EOliviaSyncError.Create(
      'まだブロックが確定していません (Process が True を返したときだけ読めます)');
  if (AIndex < 0) or (AIndex >= FBlockMode.CharsPerBlock) then
    raise EOliviaSyncError.CreateFmt('文字の位置が範囲外です (%d / 0..%d)',
      [AIndex, FBlockMode.CharsPerBlock - 1]);
  Result := FChars[AIndex];
end;

function TOliviaSync.DecodeMargin: Integer;
begin
  Result := FDemod.DecodeMargin;
end;

function TOliviaSync.BlocksOut: Int64;
begin
  Result := FBlocksOut;
end;

function TOliviaSync.SymbolsIn: Int64;
begin
  Result := FSymbolsIn;
end;

function TOliviaSync.LatencySymbols: Integer;
begin
  { 管の深さ (IntegBlocks ブロック) + 出すまでの半ブロック。
    1 ブロック = SymbolsPerBlock シンボル。 }
  Result := (2 * OLIVIA_SYNC_INTEG_BLOCKS + 1)
            * FBlockMode.SymbolsPerBlock div 2;
end;

end.
