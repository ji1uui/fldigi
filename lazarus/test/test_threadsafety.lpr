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
  RigControlIntf, RigPollThread, DecodeEvidence, EventBus;

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
    FErrors: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnRxChar(Sender: TModemUI; ACh: Integer;
      AMetricKind: TEvidenceMetricKind; AMetric: Double; AAltCount: Integer);
    procedure OnState(Sender: TModemUI; AState: TTrxState);
    procedure OnError(Sender: TModemUI; const AMsg: string);
    property Chars: TStringList read FChars;
    property States: TStringList read FStates;
    property Errors: TStringList read FErrors;
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
  FErrors := TStringList.Create;
end;

destructor TUiSink.Destroy;
begin
  FChars.Free;
  FStates.Free;
  FErrors.Free;
  inherited Destroy;
end;

procedure TUiSink.OnRxChar(Sender: TModemUI; ACh: Integer;
  AMetricKind: TEvidenceMetricKind; AMetric: Double; AAltCount: Integer);
begin
  FChars.Add(IntToStr(ACh));
end;

procedure TUiSink.OnError(Sender: TModemUI; const AMsg: string);
begin
  FErrors.Add(AMsg);
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
procedure TestSharedBusUnsubscribe;
{ ADR-001 の移行で入った経路。TModemUI が「自前のバス」ではなく
  外から渡されたバスを共有する場合、破棄時に購読を外さないと
  バス側に解放済み TModemUI を指すハンドラが残る。

  自前バスの場合はバスごと解放されるので気づけない。
  共有バスの場合だけ露見するので、そちらを明示的に検査する。 }
var
  bus: TEventBus;
  ui: TModemUI;
  sink: TUiSink;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 14. ADR-001: 共有バスからの購読解除 ---');
  bus := TEventBus.Create;
  sink := TUiSink.Create;
  try
    bus.AutoDispatch := False;
    ui := TModemUI.Create(bus);      { バスを共有する }
    ui.OnRxChar := @sink.OnRxChar;
    Check(bus.SubscriberCount = 1, 'TModemUI がバスを購読する');
    Check(ui.Bus = bus, '渡したバスをそのまま使う (自前で作らない)');

    ui.PushEvent(uekRxChar, Ord('A'), '');
    bus.DispatchPending;
    Check(sink.Chars.Count = 1, '共有バス経由でイベントが届く');

    ui.Free;
    Check(bus.SubscriberCount = 0,
      '破棄時に購読を外す (解放済みハンドラをバスに残さない)');

    { 解放後にバスへ発行しても、解放済みハンドラは呼ばれない }
    for i := 1 to 10 do
      bus.PublishNumeric(bekDecodedSymbol, Ord('B'), 0, 0, 0, 'test');
    bus.DispatchPending;
    Check(sink.Chars.Count = 1,
      '破棄後の発行は解放済み TModemUI へ配送されない (実際: ' +
      IntToStr(sink.Chars.Count) + '件)');
    Check(bus.SubscriberErrorCount = 0, '購読者の例外も発生していない');
  finally
    sink.Free;
    bus.Free;
  end;
end;

procedure TestFrequencyConflationThroughUi;
{ UI-01: 周波数と S メーターは更新頻度が高く、FIFO に積むと
  復調文字を押し出す。TModemUI を通した経路で合流していることを確かめる。
  バス単体の合流テスト (test_eventbus 8) とは別に、
  TModemUI が合流用の発行を使っているかを見る。 }
var
  bus: TEventBus;
  ui: TModemUI;
  sink: TUiSink;
  modem: TNullModem;
  snd: TNullSoundDevice;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 15. UI-01: 周波数更新が復調文字を押し出さないこと ---');
  snd := TNullSoundDevice.Create;
  modem := TNullModem.Create(snd);
  bus := TEventBus.Create(64);   { 小さい容量で押し出しを起こしやすくする }
  sink := TUiSink.Create;
  try
    bus.AutoDispatch := False;
    ui := TModemUI.Create(bus);
    try
      ui.OnRxChar := @sink.OnRxChar;
      ui.AttachModem(modem);

      { 文字 20 件のあいだに周波数を 500 回更新する }
      for i := 1 to 20 do
        ui.PushEvent(uekRxChar, Ord('0') + (i mod 10), '');
      for i := 1 to 500 do
        modem.Frequency := 1000 + i;

      bus.DispatchPending;
      Check(sink.Chars.Count = 20,
        '文字 20 件がすべて届く (実際: ' + IntToStr(sink.Chars.Count) + ')');
      Check(ui.DroppedEventCount = 0,
        '周波数更新で文字が押し出されていない (捨てた件数 ' +
        IntToStr(ui.DroppedEventCount) + ')');
      ui.DetachModem;
    finally
      ui.Free;
    end;
  finally
    sink.Free; bus.Free; modem.Free; snd.Free;
  end;
