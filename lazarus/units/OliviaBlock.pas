{ ============================================================================
  OliviaBlock.pas

  Olivia / Contestia の**符号の層**。1 文字を Walsh 関数に展開し、
  かき混ぜて、シンボルの並びに畳む。受信はその逆。

  Olivia がほかの MFSK 系と違うところ
  ----------------------------------------------------------------------------
  MFSK16 は「畳み込み符号 + インタリーバ」で守る (MDM-009)。ビットを順に
  流し、誤りを散らしてから Viterbi で直す。

  Olivia は考え方が違う。**1 文字を丸ごと一つの直交波形にする。**
  7 ビットの文字を長さ 64 の ±1 の並び (Walsh 関数) に展開し、受信側は
  アダマール変換を一発かけて「どの並びだったか」を山の位置で読む。
  誤り訂正という別の層があるのではなく、**展開そのものが誤り訂正**である。

  これが Olivia が極端に弱い信号で通る理由でもある。64 個のシンボルの
  うち半分近くが化けても、山はまだ正しい位置に立つ。

  ブロックの組み立て
  ----------------------------------------------------------------------------
  1 ブロックは SymbolsPerBlock 個のシンボルからなり、BitsPerSymbol 文字を
  同時に運ぶ。32 トーン Olivia なら 64 シンボルで 5 文字である。

      文字 0 -> Walsh 関数 (長さ 64 の ±1) -> シンボル 0..63 の bit 0
      文字 1 -> Walsh 関数                 -> シンボル 0..63 の bit 1
      ...
      文字 4 -> Walsh 関数                 -> シンボル 0..63 の bit 4

  ただしそのまま重ねない。二段の細工が入る。

  - **かき混ぜ (Scramble)**。文字ごとに決まったずらし量で、固定の 64 bit
    符号に従って ±1 を反転する。同じ文字を続けて送っても同じ音にならない
    ようにするためで、これが無いと定常波が立つ。
  - **斜めに置く (Rotate)**。文字 f のビットは、時刻 t では
    (f + t) mod BitsPerSymbol 番目のビット位置に入る。1 文字が特定の
    トーンのビット位置に偏らないようにする ―― 帯域の一部が潰れたときに
    1 文字だけが全滅するのを避ける、インタリーバに当たる働きである。

  軟判定の向き
  ----------------------------------------------------------------------------
  送信側は **Walsh 値が負のときビットを 1 にする**。したがって受信側の
  軟判定は

      正 = ビット 0 らしい / 負 = ビット 1 らしい / 0 = 分からない

  という向きになる。MFSK 側の 0..255 (128 が分からない) とは別の約束で、
  これは上流の造りをそのまま使っている ―― アダマール変換が線形なので、
  ±に振れた実数をそのまま入れれば軟判定がそのまま効く。**変換前に
  硬判定へ落としてはいけない。**

  Contestia との違い
  ----------------------------------------------------------------------------
  - 1 文字 6 ビット (Olivia は 7)。したがってブロックは 32 シンボル。
  - 文字の割り当てが違う。大文字に畳んだ 64 文字の限られた表を使う。
  - かき混ぜ符号とずらし量が違う。

  上流のどこを見たか
  ----------------------------------------------------------------------------
  src/include/jalocha/pj_mfsk.h の MFSK_Encoder / MFSK_SoftDecoder、
  および pj_fht.h。アダマール変換そのものは ModemDSP に置いた (X-05)。

  ここに無いもの
  ----------------------------------------------------------------------------
  トーンの生成と検出、ブロックの頭出し (同期)、AFC。別の層である。
  受信側が出す Signal / NoiseEnergy は、その同期の層が「どのブロック位相が
  正しいか」を選ぶための材料になる (上流は位相ごとに復号器を並べて
  S/N の一番良いものを採る)。
  ============================================================================ }
unit OliviaBlock;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemDSP;

const
  { かき混ぜ符号。上流 pj_mfsk.h の ScramblingCode*。
    64 bit の即値は 2 つに割って組む (-Crio で 2^63 を超える即値が
    弾かれるため。README 32 章)。 }
  OLIVIA_SCRAMBLE: QWord = (QWord($E257E6D0) shl 32) or QWord($291574EC);
  CONTESTIA_SCRAMBLE: QWord = $EDB88320;

  { 文字ごとのかき混ぜのずらし量。 }
  OLIVIA_CODE_SHIFT = 13;
  CONTESTIA_CODE_SHIFT = 5;

  { 1 シンボルが運ぶビット数の上限。32 トーンで 5、64 トーンで 6。 }
  OLIVIA_MAX_BITS_PER_SYMBOL = 8;

