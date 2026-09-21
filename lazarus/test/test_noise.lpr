{ ============================================================================
  test_noise.lpr

  雑音床の共有サービスの試験 (units/NoiseEstimator.pas)。
  Phase 3 Adaptive Receiver の最初の部品である。

  何を守るか
  ----------------------------------------------------------------------------
  1. **較正**: 白色雑音の密度が理論値 2*sigma^2/Fs に載る
     (分位点・窓・FFT 長を変えても)
  2. **強い信号が立っても雑音床が動かない** (平均ならどうなるかと対比)
  3. 帯域 S/N が信号の強さに追随する
  4. 取りこぼしと流し直しを黙って飲まない
  5. ならしが 1 枠の揺らぎを潰す
  6. 測れていない間は使わせない
  7. 確保しない (X-04) / 同じ音から同じ結果 (Z-05)

  1 と 2 が対になっている。分位点を使うのは 2 のためだが、分位点は
  平均より小さい値なので、そのままでは雑音床を低く見積もって
  **S/N をよく申告してしまう**。だから較正係数で割り戻す。
  較正だけ見ても、頑丈さだけ見ても、片方は成り立ってしまう。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_noise;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, SpectrumService, NoiseEstimator,
  TestVectors, Requirements;

type
  TDArr = array of Double;

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  Inc(TestCount);
  if ACondition then WriteLn('  [OK] ', AMsg)
  else begin WriteLn('  [NG] ', AMsg); Inc(FailCount); end;
end;

procedure CheckEqI(AActual, AExpected: Int64; const AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected, '  実際: ', AActual);
    Inc(FailCount);
  end;
end;

const
  SR = 8000;
  HOP = 1024;
  FRAMES = 120;

{ 白色雑音 (+ 指定した本数の強い信号) を流して推定させる。
  AMeanDensity には、同じ枠から平均で出した密度を返す ―― 分位点を
  使う意味を見るための対照である。 }
procedure RunNoise(AFftSize: Integer; AWindow: TSpectrumWindow;
  APercentile: Double; ASigma: Double; ATones: Integer;
  out ADensity, AMeanDensity: Double; out AFrames: Int64;
  ASmooth: Integer = 8);
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rnd: TVectorRandom;
  buf, bins: TDArr;
  info: TNoiseUpdateInfo;
  fi: TSpectrumFrameInfo;
  reader: TSpectrumReader;
  i, n, t: Integer;
  sum: Double;
  cnt: Integer;
begin
  sp := TSpectrumService.Create(AFftSize, SR, HOP, AWindow);
  ne := TNoiseEstimator.Create(sp, APercentile, ASmooth);
  try
    rnd.Seed(20260921);
    SetLength(buf, HOP);
    SetLength(bins, sp.BinCount);
    reader := sp.NewReader;
    sum := 0; cnt := 0;
    for n := 1 to FRAMES do
    begin
      for i := 0 to HOP - 1 do
      begin
        buf[i] := ASigma * rnd.NextGauss;
        for t := 1 to ATones do
          buf[i] := buf[i] +
            1.0 * Sin(2 * Pi * (500 + 300 * t) * ((n - 1) * HOP + i) / SR);
      end;
      sp.Feed(buf, HOP);
      ne.Update(info);
      { 対照: 同じ枠を別の読み手で読み、平均で密度を出す。 }
      while sp.TryRead(reader, bins, fi) = srOk do
      begin
        for i := 1 to sp.BinCount - 2 do
          sum := sum + sp.PowerToDensity(bins[i]);
        Inc(cnt, sp.BinCount - 2);
      end;
    end;
    ADensity := ne.NoiseDensity;
    AFrames := ne.FramesUsed;
    if cnt > 0 then AMeanDensity := sum / cnt else AMeanDensity := 0;
  finally
    ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  1. 較正
  -------------------------------------------------------------------------- }
procedure TestCalibration;
var
  d, md, theory, sigma, worst, ratio: Double;
  frames: Int64;
  i: Integer;
  ps: array[0..3] of Double = (0.25, 0.5, 0.75, 0.9);
  ffts: array[0..2] of Integer = (1024, 4096, 8192);
  wins: array[0..2] of TSpectrumWindow = (swRectangular, swHann, swBlackman);
