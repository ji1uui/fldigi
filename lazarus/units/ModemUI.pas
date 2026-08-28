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
  Classes, SysUtils, SyncObjs, Modem, ModemEngine, ModemTypes;

type
  { FIFO に積むイベントの種別 (UI-01)。 }
  TUiEventKind = (uekRxChar, uekState, uekStatus, uekError);

  TUiEvent = record
    Kind: TUiEventKind;
    IntValue: Integer;   // uekRxChar: 文字コード / uekState: Ord(TTrxState)
    StrValue: string;    // uekStatus / uekError
  end;

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

    { --- UI-01/UI-02: スレッド安全な有界FIFO + 単一ドレイン方式 ---
      旧実装は各イベントが単一の FPending* を上書きしてから同じ無引数
      メソッドを Queue していた。復調文字のように短時間に複数届く値では、
      メインスレッドが取り出す前に後続の値で上書きされ、
      「前の文字が消え、後の文字が二重に届く」ことが起きていた。
      さらに string 型の FPending* はワーカー書込みと GUI 読取りが競合し、
      参照カウントを壊す危険もあった。

      対策として、順序と個数を保つ必要のあるイベント (RX文字/状態/
      ステータス/エラー) はロック付きFIFOへ積み、最新値だけでよい
      イベント (周波数/メトリック) は意図的に「最新1件」へ合流させる。
      Queue するのは DrainToUi 1種類だけで、しかも未処理の
      ドレインが無いときだけ積む (FDrainScheduled) ので、
      キューが膨張しない。 }
    procedure DrainToUi;
    procedure ScheduleDrain;

    { --- 破棄とワーカー呼び出しの競合を狭めるための在席カウンタ ---
      DetachModem/DetachEngine は「これ以降の呼び出し」を止めるだけで、
      既に中に入っている呼び出しは止められない。ワーカーが PushEvent の
      FLock.Enter で待っている最中に Destroy が FLock.Free をすると
      解放済みロックを掴むことになる (ENG-01 と同じ型の不具合)。
      そこで「今このオブジェクトのコールバック内にいるスレッド数」を
      ロックの外側で数え、Destroy はそれが 0 になるまで解放を待つ。
      カウンタ自体はロックで守れない (守るべきロックを解放する判断に
      使うため) ので、インターロック命令で操作する。

      【できることの限界】これが救うのは「Destroy に入った時点で既に
      中にいた呼び出し」だけである。Destroy が戻った後に始まる呼び出しは、
      オブジェクトのメモリ自体が解放済みなので何をしても救えない。
      したがって呼び出し側の責務は変わらない:
        エンジンのワーカースレッドを停止させてから TModemUI を破棄すること。
      在席カウンタはその順序を守った上での安全網である。 }
    function EnterCallback: Boolean;
    procedure LeaveCallback;

  private
    FLock: TCriticalSection;
    FQueue: array of TUiEvent;      // 有界FIFO (順序保持が必要なイベント)
    FQHead, FQCount: Integer;
    FDropped: Int64;                // 溢れて捨てた件数 (診断用)
    FDrainScheduled: Boolean;
    FShuttingDown: Boolean;         // ロック外からも読む (在席カウンタと対で使う)
    FInFlight: Integer;             // コールバック実行中のスレッド数

    { 合流させる最新値 (順序を保つ必要がないもの) }
    FLatestFrequency: Double;
    FHasFrequency: Boolean;
    FLatestMetric: Double;
    FHasMetric: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { 順序保持が必要なイベントを FIFO へ積む。Attach したモデム/エンジンの
      イベントハンドラが使う入口であり、テストからイベントを注入する
      際にも利用する。ワーカースレッドから呼んで安全。 }
    procedure PushEvent(AKind: TUiEventKind; AIntValue: Integer;
      const AStrValue: string);

    { モデム/エンジンを購読対象として登録する。
      fldigi でいう「active_modem に対して各種フックを仕込む」処理。

      【前提条件】Attach/Detach は「エンジンのワーカースレッドが動いて
      いない間」に行うこと (生成直後、または RequestExit + WaitFor の後)。
      TCustomModem のイベントはロックを持たずに発火するため、走行中に
      付け外しすると、2ワードあるメソッドポインタのちぎれた値を
      ワーカーが読む危険がある。TModemEngine 側のイベントはロックで
      守ってあるが、モデム側まで同じ保護を入れると DSP のホットパスに
      ロックが乗るため、呼び出し順序で保証する設計とする。
      本アプリの破棄手順 (UnitMainForm.Destroy) もこの順序に従っている。 }
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

    { 有界FIFOが溢れて捨てたイベント数 (0 が正常)。過負荷の検出用。 }
    function DroppedEventCount: Int64;
  end;

