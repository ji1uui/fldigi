{ ============================================================================
  test_capture.lpr

  Phase 1 / §4 X-01「Audio I/O 専用経路を DSP 重処理から分離する」の検証。

  Phase 1 の完了条件のうち「長時間受信で dropout がない」を、
  **実際に測って** 確かめる。

  何を測れば分離できたと言えるか
  ----------------------------------------------------------------------------
  「リングを足した」ことは証明にならない。証明すべきは

      復調が一時的に詰まったとき、その間の音が失われないこと

  である。そのためには「復調が詰まる」状況と「音が失われる」ことを
  再現できる相手が要る。TNullSoundDevice は待たずにいくらでも読めるので、
  詰まっても何も起きず、分離の有無で差が出ない。

  そこで実機の性質を持つ試験用デバイスを作る。

    - 実時間で決まった速さでサンプルを生み続ける
    - 内部に持てるのは有限個。読みに来なければ **溢れて消える**
    - 消えた数を数える
    - 値は通し番号なので、欠けたかどうかを受け側で判定できる

  これは実際の音声デバイスの振る舞いそのものである。この相手に対して

    分離なし: 復調が詰まった分だけ読みに行けず、デバイス側で溢れる
    分離あり: 取り込みスレッドが読み続けるので溢れない

  という差が出る。出なければ分離できていない。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_capture;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, SyncObjs, Math,
  SoundIntf, ModemTypes, Modem, ModemEngine, DecodeEvidence,
  AudioRing, AudioCapture, Observability, Requirements;

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
  実機の性質を持つ試験用デバイス

  実時間でサンプルを生み、読みに来なければ溢れて消える。
  ========================================================================== }
type
  TPacedSoundDevice = class(TCustomSoundDevice)
  private
    FLock: TCriticalSection;
    FStartSec: Double;
    FRate: Double;
    FBufferLimit: Int64;      // デバイスが溜めておける最大サンプル数
    FDelivered: Int64;        // 読み出し済みの通算
    FDropped: Int64;          // 溢れて消えた通算
    FAborted: Boolean;
    function ProducedNow: Int64;
  public
    constructor Create; override;
    destructor Destroy; override;
    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; override;
    procedure Close; override;
    procedure AbortIO; override;
    function ReadSamples(var Buf: array of Double; Count: Integer): Integer; override;
    function WriteSamples(const Buf: array of Double; Count: Integer): Integer; override;
    property Dropped: Int64 read FDropped;
    property Delivered: Int64 read FDelivered;
    property BufferLimit: Int64 read FBufferLimit write FBufferLimit;
  end;

constructor TPacedSoundDevice.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBufferLimit := 4096;
end;

destructor TPacedSoundDevice.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TPacedSoundDevice.Open(Direction: TSoundDirection;
  ASampleRate: Integer): Boolean;
begin
  SampleRate := ASampleRate;
  FRate := ASampleRate;
  FStartSec := ObsHiResSeconds;
  FDelivered := 0;
  FDropped := 0;
  FAborted := False;
  IsOpenFlag := True;
  Result := True;
end;

procedure TPacedSoundDevice.Close;
begin
  IsOpenFlag := False;
end;

procedure TPacedSoundDevice.AbortIO;
begin
  FAborted := True;
  IsOpenFlag := False;
end;

function TPacedSoundDevice.ProducedNow: Int64;
begin
  { 実時間の経過ぶんだけ生まれている。 }
  Result := Trunc((ObsHiResSeconds - FStartSec) * FRate);
  if Result < 0 then Result := 0;
end;

function TPacedSoundDevice.ReadSamples(var Buf: array of Double;
  Count: Integer): Integer;
var
  produced, pending, over: Int64;
  i, n: Integer;
begin
  Result := 0;
  if FAborted then
    raise ESoundError.Create('AbortIO により解除されました');
  if Count <= 0 then Exit;
  if Count > Length(Buf) then Count := Length(Buf);

  FLock.Enter;
  try
    produced := ProducedNow;
    pending := produced - FDelivered;

    { --- ここが実機の肝 ---
      読みに来るのが遅れると、デバイスが持てる分を超えたぶんは消える。 }
    if pending > FBufferLimit then
    begin
      over := pending - FBufferLimit;
      Inc(FDropped, over);
      Inc(FDelivered, over);      { 消えた分は「読まれた」ことにして飛ばす }
      pending := FBufferLimit;
    end;

    if pending <= 0 then Exit(0);

    n := Count;
    if n > pending then n := Integer(pending);
    { 値は通し番号。受け側が欠けを判定できる。 }
    for i := 0 to n - 1 do
      Buf[i] := FDelivered + i;
    Inc(FDelivered, n);
    Result := n;
  finally
    FLock.Leave;
  end;
