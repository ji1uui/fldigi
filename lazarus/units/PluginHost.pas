{ ============================================================================
  PluginHost.pas

  §11 Extension Platform の Core 側。Plugin を受け入れ、呼び出し、
  壊れたものを隔離する。

  **Plugin 作者はこのユニットに依存しない**。依存するのは PluginApi.pas
  だけである。この向きを保つことが、後で Plugin を別プロセスへ出せるか
  どうかを決める (ADR-005)。逆向きの依存が 1 本でも付くと、Plugin が
  Core の内部構造を掴んでしまい、境界が意味を失う。

  §11.1「Plugin 障害は Core や他 Plugin へ波及させない」をどう受けたか
  ----------------------------------------------------------------------------
  Plugin への呼び出しは **すべて SafeInvoke という 1 か所の関門を通る**。
  ここ以外から Plugin のメソッドを呼んではならない。関門がやることは 3 つ。

    1. 例外を受け止める。呼び出し元へ投げ返さない。
    2. 連続失敗を数え、続いたら隔離する (呼ぶのをやめる)。
    3. 所要時間を測り、予算を超えたら記録する。

  なぜ「連続」失敗で数えるか
  ----------------------------------------------------------------------------
  通算の失敗数で切ると、長時間動いている健全な Plugin がいつか必ず
  隔離される。逆に「たまに失敗する」ことを許し続けると、壊れた Plugin が
  毎回例外を投げながら永久に呼ばれ続ける。circuit breaker と同じ考え方で、
  成功したら数え直し、連続して失敗したときだけ切る。

  時間の予算について正直に書いておく
  ----------------------------------------------------------------------------
  同一プロセス内では、時間を **測ることはできるが止めることはできない**。
  Plugin が無限ループに入れば、呼んだスレッドは戻ってこない。
  Z-04 の deadline を Plugin に対して本当に強制するには、別プロセスに
  出して落とせるようにするしかない。ここで測っているのは「その必要が
  あるかどうかを判断するための材料」であり、強制ではない。
  これが ADR-005 (将来サブプロセス化を妨げない) が必要な理由そのものである。

  Plugin が Event Bus へ発行するとき
  ----------------------------------------------------------------------------
  発行元 (Source) は Plugin の Id で **上書きする**。Plugin に名乗らせない。
  名乗らせると、Plugin が Core や他 Plugin になりすませてしまい、
  記録を見ても誰が出したのか分からなくなる。
  ============================================================================ }
unit PluginHost;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SyncObjs,
  PluginApi, EventBus, Observability;

const
  { 連続して何回失敗したら隔離するか。
    1 回で切ると起動直後の一時的な失敗で使えなくなり、大きすぎると
    壊れたものを呼び続ける。 }
  DEFAULT_FAULT_LIMIT = 3;

  { 1 回の呼び出しの目安 [秒]。超えても止められない (上の注を参照)。
    記録して「別プロセスに出すべき Plugin」を見つけるための線。 }
  DEFAULT_CALL_BUDGET_SEC = 0.010;

  { Plugin が Event Bus へ載せられる文字列の上限。
    Control Plane に大きなものを流させないための歯止め (ADR-001)。 }
  MAX_PLUGIN_EVENT_TEXT = 4096;

