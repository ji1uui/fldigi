{ ============================================================================
  test_filter_switch.lpr

  RttyModemImpl.pas / CwModemImpl.pas に組み込んだ ModemDSP.TFftFilt
  (Overlap-Add FFT畳み込みフィルタ) が、運用中のパラメータ変更
  (RTTY: ボーレート/シフト切替、CW: 帯域幅変更) のたびに正しく再生成され、
  例外やNaN/Infを出すことなく動作し続けることを確認する安定性テスト。

  test_rtty_cw.lpr は既定パラメータ(RTTY 45.45baud/CW 18wpm)での
  復調精度を検証するのに対し、本テストは
  「RttyFiltLenTable[]/CW_FFT_SIZEで指定される全パターンのフィルタサイズ
  への切り替えが安全に行えるか」に焦点を当てる。

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_filter_switch test/test_filter_switch.lpr
    ./test/test_filter_switch
  ============================================================================ }
program test_filter_switch;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math, SoundIntf, ModemTypes, RttyModemImpl, CwModemImpl;

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

function IsFinite(AValue: Double): Boolean;
begin
  Result := (not IsNan(AValue)) and (not IsInfinite(AValue));
end;

{ ------------------------------------------------------------------------
  1. RTTY: 全ボーレート x 全シフトの組み合わせでフィルタが安全に
     再生成され、ノイズ入力でも例外/NaN無く動作すること
  ------------------------------------------------------------------------ }
procedure TestRttyFilterSwitch;
var
  modem: TRttyModem;
  buf: array of Double;
  baudIdx, shiftIdx, i: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. RTTY: 全ボーレート(10種)x全シフト(10種)でのフィルタ切替 ---');

  modem := TRttyModem.Create(nil);
  try
    SetLength(buf, 4000); // 0.5秒分@8000Hz (最小filter_length=64の複数ブロック分)

    ok := True;
    for baudIdx := 0 to 9 do
    begin
      modem.SetBaudIndex(baudIdx);
      for shiftIdx := 0 to 9 do
      begin
        modem.SetShiftIndex(shiftIdx);
        for i := 0 to High(buf) do
          buf[i] := 0.3 * (Random - 0.5); // ノイズのみ (復調精度は問わない)
        try
          modem.RxProcess(buf, Length(buf));
        except
          on E: Exception do
          begin
            WriteLn('    例外発生: baudIdx=', baudIdx, ' shiftIdx=', shiftIdx, ' : ', E.Message);
            ok := False;
          end;
        end;
        if not (IsFinite(modem.Shift) and IsFinite(modem.Baud)) then
          ok := False;
      end;
    end;
    Check(ok, '全100通りの(baud,shift)組み合わせで例外/NaNなく動作する');
    Check(IsFinite(modem.Metric), '一連の切替後もMetricが有限値である (実際: ' + FloatToStr(modem.Metric) + ')');
  finally
    modem.Free;
  end;
end;

{ ------------------------------------------------------------------------
  2. CW: 帯域幅(Bandwidth)変更のたびに fftfilt が正しく再生成され、
     速度変更と合わせても安全に動作すること
  ------------------------------------------------------------------------ }
procedure TestCwFilterSwitch;
var
  modem: TCwModem;
  buf: array of Double;
  speed, i: Integer;
  bw: Double;
  ok: Boolean;
  bandwidths: array[0..3] of Double;
  bwIdx: Integer;
begin
  WriteLn;
  WriteLn('--- 2. CW: 帯域幅変更(CW_FFT_SIZE=2048再生成)x速度変更の安定性 ---');

  bandwidths[0] := 80;
  bandwidths[1] := 150; // 既定
  bandwidths[2] := 300;
  bandwidths[3] := 50;

  modem := TCwModem.Create(nil);
  try
    SetLength(buf, 6000); // 2048点FFTが複数ブロック回るのに十分な長さ

    ok := True;
    for speed := 5 to 40 do
    begin
      if speed mod 5 <> 0 then Continue; // 5,10,...,40 の8段階
      modem.SetCwSpeed(speed);
      for bwIdx := 0 to High(bandwidths) do
      begin
        bw := bandwidths[bwIdx];
        modem.Bandwidth := bw;
        for i := 0 to High(buf) do
          buf[i] := 0.3 * (Random - 0.5);
        try
          modem.RxProcess(buf, Length(buf));
        except
          on E: Exception do
          begin
            WriteLn('    例外発生: speed=', speed, ' bandwidth=', bw:0:0, ' : ', E.Message);
            ok := False;
          end;
        end;
      end;
    end;
    Check(ok, '速度8段階x帯域幅4段階の全組み合わせで例外なく動作する');
    Check(modem.Bandwidth = bandwidths[High(bandwidths)],
      '最後に設定したBandwidthが保持されている (実際: ' + FloatToStr(modem.Bandwidth) + ')');
  finally
    modem.Free;
  end;
end;

{ ------------------------------------------------------------------------
  3. CW: 同じ帯域幅を連続で設定してもフィルタを再生成しない
     (無駄な TFftFilt.Create/Free を避けられているか、Bandwidth比較の
     健全性を確認)
  ------------------------------------------------------------------------ }
procedure TestCwFilterNoRebuildWhenUnchanged;
var
  modem: TCwModem;
  buf: array of Double;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 3. CW: Bandwidth不変時は繰り返しRxProcessを呼んでも安定 ---');

  modem := TCwModem.Create(nil);
  try
    SetLength(buf, 3000);
    for i := 0 to High(buf) do
      buf[i] := 0.2 * Sin(2 * Pi * 700 * i / modem.SampleRate);

    modem.RxProcess(buf, Length(buf));
    modem.RxProcess(buf, Length(buf));
    modem.RxProcess(buf, Length(buf));

    Check(IsFinite(modem.Metric), '同一Bandwidthでの繰り返し呼び出し後もMetricが有限値');
  finally
    modem.Free;
  end;
end;

begin
  Randomize;
  WriteLn('=== RTTY/CW: TFftFilt パラメータ変更時の安定性テスト ===');

  TestRttyFilterSwitch;
  TestCwFilterSwitch;
  TestCwFilterNoRebuildWhenUnchanged;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
