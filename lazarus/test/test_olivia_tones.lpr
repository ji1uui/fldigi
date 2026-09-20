{ ============================================================================
  test_olivia_tones.lpr

  Olivia / Contestia の**音の層**の試験 (units/OliviaTones.pas と
  ModemDSP.SplitTwoRealSpectra)。

  何を守るか
  ----------------------------------------------------------------------------
  1. 諸元が上流の式と一致する (シンボル長・トーンの置き場所・速度)
  2. 実数列 2 本を 1 回の FFT で分けたものが、2 回回したものと一致する
  3. 送信波形の包絡線が平らで、電力が占有帯域に収まる
  4. **送ったシンボルがそのシンボルとして戻る** (3 つの諸元で)
  5. 2 枚の spectrum が半シンボルずれている (次の層が選ぶ材料)
  6. 隣のトーンと取り違えてもビット誤りは 1 本 (Gray)
  7. **軟判定が符号の層にそのまま噛み合う** (向きとビットの並び)
      および、符号の層まで通した文字誤りで軟判定の質を測る
  8. 周波数のずれを FreqOffset で補える
  9. 雑音に対する強さを数字で残す
  10. 確保しない (X-04) / 同じ入力から同じ音・同じ結果 (Z-05)

  7 が地味だが効く。層の間ではビットの並び (最上位が先か最下位が先か) と
  軟判定の符号 (正が 0 か 1 か) が食い違いやすく、**どちらも往復試験では
  見えない**。実際に符号の層へ通して文字が戻ることで初めて固定できる。

  ここは**モードとしての成立 (OLV-002) ではない**。ブロックの頭出しは
  次の層で、この試験は区切りを知っている前提で噛み合いだけを見ている。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_olivia_tones;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, OliviaBlock, OliviaTones, TestVectors, Requirements;

type
  TDArr = array of Double;
  TIArr = array of Integer;

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

{ --------------------------------------------------------------------------
  送信と受信の足回り

  この層は 1 回の Process が 2 枚の spectrum を出す。区切りに合っているのは
  片方だけで、どちらかは次の層が選ぶ。試験では実測した組 (slice 1 /
  1 区画の遅れ) を使う ―― その組が正しいことは試験 5 で別に確かめる。
  -------------------------------------------------------------------------- }
const
  ALIGNED_SLICE = 1;
  ALIGNED_DELAY = 1;

function Modulate(const AMode: TOliviaToneMode; const ASyms: TIArr;
  ACentreHz: Double; ANoiseRms: Double = 0; ASeed: QWord = 1): TDArr;
var
  mo: TOliviaModulator;
  buf: TDArr;
  rnd: TVectorRandom;
  i, k, n: Integer;
begin
  rnd.Seed(ASeed);
  mo := TOliviaModulator.Create(AMode, ACentreHz);
  try
    n := Length(ASyms);
    SetLength(buf, AMode.SymbolSepar);
    { 本文 + 押し出し 1 区画 + 無音 1 区画。 }
    SetLength(Result, (n + 2) * AMode.SymbolSepar);
    for i := 0 to n - 1 do
    begin
      mo.Send(ASyms[i], buf);
      for k := 0 to AMode.SymbolSepar - 1 do
        Result[i * AMode.SymbolSepar + k] := buf[k];
    end;
    mo.Flush(buf);
    for k := 0 to AMode.SymbolSepar - 1 do
      Result[n * AMode.SymbolSepar + k] := buf[k];
    for k := 0 to AMode.SymbolSepar - 1 do
      Result[(n + 1) * AMode.SymbolSepar + k] := 0;
  finally
    mo.Free;
  end;
  if ANoiseRms > 0 then
    for k := 0 to High(Result) do
      Result[k] := Result[k] + ANoiseRms * rnd.NextGauss;
end;

{ 復調して、指定の slice / 遅れで読んだシンボルを返す。 }
function Demodulate(const AMode: TOliviaToneMode; const AWave: TDArr;
  ACentreHz: Double; ASlice: Integer = ALIGNED_SLICE;
  ADelay: Integer = ALIGNED_DELAY; AFreqOffset: Integer = 0;
  AMinMargin: PDouble = nil): TIArr;
var
  de: TOliviaDemodulator;
  buf, soft: TDArr;
  i, k, b, blocks, n: Integer;
  mm, worst: Double;
begin
  de := TOliviaDemodulator.Create(AMode, ACentreHz);
  try
    SetLength(buf, AMode.SymbolSepar);
    SetLength(soft, AMode.BitsPerSymbol);
    blocks := Length(AWave) div AMode.SymbolSepar;
    SetLength(Result, blocks);
    n := 0;
    worst := 1E30;
    for i := 0 to blocks - 1 do
    begin
      for k := 0 to AMode.SymbolSepar - 1 do
        buf[k] := AWave[i * AMode.SymbolSepar + k];
      de.Process(buf);
      if i >= ADelay then
      begin
        Result[n] := de.HardDecode(ASlice, AFreqOffset);
        de.SoftDecode(ASlice, soft, AFreqOffset);
        mm := 1E30;
        for b := 0 to AMode.BitsPerSymbol - 1 do
          if Abs(soft[b]) < mm then mm := Abs(soft[b]);
        if mm < worst then worst := mm;
        Inc(n);
      end;
    end;
    SetLength(Result, n);
    if AMinMargin <> nil then AMinMargin^ := worst;
  finally
    de.Free;
  end;
end;

function MakeSymbols(ACount, ATones: Integer): TIArr;
var
  i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
    Result[i] := (i * 11 + 3) mod ATones;
end;

{ 送ったシンボルと読んだシンボルを突き合わせる。 }
function CountBad(const ASent, AGot: TIArr): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(ASent) do
    if (i > High(AGot)) or (AGot[i] <> ASent[i]) then Inc(Result);
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

  上流は FirstCarrier を
      (SymbolLen/16) * (f - Bandwidth*(1 - 0.5/Tones)/2) / 500 + 1
  という形で出す。こちらは「トーンの列の中心が f に来る bin」という形で
  出している。**同じ値になること**を、いくつかの諸元と周波数で確かめる。
  -------------------------------------------------------------------------- }