begin
  WriteLn;
  WriteLn('--- 1. 較正: 白色雑音の密度が理論値に載る ---');
  sigma := 0.3;
  theory := 2 * sigma * sigma / SR;

  WriteLn('        分位点ごと (FFT 4096 / Hann)');
  WriteLn('          分位点   係数     推定/理論');
  worst := 0;
  for i := 0 to High(ps) do
  begin
    RunNoise(4096, swHann, ps[i], sigma, 0, d, md, frames);
    ratio := d / theory;
    WriteLn(Format('          %6.2f   %.4f   %.4f (%.2f dB)',
      [ps[i], -Ln(1 - ps[i]), ratio, 10 * Log10(ratio)]));
    if Abs(10 * Log10(ratio)) > worst then worst := Abs(10 * Log10(ratio));
  end;
  Check(worst < 0.3,
    Format('**分位点を変えても理論値に載る** (最大のずれ %.3f dB)', [worst]));

  WriteLn('        FFT 長ごと (分位点 0.5 / Hann)');
  for i := 0 to High(ffts) do
  begin
    RunNoise(ffts[i], swHann, 0.5, sigma, 0, d, md, frames);
    ratio := d / theory;
    WriteLn(Format('          %6d   %.4f (%.2f dB)',
      [ffts[i], ratio, 10 * Log10(ratio)]));
    if Abs(10 * Log10(ratio)) > worst then worst := Abs(10 * Log10(ratio));
  end;

  WriteLn('        窓ごと (FFT 4096 / 分位点 0.5)');
  for i := 0 to High(wins) do
  begin
    RunNoise(4096, wins[i], 0.5, sigma, 0, d, md, frames);
    ratio := d / theory;
    WriteLn(Format('          %-12s %.4f (%.2f dB)',
      [SpectrumWindowName(wins[i]), ratio, 10 * Log10(ratio)]));
    if Abs(10 * Log10(ratio)) > worst then worst := Abs(10 * Log10(ratio));
  end;
  Check(worst < 0.5,
    Format('**窓と FFT 長を変えても理論値に載る** (最大のずれ %.3f dB)',
      [worst]));

  { 較正係数そのもの。指数分布の p 分位点は -ln(1-p) * 平均。 }
  RunNoise(4096, swHann, 0.5, sigma, 0, d, md, frames);
  Check(Abs(-Ln(0.5) - 0.6931471805) < 1E-9, '中央値の較正係数は ln2');
  Check(frames > 0, Format('枠を取り込んでいる (%d 枠)', [frames]));
end;

{ --------------------------------------------------------------------------
  2. 強い信号が立っても動かない

  分位点を使う理由そのものである。平均で出した密度を並べて比べる ――
  平均は信号に引きずられ、分位点は動かない。片方だけでは
  「そもそも信号が入っていない」と区別できない。
  -------------------------------------------------------------------------- }
procedure TestRobustToSignals;
var
  d, md, theory, sigma, worstQ, riseMean: Double;
  frames: Int64;
  i: Integer;
  tones: array[0..4] of Integer = (0, 1, 2, 4, 8);
  meanAt0: Double;
begin
  WriteLn;
  WriteLn('--- 2. 強い信号が立っても雑音床が動かない ---');
  sigma := 0.3;
  theory := 2 * sigma * sigma / SR;
  worstQ := 0; riseMean := 0; meanAt0 := 0;

  WriteLn('          信号の本数   分位点/理論   平均/理論');
  for i := 0 to High(tones) do
  begin
    RunNoise(4096, swHann, 0.5, sigma, tones[i], d, md, frames);
    if i = 0 then meanAt0 := md;
    WriteLn(Format('          %10d   %10.4f   %9.4f',
      [tones[i], d / theory, md / theory]));
    if Abs(d / theory - 1) > worstQ then worstQ := Abs(d / theory - 1);
    if md / meanAt0 > riseMean then riseMean := md / meanAt0;
  end;

  Check(worstQ < 0.10,
    Format('**信号が 8 本立っても雑音床のずれが %.1f%% 以内**',
      [100 * worstQ]));
  Check(riseMean > 2.0,
    Format('前提: 平均なら %.1f 倍に持ち上がる (分位点を使う理由)',
      [riseMean]));
