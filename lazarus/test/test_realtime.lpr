{ ============================================================================
  test_realtime.lpr

  X-04「Realtime 経路で動的 memory allocation を最小化する」の検証。

  なぜメモリマネージャを差し替えるのか:
  ----------------------------------------------------------------------------
  「確保していないこと」はコードを読むだけでは保証できない。動的配列の
  SetLength、文字列の連結、一時オブジェクトの生成は見落としやすく、
  しかも確保と解放が対になっていると使用量を測っても検出できない
  (増えて減るので差分が 0 になる)。

  そこで測定区間だけメモリマネージャを差し替え、GetMem / FreeMem の
  呼び出し回数そのものを数える。これなら「1ブロックあたり何回確保したか」を
  直接見られる。

  なぜ回数が問題なのか:
  ----------------------------------------------------------------------------
  FPC のメモリマネージャはロックを取る。音声スレッドがそこで待たされると
  deadline を落とし、underrun になる (v1.1 Z-04 Deterministic Realtime)。
  8000Hz / 512サンプルなら毎秒 16 ブロック、送受信の両方で走る。
  1ブロックあたり数回の確保でも、待ちの分散が読めなくなる。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_realtime;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math,
  SoundIntf, ModemTypes, Modem, ModemDSP, DecodeEvidence,
  RttyModemImpl, CwModemImpl, PskModemImpl, TestSupport, Requirements;

const
  { --- deadline に対する判定しきい値 (v1.1 Z-04) ---
    判定を平均 CPU 使用率ではなく「1ブロックの処理時間」に置くのは、
    音声が途切れる原因が平均負荷ではなく deadline 超過だからである。
    平均が 1% でも、たまに 100ms かかれば underrun する。

    実測 (このコンテナ, 3000ブロック x 3回):
      RTTY 平均 1.1〜1.2% / p99 1.2〜1.7% / 最悪 1.8〜4.7%
      CW   平均 0.54%     / p99 1.07%     / 最悪 1.32%

    最悪値だけは実行ごとに 3 倍近くばらつく (OS のスケジューラに
    割り込まれるため)。そこで
      - 平均と p99 は安定するので厳しめに (8〜9倍の余裕)
      - 最悪値はスケジューラ由来の外れ値を許すため緩めに (10倍の余裕)
    という置き方にする。緩くても「20倍遅くなった」は捕まえられる。 }
  MAX_MEAN_RATIO = 0.10;   // 平均は deadline の 10% 未満
  MAX_P99_RATIO  = 0.15;   // p99 は 15% 未満
  MAX_PEAK_RATIO = 0.50;   // 最悪でも 50% 未満 (絶対に落とさない側の保険)

const
  { 送信 1 回ぶんの測定で許す確保回数。送信量に比例して増えないことを
    見るための上限であり、絶対値そのものに意味はない。 }
  MAX_TX_ALLOC = 20;

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

{ --------------------------------------------------------------------------
  確保回数を数えるメモリマネージャ
  -------------------------------------------------------------------------- }
var
  GBaseMM: TMemoryManager;
  GCounting: Boolean = False;
  GGetMemCount: Int64 = 0;
  GReallocCount: Int64 = 0;

function CountingGetMem(Size: PtrUInt): Pointer;
begin
  if GCounting then Inc(GGetMemCount);
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
  if GCounting then Inc(GGetMemCount);
  Result := GBaseMM.AllocMem(Size);
end;

function CountingReAllocMem(var p: Pointer; Size: PtrUInt): Pointer;
begin
  if GCounting then Inc(GReallocCount);
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

procedure BeginMeasure;
begin
  GGetMemCount := 0;
  GReallocCount := 0;
  GCounting := True;
end;

procedure EndMeasure;
begin
  GCounting := False;
end;

{ --------------------------------------------------------------------------
  テスト
  -------------------------------------------------------------------------- }

procedure TestSoundWritePathIsAllocationFree;
{ 送信の最内周: モデムが作った波形をサウンドデバイスへ渡す経路。 }
var
  snd: TCaptureSoundDevice;
  buf: array[0..511] of Double;
  i, k: Integer;
  alloc: Int64;
const
  BLOCKS = 200;
begin
  WriteLn;
  WriteLn('--- 1. サウンド書き込み経路 ---');
  snd := TCaptureSoundDevice.Create;
  try
    snd.Open(sdWrite, 8000);
    for i := 0 to High(buf) do
      buf[i] := Sin(i * 0.01);
    { 測定前に一度回して、バッファの初回確保を済ませておく }
    snd.WriteSamples(buf, Length(buf));

    BeginMeasure;
    for k := 1 to BLOCKS do
      snd.WriteSamples(buf, Length(buf));
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  %d ブロック書き込み: 確保 %d 回 (1ブロックあたり %.2f 回)',
      [BLOCKS, alloc, alloc / BLOCKS]));
    { TCaptureSoundDevice は波形を溜め続けるので容量拡張が起きる。
      それを除いた「変換処理そのもの」が確保しないことを見たいので、
      1ブロックあたり 1 回未満であることを条件にする。 }
    { 確保がブロック数に比例していないこと。TCaptureSoundDevice の
      容量拡張 (テスト側の都合) だけが残るので、小さな定数で抑える。 }
    Check(alloc <= 20, Format(
      '確保回数がブロック数に比例しない (%d 回 / %d ブロック)', [alloc, BLOCKS]));
  finally
    snd.Free;
  end;