type
  EOliviaError = class(Exception);

  TOliviaVariant = (ovOlivia, ovContestia);

  { モードの諸元。トーン数は BitsPerSymbol から決まる (2^k)。 }
  TOliviaMode = record
    Variant_: TOliviaVariant;
    BitsPerSymbol: Integer;     // 32 トーンなら 5
    function Name: string;
    function BitsPerCharacter: Integer;   // Olivia 7 / Contestia 6
    function Tones: Integer;              // 2^BitsPerSymbol
    function SymbolsPerBlock: Integer;    // 2^(BitsPerCharacter-1)
    { 1 ブロックが運ぶ文字数。BitsPerSymbol と同じだが、意味が違うので
      名前を分けてある。 }
    function CharsPerBlock: Integer;
    function ScramblingCode: QWord;
    function CodeShift: Integer;
    function Describe: string;
  end;

const
  { 既定の 32 トーン。Olivia 32/1000 と Contestia 32/1000 の符号の層。 }
  OLIVIA_32_MODE: TOliviaMode = (Variant_: ovOlivia; BitsPerSymbol: 5);
  CONTESTIA_32_MODE: TOliviaMode = (Variant_: ovContestia; BitsPerSymbol: 5);
  OLIVIA_16_MODE: TOliviaMode = (Variant_: ovOlivia; BitsPerSymbol: 4);

type
  { --- 送信側 ---
    CharsPerBlock 文字を入れると SymbolsPerBlock 個のシンボル値が出る。 }
  TOliviaBlockEncoder = class
  private
    FMode: TOliviaMode;
    FWalsh: array of Double;     // 作業用。確保しないために持ち回す
    procedure ExpandCharacter(AChar: Byte);
    procedure Scramble(ACodeOffset: Integer);
  public
    constructor Create(const AMode: TOliviaMode);
    { AChars は CharsPerBlock 個、ASymbols は SymbolsPerBlock 個ちょうど。
      ASymbols の各要素は 0..Tones-1 のシンボル値である。 }
    procedure EncodeBlock(const AChars: array of Byte;
      var ASymbols: array of Byte);
    property Mode: TOliviaMode read FMode;
  end;

  { --- 受信側 ---
    1 シンボルぶんの軟判定 (BitsPerSymbol 本) を Input で入れ、
    ブロックの区切りで Process を呼ぶ。 }
  TOliviaBlockDecoder = class
  private
    FMode: TOliviaMode;
    FInput: array of Double;     // [SymbolsPerBlock][BitsPerSymbol] の環
    FInputLen: Integer;
    FPtr: Integer;
    FWalsh: array of Double;
    FChars: array of Byte;
    FSignal: Double;
    FNoiseEnergy: Double;
    FFedSymbols: Int64;
    procedure DecodeCharacter(AFreqBit: Integer);
  public
    constructor Create(const AMode: TOliviaMode);
    { 環を空にする。前のブロックを持ち越さない。 }
    procedure Reset;
    { 1 シンボルぶんの軟判定。正がビット 0、負がビット 1 の向き。
      要素数は BitsPerSymbol 以上。確保しない (X-04)。 }
    procedure Input(const ASoft: array of Double);
    { 環に溜まっている直近 SymbolsPerBlock シンボルを 1 ブロックとして
      復号する。確保しない。 }
    procedure Process;
    { 復号した文字。添字は 0..CharsPerBlock-1。 }
    function OutputChar(AIndex: Integer): Byte;

    { 直近の Process で見えた山の高さの平均。大きいほど揃っている。 }
    property Signal: Double read FSignal;
    { 山を除いた残りの二乗平均。雑音の代表値である。
      この二つの比が、同期の層が正しいブロック位相を選ぶ材料になる。 }
    property NoiseEnergy: Double read FNoiseEnergy;
    { これまでに入れたシンボル数。環が満ちたかを呼び手が知るために使う。 }
    function FedSymbols: Int64;
    property Mode: TOliviaMode read FMode;
  end;