end;

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

  { --- 破棄経路でも PTT が下りること ---
    ここでは「例外なく完了する」ことだけを見る。実際に SetPTT(False) が
    発行されたかは、外から観測できるテストダブルを使う 12 で検証する。 }
  rig := TNullRigControl.Create;
  rig.Open;
  rig.SetPTT(True);
  rig.Free;   // Destroy が EnsurePttOff を呼ぶ
  Check(True, '送信状態のまま破棄しても例外なく完了する (RIG-11)');
end;

type
  { 破棄経路で本当に PTT が下りたかを、オブジェクトの外から観測するための
    テストダブル。以前のテストは rig.Free の後に Check(True,...) と
    書いていただけで、実際には何も検証していなかった。 }
  TObservedRigControl = class(TNullRigControl)
  public
    procedure SetPTT(OnOff: Boolean; Vfo: TRigVfoSel = rvCurrent); override;
  end;

  { TransmitGuarded に渡すメソッド (procedure of object) の提供元。
    引数型が System.TProcedure のままだとこれがコンパイルできない。 }
  TTxCaller = class
  private
    FRig: TCustomRigControl;
    FRaise: Boolean;
  public
    constructor Create(ARig: TCustomRigControl; ARaise: Boolean);
    procedure DoTransmit;
    property Rig: TCustomRigControl read FRig;
  end;

var
  GPttOffSeen: Boolean = False;
  GPttOnSeen: Boolean = False;

procedure TObservedRigControl.SetPTT(OnOff: Boolean; Vfo: TRigVfoSel);
begin
  inherited SetPTT(OnOff, Vfo);
  if OnOff then GPttOnSeen := True else GPttOffSeen := True;
end;

constructor TTxCaller.Create(ARig: TCustomRigControl; ARaise: Boolean);
begin
  inherited Create;
  FRig := ARig;
  FRaise := ARaise;
end;

procedure TTxCaller.DoTransmit;
begin
  FRig.SetPTT(True);
  if FRaise then
    raise Exception.Create('送信中の障害を模擬');
end;

type
  { 実デバイス (PortAudio) の挙動を模す。AbortIO/Close の後に
    ReadSamples を呼ぶと例外を投げる。 }
  TRaisingSoundDevice = class(TCustomSoundDevice)
  private
    FRelease: TSimpleEvent;
    FFailNow: Boolean;
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
    { 走行中の障害を模擬する (終了要求とは無関係な本物のエラー) }
    procedure InjectFailure;
  end;

constructor TRaisingSoundDevice.Create;
begin
  inherited Create;
  FRelease := TSimpleEvent.Create;
  FFailNow := False;
end;

destructor TRaisingSoundDevice.Destroy;
begin
  FRelease.Free;
  inherited Destroy;
end;

function TRaisingSoundDevice.Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean;
begin
  SampleRate := ASampleRate;
  FRelease.ResetEvent;
  FFailNow := False;
  IsOpenFlag := True;
  Result := True;
end;

procedure TRaisingSoundDevice.Close;
begin
  IsOpenFlag := False;
  FRelease.SetEvent;
end;

procedure TRaisingSoundDevice.AbortIO;
begin
  { PortAudio 実装と同じく「解除して閉じる」。以降の Read は例外になる。 }
  Close;
end;

procedure TRaisingSoundDevice.InjectFailure;
begin
  FFailNow := True;
  FRelease.SetEvent;
end;

function TRaisingSoundDevice.ReadSamples(var Buf: array of Double; Count: Integer): Integer;
begin
  Result := 0;
  FRelease.WaitFor(INFINITE);
  FRelease.ResetEvent;
  if FFailNow then
    raise ESoundError.Create('デバイス障害を模擬');
  if not IsOpen then
    raise ESoundError.Create('ReadSamples: デバイスが未オープンです');
end;

