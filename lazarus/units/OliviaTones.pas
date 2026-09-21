{ ============================================================================
  OliviaTones.pas

  Olivia / Contestia の**音の層**。シンボル値をトーンにして音にし、
  受け取った音からトーンを測って軟判定に落とす。

  符号の層 (OliviaBlock) との繋がり

      送信  文字 -> [符号の層] -> シンボル値 -> [ここ] -> 音
      受信  音 -> [ここ] -> 軟判定 (符号つき実数) -> [符号の層] -> 文字

  MFSK16 の音の層 (MfskTones) と違うところ
  ----------------------------------------------------------------------------
  MFSK16 は 1 シンボルを 1 区画の矩形窓で送り、滑る DFT で追う。
  Olivia は違う。

  - **シンボルが半分ずつ重なる。** 1 シンボルの長さは SymbolLen だが、
    送り出す間隔は SymbolSepar = SymbolLen/2 である。持ち上がり波形
    (1 - cos) を掛けて足し合わせると、重なった包絡線がちょうど平らになる
    (1-cos(x) + 1-cos(x+pi) = 2)。矩形で切らないので帯域外への漏れが小さい。
  - **FFT で測る。** 毎サンプル追う必要が無く、半シンボルごとに 1 回
    まとめて変換する。しかも実数列 2 本を 1 回の複素 FFT に詰めるので
    (ModemDSP.SplitTwoRealSpectra)、半シンボルあたり FFT 1 回で済む。
  - **1 回の取り込みで 2 枚の spectrum が出る。** 窓を SymbolLen/4 ずつ
    ずらした 2 枚で、どちらがシンボルの区切りに合っているかは次の層
    (ブロックの頭出し) が選ぶ。ここでは両方を出すところまでを持つ。

  トーンの置き方
  ----------------------------------------------------------------------------
  トーン k は bin FirstCarrier + 2k に置く。bin を 1 つ飛ばしにしてある
  (CarrierSepar = 2) のは、持ち上がり窓の主葉が bin 2 本ぶんの幅を持つ
  ためである。詰めると隣に漏れる。

  FirstCarrier は、トーンの列の中心が指定の周波数に来るように決める。

      FirstCarrier = round(f * SymbolLen / SampleRate) - (Tones - 1)

  上流は (SymbolLen/16) * (f - Bandwidth*(1 - 0.5/Tones)/2) / 500 + 1 という
  別の形で書いているが、同じ値になる ―― Olivia 32/1000 を 1000 Hz に
  置くと、どちらも bin 33 である。こちらの形にしたのは、**何を意図して
  いるかがそのまま読める**からである。

  軟判定の向き
  ----------------------------------------------------------------------------
  符号の層が要求する **正 = ビット 0 / 負 = ビット 1** で出す。
  値は -1..+1 に正規化してある。添字は**最下位ビットが 0 番**である
  (MFSK 側は最上位が 0 番。層ごとに約束が違うので取り違えないこと)。

  トーンの重みに energy の二乗 (|X|^4) を使うのは上流と同じである。
  山を際立たせ、二番手以下の寄与を抑える。

  実装していないもの
  ----------------------------------------------------------------------------
  - **ブロックの頭出し** (どの spectrum がシンボルの区切りか)。次の層。
  - **AFC**。ただし復号の窓に余裕 (DecodeMargin) を取ってあり、
    bin 単位のずれを指定して読める。次の層が探索に使う。
  - 入力段の雑音・混信制限 (上流の MFSK_InputProcessor)。Phase 3 の
    Noise Estimator と合わせて扱う。
  - 送信のサンプル速度変換 (上流の RateConverter)。音声側が 8 kHz で
    揃っているので要らない。

  上流のどこを見たか
  ----------------------------------------------------------------------------
  src/include/jalocha/pj_mfsk.h の MFSK_Modulator / MFSK_Demodulator、
  および src/olivia/olivia.cxx の諸元の決め方。
  ============================================================================ }
unit OliviaTones;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemTypes, ModemDSP, OliviaBlock;