end;

function TPacedSoundDevice.WriteSamples(const Buf: array of Double;
  Count: Integer): Integer;
begin
  Result := Count;
end;

{ ==========================================================================
  ときどき詰まる復調器

  通常は即座に終わるが、N ブロックに 1 回だけ長く止まる。
  実際の Adaptive DSP や GC、他プロセスの割り込みで起きる状況である。
  ========================================================================== }
type
  TStallingModem = class(TCustomModem)
  private
    FBlocks: Int64;
    FStallEvery: Integer;
    FStallMs: Integer;
    FSeen: Int64;          // 受け取ったサンプル数
    FGaps: Integer;        // 通し番号の飛びを見つけた回数
    FNextExpected: Double;
    FHasPrev: Boolean;
  public
    constructor Create(ASound: TCustomSoundDevice); reintroduce;
    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer; override;
    function TxProcess: Integer; override;
    property Blocks: Int64 read FBlocks;
    property Seen: Int64 read FSeen;
    property Gaps: Integer read FGaps;
    property StallEvery: Integer read FStallEvery write FStallEvery;
    property StallMs: Integer read FStallMs write FStallMs;
  end;

constructor TStallingModem.Create(ASound: TCustomSoundDevice);
begin
  inherited Create(ASound, mmNull);
  SampleRate := 48000;
  FStallEvery := 8;
  FStallMs := 120;
end;

procedure TStallingModem.TxInit;
begin
end;

procedure TStallingModem.RxInit;
begin
end;

procedure TStallingModem.Restart;
begin
end;

function TStallingModem.RxProcess(const ABuf: array of Double;
  ALen: Integer): Integer;
var
  i: Integer;
begin
  Inc(FBlocks);
  { 通し番号が連続しているかを見る。飛んでいれば音が失われている。 }
  for i := 0 to ALen - 1 do
  begin
    if FHasPrev and (ABuf[i] <> FNextExpected) then
      Inc(FGaps);
    FNextExpected := ABuf[i] + 1;
    FHasPrev := True;
  end;
  Inc(FSeen, ALen);

  if (FStallEvery > 0) and ((FBlocks mod FStallEvery) = 0) then
    Sleep(FStallMs);
  Result := 0;
end;

function TStallingModem.TxProcess: Integer;
begin
  Result := -1;
end;

{ --------------------------------------------------------------------------
  共通の実行
  -------------------------------------------------------------------------- }
type
  TRunResult = record
    DeviceDropped: Int64;
    RingDropped: Int64;
    Seen: Int64;
    Gaps: Integer;
    Produced: Int64;
  end;

function RunScenario(ASeparated: Boolean; ADurationMs: Integer;
  ASampleRate: Integer; ADeviceBuffer: Int64;
  ARingCapacity: Integer = 0; AStallEvery: Integer = 8;
  AStallMs: Integer = 120): TRunResult;
var
  dev: TPacedSoundDevice;
  eng: TModemEngine;
  m: TStallingModem;
  cap: TAudioCapture;
begin
  FillChar(Result, SizeOf(Result), 0);
  dev := TPacedSoundDevice.Create;
  dev.BufferLimit := ADeviceBuffer;
  dev.Open(sdRead, ASampleRate);

  m := TStallingModem.Create(dev);
  m.StallEvery := AStallEvery;
  m.StallMs := AStallMs;
  eng := TModemEngine.Create(dev, dev);
  cap := nil;
  try
    if ASeparated then
    begin
      if ARingCapacity <= 0 then
        ARingCapacity := ASampleRate * 2;   { 既定は 2 秒ぶん }
      cap := TAudioCapture.Create(dev, ARingCapacity, 0, ASampleRate);
      eng.AttachCapture(cap);
      cap.Start;
    end;

    eng.SetModem(m);
    eng.Start;
    eng.RequestReceive;
    Sleep(ADurationMs);

    { 取り込みを先に止める。エンジンより先に止めないと、
      止めたデバイスから読もうとして偽のエラーが出る。 }
    if cap <> nil then
    begin
      cap.RequestStop;
      cap.WaitFor;
      Result.RingDropped := cap.Ring.OverrunSamples;
    end;

    eng.RequestExit;
    eng.WaitFor;

    Result.DeviceDropped := dev.Dropped;
    Result.Seen := m.Seen;
    Result.Gaps := m.Gaps;
    Result.Produced := dev.Delivered + dev.Dropped;
  finally
    cap.Free;
    eng.Free;
    m.Free;
    dev.Free;
  end;
