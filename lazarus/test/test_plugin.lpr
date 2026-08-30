{ ============================================================================
  test_plugin.lpr

  §11 Extension Platform / Plugin API draft の検証。

  「型を定義した」ことではなく、**§11.1 が課している 5 つの原則が実際に
  効いているか**を確かめる。

    1. Semantic Versioning (ADR-004)
       0.x の間は MINOR 一致を要求する。緩めると draft の間に何を変えても
       互換だと言えてしまい、SemVer を前提にした意味が無くなる。

    2. Capability Negotiation (ADR-004)
       Host に無いものを Requires していれば断る。知らない capability 名で
       落ちない (新しい Core 向けの Plugin が古い Core でも動く)。

    3. サブプロセス化を妨げない (ADR-005)
       境界を越える型がすべてバイト列に往復できること。ここが落ちるのは
       誰かが境界にオブジェクト参照を足したときで、それが検出したいこと。

    4. 障害の非波及 (§11.1)
       壊れた Plugin があっても Core は落ちず、他の Plugin には届く。
       壊れ続けたら隔離される。

    5. 外部 Modem Plugin は Test vectors 必須 (§11.1)

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_plugin;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils,
  PluginApi, PluginHost, EventBus, Observability, Requirements;

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

{ --------------------------------------------------------------------------
  1 回の確保の最大サイズを見張るメモリマネージャ

  「壊れた長さで巨大な確保をしない」は戻り値を見ても分からない。
  拒否していても、拒否する前に 2GB 確保していれば意味がない。
  別プロセス化したら向こう側は信用できない入力元になるので、ここは
  実際に測る (test_realtime / test_observability と同じ仕掛け)。
  -------------------------------------------------------------------------- }
var
  GOldMM: TMemoryManager;
  GWatching: Boolean = False;
  GMaxAlloc: PtrUInt = 0;

function WatchGetMem(ASize: PtrUInt): Pointer;
begin
  if GWatching and (ASize > GMaxAlloc) then GMaxAlloc := ASize;
  Result := GOldMM.GetMem(ASize);
end;

function WatchReAllocMem(var P: Pointer; ASize: PtrUInt): Pointer;
begin
  if GWatching and (ASize > GMaxAlloc) then GMaxAlloc := ASize;
  Result := GOldMM.ReAllocMem(P, ASize);
end;

procedure InstallWatchMM;
var
  mm: TMemoryManager;
begin
  GetMemoryManager(GOldMM);
  mm := GOldMM;
  mm.GetMem := @WatchGetMem;
  mm.ReAllocMem := @WatchReAllocMem;
  SetMemoryManager(mm);
end;

procedure RestoreMM;
begin
  SetMemoryManager(GOldMM);
end;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  Inc(TestCount);
  if ACondition then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    Inc(FailCount);
  end;
end;

procedure CheckEq(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: [', AExpected, ']  実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

procedure CheckEqI(AActual, AExpected: Int64; const AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected, '  実際: ', AActual);
    Inc(FailCount);
  end;
end;

{ ==========================================================================
  試験用の Plugin

  「行儀のよいもの」と「壊れているもの」の両方を用意する。壊れたものを
  実際に登録して呼ばないと、障害の非波及が効いているか確かめられない。
  ========================================================================== }
type
  { 普通に動くもの。呼ばれた回数を数える。 }
  TGoodPlugin = class(TPluginBase)
  private
    FId: string;
    FCalls: Integer;
    FInitialized: Boolean;
    FShutdownCalled: Boolean;
  public
    constructor Create(const AId: string);
    function Describe: TPluginDescriptor; override;
    procedure Initialize(AHost: TPluginHostContext); override;
    procedure Shutdown; override;
    function Handles(const AVerb: string): Boolean; override;
    function Handle(const AMsg: TPluginMessage;
      out AReply: TPluginMessage): Boolean; override;
    property Calls: Integer read FCalls;
    property Initialized: Boolean read FInitialized;
    property ShutdownCalled: Boolean read FShutdownCalled;
  end;

  { Handle で必ず例外を投げるもの。 }
  TThrowingPlugin = class(TPluginBase)
  private
    FId: string;
    FAttempts: Integer;
  public
    constructor Create(const AId: string);
    function Describe: TPluginDescriptor; override;
    function Handles(const AVerb: string): Boolean; override;
    function Handle(const AMsg: TPluginMessage;
      out AReply: TPluginMessage): Boolean; override;
    property Attempts: Integer read FAttempts;
  end;

  { N 回に 1 回だけ失敗し続けるもの。
    「連続」で数えているかを確かめるために要る。総数で数えていれば
    いつか必ず上限を超えるが、連続で数えていれば決して超えない。
    最初の数回だけ失敗するものでは、総数と連続数が食い違わないので
    この区別を確かめられない。 }
  TFlakyPlugin = class(TPluginBase)
  private
    FId: string;
    FPeriod: Integer;
    FCalls: Integer;
  public
    constructor Create(const AId: string; APeriod: Integer);
    function Describe: TPluginDescriptor; override;
    function Handles(const AVerb: string): Boolean; override;
    function Handle(const AMsg: TPluginMessage;
      out AReply: TPluginMessage): Boolean; override;
  end;

  { 自己申告 (Describe) の時点で例外を投げるもの。 }
  TBadDescribePlugin = class(TPluginBase)
  public
    function Describe: TPluginDescriptor; override;
  end;

  { Initialize で例外を投げるもの。 }
  TBadInitPlugin = class(TPluginBase)
  public
    function Describe: TPluginDescriptor; override;
    procedure Initialize(AHost: TPluginHostContext); override;
  end;

  { Shutdown で例外を投げるもの。 }
  TBadShutdownPlugin = class(TPluginBase)
  private
    FId: string;
  public
    constructor Create(const AId: string);
    function Describe: TPluginDescriptor; override;
    procedure Shutdown; override;
  end;

constructor TGoodPlugin.Create(const AId: string);
begin
  inherited Create;
  FId := AId;
end;

function TGoodPlugin.Describe: TPluginDescriptor;
begin
  Result.Init(FId, pkContest);
  Result.DisplayName := 'Good ' + FId;
  Result.Provides := [pcDupeCheck, pcMultiplier];
  Result.Requires := [pcOfflineQueue];
end;

procedure TGoodPlugin.Initialize(AHost: TPluginHostContext);
begin
  inherited Initialize(AHost);
  FInitialized := True;
end;

procedure TGoodPlugin.Shutdown;
begin
  FShutdownCalled := True;
  inherited Shutdown;
end;

function TGoodPlugin.Handles(const AVerb: string): Boolean;
begin
  Result := AVerb = 'contest.score';
end;

function TGoodPlugin.Handle(const AMsg: TPluginMessage;
  out AReply: TPluginMessage): Boolean;
begin
  Inc(FCalls);
  AReply.Init('contest.score.reply');
  AReply.PutInt('score', AMsg.Get('points').AsInt * 2);
  AReply.PutText('by', FId);
  Result := True;
end;

constructor TThrowingPlugin.Create(const AId: string);
begin
  inherited Create;
  FId := AId;
end;

function TThrowingPlugin.Describe: TPluginDescriptor;
begin
  Result.Init(FId, pkContest);
  Result.DisplayName := 'Throwing ' + FId;
end;

function TThrowingPlugin.Handles(const AVerb: string): Boolean;
begin
  Result := AVerb = 'contest.score';
end;

function TThrowingPlugin.Handle(const AMsg: TPluginMessage;
  out AReply: TPluginMessage): Boolean;
begin
  AReply.Init('');
  Result := False;
  Inc(FAttempts);
  raise Exception.Create('この Plugin は必ず壊れる');
end;

constructor TFlakyPlugin.Create(const AId: string; APeriod: Integer);
begin
  inherited Create;
  FId := AId;
  FPeriod := APeriod;
end;

function TFlakyPlugin.Describe: TPluginDescriptor;
begin
  Result.Init(FId, pkAward);
  Result.Provides := [pcAwardProgress];
end;

function TFlakyPlugin.Handles(const AVerb: string): Boolean;
begin
  Result := AVerb = 'award.progress';
end;

function TFlakyPlugin.Handle(const AMsg: TPluginMessage;
  out AReply: TPluginMessage): Boolean;
begin
  AReply.Init('award.progress.reply');
  Result := False;
  Inc(FCalls);
  { N 回に 1 回失敗する。連続はしない。 }
  if (FCalls mod FPeriod) = 0 then
    raise Exception.Create('ときどき失敗する');
  Result := True;
end;

function TBadDescribePlugin.Describe: TPluginDescriptor;
begin
  Result.Init('bad.describe', pkContest);
  raise Exception.Create('自己申告で壊れる');
end;

function TBadInitPlugin.Describe: TPluginDescriptor;
begin
  Result.Init('bad.init', pkContest);
end;

procedure TBadInitPlugin.Initialize(AHost: TPluginHostContext);
begin
  raise Exception.Create('初期化で壊れる');
end;

constructor TBadShutdownPlugin.Create(const AId: string);
begin
  inherited Create;
  FId := AId;
end;

function TBadShutdownPlugin.Describe: TPluginDescriptor;
begin
  Result.Init(FId, pkContest);
end;

procedure TBadShutdownPlugin.Shutdown;
begin
  raise Exception.Create('終了処理で壊れる');
end;

{ --------------------------------------------------------------------------
  1. Semantic Versioning (ADR-004)
  -------------------------------------------------------------------------- }
procedure TestVersioning;
var
  v: TApiVersion;
begin
  WriteLn;
  WriteLn('--- 1. Semantic Versioning (ADR-004) ---');

  CheckEq(MakeVersion(1, 2, 3).ToStr, '1.2.3', '文字列にできる');
  Check(ParseVersion('1.2.3', v) and (v.Major = 1) and (v.Minor = 2) and
    (v.Patch = 3), '文字列から読める');
  Check(not ParseVersion('1.2', v), '3 つ組でなければ拒否');
  Check(not ParseVersion('1.x.3', v), '数字でなければ拒否');
  Check(not ParseVersion('', v), '空は拒否');

  { MAJOR が違えば非互換。 }
  Check(not MakeVersion(1, 0, 0).IsSatisfiedBy(MakeVersion(2, 0, 0)),
    'MAJOR が違えば非互換');
  Check(not MakeVersion(2, 0, 0).IsSatisfiedBy(MakeVersion(1, 9, 9)),
    'MAJOR が上でも非互換');

  { MAJOR >= 1 なら MINOR は上位互換。 }
  Check(MakeVersion(1, 2, 0).IsSatisfiedBy(MakeVersion(1, 5, 0)),
    '1.x は Host の MINOR が上なら満たす');
  Check(not MakeVersion(1, 5, 0).IsSatisfiedBy(MakeVersion(1, 2, 0)),
    '1.x は Host の MINOR が下なら満たさない');
  Check(MakeVersion(1, 2, 9).IsSatisfiedBy(MakeVersion(1, 2, 0)),
    'PATCH の差は互換に影響しない');

  { MAJOR = 0 は不安定。MINOR の一致を要求する。
    ここを緩めると draft の間に何を変えても互換だと言えてしまう。 }
  Check(MakeVersion(0, 1, 0).IsSatisfiedBy(MakeVersion(0, 1, 0)),
    '0.x は MINOR 一致なら満たす');
  Check(not MakeVersion(0, 1, 0).IsSatisfiedBy(MakeVersion(0, 2, 0)),
    '0.x は Host の MINOR が上でも満たさない (不安定だから)');

  CheckEq(HostApiVersion.ToStr, Format('%d.%d.%d',
    [HOST_API_MAJOR, HOST_API_MINOR, HOST_API_PATCH]),
    'Host API の版が取れる');
end;

{ --------------------------------------------------------------------------
  2. Capability Negotiation (ADR-004 / §11.1)
  -------------------------------------------------------------------------- }
procedure TestNegotiation;
var
  d: TPluginDescriptor;
  r: TNegotiationResult;
  c: TPluginCapability;
begin
  WriteLn;
  WriteLn('--- 2. Capability Negotiation (§11.1) ---');

  { 名前は §11.1 の Example capabilities と同じもの。 }
  CheckEq(CapabilityToStr(pcSoftMetrics), 'supports_soft_metrics',
    '§11.1 の名前と一致 (soft metrics)');
  CheckEq(CapabilityToStr(pcMultiCandidate), 'supports_multi_candidate',
    '§11.1 の名前と一致 (multi candidate)');
  Check(StrToCapability('supports_tx', c) and (c = pcTx), '名前から引ける');
  Check(not StrToCapability('supports_time_travel', c),
    '知らない名前は False (捨てずに残すのは呼び出し側の責任)');

  { 素直に通る場合。 }
  d.Init('jp.example.contest', pkContest);
  d.Provides := [pcDupeCheck, pcCabrillo];
  d.Requires := [pcOfflineQueue];
  { Host にあれば使うが、無くても動けるもの。pcSoftMetrics は Core に
    あり、pcReplay はまだ無い。 }
  d.Wants := [pcSoftMetrics, pcReplay];
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(r.Accepted, '必須要求が満たせれば受け入れる');
  Check(r.Missing = [], '足りない必須機能は無い');
  Check(r.Granted = [pcSoftMetrics, pcTx, pcOfflineQueue] *
    (d.Requires + d.Wants + [pcSoftMetrics]),
    '(必須+任意) と Host の積が許可される');
  Check(pcOfflineQueue in r.Granted, '必須の機能は許可に入る');
  Check(pcSoftMetrics in r.Granted, 'Host にある任意の機能も許可に入る');
  Check(not (pcReplay in r.Granted),
    'Host に無い任意の機能は許可されない (断りはしない)');
  Check(not (pcDupeCheck in r.Granted),
    '自分が提供する機能は「Host から使える機能」ではない');

  { Host に無いものを要求している場合。 }
  d.Init('jp.example.replay', pkModem);
  d.Provides := [pcTestVectors];
  d.Requires := [pcReplay];   { Core はまだ提供していない }
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(not r.Accepted, 'Host に無い機能を要求すれば断る');
  Check(r.Outcome = negMissingCapability, '理由は機能不足');
  Check(pcReplay in r.Missing, '足りない機能が分かる');
  Check(Pos('supports_replay', r.Reason) > 0, '理由が人に読める');

  { Host API の版が合わない場合。 }
  d.Init('jp.example.future', pkContest);
  d.RequiredHostApi := MakeVersion(HOST_API_MAJOR + 1, 0, 0);
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(not r.Accepted, 'API の版が合わなければ断る');
  Check(r.Outcome = negApiIncompatible, '理由は版の不一致');

  { 種別不明・Id 空。 }
  d.Init('jp.example.x', pkUnknown);
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(r.Outcome = negInvalidDescriptor, '種別不明は断る');
  d.Init('', pkContest);
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(r.Outcome = negInvalidDescriptor, 'Id が空なら断る');

  { §11.1「外部 Modem Plugin は Test vectors を必須提供する」 }
  d.Init('jp.example.modem', pkModem);
  d.Origin := poExternal;
  d.Provides := [pcTx, pcSoftMetrics];   { Test vectors が無い }
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(not r.Accepted, '外部 Modem で Test vectors が無ければ断る');
  Check(r.Outcome = negMissingTestVectors, '理由が Test vectors と分かる');

  d.Provides := d.Provides + [pcTestVectors];
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(r.Accepted, 'Test vectors があれば受け入れる');

  { 内蔵は対象外 (Core 自身の回帰試験がその役を果たす)。 }
  d.Init('jp.example.builtin.modem', pkModem);
  d.Origin := poBuiltIn;
  d.Provides := [pcTx];
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(r.Accepted, '内蔵 Modem は Test vectors を要求されない');

  { 知らない capability 名で落ちないこと。これが無いと、新しい Core
    向けに書かれた Plugin が古い Core で一切動かなくなる。 }
  d.Init('jp.example.newer', pkContest);
  d.Provides := [pcDupeCheck];
  d.Requires := [pcTx];
  SetLength(d.UnknownCapabilities, 2);
  d.UnknownCapabilities[0] := 'supports_time_travel';
  d.UnknownCapabilities[1] := 'supports_telepathy';
  r := NegotiateCapabilities(d, HostApiVersion, HOST_CAPABILITIES);
  Check(r.Accepted, '知らない capability があっても受け入れる');
  Check(r.Granted = [pcTx],
    '知っている機能の交渉は普通に成立する (知らない名前に引きずられない)');
  CheckEqI(Length(d.UnknownCapabilities), 2,
    '知らない名前は捨てられずに残る');
end;

{ --------------------------------------------------------------------------
  3. サブプロセス化を妨げない (ADR-005)

  境界を越える型がバイト列に往復できることを固定する。
  誰かが将来 TPluginMessage にオブジェクト参照を足せば、ここが落ちる。
  -------------------------------------------------------------------------- }
procedure TestWireRoundTrip;
var
  m, back: TPluginMessage;
  d, dback: TPluginDescriptor;
  b: TBytes;
  bad: TBytes;
  i, accepted: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 境界を越える型がバイト列に往復する (ADR-005) ---');

  m.Init('qso.field.set');
  m.PutText('key', 'CALL');
  m.PutText('value', 'JA1ABC');
  m.PutInt('serial', 42);
  m.PutFloat('evidence', 0.8125);
  m.PutBool('confirmed', True);
  m.PutText('qth', '東京都八王子市');   { UTF-8 が壊れないこと }

  b := EncodeMessage(m);
  Check(Length(b) > 0, 'メッセージを符号化できる');
  Check(DecodeMessage(b, back), '復号できる');
  CheckEq(back.Verb, 'qso.field.set', 'verb が往復する');
  CheckEqI(back.ArgCount, m.ArgCount, '引数の数が往復する');
  CheckEq(back.Get('key').AsText, 'CALL', 'text が往復する');
  CheckEqI(back.Get('serial').AsInt, 42, 'int が往復する');
  Check(back.Get('evidence').AsFloat = 0.8125,
    'float がビットまで往復する (文字列を経由していない)');
  Check(back.Get('confirmed').AsBool, 'bool が往復する');
  CheckEq(back.Get('qth').AsText, '東京都八王子市', 'UTF-8 が往復する');
  Check(back.Get('nosuch').Kind = pvNone,
    '知らない引数は「無い」を返す (例外にしない)');

  { 引数の順序が保たれること。名前引きだが、書き出しの再現性のために
    順序は安定させる (Z-05)。 }
  CheckEq(back.Args[0].Name, 'key', '引数の順序が保たれる');
  CheckEq(back.Args[5].Name, 'qth', '最後の引数まで順序が保たれる');

  { 同名は上書き。2 つあると受け側で結果が変わってしまう。 }
  m.PutInt('serial', 99);
  CheckEqI(m.ArgCount, 6, '同名の引数は増えない');
  CheckEqI(m.Get('serial').AsInt, 99, '同名は上書きされる');

  { 空のメッセージ。 }
  m.Init('ping');
  Check(DecodeMessage(EncodeMessage(m), back), '引数なしでも往復する');
  CheckEq(back.Verb, 'ping', 'verb だけでも往復する');
  CheckEqI(back.ArgCount, 0, '引数は 0');

  { 自己申告も往復すること。別プロセス化したら、これも境界を越える。 }
  d.Init('jp.example.modem', pkModem);
  d.DisplayName := 'テスト用モデム';
  d.Author := 'JI1UUI';
  d.Version := MakeVersion(2, 3, 4);
  d.RequiredHostApi := MakeVersion(0, 1, 0);
  d.Origin := poExternal;
  d.Provides := [pcTx, pcSoftMetrics, pcTestVectors];
  d.Requires := [pcMultiCandidate];
  d.Wants    := [pcReplay, pcAutoDetection];
  SetLength(d.UnknownCapabilities, 1);
  d.UnknownCapabilities[0] := 'supports_future_thing';

  Check(DecodeDescriptor(EncodeDescriptor(d), dback), '自己申告を往復できる');
  CheckEq(dback.Id, d.Id, 'Id が往復する');
  CheckEq(dback.DisplayName, 'テスト用モデム', '表示名 (日本語) が往復する');
  CheckEq(dback.Version.ToStr, '2.3.4', '版が往復する');
  Check(dback.Kind = pkModem, '種別が往復する');
  Check(dback.Origin = poExternal, '出所が往復する');
  Check(dback.Provides = d.Provides, 'Provides が往復する');
  Check(dback.Requires = d.Requires, 'Requires が往復する');
  Check(dback.Wants = d.Wants, 'Wants が往復する');
  CheckEqI(Length(dback.UnknownCapabilities), 1,
    '知らない capability 名も往復する (落とさない)');
  CheckEq(dback.UnknownCapabilities[0], 'supports_future_thing',
    '知らない名前が保たれる');

  { --- 壊れた入力 ---
    別プロセス化したら、向こう側は信用できない入力元になる。 }
  Check(not DecodeMessage(nil, back), '空のバイト列は False');
  SetLength(bad, 3);
  bad[0] := 1; bad[1] := 2; bad[2] := 3;
  Check(not DecodeMessage(bad, back), '短すぎる入力は False');

  m.Init('qso.field.set');
  m.PutText('key', 'CALL');
  m.PutInt('serial', 42);
  m.PutFloat('evidence', 0.5);
  b := EncodeMessage(m);
  accepted := 0;
  for i := Length(b) - 1 downto 1 do
  begin
    SetLength(bad, i);
    Move(b[0], bad[0], i);
    { 途中で切ったものを「成功」と言うなら、長さの検査が甘い。 }
    if DecodeMessage(bad, back) then Inc(accepted);
  end;
  CheckEqI(accepted, 0, Format(
    '途中で切れた入力を 1 つも受け入れない (%d 通り試行)', [Length(b) - 1]));

  { --- 長さの欄が壊れている場合 ---
    拒否するだけでは足りない。拒否する前に巨大な確保をしていないことを
    実際に測る。ここを測らないと「戻り値は False だが 2GB 確保した」を
    見逃す。 }
  b := EncodeMessage(m);
  SetLength(bad, Length(b));
  Move(b[0], bad[0], Length(b));
  { verb の長さ欄 (magic 4 バイトの直後) を 0x7FFFFFFF にする }
  bad[4] := $FF; bad[5] := $FF; bad[6] := $FF; bad[7] := $7F;

  GMaxAlloc := 0;
  InstallWatchMM;
  GWatching := True;
  try
    Check(not DecodeMessage(bad, back), '長さの欄が壊れていれば拒否する');
  finally
    GWatching := False;
    RestoreMM;
  end;
  Check(GMaxAlloc < 1024 * 1024,
    Format('壊れた長さで巨大な確保をしない (最大 %d バイト)', [GMaxAlloc]));

  { 引数の個数の欄が壊れている場合も同じ。 }
  m.Init('x');
  m.PutInt('a', 1);
  b := EncodeMessage(m);
  SetLength(bad, Length(b));
  Move(b[0], bad[0], Length(b));
  { magic(4) + verb長(4) + 'x'(1) の直後が引数の個数 }
  bad[9] := $FF; bad[10] := $FF; bad[11] := $FF; bad[12] := $7F;
  GMaxAlloc := 0;
  InstallWatchMM;
  GWatching := True;
  try
    Check(not DecodeMessage(bad, back), '引数の個数が壊れていれば拒否する');
  finally
    GWatching := False;
    RestoreMM;
  end;
  Check(GMaxAlloc < 1024 * 1024,
    Format('壊れた個数で巨大な確保をしない (最大 %d バイト)', [GMaxAlloc]));
end;

{ --------------------------------------------------------------------------
  4. 登録と交渉の結果が Core に反映されること
  -------------------------------------------------------------------------- }
procedure TestRegistration;
var
  reg: TPluginRegistry;
  r: TNegotiationResult;
  good: TGoodPlugin;
  slot: TPluginSlot;
begin
  WriteLn;
  WriteLn('--- 4. 登録 ---');
  reg := TPluginRegistry.Create;
  try
    good := TGoodPlugin.Create('jp.example.a');
    slot := reg.Register(good, True, r);
    Check(slot <> nil, '受け入れた Plugin は枠が返る');
    Check(r.Accepted, '交渉が成立している');
    CheckEqI(reg.Count, 1, '1 件登録されている');
    Check(good.Initialized, '登録時に初期化が呼ばれる');
    Check(slot.IsCallable, '呼び出し可能');
    Check(reg.Find('jp.example.a') = slot, 'Id で引ける');
    Check(reg.Find('nosuch') = nil, '無い Id は nil');

    { 同じ Id を二重に登録しない。 }
    slot := reg.Register(TGoodPlugin.Create('jp.example.a'), True, r);
    Check(slot = nil, '同じ Id は受け入れない');
    Check(not r.Accepted, '断った理由が返る');
    CheckEqI(reg.Count, 1, '件数は増えない');
    CheckEqI(reg.RejectedCount, 1, '不受理の件数が数えられる');

    { 自己申告で例外を投げるものを登録しても Core は落ちない。 }
    slot := reg.Register(TBadDescribePlugin.Create, True, r);
    Check(slot = nil, '自己申告で壊れるものは受け入れない');
    Check(Pos('Describe', r.Reason) > 0, '理由に自己申告と書いてある');
    CheckEqI(reg.Count, 1, '壊れたものは登録されない');

    { nil を渡しても落ちない。 }
    slot := reg.Register(nil, False, r);
    Check(slot = nil, 'nil は受け入れない');

    { 初期化で壊れるものは、登録は残すが呼ばない。 }
    slot := reg.Register(TBadInitPlugin.Create, True, r);
    Check(slot <> nil, '初期化で壊れても登録自体は残る (状態が見えるため)');
    Check(slot.Quarantined, '初期化に失敗したものは呼ばない');
    Check(not slot.IsCallable, '呼び出し不可');
    Check(Pos('初期化で壊れる', slot.LastFault) > 0, '失敗の内容が残る');
  finally
    reg.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 障害の非波及 (§11.1) ── この草案の中心
  -------------------------------------------------------------------------- }
procedure TestFaultContainment;
var
  reg: TPluginRegistry;
  r: TNegotiationResult;
  a, b: TGoodPlugin;
  bad: TThrowingPlugin;
  msg, reply: TPluginMessage;
  n: Integer;
  badSlot: TPluginSlot;
begin
  WriteLn;
  WriteLn('--- 5. 壊れた Plugin が他へ波及しないこと (§11.1) ---');
  reg := TPluginRegistry.Create;
  try
    { 壊れたものを **間に挟む**。先頭や末尾に置くと、単に順序の都合で
      通っただけかもしれない。 }
    a := TGoodPlugin.Create('jp.example.first');
    bad := TThrowingPlugin.Create('jp.example.broken');
    b := TGoodPlugin.Create('jp.example.last');
    reg.Register(a, True, r);
    badSlot := reg.Register(bad, True, r);
    reg.Register(b, True, r);
    CheckEqI(reg.Count, 3, '3 件登録');

    msg.Init('contest.score');
    msg.PutInt('points', 10);

    n := reg.DispatchMessage(msg);
    Check(True, '壊れた Plugin を呼んでも Core は落ちない');
    CheckEqI(n, 2, '壊れていない 2 件が処理した');
    CheckEqI(a.Calls, 1, '前にいる Plugin に届いた');
    CheckEqI(b.Calls, 1, '**後ろにいる Plugin にも届いた** (波及していない)');
    CheckEqI(bad.Attempts, 1, '壊れた Plugin も呼ばれてはいる');
    CheckEqI(badSlot.TotalFaults, 1, '失敗が数えられている');
    CheckEqI(badSlot.ConsecutiveFaults, 1, '連続失敗が 1');
    Check(Pos('この Plugin は必ず壊れる', badSlot.LastFault) > 0,
      '失敗の内容が残る');
    Check(not badSlot.Quarantined, '1 回では隔離しない');

    { 続けて呼べば隔離される。 }
    reg.DispatchMessage(msg);
    Check(not badSlot.Quarantined, '2 回でもまだ隔離しない (既定は 3)');
    reg.DispatchMessage(msg);
    Check(badSlot.Quarantined, '3 回続けて失敗したら隔離する');
    CheckEqI(reg.QuarantinedCount, 1, '隔離の件数が分かる');
    CheckEqI(reg.CallableCount, 2, '呼び出し可能な件数が減る');

    { 隔離後は呼ばれない。 }
    n := bad.Attempts;
    reg.DispatchMessage(msg);
    CheckEqI(bad.Attempts, n, '隔離した Plugin はもう呼ばれない');
    CheckEqI(a.Calls, 4, '健全な Plugin は呼ばれ続ける');
    CheckEqI(b.Calls, 4, '後ろの Plugin も呼ばれ続ける');

    { 運用者が戻せる。 }
    Check(reg.Revive('jp.example.broken'), '隔離を解除できる');
    Check(not badSlot.Quarantined, '解除された');
    CheckEqI(badSlot.ConsecutiveFaults, 0, '連続失敗が数え直される');

    { 返信を取る経路でも波及しないこと。 }
    Check(reg.Request(msg, reply), '返信を取れる');
    CheckEq(reply.Get('by').AsText, 'jp.example.first',
      '最初に処理した Plugin の返信が返る');
    CheckEqI(reply.Get('score').AsInt, 20, '返信の中身が渡る');
  finally
    reg.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 「連続」失敗で隔離すること
  -------------------------------------------------------------------------- }