function UpstreamFirstCarrier(const AMode: TOliviaToneMode;
  ACentreHz: Double): Integer;
var
  fcOffset, mult: Double;
begin
  fcOffset := AMode.BandwidthHz * (1.0 - 0.5 / AMode.Tones) / 2.0;
  mult := (ACentreHz - fcOffset) / 500.0;
  Result := Trunc((AMode.SymbolLen / 16) * mult) + 1;
end;

procedure TestModeParameters;
var
  m: TOliviaToneMode;
  mo: TOliviaModulator;
  modes: array[0..2] of TOliviaToneMode;
  freqs: array[0..3] of Double = (750, 1000, 1250, 1500);
  i, k, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 1. 諸元 ---');

  m := OLIVIA_32_1000;
  WriteLn('        ', m.Describe);
  CheckEqI(m.SymbolLen, 512, 'Olivia 32/1000 のシンボル長は 512 サンプル');
  CheckEqI(m.SymbolSepar, 256, '送り出す間隔はその半分');
  Check(Abs(m.BaudRate - 31.25) < 1E-9,
    Format('速度は 31.25 baud (実測 %.4f)', [m.BaudRate]));
  Check(Abs(m.ToneSpacingHz - 31.25) < 1E-9,
    Format('トーン間隔は 31.25 Hz (実測 %.4f)', [m.ToneSpacingHz]));
  Check(Abs(m.OccupiedBandwidthHz - 968.75) < 1E-9,
    Format('占有幅は 968.75 Hz (実測 %.2f)', [m.OccupiedBandwidthHz]));

  m := OLIVIA_16_500;
  CheckEqI(m.SymbolLen, 512, 'Olivia 16/500 も 512 サンプル');
  Check(Abs(m.ToneSpacingHz - 31.25) < 1E-9, 'Olivia 16/500 の間隔も 31.25 Hz');

  { 帯域を半分にするとシンボルは倍の長さになる。 }
  m.Variant_ := ovOlivia; m.BitsPerSymbol := 5; m.BandwidthHz := 500;
  m.SampleRate := 8000;
  CheckEqI(m.SymbolLen, 1024, '帯域を半分にするとシンボル長は倍');

  { --- FirstCarrier が上流の式と一致すること --- }
  modes[0] := OLIVIA_32_1000;
  modes[1] := OLIVIA_16_500;
  modes[2] := CONTESTIA_32_1000;
  bad := 0;
  for i := 0 to High(modes) do
    for k := 0 to High(freqs) do
    begin
      mo := TOliviaModulator.Create(modes[i], freqs[k]);
      try
        if mo.FirstCarrier <> UpstreamFirstCarrier(modes[i], freqs[k]) then
        begin
          Inc(bad);
          WriteLn(Format('        ちがう: %s @%.0f Hz  こちら %d / 上流 %d',
            [modes[i].Describe, freqs[k], mo.FirstCarrier,
             UpstreamFirstCarrier(modes[i], freqs[k])]));
        end;
      finally
        mo.Free;
      end;
    end;
  CheckEqI(bad, 0,
    '**トーンの置き場所が上流の式と一致する** (3 諸元 x 4 周波数)');

  mo := TOliviaModulator.Create(OLIVIA_32_1000, 1000);
  try
    CheckEqI(mo.FirstCarrier, 33, 'Olivia 32/1000 を 1000 Hz に置くと bin 33');
  finally
    mo.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. 実数列 2 本を 1 回の FFT で
  -------------------------------------------------------------------------- }
procedure TestSplitTwoRealSpectra;
const
  N = 64;