type
  EPluginHostError = class(Exception);

  TPluginRegistry = class;

  { --- 1 つの Plugin についての Core 側の記録 --- }
  TPluginSlot = class
  private
    FPlugin: TPluginBase;
    FOwnsPlugin: Boolean;
    { Plugin はこれを Initialize で受け取って保持する。よって枠と同じ
      寿命でなければならない。登録直後に解放すると解放後参照になる。 }
    FContext: TObject;
    FDescriptor: TPluginDescriptor;
    FNegotiation: TNegotiationResult;
    FEnabled: Boolean;
    FQuarantined: Boolean;
    FConsecutiveFaults: Integer;
    FTotalFaults: Int64;
    FTotalCalls: Int64;
    FLastFault: string;
  public
    property Plugin: TPluginBase read FPlugin;
    property Descriptor: TPluginDescriptor read FDescriptor;
    property Negotiation: TNegotiationResult read FNegotiation;
    { 運用者が切った状態。隔離とは別に扱う (理由が違うので混ぜない)。 }
    property Enabled: Boolean read FEnabled write FEnabled;
    { 障害が続いたので Core が切った状態。 }
    property Quarantined: Boolean read FQuarantined;
    property ConsecutiveFaults: Integer read FConsecutiveFaults;
    property TotalFaults: Int64 read FTotalFaults;
    property TotalCalls: Int64 read FTotalCalls;
    property LastFault: string read FLastFault;
    function Id: string;
    function IsCallable: Boolean;
    function Describe: string;
  end;

  { --- Plugin から見た Core (RPC でいうスタブ) ---
    ここに置いてよいのは引数・戻り値がすべて値のメソッドだけ。
    Core のオブジェクトを返すメソッドを足した瞬間に別プロセス化できなくなる。 }
  TCorePluginHost = class(TPluginHostContext)
  private
    FRegistry: TPluginRegistry;
    FPluginId: string;
    FGranted: TPluginCapabilities;
  public
    constructor Create(ARegistry: TPluginRegistry; const APluginId: string;
      AGranted: TPluginCapabilities);
    function ApiVersion: TApiVersion; override;
    procedure Log(ALevel: TPluginLogLevel; const AText: string); override;
    procedure Publish(const AMsg: TPluginMessage); override;
    function GetSetting(const AKey, ADefault: string): string; override;
    function HasCapability(ACap: TPluginCapability): Boolean; override;
    property PluginId: string read FPluginId;
  end;

  { 設定の読み出しを Core から差し込むための口。
    Plugin ごとに名前空間が切られた状態で呼ばれる。 }
  TPluginSettingReader = function(const APluginId, AKey,
    ADefault: string): string of object;

  { --- 登録簿 ---
    Plugin への呼び出しはすべてここを通す。 }
  TPluginRegistry = class
  private
    FLock: TCriticalSection;
    FSlots: array of TPluginSlot;
    FBus: TEventBus;
    FObs: TObsRegistry;
    FCallMetric: TObsMetric;
    FFaultLimit: Integer;
    FCallBudgetSec: Double;
    FSettingReader: TPluginSettingReader;
    FHostCaps: TPluginCapabilities;
    FHostApi: TApiVersion;
    FRejectedCount: Integer;
    function IndexOfId(const AId: string): Integer;
    { 関門の共通処理。呼び出し可能かを見て、時刻を返す。 }
    function BeginCall(ASlot: TPluginSlot; out AT0: Double): Boolean;
    procedure EndCallOk(ASlot: TPluginSlot; AT0: Double);
    procedure EndCallFault(ASlot: TPluginSlot; const AWhat, AMessage: string);
    procedure NoteFault(ASlot: TPluginSlot; const AWhat, AMessage: string);
    procedure NoteSuccess(ASlot: TPluginSlot);
    procedure Record_(ASeverity: TObsSeverity; ACode: TObsCode;
      const ASource: string; AI1: Int64 = 0; AD1: Double = 0);
  public
    constructor Create(ABus: TEventBus = nil; AObs: TObsRegistry = nil);
    destructor Destroy; override;

    { --- 受け入れ (§11.1 Capability Negotiation) ---
      交渉が成立しなければ受け入れず、理由を返す。
      AOwnsPlugin=True なら破棄も引き受ける。
      戻り値: 受け入れた場合はその枠、断った場合は nil。 }
    function Register(APlugin: TPluginBase; AOwnsPlugin: Boolean;
      out AResult: TNegotiationResult): TPluginSlot;

    { --- 呼び出しの関門 (§11.1 障害の非波及) ---
      Plugin のメソッドを直接呼んでよいのはこの 3 つの中だけである。
      ほかの場所から slot.Plugin.XXX を呼ぶと、例外がそこから漏れて
      隔離も記録も働かない。

      3 つに分かれているのは Pascal に閉包が無いためで、意図としては
      1 つの関門である。失敗の数え方・時間の測り方は BeginCall /
      EndCallOk / EndCallFault に集約してあるので、増やすときも
      その 3 つを使うこと。 }
    function SafeInitialize(ASlot: TPluginSlot): Boolean;
    function SafeShutdown(ASlot: TPluginSlot): Boolean;
    function SafeHandle(ASlot: TPluginSlot; const AMsg: TPluginMessage;
      out AReply: TPluginMessage; out AHandled: Boolean): Boolean;

    { verb を扱うすべての Plugin へ配る。登録順で、途中で 1 つが
      失敗しても残りには届く。戻り値: 処理した Plugin の数。 }
    function DispatchMessage(const AMsg: TPluginMessage): Integer;
    { 最初に処理した Plugin の返信を取る。戻り値: 誰かが処理したか。 }
    function Request(const AMsg: TPluginMessage;
      out AReply: TPluginMessage): Boolean;

    procedure ShutdownAll;

    { 隔離を解除する (運用者の操作を想定)。失敗の数え直しも行う。 }
    function Revive(const AId: string): Boolean;

    function Count: Integer;
    function SlotAt(AIndex: Integer): TPluginSlot;
    function Find(const AId: string): TPluginSlot;
    function CallableCount: Integer;
    function QuarantinedCount: Integer;
    { 状態を人が読める形で (障害報告に貼れる形)。 }
    function Describe: string;

    property FaultLimit: Integer read FFaultLimit write FFaultLimit;
    property CallBudgetSec: Double read FCallBudgetSec write FCallBudgetSec;
    property SettingReader: TPluginSettingReader
      read FSettingReader write FSettingReader;
    { 受け入れなかった件数。0 でないことに気づけるようにしておく。 }
    property RejectedCount: Integer read FRejectedCount;
    property HostCapabilities: TPluginCapabilities read FHostCaps;
    property Bus: TEventBus read FBus;
  end;

