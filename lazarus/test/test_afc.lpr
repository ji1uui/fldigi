{ ============================================================================
  test_afc.lpr

  周波数追尾 (AFC) の試験 (units/FreqTracker.pas / PSK の AFC。MDM-006)。

  何を守るか
  ----------------------------------------------------------------------------
  A. 追尾の仕組み (TFreqTracker)
     1. 上限と利得の検査、Init を忘れた使い方
     2. 利得どおりに効く / 上限で止まる / 止まったことを数える
     3. 指令が変わったらずれを捨てる (前の指令に対するずれは無効)
     4. 流し直しで全部捨てる (Z-05)
  B. PSK の AFC
     5. **ずれが無ければ動かない** ―― fldigi の畳まない形はここで落ちる
     6. 上からも下からも引き込む (片側だけになっていないこと)
     7. ドリフトに追随し、切ったときより明らかによく読める
     8. 切れば 1 Hz も動かない (利用者が止められる)
     9. 上限が送信周波数の逃げも縛る (Transmit は fail-safe)
    10. Restart で指令へ戻り、同じ音から同じ結果が出る (Z-05)
    11. Evidence に「指令からのずれ」が載る (§6.1)

  5 と 6 が対になっている。**片側だけ採る AFC でも 6 は通る** ――
  引き込みそのものは起きるからである。落ちるのは 5 のほうで、
  誤差ゼロのはずの信号がじわじわ引かれていく。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_afc;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, Modem, ModemDSP, DecodeEvidence,
  FreqTracker, PskModemImpl,
  TestSupport, TestVectors, Requirements, ErrorRate;

const
  RATE = 8000;
  MSG = 'CQ CQ DE JI1UUI JI1UUI K';

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  Inc(TestCount);
  if ACondition then WriteLn('  [OK] ', AMsg)
  else begin WriteLn('  [NG] ', AMsg); Inc(FailCount); end;
end;

procedure CheckEqS(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected);
    WriteLn('        実際: ', AActual);
    Inc(FailCount);
  end;
end;

type
  { 復号文字と、最後に載っていた「指令からのずれ」を貯める。 }
  TSink = class
  public
    Text: string;
    Count: Integer;
    LastOffset: Double;
    HasOffset: Boolean;
    Sig: QWord;
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
    function Signature: string;
  end;

{$push}{$Q-}{$R-}
procedure TSink.Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
var
  m: Double;
begin
  if AEvidence.BestChar > 0 then
  begin
    Text := Text + Chr(AEvidence.BestChar);
    Inc(Count);
  end;
  HasOffset := AEvidence.HasFreqOffset;
  LastOffset := AEvidence.FreqOffsetHz;
  { FNV-1a。桁あふれは意図どおり。文字だけでなく尺度と位置も混ぜる。 }
  if Sig = 0 then Sig := (QWord($CBF29CE4) shl 32) or QWord($84222325);
  Sig := (Sig xor QWord(AEvidence.BestChar)) *
         ((QWord($00000100) shl 32) or QWord($000001B3));
  Sig := (Sig xor QWord(AEvidence.SamplePos)) *
         ((QWord($00000100) shl 32) or QWord($000001B3));
  m := AEvidence.BestMetric;
  Sig := (Sig xor PQWord(@m)^) * ((QWord($00000100) shl 32) or QWord($000001B3));
end;
{$pop}

function TSink.Signature: string;
begin
  Result := IntToHex(Sig, 16);
end;

{ PSK の波形を作る (送信周波数 ATxHz)。 }
function BuildWave(AMode: TModemMode; ATxHz: Double): TDoubleArray;
var
  txs: TCaptureSoundDevice;
  tx: TPskModem;
  src: TTxSource;
  guard, r: Integer;
begin
  txs := TCaptureSoundDevice.Create;
  tx := TPskModem.Create(txs, AMode);
  src := TTxSource.Create(MSG);
  try
    tx.Frequency := ATxHz;
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    guard := 0;
    repeat
      r := tx.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 200000);
    Result := txs.GetCapturedCopy;
  finally
    src.Free; tx.Free; txs.Free;
  end;
