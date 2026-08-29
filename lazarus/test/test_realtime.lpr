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
  RttyModemImpl, CwModemImpl, TestSupport;

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

begin
  WriteLn('=== X-04 realtime 経路の動的確保 検証 ===');
  InstallCountingMM;
  try
    TestMeasurementItselfWorks;
    TestSoundWritePathIsAllocationFree;
    TestRttyTxPathIsAllocationFree;
    TestRttyRxBlockIsAllocationFree;
    TestCwTxPathIsAllocationFree;
  finally
    RestoreMM;
  end;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
