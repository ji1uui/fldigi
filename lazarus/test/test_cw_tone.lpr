{ ============================================================================
  test_cw_tone.lpr

  CwToneDetect の単体試験。

  復調器に組み込む前に、検出器そのものを合成波形で確かめる。
  組み込んでからでは、誤りが検出器のものか復調器のものか切り分けられない。

  確かめること
  ----------------------------------------------------------------------------
  1. 打鍵が無ければ「分からない」を返す (雑音だけで on を返さない)
  2. 判定の遅れが窓の半分ちょうどで一定である (遅れが一定なら要素長は歪まない)
  3. 要素の長さが正しく測れる (閾値が立ち上がりの中点にある)
  4. 大きさの絶対値に依らない (10^-6 でも 10^3 でも同じ判定)
  5. 確保しない (X-04)
  ============================================================================ }
program test_cw_tone;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math, CwToneDetect, Requirements;

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  Inc(TestCount);
  if ACondition then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    Inc(FailCount);
  end;
end;

procedure CheckEqI(AActual, AExpected: Int64; const AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected, '  実際: ', AActual);
    Inc(FailCount);
  end;
end;

const
  DOT = 50;          { 1 単位 = 50 回の Feed (12 WPM / 8 kHz / DEC 16 相当) }
  NOISE = 1.0E-5;    { 雑音の水準 }
  TONE = 0.3;        { トーンの水準 }
  EDGE = 6;          { 立ち上がり/立ち下がりの長さ [回] }

var
  GRnd: Cardinal = 12345;

function Rnd: Double;
begin
  { 再現できる擬似乱数。試験が実行ごとに揺れないようにする。 }
  GRnd := GRnd * 1103515245 + 12345;
  Result := ((GRnd shr 16) and $7FFF) / 32768.0;
end;

function NoiseSample: Double;
begin
  { 帯域制限後の雑音は概ね一定で、わずかに揺れる。 }
  Result := NOISE * (0.8 + 0.4 * Rnd);
end;

{ 立ち上がり/立ち下がりを整形したトーンの包絡線。 }
function Envelope(APos, ALen: Integer): Double;
begin
  if APos < EDGE then
    Result := TONE * (0.5 - 0.5 * Cos(Pi * APos / EDGE))
  else if APos > ALen - EDGE then
    Result := TONE * (0.5 - 0.5 * Cos(Pi * (ALen - APos) / EDGE))
  else
    Result := TONE;
  if Result < 0 then Result := 0;
end;

{ --------------------------------------------------------------------------
  1. 雑音だけでは on を返さないこと
  -------------------------------------------------------------------------- }
procedure TestNoiseOnly;
var
  d: TCwToneDetector;
  i, onCount, unknownCount: Integer;
  r: TCwToneDecision;
begin
  WriteLn;
  WriteLn('--- 1. 雑音だけのとき ---');
  d := TCwToneDetector.Create;
  try
    d.Configure(DOT);
    onCount := 0;
    unknownCount := 0;
    for i := 1 to DOT * 200 do
    begin
      r := d.Feed(NoiseSample);
      if r = ctdOn then Inc(onCount);
      if r = ctdUnknown then Inc(unknownCount);
    end;
    CheckEqI(onCount, 0,
      '**雑音だけでは一度も on を返さない** (誤検出しない)');
    Check(unknownCount > DOT * 190,
      '大半が「分からない」になる (打鍵が無いと分かっている)');
    Check(not d.IsKeying, '打鍵なしと判定している');
  finally
    d.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. トーンの開始にどれだけ遅れるか
  -------------------------------------------------------------------------- }
