{ ============================================================================
  test_mfsk_tones.lpr

  MFSK の音の層 (units/MfskTones.pas と ModemDSP.TSlidingDft) の試験。

  何を守るか
  ----------------------------------------------------------------------------
  1. 諸元が fldigi の値と一致する (baud / 間隔 / 帯域 / 中心)
  2. 滑る DFT が直接 DFT と一致する
  3. **送ったトーンがそのトーンとして検出される**
  4. **軟判定がシンボル値を表す** (硬判定に潰すと元のシンボルになる)
  5. **隣のトーンと取り違えてもビット誤りは 1 本** (Gray の効果)
  6. 雑音に対する強さを数字で残す
  7. 取り込みで確保しない (X-04) / 同じ音から同じ結果 (Z-05)

  **シンボル同期の追尾はここでは切ってある。** ここは「区切りが合って
  いる前提でトーンをどれだけ正しく測れるか」だけを見る。追尾は
  test_mfsk_sync (MDM-013) が見る。

  3 と 4 が核心である。5 は Gray を挟む理由そのもので、音の層で効くことを
  ここで確かめる (表の上では test_mfsk_varicode が確かめている)。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_mfsk_tones;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, MfskTones, TestVectors, TestSupport, Requirements;

type
  TSoftArray = array of Byte;
  TToneArray = array of Integer;

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

{ --- 送信側 ---
  シンボル値の並びを MFSK16 の音にする。位相はシンボル間で続ける
  (切れると帯域が広がり、隣のトーンへ漏れる)。 }
function Modulate(const AMode: TMfskMode; const ASymbols: array of Integer;
  ANoiseRms: Double = 0; ASeed: QWord = 1; AOffsetHz: Double = 0): TDoubleArray;
var
  i, k, tone, n: Integer;
  f, phase, step: Double;
  rnd: TVectorRandom;
begin
  rnd.Seed(ASeed);
  n := Length(ASymbols) * AMode.SymLen;
  SetLength(Result, n);
  phase := 0;
  k := 0;
  for i := 0 to High(ASymbols) do
  begin
    tone := MfskSymbolToTone(ASymbols[i]);
    f := AMode.BaseFreqHz + tone * AMode.ToneSpacingHz + AOffsetHz;
    step := 2 * Pi * f / AMode.SampleRate;
    while k < (i + 1) * AMode.SymLen do
    begin
      Result[k] := Cos(phase);
      if ANoiseRms > 0 then
        Result[k] := Result[k] + ANoiseRms * rnd.NextGauss;
      phase := phase + step;
      if phase > 2 * Pi then phase := phase - 2 * Pi;
      Inc(k);
    end;
  end;
end;

{ 音を通して、検出されたトーン番号の並びを返す。 }
function Demodulate(const AMode: TMfskMode; const AWave: TDoubleArray;
  out ASoft: TSoftArray; ACentreHz: Double = 0): TToneArray;
var
  det: TMfskToneDetector;
  i, k, n: Integer;
begin
  det := TMfskToneDetector.Create(AMode, ACentreHz);
  try
    { **追尾は切る。** ここで見ているのは音の層だけ (MDM-012) で、
      区切りは SymLen ごとに固定してある前提の数字である。追尾を
      入れたままにすると、切り出し数が 1 つ増減して期待値が揺れるし、
      雑音耐性の実測も「トーン検出の強さ」ではなくなる。
      追尾そのものは test_mfsk_sync (MDM-013) が見ている。 }
    det.SyncTracking := False;
    SetLength(Result, 0);
    SetLength(ASoft, 0);
    n := 0;
    for i := 0 to High(AWave) do
      if det.Feed(AWave[i]) then
      begin
        SetLength(Result, n + 1);
        Result[n] := det.Symbol;
        SetLength(ASoft, (n + 1) * AMode.SymBits);
        for k := 0 to AMode.SymBits - 1 do
          ASoft[n * AMode.SymBits + k] := det.SoftBit(k);
        Inc(n);
      end;
  finally
    det.Free;
  end;
end;

{ 軟判定を硬判定に潰して、シンボル値に戻す。 }
function SoftToSymbol(const ASoft: TSoftArray; AIndex, ABits: Integer): Integer;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to ABits - 1 do
    if ASoft[AIndex * ABits + k] >= 128 then
      Result := Result or (1 shl (ABits - k - 1));
end;

function PopCount(AValue: Integer): Integer;
var
  v: Integer;
begin
  Result := 0;
  v := AValue;
  while v <> 0 do
  begin
    Inc(Result, v and 1);
    v := v shr 1;
  end;
end;

{ --------------------------------------------------------------------------
  1. 諸元
  -------------------------------------------------------------------------- }
var
  GBadMode: TMfskMode;

procedure MakeBadTones;
begin
  TMfskToneDetector.Create(GBadMode).Free;
end;

procedure TestModeParameters;
var
  m: TMfskMode;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. 諸元 ---');
  m := MFSK16_MODE;
  WriteLn('        ', m.Describe);
  Check(Abs(m.BaudRate - 15.625) < 1E-9,
    Format('シンボル速度 %.3f baud (8000/512)', [m.BaudRate]));
  Check(Abs(m.ToneSpacingHz - 15.625) < 1E-9,
    'トーン間隔はシンボル速度と同じ 15.625 Hz');
  Check(Abs(m.BaseFreqHz - 1000.0) < 1E-9,
    Format('最低トーンは %.1f Hz (bin 64)', [m.BaseFreqHz]));
  Check(Abs(m.BandwidthHz - 234.375) < 1E-9,
    Format('占有幅 %.3f Hz ((16-1) x 15.625)', [m.BandwidthHz]));
  Check(Abs(m.CentreFreqHz - 1117.1875) < 1E-9,
    Format('中心 %.4f Hz', [m.CentreFreqHz]));
  CheckEqI(m.NumTones, 1 shl m.SymBits, 'トーン数は 2^SymBits');

  { 諸元が矛盾していたら作らせない。 }
  GBadMode := MFSK16_MODE;
  GBadMode.NumTones := 15;          { 2^4 と合わない }
  Inc(TestCount);
  raised := False;
  try MakeBadTones; except on E: EMfskError do raised := True; end;
  if raised then WriteLn('  [OK] **トーン数が 2^SymBits と合わないモードを断る**')
  else begin WriteLn('  [NG] トーン数の矛盾を断る'); Inc(FailCount); end;

  GBadMode := MFSK16_MODE;
  GBadMode.BaseTone := 500;         { シンボル長の DFT に収まらない }
  Inc(TestCount);
  raised := False;
  try MakeBadTones; except on E: EMfskError do raised := True; end;
  if raised then WriteLn('  [OK] **DFT に収まらないトーン配置を断る**')
  else begin WriteLn('  [NG] トーン配置の矛盾を断る'); Inc(FailCount); end;
end;

{ --------------------------------------------------------------------------
  2. 滑る DFT が直接 DFT と一致すること

  ここが狂うと上の層すべてが狂う。漸化式の実装は目で見ても正しさが
  分からないので、素朴な DFT と突き合わせる。
  -------------------------------------------------------------------------- }
procedure TestSlidingDftMatchesDirect;
const
  N = 256; FIRST = 32; NB = 16; SR = 8000;
var
  d: TSlidingDft;
  bins: TComplexArray;
  hist: array of TComplex;
  i, k, idx: Integer;
  z, acc: TComplex;
  ph, err, worst, peak: Double;
  peakBin: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 滑る DFT ---');
  d := TSlidingDft.Create(N, FIRST, NB);
  try
    SetLength(bins, NB);
    SetLength(hist, N);
    { bin 40 ちょうどの複素正弦波。 }
    for i := 0 to 4 * N - 1 do
    begin
      ph := 2 * Pi * 40 * i / N;
      z := CplxMake(0.5 * Cos(ph), 0.5 * Sin(ph));
      hist[i mod N] := z;
      d.Run(z, bins);
    end;

    peak := -1; peakBin := -1;
    for k := 0 to NB - 1 do
      if CplxAbs(bins[k]) > peak then
      begin
        peak := CplxAbs(bins[k]);
        peakBin := FIRST + k;
      end;
    WriteLn(Format('        山は bin %d / 期待 40 (値 %.3f / 理論 %.3f)',
      [peakBin, peak, 0.5 * N]));
    CheckEqI(peakBin, 40, '**既知の周波数が正しい bin に立つ**');
    Check(Abs(peak - 0.5 * N) < 0.01,
      '山の大きさが振幅 x 窓長に一致する');

    { 素朴な DFT と突き合わせる。 }
    worst := 0;
    for k := 0 to NB - 1 do
    begin
      acc := CplxMake(0, 0);
      for i := 0 to N - 1 do
      begin
        idx := (4 * N - N + i) mod N;
        ph := -2 * Pi * (FIRST + k) * i / N;
        acc.Re := acc.Re + hist[idx].Re * Cos(ph) - hist[idx].Im * Sin(ph);
        acc.Im := acc.Im + hist[idx].Re * Sin(ph) + hist[idx].Im * Cos(ph);
      end;
      err := Abs(CplxAbs(acc) - CplxAbs(bins[k]));
      if err > worst then worst := err;
    end;
    WriteLn(Format('        直接 DFT との最大差 %.3g (山の値 %.1f)', [worst, peak]));
    Check(worst < 1E-4,
      '**漸化式が素朴な DFT と一致する** (減衰ぶんの差しかない)');
  finally
    d.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3-4. 送ったトーンが検出され、軟判定がシンボル値を表すこと
  -------------------------------------------------------------------------- }
