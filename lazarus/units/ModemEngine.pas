{ ============================================================================
  ModemEngine.pas

  fldigi の src/trx/trx.cxx (trx_start, trx_receive, trx_transmit,
  trx_state 状態機械 + 専用スレッド) を Lazarus/FPC 向けに移植した
  「送受信駆動エンジン」。

  設計方針 (fldigi との対応):
  ----------------------------------------------------------------------------
  - fldigi は trx.cxx の中で 1本のバックグラウンドスレッド (TRX_TID) を持ち、
    trx_state (STATE_RX/STATE_TX/STATE_TUNE/...) に応じて
    trx_receive_loop() / trx_transmit_loop() を回し続ける。
    本移植版では TModemEngine (TThread 派生) がこれに相当し、
    FState (TTrxState) を見て RxLoopStep / TxLoopStep を繰り返し呼ぶ。

  - fldigi はモデム差し替え時に trx_start_modem(modem*, freq) を呼び、
    ミューテックス等を介して安全に active_modem を切り替える。
    本移植版では SetModem() が同様に「実行中スレッドを一時停止し、
    アクティブモデムを入れ替えてから再開する」処理を行う。

  - オーディオIOは TCustomSoundDevice (SoundIntf.pas) を通して行う。
    fldigi の RXscard->Read() / TXscard->Write() に相当する処理を
    RxLoopStep / TxLoopStep 内で呼び出す。

  - GUI との通信は一切行わない。GUI 連携は ModemUI.pas の TModemUI が
    このクラスが発火するイベントを Synchronize/Queue でラップして行う。
    (関心の分離: エンジン=DSP駆動, UI=表示・スレッド越え通知)
  ============================================================================ }
unit ModemEngine;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, SoundIntf, ModemTypes, Modem;

const
  { fldigi: SCBLOCKSIZE (sound.h) -- 1回のRead/Writeで扱うサンプル数 }
  MODEM_BLOCK_SIZE = 512;

type
  TModemEngine = class;

  { fldigi: state_t の変化を GUI 層に伝える (put_MODEstatus 等) ためのイベント }
  TEngineStateEvent = procedure(Sender: TModemEngine; AState: TTrxState) of object;
  TEngineErrorEvent = procedure(Sender: TModemEngine; const AMsg: string) of object;

  { TModemEngine
    ---------------------------------------------------------------------
    fldigi: trx.cxx のスレッド本体 (trx_start～trx_receive_loop/
    trx_transmit_loop) に相当。
    「今どのモデムがアクティブか」「今 RX/TX/TUNE のどれか」を
    自分自身の状態として保持し、専用スレッドで駆動する。 }
  { エンジン操作のエラー (モデム差し替えのタイムアウト等)。 }
  EModemEngineError = class(Exception);

  TModemEngine = class(TThread)
  private
    FLock: TCriticalSection;
    FState: TTrxState;               // fldigi: state_t trx_state
    FRequestedState: TTrxState;      // 次に遷移すべき状態 (スレッド間受け渡し用)
    FActiveModem: TCustomModem;      // fldigi: modem *active_modem
    FRxSound: TCustomSoundDevice;    // fldigi: SoundBase *RXscard
    FTxSound: TCustomSoundDevice;    // fldigi: SoundBase *TXscard
    FRxBuf: array[0..MODEM_BLOCK_SIZE-1] of Double;

    FOnStateChanged: TEngineStateEvent;
    FOnError: TEngineErrorEvent;

    { --- ENG-02: モデム差し替えをワーカースレッド専有にするための状態 ---
      FActiveModem を外部スレッドから書き換えると、RX/TX 処理中の
      読み取りと競合して解放済みモデムを触りうる (UAF)。そこで
      「差し替えは要求としてキューに置き、実際の入れ替えはワーカー自身が
      処理の切れ目で行う」方式にする。SetModem は入れ替え完了まで待つので、
      呼び出し側は SetModem から戻った時点で旧モデムを安全に解放できる。 }
    FPendingModem: TCustomModem;
    FModemChangeRequested: Boolean;
    FModemChangeDone: TSimpleEvent;

    FStarted: Boolean;        // Start が呼ばれたか (WaitFor 可否の判定用)
    FExiting: Boolean;        // RequestExit 済み (冪等化のため)

    function GetState: TTrxState;
    function GetActiveModem: TCustomModem;
    procedure SetRequestedState(AValue: TTrxState);
    { ワーカースレッド内で保留中の差し替えを適用する (ENG-02)。 }
    procedure ApplyPendingModemChange;
    { ブロッキング中の音声入出力を解除する (ENG-04)。 }
    procedure AbortBlockingIo;
    procedure SetStateAndNotify(ANewState: TTrxState);
  protected
    procedure Execute; override;

    { fldigi: trx_receive_loop() 相当。RXscard から1ブロック読み、
      active_modem->rx_process() に渡す。 }
    procedure RxLoopStep;

    { fldigi: trx_transmit_loop() 相当。active_modem->tx_process() を
      呼び、内部で TXscard へ書き込ませる。戻り値<0で送信完了。 }
    procedure TxLoopStep;

    { fldigi: trx_tune_loop() 相当。単一トーン送出等のチューニングモード }
    procedure TuneLoopStep;

    procedure DoStateChanged(ANewState: TTrxState);
    procedure DoError(const AMsg: string);
  public
    constructor Create(ARxSound, ATxSound: TCustomSoundDevice);
    destructor Destroy; override;

    { fldigi: void trx_start_modem(modem* m, int f = 0);
      アクティブモデムを安全に差し替える。エンジンが動作中でも呼べる。 }
    procedure SetModem(AModem: TCustomModem);

    { fldigi: void trx_receive(void); -- STATE_RX への遷移要求 }
    procedure RequestReceive;
    { fldigi: void trx_transmit(void); -- STATE_TX への遷移要求 }
    procedure RequestTransmit;
    { fldigi: void trx_tune(void); -- STATE_TUNE への遷移要求 }
    procedure RequestTune;
    { fldigi: void trx_reset(void); -- STATE_RESTART への遷移要求 }
    procedure RequestRestart;
    { エンジンスレッドの終了要求 (fldigi: trx_close()) }
    procedure RequestExit;

    { Start を記録して WaitFor の可否を判定できるようにする
      (TThread.Start は virtual ではないため reintroduce する)。 }
    procedure Start; reintroduce;

    property State: TTrxState read GetState;
    property ActiveModem: TCustomModem read GetActiveModem;

    property OnStateChanged: TEngineStateEvent read FOnStateChanged write FOnStateChanged;
    property OnError: TEngineErrorEvent read FOnError write FOnError;
  end;

