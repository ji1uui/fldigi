{ ============================================================================
  test_fftfilt.lpr

  ModemDSP.pas に新規追加した ComplexFFT/InverseComplexFFT (fldigi の
  g_fft<double> 相当) と TFftFilt (fldigi の fftfilt = Overlap-Add FFT
  畳み込みフィルタ相当) の単体検証。RTTY/CW モデムへの組み込み前に、
  FFTエンジン自体の正しさ (既知の変換対・往復一致・スケーリング) と、
  フィルタとしての実際の減衰特性 (通過域/阻止域) を実データで確認する。

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_fftfilt test/test_fftfilt.lpr
    ./test/test_fftfilt
  ============================================================================ }
program test_fftfilt;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, ModemDSP;

{ X-04 の確認に使う。確保の回数を数えるためにメモリマネージャを差し替える。 }
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

{ ------------------------------------------------------------------------
  1. FFT往復一致 (ComplexFFT -> InverseComplexFFT が恒等変換になること)
  ------------------------------------------------------------------------ }
procedure TestRoundTrip;
const
  N = 64;
var
  orig, buf: TComplexArray;
  i: Integer;
  maxErr, err: Double;
begin
  WriteLn;
  WriteLn('--- 1. FFT往復一致 (N=', N, ') ---');

  SetLength(orig, N);
  SetLength(buf, N);
  for i := 0 to N - 1 do
  begin
    orig[i] := CplxMake(Sin(0.3 * i) + 0.5 * Cos(0.9 * i), Cos(0.2 * i) - 0.1 * i);
    buf[i] := orig[i];
  end;

  ComplexFFT(buf);
  InverseComplexFFT(buf);

  maxErr := 0;
  for i := 0 to N - 1 do
  begin
    err := Abs(buf[i].Re - orig[i].Re) + Abs(buf[i].Im - orig[i].Im);
    if err > maxErr then maxErr := err;
  end;
  WriteLn('  最大誤差 = ', maxErr:0:10);
  Check(maxErr < 1e-9, 'ComplexFFT->InverseComplexFFT が元信号を誤差1e-9未満で再現する');
end;

{ ------------------------------------------------------------------------
  2. 既知の変換対 (インパルス応答・直流成分)
  ------------------------------------------------------------------------ }
procedure TestKnownTransforms;
const
  N = 8;
var
  buf: TComplexArray;
  i: Integer;
  allOnes, dcOnly: Boolean;
begin
  WriteLn;
  WriteLn('--- 2. 既知の変換対 (N=', N, ') ---');

  { インパルス delta[0] -> 全て1 (スケーリングなしのΣ規約) }
  SetLength(buf, N);
  for i := 0 to N - 1 do buf[i] := CplxMake(0, 0);
  buf[0] := CplxMake(1, 0);
  ComplexFFT(buf);
  allOnes := True;
  for i := 0 to N - 1 do
    if (Abs(buf[i].Re - 1.0) > 1e-9) or (Abs(buf[i].Im) > 1e-9) then
      allOnes := False;
  Check(allOnes, 'delta[0]のFFTは全ビン1+0iになる (Σ規約、無スケーリング)');

  { 直流信号 [1,1,...,1] -> ビン0=N、他は0 }
  for i := 0 to N - 1 do buf[i] := CplxMake(1, 0);
  ComplexFFT(buf);
  dcOnly := (Abs(buf[0].Re - N) < 1e-9) and (Abs(buf[0].Im) < 1e-9);
  for i := 1 to N - 1 do
    if (Abs(buf[i].Re) > 1e-9) or (Abs(buf[i].Im) > 1e-9) then
      dcOnly := False;
  Check(dcOnly, '直流信号[1,1,...,1]のFFTはビン0=N、他ビン=0になる');
end;

{ ------------------------------------------------------------------------
  3. 単一トーンのピークビン位置 (実信号の複素FFT)
  ------------------------------------------------------------------------ }
procedure TestTonePeak;
const
  N = 64;
  K = 5; // N周期中5サイクルのコサイン波
var
  buf: TComplexArray;
  i, peakIdx: Integer;
  peakMag, mag: Double;
