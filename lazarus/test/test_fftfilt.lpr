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
end;

begin
  Randomize;
  WriteLn('=== ComplexFFT/InverseComplexFFT (ModemDSP) / TFftFilt 検証 ===');

  TestRoundTrip;
  TestKnownTransforms;
  TestTonePeak;
  TestFftFiltLowpass;
  TestFftFiltBlocking;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
