{ ============================================================================
  test_adaptive_squelch.lpr

  雑音床から自動的にしきい値を決めるスケルチの試験
  (units/AdaptiveSquelch.pas。§12 Phase 3 Adaptive Squelch / MDM-015)。

  何を守るか
  ----------------------------------------------------------------------------
  1. 帯域 S/N が測れていなければ開けたままにする (fail-open)
  2. マージンが 0 以下なら常にスケルチなし (PSK の Squelch と同じ約束)
  3. 雑音のみでは実測上ほぼ確実に閉じている (既定マージン 3 dB の裏づけ)
  4. 復号の見込みがある S/N (既定マージンの少し上) では開く
  5. **雑音床が変わっても、同じマージンのまま追随する** (適応的の中身)
  6. Reset は診断用の回数だけを捨て、判断そのものは変えない
  7. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05)

  3 と 5 が対になっている。3 は「いまの雑音床に対して正しいマージンか」、
  5 は「雑音床が動いたときにも同じマージンで正しく動くか」―― 5 が無いと、
  たまたま今の雑音床でだけ正しいマージンを選んでいないかを見落とす。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_adaptive_squelch;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, SpectrumService, NoiseEstimator, DecodeEvidence,
  ReceptionState, AdaptiveSquelch, TestVectors, Requirements;

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
  FFT = 4096;
  BANDLO = 900;
  BANDHI = 1100;
  { 帯域幅 [Hz] とベース雑音の分散 (0.3^2) から、指定した真の帯域内
    S/N [dB] を再現する正弦振幅を求める。probe で使った式と同じ。
    NoiseDensity 理論値 = 2*sigma^2/Fs (SPC-002 と同じ式)。 }
  BASE_SIGMA = 0.3;

function SignalAmpForSnr(ATrueSnrDb: Double): Double;
var
  snrLin, density, noisePower: Double;
begin
  snrLin := Power(10, ATrueSnrDb / 10);
  density := 2 * Sqr(BASE_SIGMA) / SR;
  noisePower := density * (BANDHI - BANDLO);
  Result := Sqrt(2 * snrLin * noisePower);
end;

{ 雑音床を測れる状態にする (白色雑音のみ)。 }
procedure Warmup(sp: TSpectrumService; ne: TNoiseEstimator; var rnd: TVectorRandom);
var
  buf: array of Double;
  info: TNoiseUpdateInfo;
  i, n: Integer;
begin
  SetLength(buf, HOP);
  for n := 1 to 30 do
  begin
    for i := 0 to HOP - 1 do buf[i] := BASE_SIGMA * rnd.NextGauss;
    sp.Feed(buf, HOP);
    ne.Update(info);
  end;
end;

{ --------------------------------------------------------------------------
  1-2. fail-open と マージン<=0
  -------------------------------------------------------------------------- }
procedure TestFailOpenAndNoMargin;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  sq: TAdaptiveSquelch;
  rnd: TVectorRandom;
begin
  WriteLn;
  WriteLn('--- 1-2. fail-open / マージン<=0 ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  sq := TAdaptiveSquelch.Create(rs);
  try
    Check(not rs.State.HasSnr, '前提: まだ帯域 S/N は測れていない');
    Check(sq.IsOpen, '**測れていなければ開けたままにする (fail-open)**');
    CheckEqI(sq.UnknownCount, 1, 'fail-open の回数を数えている');

    { **ここで実際に雑音床を測れる状態にする。** そうしないと、この先の
      「マージン<=0」の確認が fail-open 側を通っただけの自明な主張に
      なってしまう ―― 実際そう書いていて、fail-open を外す改竄では
      落ちるのにマージン<=0 の分岐を外す改竄では落ちなかった。
      帯域 S/N が雑音のみでマージンを明確に下回る (雑音のみは
      ほぼ確実に 0dB を超えない。試験 3 の実測を参照) 状態を作ってから
      マージン<=0 を試す。 }
    rs.SetBand(BANDLO, BANDHI);
    rnd.Seed(31415);
    Warmup(sp, ne, rnd);
    Check(rs.State.HasSnr, '前提: 帯域 S/N が測れている');
    Check(rs.State.SnrDb < ADAPTIVE_SQUELCH_DEFAULT_MARGIN_DB,
      '前提: 雑音のみなので既定マージンより低い');

    sq.MarginDb := ADAPTIVE_SQUELCH_DEFAULT_MARGIN_DB;
    Check(not sq.IsOpen, '前提: 通常のマージンなら (雑音のみなので) 閉じる');

    sq.MarginDb := 0;
    Check(sq.IsOpen, '**マージン 0 は、雑音のみでも常時スケルチなし**');
    sq.MarginDb := -5;
    Check(sq.IsOpen, '負のマージンも同様にスケルチなし');
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. 雑音のみでは実測上ほぼ確実に閉じている
  -------------------------------------------------------------------------- }
procedure TestNoiseOnlyStaysClosed;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  sq: TAdaptiveSquelch;
  rnd: TVectorRandom;
  buf: array of Double;
  info: TNoiseUpdateInfo;
  i, n, falseTriggers: Integer;