begin
  WriteLn;
  WriteLn('--- 3. 単一トーン (', K, '/', N, 'サイクル) のピークビン検出 ---');

  SetLength(buf, N);
  for i := 0 to N - 1 do
    buf[i] := CplxMake(Cos(TWOPI * K * i / N), 0);
  ComplexFFT(buf);

  peakIdx := 0;
  peakMag := 0;
  for i := 0 to N div 2 do
  begin
    mag := CplxAbs(buf[i]);
    if mag > peakMag then
    begin
      peakMag := mag;
      peakIdx := i;
    end;
  end;
  WriteLn('  ピークビン = ', peakIdx, ' (振幅 ', peakMag:0:3, ')');
  Check(peakIdx = K, 'コサイン波 K=' + IntToStr(K) + ' サイクルのピークがビン' + IntToStr(K) + 'に現れる');
  Check(Abs(peakMag - N / 2) < 1e-6, 'ピーク振幅が理論値 N/2=' + FloatToStr(N/2) + ' と一致する (実際: ' + FloatToStr(peakMag) + ')');
end;

{ ------------------------------------------------------------------------
  4. TFftFilt: ローパスフィルタの実際の減衰特性
  ------------------------------------------------------------------------ }
procedure TestFftFiltLowpass;
const
  SAMPLE_RATE = 8000.0;
  FLEN = 256;
  CUTOFF_HZ = 200.0;   // 通過域
  LOW_HZ = 100.0;      // 通過域内のトーン (減衰されないはず)
  HIGH_HZ = 2000.0;    // 阻止域のトーン (大きく減衰されるはず)
  NSAMPLES = FLEN * 20;
var
  filt: TFftFilt;
  i, n, outIdx: Integer;
  phaseLow, phaseHigh: Double;
  sampleIn: TComplex;
  outBuf: TComplexArray;
  lowSumSq, highSumSq: Double;
  lowCount, highCount: Integer;
  lowRms, highRms, attenDb: Double;
begin
  WriteLn;
  WriteLn('--- 4. TFftFilt ローパスフィルタの減衰特性 (flen=', FLEN, ', cutoff=',
    CUTOFF_HZ:0:0, 'Hz) ---');

  { --- 通過域トーン (100Hz) を流して定常応答のRMSを測る --- }
  filt := TFftFilt.Create(FLEN);
  filt.CreateLpf(CUTOFF_HZ / SAMPLE_RATE);
  phaseLow := 0;
  lowSumSq := 0;
  lowCount := 0;
  outIdx := 0;
  for i := 0 to NSAMPLES - 1 do
  begin
    sampleIn := CplxMake(Cos(phaseLow), Sin(phaseLow));
    phaseLow := phaseLow + TWOPI * LOW_HZ / SAMPLE_RATE;
    n := filt.Run(sampleIn, outBuf);
    if n > 0 then
      { 前半 (立ち上がり過渡) は除外し、後半の定常状態だけ集計する }
      for outIdx := 0 to n - 1 do
        if i > NSAMPLES div 2 then
        begin
          lowSumSq := lowSumSq + Sqr(CplxAbs(outBuf[outIdx]));
          Inc(lowCount);
        end;
  end;
  filt.Free;

  { --- 阻止域トーン (2000Hz) --- }
  filt := TFftFilt.Create(FLEN);
  filt.CreateLpf(CUTOFF_HZ / SAMPLE_RATE);
  phaseHigh := 0;
  highSumSq := 0;
  highCount := 0;
  for i := 0 to NSAMPLES - 1 do
  begin
    sampleIn := CplxMake(Cos(phaseHigh), Sin(phaseHigh));
    phaseHigh := phaseHigh + TWOPI * HIGH_HZ / SAMPLE_RATE;
    n := filt.Run(sampleIn, outBuf);
    if n > 0 then
      for outIdx := 0 to n - 1 do
        if i > NSAMPLES div 2 then
        begin
          highSumSq := highSumSq + Sqr(CplxAbs(outBuf[outIdx]));
          Inc(highCount);
        end;
  end;
  filt.Free;

  lowRms := Sqrt(lowSumSq / lowCount);
  highRms := Sqrt(highSumSq / highCount);
  attenDb := 20 * Log10(lowRms / highRms);

  WriteLn('  通過域(', LOW_HZ:0:0, 'Hz) 定常RMS  = ', lowRms:0:4);
  WriteLn('  阻止域(', HIGH_HZ:0:0, 'Hz) 定常RMS  = ', highRms:0:4);
  WriteLn('  通過域/阻止域の減衰量 = ', attenDb:0:1, ' dB');

  Check(lowRms > 0.5, '通過域トーンはほぼ減衰なく通過する (RMS>0.5、入力振幅1.0)');
  Check(attenDb > 20.0, '阻止域トーンは通過域比で20dB以上減衰する (実際: ' + FloatToStr(attenDb) + 'dB)');
end;

{ ------------------------------------------------------------------------
  5. TFftFilt: Run() のブロック化動作 (0 or flen2 サンプル) の確認
  ------------------------------------------------------------------------ }
