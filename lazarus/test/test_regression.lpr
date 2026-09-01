{ ============================================================================
  test_regression.lpr

  劣悪条件の Test vectors による復調の回帰試験 (MDM-001 / Z-02)。
  Baseline v1.1 §14.1 Golden WAV / Test Vector、§17 BER/CER。

  なぜ要るのか
  ----------------------------------------------------------------------------
  復調器を直したとき、直したつもりが別の条件を壊していないかを確かめる
  土台である。ここまで、CW のトーン検出も PSK の実装も **手作りの数例**で
  判断してきた。それは有効だったが、Phase 3 の完了条件
  「定義済み QSB/QRM/AWGN 条件で Baseline Decoder より **統計的改善** を
  確認する」を満たすには足りない。比べる物差しが要る。

  この試験の作り
  ----------------------------------------------------------------------------
  前半は **物差しそのものの検査**である。編集距離・乱数・S/N の付け方・
  周波数シフト・WAV の読み書き・有意差判定を先に確かめる。物差しが
  信用できなければ、後半の数字に意味がない。

  後半が回帰そのもので、4 モード × 10 条件 × 8 種の乱数を回して
  文字誤り率を出し、記録した上限と比べる。

  上限は実測から決めた
  ----------------------------------------------------------------------------
  「このくらいだろう」で決めた閾値は、緩ければ退行を見逃し、厳しければ
  乱数の巡り合わせで落ちる。先に測ってから、平均に対して上限を置いた。
  平均で見るのは、8 回のうち 1 回だけ崩れても落ちないようにするためで
  ある (系統的な退行なら平均が動く)。

  既知の限界は隠さない
  ----------------------------------------------------------------------------
  PSK31 / PSK63 は周波数ドリフトに追従できない。**AFC が無い**ためで、
  CW と RTTY は同じ条件を通る (RTTY は AFC が効いている)。
  **閾値を緩めて隠すのではなく**、既知の限界として表に載せ、それより
  悪くならないことだけを課す。AFC は Baseline でも Phase 3 の項目なので
  そこで直る。要求 MDM-006 として登録してある。

  ドリフトの量 (60 Hz) も測って決めた。20 Hz では RTTY の AFC を切っても
  結果が変わらず、**AFC を試したことにならなかった**。詳細は
  TestVectors.pas の MakeSpec を参照。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_regression;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  SoundIntf, ModemTypes, Modem, ModemDSP,
  CwModemImpl, RttyModemImpl, PskModemImpl, DecodeEvidence,
  TestVectors, ErrorRate, WaveFile, TestSupport, Requirements;

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

{ ==========================================================================
  第 1 部: 物差しの検査
  ========================================================================== }

procedure TestLevenshtein;
begin
  WriteLn;
  WriteLn('--- 1. 編集距離 ---');
  CheckEqI(LevenshteinDistance('', ''), 0, '空どうしは 0');
  CheckEqI(LevenshteinDistance('abc', 'abc'), 0, '同じなら 0');
  CheckEqI(LevenshteinDistance('abc', ''), 3, '空との距離は長さ');
  CheckEqI(LevenshteinDistance('', 'abc'), 3, '逆でも同じ');
  CheckEqI(LevenshteinDistance('abc', 'abd'), 1, '1 文字置換は 1');
  CheckEqI(LevenshteinDistance('abc', 'abcd'), 1, '1 文字挿入は 1');
  CheckEqI(LevenshteinDistance('abcd', 'abc'), 1, '1 文字削除は 1');
  { 教科書の例。 }
  CheckEqI(LevenshteinDistance('kitten', 'sitting'), 3,
    '**kitten と sitting の距離は 3** (よく知られた値)');
  CheckEqI(LevenshteinDistance('flaw', 'lawn'), 2, 'flaw と lawn は 2');
  { 対称であること。 }
  CheckEqI(LevenshteinDistance('CQ DE JA1ABC', 'CQ DE JA1ABD'),
           LevenshteinDistance('CQ DE JA1ABD', 'CQ DE JA1ABC'),
           '向きを変えても同じ');
end;

procedure TestCerSemantics;
var
  r: TErrorRateResult;
begin
  WriteLn;
  WriteLn('--- 2. 二つの CER の意味 ---');

  { 完全一致。 }
  r := MeasureErrorRate('CQ DE JA1ABC K', 'CQ DE JA1ABC K');
  Check(r.Cer = 0, '完全一致なら全体 CER は 0');
  Check(r.MessageCer = 0, '完全一致なら本文 CER も 0');
  Check(r.Ber = 0, '完全一致なら BER も 0');

  { 前後にゴミが付いた場合。**ここが二つの CER を分ける理由**。 }
  r := MeasureErrorRate('CQ DE JA1ABC K', 'xy CQ DE JA1ABC K zw');
  WriteLn('        ', r.Describe);
  Check(r.Cer > 0.3, '**全体 CER はゴミを誤りとして数える**');
  Check(r.MessageCer = 0, '**本文 CER はゴミを外して 0 になる**');

  { 本文そのものが壊れている場合は、どちらも上がる。 }
  r := MeasureErrorRate('CQ DE JA1ABC K', 'xy CQ DE JX1XBC K zw');
  WriteLn('        ', r.Describe);
  Check(r.MessageCer > 0, '本文が壊れていれば本文 CER も上がる');
  Check(r.Ber > 0, '文字が違えばビットも違う');

  { 何も出なかった場合。 }
  r := MeasureErrorRate('CQ DE JA1ABC K', '');
  Check(r.Cer = 1.0, '何も出なければ全体 CER は 1.0');
  Check(r.MessageCer = 1.0, '何も出なければ本文 CER も 1.0');

  { ビット比較が文字比較より細かいこと。1 文字違うが 1 bit しか違わない
    組み合わせで確かめる ('A'=0x41 と 'C'=0x43 は 1 bit 違い)。 }
  r := MeasureErrorRate('AAAA', 'ACAA');
  CheckEqI(r.BitErrors, 1, '**A と C の違いは 1 bit** (文字単位より細かい)');
  CheckEqI(r.BitsCompared, 32, '4 文字ぶん 32 bit を比べている');
end;

procedure TestRandomDeterminism;
var
  a, b: TVectorRandom;
  i, diff: Integer;
  va, vb: QWord;
  sum, sumSq, x: Double;
  n: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 乱数の再現性と分布 (Z-05) ---');

  a.Seed(12345);
  b.Seed(12345);
  diff := 0;
  for i := 1 to 10000 do
  begin
    va := a.NextU64;
    vb := b.NextU64;
    if va <> vb then Inc(diff);
  end;
  CheckEqI(diff, 0, '**同じ種なら同じ列** (1 万回)');

  a.Seed(12345);
  b.Seed(12346);
  diff := 0;
  for i := 1 to 1000 do
    if a.NextU64 <> b.NextU64 then Inc(diff);
  Check(diff > 990, '種が違えば違う列になる');

  { system の Random を回しても影響を受けないこと。ここが崩れると、
    試験を 1 つ足しただけで無関係の試験の数字が動く。 }
  a.Seed(999);
  va := a.NextU64;
  RandSeed := 1; Random; Random; Random;
  b.Seed(999);
  vb := b.NextU64;
  CheckEqI(Int64(va), Int64(vb),
    '**system の Random と独立している** (呼ぶ順番に左右されない)');

  { 正規乱数の平均と分散。 }
  a.Seed(777);
  n := 100000;
  sum := 0; sumSq := 0;
  for i := 1 to n do
  begin
    x := a.NextGauss;
    sum := sum + x;
    sumSq := sumSq + x * x;
  end;
  WriteLn(Format('        正規乱数 %d 個: 平均 %.4f / 分散 %.4f',
    [n, sum / n, sumSq / n - Sqr(sum / n)]));
  Check(Abs(sum / n) < 0.02, '平均が 0 に近い');
  Check(Abs(sumSq / n - 1.0) < 0.03, '分散が 1 に近い');

  { 一様乱数が 0..1 に収まること。 }
  a.Seed(4242);
  diff := 0;
  for i := 1 to 100000 do
  begin
    x := a.NextFloat;
    if (x < 0) or (x >= 1) then Inc(diff);
  end;
  CheckEqI(diff, 0, '一様乱数が 0 以上 1 未満に収まる');
end;

procedure TestSnrIsAchieved;
const
  N = 80000;
var
  sig: TDoubleArray;
  got: TDoubleArray;
  i, k: Integer;
  spec: TVectorSpec;
  noise: TDoubleArray;
  wanted, measured: Double;
begin
  WriteLn;
  WriteLn('--- 4. 指定した S/N が実際に付いていること ---');
  SetLength(sig, N);
  for i := 0 to N - 1 do
    sig[i] := 0.4 * Sin(2 * Pi * 1000 * i / 8000);

  for k := 0 to 3 do
  begin
    wanted := 0 + k * 10;    { 0, 10, 20, 30 dB }
    spec := MakeSpec(vkAwgn, wanted);
    got := ApplyImpairment(sig, N, spec, 8000, 4321);
    { 差を取れば雑音そのものが出る。 }
    SetLength(noise, N);
    for i := 0 to N - 1 do
      noise[i] := got[i] - sig[i];
    measured := 20 * Log10(SignalRms(sig, N) / Max(1E-30, SignalRms(noise, N)));
    WriteLn(Format('        指定 %.0f dB -> 実測 %.2f dB', [wanted, measured]));
    Check(Abs(measured - wanted) < 0.2,
      Format('S/N %.0f dB が 0.2 dB 以内で付いている', [wanted]));
  end;
end;

procedure TestImpairmentDeterminism;
const
  N = 20000;
var
  sig: TDoubleArray;
  w1, w2, w3: TDoubleArray;
  i, k: Integer;
  spec: TVectorSpec;
  c1, c2, c3: QWord;
  allSame, allDiff: Boolean;
begin
  WriteLn;
  WriteLn('--- 5. 劣化の再現性 (Z-05) ---');
  SetLength(sig, N);
  for i := 0 to N - 1 do
    sig[i] := 0.4 * Sin(2 * Pi * 900 * i / 8000);

  allSame := True;
  allDiff := True;
  for k := Ord(vkClean) to Ord(vkSilence) do
  begin
    spec := MakeSpec(TVectorKind(k), 15);
    spec.CarrierHz := 900;
    w1 := ApplyImpairment(sig, N, spec, 8000, 111);
    w2 := ApplyImpairment(sig, N, spec, 8000, 111);
    w3 := ApplyImpairment(sig, N, spec, 8000, 222);
    c1 := WaveChecksum(w1, Length(w1));
    c2 := WaveChecksum(w2, Length(w2));
    c3 := WaveChecksum(w3, Length(w3));
    if c1 <> c2 then
    begin
      allSame := False;
      WriteLn(Format('        %s: 同じ種なのに検査和が違う',
        [VectorKindName(TVectorKind(k))]));
    end;
    { Clean は乱数を使わないので種を変えても同じ。それ以外は変わるはず。 }
    if (TVectorKind(k) <> vkClean) and (c1 = c3) then
    begin
      allDiff := False;
      WriteLn(Format('        %s: 種を変えても検査和が同じ',
        [VectorKindName(TVectorKind(k))]));
    end;
  end;
  Check(allSame, '**同じ種なら 10 分類すべてで同じ波形になる**');
  Check(allDiff, '種を変えれば波形が変わる (Clean を除く)');
end;

procedure TestFrequencyShiftIsSingleSideband;
const
  N = 16000;
  FFTN = 32768;
var
  w: TDoubleArray;
  buf: TComplexArray;
  i, peakIdx: Integer;
  peak, upper, lower: Double;
begin
  WriteLn;
  WriteLn('--- 6. 周波数シフトが片側だけずれること ---');
  SetLength(w, N);
  for i := 0 to N - 1 do
    w[i] := Sin(2 * Pi * 1000 * i / 8000);

  ShiftFrequencyLinear(w, N, 8000, 50, 50);

  SetLength(buf, FFTN);
  for i := 0 to FFTN - 1 do
    if i < N then buf[i] := CplxMake(w[i], 0) else buf[i] := CplxMake(0, 0);
  ComplexFFT(buf);

  peak := 0; peakIdx := 0;
  for i := 1 to FFTN div 2 - 1 do
    if CplxAbs(buf[i]) > peak then
    begin
      peak := CplxAbs(buf[i]);
      peakIdx := i;
    end;
  upper := CplxAbs(buf[Round(1050.0 * FFTN / 8000)]);
  lower := CplxAbs(buf[Round(950.0 * FFTN / 8000)]);
  WriteLn(Format('        山 %.1f Hz / 1050 Hz %.1f / 950 Hz %.1f (鏡像)',
    [peakIdx * 8000.0 / FFTN, upper, lower]));

  Check(Abs(peakIdx * 8000.0 / FFTN - 1050.0) < 2.0,
    '**1000 Hz が 1050 Hz へ動く** (+50 Hz 指定)');
  Check(upper > lower * 100,
    '**鏡像が 40 dB 以上小さい** (振幅変調ではなく周波数シフトになっている)');
end;

procedure TestWaveFileRoundTrip;
const
  N = 5000;
var
  a, b: TDoubleArray;
  info: TWaveInfo;
  i: Integer;
  worst: Double;
  fn: string;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 7. WAV の読み書き ---');
  fn := GetTempDir + 'fldigi_lazarus_test.wav';
  SetLength(a, N);
  for i := 0 to N - 1 do
    a[i] := 0.8 * Sin(2 * Pi * 700 * i / 8000);

  SaveWave(fn, a, N, 8000);
  info := LoadWave(fn, b);
  WriteLn('        ', info.Describe);

  CheckEqI(info.SampleRate, 8000, '標本化周波数が保たれる');
  CheckEqI(info.Frames, N, '標本数が保たれる');
  CheckEqI(info.Channels, 1, 'モノラルとして書かれている');

  worst := 0;
  for i := 0 to N - 1 do
    if Abs(a[i] - b[i]) > worst then worst := Abs(a[i] - b[i]);
  WriteLn(Format('        往復の最大誤差 %.6f (16 bit の刻みは %.6f)',
    [worst, 1.0 / 32768]));
  Check(worst < 2.0 / 32768,
    '**往復の誤差が 16 bit の刻み以内** (量子化以外の劣化が無い)');

  { 範囲外は頭打ちにする。回り込ませると大きい波形が小さくなる。 }
  SetLength(a, 4);
  a[0] := 2.0; a[1] := -2.0; a[2] := 0.5; a[3] := 0;
  SaveWave(fn, a, 4, 8000);
  LoadWave(fn, b);
  Check((b[0] > 0.99) and (b[1] < -0.99),
    '**範囲外は頭打ちになる** (回り込んで符号が変わらない)');

  { 壊れたファイルは読めないと言う。 }
  raised := False;
  try
    LoadWave(GetTempDir + 'no_such_file_12345.wav', b);
  except
    on E: EWaveFileError do raised := True;
  end;
  Check(raised, '無いファイルは EWaveFileError になる');

  DeleteFile(fn);
end;

procedure TestSignificance;
var
  a, b: array[0..15] of Double;
  i: Integer;
  rnd: TVectorRandom;
  dm, dc: Double;
  short: array[0..3] of Double;
begin
  WriteLn;
  WriteLn('--- 8. 有意差の判定 ---');
  rnd.Seed(31337);

  { 同じ分布から取った 2 つ。差は無いはずなので「有意に良い」と
    言ってはいけない。 }
  for i := 0 to 15 do
  begin
    a[i] := 0.3 + 0.05 * rnd.NextGauss;
    b[i] := 0.3 + 0.05 * rnd.NextGauss;
  end;
  Check(not SignificantlyBetter(a, b, dm, dc),
    '**差が無いものを「有意に良い」と言わない**');
  WriteLn(Format('        差の平均 %.4f ± %.4f', [dm, dc]));

  { A のほうがはっきり小さい場合。 }
  for i := 0 to 15 do
  begin
    a[i] := 0.10 + 0.02 * rnd.NextGauss;
    b[i] := 0.30 + 0.02 * rnd.NextGauss;
  end;
  Check(SignificantlyBetter(a, b, dm, dc),
    '**はっきり良いものは有意と判定する**');
  WriteLn(Format('        差の平均 %.4f ± %.4f', [dm, dc]));

  { 逆向き (A のほうが悪い) を「良い」と言わない。 }
  Check(not SignificantlyBetter(b, a, dm, dc),
    '悪いほうを「良い」と言わない');

  { 試行が少なすぎるときは判定しない。 }
  for i := 0 to 3 do
  begin
    short[i] := 0.1;
  end;
  Check(not SignificantlyBetter(short, short, dm, dc),
    '**試行が 8 未満なら有意と言わない** (少ない標本で断定しない)');
end;

{ ==========================================================================
  第 2 部: 復調の回帰
  ========================================================================== }

type
  TMakeModem = function(ASound: TCustomSoundDevice): TCustomModem;

  TSink = class
    Text: string;
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
  end;

procedure TSink.Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
begin
  if AEvidence.BestChar > 0 then
    Text := Text + Chr(AEvidence.BestChar);
end;

function MakeCw(ASound: TCustomSoundDevice): TCustomModem;
var
  m: TCwModem;
begin
  m := TCwModem.Create(ASound);
  m.Frequency := 700;
  m.SetCwSpeed(20);
  m.CwTrack := False;
  Result := m;
end;

function MakeRtty(ASound: TCustomSoundDevice): TCustomModem;
var
  m: TRttyModem;
begin
  m := TRttyModem.Create(ASound);
  m.Frequency := 1000;
  m.AfcOn := True;      { 通常の運用設定 }
  Result := m;
end;

function MakePsk31(ASound: TCustomSoundDevice): TCustomModem;
begin
  Result := TPskModem.Create(ASound, mmPSK31);
  Result.Frequency := 1000;
end;

function MakePsk63(ASound: TCustomSoundDevice): TCustomModem;
begin
  Result := TPskModem.Create(ASound, mmPSK63);
  Result.Frequency := 1000;
end;

const
  REF_MSG = 'CQ DE JA1ABC K';
  TRIALS = 8;
  REG_SNR = 20.0;        { 広帯域 S/N [dB] }
  LEAD_SAMPLES = 8000;   { 前後の無音 1 秒 }

  { 実測から決めた上限 (本文 CER の平均)。0.05 は「14 文字中 1 文字の
    誤りでも 8 回の平均なら通るが、系統的な退行なら落ちる」水準。 }
  TIGHT = 0.05;

type
  TModeSpec = record
    Name: string;
    Make: TMakeModem;
    Carrier: Double;
  end;

var
  GModes: array[0..3] of TModeSpec;

{ 無音のときに出してよい文字数の上限。実測 (CW 0.0 / RTTY 14.3 /
  PSK31 31.0 / PSK63 39.1) のおよそ 2 倍。

  ここは「復調の実力」ではなく **雑音でどれだけ喋るか** の尺度である。
  スケルチや Confidence を弱めれば必ず増えるので、緩い上限では退行を
  見逃す。実測から締める。CW だけ桁が違うのは、新しいトーン検出が
  二重の門番を持っているためである (README §28)。 }
function SilenceCeilingFor(AModeIdx: Integer): Double;
begin
  case AModeIdx of
    0: Result := 5;     { CW20   実測 0.0 }
    1: Result := 35;    { RTTY45 実測 14.3 }
    2: Result := 70;    { PSK31  実測 31.0 }
  else Result := 90;    { PSK63  実測 39.1 }
  end;
end;

{ 条件ごとの上限。実測 (README §32 の表) に余裕を足した値。
  -1 は「既知の限界。別に扱う」。 }
function CeilingFor(AModeIdx: Integer; AKind: TVectorKind): Double;
begin
  Result := TIGHT;
  case AKind of
    vkSilence:
      Result := -1;      { 無音は文字数で見る }
    vkExtremeQsb:
      if AModeIdx = 0 then Result := 0.35;   { CW は深いフェージングで落ちる }
    vkFrequencyDrift:
      { PSK は AFC を持たないので 60 Hz のドリフトに追従できない。
        既知の限界として扱う (MDM-006 / Phase 3)。 }
      if AModeIdx >= 2 then Result := -1;
  end;
end;

function Transmit(AMake: TMakeModem; const AMsg: string): TDoubleArray;
var
  snd: TCaptureSoundDevice;
  m: TCustomModem;
  src: TTxSource;
  guard, r: Integer;
begin
  snd := TCaptureSoundDevice.Create;
  m := AMake(snd);
  src := TTxSource.Create(AMsg);
  try
    m.OnGetTxChar := @src.GetTxChar;
    m.TxInit;
    guard := 0;
    repeat
      r := m.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 300000);
    Result := snd.GetCapturedCopy;
  finally
    src.Free; m.Free; snd.Free;
  end;
