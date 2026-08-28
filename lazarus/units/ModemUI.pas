{ ============================================================================
  ModemUI.pas

  fldigi の GUI 連携部分 ― qrunner (src/include/qrunner.h) と
  REQ()/REQ_SYNC() マクロ、および fl_digi.cxx が提供する
  put_freq() / put_rx_char() / put_Status1() / callback_set_metric() 等の
  グローバル関数群 ― を Lazarus/FPC (LCL) 向けに移植した
  「モデムエンジン ⇔ GUI」ブリッジクラス。

  設計方針 (fldigi との対応):
  ----------------------------------------------------------------------------
  1. スレッド境界の越え方
     fldigi: 音声処理スレッド (TRX_TID) から GUI 更新を行いたいときは
       REQ(put_freq, frequency);
     のように qrunner のキューへ「関数 + 引数」を積み、メインスレッドの
     Fl::awake() タイミングで実行させる (FLTK の仕組み)。
     Lazarus/LCL では同じ役割を TThread.Queue / TThread.Synchronize が
     担う。本ユニットの TModemUI は、TCustomModem / TModemEngine が
     発火するイベント (別スレッドから呼ばれる可能性がある) を受け取り、
     TThread.Queue で「安全にメインスレッド上のコールバックとして
     再発火」する。

  2. put_rx_char() 相当
     fldigi は復調された文字を1文字ずつ put_rx_char() で受信ログ
     ウィジェット (FTextRXTX, include/FTextRXTX.h) に追加する。
     本移植版では TModemUI.OnRxChar (Synchronize 経由で呼ばれる)
     として同じ役割を提供する。実際の LCL コンポーネント (TMemo 等)
     への書き込みはアプリ側 (フォームの OnRxChar ハンドラ) で行う。
     ※ Memo 等 LCL の具象コンポーネントへの依存はこのユニットに
       持ち込まず、コールバック注入にとどめることで
       lcl-nogui 環境でも単体テスト可能な設計にしている。

  3. get_tx_char() 相当
     fldigi は送信バッファ (macro等で積まれた文字列) から
     get_tx_char() で1文字ずつ取り出す。本移植版では
     TModemUI.OnTxChar (エンジンスレッド側から直接呼ばれる、
     GUIに触れない純粋関数) として提供する。

  4. put_freq / callback_set_metric / put_Status1 相当
     いずれも「値の変化を GUI に伝える」広義の通知イベントであり、
     TModemUI.OnFrequencyChanged / OnMetricChanged / OnStatusText として
     まとめて扱う。すべて Queue 経由でメインスレッドから呼ばれることを
     保証する。
  ============================================================================ }
unit ModemUI;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Modem, ModemEngine, ModemTypes;

