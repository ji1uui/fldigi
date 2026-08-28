{ ============================================================================
  UnitMainForm.pas

  fldigi の fl_digi.cxx (メインウィンドウ + Digiscope + 受信テキスト表示 +
  ステータスバー) を Lazarus/LCL 向けに移植した、実際にモデムを
  操作するメインフォームの実装例。

  対応関係:
    fldigi (FLTK)                          Lazarus (LCL)
    ------------------------------------   -------------------------------
    FTextRXTX (受信/送信テキスト表示)       Memo_Rx / Memo_Tx (TMemo)
    put_freq() で更新される周波数表示        Label_Freq (TLabel)
    Digiscope (信号品質スコープ)             ProgressBar_Metric (簡易代用)
    put_Status1/2 (ステータスバー)           StatusBar1 (TStatusBar)
    Op_Mode コンボボックス (モード選択)      ComboBox_Mode (TComboBox)
    [T/R] 送受信切替ボタン                   Button_TxRx

  実装のポイント:
    - フォームは TModemUI が発火するイベント (OnFrequencyChanged 等) を
      購読するだけで、TCustomModem や TModemEngine を直接触らない
      (= UIコードがスレッドを意識しなくてよい設計)。
    - 送信バッファは TStringList で保持し、OnGetTxChar から
      スレッドセーフに1文字ずつ取り出す (Lock で保護)。
  ============================================================================ }
unit UnitMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Dialogs,
  SoundIntf, ModemTypes, Modem, ModemEngine, ModemUI, NullModemImpl;

type

  { TMainForm }

  TMainForm = class(TForm)
  private
    // --- LCL コンポーネント (実行時に CreateComponents で生成) ---
    Label_Freq: TLabel;
    Memo_Rx: TMemo;
    Edit_Tx: TEdit;
    Button_Send: TButton;
    Button_StartStop: TButton;
    ProgressBar_Metric: TProgressBar;
    StatusBar1: TStatusBar;

    // --- モデム層 ---
    FSound: TCustomSoundDevice;
    FModem: TCustomModem;
    FEngine: TModemEngine;
    FUI: TModemUI;

    // --- 送信バッファ (スレッド間共有のためロック必須) ---
    FTxLock: TCriticalSection;
    FTxBuffer: string;
    FTxPos: Integer;

    procedure CreateComponents;

    // TModemUI からのコールバック (すべてメインスレッドで実行される)
    procedure HandleFrequencyChanged(Sender: TModemUI; AFrequency: Double);
    procedure HandleMetricChanged(Sender: TModemUI; AMetric: Double);
    procedure HandleStatusText(Sender: TModemUI; const AText: string);
    procedure HandleRxChar(Sender: TModemUI; ACh: Integer);
    procedure HandleStateChanged(Sender: TModemUI; AState: TTrxState);
    procedure HandleError(Sender: TModemUI; const AMsg: string);

    // TModemUI から呼ばれる送信文字供給関数 (ワーカースレッドから直接呼ばれる!)
    function HandleGetTxChar(Sender: TModemUI): Integer;

    procedure Button_SendClick(Sender: TObject);
    procedure Button_StartStopClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

{ TMainForm }

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Lazarus fldigi-style Modem Demo';
  Width := 480;
  Height := 360;

  CreateComponents;

  FTxLock := TCriticalSection.Create;
  FTxBuffer := '';
  FTxPos := 1;

  // --- fldigi: RXscard/TXscard に相当するサウンドデバイス ---
  // 実運用では TPortAudioSoundDevice 等、実デバイスに接続する
  // 派生クラスをここで生成する。デモでは無音の TNullSoundDevice を使用。
  FSound := TNullSoundDevice.Create;
  FSound.Open(sdRead, 8000);

  // --- fldigi: active_modem = new NULLMODEM(); に相当 ---
  FModem := TNullModem.Create(FSound);

  // --- fldigi: trx_start() (送受信スレッド起動) に相当 ---
  FEngine := TModemEngine.Create(FSound, FSound);
  FEngine.SetModem(FModem);

  // --- fldigi: qrunner 経由の GUI 連携ブリッジ ---
  FUI := TModemUI.Create;
  FUI.OnFrequencyChanged := @HandleFrequencyChanged;
  FUI.OnMetricChanged := @HandleMetricChanged;
  FUI.OnStatusText := @HandleStatusText;
  FUI.OnRxChar := @HandleRxChar;
  FUI.OnStateChanged := @HandleStateChanged;
  FUI.OnError := @HandleError;
  FUI.OnGetTxChar := @HandleGetTxChar;
  FUI.AttachModem(FModem);
  FUI.AttachEngine(FEngine);

  FEngine.Start;
  FEngine.RequestReceive;
end;

destructor TMainForm.Destroy;
begin
  if Assigned(FEngine) then
  begin
    FEngine.RequestExit;
    FEngine.WaitFor;
    FEngine.Free;
  end;
  FUI.Free;
  FModem.Free;
  FSound.Free;
  FTxLock.Free;
  inherited Destroy;
end;