end;

{ 波形を指令周波数 ACmdHz で受信する。AAfc が False なら追尾を切る。
  復号後のモデムのずれ・逃げ・最終周波数も返す。 }
procedure Receive(const AWave: TDoubleArray; AMode: TModemMode;
  ACmdHz: Double; AAfc: Boolean; ASink: TSink;
  out AOffset, AFinalHz: Double; out AClamps: Int64);
var
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  w: TDoubleArray;
  i: Integer;
begin
  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, AMode);
  try
    rx.Frequency := ACmdHz;
    rx.AfcOn := AAfc;
    rx.RxInit;
    rx.OnDecode := @ASink.Decode;
    SetLength(w, Length(AWave));
    for i := 0 to High(w) do w[i] := AWave[i];
    rx.RxProcess(w, Length(w));
    AOffset := rx.AfcOffsetHz;
    AFinalHz := rx.Frequency;
    AClamps := rx.AfcClamps;
  finally
    rx.Free; rxs.Free;
  end;
end;

{ 文字誤り率。units/ErrorRate.pas の MessageCharErrorRate をそのまま使う
  (test_regression と同じ計算)。**自前の位置合わせ比較は使わない** ――
  最初に「先頭から 1 文字ずつ重ねる」簡易版を書いたら、復号の頭に
  余分な 1 文字が付いただけで (varicode の境界で稀に起きる)、そこから
  後ろの比較が丸ごとずれて CER が 0.96 まで跳ね上がった。実害の無い
  1 文字を「ほぼ全滅」と報告する試験は、試験そのものが壊れている。 }
function Cer(const AGot, AWant: string): Double;
begin
  Result := MessageCharErrorRate(AWant, AGot);
end;

{ --------------------------------------------------------------------------
  1. 上限と利得の検査
  -------------------------------------------------------------------------- }
procedure TestGuards;
var
  ft: TFreqTracker;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. 上限と利得の検査 ---');

  raised := False;
  try ft.Init(0, 0.1); except on EFreqTrackerError do raised := True; end;
  Check(raised, '上限 0 を撥ねる');

  raised := False;
  try ft.Init(-5, 0.1); except on EFreqTrackerError do raised := True; end;
  Check(raised, '負の上限を撥ねる');

  raised := False;
  try ft.Init(100, 0); except on EFreqTrackerError do raised := True; end;
  Check(raised, '利得 0 を撥ねる');

  raised := False;
  try ft.Init(100, 1.5); except on EFreqTrackerError do raised := True; end;
  Check(raised, '利得 1 超を撥ねる');

  ft.Init(100, 1.0);
  Check(True, '利得 1 (全部効かせる) は許す');

  FillChar(ft, SizeOf(ft), 0);
  raised := False;
  try ft.Track(1000, 1); except on EFreqTrackerError do raised := True; end;
  Check(raised, '**Init を忘れた使い方を撥ねる** (黙って 0 幅で動かない)');
end;

{ --------------------------------------------------------------------------
  2. 利得どおりに効き、上限で止まる
  -------------------------------------------------------------------------- }
