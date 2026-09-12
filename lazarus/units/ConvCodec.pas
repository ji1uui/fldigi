{ ============================================================================
  ConvCodec.pas

  畳み込み符号の符号化器と Viterbi 復号器。

  何のために要るのか
  ----------------------------------------------------------------------------
  MFSK 系のモード (MFSK16/32/64 など) は、音を符号に載せる前に畳み込み符号で
  冗長化し、受信側で Viterbi 復号する。雑音で数ビット倒れても、
  **系列全体として最も辻褄の合う道** を選ぶことで直せる。

  ここが単独のユニットなのは、Viterbi が特定のモードの持ち物ではないからで
  ある。拘束長と生成多項式を変えれば他のモードでも使える。DSP の基本部品を
  leaf に書き足すと二本になり、いずれ食い違う (X-05 で学んだ)。

  fldigi のどこを見たか
  ----------------------------------------------------------------------------
  src/filters/viterbi.cxx と src/include/viterbi.h。
  MFSK が使う定数は src/include/mfsk.h の
      NASA_K 7 / POLY1 0x6d / POLY2 0x4f
  で、これは NASA 標準の拘束長 7・符号化率 1/2 の畳み込み符号である。

  軟判定で受ける
  ----------------------------------------------------------------------------
  Decode が受け取るのは 0/1 の硬判定ではなく **0..255 の軟判定**である。

      0    確実に 0
      128  分からない (消失)
      255  確実に 1

  硬判定にしてから渡すと、「どちらとも言えない」という情報が捨てられる。
  Viterbi はその曖昧さごと足し合わせて道を選ぶので、軟判定のほうが強い。
  Baseline の Phase 3 「Soft Decision」はここに載る。

  出力の間隔について
  ----------------------------------------------------------------------------
  Decode は毎回答えを返すわけではない。道を **遡って** から確定させるので、
  8 ビットぶん (ChunkSize) 溜まったところで 1 バイトを返し、それ以外は
  CONV_NO_OUTPUT を返す。遡る長さ (TracebackLen) は拘束長の 12 倍で、
  fldigi が「任意の状態から計算するには 12 拘束長以上を要する」として
  いる値をそのまま使っている。
  ============================================================================ }
unit ConvCodec;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { 道の記憶。fldigi の PATHMEM と同じ。 }
  CONV_PATHMEM = 256;

  { MFSK 系が使う符号 (fldigi src/include/mfsk.h)。 }
  CONV_MFSK_K     = 7;
  CONV_MFSK_POLY1 = $6D;
  CONV_MFSK_POLY2 = $4F;

  { 軟判定の中点。ここを渡すと「分からない」の意味になる。 }
  CONV_SOFT_ERASURE = 128;

  { Decode がまだ答えを出せないときの戻り値。 }
  CONV_NO_OUTPUT = -1;