procedure TestConsecutiveFaultPolicy;
var
  reg: TPluginRegistry;
  r: TNegotiationResult;
  flaky: TFlakyPlugin;
  slot: TPluginSlot;
  msg: TPluginMessage;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 隔離は「連続」失敗で判断すること ---');
  reg := TPluginRegistry.Create;
  try
    { 3 回に 1 回失敗し続けるもの。既定の上限は 3。
      通算で数えていれば 9 回呼んだ時点で必ず隔離される。
      連続で数えていれば、間に成功が挟まるので決して隔離されない。 }
    flaky := TFlakyPlugin.Create('jp.example.flaky', 3);
    slot := reg.Register(flaky, True, r);
    msg.Init('award.progress');

    reg.DispatchMessage(msg);
    reg.DispatchMessage(msg);
    CheckEqI(slot.TotalFaults, 0, '最初の 2 回は成功する');
    reg.DispatchMessage(msg);
    CheckEqI(slot.ConsecutiveFaults, 1, '3 回目に失敗した');
    CheckEqI(slot.TotalFaults, 1, '通算 1 件');
    reg.DispatchMessage(msg);
    CheckEqI(slot.ConsecutiveFaults, 0, '成功したら数え直す');
    CheckEqI(slot.TotalFaults, 1, '通算の失敗数は残る');

    { ここから先、通算で数えていれば上限 3 を必ず超える。 }
    for i := 1 to 30 do
      reg.DispatchMessage(msg);
    Check(slot.TotalFaults > reg.FaultLimit,
      '通算の失敗数は上限を超えている (前提)');
    Check(not slot.Quarantined,
      '通算で上限を超えても、連続していなければ隔離しない');
    Check(slot.IsCallable, '呼び出し可能なまま');
    Check(slot.TotalCalls > 30, '呼ばれ続けている');

    { 逆に、連続すれば隔離される。 }
    reg.Free;
    reg := TPluginRegistry.Create;
    slot := reg.Register(TFlakyPlugin.Create('jp.example.always', 1),
      True, r);
    for i := 1 to 3 do
      reg.DispatchMessage(msg);
    Check(slot.Quarantined, '毎回失敗すれば隔離される');
  finally
    reg.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 終了処理・観測との接続
  -------------------------------------------------------------------------- }