const
  { 既定の中心周波数 [Hz]。上流 fldigi の待ち受けと同じ値である。
    もとは占有幅から作った式を置いていたが、**何を意図した値なのかを
    説明できなかった**。試験からも呼ばれておらず、説明できないものが
    黙って効く状態だったので、値を決め打ちにして試験を付けた。 }
  OLIVIA_DEFAULT_CENTRE_HZ = 1000.0;

  { トーンを置く bin の間隔。持ち上がり窓の主葉が 2 bin ぶんあるので
    詰められない (上流: CarrierSepar)。 }
  OLIVIA_CARRIER_SEPAR = 2;

  { 1 回の取り込みで出る spectrum の枚数。窓を SymbolLen/4 ずらした 2 枚。 }
  OLIVIA_SLICES = 2;

  { 復号の窓に取る余裕 [bin]。周波数がずれていても読めるように、
    トーンの列の外側にこれだけ余分に energy を持つ。
    次の層がここを探索して合わせる (上流: DecodeMargin)。 }
  OLIVIA_DECODE_MARGIN = 32;

type
  { 音の層の諸元。符号の層の諸元 (方式とビット数) に、帯域と標本化
    周波数を足したもの。 }
  TOliviaToneMode = record
    Variant_: TOliviaVariant;
    BitsPerSymbol: Integer;
    BandwidthHz: Integer;     // 125 / 250 / 500 / 1000 / 2000
    SampleRate: Integer;

    { 符号の層へ渡す諸元。二重に持たず、ここから作る。 }
    function BlockMode: TOliviaMode;
    function Tones: Integer;
    { 1 シンボルの長さ [サンプル]。2 の冪乗。
      上流: 1 shl (BitsPerSymbol + 7 - Log2(Bandwidth/125)) }
    function SymbolLen: Integer;
    { シンボルを送り出す間隔。重なるので長さの半分である。 }
    function SymbolSepar: Integer;
    function BaudRate: Double;
    function BinWidthHz: Double;
    function ToneSpacingHz: Double;
    { 端から端までの占有幅。上流の set_bandwidth と同じ取り方。 }
    function OccupiedBandwidthHz: Double;
    function Describe: string;
  end;

const
  { Olivia 32/1000。もっとも使われる諸元。 }
  OLIVIA_32_1000: TOliviaToneMode = (Variant_: ovOlivia; BitsPerSymbol: 5;
    BandwidthHz: 1000; SampleRate: 8000);
  { Olivia 16/500。狭くて遅い。 }
  OLIVIA_16_500: TOliviaToneMode = (Variant_: ovOlivia; BitsPerSymbol: 4;
    BandwidthHz: 500; SampleRate: 8000);
  { Contestia 32/1000。 }
  CONTESTIA_32_1000: TOliviaToneMode = (Variant_: ovContestia;
    BitsPerSymbol: 5; BandwidthHz: 1000; SampleRate: 8000);