procedure TestOnsetLatency;
var
  d: TCwToneDetector;
  i, firstOn, expected: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 判定の遅れ ---');
  d := TCwToneDetector.Create;
  try
    d.Configure(DOT);
    { 先に雑音を流す (実運用と同じく受信機は常に動いている)。 }
    for i := 1 to DOT * 20 do
      d.Feed(NoiseSample);
    Check(not d.IsKeying, '前提: 雑音の間は打鍵なし');

    firstOn := -1;
    for i := 0 to DOT * 6 - 1 do
      if (d.Feed(Envelope(i, DOT * 6) + NoiseSample) = ctdOn) and
         (firstOn < 0) then
        firstOn := i;

    Check(firstOn >= 0, 'トーンを検出した');
    { 判定は窓の中央について下すので、必ず Latency 回ぶん遅れる。
      そこから立ち上がりが閾値 (0.6) を越えるまでの数回が乗る。 }
    expected := d.Latency + EDGE div 2;
    WriteLn(Format('        開始から %d 回で on (窓の半分 = %d 回、' +
      '立ち上がり = %d 回、期待 %d 回)', [firstOn, d.Latency, EDGE, expected]));
    Check(Abs(firstOn - expected) <= EDGE,
      '**遅れが窓の半分ちょうど** (時定数ではなく固定の遅れ)');
    { 遅れが一定であることが要素長を保つ条件。立ち下がりも同じだけ
      遅れるので、差である要素長は変わらない。試験 3 で確かめる。 }
    Check(d.Latency = CWTD_HALF_DOTS * DOT,
      '遅れが窓の半分と一致する (設計どおり)');
  finally
    d.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. 要素の長さが正しく測れること
  -------------------------------------------------------------------------- }
procedure TestElementLength;
var
  d: TCwToneDetector;

  { 1 単位の空白 + ALen の音 + 4 単位の空白 を流し、on だった回数を返す。

    判定は窓の半分 (3 単位) 遅れるので、音を流している間だけ数えたのでは
    足りない。後ろの空白を窓の半分より長く取り、その間も数える。
    前の空白でも数えているのは、直前の要素が漏れて来ていないことを
    同時に確かめるためである (漏れていれば長さが伸びて試験が落ちる)。 }
  function MeasureTone(ALen: Integer): Integer;
  var
    i: Integer;
  begin
    Result := 0;
    for i := 1 to DOT do
      if d.Feed(NoiseSample) = ctdOn then
        Inc(Result);
    for i := 0 to ALen - 1 do
      if d.Feed(Envelope(i, ALen) + NoiseSample) = ctdOn then
        Inc(Result);
    for i := 1 to DOT * 4 do
      if d.Feed(NoiseSample) = ctdOn then
        Inc(Result);
  end;

var
  i, dotLen, dashLen: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 要素の長さ ---');
  d := TCwToneDetector.Create;
  try
    d.Configure(DOT);
    { 打鍵を数回流して窓を育てる。 }
    for i := 1 to 3 do
    begin
      MeasureTone(DOT);
      MeasureTone(DOT * 3);
    end;

    dotLen := MeasureTone(DOT);
    dashLen := MeasureTone(DOT * 3);
    WriteLn(Format('        短点 %d 回 (理想 %d) / 長点 %d 回 (理想 %d)',
      [dotLen, DOT, dashLen, DOT * 3]));

    { 立ち上がりと立ち下がりで対称に交差するので、長さは保たれるはず。 }
    Check(Abs(dotLen - DOT) <= EDGE,
      '短点の長さが理想と整形長のうちに収まる');
    Check(Abs(dashLen - DOT * 3) <= EDGE,
      '長点の長さが理想と整形長のうちに収まる');
    { 短点と長点が 2 単位の閾値で確実に分かれること。ここが崩れると
      短点が長点と誤判定される (この不具合の症状そのもの)。 }
    Check(dotLen < DOT * 2,
      '**短点が 2 単位未満と測れる** (長点と取り違えない)');
    Check(dashLen > DOT * 2,
      '**長点が 2 単位より長いと測れる**');
  finally
    d.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 絶対的な大きさに依らないこと

  受信機の利得や信号強度で桁が変わっても、同じ判定になること。
  -------------------------------------------------------------------------- }
procedure TestScaleInvariance;
var
  scales: array[0..3] of Double = (1.0E-6, 1.0E-3, 1.0, 1.0E3);
  k, i: Integer;
  d: TCwToneDetector;
  lens: array[0..3] of Integer;

  function MeasureAt(AScale: Double): Integer;
  var
    j, n: Integer;
  begin
    d.Reset;
    { 乱数列も揃える。揃えないと倍率ではなく雑音の違いを見てしまう。 }
    GRnd := 999;
    for j := 1 to DOT * 10 do
      d.Feed(NOISE * AScale * (0.8 + 0.4 * Rnd));
    { 窓を育てる }
    for j := 1 to 2 do
    begin
      for n := 0 to DOT * 3 - 1 do
        d.Feed(Envelope(n, DOT * 3) * AScale + NOISE * AScale);
      for n := 1 to DOT * 4 do
        d.Feed(NOISE * AScale * (0.8 + 0.4 * Rnd));
    end;
    Result := 0;
    for n := 0 to DOT - 1 do
      if d.Feed(Envelope(n, DOT) * AScale + NOISE * AScale) = ctdOn then
        Inc(Result);
    for n := 1 to DOT * 4 do
      if d.Feed(NOISE * AScale * (0.8 + 0.4 * Rnd)) = ctdOn then
        Inc(Result);
  end;