var
  a, b: array[0..N - 1] of Double;
  z, fa, fb: TComplexArray;
  o0, o1: TComplexArray;
  i: Integer;
  worst, d: Double;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 2. 実数列 2 本を 1 回の FFT で分ける ---');
  for i := 0 to N - 1 do
  begin
    a[i] := Sin(i * 0.31) + 0.5 * Cos(i * 1.7);
    b[i] := Cos(i * 0.11) - 0.25 * Sin(i * 2.3);
  end;

  { 別々に 2 回回したもの (基準)。 }
  SetLength(fa, N); SetLength(fb, N);
  for i := 0 to N - 1 do
  begin
    fa[i] := CplxMake(a[i], 0);
    fb[i] := CplxMake(b[i], 0);
  end;
  ComplexFFT(fa);
  ComplexFFT(fb);

  { 1 回に詰めて分けたもの。 }
  SetLength(z, N);
  for i := 0 to N - 1 do z[i] := CplxMake(a[i], b[i]);
  ComplexFFT(z);
  SetLength(o0, 0); SetLength(o1, 0);
  SplitTwoRealSpectra(z, o0, o1);

  worst := 0;
  for i := 0 to N div 2 - 1 do
  begin
    d := Abs(o0[i].Re - fa[i].Re); if d > worst then worst := d;
    d := Abs(o0[i].Im - fa[i].Im); if d > worst then worst := d;
    d := Abs(o1[i].Re - fb[i].Re); if d > worst then worst := d;
    d := Abs(o1[i].Im - fb[i].Im); if d > worst then worst := d;
  end;
  Check(worst < 1E-9,
    Format('**1 回で分けたものが 2 回回したものと一致** (最大差 %.3E)',
      [worst]));

  raised := False;
  SetLength(z, 6);
  try
    SplitTwoRealSpectra(z, o0, o1);
  except
    on EDspError do raised := True;
  end;
  Check(raised, '長さが 2 の冪乗でなければ例外にする');
end;

{ --------------------------------------------------------------------------
  3. 送信波形
  -------------------------------------------------------------------------- }
procedure TestTransmitWave;
const
  NFFT = 8192;
var
  m: TOliviaToneMode;
  syms: TIArr;
  w: TDArr;
  buf: TComplexArray;
  mo: TOliviaModulator;
  one: TDArr;
  i, k, bin, loBin, hiBin: Integer;
  env, minEnv, maxEnv, mag, inBand, outBand, total: Double;
begin
  WriteLn;
  WriteLn('--- 3. 送信波形 ---');
  m := OLIVIA_32_1000;

  { --- 同じシンボルを続けると包絡線が平らになる ---
    持ち上がり窓を半分ずらして足すと 1-cos(x) + 1-cos(x+pi) = 2 になる。
    ここが平らでないと、送信の振幅が周期的に脈打つ。 }
  mo := TOliviaModulator.Create(m, 1000);
  try
    SetLength(one, m.SymbolSepar);
    SetLength(w, 20 * m.SymbolSepar);
    for i := 0 to 19 do
    begin
      mo.Send(7, one);
      for k := 0 to m.SymbolSepar - 1 do w[i * m.SymbolSepar + k] := one[k];
    end;
  finally
    mo.Free;
  end;

  { 立ち上がりの 2 区画を除いて、包絡線 (振幅の山) を見る。
    1 周期ぶんずつ最大値を取る。 }
  minEnv := 1E30; maxEnv := 0;
  i := 2 * m.SymbolSepar;
  while i + 16 < Length(w) - m.SymbolSepar do
  begin
    env := 0;
    for k := i to i + 15 do
      if Abs(w[k]) > env then env := Abs(w[k]);
    if env < minEnv then minEnv := env;
    if env > maxEnv then maxEnv := env;
    Inc(i, 16);
  end;
  WriteLn(Format('        同じトーンを続けたときの包絡線 %.4f..%.4f (比 %.4f)',
    [minEnv, maxEnv, minEnv / maxEnv]));
  { **包絡線は平らにならない。** 窓そのものは半分ずらして足すと
    1-cos(x) + 1-cos(x+pi) = 2 で平らになるが、重なる 2 つのシンボルは
    位相が 90 度ずれている (上流と同じ揺らぎを入れてあるため)。
    直交する 2 つを足すと振幅は sqrt(w1^2 + w2^2) になり、
    w1=w2=1 のとき sqrt(2)、w1=2/w2=0 のとき 2 ―― 比は 1/sqrt(2) である。

    ここを「平ら」と書いて通してしまうと、揺らぎを外したときに
    **気づかずに上流と違う波形を出す**ことになる。理屈の値で固定する。 }
  Check(Abs(minEnv / maxEnv - 1 / Sqrt(2)) < 0.02,
    Format('**包絡線の凹みが 1/sqrt(2) になる** (直交する揺らぎのため / 実測 %.4f)',
      [minEnv / maxEnv]));
  Check((maxEnv > 0.95) and (maxEnv <= 1.001),
    Format('定常トーンの振幅の山が 1.0 (実測 %.4f)', [maxEnv]));

  { --- 電力が占有帯域に収まる --- }
  syms := MakeSymbols(60, m.Tones);
  w := Modulate(m, syms, 1000);
  SetLength(buf, NFFT);
  for i := 0 to NFFT - 1 do
    buf[i] := CplxMake(w[Length(w) div 2 - NFFT div 2 + i], 0);
  ComplexFFT(buf);

  { トーンの列の外側にトーン間隔 2 本ぶんの余裕を見る。 }
  loBin := Floor((1000 - m.OccupiedBandwidthHz / 2 - 2 * m.ToneSpacingHz)
           * NFFT / m.SampleRate);
  hiBin := Ceil((1000 + m.OccupiedBandwidthHz / 2 + 2 * m.ToneSpacingHz)
           * NFFT / m.SampleRate);
  inBand := 0; outBand := 0;
  for bin := 0 to NFFT div 2 - 1 do
  begin
    mag := buf[bin].Re * buf[bin].Re + buf[bin].Im * buf[bin].Im;
    if (bin >= loBin) and (bin <= hiBin) then inBand := inBand + mag
    else outBand := outBand + mag;
  end;
  total := inBand + outBand;
  WriteLn(Format('        %.1f..%.1f Hz に %.3f%%',
    [loBin * m.SampleRate / NFFT, hiBin * m.SampleRate / NFFT,
     100 * inBand / total]));
  Check(inBand / total > 0.99, '**送信電力の 99% 以上が占有帯域に収まる**');