procedure TestGainAndRange;
var
  ft: TFreqTracker;
  f: Double;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 利得と上限 ---');

  ft.Init(100, 0.25);
  f := ft.Track(1000, 4.0);      { 4 Hz 高いところを見ている }
  Check(Abs(f - 999.0) < 1E-12,
    '**誤差の利得ぶんだけ下げる** (4 Hz * 0.25 = 1 Hz)');
  Check(Abs(ft.Offset + 1.0) < 1E-12, 'ずれは -1 Hz');
  Check(Abs(ft.LastError - 4.0) < 1E-12, '与えた誤差を憶えている');
  Check(ft.Updates = 1, '回数を数えている');

  f := ft.Track(1000, 4.0);
  Check(Abs(f - 998.0) < 1E-12, '積み上がる (ずれの積分である)');

  ft.Init(10, 0.5);
  for i := 1 to 100 do ft.Track(1000, 4.0);
  Check(Abs(ft.Offset + 10.0) < 1E-12, '**上限で止まる** (-10 Hz)');
  Check(ft.Clamps > 0, '止まったことを数えている');

  ft.Init(10, 0.5);
  for i := 1 to 100 do ft.Track(1000, -4.0);
  Check(Abs(ft.Offset - 10.0) < 1E-12, '反対側にも上限がある (+10 Hz)');

  ft.Init(100, 0.25);
  Check(not ft.HasBase, 'Init 直後は基準を持たない');
  ft.Track(1000, 0);
  Check(ft.HasBase, '1 回動かせば基準を持つ');
  Check(Abs(ft.FrequencyFor(1000) - 1000) < 1E-12,
    '誤差 0 なら指令のまま');
  Check(Abs(ft.FrequencyFor(1500) - 1500) < 1E-12,
    '違う指令を渡されたら、その指令をそのまま返す');
end;

{ --------------------------------------------------------------------------
  3. 指令が変わったらずれを捨てる
  -------------------------------------------------------------------------- }
procedure TestRebase;
var
  ft: TFreqTracker;
  f: Double;
begin
  WriteLn;
  WriteLn('--- 3. 指令が変わったら ---');

  ft.Init(100, 0.5);
  ft.Track(1000, 10.0);
  Check(Abs(ft.Offset + 5.0) < 1E-12, '前提: 1000 に対して -5 Hz');

  f := ft.Track(1500, 0.0);
  Check(Abs(ft.Offset) < 1E-12,
    '**指令が変わったらずれを捨てる** (前の指令に対する量なので)');
  Check(Abs(f - 1500) < 1E-12, '新しい指令から始まる');
  Check(ft.Rebases = 1, '捨てたことを数えている');

  ft.Track(1500, 10.0);
  Check(Abs(ft.Offset + 5.0) < 1E-12, '新しい指令に対して積み直す');

  ft.Reset;
  Check((Abs(ft.Offset) < 1E-12) and (ft.Updates = 0) and
        (ft.Clamps = 0) and (ft.Rebases = 0) and (not ft.HasBase),
    '**Reset は全部捨てる** (流し直しで前の音を持ち越さない / Z-05)');
end;

{ --------------------------------------------------------------------------
  4. ずれが無ければ動かない
  -------------------------------------------------------------------------- }
procedure TestNoSignalNoMove;
var
  wave: TDoubleArray;
  sink: TSink;
  off, fin: Double;
  clamps: Int64;
begin
  WriteLn;
  WriteLn('--- 4. ずれが無ければ動かない ---');

  { 送信も受信もぴったり 1000 Hz。雑音も無い。
    それでも動くなら、それは測り方が片側に偏っている。 }
  wave := BuildWave(mmPSK31, 1000);
  sink := TSink.Create;
  try
    Receive(wave, mmPSK31, 1000, True, sink, off, fin, clamps);
    WriteLn(Format('    ずれ %.4f Hz / 周波数 %.4f Hz / %d 文字',
      [off, fin, sink.Count]));
    Check(sink.Count > 10, '前提: 読めている');
    Check(Abs(off) < 0.20, Format(
      '**ぴったり合っていれば動かない** (ずれ %.4f Hz < 0.20)', [off]));
  finally
    sink.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 上からも下からも引き込む
  -------------------------------------------------------------------------- }
procedure TestPullInBothWays;
var
  wave: TDoubleArray;
  sink: TSink;
  offHi, offLo, finHi, finLo: Double;
  clamps: Int64;
  base: string;
