{ ============================================================================
  test_fftshared.lpr

  Phase 1 / §4 X-05「FFT、Noise Estimator、Spectrum 等を共有サービス化する」
  のうち FFT の共有プランの検証。

  何を確かめなければならないか
  ----------------------------------------------------------------------------
  この変更は **復調器が出す数値そのもの** を変える。速くなったと言う前に、
  結果が正しいことを示さなければならない。「前と同じ値が出る」では
  足りない ── 前の実装が正しい保証がそもそも無いからである。

  そこで独立した基準を置く。

    1. 直接 DFT (O(N^2))。定義そのままなので、速さを捨てれば
       いちばん信用できる。これに対する誤差を、旧実装と新実装で比べる。
    2. 解析的に答えが分かる入力 (単一の複素正弦波 → 1 本のビンだけが立つ)。

  旧実装は段ごとに係数を漸化式 `w := w * wlen` で更新していたので、
  内側ループが長いほど誤差が積み上がる。表引きにすればそれが無くなる。
  つまり **速いだけでなく正確になっている** はずで、それも測る。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_fftshared;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math,
  ModemDSP, Observability, Requirements;

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

{ --------------------------------------------------------------------------
  独立した基準: 定義どおりの離散フーリエ変換
  -------------------------------------------------------------------------- }
procedure DirectDft(const AIn: TComplexArray; out AOut: TComplexArray);
var
  n, k, i: Integer;
  sumRe, sumIm, ang, c, sr: Double;
begin
  n := Length(AIn);
  SetLength(AOut, n);
  for k := 0 to n - 1 do
  begin
    sumRe := 0; sumIm := 0;
    for i := 0 to n - 1 do
    begin
      { 角度を毎回直接計算する。漸化式を使わないので誤差が積み上がらない。 }
      ang := -2 * Pi * ((Int64(k) * i) mod n) / n;
      c := Cos(ang); sr := Sin(ang);
      sumRe := sumRe + AIn[i].Re * c - AIn[i].Im * sr;
      sumIm := sumIm + AIn[i].Re * sr + AIn[i].Im * c;
    end;
    AOut[k] := CplxMake(sumRe, sumIm);
  end;
end;

function MaxDiff(const A, B: TComplexArray): Double;
var
  i: Integer;
  d: Double;
begin
  Result := 0;
  for i := 0 to High(A) do
  begin
    d := Sqrt(Sqr(A[i].Re - B[i].Re) + Sqr(A[i].Im - B[i].Im));
    if d > Result then Result := d;
  end;
end;

procedure MakeSignal(var A: TComplexArray; N: Integer);
var
  i: Integer;
begin
  SetLength(A, N);
  for i := 0 to N - 1 do
    A[i] := CplxMake(Sin(i * 0.1) + 0.3 * Cos(i * 0.73), Cos(i * 0.17));
end;

{ --------------------------------------------------------------------------
  1. 定義どおりの DFT と一致すること ── 正しさの根拠
  -------------------------------------------------------------------------- }
procedure TestAgainstDirectDft;
const
  SIZES: array[0..2] of Integer = (64, 128, 256);
var
  k, N: Integer;
  src, plan, refv, dft: TComplexArray;
  ePlan, eRef: Double;
  planBetter: Integer;
begin
  WriteLn;
  WriteLn('--- 1. 定義どおりの DFT との一致 ---');
  planBetter := 0;
  for k := 0 to High(SIZES) do
  begin
    N := SIZES[k];
    MakeSignal(src, N);
    DirectDft(src, dft);

    SetLength(plan, N);
    Move(src[0], plan[0], N * SizeOf(TComplex));
    ComplexFFT(plan);

    SetLength(refv, N);
    Move(src[0], refv[0], N * SizeOf(TComplex));
    ComplexFFTReference(refv);

    ePlan := MaxDiff(plan, dft);
    eRef := MaxDiff(refv, dft);
    WriteLn(Format('  N=%-5d 共有プランの誤差 %.3e / 旧実装の誤差 %.3e',
      [N, ePlan, eRef]));

    Check(ePlan < 1E-9,
      Format('N=%d: 共有プランが DFT と一致する', [N]));
    if ePlan <= eRef then Inc(planBetter);
  end;
  CheckEqI(planBetter, Length(SIZES),
    '**すべての長さで共有プランの方が DFT に近い (悪化していない)**');
end;

{ --------------------------------------------------------------------------
  2. 解析的に答えが分かる入力
  -------------------------------------------------------------------------- }
procedure TestAnalyticCases;
const
  N = 256;
  BIN = 7;
var
  a: TComplexArray;
  i: Integer;
  ang, peak, other, m: Double;
  peakIdx: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 答えが分かっている入力 ---');

  { 単一の複素正弦波 exp(+2*pi*i*BIN*n/N) → BIN 番のビンだけが N になる。 }
  SetLength(a, N);
  for i := 0 to N - 1 do
  begin
    ang := 2 * Pi * BIN * i / N;
    a[i] := CplxMake(Cos(ang), Sin(ang));
  end;
  ComplexFFT(a);

  peak := 0; peakIdx := -1; other := 0;
  for i := 0 to N - 1 do
  begin
    m := Sqrt(Sqr(a[i].Re) + Sqr(a[i].Im));
    if m > peak then
    begin
      peak := m;
      peakIdx := i;
    end;
  end;
  for i := 0 to N - 1 do
  begin
    if i = peakIdx then Continue;
    m := Sqrt(Sqr(a[i].Re) + Sqr(a[i].Im));
    if m > other then other := m;
  end;

  CheckEqI(peakIdx, BIN, '単一正弦波は正しいビンに立つ');
  Check(Abs(peak - N) < 1E-9,
    Format('ピークの大きさが N になる (%.6f)', [peak]));
  Check(other < 1E-9,
    Format('他のビンは 0 になる (最大 %.3e)', [other]));

  { 直流 → 0 番だけが N。 }
  SetLength(a, N);
  for i := 0 to N - 1 do
    a[i] := CplxMake(1.0, 0.0);
  ComplexFFT(a);
  Check(Abs(a[0].Re - N) < 1E-9, '直流は 0 番に集まる');
  Check(Abs(a[1].Re) < 1E-9, '直流では他のビンが 0');

  { 単位インパルス → 全ビンが 1。 }
  SetLength(a, N);
  for i := 0 to N - 1 do
    a[i] := CplxMake(0.0, 0.0);
  a[0] := CplxMake(1.0, 0.0);
  ComplexFFT(a);
  other := 0;
  for i := 0 to N - 1 do
  begin
    m := Sqrt(Sqr(a[i].Re - 1.0) + Sqr(a[i].Im));
    if m > other then other := m;
  end;
  Check(other < 1E-12, 'インパルスは全ビンが 1 になる');
end;

{ --------------------------------------------------------------------------
  3. 往復精度が改善していること
  -------------------------------------------------------------------------- }
procedure TestRoundTripAccuracy;
const
  SIZES: array[0..2] of Integer = (256, 512, 2048);
var
  k, N, i: Integer;
  src, a: TComplexArray;
  ePlan, eRef, d: Double;
  improved: Integer;

  function RoundTripErrRef(const ASrc: TComplexArray): Double;
  var
    b: TComplexArray;
    j, n2: Integer;
    invN, e: Double;
  begin
    n2 := Length(ASrc);
    SetLength(b, n2);
    Move(ASrc[0], b[0], n2 * SizeOf(TComplex));
    ComplexFFTReference(b);
    { 旧実装の逆変換に相当するもの。共役をとって順変換し 1/N。 }
    for j := 0 to n2 - 1 do
      b[j] := CplxMake(b[j].Re, -b[j].Im);
    ComplexFFTReference(b);
    invN := 1.0 / n2;
    Result := 0;
    for j := 0 to n2 - 1 do
    begin
      e := Sqrt(Sqr(b[j].Re * invN - ASrc[j].Re) +
                Sqr(-b[j].Im * invN - ASrc[j].Im));
      if e > Result then Result := e;
    end;
  end;

begin
  WriteLn;
  WriteLn('--- 3. 往復精度 ---');
  improved := 0;
  for k := 0 to High(SIZES) do
  begin
    N := SIZES[k];
    MakeSignal(src, N);

    SetLength(a, N);
    Move(src[0], a[0], N * SizeOf(TComplex));
    ComplexFFT(a);
    InverseComplexFFT(a);
    ePlan := 0;
    for i := 0 to N - 1 do
    begin
      d := Sqrt(Sqr(a[i].Re - src[i].Re) + Sqr(a[i].Im - src[i].Im));
      if d > ePlan then ePlan := d;
    end;

    eRef := RoundTripErrRef(src);
    WriteLn(Format('  N=%-5d 共有プラン %.3e / 旧実装 %.3e (%.1f 倍改善)',
      [N, ePlan, eRef, eRef / Max(ePlan, 1E-300)]));

    Check(ePlan < 1E-12, Format('N=%d: 往復して元に戻る', [N]));
    if ePlan < eRef then Inc(improved);
  end;
  CheckEqI(improved, Length(SIZES),
    '**すべての長さで往復精度が改善している** (係数を漸化式で積まないため)');
end;

{ --------------------------------------------------------------------------
  4. 共有されていること
  -------------------------------------------------------------------------- }
procedure TestSharing;
var
  p1, p2, p3: TFftPlan;
  before, u0: Int64;
  cnt: Integer;
begin
  WriteLn;
  WriteLn('--- 4. プランが共有されていること (X-05) ---');

  p1 := SharedFftPlan(512);
  p2 := SharedFftPlan(512);
  Check(p1 = p2, '**同じ長さなら同じプランが返る** (資源が重複しない)');
  CheckEqI(p1.Size, 512, '長さが一致する');
  CheckEqI(p1.TwiddleCount, 511, '係数は N-1 個');

  p3 := SharedFftPlan(2048);
  Check(p3 <> p1, '長さが違えば別のプラン');

  u0 := p1.UseCount;
  SharedFftPlan(512);
  Check(p1.UseCount > u0, '引き当てた回数が数えられる (共有の確認用)');

  cnt := SharedFftPlanCount;
  before := cnt;
  SharedFftPlan(512);
  SharedFftPlan(2048);
  CheckEqI(SharedFftPlanCount, before, '既にある長さでは増えない');

  { RTTY は 512 の mark/space、CW は 2048。どちらも既に作られている。 }
  Check(cnt >= 2, '実際に使う長さのプランが保持されている');

  { 不正な長さ。 }
  try
    SharedFftPlan(300);
    Check(False, '2 の冪でない長さは拒むべき');
  except
    on EDspError do Check(True, '2 の冪でない長さは拒む');
  end;
end;

{ --------------------------------------------------------------------------
  5. 変換が確保しないこと (X-04)
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
  mm: TMemoryManager;
  a: TComplexArray;
  plan: TFftPlan;
  i, r: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 変換が確保しないこと (X-04) ---');
  MakeSignal(a, 512);
  plan := SharedFftPlan(512);
  { 先に一度回してから測る (遅延初期化を測らないため)。 }
  plan.Forward(a);
  plan.Inverse(a);

  GAllocCount := 0;
  GetMemoryManager(GOldMM);
  mm := GOldMM;
  mm.GetMem := @CountingGetMem;
  mm.ReAllocMem := @CountingReAllocMem;
  SetMemoryManager(mm);
  GCounting := True;
  try
    for r := 1 to 200 do
    begin
      plan.Forward(a);
      plan.Inverse(a);
    end;
    { 共有プランを引き当てる経路も確保してはならない。 }
    for r := 1 to 200 do
      SharedFftPlan(512);
    i := GAllocCount;
  finally
    GCounting := False;
    SetMemoryManager(GOldMM);
  end;
  CheckEqI(i, 0,
    Format('200 回の往復と 200 回の引き当てで確保 0 回 (実測 %d)', [i]));
end;

{ --------------------------------------------------------------------------
  6. 複数スレッドが同じプランを同時に使えること

  Phase 3 は復調戦略を並べる。戦略ごとにプランを持たずに済むことが
  共有の目的なので、同時に使って壊れないことを確かめる。
  -------------------------------------------------------------------------- }
type
  TFftWorker = class(TThread)
  private
    FN: Integer;
    FIters: Integer;
    FBad: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AN, AIters: Integer);
    property Bad: Integer read FBad;
  end;

constructor TFftWorker.Create(AN, AIters: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FN := AN;
  FIters := AIters;
end;

procedure TFftWorker.Execute;
var
  plan: TFftPlan;
  src, a: TComplexArray;
  i, r: Integer;
  d: Double;
begin
  plan := SharedFftPlan(FN);
  MakeSignal(src, FN);
  SetLength(a, FN);
  for r := 1 to FIters do
  begin
    Move(src[0], a[0], FN * SizeOf(TComplex));
    plan.Forward(a);
    plan.Inverse(a);
    for i := 0 to FN - 1 do
    begin
      d := Sqrt(Sqr(a[i].Re - src[i].Re) + Sqr(a[i].Im - src[i].Im));
      if d > 1E-9 then
      begin
        Inc(FBad);
        Break;
      end;
    end;
  end;
end;

procedure TestConcurrentUse;
const
  WORKERS = 4;
  ITERS = 300;
var
  w: array[0..WORKERS - 1] of TFftWorker;
  i, totalBad: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 複数スレッドが同じプランを同時に使うこと ---');
  for i := 0 to WORKERS - 1 do
    { 半分は 512、半分は 2048。同じプランを 2 本ずつが共有する。 }
    if (i mod 2) = 0 then
      w[i] := TFftWorker.Create(512, ITERS)
    else
      w[i] := TFftWorker.Create(2048, ITERS);
  try
    for i := 0 to WORKERS - 1 do w[i].Start;
    for i := 0 to WORKERS - 1 do w[i].WaitFor;
    totalBad := 0;
    for i := 0 to WORKERS - 1 do
      Inc(totalBad, w[i].Bad);
    CheckEqI(totalBad, 0,
      Format('**%d スレッド x %d 回で 1 件も壊れない** (プランは読むだけ)',
        [WORKERS, ITERS]));
  finally
    for i := 0 to WORKERS - 1 do w[i].Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 速さ (改善の確認。閾値は緩く取る)
  -------------------------------------------------------------------------- }
procedure TestSpeed;
const
  N = 512;
  ITERS = 3000;
  ROUNDS = 5;
var
  src, a: TComplexArray;
  r, k: Integer;
  t0, dt, bestRef, bestPlan: Double;
begin
  WriteLn;
  WriteLn('--- 7. 速さ ---');
  MakeSignal(src, N);
  SetLength(a, N);

  { 暖機。最初の一周は係数表も分岐予測も冷えているので、
    先に測ったほうが損をする。 }
  for r := 1 to 200 do
  begin
    Move(src[0], a[0], N * SizeOf(TComplex));
    ComplexFFTReference(a);
    Move(src[0], a[0], N * SizeOf(TComplex));
    ComplexFFT(a);
  end;

  { 交互に何周か測り、それぞれの **最小** を採る。
    壁時計は他の仕事に邪魔されて伸びることはあっても縮むことはないので、
    最小が最も汚染の少ない標本になる。平均は外れ値を引きずる。
    一度ずつ測って比べる作りだと、片方だけが邪魔された回に結論が反転する。 }
  bestRef := Infinity;
  bestPlan := Infinity;
  for k := 1 to ROUNDS do
  begin
    t0 := ObsHiResSeconds;
    for r := 1 to ITERS do
    begin
      Move(src[0], a[0], N * SizeOf(TComplex));
      ComplexFFTReference(a);
    end;
    dt := (ObsHiResSeconds - t0) / ITERS * 1E6;
    if dt < bestRef then bestRef := dt;

    t0 := ObsHiResSeconds;
    for r := 1 to ITERS do
    begin
      Move(src[0], a[0], N * SizeOf(TComplex));
      ComplexFFT(a);
    end;
    dt := (ObsHiResSeconds - t0) / ITERS * 1E6;
    if dt < bestPlan then bestPlan := dt;
  end;

  WriteLn(Format('  N=%d 旧実装 %.2f us / 共有プラン %.2f us (比 %.2f)',
    [N, bestRef, bestPlan, bestPlan / bestRef]));
  {$IFOPT R+}
  WriteLn('  ※ 範囲検査つきで測っている。検査を外すと共有プランは約 2 割速い。');
  WriteLn('    係数表の読み出しが 1 回ごとに検査されるためで、検査つきでは');
  WriteLn('    表引きの利得がほぼ相殺される (README §37 に実測を残した)。');
  {$ENDIF}

  { **速さは RT-008 の主張ではない。**
    RT-008 が言っているのは「資源の重複を無くす」—— 係数表を人数分
    持たないことであって、速いことではない。それは試験 4 で見ている。

    ここで壁時計の比を合否にしていたところ、閾値 1.05 に対して実測が
    1.01〜1.10 の間を行き来し、機械の負荷しだいで落ちるようになっていた。
    落ちると RT-008 の被覆申告が消え、§18 の突き合わせが
    「検証済なのに誰も検証していない」という**無関係な理由**で赤くなる。
    速さの揺らぎが要求表の嘘に化けるのは筋が悪い。

    そこで合否は「桁違いに遅くなっていない」ことだけにし、
    実測値は数字として残す (README §16 と同じ扱い)。 }
  Check(bestPlan < bestRef * 1.5,
    Format('共有プランが桁違いに遅くなっていない (比 %.2f)',
      [bestPlan / bestRef]));
end;

begin
  WriteLn('=== Phase 1 X-05 共有 FFT プラン テスト ===');

  TestAgainstDirectDft;
  TestAnalyticCases;
  TestRoundTripAccuracy;
  TestSharing;
  TestNoAllocation;
  TestConcurrentUse;
  TestSpeed;

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
    CoverReq('RT-008');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