implementation

const
  PLUGIN_LOG_PREFIX: array[TPluginLogLevel] of string =
    ('[trace] ', '[info] ', '[warn] ', '[error] ');

function ClampPluginText(const A: string): string;
begin
  { Control Plane に大きなものを流させない (ADR-001)。 }
  if Length(A) <= MAX_PLUGIN_EVENT_TEXT then
    Result := A
  else
    Result := Copy(A, 1, MAX_PLUGIN_EVENT_TEXT) + '...(切り詰め)';
end;

{ ============================ TPluginSlot ============================ }

function TPluginSlot.Id: string;
begin
  Result := FDescriptor.Id;
end;

function TPluginSlot.IsCallable: Boolean;
begin
  Result := FEnabled and not FQuarantined and (FPlugin <> nil);
end;

function TPluginSlot.Describe: string;
var
  state: string;
begin
  if FQuarantined then
    state := '隔離'
  else if not FEnabled then
    state := '停止'
  else
    state := '有効';
  Result := Format('%s [%s] 呼出=%d 失敗=%d', [
    FDescriptor.Describe, state, FTotalCalls, FTotalFaults]);
  if FLastFault <> '' then
    Result := Result + ' 直近の失敗=' + FLastFault;
end;

{ ============================ TCorePluginHost ============================ }

constructor TCorePluginHost.Create(ARegistry: TPluginRegistry;
  const APluginId: string; AGranted: TPluginCapabilities);
begin
  inherited Create;
  FRegistry := ARegistry;
  FPluginId := APluginId;
  FGranted := AGranted;
end;

function TCorePluginHost.ApiVersion: TApiVersion;
begin
  Result := HostApiVersion;
end;

procedure TCorePluginHost.Log(ALevel: TPluginLogLevel; const AText: string);
const
  MAP: array[TPluginLogLevel] of TObsSeverity =
    (obsTrace, obsInfo, obsWarning, obsError);
begin
  if FRegistry = nil then Exit;

  { TObsRecord は確保しないために固定長で、本文を持てない (ADR-010)。
    そこで二手に分ける ── 重み・発生元・件数は観測へ、本文は Control
    Plane のテキストイベントへ。どちらも既にある経路なので、Plugin の
    ために新しい記録先を作らずに済む。

    発生元はどちらも Plugin の Id に固定する。名乗らせない。 }
  FRegistry.Record_(MAP[ALevel], ocdStatus, FPluginId, Ord(ALevel));

  if (FRegistry.FBus <> nil) and (Trim(AText) <> '') then
    FRegistry.FBus.PublishText(bekStatusText,
      PLUGIN_LOG_PREFIX[ALevel] + ClampPluginText(AText), FPluginId);
end;

procedure TCorePluginHost.Publish(const AMsg: TPluginMessage);
var
  ev: TBusEvent;
begin
  if (FRegistry = nil) or (FRegistry.FBus = nil) then Exit;

  { Plugin が出せるのは汎用の通知だけ。Core 固有の種別 (復調やリグ) を
    名乗らせない。なりすまされると記録が信用できなくなる。 }
  FillChar(ev, SizeOf(ev), 0);
  ev.Kind := bekStatusText;
  ev.TimestampUtc := Now;
  { 発行元は Plugin の Id で上書きする。ここが要点。 }
  ev.Source := FPluginId;

  ev.Text := ClampPluginText(AMsg.Describe);

  FRegistry.FBus.Publish(ev);