const
  { 1 記号で測れる誤差の上限は sc_bw/4 = 記号速度/4 (PSK31 で 7.8 Hz)。
    6 Hz まではそもそも AFC が無くても読める (BPSK31 自身の耐性)。
    **7 Hz が唯一 AFC の有無で結果が分かれる帯**である ―― AFC 無しでは
    CER 0.58、有りでは 0.000 (実測、PskModemImpl.pas 冒頭の表を参照)。
    8 Hz 以上は復号そのものが最初の記号から壊れ、AFC があっても
    測る材料が無いので変わらない。ここを外すと「AFC を切ったときより
    良い」が常に成り立ってしまい (小さいずれではどちらも CER 0)、
    AFC の効果を試したことにならない ―― 実際そう書いていて気づいた。 }
  OFFSET_HZ = 7.0;
begin
  WriteLn;
  WriteLn('--- 5. 上からも下からも引き込む ---');

  wave := BuildWave(mmPSK31, 1000);

  { まず「ずれていても AFC 無しでどうなるか」を見る。 }
  sink := TSink.Create;
  try
    Receive(wave, mmPSK31, 1000 + OFFSET_HZ, False, sink, offHi, finHi, clamps);
    WriteLn(Format('    AFC 切 / +%.0f Hz: %d 文字 CER %.3f',
      [OFFSET_HZ, sink.Count, Cer(sink.Text, MSG)]));
    base := sink.Text;
    Check(Cer(base, MSG) > 0.30, Format(
      '前提: %.0f Hz は AFC 無しでは壊れる (CER %.3f)',
      [OFFSET_HZ, Cer(base, MSG)]));
  finally
    sink.Free;
  end;

  sink := TSink.Create;
  try
    Receive(wave, mmPSK31, 1000 + OFFSET_HZ, True, sink, offHi, finHi, clamps);
    WriteLn(Format('    AFC 入 / +%.0f Hz: ずれ %.2f Hz -> %.2f Hz / CER %.3f',
      [OFFSET_HZ, offHi, finHi, Cer(sink.Text, MSG)]));
    Check(offHi < -OFFSET_HZ + 1.0, Format(
      '**高いところから呼んだら下がる** (ずれ %.2f Hz)', [offHi]));
    Check(Cer(sink.Text, MSG) = 0.0, '追尾したら完全に読める');
    Check(Cer(sink.Text, MSG) < Cer(base, MSG),
      '**AFC を切ったときより良い** (壊れていた帯を救う)');
  finally
    sink.Free;
  end;

  sink := TSink.Create;
  try
    Receive(wave, mmPSK31, 1000 - OFFSET_HZ, True, sink, offLo, finLo, clamps);
    WriteLn(Format('    AFC 入 / -%.0f Hz: ずれ %.2f Hz -> %.2f Hz / CER %.3f / text=[%s]',
      [OFFSET_HZ, offLo, finLo, Cer(sink.Text, MSG), sink.Text]));
    Check(offLo > OFFSET_HZ - 1.0, Format(
      '**低いところから呼んだら上がる** (ずれ %.2f Hz)', [offLo]));
    Check(Cer(sink.Text, MSG) = 0.0, '追尾したら完全に読める');
  finally
    sink.Free;
  end;

  Check(Abs(offHi + offLo) < 1.0, Format(
    '**引き込みが上下で対称** (上 %.2f / 下 %.2f Hz)', [offHi, offLo]));
end;

{ 前後に無音を足す。test_regression.lpr の WithLeadIn と同じ考え方
  (受信機は送信の前後も聞いている)。ここではさらに、**ドリフトを
  この無音つきの波形全体に掛けてから信号を受ける**ことで、既知の限界の
  条件をそのまま再現する。 }
function WithLeadIn(const AWave: TDoubleArray): TDoubleArray;
const
  LEAD = 8000;   { test_regression.lpr の LEAD_SAMPLES と同じ (1 秒) }
var
  i: Integer;
begin
  SetLength(Result, LEAD + Length(AWave) + LEAD);
  for i := 0 to High(Result) do Result[i] := 0;
  for i := 0 to High(AWave) do
    Result[LEAD + i] := AWave[i];
end;

