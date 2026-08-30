{ ============================================================================
  PluginApi.pas

  Architecture & Requirements Baseline v1.1 §11 Extension Platform の
  Plugin API 草案 (Phase 0 の成果物 "Plugin API draft")。

  このユニットは **Plugin 作者がコンパイル対象にする境界** である。
  Core 側の実装 (PluginHost.pas) には依存しない。依存が逆向きに付いて
  いないことが、後で Plugin を別プロセスへ出せるかどうかを決める。

  §11.1 が課している原則は 5 つある。どれをどう受けたかを先に書く。
  ----------------------------------------------------------------------------
  | 原則                                    | この草案での受け方              |
  |----------------------------------------|--------------------------------|
  | Semantic Versioning を前提とする         | TApiVersion。0.x の間は MINOR   |
  |                                        | 一致を要求する (下の注を参照)    |
  | Capability Negotiation で機能差を扱う    | Provides / Requires の二方向。   |
  |                                        | 知らない capability で落ちない   |
  | API は将来のサブプロセス化・Sandbox 化を | 境界を越えるものはすべて値。      |
  | 妨げない                                | TPluginMessage は平坦なバイト列  |
  |                                        | に往復できる (test で固定)       |
  | Plugin 障害を Core や他 Plugin へ       | 呼び出しはすべて Host 側の関門を |
  | 波及させない                            | 通す (PluginHost.pas)           |
  | 外部 Modem Plugin は Test vectors 必須   | 登録時に pcTestVectors を要求    |

  「サブプロセス化を妨げない」を実際に守るには
  ----------------------------------------------------------------------------
  この原則は宣言しただけでは守られない。守られていないことに気づけない
  からである。破り方は決まっていて、境界を越える型に

    - Core のドメインオブジェクトへの参照 (TQsoEntry, TModem, TEventBus)
    - ポインタ、ファイルハンドル、クロージャ
    - 直列化できないもの

  のどれかが混ざった瞬間に、二度と別プロセスへ出せなくなる。
  そこでこの草案では、境界を越える型を **バイト列に往復できること** で
  定義した。EncodeMessage / DecodeMessage がその往復であり、
  test_plugin がすべての境界型について往復を固定している。
  誰かが将来 TPluginMessage にオブジェクト参照を足せば、その test が落ちる。

  TPluginHostContext だけはクラス参照で渡る。これは例外ではなく、
  RPC でいうスタブに当たる。別プロセス化したときは同じ宣言の
  「向こう側へ中継する実装」に差し替わる。したがってここに置いてよいのは
  **引数と戻り値がすべて値である** メソッドだけである。

  Data Plane はここを通らない
  ----------------------------------------------------------------------------
  ADR-001 のとおり、音声/IQ/スペクトラムはメッセージにしない。
  Modem Plugin の波形の受け渡しは TModemPluginBase.ProcessBlock で行い、
  「渡された配列は呼び出しの間だけ有効。保持してはならない」という規約に
  する。この規約があるから、別プロセス化のときに共有メモリのリングへ
  置き換えられる。メッセージにしてしまうと置き換えられない。

  Phase 5 との関係
  ----------------------------------------------------------------------------
  Phase 5 は "Stable Plugin API" である。本ユニットは draft なので
  API バージョンは 0.x で始まる。動的ライブラリの読み込みはまだ行わない
  (Phase 5 の Modem Plugin SDK の仕事)。いま決めておくのは「何が境界を
  越えるか」であって、「どうやって読み込むか」ではない。
  ============================================================================ }
unit PluginApi;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils;

const
  { --- Host API のバージョン (§11.1 / ADR-004) ---
    Phase 0 の draft なので 0.x。Phase 5 で "Stable Plugin API" として
    1.0.0 にする。 }
  HOST_API_MAJOR = 0;
  HOST_API_MINOR = 1;
  HOST_API_PATCH = 0;

