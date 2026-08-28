{ ============================================================================
  RigPollThread.pas

  fldigi の src/rigcontrol/hamlib.cxx の hamlib_loop() (50ms周期で
  無線機の周波数/モードをポーリングし、変化があれば GUI に通知する
  専用スレッド) を Lazarus/FPC 向けに移植した「リグ状態監視エンジン」。

  設計方針 (fldigi との対応):
  ----------------------------------------------------------------------------
  - fldigi の hamlib_loop() は 50ms sleep のループの中で、
    valHamRigPollrate (既定値) 周期ごとに rig_get_freq/rig_get_mode を
    呼び、値が変化していれば show_frequency()/show_mode() 等で GUI を
    更新する。TRigPollThread (TThread 派生) がこれに相当する。

  - hamlib_bypass (PTT送信中は周波数取得をスキップするフラグ) も
    Bypass プロパティとして再現している (送信中に CAT ポーリングが
    輻輳してタイムアウトするのを防ぐため)。

  - GUI との通信は一切行わない。OnFreqChanged/OnModeChanged/OnError は
    ワーカースレッドから直接発火されるため、フォームなど LCL 側で
    購読する場合は ModemUI.pas と同様に TThread.Queue でラップすること
    (本ユニットはそこまで面倒を見ない。関心の分離)。

  - TCustomRigControl (RigControlIntf.pas) にのみ依存するため、
    THamlibRigControl 以外の将来実装 (rigctld版等) でもそのまま使える。
  ============================================================================ }
unit RigPollThread;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, RigControlIntf;

type
  TRigPollThread = class;

  TRigFreqEvent = procedure(Sender: TRigPollThread; FreqHz: Double) of object;
  TRigModeEvent = procedure(Sender: TRigPollThread; const Mode: string;
    Width: Integer) of object;
  TRigPollErrorEvent = procedure(Sender: TRigPollThread; const Msg: string) of object;

  { TRigPollThread
    ---------------------------------------------------------------------
    fldigi: hamlib.cxx の hamlib_loop() (static void *hamlib_loop(void*)) }
  TRigPollThread = class(TThread)
  private
    FRig: TCustomRigControl;
    FLock: TCriticalSection;
    FPollIntervalMs: Integer;
    FBypass: Boolean;           // fldigi: hamlib_bypass (PTT送信中は監視休止)
    FNeedFreq: Boolean;
    FNeedMode: Boolean;
    FLastFreq: Double;
    FLastMode: string;
    FLastWidth: Integer;

    FOnFreqChanged: TRigFreqEvent;
    FOnModeChanged: TRigModeEvent;
    FOnError: TRigPollErrorEvent;

    function GetBypass: Boolean;
    procedure SetBypass(AValue: Boolean);
    procedure DoFreqChanged(F: Double);
    procedure DoModeChanged(const M: string; W: Integer);
    procedure DoError(const Msg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ARig: TCustomRigControl);
    destructor Destroy; override;

    { fldigi: hamlib_bypass = ptt ? true : false;
      PTT送信中はポーリングを止める場合に true にする
      (輻輳によるCATタイムアウトを避けるため)。 }
    property Bypass: Boolean read GetBypass write SetBypass;

    { fldigi: valHamRigPollrate->value() (ミリ秒単位) }
    property PollIntervalMs: Integer read FPollIntervalMs write FPollIntervalMs;

    property OnFreqChanged: TRigFreqEvent read FOnFreqChanged write FOnFreqChanged;
    property OnModeChanged: TRigModeEvent read FOnModeChanged write FOnModeChanged;
    property OnError: TRigPollErrorEvent read FOnError write FOnError;
  end;

implementation

constructor TRigPollThread.Create(ARig: TCustomRigControl);
begin
  inherited Create(True); // suspended
  FreeOnTerminate := False;
  FRig := ARig;
  FLock := TCriticalSection.Create;
  FPollIntervalMs := 250; // fldigi 既定に近い値
  FBypass := False;
  FNeedFreq := True;
  FNeedMode := True;
  FLastFreq := 0;
  FLastMode := '';
  FLastWidth := 0;
end;

destructor TRigPollThread.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TRigPollThread.GetBypass: Boolean;
begin
  FLock.Enter;
  try
    Result := FBypass;
  finally
    FLock.Leave;
  end;
end;

procedure TRigPollThread.SetBypass(AValue: Boolean);
begin
  FLock.Enter;
  try
    FBypass := AValue;
  finally
    FLock.Leave;
  end;
end;

procedure TRigPollThread.DoFreqChanged(F: Double);
begin
  if Assigned(FOnFreqChanged) then
    FOnFreqChanged(Self, F);
end;

procedure TRigPollThread.DoModeChanged(const M: string; W: Integer);
begin
  if Assigned(FOnModeChanged) then
    FOnModeChanged(Self, M, W);
end;

procedure TRigPollThread.DoError(const Msg: string);
begin
  if Assigned(FOnError) then
    FOnError(Self, Msg);
end;

procedure TRigPollThread.Execute;
var
  f: Double;
  m: string;
  w: Integer;
  intervalMs: Integer;
begin
  // fldigi: hamlib_loop() 冒頭で canGetFreq()/canGetMode() 相当を判定
  FNeedFreq := Assigned(FRig) and FRig.CanGetFreq;
  FNeedMode := Assigned(FRig) and FRig.CanGetMode;

  while not Terminated do
  begin
    intervalMs := FPollIntervalMs;
    if intervalMs < 10 then intervalMs := 10;
    Sleep(intervalMs);

    if Terminated then Break;
    if (FRig = nil) or not FRig.IsOnLine then Continue;
    if GetBypass then Continue; // fldigi: if (hamlib_bypass) continue;

    if FNeedFreq then
    begin
      try
        f := FRig.GetFreq;
        if (f <> 0) and (f <> FLastFreq) then
        begin
          FLastFreq := f;
          DoFreqChanged(f);
        end;
      except
        on E: Exception do
          DoError('周波数取得エラー: ' + E.Message);
      end;
    end;

    if Terminated then Break;
    if GetBypass then Continue;

    if FNeedMode then
    begin
      try
        m := FRig.GetMode(w);
        if (m <> '') and ((m <> FLastMode) or (w <> FLastWidth)) then
        begin
          FLastMode := m;
          FLastWidth := w;
          DoModeChanged(m, w);
        end;
      except
        on E: Exception do
          DoError('モード取得エラー: ' + E.Message);
      end;
    end;
  end;
end;

end.
