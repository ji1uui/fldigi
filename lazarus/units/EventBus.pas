{ ============================================================================
  EventBus.pas

  Architecture & Requirements Baseline v1.1 の
  §5.1 Data Plane / Control Plane 分離 (ADR-001) と §12 Event Bus に対応する
  Phase 0 の Core interface。

  何を運び、何を運ばないか (ADR-001):
  ----------------------------------------------------------------------------
  Event Bus は **Control Plane 専用** である。状態変化・制御・結果通知だけを
  流し、Audio / IQ / Spectrum / DSP Frame といった広帯域・高頻度のデータは
  絶対に載せない。それらは Ring Buffer や共有バッファ (Data Plane) で扱う。

  この境界を「気をつける」で守るのは無理なので、型で守る:

    - イベントの積載物 (TBusEvent) は **固定長のレコード** である。
      配列もストリームも持てないので、そもそも波形を載せられない。
    - 数値は固定スロット、文字列は 1 本だけ。文字列は確保を伴うので
      低頻度のイベント (エラー、ステータス、コールサイン) に限る。
      高頻度のイベント (DecodedSymbol) は数値スロットだけを使う。

  スレッドとの関係:
  ----------------------------------------------------------------------------
  発行側は音声ワーカースレッド、購読側は UI スレッドであることが多い。
  そこで「発行は任意スレッドから即座に戻り、配送は 1 つの消費スレッドで
  まとめて行う」形にする。

    Publish (任意スレッド) → 有界リングバッファへコピー
                           → 未スケジュールなら Queue を 1 回だけ積む
    DispatchPending (メインスレッド) → 溜まったぶんを順に購読者へ配る

  有界にしてあるのは、UI が詰まったときにメモリが伸び続けないようにするため。
  溢れたら古いものから捨て、捨てた件数を数える (黙って失うより
  「何件落ちたか」が分かる方が運用上は正しい)。

  購読者の例外を封じ込める (§12):
  ----------------------------------------------------------------------------
  「Subscriber 例外によって Event Bus 全体を停止させない」ことが要求されている。
  1 つの購読者が投げた例外で他の購読者への配送が止まると、障害が波及する
  (B-04 / Z-06 Fault Isolation)。購読者ごとに例外境界を置き、
  捕まえた例外は件数を数えて OnSubscriberError で通知したうえで、
  残りの購読者への配送を続ける。
  ============================================================================ }
