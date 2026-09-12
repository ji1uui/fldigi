{ ============================================================================
  MfskTones.pas

  MFSK の「音の層」のうち、**トーンを測って軟判定に落とす**ところ。

  MFSK の受信はこう繋がっている。

      音 -> [ここ] -> 軟判定ビット -> 戻し -> Viterbi -> ビット -> Varicode -> 文字
            トーン検出              Interleaver  ConvCodec        MfskVaricode

  ここが出すのは 1 シンボルあたり SymBits 本の軟判定 (0..255) である。
  硬判定にしないのは、Viterbi が曖昧さごと足し合わせて道を選ぶからで、
  軟判定のほうが明確に強い (test_fec で 27/30 対 18/30 を実測)。

  トーンの測り方
  ----------------------------------------------------------------------------
  MFSK16 は 8 kHz で 512 サンプルが 1 シンボル、トーンは 15.625 Hz 間隔で
  16 本、最低トーンが 1000 Hz (bin 64) である。つまり **シンボル長の DFT の
  bin がそのままトーン** になる。

  必要なのは 16 本だけで、しかも 1 サンプルずつ窓をずらして見たい
  (シンボル境界を探すため)。そこで滑る DFT (ModemDSP.TSlidingDft) を使う。
  512 点 FFT を毎サンプル回すのに比べて桁違いに軽い。

  前段について
  ----------------------------------------------------------------------------
  fldigi は Hilbert 変換で解析信号にしてから混ぜている。ここでは RTTY と
  同じく (x, x) で複素にしてから混ぜる。解析信号にはならず負の周波数側に
  像が残るが、滑る DFT が見るのは正の側の 16 本だけで、像は 128 bin 以上
  離れる。矩形窓の漏れは距離 128 bin で -50 dB 程度なので埋もれる。
  (Hilbert を入れればさらに落ちる。必要になったら測ってから入れる。)

  軟判定の作り方
  ----------------------------------------------------------------------------
  トーン i が鳴っていれば、そのトーンが表すビット並びが正しい。そこで
  各ビット位置について、**そのビットが 1 になるトーンの大きさを足し、
  0 になるトーンの大きさを引く**。差が大きいほどそのビットは確からしい。

      b[k] = Σ_i ( bit k of gray(i) ? +|X_i| : -|X_i| )
      soft[k] = 128 + b[k] / Σ|X| * 256   (0..255 に丸める)

  gray(i) を挟むのは、隣のトーンと取り違えてもビット誤りが 1 本で済む
  ようにするためである (ModemDSP.GrayEncode の説明を参照)。
  硬判定で選んだトーンだけ 2 倍に重み付けするのは fldigi と同じで、
  「一番大きかった」という判断にも一票入れる意味がある。

  実装していないもの
  ----------------------------------------------------------------------------
  - **シンボル同期の追尾**。いまは SymLen ごとに区切るだけである。
    送受でサンプルが揃っていれば動くが、ずれると崩れる。次段で入れる。
  - **AFC**。周波数のずれは追わない。
  - **CWI 回避** (定常搬送波が 1 トーンに居座る場合の穴あけ)。
    Phase 3 の QRM 対策で扱う。
  - **staticburst による穴あけ**。fldigi には書かれているが、条件が
    「全トーンが平均の 2 倍を超える」であり、平均の定義から **決して
    成立しない** (全部が平均の 2 倍を超えるなら総和が総和の 2 倍になる)。
    上流でも死んだ枝なので、写さずに落としてある。
  ============================================================================ }
unit MfskTones;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemTypes, ModemDSP;

const
  { 1 シンボルが運べるビット数の上限。MFSK 系は 3..5 だが、
    作業用配列の大きさを決めるために上限を置いてある。 }
  MFSK_MAX_SYMBITS = 8;

type
  EMfskError = class(Exception);

  { モードの諸元 (fldigi src/mfsk/mfsk.cxx の switch)。 }
  TMfskMode = record
    Name: string;
    SampleRate: Integer;
    SymLen: Integer;      // 1 シンボルのサンプル数
    SymBits: Integer;     // 1 シンボルが運ぶビット数
    BaseTone: Integer;    // 最低トーンの bin 番号
    NumTones: Integer;    // トーンの本数 (= 2^SymBits)
    Depth: Integer;       // インタリーバの段数
    { トーンの間隔 [Hz]。シンボル速度と同じ値になる。 }
    function ToneSpacingHz: Double;
    { 最低トーンの周波数 [Hz]。 }
    function BaseFreqHz: Double;
    { 占有幅 [Hz]。 }
    function BandwidthHz: Double;
    { 信号の中心周波数 [Hz]。運用上「ここに合わせる」値。 }
    function CentreFreqHz: Double;
    { シンボル速度 [baud]。 }
    function BaudRate: Double;
    function Describe: string;
  end;