{ test_regression.lpr の「既知の限界」条件 (Frequency drift、0->60 Hz、
  REF_MSG、前後 1 秒無音、S/N 20 dB) を trial 0 の乱数種 (1000) で
  そのまま再現する。数字を test_regression のものと直接比べられるように
  するためで、この関数だけ REF_MSG が test_afc.lpr の MSG と違う。 }
procedure Receive60Known(AMode: TModemMode; out ACer: Double; AAfc: Boolean);
const
  REF_MSG = 'CQ DE JA1ABC K';   { test_regression.lpr と同じ }
var
  txs: TCaptureSoundDevice;
  tx: TPskModem;
  src: TTxSource;
  clean, padded, w: TDoubleArray;
  spec: TVectorSpec;
  guard, r: Integer;
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  sink: TSink;
begin
  txs := TCaptureSoundDevice.Create;
  tx := TPskModem.Create(txs, AMode);
  src := TTxSource.Create(REF_MSG);
  try
    tx.Frequency := 1000;
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    guard := 0;
    repeat
      r := tx.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 200000);
    clean := txs.GetCapturedCopy;
  finally
    src.Free; tx.Free; txs.Free;
  end;

  padded := WithLeadIn(clean);
  spec := MakeSpec(vkFrequencyDrift, 20);
  spec.CarrierHz := 1000;
  w := ApplyImpairment(padded, Length(padded), spec, RATE, 1000);

  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, AMode);
  sink := TSink.Create;
  try
    rx.Frequency := 1000;
    rx.AfcOn := AAfc;
    rx.RxInit;
    rx.OnDecode := @sink.Decode;
    rx.RxProcess(w, Length(w));
    ACer := MessageCharErrorRate(REF_MSG, Trim(sink.Text));
  finally
    sink.Free; rx.Free; rxs.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. ドリフトに追随する
  -------------------------------------------------------------------------- }
procedure TestDrift;
var
  wave, drifted: TDoubleArray;
  sink: TSink;
  off, fin, cerOn30, cerOff30, cerOn60, cerOff60: Double;
  clamps: Int64;
  i: Integer;
const
  { 緩いドリフト (捕捉範囲の内側)。 }
  MILD_DRIFT_HZ = 30.0;