type
  EConvCodecError = class(Exception);

  { --- 符号化器 ---
    1 ビット入れると 2 ビット出る (符号化率 1/2)。
    戻り値の bit0 が poly1 の、bit1 が poly2 の出力である。 }
  TConvEncoder = class
  private
    FK: Integer;
    FPoly1: Integer;
    FPoly2: Integer;
    FOutput: array of Byte;    // 状態 -> 2 ビット出力の表
    FShreg: LongWord;
    FShregMask: LongWord;
  public
    constructor Create(AK: Integer = CONV_MFSK_K;
      APoly1: Integer = CONV_MFSK_POLY1; APoly2: Integer = CONV_MFSK_POLY2);
    procedure Reset;
    function Encode(ABit: Integer): Integer;
    property K: Integer read FK;
    property Poly1: Integer read FPoly1;
    property Poly2: Integer read FPoly2;
  end;

  { --- Viterbi 復号器 ---
    軟判定を 2 つずつ入れ、8 ビット溜まるごとに 1 バイトを返す。 }
  TViterbiDecoder = class
  private
    FK: Integer;
    FPoly1: Integer;
    FPoly2: Integer;
    FNStates: Integer;         // 1 shl (K-1)
    FOutput: array of Byte;    // 状態 -> 2 ビット出力の表 (1 shl K 個)
    FMetTab: array[0..1, 0..255] of Integer;
    FMetrics: array of Integer;   // [PATHMEM][NStates] を平坦に
    FHistory: array of Integer;
    FSequence: array[0..CONV_PATHMEM - 1] of Integer;
    FPtr: Integer;
    FTraceback: Integer;
    FChunkSize: Integer;
    function Traceback(out AMetric: Integer): Integer;
    procedure SetTracebackLen(AValue: Integer);
    procedure SetChunkSize(AValue: Integer);
  public
    constructor Create(AK: Integer = CONV_MFSK_K;
      APoly1: Integer = CONV_MFSK_POLY1; APoly2: Integer = CONV_MFSK_POLY2);
    procedure Reset;
    { ASym0 は poly1 の、ASym1 は poly2 の軟判定 (0..255)。
      8 ビット溜まったら 0..255 のバイトを返し、それ以外は CONV_NO_OUTPUT。
      AMetric には、その 8 ビットを選んだ道の確からしさ (大きいほど良い) が
      入る。Phase 3/4 の Evidence に載せるための材料である。 }
    function Decode(ASym0, ASym1: Byte; out AMetric: Integer): Integer;
    property K: Integer read FK;
    property StateCount: Integer read FNStates;

    { --- 遡る長さと、一度に確定するビット数 ---
      既定は fldigi の viterbi::init() と同じ (K*12 と 8) だが、モードによって
      変える。MFSK は mfsk.cxx の TRACEPAIR(45, 352) と setchunksize(1) で
      **遡り 45・1 ビットずつ**にしている。復調器が 1 ビット単位で
      Varicode のシフトレジスタへ入れる作りだからである。

      遡りを短くすると応答は速くなるが訂正力が落ちる。長くすると逆になる。
      モードごとの取り合いなので、ここは設定にしてある。 }
    property TracebackLen: Integer read FTraceback write SetTracebackLen;
    property ChunkSize: Integer read FChunkSize write SetChunkSize;
  end;

{ 立っているビットの数が奇数なら 1。生成多項式との畳み込みに使う。 }
function BitParity(AValue: LongWord): Integer;

implementation

function BitParity(AValue: LongWord): Integer;
var
  v: LongWord;
begin
  { 折り畳んで数える。ループより分岐が少ない。 }
  v := AValue;
  v := v xor (v shr 16);
  v := v xor (v shr 8);
  v := v xor (v shr 4);
  v := v xor (v shr 2);
  v := v xor (v shr 1);
  Result := Integer(v and 1);
end;

procedure ValidateParams(AK, APoly1, APoly2: Integer);
begin
  { 拘束長の上限は状態表の大きさで決まる。9 で 512 状態・256 道なら
    まだ現実的だが、それ以上は用が無いので断る。黙って巨大な表を
    確保するより、作れないと言うほうがよい。 }
  if (AK < 3) or (AK > 9) then
    raise EConvCodecError.CreateFmt(
      '拘束長は 3..9 です (指定 %d)', [AK]);
  if (APoly1 <= 0) or (APoly1 >= (1 shl AK)) then
    raise EConvCodecError.CreateFmt(
      '生成多項式 1 が拘束長に収まりません (%d / 上限 %d)',
      [APoly1, (1 shl AK) - 1]);
  if (APoly2 <= 0) or (APoly2 >= (1 shl AK)) then
    raise EConvCodecError.CreateFmt(
      '生成多項式 2 が拘束長に収まりません (%d / 上限 %d)',
      [APoly2, (1 shl AK) - 1]);
  if APoly1 = APoly2 then
    raise EConvCodecError.Create(
      '生成多項式が同じでは冗長になりません (2 本とも同じ出力になる)。');
end;

{ 状態 -> 2 ビット出力の表を作る。符号化器と復号器で同じものを使う。 }
procedure BuildOutputTable(var ATable: array of Byte;
  AK, APoly1, APoly2: Integer);
var
  i: Integer;
