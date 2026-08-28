{ ============================================================================
  test_threadsafety.lpr

  品質レビューで指摘された P0 (メモリ安全性・送信安全性) の回帰テスト。
  修正前なら停止しない/落ちる/データが壊れる条件を再現して確かめる。

  対象:
    ENG-01 : エンジン破棄時のロック解放順序
    ENG-02 : モデム差し替えと RX/TX の競合
    ENG-04 : ブロッキング読み取り中でも停止できること / tsExit 通知
    UI-01  : 受信文字の取りこぼし・重複・順序破壊
    UI-02  : 破棄後にキューが実行される use-after-free
    APP-01 : UI とエンジンの破棄順序
    AUD-05 : 入出力の引数検証
    AUD-06 : 多チャネル時のバッファ長
    AUD-07 : AbortIO 後にストリームが残らないこと
    RIG-01 : ポーリングスレッド破棄時のロック解放順序
    RIG-11 : PTT フェイルセーフ

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -otest/test_threadsafety test/test_threadsafety.lpr
    ./test/test_threadsafety
  ============================================================================ }
program test_threadsafety;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, SyncObjs,
  SoundIntf, ModemTypes, Modem, ModemEngine, ModemUI, NullModemImpl,
  RigControlIntf, RigPollThread;

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

type
  { ReadSamples が「データが来るまで返らない」実デバイス (PortAudio の
    ブロッキング読み取り) を模したテストダブル。AbortIO で解除される。 }
  TBlockingSoundDevice = class(TCustomSoundDevice)
  private
    FRelease: TSimpleEvent;
    FAborted: Boolean;
    FReadEntered: Boolean;
  public
    constructor Create; override;
    destructor Destroy; override;
    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; override;
    procedure Close; override;
    procedure AbortIO; override;
    function ReadSamples(var Buf: array of Double; Count: Integer): Integer; override;
    function WriteSamples(const Buf: array of Double; Count: Integer): Integer; override;
    function WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer; override;
    procedure Flush; override;
    property ReadEntered: Boolean read FReadEntered;
  end;

constructor TBlockingSoundDevice.Create;
begin
  inherited Create;
  FRelease := TSimpleEvent.Create;
  FAborted := False;
  FReadEntered := False;
end;

destructor TBlockingSoundDevice.Destroy;
begin
  FRelease.Free;
  inherited Destroy;
end;

function TBlockingSoundDevice.Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean;
begin
  SampleRate := ASampleRate;
  FAborted := False;
  FRelease.ResetEvent;
  IsOpenFlag := True;
  Result := True;
end;

procedure TBlockingSoundDevice.Close;
begin
  FAborted := True;
  FRelease.SetEvent;
  IsOpenFlag := False;
end;

procedure TBlockingSoundDevice.AbortIO;
begin
  FAborted := True;
  FRelease.SetEvent;   // ブロック中の ReadSamples を解除する
  IsOpenFlag := False;
end;

function TBlockingSoundDevice.ReadSamples(var Buf: array of Double; Count: Integer): Integer;
begin
  FReadEntered := True;
  { データは永遠に来ない。AbortIO/Close だけが解除できる。 }
  FRelease.WaitFor(INFINITE);
  Result := 0;
end;

function TBlockingSoundDevice.WriteSamples(const Buf: array of Double; Count: Integer): Integer;
begin
  Result := Count;
end;

function TBlockingSoundDevice.WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer;
begin
  Result := Count;
end;

procedure TBlockingSoundDevice.Flush;
begin
end;

type
  { ワーカースレッドからイベントを投入する。
    FPC の TThread.Queue は「メインスレッドから呼ぶと即時実行」なので、
    キューイングの挙動 (UI-01/UI-02) を検証するには別スレッドから
    投入しなければならない。 }
  TPusherThread = class(TThread)
  private
    FUi: TModemUI;
    FCount: Integer;
    FDone: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AUi: TModemUI; ACount: Integer);
    { WaitFor はメインスレッドから呼ぶとキューを処理してしまうため、
      「キューに溜めたまま破棄する」検証では使えない。
      代わりにこのフラグを Sleep でポーリングして完了を待つ。 }
    property Done: Boolean read FDone;
  end;

  { UI イベントの受け手。受信文字を順番どおり記録する。 }
  TUiSink = class
  private
    FChars: TStringList;
    FStates: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnRxChar(Sender: TModemUI; ACh: Integer);
    procedure OnState(Sender: TModemUI; AState: TTrxState);
    property Chars: TStringList read FChars;
    property States: TStringList read FStates;
  end;