procedure TestShutdownAndObservability;
var
  reg: TPluginRegistry;
  obs: TObsRegistry;
  bus: TEventBus;
  r: TNegotiationResult;
  a, b: TGoodPlugin;
  bad: TThrowingPlugin;
  msg: TPluginMessage;
  recs: TObsRecordArray;
  i, loaded, faults, quar: Integer;
begin
  WriteLn;
  WriteLn('--- 7. 終了処理と観測 (ADR-010 との接続) ---');
  bus := TEventBus.Create;
  obs := TObsRegistry.Create;
  reg := TPluginRegistry.Create(bus, obs);
  try
    a := TGoodPlugin.Create('jp.example.a');
    b := TGoodPlugin.Create('jp.example.b');
    bad := TThrowingPlugin.Create('jp.example.bad');
    reg.Register(a, True, r);
    reg.Register(TBadShutdownPlugin.Create('jp.example.badshutdown'), True, r);
    reg.Register(b, True, r);
    reg.Register(bad, True, r);

    msg.Init('contest.score');
    for i := 1 to 4 do
      reg.DispatchMessage(msg);

    { 終了処理で例外を投げるものがいても、残りの終了処理は行われる。 }
    reg.ShutdownAll;
    Check(a.ShutdownCalled, '前にいる Plugin の終了処理が呼ばれた');
    Check(b.ShutdownCalled,
      '壊れた終了処理の**後ろ**の Plugin も終了処理が呼ばれた');

    { 障害が Core の記録に残ること。「どこを見れば分かるか」が
      Plugin だけ別になっていては診断できない (ADR-010)。 }
    recs := obs.Log.Snapshot;
    loaded := 0; faults := 0; quar := 0;
    for i := 0 to High(recs) do
    begin
      if recs[i].Category <> ocatPlugin then Continue;
      case recs[i].Code of
        ocdPluginLoaded:      Inc(loaded);
        ocdPluginFault:       Inc(faults);
        ocdPluginQuarantined: Inc(quar);
      end;
    end;
    CheckEqI(loaded, 4, '受け入れた 4 件が記録に残る');
    Check(faults >= 3, '失敗が記録に残る');
    Check(quar >= 1, '隔離が記録に残る');
    Check(Pos('jp.example.bad', obs.Export_) > 0,
      '記録に発生元の Id が出る');

    { 呼び出し時間の統計が取れていること (Z-04 の材料)。 }
    Check(obs.Metric('plugin.call', 's').Count > 0,
      '呼び出し時間が統計に積まれる');
  finally
    reg.Free;
    obs.Free;
    bus.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. Plugin から見た Core (窓口の制約)
  -------------------------------------------------------------------------- }
