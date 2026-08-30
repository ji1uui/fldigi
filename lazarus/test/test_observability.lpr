{ ============================================================================
  test_observability.lpr

  Z-01 Observability の検証。

  観測機構そのものが要求を壊してはいけないので、重点は 2 つ。

    1. 記録が確保しないこと (X-04 / ADR-009)
       観測のために deadline を落としては本末転倒である。
       メモリマネージャを差し替えて確保回数を実測する。

    2. 実際に「診断に使える情報」が残ること
       件数だけ数えても診断はできない。順序・発生元・値が残り、
       捨てた場合はそれが分かる必要がある。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_observability;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math,
  SoundIntf, ModemTypes, Modem, ModemEngine, ModemUI, DecodeEvidence,
  EventBus, Observability, NullModemImpl, TestSupport, Requirements;

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

{ --------------------------------------------------------------------------
  確保回数を数えるメモリマネージャ (test_realtime と同じ仕掛け)
  -------------------------------------------------------------------------- }
var
  GBaseMM: TMemoryManager;
  GCounting: Boolean = False;
  GAllocCount: Int64 = 0;

function CountingGetMem(Size: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GBaseMM.GetMem(Size);
end;

function CountingFreeMem(p: Pointer): PtrUInt;
begin
  Result := GBaseMM.FreeMem(p);
end;

function CountingFreeMemSize(p: Pointer; Size: PtrUInt): PtrUInt;
begin
  Result := GBaseMM.FreeMemSize(p, Size);
end;

function CountingAllocMem(Size: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GBaseMM.AllocMem(Size);
end;

function CountingReAllocMem(var p: Pointer; Size: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GBaseMM.ReAllocMem(p, Size);
end;

function CountingMemSize(p: Pointer): PtrUInt;
begin
  Result := GBaseMM.MemSize(p);
end;

procedure InstallCountingMM;
var
  mm: TMemoryManager;
begin
  GetMemoryManager(GBaseMM);
  mm := GBaseMM;
  mm.GetMem := @CountingGetMem;
  mm.FreeMem := @CountingFreeMem;
  mm.FreeMemSize := @CountingFreeMemSize;
  mm.AllocMem := @CountingAllocMem;
  mm.ReAllocMem := @CountingReAllocMem;
  mm.MemSize := @CountingMemSize;
  SetMemoryManager(mm);
end;

procedure RestoreMM;
begin
  SetMemoryManager(GBaseMM);
end;

{ --------------------------------------------------------------------------
  テスト
  -------------------------------------------------------------------------- }

procedure TestRecordingIsAllocationFree;
{ 観測のために realtime 経路へ確保を持ち込んでいないこと。 }
const
  N = 2000;
var
  log: TObsLog;
  metric: TObsMetric;
  nm: TObsName;
  i: Integer;
  allocLog, allocMetric: Int64;
begin
  WriteLn;
  WriteLn('--- 1. 記録が確保しないこと ---');
  log := TObsLog.Create(256);
  metric := TObsMetric.Create('block', 'ms', 64.0);
  try
    log.MinSeverity := obsTrace;
    SetObsName(nm, 'RTTY');
    { 事前に一度回して初回コストを測定から外す }
    log.AddRaw(obsInfo, ocatDsp, ocdDecodeEmitted, nm, 65);
    metric.Observe(0.5);

    GAllocCount := 0; GCounting := True;
    for i := 1 to N do
      log.AddRaw(obsInfo, ocatDsp, ocdDecodeEmitted, nm, 65, 0, 0.5, 12.3);
    GCounting := False;
    allocLog := GAllocCount;

    GAllocCount := 0; GCounting := True;
    for i := 1 to N do
      metric.Observe(0.4 + i * 0.0001);
    GCounting := False;
    allocMetric := GAllocCount;

    WriteLn(Format('  出来事 %d 件の記録: 確保 %d 回', [N, allocLog]));
    WriteLn(Format('  統計 %d 件の記録  : 確保 %d 回', [N, allocMetric]));
    Check(allocLog = 0, '出来事の記録で一切確保しない');
    Check(allocMetric = 0, '統計の記録で一切確保しない');

    { 文字列版は確保しうる。realtime 経路では AddRaw を使う、という
      使い分けが成立していることを明示しておく。 }
    Check(log.TotalRecorded = N + 1, '記録件数が数えられている');
  finally
    metric.Free;
    log.Free;
  end;
end;

procedure TestLogIsBoundedAndOrdered;
var
  log: TObsLog;
  recs: TObsRecordArray;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 出来事の記録が有界で順序を保つこと ---');
  log := TObsLog.Create(16);
  try
    for i := 1 to 100 do
      log.Add(obsInfo, ocatDsp, ocdDecodeEmitted, 'RTTY', i);

    Check(log.PendingCount = 16, '容量を超えて溜まらない (実際: ' +
      IntToStr(log.PendingCount) + ')');
    Check(log.DroppedCount = 84, '捨てた件数が分かる (実際: ' +
      IntToStr(log.DroppedCount) + ')');
    Check(log.TotalRecorded = 100, '通算件数が分かる');

    recs := log.Snapshot;
    Check(Length(recs) = 16, 'スナップショットは保持分だけ返す');
    Check(recs[0].I1 = 85, '古いものから捨てられ新しい方が残る');
    Check(recs[15].I1 = 100, '最新が残る');
    for i := 1 to High(recs) do
      if recs[i].I1 <> recs[i - 1].I1 + 1 then
      begin
        Check(False, '順序が保たれる');
        Exit;
      end;
    Check(True, '順序が保たれる');
  finally
    log.Free;
  end;
end;

procedure TestSeverityFilter;
var
  log: TObsLog;
begin
  WriteLn;
  WriteLn('--- 3. 重大度による絞り込み ---');
  log := TObsLog.Create(64);
  try
    Check(log.MinSeverity = obsInfo, '既定は INFO 以上');
    log.Add(obsTrace, ocatDsp, ocdDecodeEmitted, 'RTTY');
    Check(log.PendingCount = 0, 'TRACE は既定では記録しない');
    log.Add(obsWarning, ocatAudio, ocdAudioOverflow, 'pa');
    Check(log.PendingCount = 1, 'WARN は記録する');

    log.MinSeverity := obsTrace;
    log.Add(obsTrace, ocatDsp, ocdDecodeEmitted, 'RTTY');
    Check(log.PendingCount = 2, 'TRACE まで下げれば記録する');
  finally
    log.Free;
  end;
end;

procedure TestMetricStatistics;
var
  m: TObsMetric;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 4. 統計 ---');
  m := TObsMetric.Create('block', 'ms', 64.0);
  try
    Check(m.Count = 0, '初期状態は 0 件');
    Check(Abs(m.Mean) < 1E-12, '0 件なら平均は 0');

    for i := 1 to 100 do
      m.Observe(i * 0.1);          { 0.1 〜 10.0 }
    Check(m.Count = 100, '件数');
    Check(Abs(m.MinValue - 0.1) < 1E-9, '最小値');
    Check(Abs(m.MaxValue - 10.0) < 1E-9, '最大値');
    Check(Abs(m.Mean - 5.05) < 1E-9, '平均 (実際: ' +
      FormatFloat('0.000', m.Mean) + ')');
    Check(m.OverBudgetCount = 0, '予算 (64ms) を超えていない');

    { 予算超過を数えること = Z-04 の判定材料 }
    m.Observe(100.0);
    Check(m.OverBudgetCount = 1, '予算を超えた件数が分かる');
    Check(Pos('予算超過 1 件', m.Describe) > 0, '要約に予算超過が出る');

    { 分布が残ること }
    Check(Pos(':', m.DescribeDistribution) > 0, '分布が読める形で出る');

    m.Reset;
    Check(m.Count = 0, 'リセットできる');
  finally
    m.Free;
  end;
end;

type
  { 障害を起こす購読者 (バスの例外封じ込めと記録の両立を見る) }
  TBadSubscriber = class
  public
    procedure Handle(const AEvent: TBusEvent);
  end;

procedure TBadSubscriber.Handle(const AEvent: TBusEvent);
begin
  raise Exception.Create('購読者の障害を模擬');
end;

procedure TestBusRecorder;
{ バスに購読を 1 つ足すだけで「何が起きたか」が残ること。
  発行元 (モデム/エンジン) には一切手を入れていない。 }
var
  bus: TEventBus;
  log: TObsLog;
  rec: TObsBusRecorder;
  snr: TObsMetric;
  recs: TObsRecordArray;
  bad: TBadSubscriber;
begin
  WriteLn;
  WriteLn('--- 5. Event Bus からの記録 ---');
  bus := TEventBus.Create;
  log := TObsLog.Create(128);
  snr := TObsMetric.Create('decode.snr', 'dB');
  bad := TBadSubscriber.Create;
  try
    bus.AutoDispatch := False;
    log.MinSeverity := obsTrace;
    rec := TObsBusRecorder.Create(bus, log);
    try
      rec.DecodeSnrMetric := snr;

      bus.PublishNumeric(bekDecodedSymbol, Ord('E'), Ord(emkSoftMargin),
        0.42, 12.5, 'RTTY', 1);
      bus.PublishNumeric(bekTrxStateChanged, 2, 0, 0, 0, 'engine');
      bus.PublishText(bekError, 'デバイス障害', 'audio');
      bus.DispatchPending;

      Check(log.PendingCount = 3, '3 件記録された (実際: ' +
        IntToStr(log.PendingCount) + ')');
      recs := log.Snapshot;
      Check(recs[0].Code = ocdDecodeEmitted, '復調イベントが記録される');
      CheckEq(recs[0].SourceStr, 'RTTY',
        '発行元 (復調戦略名) が残る = どの戦略が出したか分かる');
      Check(recs[0].I1 = Ord('E'), '文字コードが残る');
      Check(Abs(recs[0].D1 - 0.42) < 1E-9, '尺度が残る');
      Check(Abs(recs[0].D2 - 12.5) < 1E-9, 'SNR が残る');
      Check(recs[2].Severity = obsError, 'エラーは ERROR として記録される');

      { アルゴリズム改善のための材料が溜まること }
      Check(snr.Count = 1, 'SNR が統計へ積まれる');
      Check(Abs(snr.Mean - 12.5) < 1E-9, 'SNR の値');

      { 購読者が壊れてもバスも記録も止まらないこと }
      bus.Subscribe(@bad.Handle);
      bus.PublishNumeric(bekDecodedSymbol, Ord('T'), 0, 0, 9.0, 'CW');
      bus.DispatchPending;
      Check(log.PendingCount = 4,
        '他の購読者が例外を投げても記録は続く');
      Check(bus.SubscriberErrorCount = 1, 'バスが例外件数を数えている');
    finally
      rec.Free;
    end;
    { 記録者を外したら記録されないこと }
    bus.PublishNumeric(bekDecodedSymbol, Ord('X'));
    bus.DispatchPending;
    Check(log.PendingCount = 4, '記録者を破棄したら記録されない');
  finally
    bad.Free; snr.Free; log.Free; bus.Free;
  end;
end;

procedure TestEndToEndFromModem;
{ 実際の経路 (モデム → ModemUI → バス → 記録) で、アルゴリズム改善に要る
  情報が最後まで届くこと。

  バスへ直接発行するテストでは、ModemUI が途中で値を落としていても
  気づけない。実際に一度、ModemUI が Evidence の SNR と復調戦略名を
  捨てていた (UI 自身の名前で発行していた)。 }
var
  bus: TEventBus;
  log: TObsLog;
  rec: TObsBusRecorder;
  snr: TObsMetric;
  ui: TModemUI;
  ev: TDecodeEvidence;
  recs: TObsRecordArray;
begin
  WriteLn;
  WriteLn('--- 6. モデムから記録までの通し ---');
  bus := TEventBus.Create;
  log := TObsLog.Create(64);
  snr := TObsMetric.Create('decode.snr', 'dB');
  try
    bus.AutoDispatch := False;
    log.MinSeverity := obsTrace;
    rec := TObsBusRecorder.Create(bus, log);
    ui := TModemUI.Create(bus);
    try
      rec.DecodeSnrMetric := snr;

      { 復調器が出すのと同じ形の Evidence を通す }
      ev := ScoredCandidateEvidence(Ord('E'), 0.47, emkSoftMargin, 'RTTY');
      ev.HasSnr := True;
      ev.SnrDb := 14.25;
      AddCandidate(ev, Ord('I'), -0.47);
      ui.PushDecode(ev);
      bus.DispatchPending;

      Check(log.PendingCount = 1, '記録に届く');
      recs := log.Snapshot;
      CheckEq(recs[0].SourceStr, 'RTTY',
        '復調戦略名が最後まで届く (UI の名前で上書きされていない)');
      Check(Abs(recs[0].D2 - 14.25) < 1E-9,
        'SNR が最後まで届く (実際: ' + FormatFloat('0.00', recs[0].D2) + ')');
      Check(Abs(recs[0].D1 - 0.47) < 1E-9, '軟判定の尺度が届く');
      Check(recs[0].I2 = Ord(emkSoftMargin), '尺度の種類が届く');
      Check(recs[0].I1 = Ord('E'), '最有力候補の文字が届く');
      Check(snr.Count = 1, 'SNR が統計へ積まれる');
      Check(Abs(snr.Mean - 14.25) < 1E-9, 'SNR の値が正しい');
    finally
      ui.Free;
      rec.Free;
    end;
  finally
    snr.Free; log.Free; bus.Free;
  end;
end;

procedure TestEngineBlockMetric;
{ Z-04: エンジンが 1 ブロックの復調時間を積めること。
  結合を増やさないよう注入型にしてあるので、設定しなければ何も測らない。 }
var
  snd: TNullSoundDevice;
  eng: TModemEngine;
  modem: TNullModem;
  m: TObsMetric;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 7. エンジンのブロック処理時間 ---');
  snd := TNullSoundDevice.Create;
  snd.Open(sdRead, 8000);
  modem := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  m := TObsMetric.Create('engine.block', 'ms', 64.0);
  try
    Check(eng.BlockMetric = nil, '既定では測らない (結合を強いない)');
    eng.BlockMetric := m;
    eng.SetModem(modem);
    eng.Start;
    eng.RequestReceive;
    for i := 1 to 40 do
    begin
      CheckSynchronize(10);
      Sleep(5);
    end;
    eng.RequestExit;
    eng.WaitFor;

    WriteLn('  ', m.Describe);
    Check(m.Count > 0, 'ブロック処理時間が積まれた (実際: ' +
      IntToStr(m.Count) + ' 件)');
    Check(m.OverBudgetCount = 0,
      'deadline (64ms) を超えたブロックが無い');
  finally
    m.Free; eng.Free; modem.Free; snd.Free;
  end;
end;

procedure TestRegistryExport;
{ 障害報告に貼れる形で出せること。「どこを見れば分かるか」が
  1 か所にまとまっていないと、診断のたびに探し回ることになる。 }
var
  reg: TObsRegistry;
  txt: string;
begin
  WriteLn;
  WriteLn('--- 8. 集約と書き出し ---');
  reg := TObsRegistry.Create(64);
  try
    reg.Metric('engine.block', 'ms', 64.0).Observe(0.7);
    reg.Metric('engine.block', 'ms').Observe(0.9);
    Check(reg.MetricCount = 1, '同じ名前は同じ統計を指す');
    Check(reg.Metric('engine.block', 'ms').Count = 2, '2 件積まれている');

    reg.Metric('decode.snr', 'dB').Observe(12.0);
    Check(reg.MetricCount = 2, '別名なら別の統計');

    reg.Log.Add(obsWarning, ocatAudio, ocdAudioOverflow, 'pa', 3);
    txt := reg.Export_;
    Check(Pos('engine.block', txt) > 0, '統計名が出る');
    Check(Pos('decode.snr', txt) > 0, '複数の統計が出る');
    Check(Pos('AudioOverflow', txt) > 0, '出来事が出る');
    Check(Pos('=== 出来事', txt) > 0, '章立てがある');

    { 範囲外の添字 }
    try
      reg.MetricAt(99);
      Check(False, '範囲外の添字は例外');
    except
      on E: Exception do
        Check(True, '範囲外の添字は例外');
    end;
  finally
    reg.Free;
  end;
end;

procedure TestNameTruncation;
var
  log: TObsLog;
  recs: TObsRecordArray;
begin
  WriteLn;
  WriteLn('--- 9. 発生元名の扱い ---');
  log := TObsLog.Create(8);
  try
    log.Add(obsInfo, ocatDsp, ocdDecodeEmitted, 'RTTY');
    log.Add(obsInfo, ocatDsp, ocdDecodeEmitted,
      'とても長い戦略名がここに入る場合の切り詰め確認用の文字列');
    log.Add(obsInfo, ocatDsp, ocdDecodeEmitted, '');
    recs := log.Snapshot;
    CheckEq(recs[0].SourceStr, 'RTTY', '短い名前はそのまま');
    Check(Length(recs[1].SourceStr) <= OBS_NAME_LEN,
      '長い名前は切り詰められる (固定長なので溢れない)');
    CheckEq(recs[2].SourceStr, '', '空でも壊れない');
  finally
    log.Free;
  end;
end;

begin
  WriteLn('=== Z-01 Observability テスト ===');
  InstallCountingMM;
  try
    TestRecordingIsAllocationFree;
  finally
    RestoreMM;
  end;

  TestLogIsBoundedAndOrdered;
  TestSeverityFilter;
  TestMetricStatistics;
  TestBusRecorder;
  TestEndToEndFromModem;
  TestEngineBlockMetric;
  TestRegistryExport;
  TestNameTruncation;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('OBS-001');
    CoverReq('OBS-002');
    CoverReq('OBS-003');
  end;

  if FailCount > 0 then
    Halt(1);
end.