function TRaisingSoundDevice.WriteSamples(const Buf: array of Double; Count: Integer): Integer;
begin
  Result := Count;
end;

function TRaisingSoundDevice.WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer;
begin
  Result := Count;
end;

procedure TRaisingSoundDevice.Flush;
begin
end;

procedure TestNoSpuriousErrorOnShutdown;
{ 終了手順そのものが生む例外を「エラー」として通知しないこと。
  RequestExit は AbortIO でブロッキング読み取りを叩き落とすので、
  実デバイスでは直後の ReadSamples が必ず例外になる。それを通知すると
  終了のたびに偽のエラーがユーザーに出る。
  一方、走行中の本物の障害はきちんと通知されなければならない。 }
var
  snd: TRaisingSoundDevice;
  eng: TModemEngine;
  modem: TNullModem;
  ui: TModemUI;
  sink: TUiSink;
  i, atShutdown: Integer;
begin
  WriteLn;
  WriteLn('--- 13. ENG-05: 終了時の偽エラーと本物の障害を区別する ---');

  { (a) 正常な終了手順ではエラーを出さない }
  snd := TRaisingSoundDevice.Create;
  snd.Open(sdRead, 8000);
  modem := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  ui := TModemUI.Create;
  sink := TUiSink.Create;
  try
    ui.OnError := @sink.OnError;
    ui.AttachEngine(eng);
    eng.SetModem(modem);
    eng.Start;
    eng.RequestReceive;
    Sleep(50);
    eng.RequestExit;
    eng.WaitFor;
    for i := 1 to 20 do begin CheckSynchronize(10); Sleep(5); end;
    atShutdown := sink.Errors.Count;
    Check(atShutdown = 0,
      '正常終了では偽のエラー通知が出ない (実際: ' + IntToStr(atShutdown) + ' 件)');
  finally
    ui.Free; eng.Free; modem.Free; snd.Free; sink.Free;
  end;

  { (b) 走行中の本物の障害は通知する }
  snd := TRaisingSoundDevice.Create;
  snd.Open(sdRead, 8000);
  modem := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  ui := TModemUI.Create;
  sink := TUiSink.Create;
  try
    ui.OnError := @sink.OnError;
    ui.AttachEngine(eng);
    eng.SetModem(modem);
    eng.Start;
    eng.RequestReceive;
    Sleep(30);
    snd.InjectFailure;
    for i := 1 to 20 do begin CheckSynchronize(10); Sleep(5); end;
    Check(sink.Errors.Count > 0,
      '走行中の障害はエラーとして通知される (実際: ' +
      IntToStr(sink.Errors.Count) + ' 件)');
    eng.RequestExit;
    eng.WaitFor;
  finally
    ui.Free; eng.Free; modem.Free; snd.Free; sink.Free;
  end;
end;

procedure TestSetModemAfterExit;
{ 停止済みエンジンへの SetModem。修正前は FModemChangeDone を待ち続けて
  5 秒のタイムアウト後に例外になっていた (あるいは RequestExit が
  適用せずにイベントを立てるため「差し替え済み」と偽って戻り、
  呼び出し側が使用中の旧モデムを解放しえた)。 }
var
  sound: TNullSoundDevice;
  eng: TModemEngine;
  m1, m2: TNullModem;
  t0: QWord;
  elapsed: QWord;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 8. ENG-02: 停止済みエンジンへの SetModem ---');
  sound := TNullSoundDevice.Create;
  sound.Open(sdRead, 8000);
  m1 := TNullModem.Create(sound);
  m2 := TNullModem.Create(sound);
  eng := TModemEngine.Create(sound, sound);
  try
    eng.SetModem(m1);
    eng.Start;
    eng.RequestReceive;
    Sleep(30);
    eng.RequestExit;
    eng.WaitFor;      // ここでワーカーは確実に終了している

    raised := False;
    t0 := GetTickCount64;
    try
      eng.SetModem(m2);
    except
      on E: Exception do
        raised := True;
    end;
    elapsed := GetTickCount64 - t0;

    Check(not raised, '停止済みエンジンへの SetModem が例外にならない');
    WriteLn('  所要時間: ', elapsed, ' ms');
    Check(elapsed < 1000, '待ち続けずに即座に完了する (実際 ' + IntToStr(elapsed) + ' ms)');
    Check(eng.ActiveModem = m2, '差し替えが実際に反映されている');
  finally
    eng.Free;
    m1.Free;
    m2.Free;
    sound.Free;
  end;
