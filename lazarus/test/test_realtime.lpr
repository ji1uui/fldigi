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
  SpectrumService, WaterfallModel, NoiseEstimator,
  RttyModemImpl, CwModemImpl, PskModemImpl, MfskModemImpl, MfskTones,
  OliviaModemImpl,
  TestSupport, Requirements;

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

{ --------------------------------------------------------------------------
  あとから足したモデムの送受信経路 (RT-001 の文面は「**全モデム**」)

  RT-001 と RT-002 には「モデムを足したら試験も足すこと」と書いてある。
  ところが RT-002 (deadline) には足したのに、**RT-001 (確保) には
  足していなかった** ―― CW の受信、MFSK16 の送受信、Olivia の送受信が
  どれも入っていない。PSK を足したときと同じ抜けを、また繰り返している。

  以後また増えるので、1 つずつ手で書くのをやめて共通の手順にした。
  モデムを足したら下の表に 1 行足すだけで済む。
  -------------------------------------------------------------------------- }
type
  TMakeAnyModem = function(ASound: TCustomSoundDevice): TCustomModem;

function MakeCwModem(ASound: TCustomSoundDevice): TCustomModem;
var
  m: TCwModem;
begin
  m := TCwModem.Create(ASound);
  m.Frequency := 700;
  m.SetCwSpeed(20);
  m.CwTrack := False;
  Result := m;
end;

function MakeMfskModem(ASound: TCustomSoundDevice): TCustomModem;
begin
  Result := TMfskModem.Create(ASound, mmMFSK16);
  Result.Frequency := MFSK16_MODE.CentreFreqHz;
end;

function MakeOliviaModem(ASound: TCustomSoundDevice): TCustomModem;
begin
  Result := TOliviaModem.Create(ASound, mmOlivia, 5, 1000);
end;

procedure MeasureTxAlloc(const AName: string; AMake: TMakeAnyModem);
var
  snd: TCaptureSoundDevice;
  tx: TCustomModem;
  src: TTxSource;
  guard, res: Integer;
  alloc: Int64;
begin
  snd := TCaptureSoundDevice.Create;
  tx := AMake(snd);
  src := TTxSource.Create('CQ CQ DE JI1UUI K');
  try
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    tx.TxProcess;   { 1 回ぶん先に流してバッファを確保させる }

    BeginMeasure;
    guard := 0;
    repeat
      res := tx.TxProcess;
      Inc(guard);
    until (res < 0) or (guard > 100000);
    EndMeasure;
    alloc := GGetMemCount + GReallocCount;

    WriteLn(Format('  %-8s 送信 %7d サンプル: 確保 %d 回',
      [AName, snd.Count, alloc]));
    Check(alloc <= MAX_TX_ALLOC, Format(
      '%s: 確保回数が送信量に比例しない (%d 回 / 上限 %d)',
      [AName, alloc, MAX_TX_ALLOC]));
  finally
    src.Free; tx.Free; snd.Free;
  end;
end;

{ 受信ブロックの確保が**ブロック数に比例しないこと**を見る。

  はじめ「確保 0 回」と書いたが、それはモデムによって成り立たない。
  CW は無音のあとに**語間の空白を 1 文字**出す (それが CW の作法である)。
  文字が出れば Evidence の候補配列を作るので確保が入る。0 を要求すると、
  正しい振る舞いのほうを不具合に見せてしまう。

  そこで **100 ブロックと 200 ブロックで測り、増えないこと**を見る。
  1 ブロックごとに確保していれば倍になる。立ち上がりの固定費は
  両方に等しく乗るので差に出ない。0 を要求するより強く、しかも
  モードごとの作法を壊さない。

  AQuiet: 無信号として流す波形。**モデムによって「何も出ない音」が違う。**
  弱い純音は PSK では何も出さないが、CW の追尾フィルタは拾ってしまう。 }
type
  TQuietKind = (qkWeakTone, qkSilence);

function RunRxAlloc(AMake: TMakeAnyModem; ABlocks: Integer;
  AQuiet: TQuietKind; out AChars: Integer): Int64;