implementation

{ TModemUI }

const
  { 有界FIFOの容量。8000Hz の復調でも文字は毎秒数十字程度なので、
    メインスレッドが一時的に固まっても十分吸収できる大きさ。
    それでも溢れる場合は過負荷なので、古いものから捨てて件数を記録する。 }
  UI_QUEUE_CAPACITY = 4096;

constructor TModemUI.Create;
begin
  inherited Create;
  FModem := nil;
  FEngine := nil;
  FLock := TCriticalSection.Create;
  SetLength(FQueue, UI_QUEUE_CAPACITY);
  FQHead := 0;
  FQCount := 0;
  FDropped := 0;
  FDrainScheduled := False;
  FShuttingDown := False;
  FInFlight := 0;
  FHasFrequency := False;
  FHasMetric := False;
end;

destructor TModemUI.Destroy;
{ UI-02: TThread.Queue(nil, ...) は所有スレッドを結び付けないため、
  破棄後もキューに残ったエントリがメインスレッドで実行され、
  解放済み Self のメソッドを呼ぶ (UAF) 状態だった。
  積むメソッドを DrainToUi 1 種類に統一したので、
  RemoveQueuedEvents(TThreadMethod) でまとめて取り消せる。 }
const
  QUIESCE_TIMEOUT_MS = 2000;
var
  waited: Integer;
  idle: Boolean;
begin
  { 1. 新規のコールバックを断る。在席カウンタより先に立てること。 }
  FShuttingDown := True;

  { 2. 既に入ってきているコールバックが抜けるのを待つ。
       これを待たずに FLock.Free すると、PushEvent の FLock.Enter で
       待っているワーカーが解放済みロックを掴む。 }
  waited := 0;
  repeat
    idle := InterlockedCompareExchange(FInFlight, 0, 0) = 0;
    if idle then Break;
    Sleep(1);
    Inc(waited);
  until waited >= QUIESCE_TIMEOUT_MS;

  { 3. 溜まっている分を捨てる }
  if idle then
  begin
    FLock.Enter;
    try
      FQCount := 0;
      FQHead := 0;
      FHasFrequency := False;
      FHasMetric := False;
    finally
      FLock.Leave;
    end;
  end;

  { 4. 購読を外して、これ以上イベントが来ないようにする }
  DetachModem;
  DetachEngine;

  { 5. 未処理の DrainToUi をキューから取り除く }
  TThread.RemoveQueuedEvents(@DrainToUi);

  { 6. 静止が確認できたときだけロックを解放する。
       2 秒待っても抜けてこないのは既に異常事態 (ワーカーがハングしている)
       であり、この後 inherited Destroy が Self を解放してしまう以上、
       ロックを残しても完全には救えない。それでも「解放済みロックを掴む」
       という即死のパターンだけは避けられるので、あえて漏らす。 }
  if idle then
    FLock.Free;
  inherited Destroy;
end;

function TModemUI.DroppedEventCount: Int64;
begin
  FLock.Enter;
  try
    Result := FDropped;
  finally
    FLock.Leave;
  end;
end;

function TModemUI.EnterCallback: Boolean;
begin
  InterlockedIncrement(FInFlight);
  Result := not FShuttingDown;
  if not Result then
    InterlockedDecrement(FInFlight);
end;

procedure TModemUI.LeaveCallback;
begin
  InterlockedDecrement(FInFlight);
end;

procedure TModemUI.ScheduleDrain;
{ ロックを保持したまま呼ぶこと。未処理のドレインが無いときだけ
  Queue へ積むので、イベントが大量に来てもキューは1件しか使わない。 }
begin
  if FShuttingDown or FDrainScheduled then Exit;
  FDrainScheduled := True;
  TThread.Queue(nil, @DrainToUi);
end;

procedure TModemUI.PushEvent(AKind: TUiEventKind; AIntValue: Integer;
  const AStrValue: string);
var
  idx: Integer;
begin
  if not EnterCallback then Exit;
  try
    FLock.Enter;
    try
      if FShuttingDown then Exit;
      if FQCount >= Length(FQueue) then
      begin
        { 溢れた場合は最も古いものを捨てる (最新の受信内容を優先する)。
          黙って捨てず件数を記録し、DroppedEventCount で検出できるようにする。 }
        FQHead := (FQHead + 1) mod Length(FQueue);
        Dec(FQCount);
        Inc(FDropped);
      end;
      idx := (FQHead + FQCount) mod Length(FQueue);
      FQueue[idx].Kind := AKind;
      FQueue[idx].IntValue := AIntValue;
      FQueue[idx].StrValue := AStrValue;
      Inc(FQCount);
      ScheduleDrain;
    finally
      FLock.Leave;
    end;
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.DrainToUi;
{ メインスレッドで実行される唯一の中継処理。
  FIFO を空になるまで取り出し、順序どおりにフォーム側へ渡す。 }