const
  { MFSK16。fldigi: MODE_MFSK16 }
  MFSK16_MODE: TMfskMode = (
    Name: 'MFSK16'; SampleRate: 8000; SymLen: 512; SymBits: 4;
    BaseTone: 64; NumTones: 16; Depth: 10);

  { MFSK32。倍の速さ。 }
  MFSK32_MODE: TMfskMode = (
    Name: 'MFSK32'; SampleRate: 8000; SymLen: 256; SymBits: 4;
    BaseTone: 32; NumTones: 16; Depth: 10);

type
  { トーン検出器。
    実音声を 1 サンプルずつ入れると、シンボル境界で結果が出る。

    スレッド: 一つのスレッドから使う。内部に位相と DFT の状態を持つ。 }
  TMfskToneDetector = class
  private
    FMode: TMfskMode;
    FDft: TSlidingDft;
    FBins: TComplexArray;
    FMag: array of Double;      // 直近シンボルのトーンの大きさ
    FSoft: array of Byte;       // 直近シンボルの軟判定
    FPhase: Double;
    FMixHz: Double;
    FCounter: Integer;
    FSymbol: Integer;
    FTotalSymbols: Int64;
    procedure DecideSymbol;
  public
    constructor Create(const AMode: TMfskMode; ACentreHz: Double = 0);
    destructor Destroy; override;

    { 受信状態を初期に戻す。前の音を持ち越さない (X-06 / Z-05)。 }
    procedure Reset;

    { 実音声を 1 サンプル。シンボル境界に達したら True を返し、
      Symbol と SoftBit が更新される。確保しない (X-04)。 }
    function Feed(ASample: Double): Boolean;

    { 直近シンボルで最も強かったトーン (0..NumTones-1)。 }
    property Symbol: Integer read FSymbol;
    { 直近シンボルの軟判定。添字は 0..SymBits-1 で、0 が最上位ビット。 }
    function SoftBit(AIndex: Integer): Byte;
    { 直近シンボルのトーンの大きさ。診断と次段のシンボル同期に使う。 }
    function ToneMagnitude(AIndex: Integer): Double;

    { 合わせている中心周波数 [Hz]。 }
    property CentreHz: Double read FMixHz;
    property Mode: TMfskMode read FMode;
    { これまでに切り出したシンボル数。 }
    function TotalSymbols: Int64;
  end;

{ シンボル値をトーン番号へ (送信側)。
  fldigi: sendsymbol() の grayencode() ―― 名前は逆だが畳み込みのほう。 }
function MfskSymbolToTone(ASymbol: Integer): Integer;
{ トーン番号をシンボル値へ (受信側)。
  fldigi: softdecode() の graydecode() ―― x xor (x shr 1) のほう。 }
function MfskToneToSymbol(ATone: Integer): Integer;

implementation

function TMfskMode.ToneSpacingHz: Double;
begin
  Result := SampleRate / SymLen;
end;

function TMfskMode.BaseFreqHz: Double;
begin
  Result := SampleRate * BaseTone / SymLen;
end;

function TMfskMode.BandwidthHz: Double;
begin
  { fldigi: bw = (numtones - 1) * tonespacing
    端から端までなので本数 - 1 である。 }
  Result := (NumTones - 1) * ToneSpacingHz;
end;

function TMfskMode.CentreFreqHz: Double;
begin
  Result := BaseFreqHz + BandwidthHz / 2;
end;

function TMfskMode.BaudRate: Double;
begin
  Result := SampleRate / SymLen;
end;

function TMfskMode.Describe: string;
begin
  Result := Format('%s: %.3f baud / %d トーン / %.3f Hz 間隔 / %.1f..%.1f Hz',
    [Name, BaudRate, NumTones, ToneSpacingHz,
     BaseFreqHz, BaseFreqHz + BandwidthHz]);
end;

function MfskSymbolToTone(ASymbol: Integer): Integer;
begin
  Result := Integer(GrayDecode(LongWord(ASymbol)));
end;

function MfskToneToSymbol(ATone: Integer): Integer;
begin
  Result := Integer(GrayEncode(LongWord(ATone)));
end;

{ TMfskToneDetector }

constructor TMfskToneDetector.Create(const AMode: TMfskMode; ACentreHz: Double);
begin
  inherited Create;
  if AMode.NumTones <> (1 shl AMode.SymBits) then
    raise EMfskError.CreateFmt(
      '%s: トーン数 %d が 2^%d と合いません',
      [AMode.Name, AMode.NumTones, AMode.SymBits]);
  if (AMode.SymBits < 1) or (AMode.SymBits > MFSK_MAX_SYMBITS) then
    raise EMfskError.CreateFmt(
      '%s: 1 シンボルのビット数は 1..%d です (指定 %d)',
      [AMode.Name, MFSK_MAX_SYMBITS, AMode.SymBits]);
  if AMode.BaseTone + AMode.NumTones > AMode.SymLen then
    raise EMfskError.CreateFmt(
      '%s: トーンがシンボル長の DFT に収まりません (%d + %d > %d)',
      [AMode.Name, AMode.BaseTone, AMode.NumTones, AMode.SymLen]);

  FMode := AMode;
  if ACentreHz > 0 then FMixHz := ACentreHz
  else FMixHz := AMode.CentreFreqHz;

  FDft := TSlidingDft.Create(FMode.SymLen, FMode.BaseTone, FMode.NumTones);
  SetLength(FBins, FMode.NumTones);
  SetLength(FMag, FMode.NumTones);
  SetLength(FSoft, FMode.SymBits);
  Reset;