type
  { 窓口を使う Plugin。設定を読み、記録を残し、発行する。 }
  TChattyPlugin = class(TPluginBase)
  private
    FSetting: string;
    FCanTx, FCanReplay: Boolean;
  public
    function Describe: TPluginDescriptor; override;
    procedure Initialize(AHost: TPluginHostContext); override;
    { 発行元を詐称しようとする。Core 側で上書きされるはず。 }
    procedure PublishForged;
    property Setting: string read FSetting;
    property CanTx: Boolean read FCanTx;
    property CanReplay: Boolean read FCanReplay;
  end;

var
  GSettingCalls: Integer = 0;
  GLastSettingPlugin: string = '';

function TChattyPlugin.Describe: TPluginDescriptor;
begin
  Result.Init('jp.example.chatty', pkDataProvider);
  Result.Provides := [pcLookup];
  Result.Requires := [pcTx];       { Core にある。無ければ受け入れられない }
  Result.Wants    := [pcReplay];   { Core にまだ無い。無いなりに動く }
end;

procedure TChattyPlugin.Initialize(AHost: TPluginHostContext);
begin
  inherited Initialize(AHost);
  FSetting := AHost.GetSetting('endpoint', '(既定)');
  { 交渉で許可されたものだけが True になるはず。 }
  FCanTx := AHost.HasCapability(pcTx);
  FCanReplay := AHost.HasCapability(pcReplay);
  AHost.Log(pllInfo, '初期化しました');