var
  snd: TCaptureSoundDevice;
  rx: TCustomModem;
  sink: TEvidenceSink;
  buf: array[0..511] of Double;
  i, k: Integer;
begin
  snd := TCaptureSoundDevice.Create;
  rx := AMake(snd);
  sink := TEvidenceSink.Create;
  try
    rx.RxInit;
    rx.OnDecode := @sink.Decode;
    for i := 0 to High(buf) do
      if AQuiet = qkSilence then buf[i] := 0
      else buf[i] := 0.001 * Sin(i * 0.37);
    rx.RxProcess(buf, Length(buf));   { 初回の確保を済ませる }

    BeginMeasure;
    for k := 1 to ABlocks do
      rx.RxProcess(buf, Length(buf));
    EndMeasure;
    Result := GGetMemCount + GReallocCount;
    AChars := sink.Count;
  finally
    sink.Free; rx.Free; snd.Free;
  end;
end;

procedure MeasureRxAlloc(const AName: string; AMake: TMakeAnyModem;
  AQuiet: TQuietKind = qkWeakTone);
const
  SLACK = 4;   { 立ち上がりのばらつきぶん。比例していれば桁で超える。 }
var
  a1, a2: Int64;
  c1, c2: Integer;
begin
  a1 := RunRxAlloc(AMake, 100, AQuiet, c1);
  a2 := RunRxAlloc(AMake, 200, AQuiet, c2);
  WriteLn(Format('  %-8s 受信 100/200 ブロック: 確保 %d/%d 回 / 出力 %d/%d 文字',
    [AName, a1, a2, c1, c2]));
  Check(a2 <= a1 + SLACK,
    Format('%s: 確保がブロック数に比例しない (100->%d / 200->%d)',
      [AName, a1, a2]));
  Check(c2 <= c1 + 1,
    Format('%s: 出力もブロック数に比例しない (100->%d / 200->%d)',
      [AName, c1, c2]));
end;

procedure TestRemainingModemsAreAllocationFree;
begin
  WriteLn;
  WriteLn('--- 7. あとから足したモデムの送受信経路 (RT-001) ---');
  MeasureTxAlloc('CW', @MakeCwModem);
  { CW だけ無音にする。弱い純音 (470 Hz) を CW の追尾フィルタが拾って
    1 文字出してしまい、「文字が出ないブロック」の試験にならなかった。
    off-frequency とはいえ coherent な音なので、拾うこと自体は不具合
    ではない ―― 試験の前提のほうが合っていなかった。 }
  MeasureRxAlloc('CW', @MakeCwModem, qkSilence);
  MeasureTxAlloc('MFSK16', @MakeMfskModem);
  MeasureRxAlloc('MFSK16', @MakeMfskModem);
  MeasureTxAlloc('Olivia', @MakeOliviaModem);
  MeasureRxAlloc('Olivia', @MakeOliviaModem);
end;

procedure TestRxDeadlineMargin;
var
  snd: TCaptureSoundDevice;
  rx: TRttyModem;
  cw: TCwModem;
  psk: TPskModem;
  mfsk: TMfskModem;
  olv: TOliviaModem;
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
  end;

  { RT-002 は「**全モデム**の受信ブロック」である。モードを足したら
    ここにも足す ―― 足し忘れると、要求の文面だけが広くて中身が
    追いついていない状態になる (README 40 章の轍)。 }
  mfsk := TMfskModem.Create(snd, mmMFSK16);
  try
    mfsk.Frequency := MFSK16_MODE.CentreFreqHz;
    MeasureRxDeadline('MFSK16', mfsk, MFSK16_MODE.CentreFreqHz);
  finally
    mfsk.Free;
  end;

  olv := TOliviaModem.Create(snd, mmOlivia, 5, 1000);
  try
    MeasureRxDeadline('Olivia32/1000', olv, olv.Frequency);
  finally
    olv.Free;
    snd.Free;
  end;
end;