type
  EPluginApiError = class(Exception);

  { --- Semantic Versioning (§11.1 / ADR-004) --- }
  TApiVersion = record
    Major, Minor, Patch: Integer;
    function ToStr: string;
    { Plugin が要求するバージョン (Self) を、この Host (AHost) が
      満たせるか。

      SemVer の素直な読みに従う:
        - MAJOR が違えば非互換。
        - MAJOR >= 1 なら、Host の MINOR が要求以上であればよい
          (MINOR の増加は後方互換な追加であるため)。
        - MAJOR = 0 は「不安定」を意味し、MINOR の増加でも壊れてよい。
          よって MINOR の一致を要求する。

      0.x を緩く扱うと、draft の間に何を変えても互換だと言えてしまい、
      SemVer を前提にした意味が無くなる。 }
    function IsSatisfiedBy(const AHost: TApiVersion): Boolean;
  end;

  { --- Plugin の種別 (§11 の表) --- }
  TPluginKind = (
    pkUnknown,
    pkModem,          // RX/TX, Detector, Soft metrics, Replay, Test vectors
    pkContest,        // Rules, Exchange, Dupe, Multiplier, Score, Cabrillo
    pkAward,          // Rule, Entity 判定, Progress 計算
    pkQslProvider,    // Confirmation 送受信・状態同期
    pkCloudLog,       // QSO upload/download, 同期, 競合処理
    pkLocalAdapter,   // 外部 Logger / Contest / CAT アプリ連携
    pkUiExtension,    // 追加 Panel や表示機能
    pkDataProvider    // 外部データソース連携
  );

  { --- Plugin の出所 ---
    §11.1 の「外部 Modem Plugin は Test vectors を必須提供する」は
    外部にだけかかる規則なので、区別できるようにしておく。 }
  TPluginOrigin = (poBuiltIn, poExternal);

  { --- Capability (§11.1) ---
    §11.1 の Example capabilities を含む。名前は同じ snake_case を使う
    (外部の宣言ファイルにそのまま書ける形にしておくため)。

    閉じた列挙にしているのは、Core が「意味を知っている」ものを型で
    示すためである。知らない capability は落とさず TPluginDescriptor の
    UnknownCapabilities に文字列のまま残す。これが無いと、新しい Core
    向けに書かれた Plugin が古い Core で読み込めなくなる。 }
  TPluginCapability = (
    { §11.1 に明記されているもの }
    pcSoftMetrics,      // supports_soft_metrics
    pcReplay,           // supports_replay
    pcTx,               // supports_tx
    pcAutoDetection,    // supports_auto_detection
    pcMultiCandidate,   // supports_multi_candidate
    { §11 の責務表から導かれるもの }
    pcTestVectors,      // supports_test_vectors  (§11.1 で Modem に必須)
    pcDupeCheck,        // supports_dupe_check    (Contest)
    pcMultiplier,       // supports_multiplier    (Contest)
    pcCabrillo,         // supports_cabrillo      (Contest)
    pcAwardProgress,    // supports_award_progress(Award)
    pcUpload,           // supports_upload        (QSL / Cloud Log)
    pcDownload,         // supports_download      (Cloud Log)
    pcOfflineQueue,     // supports_offline_queue (§13.3 Eventual Sync)
    pcLookup,           // supports_lookup        (Data Provider)
    pcUiPanel           // supports_ui_panel      (UI Extension)
  );
  TPluginCapabilities = set of TPluginCapability;

  { --- 境界を越える値 ---
    ここに参照型を足してはならない。足すと別プロセス化できなくなる。 }
  TPluginValueKind = (pvNone, pvBool, pvInt, pvFloat, pvText);

  TPluginValue = record
    Kind: TPluginValueKind;
    I: Int64;        // pvInt / pvBool (0 or 1)
    F: Double;       // pvFloat
    S: string;       // pvText
    function AsBool: Boolean;
    function AsInt: Int64;
    function AsFloat: Double;
    function AsText: string;
    function Describe: string;
  end;

  TPluginArg = record
    Name: string;
    Value: TPluginValue;
  end;

  { --- 境界を越えるメッセージ ---
    引数を「名前つき」にしてあるのは SemVer のためである。位置引数は
    増やすと破壊的変更になるが、名前つきなら引数の追加は MINOR で済む。
    知らない名前の引数は無視するのが受け側の規約。 }
  TPluginMessage = record
    Verb: string;
    Args: array of TPluginArg;

    procedure Init(const AVerb: string);
    procedure PutBool(const AName: string; AValue: Boolean);
    procedure PutInt(const AName: string; AValue: Int64);
    procedure PutFloat(const AName: string; AValue: Double);
    procedure PutText(const AName, AValue: string);
    function Has(const AName: string): Boolean;
    function Get(const AName: string): TPluginValue;
    function ArgCount: Integer;
    function Describe: string;
  end;

  { --- Plugin の自己申告 --- }
  TPluginDescriptor = record
    Id: string;             // 一意な識別子 ('jp.ji1uui.rtty' 等)
    DisplayName: string;
    Author: string;
    Version: TApiVersion;         // Plugin 自身の版
    RequiredHostApi: TApiVersion; // 必要とする Host API の版
    Kind: TPluginKind;
    Origin: TPluginOrigin;
    { この Plugin ができること。Core が「この Modem は送信できるか」等を
      判断するのに使う。Plugin 自身に返すものではない。 }
    Provides: TPluginCapabilities;
    { Host に **必須** で求めるもの。1 つでも無ければ受け入れない。 }
    Requires: TPluginCapabilities;
    { Host にあれば使うが、無くても動けるもの。
      これが Capability Negotiation の本体である ── 「機能差を扱う」とは、
      無いときに落ちるのではなく、無いなりに動けるようにすることを指す。 }
    Wants: TPluginCapabilities;
    { Core が意味を知らない capability 名。落とさずここに残す。 }
    UnknownCapabilities: array of string;

    procedure Init(const AId: string; AKind: TPluginKind);
    function Describe: string;
  end;

  { --- 交渉の結果 (§11.1 Capability Negotiation) --- }
  TNegotiationOutcome = (
    negAccepted,
    negApiIncompatible,     // Host API の版が合わない
    negMissingCapability,   // Host に無いものを Requires している
    negMissingTestVectors,  // 外部 Modem なのに Test vectors が無い
    negInvalidDescriptor    // Id が空、種別不明など
  );

  TNegotiationResult = record
    Outcome: TNegotiationOutcome;
    { Plugin が **Host から** 実際に使ってよい機能。
      (Requires + Wants) と Host が持つものの積。
      Plugin 側はこれを見て、無い機能を避けた動き方を選ぶ。 }
    Granted: TPluginCapabilities;
    Missing: TPluginCapabilities;   // Requires のうち Host に無いもの
    Reason: string;                 // 人が読める理由
    function Accepted: Boolean;
  end;

  { --- Log の重み (Host へ送る用) --- }
  TPluginLogLevel = (pllTrace, pllInfo, pllWarning, pllError);

  { --- Host が Plugin に渡す唯一の窓口 ---
    RPC のスタブに当たる。ここに置いてよいのは引数・戻り値がすべて値の
    メソッドだけである。Core のオブジェクトを返すメソッドを足した瞬間に
    別プロセス化できなくなる。 }
  TPluginHostContext = class
  public
    function ApiVersion: TApiVersion; virtual; abstract;
    { Core の記録へ流す。Plugin 側で独自にファイルを開かせない
      (Sandbox 化したときに書けなくなるため)。 }
    procedure Log(ALevel: TPluginLogLevel; const AText: string);
      virtual; abstract;
    { Control Plane への発行。ADR-001 のとおり高頻度ストリームは流さない。 }
    procedure Publish(const AMsg: TPluginMessage); virtual; abstract;
    { 設定の読み出し。Plugin ごとに名前空間が切られる。 }
    function GetSetting(const AKey, ADefault: string): string;
      virtual; abstract;
    { この Host がその機能を提供していて、かつ自分が使ってよいことに
      なっているか。Wants に挙げた機能はここで有無を確かめてから使う。
      「自分が何を Provides しているか」を聞く口ではない ── それは
      Plugin 自身が知っていることで、Host に聞く意味が無い。 }
    function HasCapability(ACap: TPluginCapability): Boolean;
      virtual; abstract;
  end;

  { --- Plugin が実装する側 ---
    例外を投げてよい。Host 側が関門で受け止める (§11.1 障害の非波及)。
    ただし投げ続ければ隔離される。 }
  TPluginBase = class
  private
    FHost: TPluginHostContext;
  protected
    property Host: TPluginHostContext read FHost;
  public
    { 自己申告。副作用を持たせないこと (登録前に呼ばれる)。 }
    function Describe: TPluginDescriptor; virtual; abstract;

    procedure Initialize(AHost: TPluginHostContext); virtual;
    procedure Shutdown; virtual;

    { この verb を扱うか。扱わないものは呼ばれない。 }
    function Handles(const AVerb: string): Boolean; virtual;
    { 本体。処理したら True。AReply は処理しなかった場合は未定義。 }
    function Handle(const AMsg: TPluginMessage;
      out AReply: TPluginMessage): Boolean; virtual;
  end;

  { --- Modem Plugin の Data Plane 規約 (ADR-001 / ADR-005) ---
    波形はメッセージにしない。ProcessBlock に渡す配列は
    **呼び出しの間だけ有効** で、Plugin は保持してはならない。

    この規約があるから、別プロセス化のときに共有メモリのリングへ
    置き換えられる。保持を許すと置き換えられない。

    中身は Phase 2 で詰める (RTTY を Plugin API 準拠で実装する時)。
    ここでは境界の形だけ決めておく。 }
  TModemPluginBase = class(TPluginBase)
  public
    { ASamples[0..ACount-1] は呼び出しの間だけ有効。保持禁止。 }
    procedure ProcessBlock(const ASamples: array of Double;
      ACount: Integer); virtual; abstract;
    function SampleRate: Double; virtual; abstract;
  end;