end;

procedure TestRttyTxPathIsAllocationFree;
{ RTTY 送信: SendSymbol がシンボルごとに波形バッファを確保していないこと。 }
var
  snd: TCaptureSoundDevice;
  tx: TRttyModem;
  src: TTxSource;
  guard, res: Integer;
  alloc: Int64;
begin
  WriteLn;
  WriteLn('--- 2. RTTY 送信経路 ---');
  snd := TCaptureSoundDevice.Create;
  tx := TRttyModem.Create(snd);
  src := TTxSource.Create('CQ CQ DE JI1UUI JI1UUI K');
  try
    tx.Frequency := 1000;
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    { 1文字ぶん先に流してバッファを確保させる }
    tx.TxProcess;

    BeginMeasure;
    guard := 0;
    repeat
      res := tx.TxProcess;
      Inc(guard);
    until (res < 0) or (guard > 100000);
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  送信 %d サンプル: 確保 %d 回', [snd.Count, alloc]));
    { シンボルごとに確保していると送信文字数に比例して増える
      (修正前は同条件で 242 回だった)。小さな定数で抑える。 }
    Check(alloc <= MAX_TX_ALLOC, Format(
      '確保回数が送信量に比例しない (%d 回 / 上限 %d)', [alloc, MAX_TX_ALLOC]));
  finally
    src.Free; tx.Free; snd.Free;
  end;
end;

procedure TestRttyRxBlockIsAllocationFree;
{ RTTY 受信: 音声ブロックの処理そのものが確保しないこと。

  復調して文字が出た瞬間は Evidence (候補配列) を作るので確保が入る。
  これは意図的な設計で、RTTY 45baud なら毎秒 6 回程度、音声ブロックの
  16 回/秒と比べても支配的でない。ここで見たいのは
  「文字が出ない普通のブロックで確保が走っていないか」なので、
  無信号を流して測る。 }
var
  snd: TCaptureSoundDevice;
  rx: TRttyModem;
  sink: TEvidenceSink;
  buf: array[0..511] of Double;
  i, k: Integer;
  alloc: Int64;
const
  BLOCKS = 100;
begin
  WriteLn;
  WriteLn('--- 3. RTTY 受信ブロック処理 ---');
  snd := TCaptureSoundDevice.Create;
  rx := TRttyModem.Create(snd);
  sink := TEvidenceSink.Create;
  try
    rx.Frequency := 1000;
    rx.AfcOn := False;
    rx.RxInit;
    rx.OnDecode := @sink.Decode;
    for i := 0 to High(buf) do
      buf[i] := 0.001 * Sin(i * 0.37);   { 無信号に近い雑音 }
    rx.RxProcess(buf, Length(buf));      { 初回のフィルタ確保を済ませる }

    BeginMeasure;
    for k := 1 to BLOCKS do
      rx.RxProcess(buf, Length(buf));
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  %d ブロック復調 (出力 %d 文字): 確保 %d 回 (1ブロックあたり %.2f 回)',
      [BLOCKS, sink.Count, alloc, alloc / BLOCKS]));
    Check(alloc = 0, '受信ブロック処理で一切確保していない');
  finally
    sink.Free; rx.Free; snd.Free;
  end;
end;