type
  EOliviaToneError = class(Exception);

  { --- 送信側 ---
    Send を 1 回呼ぶと SymbolSepar サンプルぶんの音が出る。
    シンボルは半分ずつ重なるので、最初の 1 回だけは前半に前のシンボルが
    無い (立ち上がりになる)。 }
  TOliviaModulator = class
  private
    FMode: TOliviaToneMode;
    FCentreHz: Double;
    FFirstCarrier: Integer;
    FLen: Integer;             // SymbolLen
    FSepar: Integer;           // SymbolSepar
    FWrapMask: Integer;
    FCos: array of Double;     // 長さ SymbolLen の余弦表 (位相は整数添字)
    FTap: array of Double;     // 足し合わせの環
    FTapPtr: Integer;
    FPhase: Integer;           // 余弦表の添字。整数なので誤差が溜まらない
    FDither: QWord;            // ±90 度の揺らぎを決める種
    procedure AddSymbol(AFreqBin, APhase: Integer);
    function NextDither: Integer;
  public
    constructor Create(const AMode: TOliviaToneMode; ACentreHz: Double = 0);
    procedure Reset;
    { 同調し直す。トーンの置き場所 (bin) を計算し直して状態を戻す。
      収まらない周波数なら例外にする ―― 黙って別の bin に出すより、
      出せないと言うほうがよい。 }
    procedure SetCentre(AHz: Double);
    { シンボル値 (0..Tones-1) を送る。ABuf に SymbolSepar サンプル返す。
      確保しない (X-04)。 }
    procedure Send(ASymbol: Integer; var ABuf: array of Double);
    { 送信を終えるときに呼ぶ。最後のシンボルの後半を押し出す。 }
    procedure Flush(var ABuf: array of Double);

    property Mode: TOliviaToneMode read FMode;
    property CentreHz: Double read FCentreHz;
    { トーン 0 が乗る bin。診断と試験のため。 }
    property FirstCarrier: Integer read FFirstCarrier;
    property SymbolSepar: Integer read FSepar;
  end;

  { --- 受信側 ---
    Process に SymbolSepar サンプル入れると、窓を SymbolLen/4 ずらした
    2 枚の spectrum ができる。どちらが区切りに合っているかは次の層が選ぶ。 }
  TOliviaDemodulator = class
  private
    FMode: TOliviaToneMode;
    FCentreHz: Double;
    FFirstCarrier: Integer;
    FLen: Integer;
    FSepar: Integer;
    FSepar2: Integer;          // SymbolSepar/2 = SymbolLen/4
    FWrapMask: Integer;
    FWindow: array of Double;  // 持ち上がり窓 (1-cos)/N
    FTap: array of Double;
    FTapPtr: Integer;
    FFft: TComplexArray;
    FSpec0, FSpec1: TComplexArray;
    FEnergy: array of Double;  // [OLIVIA_SLICES][DecodeWidth] を平坦に
    FMargin: Integer;
    FWidth: Integer;           // DecodeWidth
    FProcessed: Int64;
    function EnergyAt(ASlice, AIndex: Integer): Double; inline;
    procedure CheckSlice(ASlice: Integer);
    procedure CheckOffset(AFreqOffset: Integer);
  public
    constructor Create(const AMode: TOliviaToneMode; ACentreHz: Double = 0);
    procedure Reset;
    { 同調し直す。読む bin と探索の余裕を決め直して状態を戻す。 }
    procedure SetCentre(AHz: Double);
    { SymbolSepar サンプル入れる。確保しない (X-04)。 }
    procedure Process(const ABuf: array of Double);

    { もっとも強かったトーンのシンボル値。AFreqOffset は bin 単位の
      ずらし量で、-Margin..+Margin の範囲で指定できる。 }
    function HardDecode(ASlice: Integer; AFreqOffset: Integer = 0): Integer;
    { 軟判定。正がビット 0、負がビット 1。添字 0 が最下位ビット。
      ASoft は BitsPerSymbol 個以上。確保しない。 }
    procedure SoftDecode(ASlice: Integer; var ASoft: array of Double;
      AFreqOffset: Integer = 0);
    { トーンの energy。診断と次の層のため。 }
    function ToneEnergy(ASlice, AToneIndex: Integer;
      AFreqOffset: Integer = 0): Double;

    property Mode: TOliviaToneMode read FMode;
    property CentreHz: Double read FCentreHz;
    property FirstCarrier: Integer read FFirstCarrier;
    property SymbolSepar: Integer read FSepar;
    { 周波数のずれを探せる幅 [bin]。次の層が使う。 }
    property DecodeMargin: Integer read FMargin;
    function ProcessedCount: Int64;
  end;

implementation

{ ==========================================================================
  諸元
  ========================================================================== }

function TOliviaToneMode.BlockMode: TOliviaMode;
begin
  Result.Variant_ := Variant_;
  Result.BitsPerSymbol := BitsPerSymbol;
end;

function TOliviaToneMode.Tones: Integer;
begin
  Result := 1 shl BitsPerSymbol;
end;

function TOliviaToneMode.SymbolLen: Integer;
var
  k: Integer;
begin
  { 上流: 1 shl (BitsPerSymbol + 7 - Log2(Bandwidth/125))
    帯域を倍にすればシンボルは半分の長さになる、という関係である。 }
  k := 0;
  while (125 shl k) < BandwidthHz do Inc(k);
  Result := 1 shl (BitsPerSymbol + 7 - k);
end;

function TOliviaToneMode.SymbolSepar: Integer;
begin
  Result := SymbolLen div 2;
end;

function TOliviaToneMode.BaudRate: Double;
begin
  Result := SampleRate / SymbolSepar;
end;

function TOliviaToneMode.BinWidthHz: Double;
begin
  Result := SampleRate / SymbolLen;
end;

function TOliviaToneMode.ToneSpacingHz: Double;
begin
  Result := OLIVIA_CARRIER_SEPAR * BinWidthHz;
end;

function TOliviaToneMode.OccupiedBandwidthHz: Double;
begin
  { 端から端まで。上流: set_bandwidth(Bandwidth - Bandwidth/Tones) }
  Result := (Tones - 1) * ToneSpacingHz;