const
  { --- Core がいま提供している capability ---
    Plugin が Requires に挙げたものがここに無ければ受け入れない。
    実装が追いついたら足す。空手形を並べないこと (「あることになって
    いるが動かない」は、無いより悪い)。 }
  HOST_CAPABILITIES: TPluginCapabilities = [
    pcSoftMetrics,      // DecodeEvidence (ADR-002)
    pcMultiCandidate,   // DecodeEvidence の候補列 (ADR-002)
    pcTx,               // TModem の送信経路
    pcOfflineQueue      // TQsoStore の Revision / Sync (ADR-011)
  ];

  PLUGIN_KIND_NAMES: array[TPluginKind] of string = (
    'unknown', 'modem', 'contest', 'award', 'qsl_provider',
    'cloud_log', 'local_adapter', 'ui_extension', 'data_provider');

  PLUGIN_CAPABILITY_NAMES: array[TPluginCapability] of string = (
    'supports_soft_metrics', 'supports_replay', 'supports_tx',
    'supports_auto_detection', 'supports_multi_candidate',
    'supports_test_vectors', 'supports_dupe_check', 'supports_multiplier',
    'supports_cabrillo', 'supports_award_progress', 'supports_upload',
    'supports_download', 'supports_offline_queue', 'supports_lookup',
    'supports_ui_panel');

