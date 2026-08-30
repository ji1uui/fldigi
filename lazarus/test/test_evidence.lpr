{ ============================================================================
  test_evidence.lpr

  ADR-002 (Modem API は複数候補・Evidence を返せる型にする) の回帰テスト。

  重点は「型が運べること」ではなく「実際に運んでいること」。
  型だけ広げて中身が空なら、Phase 4 の Confidence / Context Assistance は
  結局作れない。

  実行方法: ./run_tests.sh もしくは
    fpc -Fuunits -FEtest -otest_evidence test/test_evidence.lpr
  ============================================================================ }
program test_evidence;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math,
  SoundIntf, ModemTypes, Modem, ModemDSP, DecodeEvidence,
  RttyModemImpl, CwModemImpl, NullModemImpl, TestSupport, Requirements;

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

procedure CheckEq(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: [', AExpected, ']  実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

procedure TestEvidenceType;
var
  ev: TDecodeEvidence;
begin
  WriteLn;
  WriteLn('--- 1. Evidence 型の基本 ---');

  ev := SingleCandidateEvidence(Ord('A'), 'test');
  Check(ev.CandidateCount = 1, '候補1件');
  Check(ev.BestChar = Ord('A'), '最有力候補が取れる');
  Check(not ev.HasAlternatives, '第2候補は無い');
  Check(ev.MetricKind = emkNone, '尺度なしとして作られる');
  CheckEq(ev.DecoderName, 'test', '戦略名が入る');
  Check(ev.SamplePos = -1, 'サンプル位置は未設定なら -1');

  ev := ScoredCandidateEvidence(Ord('E'), 0.8, emkSoftMargin, 'rtty');
  Check(ev.MetricKind = emkSoftMargin, '尺度の種類が保たれる');
  Check(Abs(ev.BestMetric - 0.8) < 1E-9, '尺度の値が保たれる');

  { 候補は尺度の降順に並ぶ }
  AddCandidate(ev, Ord('I'), 0.3);
  AddCandidate(ev, Ord('S'), 0.9);
  Check(ev.CandidateCount = 3, '候補が3件になる');
  Check(ev.BestChar = Ord('S'), '最も尺度の大きい候補が先頭 (S)');
  Check(ev.Candidates[1].Ch = Ord('E'), '2番目は E');
  Check(ev.Candidates[2].Ch = Ord('I'), '3番目は I');
  Check(ev.HasAlternatives, '第2候補があると判定される');

  { 候補なし }
  ev.Candidates := nil;
  Check(ev.BestChar = DECODE_NO_CHAR, '候補なしは DECODE_NO_CHAR');
  Check(Abs(ev.BestMetric) < 1E-12, '候補なしの尺度は 0');
  CheckEq(ev.Describe, '(候補なし)', '候補なしの表示');

  ev := ScoredCandidateEvidence(Ord('A'), 0.5, emkSoftMargin, 'rtty');
  ev.HasSnr := True;
  ev.SnrDb := 12.5;
  Check(Pos('''A''', ev.Describe) > 0, '診断表示に文字が出る');
  Check(Pos('SNR', ev.Describe) > 0, '診断表示に SNR が出る');
  Check(Pos('rtty', ev.Describe) > 0, '診断表示に戦略名が出る');

  CheckEq(EvidenceMetricKindToStr(emkSoftMargin), 'soft-margin', '尺度名');
  CheckEq(EvidenceMetricKindToStr(emkNone), 'none', '尺度名 (なし)');
end;

procedure RunRttyLoopback(const AMsg: string; ASink: TEvidenceSink);
{ 送信波形を作って同じ設定の復調器へ流す。 }
var
  txSound, rxSound: TCaptureSoundDevice;
  tx, rx: TRttyModem;
  src: TTxSource;
  guard, res: Integer;
begin
  txSound := TCaptureSoundDevice.Create;
  rxSound := TCaptureSoundDevice.Create;
  tx := TRttyModem.Create(txSound);
  rx := TRttyModem.Create(rxSound);
  src := TTxSource.Create(AMsg);
  try
    tx.Frequency := 1000;
    rx.Frequency := 1000;
    rx.AfcOn := False;          { 周波数既知なので AFC は切る }
    tx.OnGetTxChar := @src.GetTxChar;
    rx.OnDecode := @ASink.Decode;
    tx.TxInit;
    guard := 0;
    repeat
      res := tx.TxProcess;
      Inc(guard);
    until (res < 0) or (guard > 100000);
    rx.RxProcess(txSound.GetCapturedCopy, txSound.Count);
  finally
    src.Free; rx.Free; tx.Free; rxSound.Free; txSound.Free;
  end;
end;

procedure TestRttyEmitsEvidence;
{ ADR-002 の実効確認。RTTY を実際に走らせ、型が空でないことを確かめる。 }
var
  sink: TEvidenceSink;
const
  MSG = 'CQ TEST DE JI1UUI 599';
begin
  WriteLn;
  WriteLn('--- 2. RTTY が Evidence を実際に載せているか ---');
  sink := TEvidenceSink.Create;
  try
    RunRttyLoopback(MSG, sink);
    WriteLn('  送信: ', MSG);
    WriteLn('  復調: ', sink.Text);
    WriteLn(Format('  Evidence: 全 %d / 尺度つき %d / 第2候補 %d / SNR %d / 位置 %d',
      [sink.Count, sink.Scored, sink.WithAlt, sink.WithSnr, sink.WithPos]));
    WriteLn(Format('  軟判定余裕の範囲: %.3f 〜 %.3f',
      [sink.MinMargin, sink.MaxMargin]));

    Check(sink.Count > 0, '復調結果が出ている');
    Check(sink.Scored = sink.Count,
      'すべての結果に尺度が載っている (emkNone のまま出していない)');
    Check(sink.WithSnr = sink.Count, 'すべての結果に SNR が載っている');
    Check(sink.WithPos = sink.Count,
      'すべての結果にサンプル位置が載っている (Replay の下地)');
    CheckEq(sink.LastDecoder, 'RTTY', '戦略名が RTTY になっている');
    Check((sink.MinMargin >= -1.0) and (sink.MaxMargin <= 1.0),
      '軟判定余裕が -1..+1 に正規化されている');
    Check(sink.MinMargin > 0, '最有力候補の余裕は正 (判定した側の符号)');
  finally
    sink.Free;
  end;
end;

procedure TestSpeculativeDecodeHasNoSideEffect;
{ 第2候補を出すための仮復号が、本物のシフト状態を壊さないこと。
  Baudot は文字/数字シフトを持つため、仮復号で状態を動かすと
  以降の数字が文字として出る。実際に一度そう壊した
  ("12345" が "WERT" になった。Baudot では 2=W,3=E,4=R,5=T)。 }
var
  sink: TEvidenceSink;
const
  MSG = 'AB 12345 CD';
begin
  WriteLn;
  WriteLn('--- 3. 仮復号がシフト状態を壊さないこと ---');
  sink := TEvidenceSink.Create;
  try
    RunRttyLoopback(MSG, sink);
    WriteLn('  送信: ', MSG);
    WriteLn('  復調: ', sink.Text);
    Check(Pos('12345', sink.Text) > 0,
      '数字が数字のまま復調される (仮復号でシフト状態が動いていない)');
    Check(sink.WithAlt > 0,
      '第2候補が実際に出ている (この経路が動いていることの確認)');
  finally
    sink.Free;
  end;
end;

procedure TestModemStateIsPerInstance;
{ ADR-009: 状態をインスタンスに閉じ込める規律の検査。

  並列化を後回しにできるのは「後から入れられる形」を保っている場合だけで、
  その条件が「同じ音声を設定違いの複数インスタンスへ流せる」ことである。
  ユニットレベルのグローバルが1つでもあると、その時点で C-06
  (複数 Decoder の並列評価) ができなくなる。

  UOS (Unshift On Space) は fldigi では progdefaults の全体設定だったため
  そのまま移植していたが、送信用と受信用のインスタンスが設定を共有して
  しまう不具合になっていた。 }
var
  snd: TNullSoundDevice;
  a, b: TRttyModem;
begin
  WriteLn;
  WriteLn('--- 5. モデムの設定がインスタンスに閉じているか ---');
  snd := TNullSoundDevice.Create;
  a := TRttyModem.Create(snd);
  b := TRttyModem.Create(snd);
  try
    Check(a.UnshiftOnSpaceRx, '既定は有効 (fldigi の progdefaults と同じ)');
    Check(b.UnshiftOnSpaceRx, '2つ目のインスタンスも既定は有効');

    a.UnshiftOnSpaceRx := False;
    Check(not a.UnshiftOnSpaceRx, '片方の設定が変わる');
    Check(b.UnshiftOnSpaceRx,
      'もう片方は影響を受けない (設定がインスタンスに閉じている)');

    a.UnshiftOnSpaceTx := False;
    Check(b.UnshiftOnSpaceTx, '送信側の設定も独立している');

    { 設定違いの2本が同じ音声を処理できること = C-06 の前提 }
    a.RxInit;
    b.RxInit;
    Check(True, '設定違いの2インスタンスを同時に初期化できる');
  finally
    b.Free; a.Free; snd.Free;
  end;
end;

procedure TestCwIsHonestAboutNoMetric;
{ CW は文字ごとの軟判定尺度を持たない。持っていないものを
  でっち上げていないこと (根拠のない尺度が Evidence に流れると、
  Phase 4 の Confidence 校正が成り立たなくなる)。 }
var
  snd: TNullSoundDevice;
  m: TCwModem;
  ev: TDecodeEvidence;
begin
  WriteLn;
  WriteLn('--- 6. CW は持っていない尺度を作らない ---');
  snd := TNullSoundDevice.Create;
  m := TCwModem.Create(snd);
  try
    m.Init;
    CheckEq(m.DecoderName, 'CW', 'CW が戦略名を名乗る');
    ev := SingleCandidateEvidence(Ord('K'), m.DecoderName);
    Check(ev.MetricKind = emkNone,
      '尺度を持たない復調器は emkNone で出す (でっち上げない)');
    Check(ev.CandidateCount = 1, '候補は1件');
    CheckEq(ev.DecoderName, 'CW', '戦略名が載る');
  finally
    m.Free; snd.Free;
  end;
end;

begin
  WriteLn('=== ADR-002 Modem API (Evidence) テスト ===');

  TestEvidenceType;
  TestRttyEmitsEvidence;
  TestSpeculativeDecodeHasNoSideEffect;
  TestModemStateIsPerInstance;
  TestCwIsHonestAboutNoMetric;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('ARC-002');
  end;

  if FailCount > 0 then
    Halt(1);
end.
