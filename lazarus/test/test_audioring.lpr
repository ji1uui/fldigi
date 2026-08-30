{ ============================================================================
  test_audioring.lpr

  Phase 1 (Modern Runtime) の Ring Buffer / History Buffer / CPU 検出の検証。

  確かめること
  ----------------------------------------------------------------------------
  1. 書き込み側が確保しないこと (X-04)
     音声スレッドから呼ばれる。確保すれば deadline を落としうる。
     メモリマネージャを差し替えて実測する。

  2. 回り込み (wrap-around) で値が壊れないこと
     リングの誤りはここに出る。境界を跨ぐ長さ・容量ちょうど・容量+1 を
     すべて通す。

  3. 溢れたときに **数が残る** こと (ADR-010)
     黙って捨てるのが最悪である。何件落ちたか言えること。

  4. 実際に 2 スレッドで流して、順序と内容が保たれること
     単一スレッドの試験だけでは、バリアの有無が結果に出ない。

  5. 履歴が「読み取り中に上書きされた」を検出すること
     検出しないと、前半が古く後半が新しい継ぎはぎの波形を「録音」として
     渡してしまう。Phase 3 が復調戦略を比較するとき、その波形は嘘の材料
     になる。

  6. CPU 検出が TThread.ProcessorCount より正しいこと (X-03)

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_audioring;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math,
  AudioRing, CpuInfo, Requirements;

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

{ --------------------------------------------------------------------------
  確保回数を数えるメモリマネージャ (test_realtime / test_observability と同じ)
  -------------------------------------------------------------------------- }
var
  GOldMM: TMemoryManager;
  GCounting: Boolean = False;
  GAllocCount: Integer = 0;

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

procedure InstallCountingMM;
var
  mm: TMemoryManager;
begin
  GetMemoryManager(GOldMM);
  mm := GOldMM;
  mm.GetMem := @CountingGetMem;
  mm.ReAllocMem := @CountingReAllocMem;
  SetMemoryManager(mm);
end;

procedure RestoreMM;
begin
  SetMemoryManager(GOldMM);
end;

{ --------------------------------------------------------------------------
  1. 基本と回り込み
  -------------------------------------------------------------------------- }
procedure TestRingBasics;
var
  r: TAudioRing;
  src, dst: array[0..63] of Double;
  i, n: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. リングの基本と回り込み ---');

  CheckEqI(NextPowerOfTwo(1), 16, '最小容量へ切り上げる');
  CheckEqI(NextPowerOfTwo(17), 32, '2 の冪へ切り上げる');
  CheckEqI(NextPowerOfTwo(32), 32, '既に 2 の冪ならそのまま');

  r := TAudioRing.Create(16);
  try
    CheckEqI(r.Capacity, 16, '容量が 16');
    Check(r.IsEmpty, '最初は空');
    CheckEqI(r.Available, 0, '読める数 0');
    CheckEqI(r.FreeSpace, 16, '空き 16');

    for i := 0 to 7 do src[i] := i + 1;
    CheckEqI(r.Write(src, 8), 8, '8 サンプル書けた');
    CheckEqI(r.Available, 8, '8 読める');
    CheckEqI(r.FreeSpace, 8, '空きが 8 に減る');
    Check(not r.IsEmpty, '空ではない');

    CheckEqI(r.Read(dst, 8), 8, '8 サンプル読めた');
    ok := True;
    for i := 0 to 7 do
      if dst[i] <> i + 1 then ok := False;
    Check(ok, '値が一致する');
    Check(r.IsEmpty, '読み切ると空');

    { --- 回り込み ---
      容量 16 の 8 まで使った状態から 12 書くと、後半が先頭へ回る。
      ここがリングの誤りが出る場所である。 }
    for i := 0 to 11 do src[i] := 100 + i;
    CheckEqI(r.Write(src, 12), 12, '境界を跨いで 12 書けた');
    CheckEqI(r.Read(dst, 12), 12, '12 読めた');
    ok := True;
    for i := 0 to 11 do
      if dst[i] <> 100 + i then ok := False;
    Check(ok, '**回り込んでも値が壊れない**');

    { 容量ちょうど。 }
    r.Clear;
    for i := 0 to 15 do src[i] := 200 + i;
    CheckEqI(r.Write(src, 16), 16, '容量ちょうど書ける');
    Check(r.IsFull, '満杯と分かる');
    CheckEqI(r.Write(src, 1), 0, '満杯なら 1 つも書けない');
    CheckEqI(r.Read(dst, 16), 16, '全部読める');
    ok := True;
    for i := 0 to 15 do
      if dst[i] <> 200 + i then ok := False;
    Check(ok, '容量ちょうどでも値が壊れない');

    { 部分読み・部分書きを混ぜて何周もする。 }
    r.Clear;
    r.ResetCounters;
    ok := True;
    n := 0;
    for i := 1 to 200 do
    begin
      src[0] := i;
      if r.Write(src, 1) <> 1 then ok := False;
      if r.Read(dst, 1) <> 1 then ok := False;
      if dst[0] <> i then ok := False;
      Inc(n);
    end;
    Check(ok, Format('1 サンプルずつ %d 回 (何周もする) 通した', [n]));
    CheckEqI(r.OverrunSamples, 0, '取りこぼしなし');

    { 引数の境界。 }
    CheckEqI(r.Write(src, 0), 0, '0 件書き込みは 0');
    CheckEqI(r.Write(src, -5), 0, '負の件数は 0');
    CheckEqI(r.Read(dst, 0), 0, '0 件読み出しは 0');
    CheckEqI(r.Read(dst, -5), 0, '負の件数は 0');
    { 受け皿より大きい要求は受け皿に切り詰める (溢れない)。 }
    r.Clear;
    r.Write(src, 16);
    CheckEqI(r.Read(dst, 1000), 16, '受け皿を超える要求でも壊れない');
  finally
    r.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. 溢れたときに数が残ること (ADR-010)
  -------------------------------------------------------------------------- }