procedure TestFftFiltBlocking;
const
  FLEN = 64;
var
  filt: TFftFilt;
  i, n, zeroCount, blockCount: Integer;
  outBuf: TComplexArray;
begin
  WriteLn;
  WriteLn('--- 5. TFftFilt.Run() のブロック化動作確認 (flen=', FLEN, ') ---');

  filt := TFftFilt.Create(FLEN);
  try
    filt.CreateLpf(0.1);
    Check(filt.Flen = FLEN, 'Flen プロパティが指定通り');
    Check(filt.Flen2 = FLEN div 2, 'Flen2 プロパティが Flen/2');
    Check(filt.FlushSize = FLEN, '生成直後の FlushSize = Flen');

    zeroCount := 0;
    blockCount := 0;
    for i := 0 to FLEN * 4 - 1 do
    begin
      n := filt.Run(CplxMake(Random - 0.5, Random - 0.5), outBuf);
      if n = 0 then
        Inc(zeroCount)
      else
      begin
        Check(n = FLEN div 2, 'Run() が0以外を返す時は必ず Flen/2 個 (実際: ' + IntToStr(n) + ')');
        Inc(blockCount);
      end;
    end;
    Check(zeroCount + blockCount = FLEN * 4,
      '0を返した回数とブロックを返した回数の合計が投入サンプル数(反復回数)と一致する');
    Check(blockCount = 4 * 2, IntToStr(FLEN * 4) + 'サンプル投入で ' + IntToStr(4*2) +
      '回ブロック出力される (実際: ' + IntToStr(blockCount) + '回)');
  finally
    filt.Free;
  end;
end;

{ ==========================================================================
  TFirFilter (fldigi: C_FIR_filter) の検証

  PSK の受信経路が使う複素 FIR。畳み込みそのものを直接計算した値と
  突き合わせる。**基準側を別に書く**のが要点で、同じ実装を 2 回書いて
  比べても誤りは見つからない。
  ========================================================================== }
procedure TestFirConvolution;
const
  L = 8;      { 短い長さで直接計算と比べる }
  N = 40;
var
  coef: array[0..L] of Double;
  fir: TFirFilter;
  inp: array[0..N-1] of TComplex;
  i, k, idx, outCount, worstAt: Integer;
  o: TComplex;
  expI, expQ, err, worst: Double;
begin
  WriteLn;
  WriteLn('--- TFirFilter: 直接畳み込みとの一致 ---');
  for i := 0 to L do
    coef[i] := 1.0 + i;          { 対称でない係数。順序の誤りが出る }
  for i := 0 to N - 1 do
    inp[i] := CplxMake(i + 1, -(i + 1) * 2);

  fir := TFirFilter.Create(L, 1, coef, coef);
  try
    worst := 0; worstAt := -1; outCount := 0;
    for i := 0 to N - 1 do
    begin
      if fir.Run(inp[i], o) then
      begin
        Inc(outCount);
        { 基準: いま入れた標本を含めず、その手前 L 個を古い順に
          係数 [0..L-1] と掛ける (fldigi の C_FIR_filter と同じ)。
          範囲外は 0。 }
        expI := 0; expQ := 0;
        for k := 0 to L - 1 do
        begin
          idx := i - L + k;
          if idx >= 0 then
          begin
            expI := expI + inp[idx].Re * coef[k];
            expQ := expQ + inp[idx].Im * coef[k];
          end;
        end;
        err := Abs(o.Re - expI) + Abs(o.Im - expQ);
        if err > worst then begin worst := err; worstAt := i; end;
      end;
    end;
    WriteLn(Format('        出力 %d 回 / 最大誤差 %.3g (第 %d 標本)',
      [outCount, worst, worstAt]));
    Check(outCount = N, '間引き 1 なら毎回出力する');
    Check(worst < 1E-9,
      '**直接畳み込みと一致する** (係数の順序も含めて)');
  finally
    fir.Free;
  end;
end;

procedure TestFirDecimation;
const
  L = 4;
var
  coef: array[0..L] of Double;
  fir: TFirFilter;
  i, outCount: Integer;
  o: TComplex;
  gaps: string;