end;

procedure TChattyPlugin.PublishForged;
var
  m: TPluginMessage;
begin
  m.Init('provider.result');
  m.PutText('source', 'ModemEngine');   { Core になりすまそうとする }
  m.PutText('note', 'なりすまし');
  Host.Publish(m);
end;

type
  { 設定の供給元と、バスの受け口。どちらもメソッドでなければ渡せない。 }
  TSettingSource = class
  private
    FSeen: Integer;
    FText: string;
    FSource: string;
    FTexts: TStringList;
    FSources: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function Read(const APluginId, AKey, ADefault: string): string;
    procedure OnBus(const AEvent: TBusEvent);
    property Seen: Integer read FSeen;
    property Text: string read FText;
    property Source: string read FSource;
    property Sources: TStringList read FSources;
  end;

function TSettingSource.Read(const APluginId, AKey,
  ADefault: string): string;
begin
  Inc(GSettingCalls);
  GLastSettingPlugin := APluginId;
  if AKey = 'endpoint' then
    Result := 'https://example.invalid/'
  else
    Result := ADefault;
end;

constructor TSettingSource.Create;
begin
  inherited Create;
  FTexts := TStringList.Create;
  FSources := TStringList.Create;
end;

destructor TSettingSource.Destroy;
begin
  FTexts.Free;
  FSources.Free;
  inherited Destroy;
