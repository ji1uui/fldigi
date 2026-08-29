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
  Classes, SysUtils, SyncObjs, Modem, ModemEngine, ModemTypes, DecodeEvidence,
  EventBus;

type
  { FIFO に積むイベントの種別 (UI-01)。 }
  TUiEventKind = (uekRxChar, uekState, uekStatus, uekError);

  TUiEvent = record
    Kind: TUiEventKind;
    IntValue: Integer;   // uekRxChar: 文字コード / uekState: Ord(TTrxState)
    StrValue: string;    // uekStatus / uekError

    { ADR-002 で復調結果が Evidence になったので、その要約もここで運ぶ。
      候補の配列そのものは載せない ― 有界FIFOの要素は固定長にしておく
      必要があり、要素ごとに動的配列を持たせると受信文字1字ごとに
      確保が走る (X-04 の趣旨に反する)。
      Phase 4 で補正候補の提示が要るようになった時点で、候補列を
      別の経路 (Evidence Store への参照) で渡す形に拡張する。 }
    MetricKind: TEvidenceMetricKind;
    Metric: Double;      // 最有力候補の尺度
    AltCount: Integer;   // 第2候補以降の件数
  end;

  TModemUI = class;

  { GUI 側 (フォーム) が実装するコールバック群。
    いずれも「メインスレッド上で」安全に呼び出されることが保証される。 }
  TUIFrequencyEvent = procedure(Sender: TModemUI; AFrequency: Double) of object;
  TUIMetricEvent = procedure(Sender: TModemUI; AMetric: Double) of object;
  TUIStatusEvent = procedure(Sender: TModemUI; const AText: string) of object;
  { ADR-002: 尺度も一緒に渡す。Phase 4 の Confidence-aware GUI が
    「低確信度の文字を強調する」ために必要になる。
    AMetricKind が emkNone なら AMetric に意味は無い。 }
  TUIRxCharEvent = procedure(Sender: TModemUI; ACh: Integer;
    AMetricKind: TEvidenceMetricKind; AMetric: Double;
    AAltCount: Integer) of object;
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
    procedure ModemDecode(Sender: TCustomModem;
      const AEvidence: TDecodeEvidence);
    function ModemGetTxChar(Sender: TCustomModem): Integer;
    procedure EngineStateChanged(Sender: TModemEngine; AState: TTrxState);
    procedure EngineError(Sender: TModemEngine; const AMsg: string);

  private
    { --- ADR-001: 待ち行列と配送は Event Bus に委ねる ---
      以前は TModemUI が自前で有界FIFO・単一ドレイン・在席カウンタを
      持っていた。その仕組みは正しかったが、Control Plane の通知路として
      同じものが Event Bus 側にも要る。二重に持つ理由がないので、
      TModemUI は
        - モデム/エンジンのイベントをバスへ発行する publisher
        - バスから受けてフォームのコールバックを呼ぶ subscriber
      の 2 役に徹する。

      副次的な効果として、ロガーや Plugin や Observability が
      同じイベントを購読できるようになる (TModemUI を経由せずに済む)。

      在席カウンタ (FInFlight) だけは TModemUI 側にも残す。
      バスは自分の破棄を守れるが、「ワーカーが TModemUI のメソッドの中に
      いる最中に TModemUI が破棄される」窓は TModemUI 自身にしか守れない。 }
    FBus: TEventBus;
    FOwnsBus: Boolean;
    FShuttingDown: Boolean;   // ロック外からも読む (在席カウンタと対で使う)
    FInFlight: Integer;       // コールバック実行中のスレッド数
  private
    { バスから受け取ってフォームのコールバックへ振り分ける。 }
    procedure HandleBusEvent(const AEvent: TBusEvent);

    { --- 破棄とワーカー呼び出しの競合を狭めるための在席カウンタ ---
      DetachModem/DetachEngine は「これから来る呼び出し」を止めるだけで、
      既に中に入っている呼び出しは止められない。
      「今このオブジェクトのコールバック内にいるスレッド数」を数え、
      Destroy はそれが 0 になるまで解放を待つ。

      【できることの限界】救えるのは「Destroy に入った時点で既に中にいた
      呼び出し」だけである。Destroy が戻った後に始まる呼び出しは、
      オブジェクトのメモリ自体が解放済みなので何をしても救えない。
      したがって呼び出し側の責務は変わらない:
        エンジンのワーカースレッドを停止させてから TModemUI を破棄すること。 }
    function EnterCallback: Boolean;
    procedure LeaveCallback;
  public
    { ABus に既存のバスを渡すと、それを共有する (ロガーや Plugin が
      同じイベントを購読できる)。nil なら自前のバスを作って所有する。 }
    constructor Create(ABus: TEventBus = nil);
    destructor Destroy; override;

    { イベントをバスへ発行する。Attach したモデム/エンジンのハンドラが
      使う入口であり、テストからイベントを注入する際にも利用する。
      ワーカースレッドから呼んで安全。 }
    procedure PushEvent(AKind: TUiEventKind; AIntValue: Integer;
      const AStrValue: string);

    { 復調結果 (Evidence) を発行する。最有力候補の文字と尺度の要約を運ぶ。 }
    procedure PushDecode(const AEvidence: TDecodeEvidence);

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

    { バスが溢れて捨てたイベント数 (0 が正常)。過負荷の検出用。 }
    function DroppedEventCount: Int64;

    { 購読しているバス。ロガーや Observability もここへ購読できる。 }
    property Bus: TEventBus read FBus;
  end;