implementation

{ TModemEngine }

constructor TModemEngine.Create(ARxSound, ATxSound: TCustomSoundDevice);
begin
  inherited Create(True); // suspended
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FModemChangeDone := TSimpleEvent.Create;
  FRxSound := ARxSound;
  FTxSound := ATxSound;
  FActiveModem := nil;
  FPendingModem := nil;
  FModemChangeRequested := False;
  FStarted := False;
  FExiting := False;
  FState := tsPause;
  FRequestedState := tsPause;
end;

destructor TModemEngine.Destroy;
{ ENG-01: 以前は FLock.Free を先に行っていたため、まだ走っている
  ワーカースレッドが解放済みのクリティカルセクションを触りえた
  (inherited Destroy が Terminate/WaitFor を行うのは、その "後" である)。
  正しい順序は「終了要求 → ブロッキング解除 → スレッド停止を待つ →
  資源解放」なので、FLock の解放は inherited Destroy の後に移す。 }
begin
  RequestExit;        // 冪等。終了要求 + ブロッキングI/Oの解除 (ENG-04)
  inherited Destroy;  // ここで Terminate / Resume / WaitFor が行われる
  FModemChangeDone.Free;
  FLock.Free;         // スレッド停止が確定してから解放する
end;

procedure TModemEngine.Start;
begin
  FLock.Enter;
  try
    FStarted := True;
  finally
    FLock.Leave;
  end;
  inherited Start;
end;

function TModemEngine.GetState: TTrxState;
begin
  FLock.Enter;
  try
    Result := FState;
  finally
    FLock.Leave;
  end;
end;

function TModemEngine.GetActiveModem: TCustomModem;
begin
  FLock.Enter;
  try
    Result := FActiveModem;
  finally
    FLock.Leave;
  end;
end;

procedure TModemEngine.SetRequestedState(AValue: TTrxState);
begin
  FLock.Enter;
  try
    FRequestedState := AValue;
  finally
    FLock.Leave;
  end;
end;