unit EventBus;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  EEventBusError = class(Exception);

  { §12 に挙げられているイベント種別。
    Control Plane のものだけを並べる。Audio/IQ/Spectrum は入れない。 }
  TBusEventKind = (
    bekNone,
    { --- 受信・復調 --- }
    bekSignalDetected,       // 信号を検出した
    bekDecodedSymbol,        // 文字/シンボルを復調した
    bekCallsignIdentified,   // コールサインを同定した
    { --- 交信 --- }
    bekQsoStarted,
    bekExchangeReceived,
    bekQsoCompleted,
    { --- 記録・集計 --- }
    bekLogUpdated,
    bekQslConfirmed,
    bekAwardProgressChanged,
    bekContestScoreChanged,
    { --- 機器・エンジン --- }
    bekModemFrequency,       // 復調中心周波数が変わった (最新値のみ意味を持つ)
    bekModemMetric,          // 受信品質指標が変わった (最新値のみ意味を持つ)
    bekRigChanged,
    bekTrxStateChanged,      // 送受信状態が変わった
    bekModemChanged,
    { --- 診断 --- }
    bekStatusText,
    bekError
  );
  TBusEventKinds = set of TBusEventKind;

  { バスを流れるイベント 1 件。

    【重要】このレコードは固定長でなければならない。
    動的配列やストリームのフィールドを足すと、
      (1) Data Plane のデータを載せられてしまい ADR-001 が崩れる
      (2) 発行のたびに確保が走り X-04 に反する
    の両方が起きる。文字列が 1 本あるのは例外で、
    低頻度のイベント専用と決めている。 }
  TBusEvent = record
    Kind: TBusEventKind;
    { 汎用の数値スロット。意味は種別ごとに決める。

        bekDecodedSymbol   I1=文字コード I2=尺度種別 I3=第2候補件数
                           D1=尺度       D2=SNR
        bekModemFrequency  D1=周波数[Hz]
        bekModemMetric     D1=指標値
        bekTrxStateChanged I1=状態値

      種別ごとに型を作らず汎用スロットにしているのは、発行が音声ワーカー
      から起きるため確保を避けたいからである (X-04)。型安全性を犠牲にする
      代わりに、意味はこの表と発行側のヘルパー関数で固定する。 }
    I1, I2, I3: Int64;
    D1, D2: Double;
    { 低頻度イベント専用の文字列スロット。
      高頻度イベントでは使わないこと (確保が走る)。 }
    Text: string;
    { 発行時刻 (UTC)。観測・再現に使う (Z-01)。 }
    TimestampUtc: TDateTime;
    { 発行元の識別子 (診断用)。 }
    Source: string;

    function Describe: string;
  end;

  TBusEventHandler = procedure(const AEvent: TBusEvent) of object;
  TBusErrorHandler = procedure(const AEvent: TBusEvent;
    const AMessage: string) of object;

  { TEventBus
    ---------------------------------------------------------------------
    Control Plane の疎結合な通知路。 }
  TEventBus = class
  private
    type
      TSubscription = record
        Handler: TBusEventHandler;
        Kinds: TBusEventKinds;   // 空集合 = すべて受け取る
        Active: Boolean;
      end;
  private
    FLock: TCriticalSection;
    FQueue: array of TBusEvent;
    FQHead, FQCount: Integer;
    FDropped: Int64;
    FPublished: Int64;
    FDelivered: Int64;
    FSubscriberErrors: Int64;
    FDrainScheduled: Boolean;
    FShuttingDown: Boolean;
    FInFlight: Integer;
    FSubs: array of TSubscription;
    { 合流対象イベントの「未配送スロット位置」。-1 = 未配送のものが無い。
      配送・破棄でスロットが出ていくときに必ず -1 に戻す
      (戻し忘れると、再利用された別のイベントを上書きしてしまう)。 }
    FLatestIdx: array[TBusEventKind] of Integer;
    FOnSubscriberError: TBusErrorHandler;
    FAutoDispatch: Boolean;

    function EnterPublish: Boolean;
    procedure LeavePublish;
    procedure ScheduleDrain;      // ロック保持中に呼ぶこと
    { スロットが待ち行列から出ていくときに合流索引を無効化する。
      ロック保持中に呼ぶこと。 }
    procedure ReleaseSlot(AIdx: Integer);
    procedure DrainToMainThread;
  public
    constructor Create(ACapacity: Integer = 0);
    destructor Destroy; override;

    { --- 発行 (任意スレッドから) --- }
    procedure Publish(const AEvent: TBusEvent);
    { 数値だけのイベントを組み立てて発行する (高頻度用。文字列を使わない)。 }
    procedure PublishNumeric(AKind: TBusEventKind; AI1: Int64 = 0;
      AI2: Int64 = 0; AD1: Double = 0; AD2: Double = 0;
      const ASource: string = ''; AI3: Int64 = 0);
    { 文字列つきイベントを発行する (低頻度用)。 }
    procedure PublishText(AKind: TBusEventKind; const AText: string;
      const ASource: string = '');
    { --- 最新値だけが意味を持つイベントの発行 ---
      同じ種別の未配送イベントが既にあれば、その場で上書きする
      (積み増さない)。周波数や S メーターのように「最後の値だけ表示できれば
      よい」ものを FIFO に積むと、更新頻度の高さで復調文字が押し出される。
      位置は最初に積まれたときのものを保つ (順序は最初の出現で決まる)。 }
    procedure PublishLatest(AKind: TBusEventKind; AI1: Int64 = 0;
      AD1: Double = 0; AD2: Double = 0; const ASource: string = '');

    { --- 購読 --- }
    { AKinds が空集合ならすべての種別を受け取る。 }
    procedure Subscribe(AHandler: TBusEventHandler;
      AKinds: TBusEventKinds = []);
    procedure Unsubscribe(AHandler: TBusEventHandler);
    function SubscriberCount: Integer;

    { --- 配送 ---
      溜まっているイベントを購読者へ配る。通常は AutoDispatch=True により
      メインスレッドで自動的に呼ばれる。テストや、独自のループを回す
      アプリでは手で呼んでよい。
      戻り値: 配送した件数。 }
    function DispatchPending: Integer;

    { 溜まっているイベントを捨てる。 }
    procedure Clear;

    { --- 観測 (Z-01) --- }
    function PendingCount: Integer;
    property PublishedCount: Int64 read FPublished;
    property DeliveredCount: Int64 read FDelivered;
    { 溢れて捨てた件数。0 でないなら購読側が追いついていない。 }
    property DroppedCount: Int64 read FDropped;
    { 購読者が投げた例外の件数。 }
    property SubscriberErrorCount: Int64 read FSubscriberErrors;

    { 購読者が例外を投げたときの通知先。設定しなくてもバスは止まらない。 }
    property OnSubscriberError: TBusErrorHandler
      read FOnSubscriberError write FOnSubscriberError;
    { True なら発行時にメインスレッドへの配送を自動で予約する (既定)。
      False にすると DispatchPending を呼ぶまで溜まる (テスト・組み込み用)。 }
    property AutoDispatch: Boolean read FAutoDispatch write FAutoDispatch;
  end;