implementation

{ TModemUI }

const
  { 有界FIFOの容量。8000Hz の復調でも文字は毎秒数十字程度なので、
    メインスレッドが一時的に固まっても十分吸収できる大きさ。
    それでも溢れる場合は過負荷なので、古いものから捨てて件数を記録する。 }
  UI_QUEUE_CAPACITY = 4096;
  { このオブジェクトが発行したことを診断で分かるようにする (Z-01)。 }
  UI_SOURCE = 'ModemUI';
  { フォームへ中継する種別。これ以外はバスを流れても無視する。 }
  UI_EVENT_KINDS = [bekModemFrequency, bekModemMetric, bekDecodedSymbol,
                    bekTrxStateChanged, bekStatusText, bekError];

constructor TModemUI.Create(ABus: TEventBus);
begin
  inherited Create;
  FModem := nil;
  FEngine := nil;
  FShuttingDown := False;
  FInFlight := 0;
  FOwnsBus := ABus = nil;
  if FOwnsBus then
    FBus := TEventBus.Create(UI_QUEUE_CAPACITY)
  else
    FBus := ABus;
  FBus.Subscribe(@HandleBusEvent, UI_EVENT_KINDS);
end;

destructor TModemUI.Destroy;
const
  QUIESCE_TIMEOUT_MS = 2000;
var
  waited: Integer;
  idle: Boolean;
begin
  { 1. 新規のコールバックを断る。在席カウンタより先に立てること。 }
  FShuttingDown := True;

  { 2. 既に入ってきているコールバックが抜けるのを待つ。 }
  waited := 0;
  repeat
    idle := InterlockedCompareExchange(FInFlight, 0, 0) = 0;
    if idle then Break;
    Sleep(1);
    Inc(waited);
  until waited >= QUIESCE_TIMEOUT_MS;

  { 3. 購読を外す。以降このオブジェクトへは配送されない。 }
  if Assigned(FBus) then
    FBus.Unsubscribe(@HandleBusEvent);

  { 4. モデム/エンジンからの購読も外す }
  DetachModem;
  DetachEngine;

  { 5. 自前のバスなら破棄する。バスの Destroy が未配送分の取り消し
       (RemoveQueuedEvents) まで面倒を見る。
       共有バスの場合は他の購読者がいるので触らない。 }
  if FOwnsBus and Assigned(FBus) then
    FBus.Free;
  FBus := nil;

  inherited Destroy;
end;

function TModemUI.DroppedEventCount: Int64;
begin
  if Assigned(FBus) then
    Result := FBus.DroppedCount
  else
    Result := 0;
end;

function TModemUI.EnterCallback: Boolean;
begin
  InterlockedIncrement(FInFlight);
  Result := (not FShuttingDown) and Assigned(FBus);
  if not Result then
    InterlockedDecrement(FInFlight);
end;

procedure TModemUI.LeaveCallback;
begin
  InterlockedDecrement(FInFlight);
end;

procedure TModemUI.PushEvent(AKind: TUiEventKind; AIntValue: Integer;
  const AStrValue: string);