procedure TestCwTxPathIsAllocationFree;
var
  snd: TCaptureSoundDevice;
  tx: TCwModem;
  src: TTxSource;
  guard, res: Integer;
  alloc: Int64;
begin
  WriteLn;
  WriteLn('--- 4. CW 送信経路 ---');
  snd := TCaptureSoundDevice.Create;
  tx := TCwModem.Create(snd);
  src := TTxSource.Create('CQ DE JI1UUI K');
  try
    tx.Frequency := 700;
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    tx.TxProcess;

    BeginMeasure;
    guard := 0;
    repeat
      res := tx.TxProcess;
      Inc(guard);
    until (res < 0) or (guard > 100000);
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  送信 %d サンプル: 確保 %d 回', [snd.Count, alloc]));
    { 修正前は同条件で 66 回だった。 }
    Check(alloc <= MAX_TX_ALLOC, Format(
      '確保回数が送信量に比例しない (%d 回 / 上限 %d)', [alloc, MAX_TX_ALLOC]));
  finally
    src.Free; tx.Free; snd.Free;
  end;
end;

procedure TestMeasurementItselfWorks;
{ 測定の仕掛けが本当に効いているかを確かめる。
  わざと確保する処理を測って 0 でないことを見ておかないと、
  上のテストが「測れていないから 0」でも通ってしまう。 }
var
  a: array of Double;
  k: Integer;
  alloc: Int64;
begin
  WriteLn;
  WriteLn('--- 5. 測定そのものの妥当性 ---');
  BeginMeasure;
  for k := 1 to 50 do
  begin
    a := nil;
    SetLength(a, 1000);
    a[0] := k;
  end;
  EndMeasure;
  alloc := GGetMemCount + GReallocCount;
  WriteLn(Format('  意図的に 50 回確保: 検出 %d 回', [alloc]));
  Check(alloc >= 50, '確保を実際に検出できている (測定が空振りしていない)');
end;

procedure MeasureRxDeadline(const AName: string; AModem: TCustomModem;
  AFreqHz: Double);
{ 受信ブロックの処理時間を測り、deadline に対する余裕を判定する。 }
const
  BLK = 512;
  SR = 8000;
  WARMUP = 200;
  SAMPLES = 2000;
var
  buf: array[0..BLK - 1] of Double;
  ms: TDoubleArray;
  i, k: Integer;
  t0: Double;
  st: TBlockTiming;
begin
  WriteLn;
  WriteLn('--- ', AName, ' 受信ブロックの deadline 余裕 ---');
  ms := nil;
  SetLength(ms, SAMPLES);
  for i := 0 to BLK - 1 do
    buf[i] := 0.3 * Sin(2 * Pi * AFreqHz * i / SR) + 0.05 * Sin(i * 0.7);

  AModem.RxInit;
  { フィルタ生成などの初回コストを測定から外す }
  for k := 1 to WARMUP do
    AModem.RxProcess(buf, BLK);

  for k := 0 to SAMPLES - 1 do
  begin
    t0 := HiResSeconds;
    AModem.RxProcess(buf, BLK);
    ms[k] := (HiResSeconds - t0) * 1000;
  end;

  st := SummarizeBlockTiming(ms, 1000.0 * BLK / SR);
  WriteLn('  ', st.Describe);

  Check(st.MeanRatio < MAX_MEAN_RATIO, Format(
    '平均が deadline の %.0f%% 未満 (実際 %.2f%%)',
    [100 * MAX_MEAN_RATIO, 100 * st.MeanRatio]));
  Check(st.P99Ratio < MAX_P99_RATIO, Format(
    'p99 が deadline の %.0f%% 未満 (実際 %.2f%%)',
    [100 * MAX_P99_RATIO, 100 * st.P99Ratio]));
  Check(st.MaxRatio < MAX_PEAK_RATIO, Format(
    '最悪でも deadline の %.0f%% 未満 (実際 %.2f%%)',
    [100 * MAX_PEAK_RATIO, 100 * st.MaxRatio]));
end;

{ PSK 送信: 記号ごとに波形バッファを確保していないこと。

  **なぜ後から足したか**: RT-001 / RT-002 は Phase 0 の要求で「検証済」に
  なっているが、この試験を書いた時点でモデムは RTTY と CW の 2 つだった。
  Phase 2 で PSK を足したとき、ここに追加するのを忘れていた。
  要求の状態は「検証済」のまま、実際の被覆だけが狭まっていた形である。
  要求が全モデムを指している以上、モデムを足したらここも足す。 }