begin
  WriteLn;
  WriteLn('--- 6. ドリフトに追随する ---');

  { --- まず捕捉範囲の内側: ロックしたあとのゆっくりしたドリフトには
    追随できる ―― PSK31 は sc_bw/4 = 7.8 Hz より速く外れなければ
    瞬間ごとの誤差がその中に収まる。 }
  wave := BuildWave(mmPSK31, 1000);
  SetLength(drifted, Length(wave));
  for i := 0 to High(wave) do drifted[i] := wave[i];
  ShiftFrequencyLinear(drifted, Length(drifted), RATE, 0, MILD_DRIFT_HZ);

  sink := TSink.Create;
  try
    Receive(drifted, mmPSK31, 1000, False, sink, off, fin, clamps);
    cerOff30 := Cer(sink.Text, MSG);
  finally
    sink.Free;
  end;
  sink := TSink.Create;
  try
    Receive(drifted, mmPSK31, 1000, True, sink, off, fin, clamps);
    cerOn30 := Cer(sink.Text, MSG);
    WriteLn(Format('    PSK31 0->%.0f Hz: AFC切 CER %.3f / AFC入 CER %.3f ' +
      '(ずれ %.2f Hz / 逃げ %d 回)', [MILD_DRIFT_HZ, cerOff30, cerOn30, off, clamps]));
    Check(cerOn30 = 0.0, Format(
      '**捕捉範囲内のドリフトなら完全に読める** (CER %.3f)', [cerOn30]));
    Check(cerOn30 < cerOff30 - 0.3, Format(
      '**AFC を切ると読めない** (入 %.3f / 切 %.3f)', [cerOn30, cerOff30]));
    Check(clamps = 0, '上限には当たっていない (自然に追随できている)');
  finally
    sink.Free;
  end;

  { --- 次に捕捉範囲の外: test_regression / MDM-006 の rationale が
    「既知の限界」として扱っている条件そのものを **同じ手順で** 再現する
    (REF_MSG、前後 1 秒の無音、S/N 20 dB、乱数種 1000 = test_regression の
    trial 0 と同一)。**ドリフトを無音つきの波形全体に掛けてから信号を
    抜き出す**ので、素の波形に直接掛ける前段の試験 (30 Hz) とは違う、
    より厳しい条件になる ―― 信号が始まった時点ですでにいくらかずれている
    (「頭出しの静的なずれ」に近い形になる)。無音つきで別に検証するのは
    このためで、素のドリフトだけでは緩すぎて既知の限界を再現しない
    (実際そう書いていて、素の波形では PSK31 も 60 Hz で CER 0.000 に
    なってしまい、既知の限界の文言と食い違った)。

    **PSK31 は改善しない (sc_bw/4=7.8 Hz を大きく超える)。
    PSK63 は改善する (sc_bw/4=15.6 Hz でこの条件の大半を捕捉できる)。**
    ここでは PSK63 の改善を実際に確かめ、PSK31 が悪化していない
    (退行していない) ことも同時に見る。数値は乱数種 1 本のみで、
    test_regression の複数乱数種平均のほうが本体の記録である。 }
  Receive60Known(mmPSK63, cerOff60, False);
  Receive60Known(mmPSK63, cerOn60, True);
  WriteLn(Format('    PSK63 既知の限界の条件 (test_regression trial 0 と同一): ' +
    'AFC切 CER %.3f / AFC入 CER %.3f', [cerOff60, cerOn60]));
  Check(cerOn60 < cerOff60 - 0.3, Format(
    '**PSK63 は既知の限界の条件でも AFC が実際に効く** (切 %.3f -> 入 %.3f)',
    [cerOff60, cerOn60]));

  Receive60Known(mmPSK31, cerOff60, False);
  Receive60Known(mmPSK31, cerOn60, True);
  WriteLn(Format('    PSK31 既知の限界の条件 (test_regression trial 0 と同一): ' +
    'AFC切 CER %.3f / AFC入 CER %.3f', [cerOff60, cerOn60]));
  Check(Abs(cerOn60 - cerOff60) < 0.15, Format(
    '**PSK31 は既知の限界のままで、AFC で悪化もしない** (切 %.3f / 入 %.3f)',
    [cerOff60, cerOn60]));
end;

{ --------------------------------------------------------------------------
  7. 切れば動かない / 上限が送信の逃げを縛る
  -------------------------------------------------------------------------- }