function MakeVersion(AMajor, AMinor, APatch: Integer): TApiVersion;
function HostApiVersion: TApiVersion;
function ParseVersion(const A: string; out AVersion: TApiVersion): Boolean;

function PluginKindToStr(A: TPluginKind): string;
function StrToPluginKind(const A: string): TPluginKind;
function CapabilityToStr(A: TPluginCapability): string;
{ 知らない名前なら False。呼び出し側はそれを捨てずに残すこと。 }
function StrToCapability(const A: string; out ACap: TPluginCapability): Boolean;
function CapabilitiesToStr(A: TPluginCapabilities): string;

{ --- 交渉 (§11.1) ---
  Host が提供する capability と Plugin の申告を突き合わせる。
  副作用は無い。受け入れるかどうかの判断だけを行う。 }
function NegotiateCapabilities(const ADesc: TPluginDescriptor;
  const AHostApi: TApiVersion;
  AHostCaps: TPluginCapabilities): TNegotiationResult;

{ --- 直列化 (ADR-005) ---
  「別プロセス化を妨げない」を検証可能にするための往復。
  境界を越える型はすべてこれを通せなければならない。 }
function EncodeMessage(const AMsg: TPluginMessage): TBytes;
function DecodeMessage(const ABytes: TBytes; out AMsg: TPluginMessage): Boolean;
function EncodeDescriptor(const ADesc: TPluginDescriptor): TBytes;
function DecodeDescriptor(const ABytes: TBytes;
  out ADesc: TPluginDescriptor): Boolean;

implementation

const
  { 直列化の壊れた入力で無制限に確保しないための上限。
    別プロセス化したときは、向こう側が信用できない入力元になる。 }
  MAX_WIRE_STRING = 1 shl 20;   // 1 MiB
  MAX_WIRE_ARGS   = 4096;
  WIRE_MSG_MAGIC  = $504D;      // 'PM'
  WIRE_DSC_MAGIC  = $5044;      // 'PD'

{ ============================ TApiVersion ============================ }

function MakeVersion(AMajor, AMinor, APatch: Integer): TApiVersion;
begin
  Result.Major := AMajor;
  Result.Minor := AMinor;
  Result.Patch := APatch;
end;

function HostApiVersion: TApiVersion;
begin
  Result := MakeVersion(HOST_API_MAJOR, HOST_API_MINOR, HOST_API_PATCH);
end;

function ParseVersion(const A: string; out AVersion: TApiVersion): Boolean;
var
  parts: TStringArray;
begin
  Result := False;
  AVersion := MakeVersion(0, 0, 0);
  parts := Trim(A).Split(['.']);
  if Length(parts) <> 3 then Exit;
  if not TryStrToInt(parts[0], AVersion.Major) then Exit;
  if not TryStrToInt(parts[1], AVersion.Minor) then Exit;
  if not TryStrToInt(parts[2], AVersion.Patch) then Exit;
  Result := (AVersion.Major >= 0) and (AVersion.Minor >= 0) and
            (AVersion.Patch >= 0);
end;

function TApiVersion.ToStr: string;
begin
  Result := Format('%d.%d.%d', [Major, Minor, Patch]);
end;

function TApiVersion.IsSatisfiedBy(const AHost: TApiVersion): Boolean;
begin
  if Major <> AHost.Major then Exit(False);
  if Major = 0 then
    { 0.x は不安定。MINOR の増加で壊れてよい規約なので一致を要求する。 }
    Result := Minor = AHost.Minor
  else
    Result := AHost.Minor >= Minor;
end;

{ ============================ 名前の変換 ============================ }

function PluginKindToStr(A: TPluginKind): string;
begin
  Result := PLUGIN_KIND_NAMES[A];
end;

function StrToPluginKind(const A: string): TPluginKind;
var
  k: TPluginKind;
  t: string;
begin
  t := LowerCase(Trim(A));
  for k := Low(TPluginKind) to High(TPluginKind) do
    if PLUGIN_KIND_NAMES[k] = t then
      Exit(k);
  Result := pkUnknown;
end;

function CapabilityToStr(A: TPluginCapability): string;
begin
  Result := PLUGIN_CAPABILITY_NAMES[A];
end;

function StrToCapability(const A: string;
  out ACap: TPluginCapability): Boolean;
var
  c: TPluginCapability;
  t: string;
begin
  ACap := Low(TPluginCapability);
  t := LowerCase(Trim(A));
  for c := Low(TPluginCapability) to High(TPluginCapability) do
    if PLUGIN_CAPABILITY_NAMES[c] = t then
    begin
      ACap := c;
      Exit(True);
    end;
  Result := False;
end;

function CapabilitiesToStr(A: TPluginCapabilities): string;
var
  c: TPluginCapability;