begin
  WriteLn;
  WriteLn('--- 4. 大きさの絶対値に依らないこと ---');
  d := TCwToneDetector.Create;
  try
    d.Configure(DOT);
    for k := 0 to High(scales) do
      lens[k] := MeasureAt(scales[k]);
    WriteLn(Format('        倍率 1e-6:%d  1e-3:%d  1:%d  1e3:%d',
      [lens[0], lens[1], lens[2], lens[3]]));
    for k := 1 to High(scales) do
      Check(Abs(lens[k] - lens[0]) <= 1,
        Format('倍率 %g でも同じ長さに測れる', [scales[k]]));
    for i := 0 to High(scales) do
      Check(lens[i] > 0, Format('倍率 %g で検出できる', [scales[i]]));
  finally
    d.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 確保しないこと (X-04)
  -------------------------------------------------------------------------- }
var
  GOldMM: TMemoryManager;
  GCounting: Boolean = False;
  GAllocCount: Integer = 0;

function CountingGetMem(ASize: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GOldMM.GetMem(ASize);
end;

function CountingReAllocMem(var P: Pointer; ASize: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GOldMM.ReAllocMem(P, ASize);
end;

procedure TestNoAllocation;
var
  d: TCwToneDetector;
  mm: TMemoryManager;
  i, n: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 判定が確保しないこと (X-04) ---');
  d := TCwToneDetector.Create;
  try
    d.Configure(DOT);
    for i := 1 to 100 do
      d.Feed(NoiseSample);

    GAllocCount := 0;
    GetMemoryManager(GOldMM);
    mm := GOldMM;
    mm.GetMem := @CountingGetMem;
    mm.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(mm);
    GCounting := True;
    try
      for i := 0 to 20000 do
        d.Feed(Envelope(i mod (DOT * 4), DOT * 4) + NoiseSample);
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0, Format('2 万回の判定で確保 0 回 (実測 %d)', [n]));
  finally
    d.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 境界の扱い
  -------------------------------------------------------------------------- }
procedure TestEdgeCases;
var
  d: TCwToneDetector;
  i, n: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 境界 ---');
  d := TCwToneDetector.Create;
  try
    d.Configure(DOT);
    Check(d.Feed(0) = ctdUnknown, '最初の 1 標本では判定しない');

    { 完全な無音 (すべて 0)。lo=0 なので比が定義できない。 }
    d.Reset;
    n := 0;
    for i := 1 to DOT * 20 do
      if d.Feed(0) = ctdOn then Inc(n);
    CheckEqI(n, 0, '完全な無音でも on を返さない (0 除算もしない)');

    { 負の入力は 0 として扱う。 }
    d.Reset;
    Check(d.Feed(-1.0) = ctdUnknown, '負の入力でも落ちない');

    { 速度変更で窓の長さが変わること。 }
    d.Configure(25);
    CheckEqI(d.WindowLen, 2 * 25 * CWTD_HALF_DOTS + 1,
      '窓の長さが速度に追随する');
    CheckEqI(d.Latency, 25 * CWTD_HALF_DOTS, '遅れも速度に追随する');
    d.Configure(0);
    Check(d.WindowLen >= 3, '0 を渡しても壊れない');

    { Reset で状態が消えること。 }
    d.Configure(DOT);
    for i := 1 to DOT * 10 do
      d.Feed(Envelope(i mod (DOT * 2), DOT * 2) + NoiseSample);
    d.Reset;
    Check(not d.IsKeying, 'Reset で打鍵ありの記憶が消える');
    Check(d.Feed(NoiseSample) = ctdUnknown, 'Reset 直後は判定しない');
  finally
    d.Free;
  end;
end;

begin
  WriteLn('=== CW トーン検出器 単体試験 ===');

  TestNoiseOnly;
  TestOnsetLatency;
  TestElementLength;
  TestScaleInvariance;
  TestNoAllocation;
  TestEdgeCases;

  if FailCount = 0 then
    CoverReq('MDM-002');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