{ --- 文字の割り当て ---
  Olivia は 7 bit をそのまま使う。Contestia は大文字に畳んだ 64 文字の
  表を使う。どちらも上流 MFSK_Encoder::EncodeCharacter /
  MFSK_SoftDecoder::DecodeCharacter と同じ。 }
function OliviaCharToCode(const AMode: TOliviaMode; ACh: Byte): Byte;
function OliviaCodeToChar(const AMode: TOliviaMode; ACode: Byte): Byte;

implementation

{ ==========================================================================
  諸元
  ========================================================================== }

function TOliviaMode.BitsPerCharacter: Integer;
begin
  if Variant_ = ovContestia then Result := 6 else Result := 7;
end;

function TOliviaMode.Tones: Integer;
begin
  Result := 1 shl BitsPerSymbol;
end;

function TOliviaMode.SymbolsPerBlock: Integer;
begin
  Result := 1 shl (BitsPerCharacter - 1);
end;

function TOliviaMode.CharsPerBlock: Integer;
begin
  Result := BitsPerSymbol;
end;

function TOliviaMode.ScramblingCode: QWord;
begin
  if Variant_ = ovContestia then Result := CONTESTIA_SCRAMBLE
  else Result := OLIVIA_SCRAMBLE;
end;

function TOliviaMode.CodeShift: Integer;
begin
  if Variant_ = ovContestia then Result := CONTESTIA_CODE_SHIFT
  else Result := OLIVIA_CODE_SHIFT;
end;

function TOliviaMode.Name: string;
begin
  if Variant_ = ovContestia then Result := 'Contestia' else Result := 'Olivia';
end;

function TOliviaMode.Describe: string;
begin
  Result := Format('%s %d トーン / 1 文字 %d bit / 1 ブロック %d シンボル %d 文字',
    [Name, Tones, BitsPerCharacter, SymbolsPerBlock, CharsPerBlock]);
end;

{ ==========================================================================
  文字の割り当て
  ========================================================================== }

function OliviaCharToCode(const AMode: TOliviaMode; ACh: Byte): Byte;
var
  c: Integer;
begin
  if AMode.Variant_ <> ovContestia then
  begin
    { Olivia は 7 bit をそのまま。上流: Char &= (SymbolsPerBlock<<1)-1 }
    Result := ACh and Byte((AMode.SymbolsPerBlock shl 1) - 1);
    Exit;
  end;

  c := ACh;
  { 小文字は大文字に畳む。Contestia の表は大文字しか持たない。 }
  if (c >= Ord('a')) and (c <= Ord('z')) then
    Dec(c, Ord('a') - Ord('A'));

  if c = Ord(' ') then Result := 59
  else if c = 13 then Result := 60          { CR }
  else if c = 10 then Result := 0           { LF は NUL に潰れる。
                                              上流のまま。戻せない。 }
  else if (c >= 33) and (c <= 90) then Result := Byte(c - 32)
  else if c = 8 then Result := 61           { BS }
  else if c = 0 then Result := 0
  else Result := Byte(Ord('?') - 32);       { 表に無いものは ? }
end;

function OliviaCodeToChar(const AMode: TOliviaMode; ACode: Byte): Byte;
begin
  if AMode.Variant_ <> ovContestia then
  begin
    Result := ACode;
    Exit;
  end;
  if ACode = 0 then Exit(0);
  case ACode of
    59: Result := Ord(' ');
    60: Result := 13;
    61: Result := 8;
  else
    Result := Byte(ACode + 32);
  end;
end;

{ ==========================================================================
  送信側
  ========================================================================== }

constructor TOliviaBlockEncoder.Create(const AMode: TOliviaMode);
begin
  inherited Create;
  if (AMode.BitsPerSymbol < 1)
     or (AMode.BitsPerSymbol > OLIVIA_MAX_BITS_PER_SYMBOL) then
    raise EOliviaError.CreateFmt(
      '1 シンボルのビット数は 1..%d です (指定 %d)',
      [OLIVIA_MAX_BITS_PER_SYMBOL, AMode.BitsPerSymbol]);
  FMode := AMode;
  SetLength(FWalsh, FMode.SymbolsPerBlock);
end;