begin
  Result := '';
  for c := Low(TPluginCapability) to High(TPluginCapability) do
    if c in A then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + PLUGIN_CAPABILITY_NAMES[c];
    end;
  if Result = '' then Result := '(なし)';
end;

{ ============================ TPluginValue ============================ }

function TPluginValue.AsBool: Boolean;
begin
  case Kind of
    pvBool, pvInt: Result := I <> 0;
    pvFloat:       Result := F <> 0;
    pvText:        Result := SameText(Trim(S), 'true') or (Trim(S) = '1');
  else
    Result := False;
  end;
end;

function TPluginValue.AsInt: Int64;
begin
  case Kind of
    pvBool, pvInt: Result := I;
    pvFloat:       Result := Round(F);
    pvText:        Result := StrToInt64Def(Trim(S), 0);
  else
    Result := 0;
  end;
end;

function TPluginValue.AsFloat: Double;
begin
  case Kind of
    pvBool, pvInt: Result := I;
    pvFloat:       Result := F;
    { ロケールに依らない読み方をする。'.' 固定。 }
    pvText:        if not TryStrToFloat(Trim(S), Result,
                          DefaultFormatSettings) then Result := 0;
  else
    Result := 0;
  end;
end;

function TPluginValue.AsText: string;
begin
  case Kind of
    pvBool:  if I <> 0 then Result := 'true' else Result := 'false';
    pvInt:   Result := IntToStr(I);
    pvFloat: Str(F, Result);   { ロケール非依存 }
    pvText:  Result := S;
  else
    Result := '';
  end;
end;

function TPluginValue.Describe: string;
begin
  case Kind of
    pvBool:  Result := 'bool:' + AsText;
    pvInt:   Result := 'int:' + AsText;
    pvFloat: Result := 'float:' + Trim(AsText);
    pvText:  Result := 'text:' + S;
  else
    Result := 'none';
  end;
end;

{ ============================ TPluginMessage ============================ }

procedure TPluginMessage.Init(const AVerb: string);
begin
  Verb := AVerb;
  SetLength(Args, 0);
end;

procedure AddArg(var AMsg: TPluginMessage; const AName: string;
  const AValue: TPluginValue);
var
  i, n: Integer;
begin
  { 同名は上書きする。位置ではなく名前で引く約束なので、
    同じ名前が 2 つあると受け側で結果が変わってしまう。 }
  for i := 0 to High(AMsg.Args) do
    if SameText(AMsg.Args[i].Name, AName) then
    begin
      AMsg.Args[i].Value := AValue;
      Exit;
    end;
  n := Length(AMsg.Args);
  SetLength(AMsg.Args, n + 1);
  AMsg.Args[n].Name := AName;
  AMsg.Args[n].Value := AValue;
end;

procedure TPluginMessage.PutBool(const AName: string; AValue: Boolean);
var
  v: TPluginValue;
begin
  v.Kind := pvBool; v.F := 0; v.S := '';
  if AValue then v.I := 1 else v.I := 0;
  AddArg(Self, AName, v);
end;

procedure TPluginMessage.PutInt(const AName: string; AValue: Int64);
var
  v: TPluginValue;
begin
  v.Kind := pvInt; v.I := AValue; v.F := 0; v.S := '';
  AddArg(Self, AName, v);
end;

procedure TPluginMessage.PutFloat(const AName: string; AValue: Double);
var
  v: TPluginValue;
begin
  v.Kind := pvFloat; v.I := 0; v.F := AValue; v.S := '';
  AddArg(Self, AName, v);
end;

procedure TPluginMessage.PutText(const AName, AValue: string);
var
  v: TPluginValue;
begin
  v.Kind := pvText; v.I := 0; v.F := 0; v.S := AValue;
  AddArg(Self, AName, v);
end;

function TPluginMessage.Has(const AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Args) do
    if SameText(Args[i].Name, AName) then Exit(True);
  Result := False;
end;

function TPluginMessage.Get(const AName: string): TPluginValue;
var
  i: Integer;
begin
  for i := 0 to High(Args) do
    if SameText(Args[i].Name, AName) then
      Exit(Args[i].Value);
  { 知らない名前は「無い」を返す。例外にしない ── 受け側が知らない
    引数を無視できることが、SemVer で引数を足せる根拠である。 }
  Result.Kind := pvNone;
  Result.I := 0; Result.F := 0; Result.S := '';
end;

function TPluginMessage.ArgCount: Integer;
begin
  Result := Length(Args);
end;

function TPluginMessage.Describe: string;
var
  i: Integer;
begin
  Result := Verb;
  for i := 0 to High(Args) do
    Result := Result + ' ' + Args[i].Name + '=' + Args[i].Value.Describe;
end;

{ ============================ TPluginDescriptor ============================ }

procedure TPluginDescriptor.Init(const AId: string; AKind: TPluginKind);
begin
  Id := AId;
  DisplayName := AId;
  Author := '';
  Version := MakeVersion(0, 1, 0);
  RequiredHostApi := HostApiVersion;
  Kind := AKind;
  Origin := poExternal;
  Provides := [];
  Requires := [];
  Wants := [];
  SetLength(UnknownCapabilities, 0);