end;

function TOliviaToneMode.Describe: string;
var
  n: string;
begin
  if Variant_ = ovContestia then n := 'Contestia' else n := 'Olivia';
  Result := Format('%s %d/%d: %.3f baud / %d トーン / %.3f Hz 間隔 / 占有 %.1f Hz',
    [n, Tones, BandwidthHz, BaudRate, Tones, ToneSpacingHz,
     OccupiedBandwidthHz]);
end;

{ トーンの列の中心が ACentreHz に来る bin を返す。 }
function FirstCarrierFor(const AMode: TOliviaToneMode;
  ACentreHz: Double): Integer;
begin
  Result := Round(ACentreHz * AMode.SymbolLen / AMode.SampleRate)
            - (AMode.Tones - 1);
end;

procedure CheckMode(const AMode: TOliviaToneMode);
begin
  if (AMode.BitsPerSymbol < 1) or (AMode.BitsPerSymbol > 8) then
    raise EOliviaToneError.CreateFmt(
      '1 シンボルのビット数は 1..8 です (指定 %d)', [AMode.BitsPerSymbol]);
  if (AMode.BandwidthHz < 125) or (AMode.BandwidthHz > 2000) then
    raise EOliviaToneError.CreateFmt(
      '帯域は 125..2000 Hz です (指定 %d)', [AMode.BandwidthHz]);
  if AMode.SampleRate <= 0 then
    raise EOliviaToneError.Create('標本化周波数が不正です');
end;

procedure CheckCarrierFits(const AMode: TOliviaToneMode;
  AFirstCarrier, AMargin: Integer);
var
  last: Integer;
begin
  last := AFirstCarrier + OLIVIA_CARRIER_SEPAR * (AMode.Tones - 1);
  if AFirstCarrier - AMargin < 0 then
    raise EOliviaToneError.CreateFmt(
      'トーンが低すぎます (bin %d - 余裕 %d < 0)。中心周波数を上げてください',
      [AFirstCarrier, AMargin]);
  if last + AMargin >= AMode.SymbolLen div 2 then
    raise EOliviaToneError.CreateFmt(
      'トーンが高すぎます (bin %d + 余裕 %d >= %d)。中心周波数を下げてください',
      [last, AMargin, AMode.SymbolLen div 2]);
end;

{ ==========================================================================
  送信側
  ========================================================================== }

constructor TOliviaModulator.Create(const AMode: TOliviaToneMode;
  ACentreHz: Double);
var
  i: Integer;
begin
  inherited Create;
  CheckMode(AMode);
  FMode := AMode;
  FLen := AMode.SymbolLen;
  FSepar := AMode.SymbolSepar;
  FWrapMask := FLen - 1;

  if ACentreHz > 0 then FCentreHz := ACentreHz
  else FCentreHz := OLIVIA_DEFAULT_CENTRE_HZ;
  FFirstCarrier := FirstCarrierFor(AMode, FCentreHz);
  { 送信に要るのは「トーンが spectrum に収まる」ことだけである。
    受信側の探索の余裕まで要求すると、低い周波数に置けなくなる。 }
  CheckCarrierFits(AMode, FFirstCarrier, 0);

  SetLength(FCos, FLen);
  for i := 0 to FLen - 1 do
    FCos[i] := Cos(2 * Pi * i / FLen);
  SetLength(FTap, FLen);
  Reset;
end;

procedure TOliviaModulator.SetCentre(AHz: Double);
var
  bin: Integer;
begin
  if AHz <= 0 then AHz := OLIVIA_DEFAULT_CENTRE_HZ;
  bin := FirstCarrierFor(FMode, AHz);
  CheckCarrierFits(FMode, bin, 0);
  FCentreHz := AHz;
  FFirstCarrier := bin;
  { 重ね合わせの環には古い同調の音が残っている。持ち越すと
    つなぎ目で別の周波数が混ざるので捨てる。 }
  Reset;
end;

procedure TOliviaModulator.Reset;
var
  i: Integer;
begin
  for i := 0 to FLen - 1 do FTap[i] := 0;
  FTapPtr := 0;
  FPhase := 0;
  { 揺らぎの種を決め打ちにしてあるのは **同じ文を送れば同じ音になる**
    ようにするためである (Z-05)。上流は rand() を引いており、同じ文を
    送っても波形が毎回変わる。試験も流し直しも成り立たない。 }
  FDither := 88172645463325252;