end;

{ --------------------------------------------------------------------------
  3. 帯域 S/N
  -------------------------------------------------------------------------- }
procedure TestBandSnr;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rnd: TVectorRandom;
  buf: TDArr;
  info: TNoiseUpdateInfo;
  i, n, k: Integer;
  amp, snr, prev: Double;
  amps: array[0..3] of Double = (0.1, 0.3, 1.0, 3.0);
  rising: Boolean;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 3. 帯域 S/N が信号の強さに追随する ---');
  WriteLn('          振幅    帯域S/N[dB]   理屈との差');
  rising := True;
  prev := -1E30;
  for k := 0 to High(amps) do
  begin
    amp := amps[k];
    sp := TSpectrumService.Create(4096, SR, HOP, swHann);
    ne := TNoiseEstimator.Create(sp, 0.5, 8);
    try
      rnd.Seed(20260921);
      SetLength(buf, HOP);
      for n := 1 to FRAMES do
      begin
        for i := 0 to HOP - 1 do
          buf[i] := 0.3 * rnd.NextGauss
            + amp * Sin(2 * Pi * 1000 * ((n - 1) * HOP + i) / SR);
        sp.Feed(buf, HOP);
        ne.Update(info);
      end;
      snr := ne.SnrInBandDb(950, 1050);
      { 理屈: 信号電力 amp^2/2、帯域内の雑音は 密度 x 100 Hz。 }
      WriteLn(Format('          %5.2f   %9.2f   %9.2f',
        [amp, snr,
         snr - 10 * Log10((amp * amp / 2) / (ne.NoiseDensity * 100))]));
      if snr <= prev then rising := False;
      prev := snr;
    finally
      ne.Free; sp.Free;
    end;
  end;
  Check(rising, '**信号を強くすると帯域 S/N が上がる**');

  { 20 dB 強くすれば S/N もおよそ 20 dB 上がる。 }
  Check(prev > 30, Format('十分強い信号では S/N が 30 dB を超える (%.1f)',
    [prev]));

  { 測れていない間は使わせない。 }
  sp := TSpectrumService.Create(4096, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp, 0.5, 8);
  try
    raised := False;
    try
      ne.SnrInBandDb(950, 1050);
    except
      on ENoiseEstimatorError do raised := True;
    end;
    Check(raised, '**まだ測れていないうちは S/N を答えない** (例外にする)');
    Check(not ne.Ready, '測れていないことが外から分かる');
  finally
    ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 取りこぼしと流し直し
  -------------------------------------------------------------------------- }
procedure TestResetDiscardsHistory; forward;

procedure TestMissedAndReset;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rnd: TVectorRandom;
  buf: TDArr;
  info: TNoiseUpdateInfo;
  i, n: Integer;
  missed: Int64;
  sawReset: Boolean;
begin
  WriteLn;
  WriteLn('--- 4. 取りこぼしと流し直しを黙って飲まない ---');
  { 枠の置き場より多く作ってから読むと、取りこぼす。 }
  sp := TSpectrumService.Create(1024, SR, HOP, swHann, 4);
  ne := TNoiseEstimator.Create(sp, 0.5, 8);
  try
    rnd.Seed(1);
    SetLength(buf, HOP);
    for n := 1 to 12 do
    begin
      for i := 0 to HOP - 1 do buf[i] := 0.3 * rnd.NextGauss;
      sp.Feed(buf, HOP);
    end;
    ne.Update(info);
    WriteLn('        ', info.Describe);
    Check(info.MissedFrames > 0,
      Format('**取りこぼした枠数を申告する** (%d 枠)', [info.MissedFrames]));
    missed := info.MissedFrames;
    Check(info.Frames > 0, '取りこぼしたあとも読み進む');

    { 流し直し。 }
    sp.Reset;
    for n := 1 to 6 do
    begin
      for i := 0 to HOP - 1 do buf[i] := 0.3 * rnd.NextGauss;
      sp.Feed(buf, HOP);
    end;
    ne.Update(info);
    WriteLn('        ', info.Describe);
    sawReset := info.WasReset;
    Check(sawReset, '**流し直しを申告する**');
    Check(missed > 0, '前提: 取りこぼしが起きていた');
  finally
    ne.Free; sp.Free;
  end;

  { --- 申告するだけでなく、溜めた推定を**捨てている**こと ---
    申告だけを見ていると、中で前の流れの雑音床を持ち越していても通る。
    実際、捨てる 5 行を消しても試験は 1 件も落ちなかった。

    見分けるには、流し直しの前後で**雑音の大きさを変える**。持ち越せば
    古い大きさに引きずられ、捨てていれば新しい大きさにすぐ載る。 }
  TestResetDiscardsHistory;