end;

function Receive(AMake: TMakeModem; const AWave: TDoubleArray): string;
var
  snd: TCaptureSoundDevice;
  m: TCustomModem;
  sink: TSink;
begin
  snd := TCaptureSoundDevice.Create;
  m := AMake(snd);
  sink := TSink.Create;
  try
    m.RxInit;
    m.OnDecode := @sink.Decode;
    m.RxProcess(AWave, Length(AWave));
    Result := sink.Text;
  finally
    sink.Free; m.Free; snd.Free;
  end;
end;

{ 前後に無音を足す。実際の受信機は送信の前後も聞いているので、
  そこで雑音から文字を作らないかも同時に見ることになる。 }
function WithLeadIn(const AWave: TDoubleArray): TDoubleArray;
var
  i: Integer;
begin
  SetLength(Result, LEAD_SAMPLES + Length(AWave) + LEAD_SAMPLES);
  for i := 0 to High(Result) do Result[i] := 0;
  for i := 0 to High(AWave) do
    Result[LEAD_SAMPLES + i] := AWave[i];
end;

procedure RunRegression;
var
  mi, ki, trial: Integer;
  clean, padded, w: TDoubleArray;
  spec: TVectorSpec;
  cers, mcers: array[0..TRIALS-1] of Double;
  lens: array[0..TRIALS-1] of Double;
  st, mst, lst: TErrorRateStats;
  res: TErrorRateResult;
  ceil_: Double;
  kind: TVectorKind;