procedure TestToneAndSoftBits;
var
  m: TMfskMode;
  syms: array of Integer;
  wave: TDoubleArray;
  got: TToneArray;
  soft: TSoftArray;
  i, badTone, badSoft, want: Integer;
  minMargin: Integer;
  v: Integer;
begin
  WriteLn;
  WriteLn('--- 3-4. 送ったトーンと軟判定 ---');
  m := MFSK16_MODE;
  { 全 16 シンボルを順に送る。 }
  SetLength(syms, m.NumTones);
  for i := 0 to m.NumTones - 1 do syms[i] := i;

  wave := Modulate(m, syms);
  got := Demodulate(m, wave, soft);
  CheckEqI(Length(got), m.NumTones, '16 シンボルぶん切り出せた');

  badTone := 0; badSoft := 0; minMargin := 255;
  for i := 0 to High(got) do
  begin
    { 送ったシンボル値 i に対応するトーンは MfskSymbolToTone(i)。 }
    want := MfskSymbolToTone(syms[i]);
    if got[i] <> want then Inc(badTone);
    { 軟判定を硬判定に潰すと、元のシンボル値に戻るはず。 }
    if SoftToSymbol(soft, i, m.SymBits) <> syms[i] then Inc(badSoft);
    { 判定の余裕。128 からどれだけ離れているか。 }
    for v := 0 to m.SymBits - 1 do
      if Abs(Integer(soft[i * m.SymBits + v]) - 128) < minMargin then
        minMargin := Abs(Integer(soft[i * m.SymBits + v]) - 128);
  end;
  CheckEqI(badTone, 0, '**送ったトーンがそのトーンとして検出される** (16/16)');
  CheckEqI(badSoft, 0, '**軟判定を潰すと元のシンボル値に戻る** (16/16)');
  WriteLn(Format('        軟判定の余裕は最小でも 128±%d', [minMargin]));
  Check(minMargin > 40, '軟判定に十分な余裕がある (雑音に耐えられる)');

  { Gray の往復。 }
  badTone := 0;
  for i := 0 to m.NumTones - 1 do
    if MfskToneToSymbol(MfskSymbolToTone(i)) <> i then Inc(badTone);
  CheckEqI(badTone, 0, 'シンボル値 -> トーン -> シンボル値 が戻る');