{ --------------------------------------------------------------------------
  受信経路 **全体** の deadline 余裕

  RT-002 は「**全モデム**の受信ブロック」を測っている。ところが受信経路には
  モデムのほかに共有サービスが居る。

      音声 --> モデム (復調)
           +-> SpectrumService (FFT 8192)  +-> WaterfallModel (表示の格子)
                                           +-> NoiseEstimator (雑音床)

  Spectrum と Waterfall はモデムではないので RT-002 の文面に入らず、
  あとから足したのにどの deadline 試験にも入っていなかった。
  復調が間に合っていても、滝を出した瞬間に間に合わなくなれば同じことである。

  NoiseEstimator (SPC-002) も同じ轍を踏みかけた。**受信経路に足した部品は
  受信経路の測定にも足す** ―― これを規律として書いておく。雑音床は
  枠ごとに 4094 本を並べ替えて分位点を取るので、FFT ほどではないが
  ただではない。しかも Phase 3 の戦略はみなこれを土台にする。

  Spectrum は hop 2048 なので **4 ブロックに 1 回だけ** 8192 点 FFT を回す。
  平均は小さく、その 1 ブロックだけ跳ねる。だから平均ではなく
  **p99 と最悪**で見る必要がある。
  -------------------------------------------------------------------------- }
procedure MeasureChain(const AName: string; AModems: Integer;
  AWithSpectrum: Boolean; out ASt: TBlockTiming);
const
  BLK = 512;
  SR = 8000;
  WARMUP = 200;
  SAMPLES = 2000;
  POOLBLKS = 64;             { 使い回す音の長さ [ブロック] }
  NOISEAMP = 0.05;           { 一様雑音の振幅。理論値の出どころ }
var
  buf: array[0..BLK - 1] of Double;
  pool: TDoubleArray;        { 測定の前に作る。測定中は確保しない }
  ms: TDoubleArray;
  snd: TCaptureSoundDevice;
  rx: array[0..2] of TRttyModem;
  sp: TSpectrumService;
  wf: TWaterfallModel;
  ne: TNoiseEstimator;
  ni: TNoiseUpdateInfo;
  i, k, n: Integer;
  t0: Double;
  expDb: Double;
  expected: Int64;