const
  TRIALS = 2000;
begin
  WriteLn;
  WriteLn('--- 3. 雑音のみでは閉じている ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(777);
    Warmup(sp, ne, rnd);
    SetLength(buf, HOP);
    falseTriggers := 0;
    for n := 0 to TRIALS - 1 do
    begin
      for i := 0 to HOP - 1 do buf[i] := BASE_SIGMA * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
      if sq.IsOpen then Inc(falseTriggers);
    end;
    WriteLn(Format('    既定マージン %.1f dB / 雑音のみ %d 回中 誤って開いた回数 %d',
      [ADAPTIVE_SQUELCH_DEFAULT_MARGIN_DB, TRIALS, falseTriggers]));
    Check(falseTriggers = 0, Format(
      '**既定マージンでは雑音のみで一度も誤って開かない** (実測 %d/%d)',
      [falseTriggers, TRIALS]));
    CheckEqI(sq.ClosedCount, TRIALS - falseTriggers, '閉じた回数を数えている');
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 復号の見込みがある S/N では開く
  -------------------------------------------------------------------------- }
procedure TestOpensForRealSignal;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  sq: TAdaptiveSquelch;
  rnd: TVectorRandom;
  buf: array of Double;
  info: TNoiseUpdateInfo;
  i, n, opened: Integer;
  amp: Double;
const
  TRIALS = 200;
  TRUE_SNR_DB = 10.0;   { 十分に上、実測で誤差 1dB 未満と確認済みの帯 }
begin
  WriteLn;
  WriteLn('--- 4. 復号の見込みがある S/N では開く ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(4242);
    Warmup(sp, ne, rnd);
    amp := SignalAmpForSnr(TRUE_SNR_DB);
    SetLength(buf, HOP);
    opened := 0;
    for n := 0 to TRIALS - 1 do
    begin
      for i := 0 to HOP - 1 do
        buf[i] := BASE_SIGMA * rnd.NextGauss +
          amp * Sin(2 * Pi * 1000 * (n * HOP + i) / SR);
      sp.Feed(buf, HOP);
      ne.Update(info);
      if sq.IsOpen then Inc(opened);
    end;
    WriteLn(Format('    真の帯域内 S/N %.0f dB / %d 回中 開いた回数 %d',
      [TRUE_SNR_DB, TRIALS, opened]));
    Check(opened > TRIALS - 5, Format(
      '**復号の見込みがある S/N ではほぼ常に開く** (実測 %d/%d)',
      [opened, TRIALS]));
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 雑音床が変わっても同じマージンのまま追随する (適応的の中身)
  -------------------------------------------------------------------------- }
procedure TestTracksChangingNoiseFloor;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  sq: TAdaptiveSquelch;
  rnd: TVectorRandom;
  buf: array of Double;
  info: TNoiseUpdateInfo;
  i, n, falseTriggersLoud, opened: Integer;
  amp: Double;
const
  LOUD_SIGMA = 3.0;     { 元の 10 倍。夜間の混雑帯を想定 }
  TRIALS = 500;
  TRUE_SNR_DB = 10.0;
begin
  WriteLn;
  WriteLn('--- 5. 雑音床が変わっても追随する ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(9999);
    { 最初は元の雑音床で慣らす。 }
    Warmup(sp, ne, rnd);
    Check(not sq.IsOpen, '前提: 元の雑音床では閉じている (信号なし)');

    { 雑音床が 10 倍 (+20dB) に上がる。慣らし直す。 }
    SetLength(buf, HOP);
    for n := 1 to 30 do
    begin
      for i := 0 to HOP - 1 do buf[i] := LOUD_SIGMA * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
    end;

    { 新しい (10倍高い) 雑音床のもとで、雑音のみなら閉じたまま
      ―― **固定の絶対しきい値だったら、ここで誤って開いてしまう**
      (元の雑音床基準では新しい雑音は "signal" に見えるほど大きい)。
      マージンは帯域 S/N (雑音床からの相対値) に掛けているので、
      雑音床そのものが上がっても閉じたままであるはずである。 }
    falseTriggersLoud := 0;
    for n := 0 to TRIALS - 1 do
    begin
      for i := 0 to HOP - 1 do buf[i] := LOUD_SIGMA * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
      if sq.IsOpen then Inc(falseTriggersLoud);
    end;
    WriteLn(Format('    雑音床 +20dB のもとで雑音のみ %d 回中 誤って開いた回数 %d',
      [TRIALS, falseTriggersLoud]));
    Check(falseTriggersLoud = 0, Format(
      '**雑音床が上がっても、同じマージンのまま雑音だけでは開かない** ' +
      '(実測 %d/%d)', [falseTriggersLoud, TRIALS]));

    { 新しい雑音床の上に、その雑音床から見て 10dB の信号を乗せると
      正しく開く ―― 絶対振幅は元の雑音床の基準では巨大だが、
      いま測っている雑音床から見れば「ふつうに復号できる帯」である。 }
    amp := LOUD_SIGMA / BASE_SIGMA * SignalAmpForSnr(TRUE_SNR_DB);
    opened := 0;
    for n := 0 to TRIALS - 1 do
    begin
      for i := 0 to HOP - 1 do
        buf[i] := LOUD_SIGMA * rnd.NextGauss +
          amp * Sin(2 * Pi * 1000 * (n * HOP + i) / SR);
      sp.Feed(buf, HOP);
      ne.Update(info);
      if sq.IsOpen then Inc(opened);
    end;
    WriteLn(Format('    雑音床 +20dB のもとで真の S/N %.0f dB の信号 %d 回中 ' +
      '開いた回数 %d', [TRUE_SNR_DB, TRIALS, opened]));
    Check(opened > TRIALS - 10, Format(
      '**新しい雑音床のもとでも、相対 S/N が十分なら開く** (実測 %d/%d)',
      [opened, TRIALS]));
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. Reset は診断用の回数だけを捨てる
  -------------------------------------------------------------------------- }
