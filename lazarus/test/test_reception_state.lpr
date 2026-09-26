{ ============================================================================
  test_reception_state.lpr

  受信状態推定の共有サービスの試験 (units/ReceptionState.pas。§6.1 / SPC-003)。

  何を守るか
  ----------------------------------------------------------------------------
  1. NoiseEstimator が測れていなければ SNR / NoiseFloor は「まだ」と言う
  2. 測れていれば、共有の NoiseEstimator の値をそのまま映す (二重測定しない)
  3. SNR は帯域を渡すまで測れない
  4. Frequency offset は Evidence 経由で入り、ならされる
     (雑音の1文字ぶんの揺らぎで跳ねない)
  5. HasFreqOffset が立っていない Evidence は無視する (0 を混ぜない)
  6. Reset は周波数のならしだけを捨て、共有の NoiseEstimator には触れない
  7. 実装していない 6 項目 (QSB/QRM/Impulse/Timing/Distortion/Fading) は
     常に Has*=False
  8. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05)

  4 と 5 が対になっている。ならすだけなら「HasFreqOffset=False の Evidence を
  0 として混ぜてもならされて消えるはず」と誤解しやすいが、それでは
  「測っていない」と「測って 0 だった」が区別できなくなる。無視することで
  区別を保つ。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_reception_state;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, SpectrumService, NoiseEstimator, DecodeEvidence,
  ReceptionState, TestVectors, Requirements;

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

{ HasFreqOffset だけを立てた最小の Evidence を作る。 }
function FreqEvidence(AHz: Double): TDecodeEvidence;
begin
  Result := SingleCandidateEvidence(Ord('X'), 'test');
  Result.HasFreqOffset := True;
  Result.FreqOffsetHz := AHz;
end;

{ 周波数情報を持たない Evidence (CW のような復調器を想定)。 }
function NoFreqEvidence: TDecodeEvidence;
begin
  Result := SingleCandidateEvidence(Ord('X'), 'test');
  { HasFreqOffset は既定で False (SingleCandidateEvidence が立てる)。 }
end;

{ 雑音床を実際に測れる状態にする。ne.Ready が True になるまで
  白色雑音を流す (test_noise の RunNoise と同じ考え方)。 }
procedure MakeReady(sp: TSpectrumService; ne: TNoiseEstimator; ASeed: QWord);
var
  buf: array of Double;
  rnd: TVectorRandom;
  info: TNoiseUpdateInfo;
  i, n: Integer;
begin
  rnd.Seed(ASeed);
  SetLength(buf, HOP);
  for n := 1 to 20 do
  begin
    for i := 0 to HOP - 1 do buf[i] := 0.3 * rnd.NextGauss;
    sp.Feed(buf, HOP);
    ne.Update(info);
  end;
end;

{ --------------------------------------------------------------------------
  1-3. NoiseFloor / SNR: 未測定の申告、共有値をそのまま映す、帯域の要否
  -------------------------------------------------------------------------- }
procedure TestNoiseFloorAndSnr;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  st: TReceptionState;
begin
  WriteLn;
  WriteLn('--- 1-3. NoiseFloor / SNR ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    st := rs.State;
    Check(not st.HasNoiseFloor,
      '**雑音床がまだ測れていなければ NoiseFloor は「まだ」**');
    Check(not st.HasSnr, '同じ理由で SNR も「まだ」');

    MakeReady(sp, ne, 111);
    st := rs.State;
    Check(st.HasNoiseFloor, '雑音床が測れたら NoiseFloor が立つ');
    Check(Abs(st.NoiseFloorDb - ne.NoiseDensityDb) < 1E-9,
      '**共有の NoiseEstimator の値をそのまま映す** (二重に測らない)');

    Check(not st.HasSnr,
      '雑音床が測れていても **帯域を渡すまで SNR は測れない**');

    rs.SetBand(900, 1100);
    st := rs.State;
    Check(st.HasSnr, '帯域を渡したら SNR が測れる');
    Check(Abs(st.SnrDb - ne.SnrInBandDb(900, 1100)) < 1E-9,
      '**SNR も共有の NoiseEstimator の計算をそのまま使う**');
  finally
    rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4-5. Frequency offset: Evidence 経由・ならし・無視
  -------------------------------------------------------------------------- }
procedure TestFreqOffset;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  st: TReceptionState;
  i: Integer;
  beforeIgnored: Double;