end;

{ --------------------------------------------------------------------------
  1. 試験用デバイスが実機らしく振る舞うこと (前提の確認)

  この相手が溢れないなら、以下の比較は何も証明しない。
  -------------------------------------------------------------------------- }
procedure TestPacedDeviceItself;
var
  dev: TPacedSoundDevice;
  buf: array[0..1023] of Double;
  n: Integer;
  i: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. 試験用デバイスの確認 (前提) ---');
  dev := TPacedSoundDevice.Create;
  try
    dev.BufferLimit := 2048;
    dev.Open(sdRead, 48000);

    Sleep(30);   { 約 1440 サンプル生まれる (上限内) }
    n := dev.ReadSamples(buf, 1024);
    Check(n > 0, '時間が経てば読める');
    ok := True;
    for i := 0 to n - 1 do
      if buf[i] <> i then ok := False;
    Check(ok, '値が通し番号になっている');
    CheckEqI(dev.Dropped, 0, 'すぐ読めば消えない');

    { 読みに行かずに放置すると溢れる。 }
    Sleep(150);  { 約 7200 サンプル生まれる。上限 2048 なので溢れる }
    n := dev.ReadSamples(buf, 1024);
    Check(dev.Dropped > 0,
      '**読みに来なければ溢れて消える** (実機と同じ)');
    Check(n > 0, '溢れた後も読める');
    Check(buf[0] > 2048,
      '消えた分は飛ばされる (通し番号が飛ぶ)');
  finally
    dev.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. 分離の有無で dropout が変わること ── この試験の中心
  -------------------------------------------------------------------------- }
procedure TestSeparationPreventsDropout;
const
  RATE = 48000;
  DUR_MS = 700;
  DEV_BUF = 4096;     // 約 85ms ぶん。詰まり 120ms より短い
var
  direct, split: TRunResult;
begin
  WriteLn;
  WriteLn('--- 2. 分離の有無で dropout が変わること (X-01) ---');

  direct := RunScenario(False, DUR_MS, RATE, DEV_BUF);
  WriteLn(Format('  分離なし: 生成 %d / デバイス欠落 %d / 復調が見た %d / 飛び %d 箇所',
    [direct.Produced, direct.DeviceDropped, direct.Seen, direct.Gaps]));

  split := RunScenario(True, DUR_MS, RATE, DEV_BUF);
  WriteLn(Format('  分離あり: 生成 %d / デバイス欠落 %d / リング欠落 %d / 復調が見た %d / 飛び %d 箇所',
    [split.Produced, split.DeviceDropped, split.RingDropped,
     split.Seen, split.Gaps]));

  { 前提: 分離しなければ実際に落ちること。落ちないなら、詰まりが
    足りないか デバイスの上限が大きすぎて、試験になっていない。 }
  Check(direct.DeviceDropped > 0,
    '前提: 分離しなければデバイス側で音が失われる');
  Check(direct.Gaps > 0,
    '前提: 分離しなければ復調器が受け取る音に飛びが出る');

  { 本題。 }
  CheckEqI(split.DeviceDropped, 0,
    '**分離すればデバイス側で 1 サンプルも失われない**');
  Check(split.DeviceDropped < direct.DeviceDropped,
    '分離した方が欠落が少ない');
  CheckEqI(split.Gaps, 0,
    '**復調器が受け取る音に飛びが無い** (通し番号が連続している)');
  { 実行時間は毎回わずかに違うので、生成数に対する割合で比べる。
    件数そのままだと、たまたま片方が長く走っただけで逆転しうる。 }
  Check((split.Seen / split.Produced) > (direct.Seen / direct.Produced),
    Format('分離した方が生成に対して多く復調に回る (%.1f%% > %.1f%%)',
      [100 * split.Seen / split.Produced,
       100 * direct.Seen / direct.Produced]));