type
  TModemUI = class;

  { GUI 側 (フォーム) が実装するコールバック群。
    いずれも「メインスレッド上で」安全に呼び出されることが保証される。 }
  TUIFrequencyEvent = procedure(Sender: TModemUI; AFrequency: Double) of object;
  TUIMetricEvent = procedure(Sender: TModemUI; AMetric: Double) of object;
  TUIStatusEvent = procedure(Sender: TModemUI; const AText: string) of object;
  TUIRxCharEvent = procedure(Sender: TModemUI; ACh: Integer) of object;
  TUIStateEvent = procedure(Sender: TModemUI; AState: TTrxState) of object;
  TUIErrorEvent = procedure(Sender: TModemUI; const AMsg: string) of object;

  { fldigi: get_tx_char() 相当。GUI に触れず送信バッファから
    1文字返すだけの純粋な処理として、エンジンスレッドから直接呼ばれる
    (Queueを介さない = 低遅延)。 }
  TUIGetTxCharFunc = function(Sender: TModemUI): Integer of object;

  { TModemUI
    ---------------------------------------------------------------------
    fldigi: qrunner + fl_digi.cxx のグローバル put_*/callback_* 関数群を
    1つのオブジェクトに集約したもの。
    - TCustomModem / TModemEngine のイベントを購読する (Attach)
    - ワーカースレッドから呼ばれたイベントを TThread.Queue で
      メインスレッドに転送し、フォーム側コールバックを呼ぶ }
  TModemUI = class
  private
    FModem: TCustomModem;
    FEngine: TModemEngine;

    FOnFrequencyChanged: TUIFrequencyEvent;
    FOnMetricChanged: TUIMetricEvent;
    FOnStatusText: TUIStatusEvent;
    FOnRxChar: TUIRxCharEvent;
    FOnStateChanged: TUIStateEvent;
    FOnError: TUIErrorEvent;
    FOnGetTxChar: TUIGetTxCharFunc;

    // --- TModem/TModemEngine から呼ばれるハンドラ (呼び出しスレッド不定) ---
    procedure ModemFrequencyChanged(Sender: TCustomModem; AFrequency: Double);
    procedure ModemMetricChanged(Sender: TCustomModem; AMetric: Double);
    procedure ModemStatusText(Sender: TCustomModem; const AText: string);
    procedure ModemPutRxChar(Sender: TCustomModem; ACh: Integer);
    function ModemGetTxChar(Sender: TCustomModem): Integer;
    procedure EngineStateChanged(Sender: TModemEngine; AState: TTrxState);
    procedure EngineError(Sender: TModemEngine; const AMsg: string);

    // --- TThread.Queue に渡す「メインスレッドで実行される」中継関数 ---
    // FPC の TThread.Queue は引数なし手続きしか積めないため、
    // 直近の値を一時変数に保持してから Queue する定石パターンを用いる。
    procedure QueuedFrequencyChanged;
    procedure QueuedMetricChanged;
    procedure QueuedStatusText;
    procedure QueuedRxChar;
    procedure QueuedStateChanged;
    procedure QueuedError;

  private
    // Queue 経由で受け渡すための一時バッファ (スレッドをまたぐ単純代入のみ)
    FPendingFrequency: Double;
    FPendingMetric: Double;
    FPendingStatus: string;
    FPendingRxChar: Integer;
    FPendingState: TTrxState;
    FPendingErrorMsg: string;
  public
    constructor Create;
    destructor Destroy; override;

    { モデム/エンジンを購読対象として登録する。
      fldigi でいう「active_modem に対して各種フックを仕込む」処理。 }
    procedure AttachModem(AModem: TCustomModem);
    procedure AttachEngine(AEngine: TModemEngine);
    procedure DetachModem;
    procedure DetachEngine;

    property Modem: TCustomModem read FModem;
    property Engine: TModemEngine read FEngine;

    { フォーム側が購読するイベント (すべてメインスレッドで発火) }
    property OnFrequencyChanged: TUIFrequencyEvent read FOnFrequencyChanged write FOnFrequencyChanged;
    property OnMetricChanged: TUIMetricEvent read FOnMetricChanged write FOnMetricChanged;
    property OnStatusText: TUIStatusEvent read FOnStatusText write FOnStatusText;
    property OnRxChar: TUIRxCharEvent read FOnRxChar write FOnRxChar;
    property OnStateChanged: TUIStateEvent read FOnStateChanged write FOnStateChanged;
    property OnError: TUIErrorEvent read FOnError write FOnError;

    { フォーム側が「送信キューから次の文字を返す」処理を実装するための
      フック。fldigi: get_tx_char() の実装先 (main.cxx 側) に相当。
      ※ これはワーカースレッドから直接呼ばれるため、
        LCL コンポーネントに直接触れる実装をしてはならない
        (スレッドセーフなバッファ/キューを介すこと)。 }
    property OnGetTxChar: TUIGetTxCharFunc read FOnGetTxChar write FOnGetTxChar;
  end;

implementation

{ TModemUI }

constructor TModemUI.Create;
begin
  inherited Create;
  FModem := nil;
  FEngine := nil;
end;

destructor TModemUI.Destroy;
begin
  DetachModem;
  DetachEngine;
  inherited Destroy;
end;

procedure TModemUI.AttachModem(AModem: TCustomModem);
begin
  DetachModem;
  FModem := AModem;
  if Assigned(FModem) then
  begin
    FModem.OnFrequencyChanged := @ModemFrequencyChanged;
    FModem.OnMetricChanged := @ModemMetricChanged;
    FModem.OnStatusText := @ModemStatusText;
    FModem.OnPutRxChar := @ModemPutRxChar;
    FModem.OnGetTxChar := @ModemGetTxChar;
  end;