end;

destructor TMfskToneDetector.Destroy;
begin
  FDft.Free;
  inherited Destroy;
end;

procedure TMfskToneDetector.Reset;
var
  i: Integer;
begin
  FDft.Reset;
  FPhase := 0;
  FCounter := FMode.SymLen;
  FSymbol := 0;
  FTotalSymbols := 0;
  for i := 0 to FMode.NumTones - 1 do FMag[i] := 0;
  for i := 0 to FMode.SymBits - 1 do FSoft[i] := 128;
end;

procedure TMfskToneDetector.DecideSymbol;
var
  tone, bit, symValue: Integer;
  sum, best, mag, weight, v: Double;
  acc: array[0..MFSK_MAX_SYMBITS - 1] of Double;
begin
  { --- 大きさを測り、いちばん強いトーンを選ぶ (硬判定) --- }
  sum := 0;
  best := -1;
  FSymbol := 0;
  for tone := 0 to FMode.NumTones - 1 do
  begin
    mag := CplxAbs(FBins[tone]);
    FMag[tone] := mag;
    sum := sum + mag;
    if mag > best then
    begin
      best := mag;
      FSymbol := tone;
    end;
  end;
  { 無音のとき 0 で割らない。 }
  if sum < 1E-10 then sum := 1E-10;

  { --- ビットごとに「1 側」と「0 側」の大きさを集める ---
    トーン tone が表すシンボル値の各ビットを見て、1 なら足し 0 なら引く。
    差が大きいほどそのビットは確からしい。 }
  for bit := 0 to FMode.SymBits - 1 do acc[bit] := 0;

  for tone := 0 to FMode.NumTones - 1 do
  begin
    weight := FMag[tone];
    { 硬判定で選んだトーンには重みを 2 倍。fldigi と同じで、
      「一番大きかった」という判断にも一票入れる意味がある。 }
    if tone = FSymbol then weight := 2 * weight;

    symValue := MfskToneToSymbol(tone);
    for bit := 0 to FMode.SymBits - 1 do
      { 添字 0 が最上位ビット (fldigi: 1 << (symbits - k - 1))。 }
      if (symValue and (1 shl (FMode.SymBits - bit - 1))) <> 0 then
        acc[bit] := acc[bit] + weight
      else
        acc[bit] := acc[bit] - weight;
  end;

  { --- 0..255 に写す。128 が「分からない」 --- }
  for bit := 0 to FMode.SymBits - 1 do
  begin
    v := 128 + acc[bit] / sum * 256.0;
    if v < 0 then v := 0;
    if v > 255 then v := 255;
    FSoft[bit] := Byte(Round(v));
  end;

  Inc(FTotalSymbols);
end;

function TMfskToneDetector.Feed(ASample: Double): Boolean;
var
  z: TComplex;
begin
  { 実音声を複素にする。解析信号ではないが、見る bin は正の側だけで
    像は遠いので埋もれる (見出しの説明を参照)。 }
  z := CplxMake(ASample, ASample);
  { 最低トーンが bin BaseTone に来るように下へずらす。 }
  z := ComplexMix(FPhase, FMixHz - FMode.CentreFreqHz, FMode.SampleRate, z);
  FDft.Run(z, FBins);

  Dec(FCounter);
  Result := FCounter <= 0;
  if Result then
  begin
    FCounter := FMode.SymLen;
    DecideSymbol;
  end;
end;

function TMfskToneDetector.SoftBit(AIndex: Integer): Byte;
begin
  if (AIndex < 0) or (AIndex >= FMode.SymBits) then
    raise EMfskError.CreateFmt(
      'ビット位置が範囲外です (%d / 0..%d)', [AIndex, FMode.SymBits - 1]);
  Result := FSoft[AIndex];
end;

function TMfskToneDetector.ToneMagnitude(AIndex: Integer): Double;
begin
  if (AIndex < 0) or (AIndex >= FMode.NumTones) then
    raise EMfskError.CreateFmt(
      'トーン番号が範囲外です (%d / 0..%d)', [AIndex, FMode.NumTones - 1]);
  Result := FMag[AIndex];
end;

function TMfskToneDetector.TotalSymbols: Int64;
begin
  Result := FTotalSymbols;
end;

end.