var
  ev: TUiEvent;
  freq, metric: Double;
  haveFreq, haveMetric, haveEvent: Boolean;
begin
  FLock.Enter;
  try
    FDrainScheduled := False;
    if FShuttingDown then Exit;
  finally
    FLock.Leave;
  end;

  { --- 合流させた最新値 (周波数/メトリック) --- }
  FLock.Enter;
  try
    haveFreq := FHasFrequency;
    freq := FLatestFrequency;
    FHasFrequency := False;
    haveMetric := FHasMetric;
    metric := FLatestMetric;
    FHasMetric := False;
  finally
    FLock.Leave;
  end;
  if haveFreq and Assigned(FOnFrequencyChanged) then
    FOnFrequencyChanged(Self, freq);
  if haveMetric and Assigned(FOnMetricChanged) then
    FOnMetricChanged(Self, metric);

  { --- 順序保持が必要なイベント --- }
  repeat
    FLock.Enter;
    try
      haveEvent := (FQCount > 0) and (not FShuttingDown);
      if haveEvent then
      begin
        ev := FQueue[FQHead];
        FQueue[FQHead].StrValue := '';   // 参照を残さない
        FQHead := (FQHead + 1) mod Length(FQueue);
        Dec(FQCount);
      end;
    finally
      FLock.Leave;
    end;
    if not haveEvent then Break;

    case ev.Kind of
      uekRxChar:
        if Assigned(FOnRxChar) then FOnRxChar(Self, ev.IntValue);
      uekState:
        if Assigned(FOnStateChanged) then FOnStateChanged(Self, TTrxState(ev.IntValue));
      uekStatus:
        if Assigned(FOnStatusText) then FOnStatusText(Self, ev.StrValue);
      uekError:
        if Assigned(FOnError) then FOnError(Self, ev.StrValue);
    end;
  until False;
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
  // 周波数は「最新値だけ表示できればよい」ので意図的に合流させる (UI-01)。
  if not EnterCallback then Exit;
  try
    FLock.Enter;
    try
      FLatestFrequency := AFrequency;
      FHasFrequency := True;
      ScheduleDrain;
    finally
      FLock.Leave;
    end;
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.ModemMetricChanged(Sender: TCustomModem; AMetric: Double);
begin
  // fldigi: REQ(callback_set_metric, m);
  // メトリックも最新値のみで足りるため合流させる (UI-01)。
  if not EnterCallback then Exit;
  try
    FLock.Enter;
    try
      FLatestMetric := AMetric;
      FHasMetric := True;
      ScheduleDrain;
    finally
      FLock.Leave;
    end;
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.ModemStatusText(Sender: TCustomModem; const AText: string);
begin
  // fldigi: put_Status1(msg) / put_MODEstatus(...)
  PushEvent(uekStatus, 0, AText);
end;

procedure TModemUI.ModemPutRxChar(Sender: TCustomModem; ACh: Integer);
begin
  // fldigi: put_rx_char(c) -- 復調文字を受信ウィンドウへ
  // 文字は 1 字も落とさず順序も守る必要があるため FIFO へ積む (UI-01)。
  PushEvent(uekRxChar, ACh, '');
end;

function TModemUI.ModemGetTxChar(Sender: TCustomModem): Integer;
begin
  { fldigi: get_tx_char() は「今すぐ値が要る」同期呼び出しであり、
    キューイングすると送信タイミングが崩れる。そのため、
    OnGetTxChar はスレッドセーフな実装であることを呼び出し元
    (フォーム) に要求した上で、直接呼び出す (Queueしない)。 }
  Result := MODEM_TX_CHAR_ETX;
  if not EnterCallback then Exit;
  try
    if Assigned(FOnGetTxChar) then
      Result := FOnGetTxChar(Self);
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.EngineStateChanged(Sender: TModemEngine; AState: TTrxState);
begin
  { 状態遷移は履歴として意味があるので合流させず FIFO へ積む。 }
  PushEvent(uekState, Ord(AState), '');
end;

procedure TModemUI.EngineError(Sender: TModemEngine; const AMsg: string);
begin
  PushEvent(uekError, 0, AMsg);
end;

end.