procedure TestPskTxPathIsAllocationFree;
var
  snd: TCaptureSoundDevice;
  tx: TPskModem;
  src: TTxSource;
  guard, res: Integer;
  alloc: Int64;
begin
  WriteLn;
  WriteLn('--- 5. PSK 送信経路 ---');
  snd := TCaptureSoundDevice.Create;
  tx := TPskModem.Create(snd, mmPSK31);
  src := TTxSource.Create('CQ CQ DE JI1UUI K');
  try
    tx.Frequency := 1000;
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    tx.TxProcess;   { 1 文字ぶん先に流してバッファを確保させる }

    BeginMeasure;
    guard := 0;
    repeat
      res := tx.TxProcess;
      Inc(guard);
    until (res < 0) or (guard > 100000);
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  送信 %d サンプル: 確保 %d 回', [snd.Count, alloc]));
    Check(alloc <= MAX_TX_ALLOC, Format(
      '確保回数が送信量に比例しない (%d 回 / 上限 %d)', [alloc, MAX_TX_ALLOC]));
  finally
    src.Free; tx.Free; snd.Free;
  end;
end;

procedure TestPskRxBlockIsAllocationFree;
{ PSK 受信: 音声ブロックの処理そのものが確保しないこと。

  文字が出た瞬間は Evidence (候補配列) を作るので確保が入る。ここで
  見たいのは「文字が出ない普通のブロックで確保が走っていないか」なので、
  位相反転の無い純音を流す (DCD が立たず文字も出ない)。 }
var
  snd: TCaptureSoundDevice;
  rx: TPskModem;
  buf: array[0..511] of Double;
  i, k: Integer;
  alloc: Int64;
const
  BLOCKS = 100;
begin
  WriteLn;
  WriteLn('--- 6. PSK 受信ブロック処理 ---');
  snd := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(snd, mmPSK31);
  try
    rx.Frequency := 1000;
    rx.RxInit;
    for i := 0 to High(buf) do
      buf[i] := 0.5 * Sin(2 * Pi * 1000 * i / rx.SampleRate);
    rx.RxProcess(buf, Length(buf));   { 初回のフィルタ確保を済ませる }

    BeginMeasure;
    for k := 1 to BLOCKS do
      rx.RxProcess(buf, Length(buf));
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  %d ブロック復調: 確保 %d 回 (1ブロックあたり %.2f 回)',
      [BLOCKS, alloc, alloc / BLOCKS]));
    Check(alloc = 0, '受信ブロック処理で一切確保していない');
  finally
    rx.Free; snd.Free;
  end;
end;

procedure TestRxDeadlineMargin;
var
  snd: TCaptureSoundDevice;
  rx: TRttyModem;
  cw: TCwModem;
  psk: TPskModem;
begin
  snd := TCaptureSoundDevice.Create;
  rx := TRttyModem.Create(snd);
  try
    rx.Frequency := 1000;
    rx.AfcOn := True;
    MeasureRxDeadline('RTTY', rx, 1000);
  finally
    rx.Free;
  end;

  cw := TCwModem.Create(snd);
  try
    cw.Frequency := 700;
    MeasureRxDeadline('CW', cw, 700);
  finally
    cw.Free;
  end;

  psk := TPskModem.Create(snd, mmPSK31);
  try
    psk.Frequency := 1000;
    MeasureRxDeadline('PSK31', psk, 1000);
  finally
    psk.Free;
    snd.Free;
  end;
end;

begin
  WriteLn('=== X-04 / Z-04 realtime 特性の検証 ===');
  InstallCountingMM;
  try
    TestMeasurementItselfWorks;
    TestSoundWritePathIsAllocationFree;
    TestRttyTxPathIsAllocationFree;
    TestRttyRxBlockIsAllocationFree;
    TestCwTxPathIsAllocationFree;
    TestPskTxPathIsAllocationFree;
    TestPskRxBlockIsAllocationFree;
  finally
    RestoreMM;
  end;

  { 時間の測定は、計数用メモリマネージャを外してから行う
    (計数のオーバーヘッドが測定値に乗らないようにするため)。 }
  TestRxDeadlineMargin;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('RT-001');
    CoverReq('RT-002');
  end;

  if FailCount > 0 then
    Halt(1);
end.