procedure TestRingOverrun;
var
  r: TAudioRing;
  src, dst: array[0..63] of Double;
  i: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 2. 溢れの記録 (ADR-010) ---');
  r := TAudioRing.Create(16);
  try
    for i := 0 to 63 do src[i] := i;

    { 16 しか入らないところへ 20 書く。 }
    CheckEqI(r.WriteOrDrop(src, 20), 16, '入る分だけ書く');
    CheckEqI(r.OverrunSamples, 4, '**捨てた 4 サンプルが数として残る**');
    CheckEqI(r.OverrunEvents, 1, '捨てが 1 回起きたと分かる');

    { 満杯にさらに書く。 }
    CheckEqI(r.WriteOrDrop(src, 5), 0, '満杯なら 0');
    CheckEqI(r.OverrunSamples, 9, '捨てた数が積み上がる');
    CheckEqI(r.OverrunEvents, 2, '回数も積み上がる');

    { 捨てられたのは「新しい方」であり、既に入っている古い方は無傷。
      ここが上書き方式との違いで、読み手の連続性を守っている。 }
    CheckEqI(r.Read(dst, 16), 16, '入っていた分は読める');
    ok := True;
    for i := 0 to 15 do
      if dst[i] <> i then ok := False;
    Check(ok, '**古い方は上書きされていない** (読み手の連続性が保たれる)');

    r.ResetCounters;
    CheckEqI(r.OverrunSamples, 0, '記録をリセットできる');

    { --- 二つの入口の違い ---
      再試行する側の書き込みを「捨てた」と数えてしまうと、取りこぼし
      件数が「復調が追いついていない量」を表さなくなる。 }
    r.Clear;
    r.ResetCounters;
    r.Write(src, 16);                       { 満杯にする }
    CheckEqI(r.Write(src, 8), 0, 'Write は満杯なら 0 を返す');
    CheckEqI(r.OverrunSamples, 0,
      '**Write は捨てたと数えない** (呼び出し側が再試行できるため)');
    CheckEqI(r.WriteOrDrop(src, 8), 0, 'WriteOrDrop も満杯なら 0');
    CheckEqI(r.OverrunSamples, 8,
      '**WriteOrDrop は捨てたと数える** (音声スレッドは再試行できない)');
    Check(Pos('取りこぼし', r.Describe) > 0, '状態を人が読める形で出せる');
  finally
    r.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. 書き込み側が確保しないこと (X-04)
  -------------------------------------------------------------------------- }