begin
  for i := 0 to (1 shl AK) - 1 do
    ATable[i] := Byte(BitParity(LongWord(APoly1 and i)) or
                      (BitParity(LongWord(APoly2 and i)) shl 1));
end;

{ TConvEncoder }

constructor TConvEncoder.Create(AK, APoly1, APoly2: Integer);
begin
  inherited Create;
  ValidateParams(AK, APoly1, APoly2);
  FK := AK;
  FPoly1 := APoly1;
  FPoly2 := APoly2;
  SetLength(FOutput, 1 shl FK);
  BuildOutputTable(FOutput, FK, FPoly1, FPoly2);
  FShregMask := LongWord((1 shl FK) - 1);
  Reset;
end;

procedure TConvEncoder.Reset;
begin
  FShreg := 0;
end;

function TConvEncoder.Encode(ABit: Integer): Integer;
begin
  { fldigi: shreg = (shreg << 1) | !!bit  ―― 0 以外はすべて 1 として扱う。 }
  FShreg := ((FShreg shl 1) or LongWord(Ord(ABit <> 0))) and FShregMask;
  Result := FOutput[FShreg];
end;

{ TViterbiDecoder }

constructor TViterbiDecoder.Create(AK, APoly1, APoly2: Integer);
var
  i: Integer;
begin
  inherited Create;
  ValidateParams(AK, APoly1, APoly2);
  FK := AK;
  FPoly1 := APoly1;
  FPoly2 := APoly2;
  FNStates := 1 shl (FK - 1);

  SetLength(FOutput, 1 shl FK);
  BuildOutputTable(FOutput, FK, FPoly1, FPoly2);

  { 軟判定 -> 尺度の表。0 なら「0 らしい」方向へ 128、255 なら逆へ 127。
    128 (消失) はどちらにも 0 を足す ―― 何も主張しない。 }
  for i := 0 to 255 do
  begin
    FMetTab[0, i] := CONV_SOFT_ERASURE - i;
    FMetTab[1, i] := i - CONV_SOFT_ERASURE;
  end;

  SetLength(FMetrics, CONV_PATHMEM * FNStates);
  SetLength(FHistory, CONV_PATHMEM * FNStates);

  { fldigi: _traceback = k * 12
    「任意の状態から計算するには 12 拘束長以上を要する」 }
  FTraceback := FK * 12;
  FChunkSize := 8;
  Reset;
end;

procedure TViterbiDecoder.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FMetrics) do FMetrics[i] := 0;
  for i := 0 to High(FHistory) do FHistory[i] := 0;
  for i := 0 to CONV_PATHMEM - 1 do FSequence[i] := 0;
  FPtr := 0;
end;

procedure TViterbiDecoder.SetTracebackLen(AValue: Integer);
begin
  { 道の記憶より長くは遡れない。確定させる分も要るので余裕を見る。 }
  if (AValue < FK) or (AValue > CONV_PATHMEM - 16) then
    raise EConvCodecError.CreateFmt(
      '遡る長さは %d..%d です (指定 %d)', [FK, CONV_PATHMEM - 16, AValue]);
  FTraceback := AValue;
  Reset;
end;

procedure TViterbiDecoder.SetChunkSize(AValue: Integer);
begin
  { PATHMEM を割り切れないと、ptr が一周したときに確定の位置がずれる。 }
  if (AValue < 1) or (AValue > 8) or ((CONV_PATHMEM mod AValue) <> 0) then
    raise EConvCodecError.CreateFmt(
      '一度に確定するビット数は 1..8 かつ %d の約数です (指定 %d)',
      [CONV_PATHMEM, AValue]);
  FChunkSize := AValue;
  Reset;
end;

function TViterbiDecoder.Traceback(out AMetric: Integer): Integer;
var
  bestMetric, bestState, i, p, prev, c, startMetric: Integer;