end;

{ --------------------------------------------------------------------------
  5. 隣のトーンと取り違えてもビット誤りが 1 本で済むこと

  Gray を挟む理由そのもの。音の層で効くことをここで見る。
  -------------------------------------------------------------------------- }
procedure TestAdjacentToneCostsOneBit;
var
  m: TMfskMode;
  tone, worstGray, worstPlain, d: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 隣のトーンとの取り違え ---');
  m := MFSK16_MODE;
  worstGray := 0;
  for tone := 0 to m.NumTones - 2 do
  begin
    d := PopCount(MfskToneToSymbol(tone) xor MfskToneToSymbol(tone + 1));
    if d > worstGray then worstGray := d;
  end;
  { Gray を挟まずトーン番号をそのままシンボル値にした場合。 }
  worstPlain := 0;
  for tone := 0 to m.NumTones - 2 do
  begin
    d := PopCount(tone xor (tone + 1));
    if d > worstPlain then worstPlain := d;
  end;
  WriteLn(Format('        隣のトーンとのビット差: Gray %d bit / 素の番号 %d bit',
    [worstGray, worstPlain]));
  CheckEqI(worstGray, 1,
    '**隣のトーンと取り違えてもビット誤りは 1 本**');
  Check(worstPlain > 1, '前提: Gray を挟まないと 1 本では済まない');