procedure TestNoAllocationOnWrite;
var
  r: TAudioRing;
  h: TAudioHistory;
  src: array[0..255] of Double;
  i, j: Integer;
  writeAllocs, appendAllocs: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 書き込み側が確保しないこと (X-04) ---');
  for i := 0 to 255 do src[i] := i * 0.5;

  r := TAudioRing.Create(4096);
  h := TAudioHistory.Create(4096, 8000);
  try
    { 事前に一度回してから測る (遅延初期化を測らないため)。 }
    r.Write(src, 256);
    r.Discard(256);
    h.Append(src, 256);

    GAllocCount := 0;
    InstallCountingMM;
    GCounting := True;
    try
      for j := 1 to 500 do
      begin
        r.Write(src, 256);
        r.Discard(256);
      end;
      writeAllocs := GAllocCount;

      GAllocCount := 0;
      for j := 1 to 500 do
        h.Append(src, 256);
      appendAllocs := GAllocCount;
    finally
      GCounting := False;
      RestoreMM;
    end;

    CheckEqI(writeAllocs, 0,
      Format('リングへの 500 回の書き込みで確保 0 回 (実測 %d)', [writeAllocs]));
    CheckEqI(appendAllocs, 0,
      Format('履歴への 500 回の追記で確保 0 回 (実測 %d)', [appendAllocs]));
  finally
    r.Free;
    h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 実際に 2 スレッドで流す

  単一スレッドの試験だけでは、バリアの有無が結果に出ない。
  -------------------------------------------------------------------------- }
type
  TProducer = class(TThread)
  private
    FRing: TAudioRing;
    FTotal: Int64;
    FWritten: Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(ARing: TAudioRing; ATotal: Int64);
    property Written: Int64 read FWritten;
  end;

constructor TProducer.Create(ARing: TAudioRing; ATotal: Int64);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRing := ARing;
  FTotal := ATotal;
end;

procedure TProducer.Execute;
var
  buf: array[0..63] of Double;
  i, n: Integer;
  v: Int64;
begin
  v := 0;
  while v < FTotal do
  begin
    n := 64;
    if v + n > FTotal then n := Integer(FTotal - v);
    for i := 0 to n - 1 do
      buf[i] := v + i;      { 値そのものが通し番号 }
    { 空きができるまで待ってからブロックごと書く。
      試験なので取りこぼしを 0 にしたい。本番の音声スレッドはこれを
      やってはならない (待てないので WriteOrDrop を使う)。 }
    while FRing.FreeSpace < n do
      ThreadSwitch;
    if FRing.Write(buf, n) <> n then
      Break;   { 空きを確認してから書いたので起きないはず }
    Inc(v, n);
    Inc(FWritten, n);
  end;
end;

procedure TestTwoThreads;
const
  TOTAL = 500000;
var
  r: TAudioRing;
  prod: TProducer;
  buf: array[0..127] of Double;
  got, i, n: Integer;
  expect: Int64;
  ok: Boolean;
  firstBad: Int64;
begin
  WriteLn;
  WriteLn('--- 4. 2 スレッドで実際に流す ---');
  r := TAudioRing.Create(1024);
  prod := TProducer.Create(r, TOTAL);
  try
    expect := 0;
    ok := True;
    firstBad := -1;
    prod.Start;

    while expect < TOTAL do
    begin
      n := r.Read(buf, 128);
      if n = 0 then
      begin
        if prod.Finished and (r.Available = 0) then Break;
        Continue;
      end;
      for i := 0 to n - 1 do
      begin
        if buf[i] <> expect then
        begin
          if ok then firstBad := expect;
          ok := False;
        end;
        Inc(expect);
      end;
    end;

    prod.WaitFor;
    got := Integer(expect);
    CheckEqI(got, TOTAL, Format('%d サンプルすべて読めた', [TOTAL]));
    if ok then
      Check(True, '**順序も値も 1 つも狂わなかった** (通し番号で照合)')
    else
      Check(False, Format('順序か値が狂った (最初は %d サンプル目)', [firstBad]));
    CheckEqI(r.OverrunSamples, 0, '取りこぼしなし (書けるまで粘ったため)');
  finally
    prod.Free;
    r.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 履歴 (Replay)
  -------------------------------------------------------------------------- }