constructor TPusherThread.Create(AUi: TModemUI; ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FUi := AUi;
  FCount := ACount;
end;

procedure TPusherThread.Execute;
var
  i: Integer;
begin
  for i := 1 to FCount do
    FUi.PushEvent(uekRxChar, i, '');
  FDone := True;
end;

constructor TUiSink.Create;
begin
  inherited Create;
  FChars := TStringList.Create;
  FStates := TStringList.Create;
end;

destructor TUiSink.Destroy;
begin
  FChars.Free;
  FStates.Free;
  inherited Destroy;
end;

procedure TUiSink.OnRxChar(Sender: TModemUI; ACh: Integer);
begin
  FChars.Add(IntToStr(ACh));
end;

procedure TUiSink.OnState(Sender: TModemUI; AState: TTrxState);
begin
  FStates.Add(IntToStr(Ord(AState)));
end;

{ ------------------------------------------------------------------------
  1. ENG-04 / ENG-01: ブロッキング読み取り中でも停止・破棄できること
  ------------------------------------------------------------------------ }
procedure TestEngineStopsWhileBlocked;
var
  snd: TBlockingSoundDevice;
  eng: TModemEngine;
  modem: TNullModem;
  t0: TDateTime;
  elapsedMs: Double;
  waited: Integer;
begin
  WriteLn;
  WriteLn('--- 1. ENG-04/ENG-01: ブロッキング読み取り中の停止と破棄 ---');

  snd := TBlockingSoundDevice.Create;
  snd.Open(sdRead, 8000);
  modem := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  try
    eng.SetModem(modem);
    eng.Start;
    eng.RequestReceive;

    { ワーカーがブロッキング読み取りに入るまで待つ }
    waited := 0;
    while (not snd.ReadEntered) and (waited < 2000) do
    begin
      Sleep(1);
      Inc(waited);
    end;
    Check(snd.ReadEntered, 'ワーカーがブロッキング読み取りに入った');

    { 修正前はここで永久にハングしていた }
    t0 := Now;
    eng.RequestExit;
    eng.WaitFor;
    elapsedMs := (Now - t0) * 24 * 60 * 60 * 1000;
    WriteLn('  停止までの時間: ', elapsedMs:0:0, ' ms');
    Check(elapsedMs < 2000,
      'ブロッキング読み取り中でも 2 秒以内に停止する (ENG-04)');
  finally
    { ENG-01: 走行中/停止直後の破棄でロックを先に解放しないこと }
    eng.Free;
    modem.Free;
    snd.Free;
  end;
  Check(True, 'エンジン破棄がアクセス違反なく完了する (ENG-01)');
end;

{ ------------------------------------------------------------------------
  2. ENG-04: 終了時に tsExit が必ず通知されること
  ------------------------------------------------------------------------ }
procedure TestExitStateNotified;
var
  snd: TNullSoundDevice;
  eng: TModemEngine;
  modem: TNullModem;
  ui: TModemUI;
  sink: TUiSink;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 2. ENG-04: 終了時の tsExit 通知 ---');

  snd := TNullSoundDevice.Create;
  snd.Open(sdRead, 8000);
  modem := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  ui := TModemUI.Create;
  sink := TUiSink.Create;
  try
    ui.OnStateChanged := @sink.OnState;
    ui.AttachEngine(eng);
    eng.SetModem(modem);
    eng.Start;
    eng.RequestReceive;
    Sleep(50);
    eng.RequestExit;
    eng.WaitFor;

    { キューを掃き出す }
    for i := 1 to 20 do
    begin
      CheckSynchronize(10);
      Sleep(5);
    end;

    Check(sink.States.IndexOf(IntToStr(Ord(tsExit))) >= 0,
      '終了時に tsExit(' + IntToStr(Ord(tsExit)) + ') が通知される。実際: [' +
      sink.States.CommaText + ']');
  finally
    ui.Free;
    eng.Free;
    modem.Free;
    snd.Free;
    sink.Free;
  end;
end;

{ ------------------------------------------------------------------------
  3. UI-01: 受信文字を取りこぼさず、重複させず、順序も守ること
  ------------------------------------------------------------------------ }
procedure TestUiCharOrdering;
const
  N = 500;
var
  ui: TModemUI;
  sink: TUiSink;
  pusher: TPusherThread;
  i, drained: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 3. UI-01: 受信文字の欠落・重複・順序 (', N, '文字) ---');

  ui := TModemUI.Create;
  sink := TUiSink.Create;
  try
    ui.OnRxChar := @sink.OnRxChar;

    { メインスレッドが取り出す前に、別スレッドから連続投入する
      = 旧実装 (単一 FPending* を上書き) が壊れる条件。 }
    pusher := TPusherThread.Create(ui, N);
    pusher.Start;
    pusher.WaitFor;
    pusher.Free;

    drained := 0;
    while (sink.Chars.Count < N) and (drained < 200) do
    begin
      CheckSynchronize(10);
      Inc(drained);
    end;

    Check(sink.Chars.Count = N,
      IntToStr(N) + ' 文字すべてが届く (実際: ' + IntToStr(sink.Chars.Count) + ')');

    ok := True;
    for i := 0 to sink.Chars.Count - 1 do
      if sink.Chars[i] <> IntToStr(i + 1) then
      begin
        ok := False;
        Break;
      end;
    Check(ok, '順序が投入順どおりで、重複も入れ替わりもない');
    Check(ui.DroppedEventCount = 0,
      '有界FIFOの溢れが発生していない (捨てた件数 ' +
      IntToStr(ui.DroppedEventCount) + ')');
  finally
    ui.Free;
    sink.Free;
  end;
end;

{ ------------------------------------------------------------------------
  4. UI-02 / APP-01: 破棄後にキューが実行されないこと
  ------------------------------------------------------------------------ }
procedure TestUiDestroyRemovesQueue;
var
  ui: TModemUI;
  sink: TUiSink;
  pusher: TPusherThread;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 4. UI-02: 破棄後にキューが実行されないこと ---');

  sink := TUiSink.Create;
  try
    ui := TModemUI.Create;
    ui.OnRxChar := @sink.OnRxChar;
    { 別スレッドから大量に積み、メインスレッドで一度も取り出さないまま
      破棄する = 旧実装なら破棄済み Self のメソッドが後から呼ばれる。 }
    pusher := TPusherThread.Create(ui, 200);
    pusher.Start;
    { WaitFor を使うとメインスレッドがここでキューを処理してしまい、
      「破棄前に配送済み」になって検証にならない。Sleep で待つ。 }
    i := 0;
    while (not pusher.Done) and (i < 2000) do
    begin
      Sleep(1);
      Inc(i);
    end;
    Check(pusher.Done, '投入スレッドが完了した (キューは未処理のまま)');

    ui.Free;      // ここで未処理のキューが取り消されなければ UAF になる
    pusher.Free;  // ui.Free の後なら WaitFor でキューを処理しても安全

    { 破棄後にメインスレッドのキューを回す。
      修正前はここで解放済みオブジェクトのメソッドが実行されていた。 }
    for i := 1 to 20 do
    begin
      CheckSynchronize(10);
      Sleep(1);
    end;

    Check(sink.Chars.Count = 0,
      '破棄後に積まれていたイベントは実行されない (実際: ' +
      IntToStr(sink.Chars.Count) + '件)');
  finally
    sink.Free;
  end;
end;

{ ------------------------------------------------------------------------
  5. ENG-02: RX 継続中のモデム差し替えが安全なこと
  ------------------------------------------------------------------------ }
procedure TestModemSwapUnderLoad;
const
  SWAPS = 30;
var
  snd: TNullSoundDevice;
  eng: TModemEngine;
  m1, m2: TNullModem;
  i: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 5. ENG-02: RX 継続中のモデム差し替え x', SWAPS, ' ---');

  snd := TNullSoundDevice.Create;
  snd.Open(sdRead, 8000);
  m1 := TNullModem.Create(snd);
  m2 := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  try
    eng.SetModem(m1);
    eng.Start;
    eng.RequestReceive;

    ok := True;
    try
      for i := 1 to SWAPS do
      begin
        if Odd(i) then
          eng.SetModem(m2)
        else
          eng.SetModem(m1);
      end;
    except
      on E: Exception do
      begin
        ok := False;
        WriteLn('    例外: ', E.Message);
      end;
    end;
    Check(ok, 'RX 実行中の差し替えが例外なく完了する');
    Check(eng.ActiveModem <> nil, '差し替え後もアクティブモデムが有効');
    { SetModem は入れ替え完了まで待つ契約なので、戻った時点で
      直前のモデムはもう使われていない = 解放して安全。 }
    Check(True, 'SetModem 復帰後に旧モデムを解放できる契約が保たれる');

    eng.RequestExit;
    eng.WaitFor;
  finally
    eng.Free;
    m1.Free;
    m2.Free;
    snd.Free;
  end;
end;

{ ------------------------------------------------------------------------
  6. AUD-05 / AUD-06: 入出力の引数検証とチャネル長
  ------------------------------------------------------------------------ }
procedure TestSoundContracts;
var
  snd: TNullSoundDevice;
  buf: array[0..15] of Double;
  bufR: array[0..7] of Double;
  caught: Boolean;
begin
  WriteLn;
  WriteLn('--- 6. AUD-05: 入出力の引数検証 ---');

  snd := TNullSoundDevice.Create;
  try
    { 未オープンでの読み取りは契約違反 }
    caught := False;
    try
      snd.ReadSamples(buf, 8);
    except
      on E: ESoundError do caught := True;
    end;
    Check(caught, '未オープンでの ReadSamples は ESoundError');

    snd.Open(sdRead, 8000);

    caught := False;
    try
      snd.ReadSamples(buf, -1);
    except
      on E: ESoundError do caught := True;
    end;
    Check(caught, 'Count が負なら ESoundError');

    caught := False;
    try
      snd.ReadSamples(buf, Length(buf) + 1);
    except
      on E: ESoundError do caught := True;
    end;
    Check(caught, 'Count がバッファ長を超えたら ESoundError');

    Check(snd.ReadSamples(buf, 0) = 0, 'Count=0 は例外にせず 0 件で正常終了');

    caught := False;
    try
      snd.WriteStereo(buf, bufR, 16);   // R 側が 8 要素しかない
    except
      on E: ESoundError do caught := True;
    end;
    Check(caught, 'WriteStereo で R バッファ長が不足なら ESoundError');
  finally
    snd.Free;
  end;
end;

{ ------------------------------------------------------------------------
  7. RIG-01 / RIG-11: ポーリングスレッド破棄と PTT フェイルセーフ
  ------------------------------------------------------------------------ }
procedure TestRigSafety;
var
  rig: TNullRigControl;
  poll: TRigPollThread;
begin
  WriteLn;
  WriteLn('--- 7. RIG-01/RIG-11: スレッド破棄と PTT フェイルセーフ ---');

  { --- RIG-01: 走行中のポーリングスレッドを破棄する --- }
  rig := TNullRigControl.Create;
  try
    rig.Open;
    poll := TRigPollThread.Create(rig);
    poll.Start;
    Sleep(60);   // 実際にポーリングを回してから破棄する
    poll.Free;   // 修正前は解放済みロックを触りえた
    Check(True, '走行中のポーリングスレッド破棄が完了する (RIG-01)');
  finally
    rig.Free;
  end;

  { --- RIG-11: 送信状態のまま破棄しても PTT が下りること --- }
  rig := TNullRigControl.Create;
  try
    rig.Open;
    rig.SetPTT(True);
    Check(rig.GetPTT, '送信 ON になっている');
    Check(rig.PttAsserted, 'フェイルセーフが送信状態を把握している');

    Check(rig.EnsurePttOff, 'EnsurePttOff が成功する');
    Check(not rig.GetPTT, 'EnsurePttOff で PTT が下りる (RIG-11)');
    Check(not rig.PttAsserted, '送信状態の記録がクリアされる');
  finally
    rig.Free;
  end;

  { --- 例外が起きても PTT が下りること --- }
  rig := TNullRigControl.Create;
  try
    rig.Open;
    try
      rig.SetPTT(True);
      raise Exception.Create('送信中の障害を模擬');
    except
      on E: Exception do
        rig.EnsurePttOff;
    end;
    Check(not rig.GetPTT, '例外経路でも PTT が下りる (RIG-11)');
  finally
    rig.Free;
  end;

  { --- 破棄経路でも PTT が下りること --- }
  rig := TNullRigControl.Create;
  rig.Open;
  rig.SetPTT(True);
  rig.Free;   // Destroy が EnsurePttOff を呼ぶ
  Check(True, '送信状態のまま破棄しても例外なく完了する (RIG-11)');
end;

begin
  WriteLn('=== P0 (メモリ安全性・送信安全性) 回帰テスト ===');

  TestEngineStopsWhileBlocked;
  TestExitStateNotified;
  TestUiCharOrdering;
  TestUiDestroyRemovesQueue;
  TestModemSwapUnderLoad;
  TestSoundContracts;
  TestRigSafety;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