begin
  if not EnterCallback then Exit;
  try
    case AKind of
      uekRxChar:
        FBus.PublishNumeric(bekDecodedSymbol, AIntValue, Ord(emkNone),
          0, 0, UI_SOURCE, 0);
      uekState:
        FBus.PublishNumeric(bekTrxStateChanged, AIntValue, 0, 0, 0, UI_SOURCE);
      uekStatus:
        FBus.PublishText(bekStatusText, AStrValue, UI_SOURCE);
      uekError:
        FBus.PublishText(bekError, AStrValue, UI_SOURCE);
    end;
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.PushDecode(const AEvidence: TDecodeEvidence);
begin
  if not EnterCallback then Exit;
  try
    { 候補の配列そのものはバスに載せない。イベントは固定長でなければ
      ならず (ADR-001)、受信文字ごとに確保が走ると X-04 にも反する。
      最有力候補と尺度の要約だけを運ぶ。補正候補の提示が要る Phase 4 で、
      候補列を別経路 (Evidence Store への参照) で渡す形に拡張する。 }
    { Z-01: SNR と復調戦略名は、アルゴリズム改善のための材料になる。
      Evidence が持っているのにここで落としていたので通す。
      発行元は UI ではなく「どの戦略が出したか」にする ―
      Phase 3 で複数戦略を並列評価したとき、記録から戦略を
      区別できる必要がある。 }
    FBus.PublishNumeric(bekDecodedSymbol,
      AEvidence.BestChar, Ord(AEvidence.MetricKind),
      AEvidence.BestMetric,
      AEvidence.SnrDb,
      AEvidence.DecoderName,
      AEvidence.CandidateCount - 1);
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.HandleBusEvent(const AEvent: TBusEvent);
{ メインスレッドで実行される唯一の中継処理。
  バスが順序・有界性・単一ドレイン・購読者の例外封じ込めを担うので、
  ここは種別ごとの振り分けだけを行う。 }
begin
  if FShuttingDown then Exit;
  case AEvent.Kind of
    bekModemFrequency:
      if Assigned(FOnFrequencyChanged) then
        FOnFrequencyChanged(Self, AEvent.D1);
    bekModemMetric:
      if Assigned(FOnMetricChanged) then
        FOnMetricChanged(Self, AEvent.D1);
    bekDecodedSymbol:
      if Assigned(FOnRxChar) then
        FOnRxChar(Self, AEvent.I1, TEvidenceMetricKind(AEvent.I2),
          AEvent.D1, AEvent.I3);
    bekTrxStateChanged:
      if Assigned(FOnStateChanged) then
        FOnStateChanged(Self, TTrxState(AEvent.I1));
    bekStatusText:
      if Assigned(FOnStatusText) then
        FOnStatusText(Self, AEvent.Text);
    bekError:
      if Assigned(FOnError) then
        FOnError(Self, AEvent.Text);
  end;
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
    FModem.OnDecode := @ModemDecode;
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
    FModem.OnDecode := nil;
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
  // 周波数は「最新値だけ表示できればよい」ので合流させる (UI-01)。
  // 更新頻度が高く、FIFO に積むと復調文字を押し出してしまう。
  if not EnterCallback then Exit;
  try
    FBus.PublishLatest(bekModemFrequency, 0, AFrequency, 0, UI_SOURCE);
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.ModemMetricChanged(Sender: TCustomModem; AMetric: Double);
begin
  // fldigi: REQ(callback_set_metric, m)
  // メトリックも最新値のみで足りるため合流させる (UI-01)。
  if not EnterCallback then Exit;
  try
    FBus.PublishLatest(bekModemMetric, 0, AMetric, 0, UI_SOURCE);
  finally
    LeaveCallback;
  end;
end;

procedure TModemUI.ModemStatusText(Sender: TCustomModem; const AText: string);
begin
  // fldigi: put_Status1(msg) / put_MODEstatus(...)
  PushEvent(uekStatus, 0, AText);
end;

procedure TModemUI.ModemDecode(Sender: TCustomModem;
  const AEvidence: TDecodeEvidence);
begin
  // fldigi: put_rx_char(c) -- 復調結果を受信ウィンドウへ
  // 文字は 1 字も落とさず順序も守る必要があるため FIFO へ積む (UI-01)。
  if AEvidence.CandidateCount = 0 then Exit;   // 候補なしは表示しない
  PushDecode(AEvidence);
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