procedure TModemEngine.SetModem(AModem: TCustomModem);
{ ENG-02: 以前はポインタ代入だけをロックしていたが、RX/TX 側は
  ロックなしで FActiveModem を読んでいたため、差し替えと処理が競合し
  解放済みモデムを触りうる状態だった (コメントの「一時停止して差し替える」
  とも実装が一致していなかった)。
  ここでは差し替えを "要求" として置き、実際の入れ替えはワーカー自身が
  処理の切れ目で行う。完了まで待ってから戻るので、呼び出し側は
  SetModem 復帰後に旧モデムを安全に解放できる。 }
const
  SWAP_TIMEOUT_MS = 5000;
var
  running: Boolean;
begin
  FLock.Enter;
  try
    running := FStarted and (not Finished) and (not Terminated);
    if not running then
    begin
      { スレッド未開始/停止済みなら競合相手がいないので直接適用する。 }
      FActiveModem := AModem;
      if Assigned(FActiveModem) then
      begin
        FActiveModem.Init;
        FActiveModem.RxInit;
      end;
      Exit;
    end;
    FPendingModem := AModem;
    FModemChangeRequested := True;
    FModemChangeDone.ResetEvent;
  finally
    FLock.Leave;
  end;

  { RX 1ブロック分の読み取りが終われば適用されるため、通常は数十msで完了する。
    応答が無い場合は黙って競合させるより、原因の分かる失敗にする。 }
  if FModemChangeDone.WaitFor(SWAP_TIMEOUT_MS) <> wrSignaled then
    raise EModemEngineError.Create(
      'モデムの差し替えがタイムアウトしました (エンジンが応答していません)');
end;

procedure TModemEngine.ApplyPendingModemChange;
{ ワーカースレッドからのみ呼ぶ。ここが FActiveModem を書き換える唯一の
  場所なので、RX/TX 側はロックなしで読んでよい。 }
var
  newModem: TCustomModem;
  changed: Boolean;
begin
  FLock.Enter;
  try
    changed := FModemChangeRequested;
    newModem := FPendingModem;
    if changed then
    begin
      FModemChangeRequested := False;
      FPendingModem := nil;
    end;
  finally
    FLock.Leave;
  end;
  if not changed then Exit;

  try
    FActiveModem := newModem;
    if Assigned(FActiveModem) then
    begin
      FActiveModem.Init;
      FActiveModem.RxInit;
    end;
  finally
    { 例外が起きても待機側を必ず解放する (デッドロック防止)。 }
    FModemChangeDone.SetEvent;
  end;
end;

procedure TModemEngine.AbortBlockingIo;
{ ENG-04: 終了要求は Terminate を立てるだけで、ブロッキング中の
  ReadSamples を解除していなかった。PortAudio のブロッキング読み取り中は
  WaitFor が戻らず、アプリが終了できない状態になる。 }
begin
  try
    if Assigned(FRxSound) then
      FRxSound.AbortIO;
  except
    on E: Exception do ; // 終了処理中の失敗は伝播させない
  end;
  try
    if Assigned(FTxSound) and (FTxSound <> FRxSound) then
      FTxSound.AbortIO;
  except
    on E: Exception do ;
  end;
end;

procedure TModemEngine.SetStateAndNotify(ANewState: TTrxState);
var
  changed: Boolean;
begin
  FLock.Enter;
  try
    changed := FState <> ANewState;
    if changed then
      FState := ANewState;
  finally
    FLock.Leave;
  end;
  { 通知はロック外で行う (購読側が本エンジンを呼び返してもデッドロックしない) }
  if changed then
    DoStateChanged(ANewState);
end;

procedure TModemEngine.RequestReceive;
begin
  SetRequestedState(tsReceive);
end;

procedure TModemEngine.RequestTransmit;
begin
  SetRequestedState(tsTransmit);
end;

procedure TModemEngine.RequestTune;
begin
  SetRequestedState(tsTune);
end;

procedure TModemEngine.RequestRestart;
begin
  SetRequestedState(tsRestart);
end;

procedure TModemEngine.RequestExit;
{ 冪等。何度呼んでも安全 (デストラクタからも呼ばれる)。 }
begin
  FLock.Enter;
  try
    FExiting := True;
    FRequestedState := tsExit;
  finally
    FLock.Leave;
  end;

  Terminate;
  AbortBlockingIo;   // ENG-04: ブロッキング中の読み取りを解除する

  { 差し替え完了を待っているスレッドがいたら解放する (終了時のデッドロック防止) }
  FModemChangeDone.SetEvent;
end;