end;

function TCorePluginHost.GetSetting(const AKey, ADefault: string): string;
begin
  Result := ADefault;
  if (FRegistry <> nil) and Assigned(FRegistry.FSettingReader) then
    { 名前空間は Plugin の Id。他の Plugin や Core の設定は読めない。 }
    Result := FRegistry.FSettingReader(FPluginId, AKey, ADefault);
end;

function TCorePluginHost.HasCapability(ACap: TPluginCapability): Boolean;
begin
  { 交渉で許可されたものだけ。申告しただけでは使えない。 }
  Result := ACap in FGranted;
end;

{ ============================ TPluginRegistry ============================ }

constructor TPluginRegistry.Create(ABus: TEventBus; AObs: TObsRegistry);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBus := ABus;
  FObs := AObs;
  FFaultLimit := DEFAULT_FAULT_LIMIT;
  FCallBudgetSec := DEFAULT_CALL_BUDGET_SEC;
  FHostCaps := HOST_CAPABILITIES;
  FHostApi := HostApiVersion;
  if FObs <> nil then
    FCallMetric := FObs.Metric('plugin.call', 's', FCallBudgetSec);
end;

destructor TPluginRegistry.Destroy;
var
  i: Integer;
begin
  ShutdownAll;
  for i := 0 to High(FSlots) do
  begin
    if FSlots[i].FOwnsPlugin then
      FSlots[i].FPlugin.Free;
    FSlots[i].FContext.Free;
    FSlots[i].Free;
  end;
  SetLength(FSlots, 0);
  FLock.Free;
  inherited Destroy;
end;

procedure TPluginRegistry.Record_(ASeverity: TObsSeverity; ACode: TObsCode;
  const ASource: string; AI1: Int64; AD1: Double);
begin
  if FObs <> nil then
    FObs.Log.Add(ASeverity, ocatPlugin, ACode, ASource, AI1, 0, AD1, 0);
end;

function TPluginRegistry.IndexOfId(const AId: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FSlots) do
    if SameText(FSlots[i].FDescriptor.Id, AId) then
      Exit(i);
  Result := -1;
end;

function TPluginRegistry.Register(APlugin: TPluginBase; AOwnsPlugin: Boolean;
  out AResult: TNegotiationResult): TPluginSlot;
var
  desc: TPluginDescriptor;
  slot: TPluginSlot;
  ctx: TCorePluginHost;
  n: Integer;
  ok: Boolean;
begin
  Result := nil;
  AResult.Outcome := negInvalidDescriptor;
  AResult.Granted := [];
  AResult.Missing := [];
  AResult.Reason := '';

  if APlugin = nil then
  begin
    AResult.Reason := 'Plugin が nil です。';
    Inc(FRejectedCount);
    Exit;
  end;

  { 自己申告を取るところも Plugin のコードである。ここで例外を投げられても
    Core が落ちてはいけない。 }
  ok := True;
  try
    desc := APlugin.Describe;
  except
    on E: Exception do
    begin
      ok := False;
      AResult.Reason := '自己申告 (Describe) が例外を投げました: ' + E.Message;
    end;
  end;
  if not ok then
  begin
    Inc(FRejectedCount);
    Record_(obsError, ocdPluginRejected, '(describe)');
    if AOwnsPlugin then APlugin.Free;
    Exit;
  end;

  AResult := NegotiateCapabilities(desc, FHostApi, FHostCaps);
  if not AResult.Accepted then
  begin
    Inc(FRejectedCount);
    Record_(obsWarning, ocdPluginRejected, desc.Id, Ord(AResult.Outcome));
    if AOwnsPlugin then APlugin.Free;
    Exit;
  end;

  FLock.Acquire;
  try
    if IndexOfId(desc.Id) >= 0 then
    begin
      AResult.Outcome := negInvalidDescriptor;
      AResult.Reason := Format('%s: 同じ Id が既に登録されています。',
        [desc.Id]);
      Inc(FRejectedCount);
      Record_(obsWarning, ocdPluginRejected, desc.Id);
      if AOwnsPlugin then APlugin.Free;
      Exit(nil);
    end;

    slot := TPluginSlot.Create;
    slot.FPlugin := APlugin;
    slot.FOwnsPlugin := AOwnsPlugin;
    slot.FDescriptor := desc;
    slot.FNegotiation := AResult;
    slot.FEnabled := True;
    slot.FQuarantined := False;

    n := Length(FSlots);
    SetLength(FSlots, n + 1);
    FSlots[n] := slot;
  finally
    FLock.Release;
  end;

  { Plugin はこの窓口を保持する。よって枠が持ち、枠と一緒に解放する。
    ここで解放すると Plugin が解放済みの参照を握ることになる。 }
  ctx := TCorePluginHost.Create(Self, desc.Id, AResult.Granted);
  slot.FContext := ctx;

  { 初期化も Plugin のコードなので関門を通す。失敗しても登録は残す
    ── 黙って消えるより、状態が見えるほうが診断しやすい。
    ただし初期化に失敗したものは呼ばない。 }
  SafeInitialize(slot);

  Record_(obsInfo, ocdPluginLoaded, desc.Id, Ord(desc.Kind));
  Result := slot;