end;

procedure TModemUI.DetachModem;
begin
  if Assigned(FModem) then
  begin
    FModem.OnFrequencyChanged := nil;
    FModem.OnMetricChanged := nil;
    FModem.OnStatusText := nil;
    FModem.OnPutRxChar := nil;
    FModem.OnGetTxChar := nil;
    FModem := nil;
  end;
end;

procedure TModemUI.AttachEngine(AEngine: TModemEngine);
begin
  DetachEngine;
  FEngine := AEngine;
  if Assigned(FEngine) then
  begin
    FEngine.OnStateChanged := @EngineStateChanged;
    FEngine.OnError := @EngineError;
  end;
end;

procedure TModemUI.DetachEngine;
begin
  if Assigned(FEngine) then
  begin
    FEngine.OnStateChanged := nil;
    FEngine.OnError := nil;
    FEngine := nil;
  end;
end;

{ ---- TCustomModem 側イベント (エンジンスレッドから呼ばれ得る) ---- }

procedure TModemUI.ModemFrequencyChanged(Sender: TCustomModem; AFrequency: Double);
begin
  // fldigi: REQ(put_freq, frequency);
  FPendingFrequency := AFrequency;
  TThread.Queue(nil, @QueuedFrequencyChanged);
end;

procedure TModemUI.ModemMetricChanged(Sender: TCustomModem; AMetric: Double);
begin
  // fldigi: REQ(callback_set_metric, m);
  FPendingMetric := AMetric;
  TThread.Queue(nil, @QueuedMetricChanged);
end;

procedure TModemUI.ModemStatusText(Sender: TCustomModem; const AText: string);
begin
  // fldigi: put_Status1(msg) / put_MODEstatus(...)
  FPendingStatus := AText;
  TThread.Queue(nil, @QueuedStatusText);
end;

procedure TModemUI.ModemPutRxChar(Sender: TCustomModem; ACh: Integer);
begin
  // fldigi: put_rx_char(c) -- 復調文字を受信ウィンドウへ
  FPendingRxChar := ACh;
  TThread.Queue(nil, @QueuedRxChar);
end;

function TModemUI.ModemGetTxChar(Sender: TCustomModem): Integer;
begin
  { fldigi: get_tx_char() は「今すぐ値が要る」同期呼び出しであり、
    キューイングすると送信タイミングが崩れる。そのため、
    OnGetTxChar はスレッドセーフな実装であることを呼び出し元
    (フォーム) に要求した上で、直接呼び出す (Queueしない)。 }
  if Assigned(FOnGetTxChar) then
    Result := FOnGetTxChar(Self)
  else
    Result := MODEM_TX_CHAR_ETX;
end;

procedure TModemUI.EngineStateChanged(Sender: TModemEngine; AState: TTrxState);
begin
  FPendingState := AState;
  TThread.Queue(nil, @QueuedStateChanged);
end;

procedure TModemUI.EngineError(Sender: TModemEngine; const AMsg: string);
begin
  FPendingErrorMsg := AMsg;
  TThread.Queue(nil, @QueuedError);
end;

{ ---- Queue 経由でメインスレッド上で実行される中継処理 ---- }

procedure TModemUI.QueuedFrequencyChanged;
begin
  if Assigned(FOnFrequencyChanged) then
    FOnFrequencyChanged(Self, FPendingFrequency);
end;

procedure TModemUI.QueuedMetricChanged;
begin
  if Assigned(FOnMetricChanged) then
    FOnMetricChanged(Self, FPendingMetric);
end;

procedure TModemUI.QueuedStatusText;
begin
  if Assigned(FOnStatusText) then
    FOnStatusText(Self, FPendingStatus);
end;

procedure TModemUI.QueuedRxChar;
begin
  if Assigned(FOnRxChar) then
    FOnRxChar(Self, FPendingRxChar);
end;

procedure TModemUI.QueuedStateChanged;
begin
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FPendingState);
end;

procedure TModemUI.QueuedError;
begin
  if Assigned(FOnError) then
    FOnError(Self, FPendingErrorMsg);
end;

end.