procedure TestResetOnlyClearsCounters;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  sq: TAdaptiveSquelch;
  rnd: TVectorRandom;
  buf: array of Double;
  info: TNoiseUpdateInfo;
  i: Integer;
  before, after: Boolean;
begin
  WriteLn;
  WriteLn('--- 6. Reset の範囲 ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(1);
    Warmup(sp, ne, rnd);
    SetLength(buf, HOP);
    for i := 0 to HOP - 1 do buf[i] := BASE_SIGMA * rnd.NextGauss;
    sp.Feed(buf, HOP);
    ne.Update(info);
    before := sq.IsOpen;

    sq.Reset;
    CheckEqI(sq.OpenCount, 0, 'Reset で開いた回数が 0 に戻る');
    CheckEqI(sq.ClosedCount, 0, 'Reset で閉じた回数が 0 に戻る');
    CheckEqI(sq.UnknownCount, 0, 'Reset で fail-open の回数も 0 に戻る');

    after := sq.IsOpen;
    Check(before = after, Format(
      '**Reset は判断そのものを変えない** (同じ入力なら同じ判断。%s -> %s)',
      [BoolToStr(before, 'open', 'closed'), BoolToStr(after, 'open', 'closed')]));
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 確保しない (X-04) / 決定性 (Z-05)
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
  rs: TReceptionStateEstimator;
  sq: TAdaptiveSquelch;
  rnd: TVectorRandom;
  buf: array of Double;
  info: TNoiseUpdateInfo;
  i, n, alloc: Integer;
  open1, open2: Integer;
begin
  WriteLn;
  WriteLn('--- 7. 確保しない (X-04) / 決定性 (Z-05) ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(55);
    Warmup(sp, ne, rnd);
    SetLength(buf, HOP);

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
        for i := 0 to HOP - 1 do buf[i] := BASE_SIGMA * rnd.NextGauss;
        sp.Feed(buf, HOP);
        ne.Update(info);
        sq.IsOpen;
      end;
      alloc := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(alloc, 0,
      Format('100 回の判定で確保 0 回 (実測 %d)', [alloc]));
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;

  { 同じ入力から同じ結果 (Z-05)。 }
  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(321);
    Warmup(sp, ne, rnd);
    SetLength(buf, HOP);
    open1 := 0;
    for n := 1 to 50 do
    begin
      for i := 0 to HOP - 1 do buf[i] := BASE_SIGMA * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
      if sq.IsOpen then Inc(open1);
    end;
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  rs.SetBand(BANDLO, BANDHI);
  sq := TAdaptiveSquelch.Create(rs);
  try
    rnd.Seed(321);
    Warmup(sp, ne, rnd);
    SetLength(buf, HOP);
    open2 := 0;
    for n := 1 to 50 do
    begin
      for i := 0 to HOP - 1 do buf[i] := BASE_SIGMA * rnd.NextGauss;
      sp.Feed(buf, HOP);
      ne.Update(info);
      if sq.IsOpen then Inc(open2);
    end;
  finally
    sq.Free; rs.Free; ne.Free; sp.Free;
  end;
  CheckEqI(open1, open2, '**同じ入力から同じ結果** (Z-05)');
end;

{ --------------------------------------------------------------------------
  境界: 構築時の検査
  -------------------------------------------------------------------------- }
procedure TestGuards;
var
  raised: Boolean;
  sq: TAdaptiveSquelch;
begin
  WriteLn;
  WriteLn('--- 境界の検査 ---');

  raised := False;
  try
    sq := TAdaptiveSquelch.Create(nil);
    sq.Free;
  except
    on EAdaptiveSquelchError do raised := True;
  end;
  Check(raised, 'nil の ReceptionStateEstimator を撥ねる');
end;

begin
  WriteLn('=== 適応スケルチの試験 (MDM-015) ===');

  TestGuards;
  TestFailOpenAndNoMargin;
  TestNoiseOnlyStaysClosed;
  TestOpensForRealSignal;
  TestTracksChangingNoiseFloor;
  TestResetOnlyClearsCounters;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('MDM-015');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