end;

function TPluginRegistry.BeginCall(ASlot: TPluginSlot;
  out AT0: Double): Boolean;
begin
  AT0 := 0;
  if (ASlot = nil) or not ASlot.IsCallable then Exit(False);
  Inc(ASlot.FTotalCalls);
  AT0 := ObsHiResSeconds;
  Result := True;
end;

procedure TPluginRegistry.EndCallOk(ASlot: TPluginSlot; AT0: Double);
var
  dt: Double;
begin
  dt := ObsHiResSeconds - AT0;
  if FCallMetric <> nil then
    FCallMetric.Observe(dt);
  if (FCallBudgetSec > 0) and (dt > FCallBudgetSec) then
    { 同一プロセスでは止められない。測って記録するだけである
      (ユニット冒頭の注を参照)。 }
    Record_(obsWarning, ocdPluginSlow, ASlot.Id, 0, dt);
  NoteSuccess(ASlot);
end;

procedure TPluginRegistry.EndCallFault(ASlot: TPluginSlot;
  const AWhat, AMessage: string);
begin
  NoteFault(ASlot, AWhat, AMessage);
end;

function TPluginRegistry.SafeInitialize(ASlot: TPluginSlot): Boolean;
var
  t0: Double;
begin
  Result := False;
  if not BeginCall(ASlot, t0) then Exit;
  try
    ASlot.FPlugin.Initialize(TPluginHostContext(ASlot.FContext));
  except
    on E: Exception do
    begin
      EndCallFault(ASlot, 'Initialize', E.ClassName + ': ' + E.Message);
      { 初期化に失敗したものは呼ばない。半端な状態の Plugin を呼ぶと
        次の失敗の原因が初期化なのか処理なのか分からなくなる。 }
      ASlot.FQuarantined := True;
      Record_(obsError, ocdPluginQuarantined, ASlot.Id, ASlot.FTotalFaults);
      Exit(False);
    end;
  end;
  EndCallOk(ASlot, t0);
  Result := True;
end;

function TPluginRegistry.SafeShutdown(ASlot: TPluginSlot): Boolean;
var
  t0: Double;
begin
  Result := False;
  { 終了処理は隔離されたものにも行う。確保した資源を返させるため。 }
  if (ASlot = nil) or (ASlot.FPlugin = nil) then Exit;
  t0 := ObsHiResSeconds;
  Inc(ASlot.FTotalCalls);
  try
    ASlot.FPlugin.Shutdown;
  except
    on E: Exception do
    begin
      EndCallFault(ASlot, 'Shutdown', E.ClassName + ': ' + E.Message);
      Exit(False);
    end;
  end;
  EndCallOk(ASlot, t0);
  Result := True;
end;

function TPluginRegistry.SafeHandle(ASlot: TPluginSlot;
  const AMsg: TPluginMessage; out AReply: TPluginMessage;
  out AHandled: Boolean): Boolean;
var
  t0: Double;
begin
  AReply.Init('');
  AHandled := False;
  Result := False;
  if not BeginCall(ASlot, t0) then Exit;
  try
    { Handles も Plugin のコードなので、同じ try の中で呼ぶ。
      外に出すと「どの verb を扱うか」を答える最中の例外が漏れる。 }
    if ASlot.FPlugin.Handles(AMsg.Verb) then
      AHandled := ASlot.FPlugin.Handle(AMsg, AReply);
  except
    on E: Exception do
    begin
      EndCallFault(ASlot, 'Handle(' + AMsg.Verb + ')',
        E.ClassName + ': ' + E.Message);
      AHandled := False;
      Exit(False);
    end;
  end;
  EndCallOk(ASlot, t0);
  Result := True;