begin
  p := (FPtr + CONV_PATHMEM - 1) mod CONV_PATHMEM;

  { いちばん確からしい状態を探す。 }
  bestMetric := Low(Integer);
  bestState := 0;
  for i := 0 to FNStates - 1 do
    if FMetrics[p * FNStates + i] > bestMetric then
    begin
      bestMetric := FMetrics[p * FNStates + i];
      bestState := i;
    end;

  { そこから TracebackLen ぶん遡る。遡った先では、どの状態から来たかが
    ほぼ一意に決まっている ―― これが Viterbi が「後から」直せる理由。 }
  FSequence[p] := bestState;
  for i := 1 to FTraceback do
  begin
    prev := (p + CONV_PATHMEM - 1) mod CONV_PATHMEM;
    FSequence[prev] := FHistory[p * FNStates + FSequence[p]];
    p := prev;
  end;

  startMetric := FMetrics[p * FNStates + FSequence[p]];

  { 遡った地点から ChunkSize ビットぶん前へ読み出す。
    状態の最下位ビットが、そのとき入力されたビットである。 }
  c := 0;
  for i := 1 to FChunkSize do
  begin
    c := (c shl 1) or (FSequence[p] and 1);
    p := (p + 1) mod CONV_PATHMEM;
  end;

  { この 8 ビットぶんで道の尺度がどれだけ伸びたか。大きいほど確からしい。 }
  AMetric := FMetrics[p * FNStates + FSequence[p]] - startMetric;
  Result := c;
end;

function TViterbiDecoder.Decode(ASym0, ASym1: Byte; out AMetric: Integer): Integer;
var
  met: array[0..3] of Integer;
  n, s0, s1, p0, p1, m0, m1, i, j: Integer;
  currptr, prevptr: Integer;
begin
  AMetric := 0;
  currptr := FPtr;
  prevptr := (currptr + CONV_PATHMEM - 1) mod CONV_PATHMEM;

  { 2 ビットの組み合わせ 4 通りについて、受け取った軟判定との合い具合。
    添字は (poly2 のビット shl 1) or (poly1 のビット) で、
    BuildOutputTable の並びと揃えてある。 }
  met[0] := FMetTab[0, ASym1] + FMetTab[0, ASym0];
  met[1] := FMetTab[0, ASym1] + FMetTab[1, ASym0];
  met[2] := FMetTab[1, ASym1] + FMetTab[0, ASym0];
  met[3] := FMetTab[1, ASym1] + FMetTab[1, ASym0];

  for n := 0 to FNStates - 1 do
  begin
    { 状態 n へ来られる道は 2 本しかない。良いほうだけ残す。
      残さなかったほうは二度と最良になれない ―― それが Viterbi の要。 }
    s0 := n;
    s1 := n + FNStates;
    p0 := s0 shr 1;
    p1 := s1 shr 1;

    m0 := FMetrics[prevptr * FNStates + p0] + met[FOutput[s0]];
    m1 := FMetrics[prevptr * FNStates + p1] + met[FOutput[s1]];

    if m0 > m1 then
    begin
      FMetrics[currptr * FNStates + n] := m0;
      FHistory[currptr * FNStates + n] := p0;
    end
    else
    begin
      FMetrics[currptr * FNStates + n] := m1;
      FHistory[currptr * FNStates + n] := p1;
    end;
  end;

  FPtr := (FPtr + 1) mod CONV_PATHMEM;

  if (FPtr mod FChunkSize) = 0 then
    Exit(Traceback(AMetric));

  { 尺度は足し続けると際限なく育つ。全体を平行移動しても道の選択は
    変わらないので、大きくなったら丸ごと引く。
    (-Crio で建てるので、桁あふれさせてはいけない。1 歩あたり最大 255、
    ChunkSize 8 歩ごとに必ずここを通るので余裕は十分ある。) }
  if FMetrics[currptr * FNStates] > (High(Integer) div 2) then
    for i := 0 to CONV_PATHMEM - 1 do
      for j := 0 to FNStates - 1 do
        Dec(FMetrics[i * FNStates + j], High(Integer) div 2);

  if FMetrics[currptr * FNStates] < (Low(Integer) div 2) then
    for i := 0 to CONV_PATHMEM - 1 do
      for j := 0 to FNStates - 1 do
        Inc(FMetrics[i * FNStates + j], High(Integer) div 2);

  Result := CONV_NO_OUTPUT;
end;

end.