procedure TMainForm.CreateComponents;
begin
  Label_Freq := TLabel.Create(Self);
  Label_Freq.Parent := Self;
  Label_Freq.SetBounds(8, 8, 200, 20);
  Label_Freq.Caption := 'Freq: ---- Hz';

  ProgressBar_Metric := TProgressBar.Create(Self);
  ProgressBar_Metric.Parent := Self;
  ProgressBar_Metric.SetBounds(220, 8, 240, 20);
  ProgressBar_Metric.Min := 0;
  ProgressBar_Metric.Max := 100;

  Memo_Rx := TMemo.Create(Self);
  Memo_Rx.Parent := Self;
  Memo_Rx.SetBounds(8, 36, 452, 220);
  Memo_Rx.ScrollBars := ssVertical;
  Memo_Rx.ReadOnly := True;

  Edit_Tx := TEdit.Create(Self);
  Edit_Tx.Parent := Self;
  Edit_Tx.SetBounds(8, 264, 340, 24);

  Button_Send := TButton.Create(Self);
  Button_Send.Parent := Self;
  Button_Send.SetBounds(352, 264, 108, 24);
  Button_Send.Caption := 'Send (TX)';
  Button_Send.OnClick := @Button_SendClick;

  Button_StartStop := TButton.Create(Self);
  Button_StartStop.Parent := Self;
  Button_StartStop.SetBounds(8, 296, 120, 24);
  Button_StartStop.Caption := 'RX <-> TX';
  Button_StartStop.OnClick := @Button_StartStopClick;

  StatusBar1 := TStatusBar.Create(Self);
  StatusBar1.Parent := Self;
  StatusBar1.SimpleText := 'READY';
end;

{ ---- TModemUI コールバック (fldigi の put_freq/put_Status1 等に相当) ---- }

procedure TMainForm.HandleFrequencyChanged(Sender: TModemUI; AFrequency: Double);
begin
  // fldigi: put_freq(double frequency) の GUI更新部分に相当
  Label_Freq.Caption := Format('Freq: %.0f Hz', [AFrequency]);
end;

procedure TMainForm.HandleMetricChanged(Sender: TModemUI; AMetric: Double);
begin
  // fldigi: callback_set_metric(double metric) に相当 (Digiscopeメータ更新)
  if AMetric < 0 then AMetric := 0;
  if AMetric > 100 then AMetric := 100;
  ProgressBar_Metric.Position := Round(AMetric);
end;

procedure TMainForm.HandleStatusText(Sender: TModemUI; const AText: string);
begin
  // fldigi: put_Status1() / put_MODEstatus() に相当
  StatusBar1.SimpleText := AText;
end;

procedure TMainForm.HandleRxChar(Sender: TModemUI; ACh: Integer);
begin
  // fldigi: put_rx_char(unsigned int data) に相当。
  // 受信復調された1文字をテキスト表示に追記する。
  if (ACh >= 32) and (ACh < 127) then
    Memo_Rx.Text := Memo_Rx.Text + Chr(ACh)
  else if ACh = 10 then
    Memo_Rx.Lines.Add('');
end;

procedure TMainForm.HandleStateChanged(Sender: TModemUI; AState: TTrxState);
begin
  case AState of
    tsReceive:  StatusBar1.SimpleText := 'RX (受信中)';
    tsTransmit: StatusBar1.SimpleText := 'TX (送信中)';
    tsTune:     StatusBar1.SimpleText := 'TUNE';
  else
    StatusBar1.SimpleText := 'STATE=' + IntToStr(Ord(AState));
  end;
end;

procedure TMainForm.HandleError(Sender: TModemUI; const AMsg: string);
begin
  StatusBar1.SimpleText := 'ERROR: ' + AMsg;
end;

function TMainForm.HandleGetTxChar(Sender: TModemUI): Integer;
begin
  { fldigi: get_tx_char() 実装 (main.cxx 側) に相当。
    ★重要★ この関数はワーカースレッド (TModemEngine) から直接
    呼ばれるため、TMemo/TEdit など LCL コンポーネントに絶対に
    触れてはならない。文字列バッファへのアクセスは必ず
    クリティカルセクションで保護すること。 }
  FTxLock.Enter;
  try
    if FTxPos <= Length(FTxBuffer) then
    begin
      Result := Ord(FTxBuffer[FTxPos]);
      Inc(FTxPos);
    end
    else
      Result := MODEM_TX_CHAR_ETX;
  finally
    FTxLock.Leave;
  end;
end;

procedure TMainForm.Button_SendClick(Sender: TObject);
begin
  // fldigi: 送信ボタン押下 → 送信バッファへ文字列を積み、TX状態へ遷移
  FTxLock.Enter;
  try
    FTxBuffer := Edit_Tx.Text + #13#10;
    FTxPos := 1;
  finally
    FTxLock.Leave;
  end;
  Edit_Tx.Clear;
  FEngine.RequestTransmit;
end;

procedure TMainForm.Button_StartStopClick(Sender: TObject);
begin
  if FEngine.State = tsTransmit then
    FEngine.RequestReceive
  else
    FEngine.RequestTransmit;
end;

end.