procedure TOliviaBlockEncoder.ExpandCharacter(AChar: Byte);
var
  i, n, code: Integer;
begin
  { 文字を「位置 + 符号」に読み替え、その位置だけ立てた単位ベクトルを
    逆アダマール変換する。出てくるのは ±1 の並び (Walsh 関数) である。
    上位ビットが符号になっているのは、長さ N の変換で表せる直交波形が
    N 本しかなく、符号を足して 2N 文字ぶんにしているからである。 }
  n := FMode.SymbolsPerBlock;
  for i := 0 to n - 1 do FWalsh[i] := 0;

  code := OliviaCharToCode(FMode, AChar);
  if code < n then
    FWalsh[code] := 1
  else
    FWalsh[code - n] := -1;

  InverseFastHadamard(FWalsh, n);
end;

procedure TOliviaBlockEncoder.Scramble(ACodeOffset: Integer);
var
  t, codeBit, wrap: Integer;
  code: QWord;
begin
  wrap := FMode.SymbolsPerBlock - 1;
  codeBit := ACodeOffset and wrap;
  code := FMode.ScramblingCode;
  for t := 0 to FMode.SymbolsPerBlock - 1 do
  begin
    if (code and (QWord(1) shl codeBit)) <> 0 then
      FWalsh[t] := -FWalsh[t];
    codeBit := (codeBit + 1) and wrap;
  end;
end;

procedure TOliviaBlockEncoder.EncodeBlock(const AChars: array of Byte;
  var ASymbols: array of Byte);
var
  f, t, rotate, bit: Integer;
begin
  if Length(AChars) < FMode.CharsPerBlock then
    raise EOliviaError.CreateFmt('文字が足りません (要求 %d / 受け取り %d)',
      [FMode.CharsPerBlock, Length(AChars)]);
  if Length(ASymbols) < FMode.SymbolsPerBlock then
    raise EOliviaError.CreateFmt('シンボルの置き場が足りません (要求 %d / 受け取り %d)',
      [FMode.SymbolsPerBlock, Length(ASymbols)]);

  for t := 0 to FMode.SymbolsPerBlock - 1 do ASymbols[t] := 0;

  for f := 0 to FMode.CharsPerBlock - 1 do
  begin
    ExpandCharacter(AChars[f]);
    Scramble(f * FMode.CodeShift);

    { 斜めに置く。文字 f のビットは時刻 t では (f+t) mod BitsPerSymbol
      番目に入る。1 文字が特定のビット位置に偏らないようにするためで、
      畳み込み符号側のインタリーバに当たる働きである。 }
    rotate := 0;
    for t := 0 to FMode.SymbolsPerBlock - 1 do
    begin
      if FWalsh[t] < 0 then
      begin
        bit := f + rotate;
        if bit >= FMode.BitsPerSymbol then Dec(bit, FMode.BitsPerSymbol);
        ASymbols[t] := ASymbols[t] or Byte(1 shl bit);
      end;
      Inc(rotate);
      if rotate >= FMode.BitsPerSymbol then Dec(rotate, FMode.BitsPerSymbol);
    end;
  end;
end;

{ ==========================================================================
  受信側
  ========================================================================== }

constructor TOliviaBlockDecoder.Create(const AMode: TOliviaMode);
begin
  inherited Create;
  if (AMode.BitsPerSymbol < 1)
     or (AMode.BitsPerSymbol > OLIVIA_MAX_BITS_PER_SYMBOL) then
    raise EOliviaError.CreateFmt(
      '1 シンボルのビット数は 1..%d です (指定 %d)',
      [OLIVIA_MAX_BITS_PER_SYMBOL, AMode.BitsPerSymbol]);
  FMode := AMode;
  FInputLen := FMode.SymbolsPerBlock * FMode.BitsPerSymbol;
  SetLength(FInput, FInputLen);
  SetLength(FWalsh, FMode.SymbolsPerBlock);
  SetLength(FChars, FMode.CharsPerBlock);
  Reset;
end;

procedure TOliviaBlockDecoder.Reset;
var
  i: Integer;
begin
  for i := 0 to FInputLen - 1 do FInput[i] := 0;
  for i := 0 to FMode.CharsPerBlock - 1 do FChars[i] := 0;
  FPtr := 0;
  FSignal := 0;
  FNoiseEnergy := 0;
  FFedSymbols := 0;