procedure TestHistory;
var
  h: TAudioHistory;
  src, dst: array[0..255] of Double;
  i, n: Integer;
  err: string;
  first, last: Int64;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 5. Replay 履歴 ---');
  h := TAudioHistory.Create(64, 8000);
  try
    CheckEqI(h.Capacity, 64, '容量 64');
    CheckEqI(h.TotalWritten, 0, '最初は 0');
    CheckEqI(h.AvailableSamples, 0, '保持 0');

    for i := 0 to 31 do src[i] := i;
    h.Append(src, 32);
    CheckEqI(h.TotalWritten, 32, '通算 32');
    CheckEqI(h.AvailableSamples, 32, '保持 32');
    h.LiveRange(first, last);
    CheckEqI(first, 0, '生存区間の先頭は 0');
    CheckEqI(last, 32, '生存区間の末尾は 32');

    Check(h.TryReadRange(0, 32, dst, err), '書いた区間を取り出せる');
    ok := True;
    for i := 0 to 31 do
      if dst[i] <> i then ok := False;
    Check(ok, '値が一致する');

    Check(h.TryReadRange(8, 16, dst, err), '途中の区間を取り出せる');
    ok := True;
    for i := 0 to 15 do
      if dst[i] <> 8 + i then ok := False;
    Check(ok, '途中の区間の値も正しい');

    { まだ書かれていない区間。 }
    Check(not h.TryReadRange(20, 32, dst, err), 'まだ書かれていない区間は取れない');
    Check(Pos('まだ書かれていない', err) > 0, '理由が分かる');

    { --- 回り込んで古い方が消える --- }
    for i := 0 to 63 do src[i] := 1000 + i;
    h.Append(src, 64);
    CheckEqI(h.TotalWritten, 96, '通算 96');
    CheckEqI(h.AvailableSamples, 64, '保持は容量どまり');
    h.LiveRange(first, last);
    CheckEqI(first, 32, '生存区間の先頭が進む');

    Check(not h.TryReadRange(0, 16, dst, err), '上書きされた区間は取れない');
    Check(Pos('既に上書き', err) > 0, '理由が「上書き済み」と分かる');
    Check(h.TryReadRange(32, 64, dst, err), '生きている区間は取れる');
    ok := True;
    for i := 0 to 63 do
      if dst[i] <> 1000 + i then ok := False;
    Check(ok, '回り込んだ後も値が正しい');

    { 直近を取る。 }
    n := h.ReadLatest(16, dst);
    CheckEqI(n, 16, '直近 16 を取れる');
    ok := True;
    for i := 0 to 15 do
      if dst[i] <> 1000 + 48 + i then ok := False;
    Check(ok, '直近の値が正しい');

    { 容量より長い追記は末尾だけ残り、通算はずれない。 }
    for i := 0 to 255 do src[i] := 5000 + i;
    h.Append(src, 200);
    CheckEqI(h.TotalWritten, 296, '容量超の追記でも通算がずれない');
    n := h.ReadLatest(64, dst);
    CheckEqI(n, 64, '直近 64 を取れる');
    ok := True;
    for i := 0 to 63 do
      if dst[i] <> 5000 + 136 + i then ok := False;
    Check(ok, '容量超の追記でも末尾が正しく残る');

    { 引数の境界。 }
    Check(not h.TryReadRange(0, 0, dst, err), '長さ 0 は失敗');
    Check(not h.TryReadRange(-1, 8, dst, err), '負の開始は失敗');
    { 受け皿には収まるが履歴の容量 (64) を超える長さ。
      1000 にすると先に「受け皿が足りません」で弾かれ、容量の検査を
      通らない ── 確かめたい検査に届いていなかった。 }
    Check(not h.TryReadRange(240, 200, dst, err), '容量超の要求は失敗');
    Check(Pos('履歴より長い', err) > 0, '理由が「履歴より長い」と分かる');
    Check(not h.TryReadRange(240, 1000, dst, err), '受け皿超の要求も失敗');
    Check(Pos('受け皿', err) > 0, '理由が「受け皿が足りない」と分かる');
  finally
    h.Free;
  end;

  { 秒数指定。 }
  h := TAudioHistory.ForSeconds(2.0, 8000);
  try
    Check(h.Capacity >= 16000, '2 秒ぶん (8000Hz) 以上の容量');
    Check(h.DurationSeconds = 0, '書く前の保持時間は 0');
  finally
    h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 読み取り中に上書きされたことを検出する

  ここが検出できないと、前半が古く後半が新しい継ぎはぎの波形を
  「録音」として渡してしまう。
  -------------------------------------------------------------------------- }