end;

function TOliviaModulator.NextDither: Integer;
begin
  { xorshift64。揺らぎに要るのは 1 ビットだけなので、これで十分である。 }
  {$push}{$Q-}{$R-}
  FDither := FDither xor (FDither shl 13);
  FDither := FDither xor (FDither shr 7);
  FDither := FDither xor (FDither shl 17);
  {$pop}
  if (FDither and 1) <> 0 then
    Result := FLen div 4
  else
    Result := -(FLen div 4);
end;

procedure TOliviaModulator.AddSymbol(AFreqBin, APhase: Integer);
var
  t, ph: Integer;
begin
  ph := APhase and FWrapMask;
  for t := 0 to FLen - 1 do
  begin
    { 持ち上がり窓 (1 - cos)。半分ずらして足すと包絡線が平らになる。 }
    FTap[FTapPtr] := FTap[FTapPtr] + FCos[ph] * (1 - FCos[t]);
    ph := (ph + AFreqBin) and FWrapMask;
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;
end;

procedure TOliviaModulator.Send(ASymbol: Integer; var ABuf: array of Double);
var
  tone, freqBin, shift, i: Integer;
begin
  if Length(ABuf) < FSepar then
    raise EOliviaToneError.CreateFmt(
      '置き場が足りません (要求 %d / 受け取り %d)', [FSepar, Length(ABuf)]);

  { Gray を挟む。隣のトーンと取り違えてもビット誤りが 1 本で済む。
    上流 pj_gray.h の GrayCode は x xor (x shr 1) ―― ModemDSP の
    GrayEncode と同じものである (fldigi の MFSK 側は名前が逆なので注意)。 }
  tone := Integer(GrayEncode(LongWord(ASymbol and (FMode.Tones - 1))));
  freqBin := FFirstCarrier + OLIVIA_CARRIER_SEPAR * tone;

  { 窓の中心が区切りに来るように位相を前後させる。整数の位相で
    やっているので、何シンボル続けても誤差が溜まらない。 }
  shift := FSepar div 2 - FLen div 2;
  FPhase := (FPhase + freqBin * shift) and FWrapMask;
  AddSymbol(freqBin, FPhase);

  shift := FSepar div 2 + FLen div 2;
  FPhase := (FPhase + freqBin * shift) and FWrapMask;
  FPhase := (FPhase + NextDither) and FWrapMask;

  { 書き出して、その枠を空ける。重なりぶんは環に残る。
    包絡線が 2 になるので半分にして、定常トーンの振幅を 1 に揃える
    (ほかのモデムと同じ目盛りにするため)。 }
  for i := 0 to FSepar - 1 do
  begin
    ABuf[i] := 0.5 * FTap[FTapPtr];
    FTap[FTapPtr] := 0;
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;
end;

procedure TOliviaModulator.Flush(var ABuf: array of Double);
var
  i: Integer;
begin
  if Length(ABuf) < FSepar then
    raise EOliviaToneError.CreateFmt(
      '置き場が足りません (要求 %d / 受け取り %d)', [FSepar, Length(ABuf)]);
  for i := 0 to FSepar - 1 do
  begin
    ABuf[i] := 0.5 * FTap[FTapPtr];
    FTap[FTapPtr] := 0;
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;
end;

{ ==========================================================================
  受信側
  ========================================================================== }

constructor TOliviaDemodulator.Create(const AMode: TOliviaToneMode;
  ACentreHz: Double);
var
  i: Integer;