end;

{ --------------------------------------------------------------------------
  4. 往復
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  modes: array[0..2] of TOliviaToneMode;
  syms, got: TIArr;
  w: TDArr;
  i, bad: Integer;
  marg: Double;
begin
  WriteLn;
  WriteLn('--- 4. 送ったシンボルがそのシンボルとして戻る ---');
  modes[0] := OLIVIA_32_1000;
  modes[1] := OLIVIA_16_500;
  modes[2] := CONTESTIA_32_1000;
  for i := 0 to High(modes) do
  begin
    syms := MakeSymbols(80, modes[i].Tones);
    w := Modulate(modes[i], syms, 1000);
    got := Demodulate(modes[i], w, 1000, ALIGNED_SLICE, ALIGNED_DELAY, 0,
      @marg);
    bad := CountBad(syms, got);
    WriteLn(Format('        %-34s 誤り %d / %d  余裕 %.4f',
      [modes[i].Describe, bad, Length(syms), marg]));
    CheckEqI(bad, 0, Format('**%d トーン / %d Hz で全シンボル戻る**',
      [modes[i].Tones, modes[i].BandwidthHz]));
  end;
end;

{ --------------------------------------------------------------------------
  5. 2 枚の spectrum

  1 回の Process で出る 2 枚は SymbolLen/4 = 半シンボル ずれている。
  片方が区切りに合っていれば、もう片方は必ず二つのシンボルにまたがる。
  どちらが合っているかは次の層 (ブロックの頭出し) が選ぶ。
  -------------------------------------------------------------------------- }
procedure TestTwoSlices;
var
  m: TOliviaToneMode;
  syms, got: TIArr;
  w: TDArr;
  slice, delay, bad, best, bestSlice, bestDelay, zeroCount: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 2 枚の spectrum のうち合うのは片方だけ ---');
  m := OLIVIA_32_1000;
  syms := MakeSymbols(60, m.Tones);
  w := Modulate(m, syms, 1000);

  best := MaxInt; bestSlice := -1; bestDelay := -1; zeroCount := 0;
  WriteLn('          slice  遅れ  誤り');
  for slice := 0 to OLIVIA_SLICES - 1 do
    for delay := 0 to 2 do
    begin
      got := Demodulate(m, w, 1000, slice, delay);
      bad := CountBad(syms, got);
      WriteLn(Format('          %3d   %3d   %3d', [slice, delay, bad]));
      if bad = 0 then Inc(zeroCount);
      if bad < best then
      begin
        best := bad; bestSlice := slice; bestDelay := delay;
      end;
    end;
  CheckEqI(zeroCount, 1, '**誤り 0 になる組み合わせはただ一つ**');
  CheckEqI(bestSlice, ALIGNED_SLICE, 'その組は slice 1');
  CheckEqI(bestDelay, ALIGNED_DELAY, 'その組は遅れ 1 区画');
  Check(best = 0, '前提: その組で誤りが無い');
end;

{ --------------------------------------------------------------------------
  6. トーンの割り当てが上流と一致する

  上流 Olivia は送信で tone = GrayCode(symbol) = symbol xor (symbol shr 1)、
  受信で symbol = BinaryCode(tone) (畳み込み) を使う。

  **これは fldigi の MFSK とは逆向きである。** MFSK は
  symbol = GrayEncode(tone) なので、隣り合うトーンを取り違えても
  ビット誤りが 1 本で済む。Olivia の向きではそうならず、実測で最大 3 本
  化ける。上流がそう書いている以上、互換性のためこちらも合わせる ――
  **良し悪しではなく、繋がるかどうかの問題である。**

  内部の関数を呼び比べるだけでは「自分の思い込み同士」を突き合わせる
  ことになるので、**実際に出した音の山がどの bin に立つか**で見る。
  -------------------------------------------------------------------------- }
procedure TestToneAssignment;
const
  NFFT = 4096;
var
  m: TOliviaToneMode;
  mo: TOliviaModulator;
  buf: TDArr;
  fft: TComplexArray;
  sym, i, k, bin, peakBin, expectBin, bad, worst, plain: Integer;
  e, peak: Double;
begin
  WriteLn;
  WriteLn('--- 6. トーンの割り当てが上流と一致する ---');
  m := OLIVIA_32_1000;

  bad := 0;
  for sym := 0 to m.Tones - 1 do
  begin
    { 同じシンボルを続けて出し、真ん中を切り出して山を探す。 }
    mo := TOliviaModulator.Create(m, 1000);
    try
      SetLength(buf, m.SymbolSepar);
      SetLength(fft, NFFT);
      k := 0;
      for i := 0 to (NFFT div m.SymbolSepar) + 3 do
      begin
        mo.Send(sym, buf);
        for bin := 0 to m.SymbolSepar - 1 do
          if (i >= 2) and (k < NFFT) then
          begin
            fft[k] := CplxMake(buf[bin], 0);
            Inc(k);
          end;
      end;
    finally
      mo.Free;
    end;
    ComplexFFT(fft);

    peak := 0; peakBin := 0;
    for bin := 0 to NFFT div 2 - 1 do
    begin
      e := fft[bin].Re * fft[bin].Re + fft[bin].Im * fft[bin].Im;
      if e > peak then begin peak := e; peakBin := bin; end;
    end;

    { 上流の割り当て: bin = FirstCarrier + 2 * (sym xor (sym shr 1))。
      NFFT は SymbolLen の 8 倍なので bin も 8 倍になる。 }
    expectBin := (33 + OLIVIA_CARRIER_SEPAR * (sym xor (sym shr 1)))
                 * (NFFT div m.SymbolLen);
    if Abs(peakBin - expectBin) > 1 then
    begin
      Inc(bad);
      if bad <= 3 then
        WriteLn(Format('        ちがう: シンボル %d は bin %d / 期待 %d',
          [sym, peakBin, expectBin]));
    end;
  end;
  CheckEqI(bad, 0,
    '**32 通りすべてで、出した音の山が上流の割り当てどおりの bin に立つ**');

  { 隣り合うトーンのビット差。上流の向きでは 1 本では済まない。
    数字を残しておく ―― 次の層で軟判定の重みを考えるときに要る。 }
  worst := 0; plain := 0;
  for i := 0 to m.Tones - 2 do
  begin
    if PopCount(Integer(GrayDecode(LongWord(i)))
                xor Integer(GrayDecode(LongWord(i + 1)))) > worst then
      worst := PopCount(Integer(GrayDecode(LongWord(i)))
                        xor Integer(GrayDecode(LongWord(i + 1))));
    if PopCount(i xor (i + 1)) > plain then plain := PopCount(i xor (i + 1));
  end;
  WriteLn(Format('        隣り合うトーンのビット差: Olivia の向き %d bit / 素の番号 %d bit',
    [worst, plain]));
  CheckEqI(worst, 3,
    '隣り合うトーンの取り違えは最大 3 bit (MFSK の 1 bit とは違う向き)');
  Check(worst < plain, '素の番号よりはましである');
end;

{ --------------------------------------------------------------------------
  7. 軟判定が符号の層に噛み合う

  層の間でビットの並びと軟判定の符号が食い違っていないことを、
  **実際に通して文字が戻るか**で確かめる。往復試験では見えない。
  -------------------------------------------------------------------------- }
procedure TestFeedsBlockDecoder;
var
  tm: TOliviaToneMode;
  bm: TOliviaMode;
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  de: TOliviaDemodulator;
  mo: TOliviaModulator;
  chars, blockSyms: array of Byte;
  buf, soft: TDArr;
  w: TDArr;
  i, k, n, fed, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 7. 軟判定が符号の層にそのまま噛み合う ---');
  tm := OLIVIA_32_1000;
  bm := tm.BlockMode;

  { 1 ブロックぶんの文字を符号化してシンボル列にし、音にする。 }
  enc := TOliviaBlockEncoder.Create(bm);
  try
    SetLength(chars, bm.CharsPerBlock);
    SetLength(blockSyms, bm.SymbolsPerBlock);
    for i := 0 to bm.CharsPerBlock - 1 do chars[i] := Ord('A') + i;
    enc.EncodeBlock(chars, blockSyms);
  finally
    enc.Free;
  end;

  mo := TOliviaModulator.Create(tm, 1000);
  try
    SetLength(buf, tm.SymbolSepar);
    n := bm.SymbolsPerBlock;
    SetLength(w, (n + 2) * tm.SymbolSepar);
    for i := 0 to n - 1 do
    begin
      mo.Send(blockSyms[i], buf);
      for k := 0 to tm.SymbolSepar - 1 do
        w[i * tm.SymbolSepar + k] := buf[k];
    end;
    mo.Flush(buf);
    for k := 0 to tm.SymbolSepar - 1 do
      w[n * tm.SymbolSepar + k] := buf[k];
    for k := 0 to tm.SymbolSepar - 1 do
      w[(n + 1) * tm.SymbolSepar + k] := 0;
  finally
    mo.Free;
  end;

  { 音から軟判定を取り、そのまま符号の層へ流す。 }
  de := TOliviaDemodulator.Create(tm, 1000);
  dec_ := TOliviaBlockDecoder.Create(bm);
  try
    SetLength(soft, tm.BitsPerSymbol);
    fed := 0;
    for i := 0 to Length(w) div tm.SymbolSepar - 1 do
    begin
      for k := 0 to tm.SymbolSepar - 1 do
        buf[k] := w[i * tm.SymbolSepar + k];
      de.Process(buf);
      if (i >= ALIGNED_DELAY) and (fed < n) then
      begin
        de.SoftDecode(ALIGNED_SLICE, soft);
        dec_.Input(soft);
        Inc(fed);
      end;
    end;
    CheckEqI(fed, n, '前提: 1 ブロックぶんの軟判定を流し込めた');
    dec_.Process;
    bad := 0;
    for i := 0 to bm.CharsPerBlock - 1 do
      if dec_.OutputChar(i) <> chars[i] then Inc(bad);
    WriteLn(Format('        復号: [%s%s%s%s%s] / Signal %.3E / Noise %.3E',
      [Chr(dec_.OutputChar(0)), Chr(dec_.OutputChar(1)),
       Chr(dec_.OutputChar(2)), Chr(dec_.OutputChar(3)),
       Chr(dec_.OutputChar(4)), dec_.Signal, dec_.NoiseEnergy]));
    CheckEqI(bad, 0,
      '**音から取った軟判定で符号の層が文字を戻す** (向きと並びが合っている)');
  finally
    de.Free; dec_.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7b. 軟判定の質を、符号の層を通した文字誤りで測る

  トーンの重みに energy の二乗 (|X|^4) を使うのは上流と同じだが、
  **硬判定には一切効かない** ―― 単調変換なので山の位置が変わらない。
  効くのは軟判定の形だけである。したがって硬判定だけを見ている試験では
  二乗を外しても何も落ちない (実際に落ちなかった)。

  そこで符号の層まで通した文字誤りで測る。ついでに、誤り訂正が
  どれだけ稼いでいるかの数字にもなる。
  -------------------------------------------------------------------------- }