procedure TestTornReadDetection;
var
  h: TAudioHistory;
  src, dst: array[0..255] of Double;
  i: Integer;
  err: string;
  detected, staleAccepted: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 読み取り中の上書きを検出すること ---');
  h := TAudioHistory.Create(64, 8000);
  try
    for i := 0 to 63 do src[i] := i;
    h.Append(src, 64);

    { まず正常に取れることを確認 (前提)。 }
    Check(h.TryReadRange(0, 64, dst, err), '前提: 生きている区間は取れる');

    { 取り出しの直前に書き手が丸ごと 1 周した状況を作る。
      TryReadRange の中では複写→再確認の順なので、複写後に総数が
      進んでいれば検出される。ここでは複写前に進めたうえで、
      「開始位置が既に生存区間の外」として弾かれることを確かめる。 }
    detected := 0;
    staleAccepted := 0;
    for i := 1 to 50 do
    begin
      h.Append(src, 64);   { 丸ごと 1 周ぶん上書き }
      { 1 周前の区間を要求する。既に上書きされているので取れてはならない。 }
      if h.TryReadRange(h.TotalWritten - 128, 64, dst, err) then
        Inc(staleAccepted)
      else
        Inc(detected);
    end;
    CheckEqI(staleAccepted, 0,
      '上書き済みの区間を 1 度も渡さない (50 回試行)');
    CheckEqI(detected, 50, '50 回とも上書き済みと判定した');

    { 境界ちょうど: 最古のサンプルは取れる。 }
    Check(h.TryReadRange(h.TotalWritten - 64, 64, dst, err),
      '生存区間の下端ちょうどは取れる');
    { その 1 つ手前は取れない。 }
    Check(not h.TryReadRange(h.TotalWritten - 65, 64, dst, err),
      '下端の 1 つ手前は取れない (境界が 1 つずれていない)');
  finally
    h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6b. 書き手が動いている最中の読み取り

  6 の試験は単一スレッドなので、複写の **前** に上書き済みと分かる経路しか
  通っていなかった。複写の **最中** に書き手が回り込む経路 (= 継ぎはぎの
  波形ができる経路) は一度も走っていない。実際、その検査を外しても 6 は
  全部通ってしまった。

  書き手を別スレッドで走らせ、上書きされやすい末端の区間を読み続ける。
  値を通し番号にしておけば、返ってきた波形が継ぎはぎかどうかが分かる。
  -------------------------------------------------------------------------- }
type
  THistoryWriter = class(TThread)
  private
    FHist: TAudioHistory;
    FStop: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AHist: TAudioHistory);
    procedure Stop;
  end;

constructor THistoryWriter.Create(AHist: TAudioHistory);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FHist := AHist;
end;

procedure THistoryWriter.Stop;
begin
  FStop := True;
end;

procedure THistoryWriter.Execute;
var
  buf: array[0..255] of Double;
  i: Integer;
  v: Int64;
begin
  v := 0;
  while not FStop do
  begin
    for i := 0 to 255 do
      buf[i] := v + i;      { 値そのものが通し番号 }
    FHist.Append(buf, 256);
    Inc(v, 256);
  end;
end;

procedure TestTornReadUnderConcurrentWriter;
const
  CAP = 4096;
  READ_LEN = 2048;
  ATTEMPTS = 3000;