end;

function TPluginDescriptor.Describe: string;
begin
  Result := Format('%s (%s) %s / kind=%s origin=%s / host-api>=%s',
    [DisplayName, Id, Version.ToStr, PluginKindToStr(Kind),
     specialize IfThen<string>(Origin = poBuiltIn, 'built-in', 'external'),
     RequiredHostApi.ToStr]);
end;

{ ============================ 交渉 ============================ }

function TNegotiationResult.Accepted: Boolean;
begin
  Result := Outcome = negAccepted;
end;

function NegotiateCapabilities(const ADesc: TPluginDescriptor;
  const AHostApi: TApiVersion;
  AHostCaps: TPluginCapabilities): TNegotiationResult;
begin
  Result.Outcome := negAccepted;
  Result.Granted := [];
  Result.Missing := [];
  Result.Reason := '';

  if Trim(ADesc.Id) = '' then
  begin
    Result.Outcome := negInvalidDescriptor;
    Result.Reason := 'Plugin の Id が空です。';
    Exit;
  end;
  if ADesc.Kind = pkUnknown then
  begin
    Result.Outcome := negInvalidDescriptor;
    Result.Reason := Format('%s: Plugin の種別が不明です。', [ADesc.Id]);
    Exit;
  end;

  if not ADesc.RequiredHostApi.IsSatisfiedBy(AHostApi) then
  begin
    Result.Outcome := negApiIncompatible;
    Result.Reason := Format(
      '%s: Host API %s を要求していますが、この Core は %s です。',
      [ADesc.Id, ADesc.RequiredHostApi.ToStr, AHostApi.ToStr]);
    Exit;
  end;

  { Requires のうち Host に無いもの。 }
  Result.Missing := ADesc.Requires - AHostCaps;
  if Result.Missing <> [] then
  begin
    Result.Outcome := negMissingCapability;
    Result.Reason := Format(
      '%s: この Core が提供していない機能を要求しています: %s',
      [ADesc.Id, CapabilitiesToStr(Result.Missing)]);
    Exit;
  end;

  { §11.1「外部 Modem Plugin は Test vectors を必須提供する」。
    内蔵は対象外 (Core 自身の回帰試験がその役を果たすため)。 }
  if (ADesc.Kind = pkModem) and (ADesc.Origin = poExternal) and
     not (pcTestVectors in ADesc.Provides) then
  begin
    Result.Outcome := negMissingTestVectors;
    Result.Reason := Format(
      '%s: 外部 Modem Plugin は %s を宣言する必要があります (§11.1)。',
      [ADesc.Id, CapabilityToStr(pcTestVectors)]);
    Exit;
  end;

  { Host から使ってよい機能 = (必須 + 任意) のうち Host が持つもの。
    Requires は上で検査済みなので必ず入る。Wants は入るとは限らず、
    入らなかったものは Plugin 側が避けて動く。

    知らない capability 名 (UnknownCapabilities) はここで落とさない。
    落とさないことで、新しい Core 向けに書かれた Plugin が古い Core でも
    ── その機能は使えないなりに ── 動く。 }
  Result.Granted := (ADesc.Requires + ADesc.Wants) * AHostCaps;
  Result.Reason := Format('%s: 受け入れました。Host から使用可: %s',
    [ADesc.Id, CapabilitiesToStr(Result.Granted)]);
end;

{ ============================================================================
  直列化

  形式は「長さ前置・リトルエンディアン」。ADIF と同じ考え方で、
  値の中身を見ずに長さだけで切り出せるようにしてある。

  壊れた入力で落ちないこと・無制限に確保しないことを守る。別プロセス化
  したとき、向こう側は信用できない入力元になるためである。
  ============================================================================ }

type
  TWireWriter = record
    Buf: TBytes;
    Len: Integer;
    procedure Init;
    procedure Need(ACount: Integer);
    procedure PutByte(A: Byte);
    procedure PutI32(A: LongInt);
    procedure PutI64(A: Int64);
    procedure PutF64(A: Double);
    procedure PutStr(const A: string);
    function Done: TBytes;
  end;

  TWireReader = record
    Buf: TBytes;
    Pos: Integer;
    Failed: Boolean;
    procedure Init(const A: TBytes);
    function Avail: Integer;
    function GetByte: Byte;
    function GetI32: LongInt;
    function GetI64: Int64;
    function GetF64: Double;
    function GetStr: string;
  end;

procedure TWireWriter.Init;
begin
  SetLength(Buf, 256);
  Len := 0;
end;

procedure TWireWriter.Need(ACount: Integer);
begin
  if Len + ACount > Length(Buf) then
    SetLength(Buf, (Len + ACount) * 2);
end;

procedure TWireWriter.PutByte(A: Byte);
begin
  Need(1);
  Buf[Len] := A;
  Inc(Len);
end;

procedure TWireWriter.PutI32(A: LongInt);
var
  v: LongWord;
  i: Integer;