function BlockThroughAir(const ATm: TOliviaToneMode; ANoiseRms: Double;
  ASeed: QWord; out AMinMargin: Double): Integer;
var
  bm: TOliviaMode;
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  mo: TOliviaModulator;
  de: TOliviaDemodulator;
  chars, blockSyms: array of Byte;
  buf, soft, w: TDArr;
  rnd: TVectorRandom;
  i, k, b, n, fed: Integer;
  mm: Double;
begin
  bm := ATm.BlockMode;
  rnd.Seed(ASeed);

  enc := TOliviaBlockEncoder.Create(bm);
  try
    SetLength(chars, bm.CharsPerBlock);
    SetLength(blockSyms, bm.SymbolsPerBlock);
    for i := 0 to bm.CharsPerBlock - 1 do chars[i] := Ord('A') + i;
    enc.EncodeBlock(chars, blockSyms);
  finally
    enc.Free;
  end;

  mo := TOliviaModulator.Create(ATm, 1000);
  try
    SetLength(buf, ATm.SymbolSepar);
    n := bm.SymbolsPerBlock;
    SetLength(w, (n + 2) * ATm.SymbolSepar);
    for i := 0 to n - 1 do
    begin
      mo.Send(blockSyms[i], buf);
      for k := 0 to ATm.SymbolSepar - 1 do
        w[i * ATm.SymbolSepar + k] := buf[k];
    end;
    mo.Flush(buf);
    for k := 0 to ATm.SymbolSepar - 1 do
      w[n * ATm.SymbolSepar + k] := buf[k];
    for k := 0 to ATm.SymbolSepar - 1 do
      w[(n + 1) * ATm.SymbolSepar + k] := 0;
  finally
    mo.Free;
  end;
  if ANoiseRms > 0 then
    for k := 0 to High(w) do
      w[k] := w[k] + ANoiseRms * rnd.NextGauss;

  de := TOliviaDemodulator.Create(ATm, 1000);
  dec_ := TOliviaBlockDecoder.Create(bm);
  try
    SetLength(soft, ATm.BitsPerSymbol);
    fed := 0;
    AMinMargin := 1E30;
    for i := 0 to Length(w) div ATm.SymbolSepar - 1 do
    begin
      for k := 0 to ATm.SymbolSepar - 1 do
        buf[k] := w[i * ATm.SymbolSepar + k];
      de.Process(buf);
      if (i >= ALIGNED_DELAY) and (fed < n) then
      begin
        de.SoftDecode(ALIGNED_SLICE, soft);
        mm := 1E30;
        for b := 0 to ATm.BitsPerSymbol - 1 do
          if Abs(soft[b]) < mm then mm := Abs(soft[b]);
        if mm < AMinMargin then AMinMargin := mm;
        dec_.Input(soft);
        Inc(fed);
      end;
    end;
    dec_.Process;
    Result := 0;
    for i := 0 to bm.CharsPerBlock - 1 do
      if dec_.OutputChar(i) <> chars[i] then Inc(Result);
  finally
    de.Free; dec_.Free;
  end;