begin
  ms := nil; pool := nil;
  SetLength(ms, SAMPLES);
  SetLength(pool, POOLBLKS * BLK);
  { 信号 + **本物の雑音**。雑音床を測る部品を経路に入れた以上、
    無雑音の正弦だけを流したのでは意味が無い。しかも **同じ 1 ブロックを
    繰り返してはいけない** ―― 512 標本周期の完全な周期信号になり、
    8192 点 FFT では 16 本おきの線スペクトルになって、それ以外の bin が
    数値的に 0 になる。分位点は当然 0 になり、雑音床は下限に張り付く
    (実際そうなった)。だから 64 ブロックぶんを作って順に流す。
    RandSeed を固定するので走らせるたびに同じ音になる (Z-05)。 }
  RandSeed := 20240921;
  for i := 0 to POOLBLKS * BLK - 1 do
    pool[i] := 0.3 * Sin(2 * Pi * 1000 * i / SR) + NOISEAMP * (2 * Random - 1);
  Move(pool[0], buf[0], BLK * SizeOf(Double));

  snd := TCaptureSoundDevice.Create;
  sp := nil; wf := nil; ne := nil;
  for i := 0 to 2 do rx[i] := nil;
  try
    for i := 0 to AModems - 1 do
    begin
      rx[i] := TRttyModem.Create(snd);
      rx[i].Frequency := 1000;
      rx[i].AfcOn := True;
      rx[i].RxInit;
    end;
    if AWithSpectrum then
    begin
      sp := TSpectrumService.Create;          { 既定 8192 / hop 2048 }
      wf := TWaterfallModel.Create(sp);       { 既定 800 列 x 256 行 }
      ne := TNoiseEstimator.Create(sp);       { 既定 中央値 / ならし 8 枠 }
    end;

    for k := 1 to WARMUP do
    begin
      Move(pool[(k mod POOLBLKS) * BLK], buf[0], BLK * SizeOf(Double));
      for i := 0 to AModems - 1 do rx[i].RxProcess(buf, BLK);
      if AWithSpectrum then
      begin sp.Feed(buf, BLK); wf.Pump; ne.Update(ni); end;
    end;

    for k := 0 to SAMPLES - 1 do
    begin
      { 次のブロックを用意するのは **時計を回す前**。音の用意は
        受信経路の仕事ではないので、測定に混ぜない。 }
      Move(pool[(k mod POOLBLKS) * BLK], buf[0], BLK * SizeOf(Double));
      t0 := HiResSeconds;
      for i := 0 to AModems - 1 do rx[i].RxProcess(buf, BLK);
      if AWithSpectrum then
      begin sp.Feed(buf, BLK); wf.Pump; ne.Update(ni); end;
      ms[k] := (HiResSeconds - t0) * 1000;
    end;

    ASt := SummarizeBlockTiming(ms, 1000.0 * BLK / SR);
    n := 0;
    if AWithSpectrum then n := Integer(sp.FramesProduced);
    WriteLn('  ', AName);
    WriteLn('    ', ASt.Describe);
    if AWithSpectrum then
    begin
      WriteLn(Format('    (%d ブロックで枠 %d ―― FFT 8192 は 4 ブロックに 1 回)',
        [SAMPLES, n]));
      { --- 時間ではなく **仕事の量** を縛る ---
        壁時計の判定は緩く取らざるを得ない (機械の負荷で落ちては困る) ので、
        数割の劣化は捕まえられない。一方 FFT を何回回したかは決定的なので、
        「更新を速くしよう」として hop を詰めるといった変更は**厳密に**捕まる。
        時間の判定は桁違いの劣化に対する保険、こちらが日常の網である。 }
      { 期待値は **設計の定数から** 立てる。sp.Hop から計算してはいけない ――
        hop を詰める改竄をすると期待値も一緒に動いてしまい、**決して落ちない
        主張**になる (実際そう書いて反証をすり抜けさせた)。
        縛りたいのは「既定は FFT 長の 1/4 = 4 区画に 1 回」という設計そのもの。 }
      Check(sp.FftSize = SPECTRUM_DEFAULT_FFT,
        '既定の FFT 長が変わっていない');
      Check(sp.Hop = SPECTRUM_DEFAULT_FFT div 4, Format(
        '**既定の送り幅は FFT 長の 1/4** (%d 区画に 1 回 / 実際 hop %d)',
        [(SPECTRUM_DEFAULT_FFT div 4) div BLK, sp.Hop]));
      expected := ((Int64(WARMUP + SAMPLES) * BLK - SPECTRUM_DEFAULT_FFT)
                   div (SPECTRUM_DEFAULT_FFT div 4)) + 1;
      Check(sp.FramesProduced = expected, Format(
        '**FFT の回数が仕様どおり** (%d 区画で %d 枠 / 実際 %d)',
        [WARMUP + SAMPLES, expected, sp.FramesProduced]));

      { 雑音床は **出た枠を一つ残らず** 食べていること。
        取りこぼしがあると偏った標本で雑音床を作ることになり、
        しかも速く見える ―― 速さを取りこぼしで買っていないことを
        ここで縛る。枠の保持数 (既定 64) を超えて溜め込めば落ちる。 }
      Check(ne.FramesUsed = sp.FramesProduced, Format(
        '**雑音床が枠を取りこぼしていない** (出 %d / 食 %d)',
        [sp.FramesProduced, ne.FramesUsed]));
      Check(ne.Ready, '雑音床が使える状態になっている');

      { **速いだけでなく、合っていること。**
        滝と雑音床は同じ SpectrumService を二つの reader で読む。
        この組み合わせは他のどの試験にも無い ―― test_noise は
        雑音床だけで回している。読み手が増えても正しい値が出ることを
        ここで押さえる。
        期待値は生成側の振幅から **理論で** 立てる: 振幅 a の一様雑音は
        分散 (2a)^2/12、片側電力密度は 2*sigma^2/Fs (SPC-001 と同じ式)。
        較正係数 -ln(1-p) を外すと 1.59 dB ずれて落ちる。 }
      expDb := PowerToDb(2 * (4 * NOISEAMP * NOISEAMP / 12.0) / SR);
      Check(Abs(ne.NoiseDensityDb - expDb) < 1.0, Format(
        '**滝と共存しても雑音床が理論値に載る** (理論 %.1f dB / 実測 %.1f dB)',
        [expDb, ne.NoiseDensityDb]));
      WriteLn(Format('    (雑音床 %.1f dB / 理論 %.1f dB / 枠 %d)',
        [ne.NoiseDensityDb, expDb, ne.FramesUsed]));
    end;
  finally
    ne.Free; wf.Free; sp.Free;
    for i := 0 to 2 do rx[i].Free;
    snd.Free;
  end;
