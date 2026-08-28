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

    function GetState: TTrxState;
    procedure SetRequestedState(AValue: TTrxState);
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

    property State: TTrxState read GetState;
    property ActiveModem: TCustomModem read FActiveModem;

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
  FRxSound := ARxSound;
  FTxSound := ATxSound;
  FActiveModem := nil;
  FState := tsPause;
  FRequestedState := tsPause;
end;

destructor TModemEngine.Destroy;
begin
  FLock.Free;
  inherited Destroy;
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
begin
  // fldigi: trx_start_modem() は mutex を取って active_modem を
  // 置き換えた後 restart()/init() 系を呼び出す。
  FLock.Enter;
  try
    FActiveModem := AModem;
    if Assigned(FActiveModem) then
    begin
      FActiveModem.Init;
      FActiveModem.RxInit;
    end;
  finally
    FLock.Leave;
  end;
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
begin
  SetRequestedState(tsExit);
  Terminate;
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
  if (FActiveModem = nil) or (FRxSound = nil) then
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
var
  CurState: TTrxState;
begin
  while not Terminated do
  begin
    FLock.Enter;
    try
      // fldigi: while (trx_state != s_) trx_wait_state(); のポーリングに相当。
      // 要求があれば実行中の状態を更新する。
      if FRequestedState <> FState then
      begin
        FState := FRequestedState;
        CurState := FState;
        FLock.Leave;
        DoStateChanged(CurState);
      end
      else
      begin
        CurState := FState;
        FLock.Leave;
      end;
    except
      FLock.Leave;
      raise;
    end;

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
      tsExit:     Terminate;
      tsPause, tsNoop, tsIdle, tsEnded, tsAbort, tsFlush, tsNewModem:
        Sleep(10);
    end;
  end;
end;

end.