function BusEventKindToStr(AKind: TBusEventKind): string;

implementation

uses
  DateUtils;

const
  DEFAULT_CAPACITY = 4096;
  { 破棄時に、実行中のコールバックが抜けるのを待つ上限。 }
  QUIESCE_TIMEOUT_MS = 2000;

function BusEventKindToStr(AKind: TBusEventKind): string;
begin
  case AKind of
    bekSignalDetected:       Result := 'SignalDetected';
    bekDecodedSymbol:        Result := 'DecodedSymbol';
    bekCallsignIdentified:   Result := 'CallsignIdentified';
    bekQsoStarted:           Result := 'QSOStarted';
    bekExchangeReceived:     Result := 'ExchangeReceived';
    bekQsoCompleted:         Result := 'QSOCompleted';
    bekLogUpdated:           Result := 'LogUpdated';
    bekQslConfirmed:         Result := 'QSLConfirmed';
    bekAwardProgressChanged: Result := 'AwardProgressChanged';
    bekContestScoreChanged:  Result := 'ContestScoreChanged';
    bekModemFrequency:       Result := 'ModemFrequency';
    bekModemMetric:          Result := 'ModemMetric';
    bekRigChanged:           Result := 'RigChanged';
    bekTrxStateChanged:      Result := 'TrxStateChanged';
    bekModemChanged:         Result := 'ModemChanged';
    bekStatusText:           Result := 'StatusText';
    bekError:                Result := 'Error';
  else
    Result := 'None';
  end;
end;

{ TBusEvent }

function TBusEvent.Describe: string;
begin
  Result := BusEventKindToStr(Kind);
  if Source <> '' then
    Result := Result + '[' + Source + ']';
  Result := Result + Format('(%d,%d,%.3f,%.3f)', [I1, I2, D1, D2]);
  if Text <> '' then
    Result := Result + ' "' + Text + '"';
end;

{ TEventBus }

constructor TEventBus.Create(ACapacity: Integer);
var
  k: TBusEventKind;
begin
  inherited Create;
  if ACapacity <= 0 then
    ACapacity := DEFAULT_CAPACITY;
  FLock := TCriticalSection.Create;
  SetLength(FQueue, ACapacity);
  FQHead := 0;
  FQCount := 0;
  FDropped := 0;
  FPublished := 0;
  FDelivered := 0;
  FSubscriberErrors := 0;
  FDrainScheduled := False;
  FShuttingDown := False;
  FInFlight := 0;
  FAutoDispatch := True;
  for k := Low(TBusEventKind) to High(TBusEventKind) do
    FLatestIdx[k] := -1;
end;

procedure TEventBus.ReleaseSlot(AIdx: Integer);
var
  k: TBusEventKind;
begin
  k := FQueue[AIdx].Kind;
  if FLatestIdx[k] = AIdx then
    FLatestIdx[k] := -1;
end;

destructor TEventBus.Destroy;
{ ModemUI と同じ考え方。切り離しは「これから来る発行」を止めるだけで、
  既に中に入っている発行は止められない。実行中のものが抜けるのを待ってから
  ロックを解放する。抜けてこない場合は、解放して未定義動作にするより
  意図的に漏らす方が害が小さい。 }