procedure TModemEngine.DoStateChanged(ANewState: TTrxState);
begin
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, ANewState);
end;

procedure TModemEngine.DoError(const AMsg: string);
begin
  if Assigned(FOnError) then
    FOnError(Self, AMsg);
end;

procedure TModemEngine.RxLoopStep;
var
  NRead, Res: Integer;
begin
  { デバイスが未オープン/未設定のときは例外を投げずに待機する。
    そうしないと「まだ開いていない」という正常な過渡状態のたびに
    毎ループ例外が飛び、エラー通知が洪水になる。 }
  if (FActiveModem = nil) or (FRxSound = nil) or (not FRxSound.IsOpen) then
  begin
    Sleep(10);
    Exit;
  end;
  NRead := FRxSound.ReadSamples(FRxBuf, MODEM_BLOCK_SIZE);
  if NRead <= 0 then
  begin
    Sleep(1);
    Exit;
  end;
  try
    Res := FActiveModem.RxProcess(FRxBuf, NRead);
    if Res < 0 then
      DoError('rx_process returned error: ' + IntToStr(Res));
  except
    on E: Exception do
      DoError('RxProcess exception: ' + E.Message);
  end;
end;

procedure TModemEngine.TxLoopStep;
var
  Res: Integer;
begin
  if FActiveModem = nil then
  begin
    SetRequestedState(tsReceive);
    Exit;
  end;
  try
    Res := FActiveModem.TxProcess;
    if Res < 0 then
    begin
      // fldigi: tx_process() が -1 を返したら送信終了 -> 受信に戻る
      SetRequestedState(tsReceive);
    end;
  except
    on E: Exception do
    begin
      DoError('TxProcess exception: ' + E.Message);
      SetRequestedState(tsReceive);
    end;
  end;
end;

procedure TModemEngine.TuneLoopStep;
begin
  // fldigi: trx_tune_loop() は単一トーンを送出し続ける。
  // 具体的な波形生成はモデム/専用チューン処理に委譲するため、
  // ここでは簡略化して TxLoopStep と同様の駆動のみ行う。
  TxLoopStep;
end;

procedure TModemEngine.Execute;
{ ENG-04: 以前は `while not Terminated` を先に評価していたため、
  RequestExit が Terminate を立てた直後にループを抜け、tsExit への
  状態遷移通知が一度も発火しないことがあった。終了時の状態通知を
  finally で必ず行う構造にする。
  ENG-05: 例外がワーカースレッドを黙って終了させないよう、ループ本体を
  例外境界で囲み、原因を OnError で通知してから停止する。 }
var
  CurState: TTrxState;
  reqState: TTrxState;
  changed: Boolean;
begin
  try
    while not Terminated do
    begin
      { 差し替え要求はどの状態でも処理の切れ目で適用する (ENG-02) }
      ApplyPendingModemChange;

      FLock.Enter;
      try
        // fldigi: while (trx_state != s_) trx_wait_state(); のポーリングに相当。
        reqState := FRequestedState;
        changed := reqState <> FState;
        if changed then
          FState := reqState;
        CurState := FState;
      finally
        FLock.Leave;
      end;
      if changed then
        DoStateChanged(CurState);

      { 終了要求は状態を通知してから抜ける }
      if (CurState = tsExit) or Terminated then
        Break;

      try
        case CurState of
          tsReceive:  RxLoopStep;
          tsTransmit: TxLoopStep;
          tsTune:     TuneLoopStep;
          tsRestart:
            begin
              if Assigned(FActiveModem) then
                FActiveModem.Restart;
              SetRequestedState(tsReceive);
            end;
          tsExit:     Break;
          tsPause, tsNoop, tsIdle, tsEnded, tsAbort, tsFlush, tsNewModem:
            Sleep(10);
        end;
      except
        { 個々のステップで捕まえ切れなかった例外。スレッドを黙って
          終わらせず、原因を通知したうえで停止状態へ移す。 }
        on E: Exception do
        begin
          DoError('エンジンループで例外が発生しました: ' + E.Message);
          SetRequestedState(tsPause);
        end;
      end;
    end;
  finally
    { 終了経路がどれであっても tsExit を通知して終わる。
      通知先の例外でデストラクタ側の WaitFor を妨げない。 }
    try
      SetStateAndNotify(tsExit);
    except
      on E: Exception do ;
    end;
    { 差し替え待ちが残っていれば解放する }
    FModemChangeDone.SetEvent;
  end;
end;

end.