end;

{ --------------------------------------------------------------------------
  3. リングも溢れれば数が残ること

  分離すれば無敵になるわけではない。復調が恒常的に間に合わなければ
  いずれリングも溢れる。そのとき黙って捨てないことを確かめる。
  -------------------------------------------------------------------------- }
procedure TestRingOverflowIsCounted;
const
  RATE = 48000;
var
  r: TRunResult;
begin
  WriteLn;
  WriteLn('--- 3. リングが溢れたときも数が残ること (ADR-010) ---');

  { 分離すれば無敵になるわけではない。復調が **恒常的に** 間に合わなければ
    いずれリングも溢れる。そのとき黙って捨てないことを確かめる。

    デバイスの上限を極端に大きくしておくので、落ちるとすればリングである。
    リングは 0.1 秒ぶんしかなく、復調は 2 ブロックに 1 回 150ms 止まる。
    この条件で溢れなければ、そもそも溢れさせる試験になっていない。 }
  r := RunScenario(True, 700, RATE, 1 shl 22,
        RATE div 10,    { リング = 0.1 秒ぶん }
        2, 150);        { 2 ブロックに 1 回 150ms 止まる }

  WriteLn(Format('  デバイス欠落 %d / リング欠落 %d / 復調が見た %d',
    [r.DeviceDropped, r.RingDropped, r.Seen]));

  CheckEqI(r.DeviceDropped, 0,
    '前提: デバイス側では落ちていない (落ちるとすればリング)');
  Check(r.RingDropped > 0,
    '**復調が追いつかなければリングが溢れ、その数が残る** (黙って捨てない)');
  Check(r.Seen > 0, '溢れても復調は進み続ける');

  { 保存則。復調が見た数と捨てた数の合計が、生成した数を超えることは
    ありえない。超えていれば数え方が壊れている。

    「捨てた分は復調器から見て飛びになる」も真だが、読み手がその継ぎ目に
    到達するまでの時間に依存するので、短い試験では出ないことがある。
    時間に依らないこちらを見る。 }
  Check(r.Seen + r.RingDropped <= r.Produced,
    Format('保存則: 復調 %d + 欠落 %d <= 生成 %d',
      [r.Seen, r.RingDropped, r.Produced]));
  Check(r.Produced - r.Seen - r.RingDropped >= 0,
    '説明のつかない消失が無い');
end;

{ --------------------------------------------------------------------------
  4. 履歴を取りながら取り込めること (X-06)
  -------------------------------------------------------------------------- }
procedure TestCaptureWithHistory;
const
  RATE = 8000;
var
  dev: TPacedSoundDevice;
  cap: TAudioCapture;
  dst: array[0..1023] of Double;
  n, i: Integer;
  ok: Boolean;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 4. 取り込みながら Replay 履歴を残すこと (X-06) ---');
  dev := TPacedSoundDevice.Create;
  dev.BufferLimit := 1 shl 20;
  dev.Open(sdRead, RATE);
  cap := TAudioCapture.Create(dev, RATE, 1.0, RATE);
  try
    cap.Start;
    Sleep(300);
    cap.RequestStop;
    cap.WaitFor;

    Check(cap.History <> nil, '履歴を持っている');
    Check(cap.TotalCaptured > 0, '取り込んだサンプルがある');
    Check(cap.History.TotalWritten > 0, '履歴にも書かれている');
    CheckEqI(cap.History.TotalWritten, cap.TotalCaptured,
      '取り込んだ数と履歴の数が一致する');

    cap.History.LiveRange(first, last);
    n := cap.History.ReadLatest(512, dst);
    Check(n > 0, '履歴から直近を取り出せる');
    ok := True;
    for i := 1 to n - 1 do
      if dst[i] <> dst[i - 1] + 1 then ok := False;
    Check(ok, '**取り出した波形の通し番号が連続している** (Replay に使える)');

    { リングの中身と履歴が同じ音を指していること。 }
    Check(cap.Ring.Available > 0, 'リングにも溜まっている');
  finally
    cap.Free;
    dev.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4b. エンジンを先に止めても取り込みが乱されないこと

  分離しているとき、RX デバイスでブロックしているのは **取り込みスレッド**
  であってエンジンではない。エンジンの終了処理がそこへ AbortIO を撃つと、
  他人の I/O を横から解除することになり、取り込み側は原因不明の
  読み出し失敗として数える。デバイスも閉じられてしまう。

  停止の順序は呼び出し側の自由なので、どちらから止めても壊れないこと。
  -------------------------------------------------------------------------- }