var
  waited: Integer;
  idle: Boolean;
  k: TBusEventKind;
begin
  FShuttingDown := True;

  waited := 0;
  repeat
    idle := InterlockedCompareExchange(FInFlight, 0, 0) = 0;
    if idle then Break;
    Sleep(1);
    Inc(waited);
  until waited >= QUIESCE_TIMEOUT_MS;

  if idle then
  begin
    FLock.Enter;
    try
      FQCount := 0;
      FQHead := 0;
      for k := Low(TBusEventKind) to High(TBusEventKind) do
        FLatestIdx[k] := -1;
      SetLength(FSubs, 0);
    finally
      FLock.Leave;
    end;
  end;

  TThread.RemoveQueuedEvents(@DrainToMainThread);

  if idle then
    FLock.Free;
  inherited Destroy;
end;

function TEventBus.EnterPublish: Boolean;
begin
  InterlockedIncrement(FInFlight);
  Result := not FShuttingDown;
  if not Result then
    InterlockedDecrement(FInFlight);
end;

procedure TEventBus.LeavePublish;
begin
  InterlockedDecrement(FInFlight);
end;

procedure TEventBus.ScheduleDrain;
begin
  if FShuttingDown or FDrainScheduled or (not FAutoDispatch) then Exit;
  FDrainScheduled := True;
  TThread.Queue(nil, @DrainToMainThread);
end;

procedure TEventBus.DrainToMainThread;
begin
  FLock.Enter;
  try
    FDrainScheduled := False;
    if FShuttingDown then Exit;
  finally
    FLock.Leave;
  end;
  DispatchPending;
end;

procedure TEventBus.Publish(const AEvent: TBusEvent);
var
  idx: Integer;
begin
  if not EnterPublish then Exit;
  try
    FLock.Enter;
    try
      if FShuttingDown then Exit;
      Inc(FPublished);
      if FQCount >= Length(FQueue) then
      begin
        { 溢れたら最も古いものを捨てる。黙って失わず件数を記録する。 }
        ReleaseSlot(FQHead);
        FQHead := (FQHead + 1) mod Length(FQueue);
        Dec(FQCount);
        Inc(FDropped);
      end;
      idx := (FQHead + FQCount) mod Length(FQueue);
      FQueue[idx] := AEvent;
      if FQueue[idx].TimestampUtc = 0 then
        FQueue[idx].TimestampUtc := LocalTimeToUniversal(Now);
      Inc(FQCount);
      ScheduleDrain;
    finally
      FLock.Leave;
    end;
  finally
    LeavePublish;
  end;
end;

procedure TEventBus.PublishNumeric(AKind: TBusEventKind; AI1, AI2: Int64;
  AD1, AD2: Double; const ASource: string; AI3: Int64);
var
  ev: TBusEvent;
begin
  ev.Kind := AKind;
  ev.I1 := AI1;
  ev.I2 := AI2;
  ev.I3 := AI3;
  ev.D1 := AD1;
  ev.D2 := AD2;
  ev.Text := '';
  ev.TimestampUtc := 0;
  ev.Source := ASource;
  Publish(ev);
end;

procedure TEventBus.PublishText(AKind: TBusEventKind; const AText: string;
  const ASource: string);
var
  ev: TBusEvent;
begin
  ev.Kind := AKind;
  ev.I1 := 0;
  ev.I2 := 0;
  ev.I3 := 0;
  ev.D1 := 0;
  ev.D2 := 0;
  ev.Text := AText;
  ev.TimestampUtc := 0;
  ev.Source := ASource;
  Publish(ev);
end;

procedure TEventBus.PublishLatest(AKind: TBusEventKind; AI1: Int64;
  AD1, AD2: Double; const ASource: string);
var
  idx: Integer;