begin
  Need(4);
  v := LongWord(A);
  for i := 0 to 3 do
  begin
    Buf[Len + i] := Byte(v and $FF);
    v := v shr 8;
  end;
  Inc(Len, 4);
end;

procedure TWireWriter.PutI64(A: Int64);
var
  v: QWord;
  i: Integer;
begin
  Need(8);
  v := QWord(A);
  for i := 0 to 7 do
  begin
    Buf[Len + i] := Byte(v and $FF);
    v := v shr 8;
  end;
  Inc(Len, 8);
end;

procedure TWireWriter.PutF64(A: Double);
var
  q: QWord absolute A;
begin
  { IEEE754 のビットをそのまま。桁を落とさずに往復させるため、
    文字列にはしない。 }
  PutI64(Int64(q));
end;

procedure TWireWriter.PutStr(const A: string);
var
  n: Integer;
begin
  n := Length(A);   // $H+ の AnsiString なのでバイト数
  PutI32(n);
  if n > 0 then
  begin
    Need(n);
    Move(A[1], Buf[Len], n);
    Inc(Len, n);
  end;
end;

function TWireWriter.Done: TBytes;
begin
  SetLength(Buf, Len);
  Result := Buf;
end;

procedure TWireReader.Init(const A: TBytes);
begin
  Buf := A;
  Pos := 0;
  Failed := False;
end;

function TWireReader.Avail: Integer;
begin
  Result := Length(Buf) - Pos;
end;

function TWireReader.GetByte: Byte;
begin
  if Avail < 1 then
  begin
    Failed := True;
    Exit(0);
  end;
  Result := Buf[Pos];
  Inc(Pos);
end;

function TWireReader.GetI32: LongInt;
var
  v: LongWord;
  i: Integer;
begin
  if Avail < 4 then
  begin
    Failed := True;
    Exit(0);
  end;
  v := 0;
  for i := 3 downto 0 do
    v := (v shl 8) or Buf[Pos + i];
  Inc(Pos, 4);
  Result := LongInt(v);
end;

function TWireReader.GetI64: Int64;
var
  v: QWord;
  i: Integer;
begin
  if Avail < 8 then
  begin
    Failed := True;
    Exit(0);
  end;
  v := 0;
  for i := 7 downto 0 do
    v := (v shl 8) or Buf[Pos + i];
  Inc(Pos, 8);
  Result := Int64(v);
end;

function TWireReader.GetF64: Double;
var
  q: QWord;
  d: Double absolute q;
begin
  q := QWord(GetI64);
  Result := d;
end;

function TWireReader.GetStr: string;
var
  n: Integer;
begin
  Result := '';
  n := GetI32;
  if Failed then Exit;
  { 壊れた長さで巨大な確保をしない。 }
  if (n < 0) or (n > MAX_WIRE_STRING) or (n > Avail) then
  begin
    Failed := True;
    Exit;
  end;
  if n = 0 then Exit;
  SetLength(Result, n);
  Move(Buf[Pos], Result[1], n);
  Inc(Pos, n);
end;

procedure PutValue(var AW: TWireWriter; const AValue: TPluginValue);
begin
  AW.PutByte(Ord(AValue.Kind));
  case AValue.Kind of
    pvBool, pvInt: AW.PutI64(AValue.I);
    pvFloat:       AW.PutF64(AValue.F);
    pvText:        AW.PutStr(AValue.S);
  end;
end;

function GetValue(var AR: TWireReader; out AValue: TPluginValue): Boolean;
var
  k: Byte;
begin
  AValue.Kind := pvNone;
  AValue.I := 0; AValue.F := 0; AValue.S := '';
  k := AR.GetByte;
  if AR.Failed or (k > Ord(High(TPluginValueKind))) then Exit(False);
  AValue.Kind := TPluginValueKind(k);
  case AValue.Kind of
    pvBool, pvInt: AValue.I := AR.GetI64;
    pvFloat:       AValue.F := AR.GetF64;
    pvText:        AValue.S := AR.GetStr;
  end;
  Result := not AR.Failed;
end;

function EncodeMessage(const AMsg: TPluginMessage): TBytes;
var
  w: TWireWriter;
  i: Integer;
begin
  w.Init;
  w.PutI32(WIRE_MSG_MAGIC);
  w.PutStr(AMsg.Verb);
  w.PutI32(Length(AMsg.Args));
  for i := 0 to High(AMsg.Args) do
  begin
    w.PutStr(AMsg.Args[i].Name);
    PutValue(w, AMsg.Args[i].Value);
  end;
  Result := w.Done;
end;

function DecodeMessage(const ABytes: TBytes;
  out AMsg: TPluginMessage): Boolean;
var
  r: TWireReader;
  i, n: Integer;
  nm: string;
  v: TPluginValue;