end;

procedure TestSoftPathThroughBlock;
const
  TRIALS = 40;
var
  m: TOliviaToneMode;
  rms: array[0..6] of Double = (0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
  i, k, bad, total: Integer;
  mm, msum, cleanMargin: Double;
  cer3: Double;
begin
  WriteLn;
  WriteLn('--- 7b. 符号の層まで通した文字誤り ---');
  m := OLIVIA_32_1000;
  cleanMargin := 0;
  cer3 := 1;
  WriteLn('          雑音rms   文字誤り率   軟判定の最小の平均');
  for i := 0 to High(rms) do
  begin
    bad := 0; total := 0; msum := 0;
    for k := 1 to TRIALS do
    begin
      Inc(bad, BlockThroughAir(m, rms[i], QWord(7919 * k + 1), mm));
      Inc(total, m.BlockMode.CharsPerBlock);
      msum := msum + mm;
    end;
    WriteLn(Format('          %6.2f     %.3f        %.5f',
      [rms[i], bad / total, msum / TRIALS]));
    if i = 0 then cleanMargin := msum / TRIALS;
    if rms[i] = 3.0 then cer3 := bad / total;
  end;

  { 二乗の重みが効いていること。外すと無雑音でも 0.68 まで痩せる
    (実測)。硬判定には一切効かないので、ここでしか見えない。 }
  Check(cleanMargin > 0.9,
    Format('**無雑音での軟判定が振り切れている** (実測 %.4f / 二乗を外すと 0.68)',
      [cleanMargin]));
  Check(cer3 = 0,
    Format('**雑音 rms 3.0 でも文字誤り 0** (硬判定は rms 2.0 で崩れ始める / 実測 %.3f)',
      [cer3]));
end;

{ --------------------------------------------------------------------------
  8. 周波数のずれ
  -------------------------------------------------------------------------- }
procedure TestFrequencyOffset;
var
  m: TOliviaToneMode;
  syms, got: TIArr;
  w: TDArr;
  off, bad, badNo, i: Integer;
  offs: array[0..4] of Integer = (-8, -4, 0, 4, 8);
  corrected, uncorrected: Integer;
begin
  WriteLn;
  WriteLn('--- 8. 周波数のずれを FreqOffset で補える ---');
  m := OLIVIA_32_1000;
  syms := MakeSymbols(60, m.Tones);
  corrected := 0; uncorrected := 0;
  WriteLn('          ずれ[bin]  補正あり  補正なし');
  for i := 0 to High(offs) do
  begin
    off := offs[i];
    w := Modulate(m, syms, 1000 + off * m.BinWidthHz);
    got := Demodulate(m, w, 1000, ALIGNED_SLICE, ALIGNED_DELAY, off);
    bad := CountBad(syms, got);
    got := Demodulate(m, w, 1000, ALIGNED_SLICE, ALIGNED_DELAY, 0);
    badNo := CountBad(syms, got);
    WriteLn(Format('          %6d      %4d      %4d', [off, bad, badNo]));
    if bad = 0 then Inc(corrected);
    if (off <> 0) and (badNo > Length(syms) div 2) then Inc(uncorrected);
  end;
  CheckEqI(corrected, Length(offs),
    '**ずらし量を与えれば ±8 bin まで全シンボル戻る**');
  CheckEqI(uncorrected, Length(offs) - 1,
    '前提: 補正しなければ崩れる (ずらし量が効いている証拠)');

  { 範囲外は断る。黙って別の bin を読まない。 }
  bad := 0;
  try
    Demodulate(m, w, 1000, ALIGNED_SLICE, ALIGNED_DELAY, 999);
  except
    on EOliviaToneError do bad := 1;
  end;
  CheckEqI(bad, 1, '範囲外のずらし量は例外にする');
end;

{ --------------------------------------------------------------------------
  9. 雑音に対する強さ
  -------------------------------------------------------------------------- }
procedure TestNoise;
const
  TRIALS = 4;
var
  m: TOliviaToneMode;
  syms, got: TIArr;
  w, clean: TDArr;
  i, k, bad, total: Integer;
  ser, sigPwr, snr, firstFail: Double;
  foundFail: Boolean;
  rms: array[0..8] of Double = (0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0);
begin
  WriteLn;
  WriteLn('--- 9. 雑音に対する強さ ---');
  m := OLIVIA_32_1000;
  syms := MakeSymbols(100, m.Tones);
  clean := Modulate(m, syms, 1000);

  sigPwr := 0;
  for k := 0 to High(clean) do sigPwr := sigPwr + clean[k] * clean[k];
  sigPwr := sigPwr / Length(clean);

  WriteLn('          雑音rms   広帯域S/N   シンボル誤り率');
  foundFail := False; firstFail := 0;
  for i := 0 to High(rms) do
  begin
    bad := 0; total := 0;
    for k := 1 to TRIALS do
    begin
      w := Modulate(m, syms, 1000, rms[i], QWord(7919 * k + 11));
      got := Demodulate(m, w, 1000);
      Inc(bad, CountBad(syms, got));
      Inc(total, Length(syms));
    end;
    ser := bad / total;
    if rms[i] > 0 then
    begin
      snr := 10 * Log10(sigPwr / (rms[i] * rms[i]));
      WriteLn(Format('          %6.2f   %7.1f dB   %.3f', [rms[i], snr, ser]));
    end
    else
    begin
      snr := 0;
      WriteLn(Format('          %6.2f    (無雑音)   %.3f', [rms[i], ser]));
    end;
    if (not foundFail) and (ser > 0.01) then
    begin
      foundFail := True;
      firstFail := snr;
    end;
  end;
  Check(foundFail,
    '掃引が崖を跨いでいる (雑音を増やせば必ず崩れる)');
  if foundFail then
    WriteLn(Format('        シンボル誤り率 1%% を初めて超えた広帯域 S/N: %.1f dB',
      [firstFail]));

  { 実用域の主張。 }
  bad := 0; total := 0;
  for k := 1 to TRIALS do
  begin
    w := Modulate(m, syms, 1000, 1.0, QWord(104729 * k + 3));
    got := Demodulate(m, w, 1000);
    Inc(bad, CountBad(syms, got));
    Inc(total, Length(syms));
  end;
  CheckEqI(bad, 0, '**雑音 rms 1.0 ではシンボル誤り 0**');
end;

{ --------------------------------------------------------------------------
  10. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05)
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
const
  ROUNDS = 100;
var
  m: TOliviaToneMode;
  mo: TOliviaModulator;
  de: TOliviaDemodulator;
  buf, soft: TDArr;
  syms, g1, g2: TIArr;
  w1, w2: TDArr;
  i, k, n, same: Integer;
begin
  WriteLn;
  WriteLn('--- 10. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05) ---');
  m := OLIVIA_32_1000;
  mo := TOliviaModulator.Create(m, 1000);
  de := TOliviaDemodulator.Create(m, 1000);
  try
    SetLength(buf, m.SymbolSepar);
    SetLength(soft, m.BitsPerSymbol);
    mo.Send(0, buf);          { 初回ぶんを済ませる }
    de.Process(buf);
    de.SoftDecode(0, soft);

    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for k := 1 to ROUNDS do
      begin
        mo.Send(k mod m.Tones, buf);
        de.Process(buf);
        de.HardDecode(1);
        de.SoftDecode(1, soft);
      end;
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0,
      Format('%d シンボルの送受で確保 0 回 (実測 %d)', [ROUNDS, n]));
  finally
    mo.Free; de.Free;
  end;

  { 同じシンボル列から同じ音が出ること。上流は rand() を引くので
    ここが成り立たない ―― 決め打ちの種にしてある理由である。 }
  syms := MakeSymbols(40, m.Tones);
  w1 := Modulate(m, syms, 1000);
  w2 := Modulate(m, syms, 1000);
  same := 0;
  for i := 0 to High(w1) do
    if w1[i] <> w2[i] then Inc(same);
  CheckEqI(same, 0, '**同じシンボル列から 1 サンプルも違わない音が出る** (Z-05)');

  g1 := Demodulate(m, w1, 1000);
  g2 := Demodulate(m, w2, 1000);
  CheckEqI(CountBad(g1, g2), 0, '同じ音から同じ復調結果');

  { Reset で送信の環も位相も戻る。 }
  mo := TOliviaModulator.Create(m, 1000);
  try
    SetLength(w1, 8 * m.SymbolSepar);
    SetLength(w2, 8 * m.SymbolSepar);
    for i := 0 to 7 do
    begin
      mo.Send(syms[i], buf);
      for k := 0 to m.SymbolSepar - 1 do w1[i * m.SymbolSepar + k] := buf[k];
    end;
    mo.Reset;
    for i := 0 to 7 do
    begin
      mo.Send(syms[i], buf);
      for k := 0 to m.SymbolSepar - 1 do w2[i * m.SymbolSepar + k] := buf[k];
    end;
  finally
    mo.Free;
  end;
  same := 0;
  for i := 0 to High(w1) do
    if w1[i] <> w2[i] then Inc(same);
  CheckEqI(same, 0, 'Reset のあとは最初と同じ音が出る (環・位相・揺らぎ)');
end;

begin
  WriteLn('=== Olivia / Contestia の音の層の試験 ===');

  TestModeParameters;
  TestSplitTwoRealSpectra;
  TestTransmitWave;
  TestRoundTrip;
  TestTwoSlices;
  TestToneAssignment;
  TestFeedsBlockDecoder;
  TestSoftPathThroughBlock;
  TestFrequencyOffset;
  TestNoise;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('OLV-003');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