end;

procedure TestReceiveChainDeadline;
var
  st, stPortfolio: TBlockTiming;
begin
  WriteLn;
  WriteLn('--- 受信経路全体 (モデム + Spectrum + Waterfall + 雑音床) の deadline 余裕 ---');
  MeasureChain('RTTY + Spectrum(8192) + Waterfall(800x256) + Noise', 1, True, st);
  Check(st.MeanRatio < MAX_MEAN_RATIO, Format(
    '**経路全体の平均が deadline の %.0f%% 未満** (実際 %.2f%%)',
    [100 * MAX_MEAN_RATIO, 100 * st.MeanRatio]));
  Check(st.P99Ratio < MAX_P99_RATIO, Format(
    '**経路全体の p99 が deadline の %.0f%% 未満** (FFT が跳ねる分を含む / 実際 %.2f%%)',
    [100 * MAX_P99_RATIO, 100 * st.P99Ratio]));
  Check(st.MaxRatio < MAX_PEAK_RATIO, Format(
    '経路全体の最悪でも deadline の %.0f%% 未満 (実際 %.2f%%)',
    [100 * MAX_PEAK_RATIO, 100 * st.MaxRatio]));

  { Phase 3 の Algorithm Portfolio は同じ音に複数の戦略を当てる。
    何本まで載るかはそのときの設計判断だが、**桁が合っているか**を
    いま測っておく。ここは合否ではなく記録が目的なので、判定は
    「絶対に落とさない側」の最悪値だけに掛ける。 }
  WriteLn;
  WriteLn('  [Phase 3 の見積り] 戦略を 3 本並べたとき');
  MeasureChain('RTTY x3 + Spectrum + Waterfall + Noise', 3, True, stPortfolio);
  Check(stPortfolio.MaxRatio < MAX_PEAK_RATIO, Format(
    '戦略 3 本でも最悪が deadline の %.0f%% 未満 (実際 %.2f%%)',
    [100 * MAX_PEAK_RATIO, 100 * stPortfolio.MaxRatio]));
  WriteLn(Format('    -> 1 本あたりおよそ %.2f%% / 残り %.1f%% が Phase 3 の取り分',
    [100 * (stPortfolio.MeanRatio - st.MeanRatio) / 2,
     100 * (1.0 - stPortfolio.MeanRatio)]));
  WriteLn('    ※ 実測は Xeon 2.80GHz。Baseline の基準機 Intel N150 では');
  WriteLn('      おおむねこれより重くなる。N150 実機での確認は未実施。');
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
    TestRemainingModemsAreAllocationFree;
  finally
    RestoreMM;
  end;

  { 時間の測定は、計数用メモリマネージャを外してから行う
    (計数のオーバーヘッドが測定値に乗らないようにするため)。 }
  TestRxDeadlineMargin;
  TestReceiveChainDeadline;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('RT-001');
    CoverReq('RT-002');
    CoverReq('RT-009');
  end;

  if FailCount > 0 then
    Halt(1);
end.