end;

procedure TOliviaBlockDecoder.Input(const ASoft: array of Double);
var
  f: Integer;
begin
  if Length(ASoft) < FMode.BitsPerSymbol then
    raise EOliviaError.CreateFmt('軟判定が足りません (要求 %d / 受け取り %d)',
      [FMode.BitsPerSymbol, Length(ASoft)]);
  for f := 0 to FMode.BitsPerSymbol - 1 do
  begin
    FInput[FPtr] := ASoft[f];
    Inc(FPtr);
  end;
  if FPtr >= FInputLen then Dec(FPtr, FInputLen);
  Inc(FFedSymbols);
end;

procedure TOliviaBlockDecoder.DecodeCharacter(AFreqBit: Integer);
var
  t, ptr, rotate, codeBit, wrap, peakPos: Integer;
  v, peak, sqrSum: Double;
  code: QWord;
begin
  wrap := FMode.SymbolsPerBlock - 1;
  codeBit := (AFreqBit * FMode.CodeShift) and wrap;
  code := FMode.ScramblingCode;

  { 送信の斜め置きとかき混ぜをほどきながら、Walsh 変換の入力を組む。
    FPtr は次に書く位置 = **いちばん古い**シンボルなので、そこから
    読めばブロックが時間順に並ぶ。

    FPtr は常に BitsPerSymbol の倍数で、FInputLen も倍数である。
    したがって ptr + rotate は FInputLen を超えない ―― 超えると
    -Crio が範囲検査で落とす。 }
  ptr := FPtr;
  rotate := AFreqBit;
  for t := 0 to FMode.SymbolsPerBlock - 1 do
  begin
    v := FInput[ptr + rotate];
    if (code and (QWord(1) shl codeBit)) <> 0 then
      v := -v;
    FWalsh[t] := v;

    codeBit := (codeBit + 1) and wrap;
    Inc(rotate);
    if rotate >= FMode.BitsPerSymbol then Dec(rotate, FMode.BitsPerSymbol);
    Inc(ptr, FMode.BitsPerSymbol);
    if ptr >= FInputLen then Dec(ptr, FInputLen);
  end;

  { 一発で「どの Walsh 関数だったか」を読む。山の位置が文字、
    山の符号が上位ビットである。 }
  FastHadamard(FWalsh, FMode.SymbolsPerBlock);

  peak := 0;
  peakPos := 0;
  sqrSum := 0;
  for t := 0 to FMode.SymbolsPerBlock - 1 do
  begin
    v := FWalsh[t];
    sqrSum := sqrSum + v * v;
    if Abs(v) > Abs(peak) then
    begin
      peak := v;
      peakPos := t;
    end;
  end;

  if peak < 0 then
    FChars[AFreqBit] := OliviaCodeToChar(FMode,
      Byte(peakPos + FMode.SymbolsPerBlock))
  else
    FChars[AFreqBit] := OliviaCodeToChar(FMode, Byte(peakPos));

  { 山を除いた残りが雑音である。山そのものを含めると、強い信号ほど
    雑音も大きいことになってしまう。 }
  sqrSum := sqrSum - peak * peak;
  FNoiseEnergy := FNoiseEnergy + sqrSum / (FMode.SymbolsPerBlock - 1);
  FSignal := FSignal + Abs(peak);
end;

procedure TOliviaBlockDecoder.Process;
var
  f: Integer;
begin
  FSignal := 0;
  FNoiseEnergy := 0;
  for f := 0 to FMode.CharsPerBlock - 1 do
    DecodeCharacter(f);
  FSignal := FSignal / FMode.CharsPerBlock;
  FNoiseEnergy := FNoiseEnergy / FMode.CharsPerBlock;
end;

function TOliviaBlockDecoder.OutputChar(AIndex: Integer): Byte;
begin
  if (AIndex < 0) or (AIndex >= FMode.CharsPerBlock) then
    raise EOliviaError.CreateFmt('文字の位置が範囲外です (%d / 0..%d)',
      [AIndex, FMode.CharsPerBlock - 1]);
  Result := FChars[AIndex];
end;

function TOliviaBlockDecoder.FedSymbols: Int64;
begin
  Result := FFedSymbols;
end;

end.