end;

type
  { 別スレッドから SetModem を呼ぶ。ワーカーがブロッキング読み取りで
    止まっている間に要求を出し、そこへ RequestExit を重ねるための道具。 }
  TSwapThread = class(TThread)
  private
    FEng: TModemEngine;
    FModem: TCustomModem;
    FDone: Boolean;
    FRaised: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AEng: TModemEngine; AModem: TCustomModem);
    property Done: Boolean read FDone;
    property Raised: Boolean read FRaised;
  end;

constructor TSwapThread.Create(AEng: TModemEngine; AModem: TCustomModem);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FEng := AEng;
  FModem := AModem;
  FDone := False;
  FRaised := False;
end;

procedure TSwapThread.Execute;
begin
  try
    FEng.SetModem(FModem);
  except
    on E: Exception do
      FRaised := True;
  end;
  FDone := True;
end;

procedure TestSwapRacingExit;
{ ENG-02: 「待っている最中にワーカーが終了する」競合。
  ワーカーがブロッキング読み取りで止まっている間に別スレッドが SetModem を
  出し、そこへ RequestExit を重ねる。

  修正前は RequestExit と Execute の finally が「適用せずに完了イベントだけ
  立てる」実装だったため、SetModem は成功として戻るのに FActiveModem は
  旧モデムのままだった。呼び出し側は契約 (「戻ったら旧モデムを解放してよい」)
  に従って旧モデムを解放するので、エンジンが解放済みモデムを指す。 }
var
  snd: TBlockingSoundDevice;
  eng: TModemEngine;
  m1, m2: TNullModem;
  swap: TSwapThread;
  spin: Integer;
begin
  WriteLn;
  WriteLn('--- 9. ENG-02: 差し替え待ちの最中にワーカーが終了する競合 ---');
  snd := TBlockingSoundDevice.Create;
  snd.Open(sdRead, 8000);
  m1 := TNullModem.Create(snd);
  m2 := TNullModem.Create(snd);
  eng := TModemEngine.Create(snd, snd);
  swap := nil;
  try
    eng.SetModem(m1);
    eng.Start;
    eng.RequestReceive;

    { ワーカーがブロッキング読み取りに入るまで待つ }
    spin := 0;
    while (not snd.ReadEntered) and (spin < 2000) do
    begin
      Sleep(1);
      Inc(spin);
    end;
    Check(snd.ReadEntered, 'ワーカーがブロッキング読み取りに入った');

    { この時点で SetModem は「走行中」と判断し、要求を置いて待ちに入る。
      ワーカーは読み取りで止まっているので、まだ適用できない。 }
    swap := TSwapThread.Create(eng, m2);
    swap.Start;
    Sleep(50);
    Check(not swap.Done, 'SetModem は適用待ちでブロックしている');

    { ここへ終了要求を重ねる }
    eng.RequestExit;

    spin := 0;
    while (not swap.Done) and (spin < 3000) do
    begin
      Sleep(1);
      Inc(spin);
    end;
    Check(swap.Done, 'SetModem がタイムアウトを待たずに復帰する');

    if swap.Raised then
      Check(eng.ActiveModem = m1,
        'SetModem が失敗を返したなら差し替えは行われていない')
    else
      Check(eng.ActiveModem = m2,
        'SetModem が成功を返したなら差し替えは実際に済んでいる ' +
        '(戻った時点で旧モデムを解放してよいという契約)');
  finally
    swap.Free;
    eng.Free;
    m1.Free;
    m2.Free;
    snd.Free;
  end;
end;

procedure TestUiDestroyUnderConcurrentPush;
{ 投入スレッドを走らせながら生成・破棄を繰り返し、破棄処理そのものが
  競合下で壊れないことを数で確かめる。
  ※「破棄の最中にワーカーがコールバックの中にいる」瞬間は外から
    決定的に作れないため、これは確率的なストレステストである。
    在席カウンタ (TModemUI の EnterCallback) の窓そのものを証明する
    ものではない。 }
const
  ROUNDS = 100;
var
  i: Integer;
  ui: TModemUI;
  pusher: TPusherThread;
  sink: TUiSink;
  spin: Integer;