end;

procedure TPluginRegistry.NoteFault(ASlot: TPluginSlot;
  const AWhat, AMessage: string);
begin
  Inc(ASlot.FConsecutiveFaults);
  Inc(ASlot.FTotalFaults);
  ASlot.FLastFault := AWhat + ' -> ' + AMessage;
  Record_(obsError, ocdPluginFault, ASlot.Id, ASlot.FConsecutiveFaults);

  if (FFaultLimit > 0) and (ASlot.FConsecutiveFaults >= FFaultLimit) then
  begin
    ASlot.FQuarantined := True;
    Record_(obsError, ocdPluginQuarantined, ASlot.Id, ASlot.FTotalFaults);
  end;
end;

procedure TPluginRegistry.NoteSuccess(ASlot: TPluginSlot);
begin
  { 成功したら数え直す。「連続して」失敗したときだけ切るため。 }
  ASlot.FConsecutiveFaults := 0;
end;

function TPluginRegistry.DispatchMessage(const AMsg: TPluginMessage): Integer;
var
  i: Integer;
  slot: TPluginSlot;
  reply: TPluginMessage;
  handled: Boolean;
begin
  Result := 0;
  { 登録順で配る。順序が安定していないと、同じ入力で結果が変わりうる (Z-05)。 }
  for i := 0 to High(FSlots) do
  begin
    slot := FSlots[i];
    if not slot.IsCallable then Continue;
    { 1 つが失敗しても次へ進む。ここが波及を止める要点である。 }
    if SafeHandle(slot, AMsg, reply, handled) and handled then
      Inc(Result);
  end;
end;

function TPluginRegistry.Request(const AMsg: TPluginMessage;
  out AReply: TPluginMessage): Boolean;
var
  i: Integer;
  slot: TPluginSlot;
  reply: TPluginMessage;
  handled: Boolean;
begin
  Result := False;
  AReply.Init('');
  for i := 0 to High(FSlots) do
  begin
    slot := FSlots[i];
    if not slot.IsCallable then Continue;
    if SafeHandle(slot, AMsg, reply, handled) and handled then
    begin
      AReply := reply;
      Exit(True);
    end;
  end;
end;

procedure TPluginRegistry.ShutdownAll;
var
  i: Integer;
begin
  { 終了処理で例外を投げる Plugin があっても、残りの終了処理は行う。 }
  for i := 0 to High(FSlots) do
    SafeShutdown(FSlots[i]);
end;

function TPluginRegistry.Revive(const AId: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  i := IndexOfId(AId);
  if i < 0 then Exit;
  FSlots[i].FQuarantined := False;
  FSlots[i].FConsecutiveFaults := 0;
  Result := True;
end;

function TPluginRegistry.Count: Integer;
begin
  Result := Length(FSlots);
end;

function TPluginRegistry.SlotAt(AIndex: Integer): TPluginSlot;
begin
  if (AIndex < 0) or (AIndex > High(FSlots)) then
    raise EPluginHostError.CreateFmt(
      'Plugin の添字が範囲外です (要求 %d / 件数 %d)',
      [AIndex, Length(FSlots)]);
  Result := FSlots[AIndex];
end;

function TPluginRegistry.Find(const AId: string): TPluginSlot;
var
  i: Integer;
begin
  Result := nil;
  i := IndexOfId(AId);
  if i >= 0 then
    Result := FSlots[i];
end;

function TPluginRegistry.CallableCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FSlots) do
    if FSlots[i].IsCallable then Inc(Result);
end;

function TPluginRegistry.QuarantinedCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FSlots) do
    if FSlots[i].Quarantined then Inc(Result);
end;

function TPluginRegistry.Describe: string;
var
  i: Integer;
begin
  Result := Format('Host API %s / 登録 %d 件 (呼出可 %d / 隔離 %d / 不受理 %d)',
    [FHostApi.ToStr, Count, CallableCount, QuarantinedCount, FRejectedCount]);
  for i := 0 to High(FSlots) do
    Result := Result + LineEnding + '  ' + FSlots[i].Describe;
end;

end.