end;

procedure TestResetDiscardsHistory;
const
  LOUD = 1.0;
  QUIET = 0.1;
  SETTLE = 60;
  AFTER = 10;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rnd: TVectorRandom;
  buf: TDArr;
  info: TNoiseUpdateInfo;
  i, n: Integer;
  framesBefore, framesAfter: Int64;
  dLoud, dAfter, theoryQuiet, theoryLoud: Double;
begin
  WriteLn;
  WriteLn('--- 4b. 流し直しで溜めた推定を捨てる ---');
  theoryLoud := 2 * LOUD * LOUD / SR;
  theoryQuiet := 2 * QUIET * QUIET / SR;

  sp := TSpectrumService.Create(1024, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp, 0.5, 8);
  try
    rnd.Seed(11);
    SetLength(buf, HOP);

    { 大きい雑音で落ち着かせる。 }
    for n := 1 to SETTLE do
    begin
      for i := 0 to HOP - 1 do buf[i] := LOUD * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
    end;
    dLoud := ne.NoiseDensity;
    framesBefore := ne.FramesUsed;

    { 流し直して、**20 dB 静かな**雑音を少しだけ流す。 }
    sp.Reset;
    for n := 1 to AFTER do
    begin
      for i := 0 to HOP - 1 do buf[i] := QUIET * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
    end;
    dAfter := ne.NoiseDensity;
    framesAfter := ne.FramesUsed;

    WriteLn(Format('        流し直し前 %.4g (理論 %.4g) / 枠 %d',
      [dLoud, theoryLoud, framesBefore]));
    WriteLn(Format('        流し直し後 %.4g (理論 %.4g) / 枠 %d',
      [dAfter, theoryQuiet, framesAfter]));

    Check(framesBefore > SETTLE div 2, '前提: 前の流れで十分溜めていた');
    Check(framesAfter < framesBefore,
      Format('**流し直しで枠の数え直しが起きる** (%d -> %d)',
        [framesBefore, framesAfter]));
    { 持ち越せば、10 枠では古い大きさから下りきらない。
      捨てていれば新しい大きさの近くに居る。100 倍の差なので、
      「新しい理論値の 3 倍以内」で十分に分かれる。 }
    Check(dAfter < theoryQuiet * 3,
      Format('**流し直しのあとは新しい流れの雑音床になる** ' +
        '(%.4g / 新しい理論 %.4g / 古い理論 %.4g)',
        [dAfter, theoryQuiet, theoryLoud]));
  finally
    ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. ならし
  -------------------------------------------------------------------------- }
procedure TestSmoothing;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rnd: TVectorRandom;
  buf: TDArr;
  info: TNoiseUpdateInfo;
  i, n, cnt: Integer;
  rawMin, rawMax, smMin, smMax: Double;