end;

{ --------------------------------------------------------------------------
  5b. 別の周波数に合わせても復調できること (ミキサが効いていること)

  既定では合わせる中心 = モードの公称中心なので、ミキサのずらし量が 0 に
  なる。**その設定だけで試験していると、ミキサを殺す改竄が素通りする**
  (実際に素通りした)。運用では相手の周波数に合わせるのだから、
  ずらしが効くことを確かめなければならない。
  -------------------------------------------------------------------------- }
procedure TestTunedToOtherFrequency;
const
  OFFSETS: array[0..3] of Double = (0, 200, -100, 500);
var
  m: TMfskMode;
  syms: array of Integer;
  wave: TDoubleArray;
  got: TToneArray;
  soft: TSoftArray;
  i, k, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 5b. 別の周波数に合わせる ---');
  m := MFSK16_MODE;
  SetLength(syms, m.NumTones);
  for i := 0 to m.NumTones - 1 do syms[i] := i;

  for k := 0 to High(OFFSETS) do
  begin
    { 信号を OFFSETS[k] だけずらして送り、受信側もそこへ合わせる。 }
    wave := Modulate(m, syms, 0, 1, OFFSETS[k]);
    got := Demodulate(m, wave, soft, m.CentreFreqHz + OFFSETS[k]);
    bad := 0;
    for i := 0 to High(got) do
      if got[i] <> MfskSymbolToTone(syms[i]) then Inc(bad);
    WriteLn(Format('        中心 %.1f Hz (ずらし %.0f Hz): 誤り %d / %d',
      [m.CentreFreqHz + OFFSETS[k], OFFSETS[k], bad, Length(got)]));
    Check(bad = 0,
      Format('**%.0f Hz ずらしても全シンボルを復調できる**', [OFFSETS[k]]));
  end;

  { 合わせ損なうと復調できないこと ―― ミキサが「効いている」ことの裏。 }
  wave := Modulate(m, syms, 0, 1, 500);
  got := Demodulate(m, wave, soft, m.CentreFreqHz);   { ずらしを教えない }
  bad := 0;
  for i := 0 to High(got) do
    if got[i] <> MfskSymbolToTone(syms[i]) then Inc(bad);
  WriteLn(Format('        500 Hz ずれたまま合わせない: 誤り %d / %d',
    [bad, Length(got)]));
  Check(bad > Length(got) div 2,
    '前提: 合わせ損なえば復調できない (だからミキサが要る)');
end;

{ --------------------------------------------------------------------------
  6. 雑音に対する強さを数字で残す
  -------------------------------------------------------------------------- }
procedure TestNoiseTolerance;
const
  NSYM = 200;
var
  m: TMfskMode;
  syms: array of Integer;
  wave: TDoubleArray;
  got: TToneArray;
  soft: TSoftArray;
  rnd: TVectorRandom;
  i, k, errs, cleanErrs: Integer;
  noise: Double;
  rate, snr, cliffSnr: Double;
  found: Boolean;