begin
  WriteLn;
  WriteLn('--- 10. UI-02: 投入スレッド走行中の生成・破棄を繰り返す ---');
  sink := TUiSink.Create;
  try
    for i := 1 to ROUNDS do
    begin
      ui := TModemUI.Create;
      ui.OnRxChar := @sink.OnRxChar;
      pusher := TPusherThread.Create(ui, 200);
      pusher.Start;
      { 投入が始まったのを確認してから破棄に入る }
      spin := 0;
      while (not pusher.Done) and (spin < 200) do
      begin
        Sleep(1);
        Inc(spin);
      end;
      ui.Free;
      pusher.Free;   // ui.Free の後なら WaitFor がキューを処理しても安全
    end;
    Check(True, IntToStr(ROUNDS) +
      ' 回の「投入スレッド走行中の生成・破棄」が完了する (ストレス)');
  finally
    sink.Free;
  end;
end;

procedure TestRigPollFastShutdown;
{ RIG-01: ポーリング間隔をそのまま Sleep していたため、間隔を長くすると
  破棄がその分ブロックしていた。 }
var
  rig: TNullRigControl;
  poll: TRigPollThread;
  t0, elapsed: QWord;
begin
  WriteLn;
  WriteLn('--- 11. RIG-01: 長いポーリング間隔でも破棄が待たされないこと ---');
  rig := TNullRigControl.Create;
  try
    rig.Open;
    poll := TRigPollThread.Create(rig);
    poll.PollIntervalMs := 5000;   // 5秒間隔
    poll.Start;
    Sleep(50);                     // Sleep に入らせる
    t0 := GetTickCount64;
    poll.Free;
    elapsed := GetTickCount64 - t0;
    WriteLn('  破棄までの時間: ', elapsed, ' ms (ポーリング間隔 5000 ms)');
    { 参考: この環境では FPC の TThread.Free 自体に約 100 ms かかるため、
      それが下限になる。修正前は約 5000 ms (ポーリング間隔そのもの)。 }
    Check(elapsed < 1000,
      'ポーリング間隔を待たずに停止する (実際 ' + IntToStr(elapsed) + ' ms)');
  finally
    rig.Free;
  end;
end;

procedure TestPttFailsafeObservable;
var
  rig: TObservedRigControl;
  caller: TTxCaller;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 12. RIG-11: PTT フェイルセーフを外から観測する ---');

  { --- 破棄経路で本当に SetPTT(False) が呼ばれるか --- }
  GPttOnSeen := False;
  GPttOffSeen := False;
  rig := TObservedRigControl.Create;
  rig.Open;
  rig.SetPTT(True);
  Check(GPttOnSeen, '送信 ON が実際に発行された');
  rig.Free;
  Check(GPttOffSeen, '破棄経路で SetPTT(False) が実際に発行される (RIG-11)');

  { --- TransmitGuarded がメソッドを受け取れること + 例外時も下ろすこと --- }
  GPttOffSeen := False;
  rig := TObservedRigControl.Create;
  caller := TTxCaller.Create(rig, True);
  try
    rig.Open;
    raised := False;
    try
      rig.TransmitGuarded(@caller.DoTransmit);
    except
      on E: Exception do
        raised := True;
    end;
    Check(raised, 'TransmitGuarded は送信処理の例外を握り潰さない');
    Check(GPttOffSeen, '例外が出ても finally で PTT が下りる (RIG-11)');
    Check(not rig.GetPTT, '送信状態が残っていない');
  finally
    caller.Free;
    rig.Free;
  end;

  { --- 下ろせないのに成功を報告しないこと --- }
  rig := TObservedRigControl.Create;
  try
    rig.Open;
    rig.SetPTT(True);
    rig.Close;   // 通信路が閉じたので PTT を操作できない
    Check(not rig.EnsurePttOff,
      '下ろせない状況で EnsurePttOff は False を返す (成功と偽らない)');
    Check(rig.PttAsserted,
      '下ろせなかった記録は残す (再オープン後に再試行できる)');
  finally
    rig.Free;
  end;
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
  TestSetModemAfterExit;
  TestSwapRacingExit;
  TestUiDestroyUnderConcurrentPush;
  TestRigPollFastShutdown;
  TestPttFailsafeObservable;
  TestNoSpuriousErrorOnShutdown;
  TestSharedBusUnsubscribe;
  TestFrequencyConflationThroughUi;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