begin
  AMsg.Init('');
  r.Init(ABytes);
  if r.GetI32 <> WIRE_MSG_MAGIC then Exit(False);
  AMsg.Verb := r.GetStr;
  if r.Failed then Exit(False);
  n := r.GetI32;
  if r.Failed or (n < 0) or (n > MAX_WIRE_ARGS) then Exit(False);
  SetLength(AMsg.Args, n);
  for i := 0 to n - 1 do
  begin
    nm := r.GetStr;
    if r.Failed then Exit(False);
    if not GetValue(r, v) then Exit(False);
    AMsg.Args[i].Name := nm;
    AMsg.Args[i].Value := v;
  end;
  Result := not r.Failed;
end;

procedure PutCaps(var AW: TWireWriter; ACaps: TPluginCapabilities);
var
  c: TPluginCapability;
  bits: Int64;
begin
  { 集合を数値にする。列挙の末尾に足しても古い側が壊れないよう、
    ビット位置は列挙の順序に固定する (順序を入れ替えないこと)。 }
  bits := 0;
  for c := Low(TPluginCapability) to High(TPluginCapability) do
    if c in ACaps then
      bits := bits or (Int64(1) shl Ord(c));
  AW.PutI64(bits);
end;

function GetCaps(var AR: TWireReader): TPluginCapabilities;
var
  c: TPluginCapability;
  bits: Int64;
begin
  Result := [];
  bits := AR.GetI64;
  if AR.Failed then Exit;
  for c := Low(TPluginCapability) to High(TPluginCapability) do
    if (bits and (Int64(1) shl Ord(c))) <> 0 then
      Include(Result, c);
end;

procedure PutVer(var AW: TWireWriter; const AVer: TApiVersion);
begin
  AW.PutI32(AVer.Major);
  AW.PutI32(AVer.Minor);
  AW.PutI32(AVer.Patch);
end;

function GetVer(var AR: TWireReader): TApiVersion;
begin
  Result.Major := AR.GetI32;
  Result.Minor := AR.GetI32;
  Result.Patch := AR.GetI32;
end;

function EncodeDescriptor(const ADesc: TPluginDescriptor): TBytes;
var
  w: TWireWriter;
  i: Integer;
begin
  w.Init;
  w.PutI32(WIRE_DSC_MAGIC);
  w.PutStr(ADesc.Id);
  w.PutStr(ADesc.DisplayName);
  w.PutStr(ADesc.Author);
  PutVer(w, ADesc.Version);
  PutVer(w, ADesc.RequiredHostApi);
  w.PutI32(Ord(ADesc.Kind));
  w.PutI32(Ord(ADesc.Origin));
  PutCaps(w, ADesc.Provides);
  PutCaps(w, ADesc.Requires);
  PutCaps(w, ADesc.Wants);
  w.PutI32(Length(ADesc.UnknownCapabilities));
  for i := 0 to High(ADesc.UnknownCapabilities) do
    w.PutStr(ADesc.UnknownCapabilities[i]);
  Result := w.Done;
end;

function DecodeDescriptor(const ABytes: TBytes;
  out ADesc: TPluginDescriptor): Boolean;
var
  r: TWireReader;
  i, n, k: Integer;
begin
  ADesc.Init('', pkUnknown);
  r.Init(ABytes);
  if r.GetI32 <> WIRE_DSC_MAGIC then Exit(False);
  ADesc.Id          := r.GetStr;
  ADesc.DisplayName := r.GetStr;
  ADesc.Author      := r.GetStr;
  ADesc.Version         := GetVer(r);
  ADesc.RequiredHostApi := GetVer(r);
  if r.Failed then Exit(False);

  k := r.GetI32;
  if r.Failed or (k < 0) or (k > Ord(High(TPluginKind))) then Exit(False);
  ADesc.Kind := TPluginKind(k);

  k := r.GetI32;
  if r.Failed or (k < 0) or (k > Ord(High(TPluginOrigin))) then Exit(False);
  ADesc.Origin := TPluginOrigin(k);

  ADesc.Provides := GetCaps(r);
  ADesc.Requires := GetCaps(r);
  ADesc.Wants    := GetCaps(r);
  if r.Failed then Exit(False);

  n := r.GetI32;
  if r.Failed or (n < 0) or (n > MAX_WIRE_ARGS) then Exit(False);
  SetLength(ADesc.UnknownCapabilities, n);
  for i := 0 to n - 1 do
  begin
    ADesc.UnknownCapabilities[i] := r.GetStr;
    if r.Failed then Exit(False);
  end;
  Result := not r.Failed;
end;

{ ============================ TPluginBase ============================ }

procedure TPluginBase.Initialize(AHost: TPluginHostContext);
begin
  FHost := AHost;
end;

procedure TPluginBase.Shutdown;
begin
  FHost := nil;
end;

function TPluginBase.Handles(const AVerb: string): Boolean;
begin
  { 既定では何も扱わない。扱うものを明示させる。
    「全部受ける」を既定にすると、知らない verb で例外を投げる Plugin が
    増えて隔離が誤発火する。 }
  Result := False;
end;

function TPluginBase.Handle(const AMsg: TPluginMessage;
  out AReply: TPluginMessage): Boolean;
begin
  AReply.Init('');
  Result := False;
end;

end.