begin
  WriteLn;
  WriteLn('--- 6. 雑音に対する強さ ---');
  m := MFSK16_MODE;
  rnd.Seed(20260912);
  SetLength(syms, NSYM);
  for i := 0 to NSYM - 1 do syms[i] := Integer(rnd.NextU64 mod QWord(m.NumTones));

  wave := Modulate(m, syms);
  got := Demodulate(m, wave, soft);
  cleanErrs := 0;
  for i := 0 to High(got) do
    if got[i] <> MfskSymbolToTone(syms[i]) then Inc(cleanErrs);
  CheckEqI(cleanErrs, 0, '前提: 雑音なしならシンボル誤り 0');

  { MFSK は **狭い bin に長く積む** ので雑音に強い。512 サンプルの積分で
    約 27 dB の処理利得が付くため、広帯域で信号と同じ大きさの雑音
    (S/N 0 dB) を入れてもまだ誤らない。崖を見るにはそれよりずっと
    強い雑音まで振る必要がある。

    最初 rms 1.0 までしか振らずに「誤り率 1% を超える点」を探していたが、
    その範囲では 1 件も誤らず、探していた点が見つからないまま落ちた ――
    **試験が易しすぎた**。 }
  WriteLn('        雑音 rms   広帯域 S/N   シンボル誤り率');
  found := False;
  cliffSnr := 0;
  for k := 0 to 11 do
  begin
    noise := 0.5 * k;
    wave := Modulate(m, syms, noise, 555 + QWord(k));
    got := Demodulate(m, wave, soft);
    errs := 0;
    for i := 0 to High(got) do
      if got[i] <> MfskSymbolToTone(syms[i]) then Inc(errs);
    rate := errs / Length(got);
    if noise > 0 then snr := 10 * Log10(0.5 / (noise * noise)) else snr := 99;
    if noise = 0 then
      WriteLn(Format('        %6.2f       (無雑音)    %.3f  (%d / %d)',
        [noise, rate, errs, Length(got)]))
    else
      WriteLn(Format('        %6.2f     %6.1f dB    %.3f  (%d / %d)',
        [noise, snr, rate, errs, Length(got)]));
    { 「まだ見つかっていない」の印に負の値を使ってはいけない。
      探している量 (S/N) 自体が負なので、一度入れても条件が真のままになり、
      **最後の値で上書きされ続ける**。最初にそう書いて、崖として
      -17.8 dB (掃引の末端) が出ていた。真偽の旗で持つ。 }
    if (rate > 0.01) and (not found) then
    begin
      found := True;
      cliffSnr := snr;
    end;
  end;
  if not found then
    WriteLn('        この範囲では誤り率 1% を超えなかった')
  else
    WriteLn(Format('        誤り率 1%% を初めて超えた広帯域 S/N: %.1f dB',
      [cliffSnr]));
  Check(found and (cliffSnr < -10.0),
    Format('**広帯域 S/N -10 dB まではシンボル誤り 1%% 以下** (崖は %.1f dB)',
      [cliffSnr]));
end;

{ --------------------------------------------------------------------------
  7. 確保しない (X-04) / 同じ音から同じ結果 (Z-05)
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

procedure TestNoAllocationAndDeterminism;
var
  m: TMfskMode;
  det: TMfskToneDetector;
  mm: TMemoryManager;
  syms: array of Integer;
  wave: TDoubleArray;
  g1, g2: TToneArray;
  s1, s2: TSoftArray;
  i, n: Integer;
  same: Boolean;
begin
  WriteLn;
  WriteLn('--- 7. 確保しない (X-04) / 同じ音から同じ結果 (Z-05) ---');
  m := MFSK16_MODE;
  SetLength(syms, 20);
  for i := 0 to 19 do syms[i] := i mod m.NumTones;
  wave := Modulate(m, syms, 0.05, 99);

  det := TMfskToneDetector.Create(m);
  det.SyncTracking := False;
  try
    for i := 0 to 2 * m.SymLen - 1 do det.Feed(wave[i]);   { 初回を済ませる }

    GAllocCount := 0;
    GetMemoryManager(GOldMM);
    mm := GOldMM;
    mm.GetMem := @CountingGetMem;
    mm.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(mm);
    GCounting := True;
    try
      for i := 0 to High(wave) do det.Feed(wave[i]);
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0, Format('%d サンプル投入で確保 0 回 (実測 %d)',
      [Length(wave), n]));
  finally
    det.Free;
  end;

  g1 := Demodulate(m, wave, s1);
  g2 := Demodulate(m, wave, s2);
  same := Length(g1) = Length(g2);
  if same then
    for i := 0 to High(g1) do
      if g1[i] <> g2[i] then same := False;
  if same then
    for i := 0 to High(s1) do
      if s1[i] <> s2[i] then same := False;
  Check(same, '**同じ音から同じトーンと同じ軟判定** (Z-05)');
end;

begin
  WriteLn('=== MFSK の音の層 (トーン検出と軟判定) の試験 ===');

  TestModeParameters;
  TestSlidingDftMatchesDirect;
  TestToneAndSoftBits;
  TestAdjacentToneCostsOneBit;
  TestTunedToOtherFrequency;
  TestNoiseTolerance;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('MDM-012');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