procedure TestOffAndRange;
var
  wave, drifted: TDoubleArray;
  sink: TSink;
  off, fin: Double;
  clamps: Int64;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 7. 切れば動かない / 上限 ---');

  wave := BuildWave(mmPSK31, 1000);
  sink := TSink.Create;
  try
    Receive(wave, mmPSK31, 1004, False, sink, off, fin, clamps);
    Check(Abs(off) < 1E-12, '**切れば 1 Hz も動かない** (利用者が止められる)');
    Check(Abs(fin - 1004) < 1E-12, '周波数は指令のまま');
    Check(sink.HasOffset and (Abs(sink.LastOffset) < 1E-12),
      'Evidence のずれも 0');
  finally
    sink.Free;
  end;

  { 捕捉範囲 (sc_bw/4 ≈ 7.8 Hz) を大きく越えるドリフトを与える。

    **上限まで歩いていくとは限らない。** 誤差が測れる範囲を超えた
    瞬間に品質 (afcmetric) が崩れ、門 (PSK_AFC_MIN_QUALITY) が
    それ以上の補正を止める ―― 追尾は「上限まで動いて止まる」のではなく
    「捕まえていた最後の値で凍る」。これは安全側の性質である
    (Permanent Rules: Transmit は fail-safe)。**ここでは上限に
    当たることではなく、上限のはるか手前で止まっていることを見る。** }
  SetLength(drifted, Length(wave));
  for i := 0 to High(wave) do drifted[i] := wave[i];
  ShiftFrequencyLinear(drifted, Length(drifted), RATE, 0, 400);

  sink := TSink.Create;
  try
    Receive(drifted, mmPSK31, 1000, True, sink, off, fin, clamps);
    WriteLn(Format('    400 Hz ドリフト: ずれ %.2f Hz / 逃げ %d 回',
      [off, clamps]));
    Check(Abs(off) <= PSK_AFC_RANGE_HZ + 1E-9, Format(
      '**指令から %.0f Hz より遠くへは行かない** (実際 %.2f Hz)',
      [PSK_AFC_RANGE_HZ, off]));
    Check(Abs(fin - 1000) <= PSK_AFC_RANGE_HZ + 1E-9,
      '見ている周波数も指令の近傍に留まる (送信も一緒に動くため)');
    Check(Abs(off) < PSK_AFC_RANGE_HZ / 4, Format(
      '**上限まで暴走せず、捕捉限界の手前で凍る** (ずれ %.2f Hz、上限 %.0f Hz)',
      [off, PSK_AFC_RANGE_HZ]));
  finally
    sink.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. Restart で戻り、同じ音から同じ結果
  -------------------------------------------------------------------------- }
procedure TestRestartAndDeterminism;
var
  wave: TDoubleArray;
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  s1, s2: TSink;
  w: TDoubleArray;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 8. Restart と再現性 ---');

  wave := BuildWave(mmPSK31, 1000);
  SetLength(w, Length(wave));
  for i := 0 to High(wave) do w[i] := wave[i];

  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, mmPSK31);
  s1 := TSink.Create;
  s2 := TSink.Create;
  try
    rx.Frequency := 1004;        { わざとずらして呼ぶ。AFC が動く }
    rx.RxInit; rx.StreamPosition := 0; rx.OnDecode := @s1.Decode;
    rx.RxProcess(w, Length(w));
    Check(Abs(rx.AfcOffsetHz) > 2.0, '前提: 1 回目で AFC が動いている');

    rx.Restart; rx.StreamPosition := 0; rx.OnDecode := @s2.Decode;
    Check(Abs(rx.Frequency - 1004) < 1E-12,
      '**Restart が指令された周波数へ戻す** (追尾を取り消せる)');
    Check(Abs(rx.AfcOffsetHz) < 1E-12, 'ずれも捨てている');

    rx.RxProcess(w, Length(w));
    CheckEqS(s2.Signature, s1.Signature,
      '**同じ音から同じ結果** (AFC が状態を持ち越さない / Z-05)');
  finally
    s1.Free; s2.Free; rx.Free; rxs.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. Evidence に載る / PSK63 でも動く
  -------------------------------------------------------------------------- }
procedure TestEvidenceAndPsk63;
var
  wave: TDoubleArray;
  sink: TSink;
  off, fin: Double;
  clamps: Int64;