procedure TestEngineStopDoesNotDisturbCapture;
const
  RATE = 8000;
var
  dev: TPacedSoundDevice;
  eng: TModemEngine;
  m: TStallingModem;
  cap: TAudioCapture;
  capturedAtEngineStop: Int64;
begin
  WriteLn;
  WriteLn('--- 4b. エンジンを先に止めても取り込みが乱されないこと ---');
  dev := TPacedSoundDevice.Create;
  dev.BufferLimit := 1 shl 20;
  dev.Open(sdRead, RATE);
  m := TStallingModem.Create(dev);
  m.StallEvery := 0;
  eng := TModemEngine.Create(dev, dev);
  cap := TAudioCapture.Create(dev, RATE, 0, RATE);
  try
    eng.AttachCapture(cap);
    eng.SetModem(m);
    cap.Start;
    eng.Start;
    eng.RequestReceive;
    Sleep(100);

    CheckEqI(cap.ReadErrors, 0, '前提: ここまで読み出し失敗は無い');

    { --- ここが要点: 取り込みより先にエンジンを止める --- }
    eng.RequestExit;
    eng.WaitFor;
    capturedAtEngineStop := cap.TotalCaptured;

    CheckEqI(cap.ReadErrors, 0,
      '**エンジンの停止が取り込みの読み出しを壊さない**');
    Check(dev.IsOpen,
      '**エンジンの停止でデバイスが閉じられない** (取り込みが使っている)');

    Sleep(60);
    Check(cap.TotalCaptured > capturedAtEngineStop,
      'エンジン停止後も取り込みは進み続ける');

    cap.RequestStop;
    cap.WaitFor;
    CheckEqI(cap.ReadErrors, 0, '自分で止めた分も失敗として数えない');
  finally
    cap.Free;
    eng.Free;
    m.Free;
    dev.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 繋ぎ替えの安全
  -------------------------------------------------------------------------- }
procedure TestAttachGuards;
var
  dev: TPacedSoundDevice;
  eng: TModemEngine;
  m: TStallingModem;
  cap: TAudioCapture;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 5. 繋ぎ替えの安全 ---');
  dev := TPacedSoundDevice.Create;
  dev.BufferLimit := 1 shl 20;
  dev.Open(sdRead, 8000);
  m := TStallingModem.Create(dev);
  m.StallEvery := 0;
  eng := TModemEngine.Create(dev, dev);
  cap := TAudioCapture.Create(dev, 8000, 0, 8000);
  try
    Check(not eng.IsCaptureSeparated, '既定では分離していない (従来経路)');
    eng.AttachCapture(cap);
    Check(eng.IsCaptureSeparated, '繋ぐと分離状態になる');
    Check(eng.Capture = cap, '繋いだものを取り出せる');

    eng.SetModem(m);
    cap.Start;
    eng.Start;
    eng.RequestReceive;
    Sleep(50);

    { 受信中の繋ぎ替えは拒む。 }
    raised := False;
    try
      eng.DetachCapture;
    except
      on EModemEngineError do raised := True;
    end;
    Check(raised, '**受信中の取り外しは拒む** (半端に読むのを防ぐ)');
    Check(eng.IsCaptureSeparated, '拒んだので状態は変わらない');

    cap.RequestStop;
    cap.WaitFor;
    eng.RequestExit;
    eng.WaitFor;

    { 停止後なら外せる。 }
    eng.DetachCapture;
    Check(not eng.IsCaptureSeparated, '停止後は外せる');
  finally
    cap.Free;
    eng.Free;
    m.Free;
    dev.Free;
  end;
end;

begin
  WriteLn('=== Phase 1 X-01 取り込みと復調の分離 テスト ===');

  TestPacedDeviceItself;
  TestSeparationPreventsDropout;
  TestRingOverflowIsCounted;
  TestCaptureWithHistory;
  TestEngineStopDoesNotDisturbCapture;
  TestAttachGuards;

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
    CoverReq('RT-007');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