begin
  WriteLn;
  WriteLn('--- 5. ならしが 1 枠の揺らぎを潰す ---');
  sp := TSpectrumService.Create(1024, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp, 0.5, 16);
  try
    rnd.Seed(7);
    SetLength(buf, HOP);
    rawMin := 1E30; rawMax := 0; smMin := 1E30; smMax := 0; cnt := 0;
    for n := 1 to 200 do
    begin
      for i := 0 to HOP - 1 do buf[i] := 0.3 * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
      { 立ち上がりを避けて、落ち着いてから測る。 }
      if n > 60 then
      begin
        if ne.RawDensity < rawMin then rawMin := ne.RawDensity;
        if ne.RawDensity > rawMax then rawMax := ne.RawDensity;
        if ne.NoiseDensity < smMin then smMin := ne.NoiseDensity;
        if ne.NoiseDensity > smMax then smMax := ne.NoiseDensity;
        Inc(cnt);
      end;
    end;
    WriteLn(Format('        ならす前 %.4g..%.4g (幅 %.1f%%) / ならした後 %.4g..%.4g (幅 %.1f%%)',
      [rawMin, rawMax, 100 * (rawMax - rawMin) / rawMin,
       smMin, smMax, 100 * (smMax - smMin) / smMin]));
    Check(cnt > 0, '前提: 落ち着いたあとの値を集められた');
    Check((smMax - smMin) / smMin < (rawMax - rawMin) / rawMin / 2,
      '**ならすと揺らぎが半分以下になる**');
  finally
    ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 分位点の指定
  -------------------------------------------------------------------------- }
procedure TestPercentileGuards;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  bad: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 分位点の指定 ---');
  sp := TSpectrumService.Create(1024, SR, HOP, swHann);
  try
    bad := 0;
    try
      ne := TNoiseEstimator.Create(sp, 0.0, 8);
      ne.Free;
    except
      on ENoiseEstimatorError do Inc(bad);
    end;
    try
      ne := TNoiseEstimator.Create(sp, 1.0, 8);
      ne.Free;
    except
      on ENoiseEstimatorError do Inc(bad);
    end;
    CheckEqI(bad, 2, '0 と 1 は分位点として受け付けない');

    ne := TNoiseEstimator.Create(sp, 0.5, 8);
    try
      Check(Abs(ne.Correction - Ln(2)) < 1E-12, '中央値の係数が ln2');
      ne.Percentile := 0.75;
      Check(Abs(ne.Correction - (-Ln(0.25))) < 1E-12,
        '分位点を変えると係数も変わる');
      CheckEqI(ne.LowBin, 1, '直流の bin は雑音の標本に入れない');
      CheckEqI(ne.HighBin, sp.BinCount - 2,
        'ナイキストの bin も入れない (片側しか折り返さず電力が半分)');
    finally
      ne.Free;
    end;
  finally
    sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 確保しない / 決定性
  -------------------------------------------------------------------------- }
var
  GOldMM: TMemoryManager;
  GNewMM: TMemoryManager;
  GAllocCount: Integer = 0;
  GCounting: Boolean = False;

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

procedure TestNoAllocationAndDeterminism;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rnd: TVectorRandom;
  buf: TDArr;
  info: TNoiseUpdateInfo;
  i, n, alloc: Integer;
  d1, d2, md: Double;
  f1, f2: Int64;
begin
  WriteLn;
  WriteLn('--- 7. 確保しない (X-04) / 同じ音から同じ結果 (Z-05) ---');
  sp := TSpectrumService.Create(4096, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp, 0.5, 8);
  try
    rnd.Seed(3);
    SetLength(buf, HOP);
    for i := 0 to HOP - 1 do buf[i] := 0.3 * rnd.NextGauss;
    sp.Feed(buf, HOP);
    ne.Update(info);     { 初回ぶんを済ませる }

    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for n := 1 to 100 do
      begin
        for i := 0 to HOP - 1 do buf[i] := 0.3 * rnd.NextGauss;
        sp.Feed(buf, HOP);
        ne.Update(info);
      end;
      alloc := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(alloc, 0,
      Format('100 枠の取り込みで確保 0 回 (実測 %d)', [alloc]));
  finally
    ne.Free; sp.Free;
  end;

  RunNoise(4096, swHann, 0.5, 0.3, 2, d1, md, f1);
  RunNoise(4096, swHann, 0.5, 0.3, 2, d2, md, f2);
  Check((d1 = d2) and (f1 = f2), '**同じ音から同じ雑音床** (Z-05)');
end;

begin
  WriteLn('=== 雑音床の共有サービスの試験 (SPC-002) ===');

  TestCalibration;
  TestRobustToSignals;
  TestBandSnr;
  TestMissedAndReset;
  TestSmoothing;
  TestPercentileGuards;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('SPC-002');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