begin
  WriteLn;
  WriteLn(Format('--- 9. 復調の回帰 (S/N %.0f dB 広帯域 / %d 種の乱数) ---',
    [REG_SNR, TRIALS]));
  WriteLn('    モード   条件               本文CER 平均±95%   上限   判定');

  for mi := 0 to High(GModes) do
  begin
    clean := Transmit(GModes[mi].Make, REF_MSG);
    padded := WithLeadIn(clean);

    for ki := Ord(vkClean) to Ord(vkSilence) do
    begin
      kind := TVectorKind(ki);
      spec := MakeSpec(kind, REG_SNR);
      spec.CarrierHz := GModes[mi].Carrier;

      for trial := 0 to TRIALS - 1 do
      begin
        w := ApplyImpairment(padded, Length(padded), spec, 8000,
          QWord(1000 + trial * 7919));
        res := MeasureErrorRate(REF_MSG, Trim(Receive(GModes[mi].Make, w)));
        cers[trial] := res.Cer;
        mcers[trial] := res.MessageCer;
        lens[trial] := res.GotLength;
      end;

      st := SummarizeRates(cers);
      mst := SummarizeRates(mcers);
      lst := SummarizeRates(lens);
      ceil_ := CeilingFor(mi, kind);

      if kind = vkSilence then
      begin
        { 無音では「何文字出したか」を見る。復調そのものではなく、
          雑音でどれだけ喋るかの尺度である。 }
        WriteLn(Format('    %-8s %-18s 出力 %.1f 文字   上限 %.0f   %s',
          [GModes[mi].Name, VectorKindName(kind), lst.Mean,
           SilenceCeilingFor(mi),
           BoolToStr(lst.Mean <= SilenceCeilingFor(mi), 'OK', 'NG')]));
        Check(lst.Mean <= SilenceCeilingFor(mi),
          Format('%s / 無音: 出力 %.1f 文字 <= %.0f (雑音で喋りすぎない)',
            [GModes[mi].Name, lst.Mean, SilenceCeilingFor(mi)]));
      end
      else if ceil_ < 0 then
      begin
        { 既知の限界。隠さずに表に出し、それ以上悪くならないことだけ課す。 }
        WriteLn(Format('    %-8s %-18s %6.3f ±%.3f   既知の限界 (<=0.85)',
          [GModes[mi].Name, VectorKindName(kind), mst.Mean, mst.Ci95]));
        Check(mst.Mean <= 0.85,
          Format('%s / %s: 既知の限界より悪化していない (実測 %.3f)',
            [GModes[mi].Name, VectorKindName(kind), mst.Mean]));
      end
      else
      begin
        WriteLn(Format('    %-8s %-18s %6.3f ±%.3f   %.2f   %s',
          [GModes[mi].Name, VectorKindName(kind), mst.Mean, mst.Ci95, ceil_,
           BoolToStr(mst.Mean <= ceil_, 'OK', 'NG')]));
        Check(mst.Mean <= ceil_,
          Format('%s / %s: 本文 CER %.3f <= %.2f',
            [GModes[mi].Name, VectorKindName(kind), mst.Mean, ceil_]));
      end;

      { Clean だけは全体 CER も 0 であること (ゴミも出ないはず)。 }
      if kind = vkClean then
        Check(st.Mean = 0,
          Format('%s / Clean: 全体 CER も 0 (余計な文字を出さない)',
            [GModes[mi].Name]));
    end;
  end;
end;

begin
  WriteLn('=== 劣悪条件の Test vectors による回帰試験 (MDM-001 / Z-02) ===');

  GModes[0].Name := 'CW20';   GModes[0].Make := @MakeCw;    GModes[0].Carrier := 700;
  GModes[1].Name := 'RTTY45'; GModes[1].Make := @MakeRtty;  GModes[1].Carrier := 1000;
  GModes[2].Name := 'PSK31';  GModes[2].Make := @MakePsk31; GModes[2].Carrier := 1000;
  GModes[3].Name := 'PSK63';  GModes[3].Make := @MakePsk63; GModes[3].Carrier := 1000;

  TestLevenshtein;
  TestCerSemantics;
  TestRandomDeterminism;
  TestSnrIsAchieved;
  TestImpairmentDeterminism;
  TestFrequencyShiftIsSingleSideband;
  TestWaveFileRoundTrip;
  TestSignificance;
  RunRegression;

  if FailCount = 0 then
    CoverReq('MDM-001');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