begin
  WriteLn;
  WriteLn('--- TFirFilter: 間引き ---');
  for i := 0 to L do coef[i] := 1.0;

  fir := TFirFilter.Create(L, 4, coef, coef);
  try
    outCount := 0;
    gaps := '';
    for i := 1 to 20 do
      if fir.Run(CplxMake(1, 0), o) then
      begin
        Inc(outCount);
        gaps := gaps + IntToStr(i) + ' ';
      end;
    WriteLn('        出力した回数目: ', gaps);
    Check(outCount = 5, '20 標本を間引き 4 で入れると 5 回出力する');
    Check(gaps = '4 8 12 16 20 ', '**4 標本ごとちょうどに出力する**');
  finally
    fir.Free;
  end;
end;

procedure TestFirReset;
const
  L = 6;
var
  coef: array[0..L] of Double;
  fir: TFirFilter;
  i: Integer;
  o, first, again: TComplex;
begin
  WriteLn;
  WriteLn('--- TFirFilter: Reset ---');
  for i := 0 to L do coef[i] := 1.0 + i * 0.5;
  fir := TFirFilter.Create(L, 1, coef, coef);
  try
    { 一度流して、Reset して同じものを流したら同じ出力になること。
      残っていると Replay の再現性が崩れる (README §29)。 }
    for i := 1 to 30 do
      fir.Run(CplxMake(i, i), o);
    first := o;

    fir.Reset;
    for i := 1 to 30 do
      fir.Run(CplxMake(i, i), o);
    again := o;

    Check((Abs(first.Re - again.Re) < 1E-12) and
          (Abs(first.Im - again.Im) < 1E-12),
      '**Reset のあと同じ入力で同じ出力になる** (前の音が残らない)');

    { Reset 直後は畳み込みの中身が 0 なので、最初の出力は 0 になる。 }
    fir.Reset;
    Check(fir.Run(CplxMake(1, 1), o), 'Reset 直後も出力は出る');
    Check((Abs(o.Re) < 1E-12) and (Abs(o.Im) < 1E-12),
      'Reset 直後の出力は 0 (緩衝が空)');
  finally
    fir.Free;
  end;
end;

procedure TestFirNoAllocation;
var
  coef: array[0..64] of Double;
  fir: TFirFilter;
  i, n: Integer;
  o: TComplex;
  mm: TMemoryManager;
begin
  WriteLn;
  WriteLn('--- TFirFilter: 確保しないこと (X-04) ---');
  WSincFilter(coef, 1.0 / 16.0, 64);
  fir := TFirFilter.Create(64, 1, coef, coef);
  try
    for i := 1 to 100 do fir.Run(CplxMake(1, 0), o);

    GAllocCount := 0;
    GetMemoryManager(GOldMM);
    mm := GOldMM;
    mm.GetMem := @CountingGetMem;
    mm.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(mm);
    GCounting := True;
    try
      for i := 1 to 20000 do
        fir.Run(CplxMake(Sin(i * 0.1), Cos(i * 0.1)), o);
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    Check(n = 0, Format('2 万回で確保 0 回 (実測 %d)', [n]));
  finally
    fir.Free;
  end;
end;

procedure TestWSincFilter;
var
  coef: array[0..64] of Double;
  i: Integer;
  sum, peak: Double;
  peakAt: Integer;
begin
  WriteLn;
  WriteLn('--- WSincFilter: 係数の性質 ---');
  WSincFilter(coef, 1.0 / 16.0, 64);
  sum := 0;
  peak := 0; peakAt := -1;
  for i := 0 to 64 do
  begin
    sum := sum + coef[i];
    if Abs(coef[i]) > peak then begin peak := Abs(coef[i]); peakAt := i; end;
  end;
  WriteLn(Format('        合計 %.6f / 最大 %.6f (第 %d 係数)', [sum, peak, peakAt]));
  { 正規化してあるので直流利得は 1。 }
  Check(Abs(sum - 1.0) < 1E-9, '**係数の合計が 1** (直流利得が 1 に正規化されている)');
  { 中央が最大 (窓つき sinc なので対称)。 }
  Check(peakAt = 32, '最大の係数が中央にある');
  { 対称性。ここが崩れると位相が線形でなくなる。 }
  sum := 0;
  for i := 0 to 32 do
    sum := sum + Abs(coef[i] - coef[64 - i]);
  Check(sum < 1E-12, '**係数が左右対称** (位相が線形になる条件)');
end;

begin
  Randomize;
  WriteLn('=== ComplexFFT/InverseComplexFFT (ModemDSP) / TFftFilt / TFirFilter 検証 ===');

  TestRoundTrip;
  TestKnownTransforms;
  TestTonePeak;
  TestFftFiltLowpass;
  TestFftFiltBlocking;
  TestFirConvolution;
  TestFirDecimation;
  TestFirReset;
  TestFirNoAllocation;
  TestWSincFilter;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