end;

procedure TSettingSource.OnBus(const AEvent: TBusEvent);
begin
  if AEvent.Kind = bekStatusText then
  begin
    Inc(FSeen);
    FText := AEvent.Text;
    FSource := AEvent.Source;
    FTexts.Add(AEvent.Text);
    FSources.Add(AEvent.Source);
  end;
end;

{ 記録した中に、その発行元のものがあるか。 }
function SourceSeen(ASrc: TSettingSource; const AId: string): Boolean;
begin
  Result := ASrc.Sources.IndexOf(AId) >= 0;
end;

procedure TestHostContext;
var
  reg: TPluginRegistry;
  bus: TEventBus;
  src: TSettingSource;
  r: TNegotiationResult;
  p: TChattyPlugin;
begin
  WriteLn;
  WriteLn('--- 8. Plugin から見た Core の窓口 ---');
  bus := TEventBus.Create;
  src := TSettingSource.Create;
  reg := TPluginRegistry.Create(bus);
  try
    bus.Subscribe(@src.OnBus, []);
    reg.SettingReader := @src.Read;

    p := TChattyPlugin.Create;
    Check(reg.Register(p, True, r) <> nil, '窓口を使う Plugin を受け入れた');

    CheckEq(p.Setting, 'https://example.invalid/', '設定を読める');
    CheckEqI(GSettingCalls, 1, '設定の読み出しが Core 側へ届く');
    CheckEq(GLastSettingPlugin, 'jp.example.chatty',
      '設定は Plugin ごとの名前空間で引かれる (他の設定を読めない)');

    { 交渉の結果だけが使える。申告していないものは使えない。 }
    Check(p.CanTx, '必須要求として通した Host の機能は使える');
    Check(not p.CanReplay,
      'Host に無い任意機能は使えないと分かる (Plugin が避けて動ける)');

    { Plugin の記録が Control Plane に出ること、かつ発行元が
      Plugin の Id に固定されること。 }
    bus.DispatchPending;
    Check(src.Seen > 0, 'Plugin の記録がバスに出る');
    Check(Pos('初期化しました', src.Text) > 0, '本文が届く');
    Check(Pos('[info]', src.Text) > 0, '重みが分かる');
    CheckEq(src.Source, 'jp.example.chatty',
      '記録の発行元は Plugin の Id に固定される');

    { 発行 (Publish) の経路でも同じであること。記録 (Log) とは別の
      道筋なので、片方だけ守られていても意味がない。 }
    src.Sources.Clear;
    src.FTexts.Clear;
    p.PublishForged;
    bus.DispatchPending;
    Check(src.Sources.Count > 0, 'Plugin の発行がバスに出る');
    Check(SourceSeen(src, 'jp.example.chatty'),
      '発行の発行元も Plugin の Id に固定される');
    Check(not SourceSeen(src, 'ModemEngine'),
      '**Core になりすませない** (Plugin が名乗った発行元は使われない)');
  finally
    reg.Free;
    src.Free;
    bus.Free;
  end;
end;

begin
  WriteLn('=== §11 Plugin API draft テスト ===');

  TestVersioning;
  TestNegotiation;
  TestWireRoundTrip;
  TestRegistration;
  TestFaultContainment;
  TestConsecutiveFaultPolicy;
  TestShutdownAndObservability;
  TestHostContext;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('PLG-001');
    CoverReq('PLG-003');
    CoverReq('PLG-004');
    CoverReq('PLG-005');
  end;

  if FailCount > 0 then
    Halt(1);
end.
