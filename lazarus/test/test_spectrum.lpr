{ ============================================================================
  test_spectrum.lpr

  共有スペクトルサービス (X-05 の Spectrum 部分) の試験。

  何を守るか
  ----------------------------------------------------------------------------
  1. 既知の正弦波が正しい bin に、正しい大きさで現れる
  2. 同じ音から同じスペクトルが出る (Z-05)
  4. 音を入れる経路で確保しない (X-04)
  5. **複数の読み手が全員同じ枠を得る** (Phase 3 の Algorithm Portfolio)
  6. **遅れた読み手は「何枠飛ばしたか」を知る**
  7. **流し直し (X-06 Replay) をまたいだ読み手はそれを知る** (黙って飛ばさない)
  8. FFT の係数表を他の利用者と共有している (X-05「資源の重複を無くす」)
  9. Waterfall の使い方 (最新が欲しい) と Noise Estimator の使い方
     (全枠が欲しい) の両方が成り立つ

  5 と 6 がこの単元の要点である。表示だけなら取りこぼしても困らないが、
  統計を取る側は取りこぼしに気づけないと**自分が偏っていることが分からない**。
  だから「飛ばした」を返り値で言う。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_spectrum;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, SpectrumService, TestVectors, EventBus, TestSupport,
  Requirements;

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
  RATE = 8000;
  FFTN = 2048;   { 試験では短くして速く回す。既定の 8192 は諸元の試験で見る }

  { 「全部入れてから読む」形の試験で使う輪の大きさ。
    hop は FFTN/4 = 512 なので、FFTN*4 サンプル入れると 13 枠できる。
    輪がそれより小さいと、読む前に最古が潰れて srMissed になる —— それは
    サービスの正しい振る舞いであって、ここで見たいことではない。
    追い越しそのものは試験 6 で正面から見る。 }
  CAP_ENOUGH = 64;

{ 振幅 AAmp・周波数 AHz の正弦波を ACount サンプル作って入れる。 }
procedure FeedTone(ASvc: TSpectrumService; AHz, AAmp: Double; ACount: Integer;
  APhase: Double = 0);
var
  buf: array of Double;
  i: Integer;
begin
  SetLength(buf, ACount);
  for i := 0 to ACount - 1 do
    buf[i] := AAmp * Sin(2 * Pi * AHz * i / RATE + APhase);
  ASvc.Feed(buf, ACount);
end;

{ 読める枠をすべて読む。最後の枠が ABins に残る。
  **srMissed で止まらない**のが肝で、`while TryRead(...) = srOk` と書くと
  一度追い越されただけで以降を読まずに終わってしまう。使う側が書きがちな
  誤りなので、正しい形をここに一つ置いて試験全体で使い回す。 }
function DrainFrames(ASvc: TSpectrumService; var ARd: TSpectrumReader;
  var ABins: array of Double; out AMissed: Int64): Integer;
var
  info: TSpectrumFrameInfo;
  r: TSpectrumReadResult;
begin
  Result := 0;
  AMissed := 0;
  repeat
    r := ASvc.TryRead(ARd, ABins, info);
    if r = srOk then
      Inc(Result)
    else if r = srMissed then
      AMissed := AMissed + info.MissedFrames;
    { srReset はここでは位置合わせだけして読み進める。
      統計を捨てるかどうかは使う側の判断なので、試験 8 で正面から見る。 }
  until r = srNoData;
end;

{ --------------------------------------------------------------------------
  1. 諸元
  -------------------------------------------------------------------------- }
procedure TestParameters;
var
  s: TSpectrumService;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. 諸元 ---');
  s := TSpectrumService.Create;   { 既定 }
  try
    CheckEqI(s.FftSize, 8192, '既定の FFT 長は 8192');
    CheckEqI(s.BinCount, 4097, 'bin は N/2+1 個');
    CheckEqI(s.Hop, 2048, '既定の送り幅は FFT 長の 1/4 (75% 重なる)');
    Check(Abs(s.BinFrequency(1) - 0.9765625) < 1E-9,
      Format('1 bin = %.4f Hz (PSK31 の幅 31 Hz を見分けられる)',
        [s.BinFrequency(1)]));
    Check(s.WindowKind = swHann, '既定の窓は Hann');
    Check(Abs(s.FrameSeconds - 0.256) < 1E-9,
      Format('1 枠あたり %.3f 秒', [s.FrameSeconds]));
  finally
    s.Free;
  end;

  { 不正な指定は作らせない。黙って別の値で動くより、作れないと言うほうがよい。 }
  Inc(TestCount);
  raised := False;
  try
    s := TSpectrumService.Create(1000);   { 2 の冪乗でない }
    s.Free;
  except
    on E: ESpectrumError do raised := True;
  end;
  if raised then WriteLn('  [OK] **2 の冪乗でない FFT 長を断る**')
  else begin WriteLn('  [NG] 2 の冪乗でない FFT 長を断る'); Inc(FailCount); end;

  Inc(TestCount);
  raised := False;
  try
    s := TSpectrumService.Create(FFTN, RATE, FFTN * 2);   { 送りが窓より広い }
    s.Free;
  except
    on E: ESpectrumError do raised := True;
  end;
  if raised then WriteLn('  [OK] **送り幅が FFT 長を超える指定を断る** (音が抜ける)')
  else begin WriteLn('  [NG] 送り幅が FFT 長を超える指定を断る'); Inc(FailCount); end;
end;

{ --------------------------------------------------------------------------
  2. 既知の正弦波が正しい bin に正しい大きさで出ること

  ここが合っていなければ、この上に建てる雑音推定も信号発見も意味を持たない。
  -------------------------------------------------------------------------- }
procedure TestKnownTone;
const
  TONE_HZ = 1000.0;
  AMP = 0.5;
var
  s: TSpectrumService;
  rd: TSpectrumReader;
  bins: array of Double;
  info: TSpectrumFrameInfo;
  i, peakBin, wantBin, frames: Integer;
  peak, expected, total: Double;
  r: TSpectrumReadResult;
  missed: Int64;
begin
  WriteLn;
  WriteLn('--- 2. 既知の正弦波 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
  try
    SetLength(bins, s.BinCount);
    rd := s.NewReader;
    FeedTone(s, TONE_HZ, AMP, FFTN * 3);

    frames := 0; missed := 0;
    peak := 0; peakBin := -1;
    repeat
      r := s.TryRead(rd, bins, info);
      if r = srMissed then
        missed := missed + info.MissedFrames
      else if r = srOk then
      begin
        Inc(frames);
        for i := 0 to s.BinCount - 1 do
          if bins[i] > peak then
          begin
            peak := bins[i];
            peakBin := i;
          end;
      end;
    until r = srNoData;

    CheckEqI(missed, 0, '前提: 輪を追い越していない (この試験の対象外)');
    Check(frames > 0, Format('枠ができた (%d 枠)', [frames]));
    if peakBin < 0 then
    begin
      WriteLn('        枠が無いので以降の確認を飛ばす');
      Exit;
    end;
    wantBin := s.FrequencyToBin(TONE_HZ);
    WriteLn(Format('        山は bin %d (%.1f Hz) / 期待 bin %d (%.1f Hz)',
      [peakBin, s.BinFrequency(peakBin), wantBin, s.BinFrequency(wantBin)]));
    CheckEqI(peakBin, wantBin, '**山が正しい bin に立つ**');

    { 正弦波の平均電力は A^2/2。窓の利得を正規化してあるので、
      山の bin にほぼそのまま出るはず。Hann 窓は隣の bin にも
      分けるので、山だけでは少し低く出る。 }
    expected := AMP * AMP / 2;
    WriteLn(Format('        山の値 %.6f / 正弦波の平均電力 %.6f (比 %.3f)',
      [peak, expected, peak / expected]));
    Check((peak > expected * 0.5) and (peak < expected * 1.2),
      '**山の大きさが正弦波の平均電力に見合う** (窓の利得が正規化されている)');

    { 山と両隣の和は平均電力そのものにはならない —— **ならないのが正しい**。
      窓の利得で正規化してあるので山が A^2/2 を指す。その代わり、
      全 bin を足すと A^2/2 の ENBW 倍 (Hann なら 1.5 倍) になる。
      これは Parseval から出る量で、窓を掛けた以上避けられない。
      「山を読む」用と「雑音を足す」用は別の正規化だ、という約束が
      ここに現れている。 }
    total := bins[peakBin];
    if peakBin > 0 then total := total + bins[peakBin - 1];
    if peakBin < s.BinCount - 1 then total := total + bins[peakBin + 1];
    WriteLn(Format('        山と両隣の和 %.6f / 期待 %.6f (= 平均電力 x ENBW %.4f)',
      [total, expected * s.NoiseBandwidthBins, s.NoiseBandwidthBins]));
    Check(Abs(total - expected * s.NoiseBandwidthBins) < expected * 0.03,
      '**山と両隣の和 = 平均電力 x ENBW** (窓が広げたぶんが勘定に合う)');

    { 全 bin を足しても同じ値になる。両隣より外に漏れが残っていない。 }
    total := 0;
    for i := 0 to s.BinCount - 1 do
      total := total + bins[i];
    WriteLn(Format('        全 bin の和 %.6f (比 %.4f)',
      [total, total / (expected * s.NoiseBandwidthBins)]));
    Check(Abs(total - expected * s.NoiseBandwidthBins) < expected * 0.03,
      '全 bin を足しても同じ (漏れが両隣の外に散っていない)');

    { 信号の無いところは十分小さい。 }
    peak := 0;
    for i := 0 to s.BinCount - 1 do
      if Abs(i - wantBin) > 5 then
        if bins[i] > peak then peak := bins[i];
    WriteLn(Format('        信号から離れた最大 %.3g (%.1f dB)',
      [peak, PowerToDb(peak)]));
    Check(peak < expected * 1E-3,
      '**信号から離れた bin は 30 dB 以上小さい** (窓が漏れを抑えている)');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. 二つの信号を見分けられること (自動信号発見の下地)
  -------------------------------------------------------------------------- }
procedure TestTwoTones;
var
  s: TSpectrumService;
  rd: TSpectrumReader;
  bins, buf: array of Double;
  i, b1, b2, frames: Integer;
  v1, v2, mid, f1, f2: Double;
  missed: Int64;
begin
  WriteLn;
  WriteLn('--- 3. 二つの信号を見分ける ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
  try
    SetLength(bins, s.BinCount);
    SetLength(buf, FFTN * 3);
    { 大きさを厳密に見たいので、音は **bin の中心** に置く。
      中心から外れると窓の山を斜めに切ることになり (スカラップ損)、
      同じ振幅でも読み値が下がる。中心から外れたときの振る舞いは
      この直後に別途見る —— 二つを混ぜると、どちらが原因か分からなくなる。 }
    b1 := 205;                       { 800.78 Hz }
    b2 := 410;                       { 1601.56 Hz }
    f1 := s.BinFrequency(b1);
    f2 := s.BinFrequency(b2);
    for i := 0 to High(buf) do
      buf[i] := 0.4 * Sin(2 * Pi * f1 * i / RATE)
              + 0.2 * Sin(2 * Pi * f2 * i / RATE);
    rd := s.NewReader;
    s.Feed(buf, Length(buf));
    frames := DrainFrames(s, rd, bins, missed);
    Check((frames > 0) and (missed = 0),
      Format('前提: %d 枠を取りこぼさず読んだ', [frames]));

    v1 := bins[b1];
    v2 := bins[b2];
    mid := bins[(b1 + b2) div 2];
    WriteLn(Format('        %.1fHz %.6f / %.1fHz %.6f / 間 %.3g',
      [f1, v1, f2, v2, mid]));
    Check(v1 > mid * 100, '下の山が谷よりはるかに高い');
    Check(v2 > mid * 100, '上の山が谷よりはるかに高い');
    { 山の高さがそれぞれの平均電力 A^2/2 に一致すること。
      二つ在っても互いに影響しない (線形性)。 }
    Check(Abs(v1 - 0.4 * 0.4 / 2) < 0.4 * 0.4 / 2 * 0.02,
      '**下の山が自分の平均電力を指す** (もう一方に引きずられない)');
    Check(Abs(v2 - 0.2 * 0.2 / 2) < 0.2 * 0.2 / 2 * 0.02,
      '**上の山が自分の平均電力を指す**');
    { 振幅比 0.4 : 0.2 なので電力比は 4 : 1 のはず。 }
    WriteLn(Format('        電力比 %.4f (振幅比 2 倍 -> 電力 4 倍が期待)',
      [v1 / v2]));
    Check(Abs(v1 / v2 - 4.0) < 0.05,
      '**電力比が振幅比の二乗になる** (大きさの意味が保たれている)');

    { bin の中心から最も遠いところ (半 bin ずれ) に置いたときの目減り。
      Hann のスカラップ損は最大 1.42 dB (電力で 0.72 倍)。
      信号発見が「山の高さ」で閾値を切るときに効いてくる量なので、
      **どれだけ目減りするかを数字で残しておく**。 }
    s.Reset;
    f1 := s.BinFrequency(b1) + s.BinWidthHz / 2;
    for i := 0 to High(buf) do
      buf[i] := 0.4 * Sin(2 * Pi * f1 * i / RATE);
    rd := s.NewReader;
    s.Feed(buf, Length(buf));
    frames := DrainFrames(s, rd, bins, missed);
    v1 := 0;
    for i := 0 to s.BinCount - 1 do
      if bins[i] > v1 then v1 := bins[i];
    v2 := 0.4 * 0.4 / 2;
    WriteLn(Format('        半 bin ずらすと山は %.4f 倍 (%.2f dB)',
      [v1 / v2, PowerToDb(v1 / v2)]));
    Check((v1 / v2 > 0.70) and (v1 / v2 < 0.75),
      '**bin の中心から半 bin ずれても目減りは 1.42 dB に収まる**');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 雑音の床が窓と FFT 長に依らないこと (Phase 3 Noise Estimator の下地)

  枠の値をそのまま雑音床に使うと、**設定を変えただけで床が動く**。
  Hann と Blackman では ENBW が 1.5 対 1.727 なので約 0.6 dB、
  FFT 長を 4 倍にすれば bin 幅が 1/4 になって 6 dB 動く。
  そんな量を基準にすると「雑音が増えた」のか「窓を替えた」のかを
  区別できない —— 受信状態の判定 (Phase 3) が成り立たなくなる。

  PowerToDensity で 1 Hz あたりに直せば、分散 sigma^2 の白色雑音は
  窓にも FFT 長にも依らず 2*sigma^2/Fs になる。それをここで確かめる。
  この性質が無いと、この上に雑音推定は建てられない。
  -------------------------------------------------------------------------- }
{ 窓の ENBW が理論値ちょうどか、しかも FFT 長に依らないか。
  理論値は Σw^2/N を (Σw/N)^2 で割ったもの。余弦の項は二乗和が 1/2 に
  なるので、係数から手で出せる (例: Hann は 0.375/0.25 = 1.5)。 }
procedure CheckEnbw(AWin: TSpectrumWindow; AMeanSq: Double);
const
  DC: array[TSpectrumWindow] of Double = (1.0, 0.5, 0.54, 0.42);
var
  a, b: TSpectrumService;
  want: Double;
begin
  want := AMeanSq / (DC[AWin] * DC[AWin]);
  a := TSpectrumService.Create(1024, RATE, 0, AWin, 4);
  b := TSpectrumService.Create(8192, RATE, 0, AWin, 4);
  try
    WriteLn(Format('        %-10s ENBW 理論 %.6f / 1024点 %.6f / 8192点 %.6f',
      [SpectrumWindowName(AWin), want, a.NoiseBandwidthBins,
       b.NoiseBandwidthBins]));
    Check((Abs(a.NoiseBandwidthBins - want) < 1E-12) and
          (Abs(b.NoiseBandwidthBins - want) < 1E-12),
      Format('**%s の ENBW が理論値ちょうど・FFT 長に依らない**',
        [SpectrumWindowName(AWin)]));
  finally
    a.Free; b.Free;
  end;
end;

procedure TestNoiseDensityIsInvariant;
const
  SIGMA = 0.1;
  NSAMP = 65536;
type
  TCase = record
    Name: string;
    Fft: Integer;
    Win: TSpectrumWindow;
  end;
const
  CASES: array[0..3] of TCase = (
    (Name: 'Hann  1024';     Fft: 1024; Win: swHann),
    (Name: 'Hann  4096';     Fft: 4096; Win: swHann),
    (Name: 'Blackman 1024';  Fft: 1024; Win: swBlackman),
    (Name: '矩形 1024';      Fft: 1024; Win: swRectangular)
  );
var
  s: TSpectrumService;
  rd: TSpectrumReader;
  noise, bins: array of Double;
  info: TSpectrumFrameInfo;
  rnd: TVectorRandom;
  dens: array[0..High(CASES)] of Double;
  c, i, lo, hi, frames: Integer;
  r: TSpectrumReadResult;
  sum, want, worst, ratio: Double;
begin
  WriteLn;
  WriteLn('--- 4. 雑音の床が窓と FFT 長に依らないこと (Phase 3 の下地) ---');

  { 同じ雑音を全員に聞かせる。系統の Random ではなく試験用の PRNG を
    使うので、いつ回しても同じ波形になる (Z-05)。 }
  rnd.Seed(20260904);
  SetLength(noise, NSAMP);
  for i := 0 to NSAMP - 1 do
    noise[i] := SIGMA * rnd.NextGauss;

  { 白色雑音の片側電力密度は 2*sigma^2/Fs。 }
  want := 2 * SIGMA * SIGMA / RATE;

  for c := 0 to High(CASES) do
  begin
    s := TSpectrumService.Create(CASES[c].Fft, RATE, 0, CASES[c].Win, CAP_ENOUGH);
    try
      SetLength(bins, s.BinCount);
      rd := s.NewReader;
      s.Feed(noise, Length(noise));

      { 端は避ける。直流付近と折り返し付近は片側化の扱いが違う。 }
      lo := s.BinCount div 10;
      hi := s.BinCount - s.BinCount div 10;
      sum := 0; frames := 0;
      repeat
        r := s.TryRead(rd, bins, info);
        if r = srOk then
        begin
          Inc(frames);
          for i := lo to hi - 1 do
            sum := sum + s.PowerToDensity(bins[i]);
        end;
      until r = srNoData;
      Check(frames > 0, Format('前提: %s で枠が出た (%d 枠)',
        [CASES[c].Name, frames]));
      dens[c] := sum / (frames * (hi - lo));
      WriteLn(Format('        %-14s ENBW %.4f bin / 密度 %.4g (理論比 %.4f)',
        [CASES[c].Name, s.NoiseBandwidthBins, dens[c], dens[c] / want]));
    finally
      s.Free;
    end;
  end;

  { ENBW が教科書の値ちょうどになること。
    周期形の窓なら FFT 長に依らない定数になる —— **1024 と 8192 で同じ値**
    であることまで見る。ここがずれると Noise Estimator の較正がずれる。 }
  CheckEnbw(swRectangular, 1.0);
  CheckEnbw(swHann,        0.5 * 0.5 + 0.5 * (0.5 * 0.5));
  CheckEnbw(swHamming,     0.54 * 0.54 + 0.5 * (0.46 * 0.46));
  CheckEnbw(swBlackman,    0.42 * 0.42 + 0.5 * (0.5 * 0.5 + 0.08 * 0.08));

  { どの設定でも理論値に載っていること。 }
  worst := 0;
  for c := 0 to High(CASES) do
  begin
    ratio := Abs(dens[c] / want - 1.0);
    if ratio > worst then worst := ratio;
  end;
  WriteLn(Format('        理論値からの最大ずれ %.2f %%', [worst * 100]));
  Check(worst < 0.05,
    '**窓と FFT 長を変えても雑音密度が理論値 2*sigma^2/Fs に載る**');

  { 互いのずれ。ここが揃わないと「窓を替えたら雑音が増えた」ことになる。 }
  worst := 0;
  for c := 1 to High(CASES) do
  begin
    ratio := Abs(dens[c] / dens[0] - 1.0);
    if ratio > worst then worst := ratio;
  end;
  WriteLn(Format('        設定どうしの最大ずれ %.2f %%', [worst * 100]));
  Check(worst < 0.05,
    '**設定を替えても雑音床が動かない** (Noise Estimator を較正できる)');
end;

{ --------------------------------------------------------------------------
  5. 同じ音から同じスペクトル (Z-05)
  -------------------------------------------------------------------------- }
procedure TestDeterminism;
var
  s: TSpectrumService;
  rd: TSpectrumReader;
  bins: array of Double;
  info: TSpectrumFrameInfo;
  sig: array[0..3] of string;
  k, i: Integer;
  allSame: Boolean;
begin
  WriteLn;
  WriteLn('--- 5. 同じ音から同じスペクトル (Z-05) ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
  try
    SetLength(bins, s.BinCount);
    for k := 0 to 3 do
    begin
      s.Reset;
      rd := s.NewReader;
      FeedTone(s, 1234.0, 0.3, FFTN * 2);
      sig[k] := '';
      while s.TryRead(rd, bins, info) = srOk do
        for i := 0 to 20 do
          sig[k] := sig[k] + Format('%.12g;', [bins[i * 17]]);
    end;
    Check(sig[0] <> '', '前提: 一度目に枠が出た');
    allSame := True;
    for k := 1 to 3 do
      if sig[k] <> sig[0] then allSame := False;
    Check(allSame, '**4 回流しても値が完全に一致する**');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 複数の読み手 (Phase 3 の Algorithm Portfolio)
  -------------------------------------------------------------------------- }
procedure TestMultipleReaders;
const
  N = 4;
var
  s: TSpectrumService;
  rd: array[0..N-1] of TSpectrumReader;
  bins: array of Double;
  info: TSpectrumFrameInfo;
  sums: array[0..N-1] of Double;
  counts: array[0..N-1] of Integer;
  k, i: Integer;
  same: Boolean;
begin
  WriteLn;
  WriteLn('--- 6. 複数の読み手が全員同じ枠を得ること ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, 32);
  try
    SetLength(bins, s.BinCount);
    for k := 0 to N - 1 do
    begin
      rd[k] := s.NewReader;
      sums[k] := 0;
      counts[k] := 0;
    end;

    FeedTone(s, 900.0, 0.25, FFTN * 6);

    for k := 0 to N - 1 do
      while s.TryRead(rd[k], bins, info) = srOk do
      begin
        Inc(counts[k]);
        for i := 0 to s.BinCount - 1 do
          sums[k] := sums[k] + bins[i];
      end;

    WriteLn(Format('        各読み手が受け取った枠数: %d %d %d %d',
      [counts[0], counts[1], counts[2], counts[3]]));
    same := True;
    for k := 1 to N - 1 do
      if (counts[k] <> counts[0]) or (Abs(sums[k] - sums[0]) > 1E-12) then
        same := False;
    Check(counts[0] > 0, '前提: 枠が出た');
    Check(same, '**4 人の読み手が全員同じ枠を同じ値で受け取る**');
    { 一度だけ計算していること: 読み手が 4 人でも枠数は変わらない。 }
    CheckEqI(counts[0], s.FramesProduced,
      '読み手が何人いても計算は 1 回 (枠数が読み手数に依らない)');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 遅れた読み手は「飛ばした」ことを知る

  ここが黙って飛ばす作りだと、統計を取る側は**自分が偏っていることに
  気づけない**。表示だけなら困らないので、見落とされやすい。
  -------------------------------------------------------------------------- }
procedure TestSlowReaderIsTold;
var
  s: TSpectrumService;
  rd: TSpectrumReader;
  bins: array of Double;
  info: TSpectrumFrameInfo;
  r: TSpectrumReadResult;
  got, missedTotal: Int64;
begin
  WriteLn;
  WriteLn('--- 7. 遅れた読み手への申告 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, 4);   { 4 枠しか持たない }
  try
    SetLength(bins, s.BinCount);
    rd := s.NewReader;

    { 読まずに 20 枠ぶん流し込む。輪は 4 枠しかないので追い越される。 }
    FeedTone(s, 700.0, 0.3, FFTN div 4 * 24);
    WriteLn(Format('        作った枠 %d / 保持できる枠 %d',
      [s.FramesProduced, s.FrameCapacity]));
    Check(s.FramesProduced > s.FrameCapacity, '前提: 輪を追い越した');

    r := s.TryRead(rd, bins, info);
    Check(r = srMissed, '**追い越されたら srMissed を返す**');
    Check(info.MissedFrames > 0,
      Format('**何枠飛ばしたかを言う** (%d 枠)', [info.MissedFrames]));
    WriteLn('        ', info.Describe);
    missedTotal := info.MissedFrames;

    { 申告のあとは最古の生存枠から続けて読める。 }
    got := 0;
    while s.TryRead(rd, bins, info) = srOk do
      Inc(got);
    WriteLn(Format('        申告のあと %d 枠を読めた', [got]));
    Check(got > 0, '申告のあとは読み進められる (止まらない)');
    CheckEqI(missedTotal + got, s.FramesProduced,
      '**飛ばした数 + 読めた数 = 作った数** (勘定が合う)');

    { 追いついたら srNoData。 }
    Check(s.TryRead(rd, bins, info) = srNoData, '追いついたら srNoData');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 流し直しを黙って隠さないこと (X-06 Replay)

  Reset は通し番号を 0 に戻す。前の流れの位置を持ったままの読み手は、
  **何も返されないまま待ち続け**、新しい流れが元の位置を追い越した瞬間に
  何事もなかったように途中から読み始める。統計を溜めている側にとっては
  これが最悪で、二つの録音が混ざったまま気づけない。

  Replay Decode (X-06) は「同じ音をもう一度流す」機能そのものなので、
  この経路は必ず通る。だから世代を持ち、srReset で知らせる。
  -------------------------------------------------------------------------- }
procedure TestResetIsAnnounced;
var
  s: TSpectrumService;
  rd, fresh: TSpectrumReader;
  bins: array of Double;
  info: TSpectrumFrameInfo;
  r: TSpectrumReadResult;
  before, after: Integer;
  missed: Int64;
begin
  WriteLn;
  WriteLn('--- 8. 流し直しを黙って隠さないこと (X-06) ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
  try
    SetLength(bins, s.BinCount);
    rd := s.NewReader;
    FeedTone(s, 1000, 0.3, FFTN * 3);
    before := DrainFrames(s, rd, bins, missed);
    Check((before > 0) and (missed = 0),
      Format('前提: 一度目に %d 枠を読んだ', [before]));

    { ここで流し直す。読み手はまだ古い流れの位置を持っている。 }
    s.Reset;
    FeedTone(s, 1000, 0.3, FFTN * 3);

    r := s.TryRead(rd, bins, info);
    Check(r = srReset,
      Format('**流し直したら srReset を返す** (実際 %s)',
        [SpectrumReadResultName(r)]));

    { 知らせたあとは、新しい流れの先頭から読み進められる。 }
    after := DrainFrames(s, rd, bins, missed);
    WriteLn(Format('        流し直しのあと %d 枠を読めた (一度目は %d 枠)',
      [after, before]));
    CheckEqI(after, before, '**知らせたあとは新しい流れを先頭から全部読める**');

    { 二度目は言わない。言い続けると読み手が進めなくなる。 }
    Check(s.TryRead(rd, bins, info) = srNoData,
      'srReset は一度だけ (以後は普通に読める)');

    { 流し直しのあとに作った読み手は、そもそも知らされない。 }
    s.Reset;
    fresh := s.NewReader;
    FeedTone(s, 1000, 0.3, FFTN * 2);
    r := s.TryRead(fresh, bins, info);
    Check(r = srOk, '流し直しのあとに開いた読み手には知らせない (無関係)');

    { 零で埋めただけの読み手は、読み進める前に必ず srReset を受け取る。
      世代 0 はどの流れとも一致しないので、初期化し忘れが
      **黙って過去を読む**事故にならない。 }
    FillChar(fresh, SizeOf(fresh), 0);
    Check(s.TryRead(fresh, bins, info) = srReset,
      '**初期化していない読み手は黙って読まず srReset になる**');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. 二つの使い方が両立すること

  Waterfall は最新だけ見たい。Noise Estimator は全枠が要る。
  同じサービスから同時に、それぞれのやり方で取れること。
  -------------------------------------------------------------------------- }
procedure TestTwoUsagePatterns;
var
  s: TSpectrumService;
  wf, ne: TSpectrumReader;
  bins: array of Double;
  info: TSpectrumFrameInfo;
  r: TSpectrumReadResult;
  neCount, wfCount, k: Integer;
  neMissed: Int64;
begin
  WriteLn;
  WriteLn('--- 9. Waterfall 型と Noise Estimator 型の併存 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, 8);
  try
    SetLength(bins, s.BinCount);
    wf := s.NewReader;
    ne := s.NewReader;
    neCount := 0; wfCount := 0; neMissed := 0;

    { 少しずつ流しながら、Noise Estimator は毎回すべて読み、
      Waterfall は 3 回に 1 回しか読まない (表示の間引き)。 }
    for k := 1 to 12 do
    begin
      FeedTone(s, 1500.0, 0.2, FFTN div 4 * 2, k * 0.1);

      repeat
        r := s.TryRead(ne, bins, info);
        if r = srOk then Inc(neCount);
        if r = srMissed then neMissed := neMissed + info.MissedFrames;
      until r = srNoData;

      if (k mod 3) = 0 then
      begin
        repeat
          r := s.TryRead(wf, bins, info);
          if r = srOk then Inc(wfCount);
        until r = srNoData;
      end;
    end;

    WriteLn(Format('        作った枠 %d / 推定側 %d 枠 (飛ばし %d) / 表示側 %d 枠',
      [s.FramesProduced, neCount, neMissed, wfCount]));
    CheckEqI(neCount, s.FramesProduced,
      '**毎回読む側は 1 枠も取りこぼさない** (統計が偏らない)');
    CheckEqI(neMissed, 0, '毎回読む側に飛ばしは起きない');
    Check(wfCount > 0, '間引いて読む側も枠を得られる');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  10. FFT の係数表を共有していること (X-05「資源の重複を無くす」)
  -------------------------------------------------------------------------- }
procedure TestPlanIsShared;
var
  a, b, c: TSpectrumService;
  before, after: Integer;
  bins: array of Double;
  rd: TSpectrumReader;
  missed: Int64;
begin
  WriteLn;
  WriteLn('--- 10. FFT の係数表を共有していること (X-05) ---');
  { 先に 1 つ作って回し、その長さのプランを確保させる。 }
  a := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
  try
    SetLength(bins, a.BinCount);
    rd := a.NewReader;
    FeedTone(a, 1000, 0.3, FFTN * 2);
    DrainFrames(a, rd, bins, missed);
    before := SharedFftPlanCount;

    { 同じ長さのサービスを 2 つ増やして回す。 }
    b := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
    c := TSpectrumService.Create(FFTN, RATE, 0, swBlackman, CAP_ENOUGH);
    try
      rd := b.NewReader;
      FeedTone(b, 1000, 0.3, FFTN * 2);
      DrainFrames(b, rd, bins, missed);
      rd := c.NewReader;
      FeedTone(c, 1000, 0.3, FFTN * 2);
      DrainFrames(c, rd, bins, missed);
      after := SharedFftPlanCount;
    finally
      b.Free; c.Free;
    end;

    WriteLn(Format('        プラン数 %d -> %d (サービスを 2 つ増やした)',
      [before, after]));
    CheckEqI(after, before,
      '**サービスを増やしても係数表は増えない** (共有できている)');
  finally
    a.Free;
  end;
end;

{ --------------------------------------------------------------------------
  11. 音を入れる経路で確保しないこと (X-04)
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
  s: TSpectrumService;
  buf, bins: array of Double;
  rd: TSpectrumReader;
  info: TSpectrumFrameInfo;
  i, n, k: Integer;
  mm: TMemoryManager;
begin
  WriteLn;
  WriteLn('--- 11. 音を入れる経路で確保しないこと (X-04) ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, 16);
  try
    SetLength(bins, s.BinCount);
    SetLength(buf, 512);
    for i := 0 to High(buf) do
      buf[i] := 0.3 * Sin(2 * Pi * 1000 * i / RATE);
    s.Feed(buf, Length(buf));   { 初回を済ませる }
    rd := s.NewReader;

    GAllocCount := 0;
    GetMemoryManager(GOldMM);
    mm := GOldMM;
    mm.GetMem := @CountingGetMem;
    mm.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(mm);
    GCounting := True;
    try
      for k := 1 to 200 do
      begin
        s.Feed(buf, Length(buf));
        while s.TryRead(rd, bins, info) = srOk do ;
      end;
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0,
      Format('%d サンプル投入と読み出しで確保 0 回 (実測 %d)',
        [200 * 512, n]));
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  12. Event Bus に載せていないこと (ARC-001 / §5.1)

  Spectrum は Data Plane のものである。Event Bus は状態変化・制御・結果通知
  のための経路で、毎秒何十枠も流れるものを載せると復号文字を押し出す。
  -------------------------------------------------------------------------- }
procedure TestNotOnEventBus;
var
  s: TSpectrumService;
  bus: TEventBus;
  before, after, missed: Int64;
  bins: array of Double;
  rd: TSpectrumReader;
begin
  WriteLn;
  WriteLn('--- 12. Event Bus に載せていないこと (ARC-001) ---');
  bus := TEventBus.Create;
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP_ENOUGH);
  try
    SetLength(bins, s.BinCount);
    before := bus.PublishedCount;
    rd := s.NewReader;
    FeedTone(s, 1000, 0.3, FFTN * 4);
    DrainFrames(s, rd, bins, missed);
    after := bus.PublishedCount;
    WriteLn(Format('        枠を %d 作った間の Event Bus 発行数 %d -> %d',
      [s.FramesProduced, before, after]));
    CheckEqI(after, before,
      '**スペクトルを作っても Event Bus に何も流れない**');
  finally
    s.Free;
    bus.Free;
  end;
end;

begin
  WriteLn('=== 共有スペクトルサービス (X-05) の試験 ===');

  TestParameters;
  TestKnownTone;
  TestTwoTones;
  TestNoiseDensityIsInvariant;
  TestDeterminism;
  TestMultipleReaders;
  TestSlowReaderIsTold;
  TestResetIsAnnounced;
  TestTwoUsagePatterns;
  TestPlanIsShared;
  TestNoAllocation;
  TestNotOnEventBus;

  if FailCount = 0 then
    CoverReq('SPC-001');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
