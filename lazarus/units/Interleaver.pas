{ ============================================================================
  Interleaver.pas

  対角インタリーバ。MFSK 系が畳み込み符号の前後で使う。

  何のために要るのか
  ----------------------------------------------------------------------------
  畳み込み符号は「まばらに散った誤り」に強いが、**固まった誤り**には弱い。
  ところが実際の短波では、雑音は固まって来る ―― 空電が一発落ちれば
  連続した数十シンボルがまとめて潰れる。

  そこで送る前に順番をかき混ぜ、受けてから戻す。固まって潰れた誤りが、
  戻したときには散らばる。畳み込み符号が得意な形に直してやるわけである。

  fldigi のどこを見たか
  ----------------------------------------------------------------------------
  src/mfsk/interleave.cxx と src/include/interleave.h。
  表は size x size の正方を depth 段重ねたもので、1 シンボル入れるたびに
  各段を 1 つずらし、斜めに読み出す。MFSK16 は size=4 (symbits)、depth=10。

  遅れがあることに注意
  ----------------------------------------------------------------------------
  かき混ぜと戻しは「入れた端から出てくる」ものではない。表を通り抜ける
  ぶんの遅れがあり、最初に入れたシンボルが出てくるまでに
  **size x size x depth ぶんの空回し**が要る。

  送信側は最後に空シンボルを流し込んで押し出し、受信側は頭の遅れぶんを
  捨てる。この遅れを忘れると「なぜか先頭が化ける」ことになるので、
  RoundTripDelayBlocks / RoundTripDelaySymbols で外から見えるようにしてある。
  MFSK16 (Size 4 / Depth 10) では 30 区画 = 120 シンボルである。
  ============================================================================ }
unit Interleaver;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { 戻し側の表を埋める値。「まだ何も来ていない」を意味する。
    fldigi の PUNCTURE と同じ考え方で、軟判定の消失 (128) に相当する。 }
  INTERLEAVE_ERASURE = 128;

  { MFSK16 の諸元 (fldigi src/mfsk/mfsk.cxx)。 }
  INTERLEAVE_MFSK16_SIZE  = 4;    // symbits
  INTERLEAVE_MFSK16_DEPTH = 10;

type
  EInterleaverError = class(Exception);

  { かき混ぜる向き。 }
  TInterleaveDirection = (
    idForward,   // 送信側。斜め (size-i-1) に読み出す
    idReverse    // 受信側。斜め (i) に読み出す
  );

  TInterleaver = class
  private
    FSize: Integer;
    FDepth: Integer;
    FDirection: TInterleaveDirection;
    FTable: array of Byte;      // [depth][size][size] を平坦に
    function Cell(AStage, ARow, ACol: Integer): Integer; inline;
  public
    constructor Create(ASize: Integer = INTERLEAVE_MFSK16_SIZE;
      ADepth: Integer = INTERLEAVE_MFSK16_DEPTH;
      ADirection: TInterleaveDirection = idForward);

    { 表を初期状態に戻す。送信側は 0、受信側は消失で埋める。 }
    procedure Reset;

    { size 個のシンボルを通す。**その場で書き換える**。
      ASyms は Size 個ちょうどを渡すこと。 }
    procedure Process(var ASyms: array of Byte);

    { 送信側のための入り口。1 シンボルぶんのビットを詰めた整数を通す。
      最上位が第 1 ビットである (受信側の軟判定の並びと同じ向き)。
      fldigi: void interleave::bits(unsigned int *)
      中身は Process と同じで、ビットを 0/1 のバイトに開いて通すだけ。
      送受で別の表を使ってしまう事故を防ぐために、ここに置いてある。 }
    procedure ProcessBits(var ABits: LongWord);

    { かき混ぜ -> 戻し を通り抜けるのに要る区画数 (1 区画 = Size シンボル)。

      行ごとの遅れは向きによって違う ―― それが「散らす」ということである。
      FWD の行 i は挿入した値を列 Size-1-i で読むので i 回ぶん遅れ、
      REV の行 i は列 i で読むので Size-1-i 回ぶん遅れる。1 段あたりの
      合計は (Size-1) で、これが Depth 段重なる。**行に依らず一定**なので、
      往復させれば並びは崩れずに遅れだけが付く。 }
    function RoundTripDelayBlocks: Integer;
    { 同じものをシンボル数で。送信側の押し出しと受信側の捨てに使う。 }
    function RoundTripDelaySymbols: Integer;

    property Size: Integer read FSize;
    property Depth: Integer read FDepth;
    property Direction: TInterleaveDirection read FDirection;
  end;