begin
  WriteLn;
  WriteLn('--- 4-5. Frequency offset ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    st := rs.State;
    Check(not st.HasFreqOffset,
      'Evidence が 1 件も来ていなければ「まだ」');

    rs.ObserveEvidence(FreqEvidence(10.0));
    st := rs.State;
    Check(st.HasFreqOffset, '1 件でも来れば立つ');
    Check(Abs(st.FreqOffsetHz - 10.0) < 1E-9,
      '**最初の 1 件はならさずそのまま基準にする** (0 から引きずらない)');

    { 雑音で 1 回だけ大きく跳ねても、ならしが吸収する。 }
    rs.ObserveEvidence(FreqEvidence(10.0));
    rs.ObserveEvidence(FreqEvidence(10.0));
    rs.ObserveEvidence(FreqEvidence(10.0));
    rs.ObserveEvidence(FreqEvidence(100.0));  { 雑音で跳ねた 1 件 }
    st := rs.State;
    Check(Abs(st.FreqOffsetHz - 10.0) > 0.01, '跳ねた 1 件で少しは動く');
    Check(st.FreqOffsetHz < 30.0, Format(
      '**1 件の跳ねでは大きく動かない** (ならされている。実際 %.2f Hz)',
      [st.FreqOffsetHz]));

    { HasFreqOffset が立っていない Evidence は無視する。

      **多めに流す。** ならしの重み (既定 20) では、無視せず 0 へ混ぜても
      10 回程度では 8.7 Hz 止まりで、しきい値を甘くすると見分けが付かない
      (実測して気づいた ―― 最初 10 回・しきい値 >5.0 で書いたら、無視を
      外した改竄が検出できなかった)。100 回流せば、無視せず混ぜた場合は
      0.09 Hz まで落ちる。無視できていれば **一切動かない** はずなので、
      しきい値ではなく直前の値との厳密一致で見る。 }
    st := rs.State;
    Check(st.HasFreqOffset, '前提: 直前の値を憶えている');
    beforeIgnored := st.FreqOffsetHz;
    for i := 1 to 100 do rs.ObserveEvidence(NoFreqEvidence);
    Check(rs.FreqIgnored = 100, '無視した回数を数えている');
    st := rs.State;
    Check(st.FreqOffsetHz = beforeIgnored, Format(
      '**周波数情報の無い Evidence は無視され、値が一切動かない** ' +
      '(直前 %.4f Hz -> 100 件無視後 %.4f Hz)', [beforeIgnored, st.FreqOffsetHz]));
  finally
    rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. Reset は周波数のならしだけを捨てる
  -------------------------------------------------------------------------- }
procedure TestResetScopedToFreqOnly;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  st: TReceptionState;
begin
  WriteLn;
  WriteLn('--- 6. Reset の範囲 ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    MakeReady(sp, ne, 222);
    rs.SetBand(900, 1100);
    rs.ObserveEvidence(FreqEvidence(42.0));

    rs.Reset;
    st := rs.State;
    Check(not st.HasFreqOffset, '**Reset は周波数のならしを捨てる**');
    Check(rs.FreqObservations = 0, '観測回数も 0 に戻る');

    Check(st.HasNoiseFloor,
      '**共有の NoiseEstimator には触れない** (雑音床は測れたまま)');
    Check(st.HasSnr,
      '帯域の設定も Reset をまたいで残る (聞いているモードは変わっていない)');
  finally
    rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 実装していない項目は常に Has*=False
  -------------------------------------------------------------------------- }