var
  h: TAudioHistory;
  w: THistoryWriter;
  dst: array[0..READ_LEN - 1] of Double;
  err: string;
  i, j: Integer;
  from: Int64;
  accepted, rejected, corrupted: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 6b. 書き手が動いている最中の読み取り ---');
  h := TAudioHistory.Create(CAP, 8000);
  w := THistoryWriter.Create(h);
  try
    w.Start;
    { 履歴が一杯になるまで待つ。 }
    while h.TotalWritten < CAP * 2 do
      ThreadSwitch;

    accepted := 0; rejected := 0; corrupted := 0;
    for i := 1 to ATTEMPTS do
    begin
      { 生存区間のいちばん古い側を狙う。ここが複写中に上書きされる。 }
      from := h.TotalWritten - CAP;
      if from < 0 then Continue;

      if h.TryReadRange(from, READ_LEN, dst, err) then
      begin
        Inc(accepted);
        { 受け取ったなら、通し番号が連続していなければならない。 }
        ok := True;
        for j := 0 to READ_LEN - 1 do
          if dst[j] <> from + j then
          begin
            ok := False;
            Break;
          end;
        if not ok then Inc(corrupted);
      end
      else
        Inc(rejected);
    end;

    w.Stop;
    w.WaitFor;

    WriteLn(Format('  受理 %d / 拒否 %d / うち継ぎはぎ %d (試行 %d)',
      [accepted, rejected, corrupted, ATTEMPTS]));

    { 拒否が 1 度も起きていなければ、競合そのものを再現できていない。
      その状態で「継ぎはぎ 0 件」と言っても何も証明していない。 }
    Check(rejected > 0,
      '前提: 実際に上書きとの競合が起きた (起きなければ試験にならない)');
    CheckEqI(corrupted, 0,
      '**受理した波形に継ぎはぎが 1 件も無い** (嘘の録音を渡さない)');
  finally
    w.Free;
    h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. CPU 検出 (X-03)
  -------------------------------------------------------------------------- }
procedure TestCpuDetection;
var
  info: TCpuInfo;
begin
  WriteLn;
  WriteLn('--- 7. CPU 検出 (X-03) ---');

  CheckEqI(CountCpuList('0-3'), 4, '範囲を数えられる');
  CheckEqI(CountCpuList('0'), 1, '単独を数えられる');
  CheckEqI(CountCpuList('0-3,8,10-11'), 7, '範囲と単独の混在を数えられる');
  CheckEqI(CountCpuList(''), 0, '空は 0');
  CheckEqI(CountCpuList('こわれた'), 0, '壊れた入力でも落ちない');
  CheckEqI(CountCpuList('3-0'), 0, '逆順の範囲は数えない');

  info := RefreshCpuInfo;
  WriteLn('  ', info.Describe);
  WriteLn('  参考: TThread.ProcessorCount = ', TThread.ProcessorCount);

  Check(info.LogicalProcessors >= 1, '論理プロセッサ数が 1 以上');
  Check(info.AllowedProcessors >= 1, '実行許可数が 1 以上');
  Check(info.EffectiveProcessors >= 1, '資源配分に使う数が 1 以上');
  Check(info.EffectiveProcessors <= info.AllowedProcessors,
    '資源配分に使う数は実行許可数を超えない');
  { 実行を許された CPU が機械にある CPU より多いことはありえない。
    この不整合は実際に起きた ── /proc/cpuinfo を 1 回の read() で
    読み切れると仮定していて、論理 3 / 実行許可 4 になっていた。
    数が「1 以上か」だけ見ていては気づけない種類の誤りである。 }
  Check(info.AllowedProcessors <= info.LogicalProcessors,
    '**実行許可数は論理プロセッサ数を超えない** (読み落としの検出)');
  Check(info.Source <> '', 'どこから得た値かが残る');

  { この環境では TThread.ProcessorCount = 1 だが実際は複数コアある。
    そこが X-03 の要点なので、検出がそれより正しいことを確かめる。
    (単一コアの環境では両方 1 になり、この比較は成立しないので
     その場合だけ読み替える。) }
  if info.LogicalProcessors > 1 then
    Check(info.EffectiveProcessors > TThread.ProcessorCount,
      Format('**TThread.ProcessorCount (%d) より正しい数 (%d) を返す**',
        [TThread.ProcessorCount, info.EffectiveProcessors]))
  else
    Check(True, '単一コア環境のため TThread との比較は省略');

  { キャッシュが効くこと。 }
  Check(GetCpuInfo.EffectiveProcessors = info.EffectiveProcessors,
    '二度目も同じ値を返す');
  CheckEqI(EffectiveProcessorCount, info.EffectiveProcessors,
    'EffectiveProcessorCount が一致');
end;

begin
  WriteLn('=== Phase 1 Ring Buffer / History / CPU 検出 テスト ===');

  TestRingBasics;
  TestRingOverrun;
  TestNoAllocationOnWrite;
  TestTwoThreads;
  TestHistory;
  TestTornReadDetection;
  TestTornReadUnderConcurrentWriter;
  TestCpuDetection;

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
  begin
    CoverReq('RT-004');
    CoverReq('RT-005');
    CoverReq('RT-006');
  end;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