implementation

constructor TInterleaver.Create(ASize, ADepth: Integer;
  ADirection: TInterleaveDirection);
begin
  inherited Create;
  { size は 1 シンボルのビット数なので小さい。大きな値は誤りである。 }
  if (ASize < 2) or (ASize > 8) then
    raise EInterleaverError.CreateFmt(
      '一辺は 2..8 です (指定 %d)', [ASize]);
  if (ADepth < 1) or (ADepth > 64) then
    raise EInterleaverError.CreateFmt(
      '段数は 1..64 です (指定 %d)', [ADepth]);
  FSize := ASize;
  FDepth := ADepth;
  FDirection := ADirection;
  SetLength(FTable, FDepth * FSize * FSize);
  Reset;
end;

function TInterleaver.Cell(AStage, ARow, ACol: Integer): Integer;
begin
  { fldigi: tab(i,j,k) = table[(size*size*i) + (size*j) + k] }
  Result := (FSize * FSize * AStage) + (FSize * ARow) + ACol;
end;

procedure TInterleaver.Reset;
var
  i: Integer;
  fill: Byte;
begin
  { 戻し側を 0 で埋めてはいけない。まだ来ていない枠を「確実に 0」として
    Viterbi に渡すことになり、**嘘の自信**を与えてしまう。
    消失 (128) なら「分からない」と伝わる。 }
  if FDirection = idReverse then
    fill := INTERLEAVE_ERASURE
  else
    fill := 0;
  for i := 0 to High(FTable) do
    FTable[i] := fill;
end;

procedure TInterleaver.Process(var ASyms: array of Byte);
var
  k, i, j: Integer;
begin
  if Length(ASyms) < FSize then
    raise EInterleaverError.CreateFmt(
      'シンボルが足りません (要求 %d / 受け取り %d)', [FSize, Length(ASyms)]);

  for k := 0 to FDepth - 1 do
  begin
    { 各行を 1 つ左へずらす。 }
    for i := 0 to FSize - 1 do
      for j := 0 to FSize - 2 do
        FTable[Cell(k, i, j)] := FTable[Cell(k, i, j + 1)];

    { 空いた右端に今回のシンボルを入れる。 }
    for i := 0 to FSize - 1 do
      FTable[Cell(k, i, FSize - 1)] := ASyms[i];

    { 斜めに読み出す。向きによって斜めの向きが逆になり、
      これで「かき混ぜ」と「戻し」が対になる。 }
    for i := 0 to FSize - 1 do
      if FDirection = idForward then
        ASyms[i] := FTable[Cell(k, i, FSize - i - 1)]
      else
        ASyms[i] := FTable[Cell(k, i, i)];
  end;
end;

procedure TInterleaver.ProcessBits(var ABits: LongWord);
var
  syms: array[0..7] of Byte;   { Size は 2..8 なので固定長で足りる }
  i: Integer;
  v: LongWord;
begin
  for i := 0 to FSize - 1 do
    syms[i] := (ABits shr (FSize - i - 1)) and 1;

  Process(syms);

  v := 0;
  for i := 0 to FSize - 1 do
    v := (v shl 1) or (syms[i] and 1);
  ABits := v;
end;

function TInterleaver.RoundTripDelayBlocks: Integer;
begin
  { (Size-1) x Depth。行ごとの遅れは FWD が i x Depth、REV が
    (Size-1-i) x Depth で、足すと i が消える。
    MFSK16 (Size 4 / Depth 10) なら 30 区画。 }
  Result := (FSize - 1) * FDepth;
end;

function TInterleaver.RoundTripDelaySymbols: Integer;
begin
  Result := RoundTripDelayBlocks * FSize;
end;

end.