begin
  if not EnterPublish then Exit;
  try
    FLock.Enter;
    try
      if FShuttingDown then Exit;
      Inc(FPublished);
      idx := FLatestIdx[AKind];
      if idx < 0 then
      begin
        { 未配送のものが無いので新しく積む }
        if FQCount >= Length(FQueue) then
        begin
          ReleaseSlot(FQHead);
          FQHead := (FQHead + 1) mod Length(FQueue);
          Dec(FQCount);
          Inc(FDropped);
        end;
        idx := (FQHead + FQCount) mod Length(FQueue);
        Inc(FQCount);
        FLatestIdx[AKind] := idx;
      end;
      { 既にあればその場で上書きする (積み増さない) }
      FQueue[idx].Kind := AKind;
      FQueue[idx].I1 := AI1;
      FQueue[idx].I2 := 0;
      FQueue[idx].I3 := 0;
      FQueue[idx].D1 := AD1;
      FQueue[idx].D2 := AD2;
      FQueue[idx].Text := '';
      FQueue[idx].Source := ASource;
      FQueue[idx].TimestampUtc := LocalTimeToUniversal(Now);
      ScheduleDrain;
    finally
      FLock.Leave;
    end;
  finally
    LeavePublish;
  end;
end;

procedure TEventBus.Subscribe(AHandler: TBusEventHandler;
  AKinds: TBusEventKinds);
var
  n: Integer;
begin
  if not Assigned(AHandler) then
    raise EEventBusError.Create('購読ハンドラが指定されていません');
  FLock.Enter;
  try
    n := Length(FSubs);
    SetLength(FSubs, n + 1);
    FSubs[n].Handler := AHandler;
    FSubs[n].Kinds := AKinds;
    FSubs[n].Active := True;
  finally
    FLock.Leave;
  end;
end;

procedure TEventBus.Unsubscribe(AHandler: TBusEventHandler);
var
  i, j: Integer;
begin
  FLock.Enter;
  try
    i := 0;
    while i < Length(FSubs) do
    begin
      if (TMethod(FSubs[i].Handler).Code = TMethod(AHandler).Code) and
         (TMethod(FSubs[i].Handler).Data = TMethod(AHandler).Data) then
      begin
        for j := i to High(FSubs) - 1 do
          FSubs[j] := FSubs[j + 1];
        SetLength(FSubs, Length(FSubs) - 1);
      end
      else
        Inc(i);
    end;
  finally
    FLock.Leave;
  end;
end;

function TEventBus.SubscriberCount: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FSubs);
  finally
    FLock.Leave;
  end;
end;

function TEventBus.DispatchPending: Integer;
var
  ev: TBusEvent;
  haveEvent: Boolean;
  subs: array of TSubscription;
  i: Integer;
begin
  Result := 0;
  repeat
    { イベントと購読者一覧をロック下で写し取り、呼び出しはロック外で行う。
      購読者がバスへ発行し返してもデッドロックしないようにするため。 }
    FLock.Enter;
    try
      haveEvent := (FQCount > 0) and (not FShuttingDown);
      if haveEvent then
      begin
        ev := FQueue[FQHead];
        ReleaseSlot(FQHead);
        FQueue[FQHead].Text := '';     // 参照を残さない
        FQueue[FQHead].Source := '';
        FQHead := (FQHead + 1) mod Length(FQueue);
        Dec(FQCount);
        subs := Copy(FSubs, 0, Length(FSubs));
      end;
    finally
      FLock.Leave;
    end;
    if not haveEvent then Break;

    for i := 0 to High(subs) do
    begin
      if not subs[i].Active then Continue;
      if (subs[i].Kinds <> []) and (not (ev.Kind in subs[i].Kinds)) then
        Continue;
      { §12: 購読者の例外でバス全体を止めない。 }
      try
        subs[i].Handler(ev);
      except
        on E: Exception do
        begin
          FLock.Enter;
          try
            Inc(FSubscriberErrors);
          finally
            FLock.Leave;
          end;
          if Assigned(FOnSubscriberError) then
            try
              FOnSubscriberError(ev, E.Message);
            except
              on E2: Exception do ;  // 通知先の例外も封じ込める
            end;
        end;
      end;
    end;

    FLock.Enter;
    try
      Inc(FDelivered);
    finally
      FLock.Leave;
    end;
    Inc(Result);
  until False;
end;

procedure TEventBus.Clear;
var
  k: TBusEventKind;
begin
  FLock.Enter;
  try
    FQCount := 0;
    FQHead := 0;
    for k := Low(TBusEventKind) to High(TBusEventKind) do
      FLatestIdx[k] := -1;
  finally
    FLock.Leave;
  end;
end;

function TEventBus.PendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FQCount;
  finally
    FLock.Leave;
  end;
end;

end.