procedure TestUnimplementedFieldsStayFalse;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  st: TReceptionState;
begin
  WriteLn;
  WriteLn('--- 7. 未実装の項目 ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    MakeReady(sp, ne, 333);
    rs.SetBand(900, 1100);
    rs.ObserveEvidence(FreqEvidence(5.0));
    st := rs.State;

    { 測れる 3 項目はすべて立っている前提。ここが崩れていたら
      以下の「立っていない」確認そのものが無意味になる。 }
    Check(st.HasNoiseFloor and st.HasSnr and st.HasFreqOffset,
      '前提: 測れる 3 項目は立っている');

    Check(not st.HasQsb, '**QSB は未実装 (Has=False のまま)**');
    Check(not st.HasQrm, '**QRM は未実装**');
    Check(not st.HasImpulseNoise, '**Impulse noise は未実装**');
    Check(not st.HasTimingError, '**Timing error は未実装**');
    Check(not st.HasDistortion, '**Distortion は未実装**');
    Check(not st.HasSelectiveFading, '**Selective fading は未実装**');

    WriteLn('    ', st.Describe);
  finally
    rs.Free; ne.Free; sp.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 確保しない (X-04) / 決定性 (Z-05)
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
  st: TReceptionState;
  rnd: TVectorRandom;
  evs: array[0..49] of TDecodeEvidence;
  i, n, alloc: Integer;
  off1, off2: Double;
begin
  WriteLn;
  WriteLn('--- 8. 確保しない (X-04) / 決定性 (Z-05) ---');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    MakeReady(sp, ne, 444);
    rs.SetBand(900, 1100);
    rs.ObserveEvidence(FreqEvidence(3.0));

    { Evidence は計測窓の**外**で作る。SingleCandidateEvidence が
      Candidates 配列を確保するのは Evidence を組み立てる側の性質で、
      ReceptionState.ObserveEvidence 自身の性質ではない。ここで測りたいのは
      「受け取った Evidence を処理するときに確保するか」であって、
      「Evidence を作るときに確保するか」ではない。混ぜると、
      関係の無い理由で X-04 の主張が落ちる (あるいは、ここで確保しない
      よう作り替えると本来の目的とは違う変更になる)。 }
    rnd.Seed(9);
    for n := 0 to High(evs) do
      evs[n] := FreqEvidence(3.0 + 0.1 * rnd.NextGauss);

    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for n := 0 to High(evs) do
      begin
        rs.ObserveEvidence(evs[n]);
        st := rs.State;
      end;
      alloc := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(alloc, 0,
      Format('50 回の観測+読み出しで確保 0 回 (実測 %d)', [alloc]));
  finally
    rs.Free; ne.Free; sp.Free;
  end;

  { 同じ入力から同じ結果 (Z-05)。 }
  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    MakeReady(sp, ne, 555);
    rs.SetBand(900, 1100);
    for i := 1 to 5 do rs.ObserveEvidence(FreqEvidence(7.0 + i));
    off1 := rs.State.FreqOffsetHz;
  finally
    rs.Free; ne.Free; sp.Free;
  end;
  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  rs := TReceptionStateEstimator.Create(ne);
  try
    MakeReady(sp, ne, 555);
    rs.SetBand(900, 1100);
    for i := 1 to 5 do rs.ObserveEvidence(FreqEvidence(7.0 + i));
    off2 := rs.State.FreqOffsetHz;
  finally
    rs.Free; ne.Free; sp.Free;
  end;
  Check(off1 = off2, '**同じ入力から同じ結果** (Z-05)');
end;

{ --------------------------------------------------------------------------
  境界: 構築時の検査
  -------------------------------------------------------------------------- }
procedure TestGuards;
var
  sp: TSpectrumService;
  ne: TNoiseEstimator;
  rs: TReceptionStateEstimator;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 境界の検査 ---');

  raised := False;
  try
    rs := TReceptionStateEstimator.Create(nil);
    rs.Free;
  except
    on EReceptionStateError do raised := True;
  end;
  Check(raised, 'nil の NoiseEstimator を撥ねる');

  sp := TSpectrumService.Create(FFT, SR, HOP, swHann);
  ne := TNoiseEstimator.Create(sp);
  try
    raised := False;
    try
      rs := TReceptionStateEstimator.Create(ne, 0);
      rs.Free;
    except
      on EReceptionStateError do raised := True;
    end;
    Check(raised, 'ならし段数 0 を撥ねる');

    rs := TReceptionStateEstimator.Create(ne);
    try
      raised := False;
      try
        rs.SetBand(1100, 900);
      except
        on EReceptionStateError do raised := True;
      end;
      Check(raised, '帯域の上下が逆なら撥ねる');
    finally
      rs.Free;
    end;
  finally
    ne.Free; sp.Free;
  end;
end;

begin
  WriteLn('=== 受信状態推定の共有サービスの試験 (SPC-003) ===');

  TestGuards;
  TestNoiseFloorAndSnr;
  TestFreqOffset;
  TestResetScopedToFreqOnly;
  TestUnimplementedFieldsStayFalse;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('SPC-003');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