begin
  WriteLn;
  WriteLn('--- 9. Evidence と PSK63 ---');

  wave := BuildWave(mmPSK31, 1000);
  sink := TSink.Create;
  try
    Receive(wave, mmPSK31, 1004, True, sink, off, fin, clamps);
    WriteLn(Format('    Evidence 最後のずれ %.2f Hz / RxProcess 終了時のずれ %.2f Hz',
      [sink.LastOffset, off]));
    Check(sink.HasOffset, '**Evidence がずれを名乗る** (§6.1 Frequency offset)');
    { sink.LastOffset は「最後の文字を復号した瞬間」、off は
      「RxProcess が全部終わった瞬間」の値で、**別の時刻**である
      (最後の文字のあとにも後置符号ぶんの記号が流れ、そこでも追尾は
      進む)。だから厳密な一致ではなく、同じ向き・同じ桁であることを見る
      ―― 厳密一致を要求すると、EmitPskChar が FAfc.Offset をその場で
      読んでいる (=定義上つねに一致する) だけの自明な主張になってしまう。 }
    Check(sink.LastOffset < -1.0, Format(
      '**Evidence のずれが実際に追尾の向きと合っている** (%.2f Hz、指令は +4 Hz 側)',
      [sink.LastOffset]));
    Check(Abs(sink.LastOffset - off) < 3.0, Format(
      '最後の文字のときのずれが、その後の終値と大きく離れていない ' +
      '(%.2f Hz -> %.2f Hz)', [sink.LastOffset, off]));
  finally
    sink.Free;
  end;

  wave := BuildWave(mmPSK63, 1000);
  sink := TSink.Create;
  try
    Receive(wave, mmPSK63, 1008, True, sink, off, fin, clamps);
    WriteLn(Format('    PSK63 / 指令 1008: ずれ %.2f Hz / CER %.3f',
      [off, Cer(sink.Text, MSG)]));
    Check(off < -4.0, 'PSK63 でも引き込む');
    Check(Cer(sink.Text, MSG) < 0.10, 'PSK63 でも読める');
  finally
    sink.Free;
  end;
end;

{ --------------------------------------------------------------------------
  10. 雑音だけでは酔歩しない (PSK_AFC_MIN_QUALITY の存在理由そのもの)
  -------------------------------------------------------------------------- }
procedure TestNoiseNoWander;
var
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  noise, buf: array of Double;
  i, k: Integer;
const
  BLK = 512;
  SECS = 5;
begin
  WriteLn;
  WriteLn('--- 10. 雑音だけでは酔歩しない ---');

  { Squelch の既定は 0 (スケルチなし) なので DCD はほぼ立ちっぱなしになる
    ―― **DCD だけでは雑音からの補正を止められない。** 止めているのは
    品質の門 (PSK_AFC_MIN_QUALITY) である。RandSeed を固定するので
    Z-05 のとおり毎回同じ雑音になる。 }
  RandSeed := 424242;
  SetLength(noise, RATE * SECS);
  for i := 0 to High(noise) do noise[i] := 0.3 * (2 * Random - 1);
  SetLength(buf, BLK);

  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, mmPSK31);
  try
    rx.Frequency := 1000;
    rx.AfcOn := True;
    rx.AfcSpeed := 2;   { 速い設定。酔歩するなら一番出やすい。 }
    rx.RxInit;
    k := 0;
    while k + BLK <= Length(noise) do
    begin
      for i := 0 to BLK - 1 do buf[i] := noise[k + i];
      rx.RxProcess(buf, BLK);
      Inc(k, BLK);
    end;
    WriteLn(Format('    %d 秒の雑音のみ (速い設定): ずれ %.4f Hz / 補正 %d 回 / dcd=%s',
      [SECS, rx.AfcOffsetHz, rx.AfcUpdates, BoolToStr(rx.Dcd, 'Y', 'n')]));
    Check(rx.Dcd, '前提: Squelch 既定 (無し) では DCD が立つ (門の必要性の根拠)');
    Check(rx.AfcUpdates = 0, Format(
      '**品質が一度も門を通らないので補正 0 回** (実際 %d 回)', [rx.AfcUpdates]));
    Check(Abs(rx.AfcOffsetHz) < 1E-9, Format(
      '**雑音だけでは 1 Hz どころか 1 ミリ Hz も動かない** (実際 %.6f Hz)',
      [rx.AfcOffsetHz]));
  finally
    rx.Free; rxs.Free;
  end;
end;

begin
  WriteLn('=== 周波数追尾 (AFC) の試験 (MDM-006) ===');

  TestGuards;
  TestGainAndRange;
  TestRebase;
  TestNoSignalNoMove;
  TestPullInBothWays;
  TestDrift;
  TestOffAndRange;
  TestRestartAndDeterminism;
  TestEvidenceAndPsk63;
  TestNoiseNoWander;

  if FailCount = 0 then
    CoverReq('MDM-006');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