begin
  inherited Create;
  CheckMode(AMode);
  FMode := AMode;
  FLen := AMode.SymbolLen;
  FSepar := AMode.SymbolSepar;
  FSepar2 := FSepar div 2;
  FWrapMask := FLen - 1;

  if ACentreHz > 0 then FCentreHz := ACentreHz
  else FCentreHz := OLIVIA_DEFAULT_CENTRE_HZ;
  FFirstCarrier := FirstCarrierFor(AMode, FCentreHz);
  CheckCarrierFits(AMode, FFirstCarrier, 0);
  { 探索の余裕は、spectrum の端に当たったぶんだけ削る。
    削らずに例外にすると、端に寄せた運用ができなくなる ―― 上流も
    (DecodeMargin > FirstCarrier のとき) 同じように詰めている。 }
  FMargin := OLIVIA_DECODE_MARGIN;
  if FMargin > FFirstCarrier then FMargin := FFirstCarrier;
  i := FFirstCarrier + OLIVIA_CARRIER_SEPAR * (AMode.Tones - 1);
  if i + FMargin >= AMode.SymbolLen div 2 then
    FMargin := AMode.SymbolLen div 2 - 1 - i;
  if FMargin < 0 then FMargin := 0;

  { 読む幅。トーンの列の両側に余裕を足す。 }
  FWidth := OLIVIA_CARRIER_SEPAR * (AMode.Tones - 1) + 1 + 2 * FMargin;

  SetLength(FWindow, FLen);
  for i := 0 to FLen - 1 do
    { 送信と同じ持ち上がり窓。整合フィルタになっている。
      1/N は上流の ShapeScale。energy 全体を一律に縮めるだけだが、
      数字を上流と見比べるときに揃っていたほうがよい。 }
    FWindow[i] := (1 - Cos(2 * Pi * i / FLen)) / FLen;

  SetLength(FTap, FLen);
  SetLength(FFft, FLen);
  SetLength(FSpec0, FLen div 2);
  SetLength(FSpec1, FLen div 2);
  SetLength(FEnergy, OLIVIA_SLICES * FWidth);
  Reset;
end;

procedure TOliviaDemodulator.SetCentre(AHz: Double);
var
  bin, last, margin: Integer;
begin
  if AHz <= 0 then AHz := OLIVIA_DEFAULT_CENTRE_HZ;
  bin := FirstCarrierFor(FMode, AHz);
  CheckCarrierFits(FMode, bin, 0);

  margin := OLIVIA_DECODE_MARGIN;
  if margin > bin then margin := bin;
  last := bin + OLIVIA_CARRIER_SEPAR * (FMode.Tones - 1);
  if last + margin >= FMode.SymbolLen div 2 then
    margin := FMode.SymbolLen div 2 - 1 - last;
  if margin < 0 then margin := 0;

  FCentreHz := AHz;
  FFirstCarrier := bin;
  FMargin := margin;
  { 読む幅が変わるので置き場も取り直す。同調のし直しは運用上まれな
    ので、ここで確保が起きても deadline の話にはならない。 }
  FWidth := OLIVIA_CARRIER_SEPAR * (FMode.Tones - 1) + 1 + 2 * FMargin;
  SetLength(FEnergy, OLIVIA_SLICES * FWidth);
  { 遅延線には古い同調の音が残っている。持ち越さない。 }
  Reset;
end;

procedure TOliviaDemodulator.Reset;
var
  i: Integer;
begin
  for i := 0 to FLen - 1 do FTap[i] := 0;
  for i := 0 to High(FEnergy) do FEnergy[i] := 0;
  FTapPtr := 0;
  FProcessed := 0;
end;

procedure TOliviaDemodulator.Process(const ABuf: array of Double);
var
  i, t, bin, slice, idx: Integer;
  z: TComplex;
begin
  if Length(ABuf) < FSepar then
    raise EOliviaToneError.CreateFmt(
      'サンプルが足りません (要求 %d / 受け取り %d)', [FSepar, Length(ABuf)]);

  { 前半を入れてから 1 枚目の窓を切り、後半を入れてから 2 枚目を切る。
    窓は SymbolLen/4 ずれる。**環の大きさが窓と同じ**なので、窓を
    読み終えると FTapPtr は元に戻る ―― だから読みと書きを交互に
    書けるのであって、偶然ではない。 }
  for i := 0 to FSepar2 - 1 do
  begin
    FTap[FTapPtr] := ABuf[i];
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;
  for t := 0 to FLen - 1 do
  begin
    FFft[t].Re := FTap[FTapPtr] * FWindow[t];
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;

  for i := FSepar2 to FSepar - 1 do
  begin
    FTap[FTapPtr] := ABuf[i];
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;
  for t := 0 to FLen - 1 do
  begin
    FFft[t].Im := FTap[FTapPtr] * FWindow[t];
    FTapPtr := (FTapPtr + 1) and FWrapMask;
  end;

  { 実数列 2 本を 1 回で変換する。 }
  ComplexFFT(FFft);
  SplitTwoRealSpectra(FFft, FSpec0, FSpec1);

  for slice := 0 to OLIVIA_SLICES - 1 do
    for idx := 0 to FWidth - 1 do
    begin
      bin := FFirstCarrier - FMargin + idx;
      if slice = 0 then z := FSpec0[bin] else z := FSpec1[bin];
      FEnergy[slice * FWidth + idx] := z.Re * z.Re + z.Im * z.Im;
    end;

  Inc(FProcessed);
end;

function TOliviaDemodulator.EnergyAt(ASlice, AIndex: Integer): Double;
begin
  Result := FEnergy[ASlice * FWidth + AIndex];
end;

function TOliviaDemodulator.HardDecode(ASlice: Integer;
  AFreqOffset: Integer): Integer;
var
  i, base, peakIdx: Integer;
  e, peak: Double;
begin
  CheckSlice(ASlice);
  CheckOffset(AFreqOffset);
  base := FMargin + AFreqOffset;

  peak := 0;
  peakIdx := 0;
  for i := 0 to FMode.Tones - 1 do
  begin
    e := EnergyAt(ASlice, base + OLIVIA_CARRIER_SEPAR * i);
    if e > peak then
    begin
      peak := e;
      peakIdx := i;
    end;
  end;
  { トーン番号からシンボル値へ。上流 pj_gray.h の BinaryCode。 }
  Result := Integer(GrayDecode(LongWord(peakIdx)));
end;

procedure TOliviaDemodulator.SoftDecode(ASlice: Integer;
  var ASoft: array of Double; AFreqOffset: Integer);
var
  i, b, base, symIdx: Integer;
  e, total: Double;
begin
  CheckSlice(ASlice);
  if Length(ASoft) < FMode.BitsPerSymbol then
    raise EOliviaToneError.CreateFmt(
      '軟判定の置き場が足りません (要求 %d / 受け取り %d)',
      [FMode.BitsPerSymbol, Length(ASoft)]);
  CheckOffset(AFreqOffset);
  base := FMargin + AFreqOffset;

  for b := 0 to FMode.BitsPerSymbol - 1 do ASoft[b] := 0;
  total := 0;
  for i := 0 to FMode.Tones - 1 do
  begin
    symIdx := Integer(GrayDecode(LongWord(i)));
    e := EnergyAt(ASlice, base + OLIVIA_CARRIER_SEPAR * i);
    { energy をもう一度二乗する (|X|^4)。山を際立たせ、二番手以下の
      寄与を抑えるためで、上流と同じである。 }
    e := e * e;
    total := total + e;
    for b := 0 to FMode.BitsPerSymbol - 1 do
      if (symIdx and (1 shl b)) <> 0 then
        ASoft[b] := ASoft[b] - e
      else
        ASoft[b] := ASoft[b] + e;
  end;

  if total > 0 then
    for b := 0 to FMode.BitsPerSymbol - 1 do
      ASoft[b] := ASoft[b] / total;
end;

function TOliviaDemodulator.ToneEnergy(ASlice, AToneIndex: Integer;
  AFreqOffset: Integer): Double;
begin
  CheckSlice(ASlice);
  CheckOffset(AFreqOffset);
  if (AToneIndex < 0) or (AToneIndex >= FMode.Tones) then
    raise EOliviaToneError.CreateFmt(
      'トーン番号が範囲外です (%d / 0..%d)', [AToneIndex, FMode.Tones - 1]);
  Result := EnergyAt(ASlice,
    FMargin + AFreqOffset + OLIVIA_CARRIER_SEPAR * AToneIndex);
end;

function TOliviaDemodulator.ProcessedCount: Int64;
begin
  Result := FProcessed;
end;

procedure TOliviaDemodulator.CheckSlice(ASlice: Integer);
begin
  if (ASlice < 0) or (ASlice >= OLIVIA_SLICES) then
    raise EOliviaToneError.CreateFmt(
      'spectrum の番号が範囲外です (%d / 0..%d)',
      [ASlice, OLIVIA_SLICES - 1]);
end;

procedure TOliviaDemodulator.CheckOffset(AFreqOffset: Integer);
var
  base: Integer;
begin
  base := FMargin + AFreqOffset;
  if (base < 0)
     or (base + OLIVIA_CARRIER_SEPAR * (FMode.Tones - 1) >= FWidth) then
    raise EOliviaToneError.CreateFmt(
      '周波数のずらし量が範囲外です (%d / 使えるのは -%d..+%d)',
      [AFreqOffset, FMargin, FMargin]);
end;

end.
