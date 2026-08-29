{ ============================================================================
  Observability.pas

  Architecture & Requirements Baseline v1.1 の Z-01 Observability。

  二つの目的 (§14):
  ----------------------------------------------------------------------------
    1. 障害診断  — 何が起きたのか、どの順で起きたのかを後から辿る
    2. アルゴリズム改善 — SNR・Decoder・Confidence を蓄積し、Phase 3 の
                          Algorithm Portfolio の良し悪しを測る材料にする

  この二つは要求する形が違う。

    障害診断    → 「出来事の列」。順序と時刻が要る。頻度は低い。
    改善のため  → 「数値の分布」。個々の値より統計が要る。頻度は高い。

  そこで記録を 2 種類に分ける。

    TObsLog     出来事を時系列で残す (有界リング)
    TObsMetric  数値の統計を積む (件数・最小・最大・平均・分布)

  記録は音声スレッドから起きる (X-04 / ADR-009):
  ----------------------------------------------------------------------------
  観測のために deadline を落としては本末転倒なので、記録側は
  **確保しない・伸びない** ことを設計条件にする。

    - 記録は固定長のレコード。文字列フィールドを持たず、
      発生元の名前は固定長の文字配列で持つ (代入しても確保が起きない)。
    - リングは生成時に確保し、以後伸びない。溢れたら古いものから捨て、
      捨てた件数を数える。
    - ロックは専用の短いものを使う。メモリマネージャのロックと違い、
      保持区間が数命令で有界であることが分かっている。

  この「確保しない」は回帰テスト (test_observability) でメモリマネージャを
  差し替えて実測している。読み出し・書き出し側 (Export) は確保してよい。
  ============================================================================ }
unit Observability;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  Classes, SysUtils, SyncObjs, EventBus;

const
  { 発生元の名前を入れる固定長。動的文字列にすると記録のたびに
    参照カウント操作が走るため、値のコピーで済む配列にする。 }
  OBS_NAME_LEN = 23;

type
  TObsSeverity = (
    obsTrace,     // 詳細。既定では記録しない
    obsInfo,      // 通常の出来事
    obsWarning,   // 続行できるが望ましくない
    obsError      // 機能が損なわれた
  );

  { 何の領域で起きたか。障害の切り分けに使う (B-04 / Z-06)。 }
  TObsCategory = (
    ocatAudio,     // サウンド入出力
    ocatDsp,       // 復調・DSP
    ocatRig,       // CAT 制御
    ocatEngine,    // 送受信エンジン
    ocatUi,        // UI 連携
    ocatLog,       // ロギング
    ocatPlugin,    // 拡張
    ocatSystem     // その他
  );

  { 何が起きたか。文字列ではなく列挙にしているのは、
    記録時に確保が起きないようにするためと、集計しやすくするため。 }
  TObsCode = (
    ocdNone,
    { --- 音声 --- }
    ocdAudioOverflow,        // 入力バッファ溢れ (取りこぼし)
    ocdAudioUnderflow,       // 出力バッファ枯渇 (音切れ)
    ocdAudioOpened,
    ocdAudioClosed,
    ocdAudioAborted,
    { --- 復調 --- }
    ocdDecodeEmitted,        // 文字を復調した (I1=文字, D1=尺度, D2=SNR)
    ocdStrategyChanged,      // 復調戦略が変わった (Phase 3)
    ocdDspError,
    { --- エンジン --- }
    ocdTrxStateChanged,      // I1=状態値
    ocdModemChanged,
    ocdEngineError,
    { --- 機器 --- }
    ocdRigChanged,
    ocdRigError,
    { --- 通知路 --- }
    ocdEventDropped,         // バスが溢れて捨てた
    ocdSubscriberError,      // 購読者が例外を投げた
    { --- 実時間性 --- }
    ocdDeadlineExceeded,     // ブロック処理が deadline を超えた
    { --- 汎用 --- }
    ocdStatus,
    ocdError
  );

  TObsName = array[0..OBS_NAME_LEN] of AnsiChar;

  { 出来事 1 件。固定長でなければならない (上記の理由)。 }
  TObsRecord = record
    TimestampUtc: TDateTime;
    Severity: TObsSeverity;
    Category: TObsCategory;
    Code: TObsCode;
    { 意味は Code ごとに決める。ocdDecodeEmitted なら
      I1=文字コード / I2=尺度種別 / D1=尺度 / D2=SNR。 }
    I1, I2: Int64;
    D1, D2: Double;
    Source: TObsName;      // 発生元 (復調戦略名など)

    function SourceStr: string;
    function Describe: string;
  end;
  TObsRecordArray = array of TObsRecord;

  { --- 数値の統計 ---
    個々の値ではなく分布を見るためのもの。件数・最小・最大・平均に加え、
    遅延の判断に使えるよう固定バケットのヒストグラムを持つ。
    バケット境界を固定にしているのは、記録時に確保も再配置も
    起こさないようにするため。 }
  TObsMetric = class
  private
    FLock: TCriticalSection;
    FName: string;
    FUnit: string;
    FCount: Int64;
    FSum: Double;
    FMin, FMax: Double;
    FBuckets: array[0..13] of Int64;
    FOverBudget: Int64;      // 予算 (deadline 等) を超えた件数
    FBudget: Double;         // 0 = 予算なし
  public
    constructor Create(const AName, AUnit: string; ABudget: Double = 0);
    destructor Destroy; override;

    { 値を 1 件積む。確保しない。音声スレッドから呼んでよい。 }
    procedure Observe(AValue: Double);
    procedure Reset;

    function Count: Int64;
    function Mean: Double;
    function MinValue: Double;
    function MaxValue: Double;
    { 予算を超えた件数 (Budget=0 なら常に 0)。 }
    function OverBudgetCount: Int64;
    { 分布を人が読める形にする (確保するので読み出し側専用)。 }
    function DescribeDistribution: string;
    function Describe: string;

    property Name: string read FName;
    property MetricUnit: string read FUnit;
    { これを超えた値を「予算超過」として数える。
      ブロック処理時間なら deadline を入れる (Z-04)。 }
    property Budget: Double read FBudget write FBudget;
  end;

  { --- 出来事の記録 (有界リング) --- }
  TObsLog = class
  private
    FLock: TCriticalSection;
    FRing: array of TObsRecord;
    FHead, FCount: Integer;
    FDropped: Int64;
    FTotal: Int64;
    FMinSeverity: TObsSeverity;
  public
    constructor Create(ACapacity: Integer = 0);
    destructor Destroy; override;

    { 1 件記録する。確保しない。任意スレッドから呼んでよい。 }
    procedure Add(ASeverity: TObsSeverity; ACategory: TObsCategory;
      ACode: TObsCode; const ASource: string = '';
      AI1: Int64 = 0; AI2: Int64 = 0; AD1: Double = 0; AD2: Double = 0);
    { 発生元を固定長名で渡す版 (確保を完全に避けたい経路用)。 }
    procedure AddRaw(ASeverity: TObsSeverity; ACategory: TObsCategory;
      ACode: TObsCode; const ASource: TObsName;
      AI1: Int64 = 0; AI2: Int64 = 0; AD1: Double = 0; AD2: Double = 0);

    { 保持している記録を新しい順に取り出す (確保するので読み出し側専用)。 }
    function Snapshot: TObsRecordArray;
    procedure Clear;

    function PendingCount: Integer;
    property TotalRecorded: Int64 read FTotal;
    { 溢れて捨てた件数。0 でなければ記録が追いついていない。 }
    property DroppedCount: Int64 read FDropped;
    { これ未満の重大度は記録しない (既定 obsInfo)。 }
    property MinSeverity: TObsSeverity read FMinSeverity write FMinSeverity;
  end;

  { --- 記録の集約点 ---
    「どこを見れば分かるか」を 1 か所にするためのもの。
    出来事の記録と名前つきの統計をまとめて持ち、まとめて書き出せる。 }
  TObsRegistry = class
  private
    FLog: TObsLog;
    FMetrics: array of TObsMetric;
    FLock: TCriticalSection;
  public
    constructor Create(ALogCapacity: Integer = 0);
    destructor Destroy; override;

    { 名前で統計を引く。無ければ作る。 }
    function Metric(const AName, AUnit: string;
      ABudget: Double = 0): TObsMetric;
    function MetricCount: Integer;
    function MetricAt(AIndex: Integer): TObsMetric;

    { 現状を人が読める文字列にする (障害報告に貼れる形)。 }
    function Export_(AMaxRecords: Integer = 50): string;

    property Log: TObsLog read FLog;
  end;

  { --- Event Bus を記録する購読者 ---
    バスは既に Control Plane の全イベントの通り道なので、購読を 1 つ
    足すだけで「何が起きたか」の記録経路が立つ。
    記録側から見ると、バスの発行元 (モデム/エンジン/リグ) に手を
    入れずに済むのが利点である。 }
  TObsBusRecorder = class
  private
    FLog: TObsLog;
    FBus: TEventBus;
    FDecodeMetric: TObsMetric;   // 復調の SNR 分布 (nil 可)
    procedure Handle(const AEvent: TBusEvent);
  public
    constructor Create(ABus: TEventBus; ALog: TObsLog);
    destructor Destroy; override;
    { 設定すると復調ごとの SNR をここへ積む (アルゴリズム改善用)。 }
    property DecodeSnrMetric: TObsMetric
      read FDecodeMetric write FDecodeMetric;
  end;

{ 単調増加の高分解能時刻 (秒)。
  1ブロックは 0.5ms 程度なので GetTickCount64 (ミリ秒) では粒度が足りない。
  観測のためにこれ自体が重くては困るので、システムコール 1 回で済む
  経路を使う。 }
function ObsHiResSeconds: Double;

function ObsSeverityToStr(A: TObsSeverity): string;
function ObsCategoryToStr(A: TObsCategory): string;
function ObsCodeToStr(A: TObsCode): string;
{ 文字列を固定長名へ写す (確保しない)。 }
procedure SetObsName(out ADest: TObsName; const ASource: string);

implementation

uses
  DateUtils, Math;

{$IFDEF UNIX}
type
  TObsTimespec = record
    tv_sec: clong;
    tv_nsec: clong;
  end;
function obs_clock_gettime(clk: cint; var tp: TObsTimespec): cint; cdecl;
  external 'c' name 'clock_gettime';
const
  OBS_CLOCK_MONOTONIC = 1;
{$ENDIF}

function ObsHiResSeconds: Double;
{$IFDEF UNIX}
var
  ts: TObsTimespec;
begin
  if obs_clock_gettime(OBS_CLOCK_MONOTONIC, ts) = 0 then
    Result := ts.tv_sec + ts.tv_nsec / 1.0e9
  else
    Result := Now * 86400.0;
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  f, c: Int64;
begin
  if QueryPerformanceFrequency(f) and (f <> 0) and QueryPerformanceCounter(c) then
    Result := c / f
  else
    Result := Now * 86400.0;
end;
{$ELSE}
begin
  Result := Now * 86400.0;
end;
{$ENDIF}
{$ENDIF}

const
  DEFAULT_LOG_CAPACITY = 2048;
  { ヒストグラムのバケット上限 (単位はメトリックの単位に依存)。
    遅延をミリ秒で測ることを想定した刻みにしてある。 }
  BUCKET_LIMITS: array[0..12] of Double =
    (0.1, 0.25, 0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000);

function ObsSeverityToStr(A: TObsSeverity): string;
begin
  case A of
    obsTrace:   Result := 'TRACE';
    obsWarning: Result := 'WARN';
    obsError:   Result := 'ERROR';
  else
    Result := 'INFO';
  end;
end;

function ObsCategoryToStr(A: TObsCategory): string;
begin
  case A of
    ocatAudio:  Result := 'audio';
    ocatDsp:    Result := 'dsp';
    ocatRig:    Result := 'rig';
    ocatEngine: Result := 'engine';
    ocatUi:     Result := 'ui';
    ocatLog:    Result := 'log';
    ocatPlugin: Result := 'plugin';
  else
    Result := 'system';
  end;
end;

function ObsCodeToStr(A: TObsCode): string;
begin
  case A of
    ocdAudioOverflow:     Result := 'AudioOverflow';
    ocdAudioUnderflow:    Result := 'AudioUnderflow';
    ocdAudioOpened:       Result := 'AudioOpened';
    ocdAudioClosed:       Result := 'AudioClosed';
    ocdAudioAborted:      Result := 'AudioAborted';
    ocdDecodeEmitted:     Result := 'DecodeEmitted';
    ocdStrategyChanged:   Result := 'StrategyChanged';
    ocdDspError:          Result := 'DspError';
    ocdTrxStateChanged:   Result := 'TrxStateChanged';
    ocdModemChanged:      Result := 'ModemChanged';
    ocdEngineError:       Result := 'EngineError';
    ocdRigChanged:        Result := 'RigChanged';
    ocdRigError:          Result := 'RigError';
    ocdEventDropped:      Result := 'EventDropped';
    ocdSubscriberError:   Result := 'SubscriberError';
    ocdDeadlineExceeded:  Result := 'DeadlineExceeded';
    ocdStatus:            Result := 'Status';
    ocdError:             Result := 'Error';
  else
    Result := 'None';
  end;
end;

procedure SetObsName(out ADest: TObsName; const ASource: string);
var
  i, n: Integer;
begin
  n := Length(ASource);
  if n > OBS_NAME_LEN then n := OBS_NAME_LEN;
  for i := 1 to n do
    ADest[i - 1] := ASource[i];
  for i := n to OBS_NAME_LEN do
    ADest[i] := #0;
end;

{ TObsRecord }

function TObsRecord.SourceStr: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to OBS_NAME_LEN do
  begin
    if Source[i] = #0 then Break;
    Result := Result + Source[i];
  end;
end;

function TObsRecord.Describe: string;
begin
  Result := Format('%s %-5s %-7s %-18s', [
    FormatDateTime('hh:nn:ss.zzz', TimestampUtc),
    ObsSeverityToStr(Severity),
    ObsCategoryToStr(Category),
    ObsCodeToStr(Code)]);
  if SourceStr <> '' then
    Result := Result + '[' + SourceStr + '] ';
  Result := Result + Format('i=(%d,%d) d=(%.3f,%.3f)', [I1, I2, D1, D2]);
end;

{ TObsMetric }

constructor TObsMetric.Create(const AName, AUnit: string; ABudget: Double);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FName := AName;
  FUnit := AUnit;
  FBudget := ABudget;
  Reset;
end;

destructor TObsMetric.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TObsMetric.Reset;
var
  i: Integer;
begin
  FLock.Enter;
  try
    FCount := 0;
    FSum := 0;
    FMin := 0;
    FMax := 0;
    FOverBudget := 0;
    for i := Low(FBuckets) to High(FBuckets) do
      FBuckets[i] := 0;
  finally
    FLock.Leave;
  end;
end;

procedure TObsMetric.Observe(AValue: Double);
{ 音声スレッドから呼ばれる。確保しないこと。
  ロックは保持区間が数命令で有界なので realtime でも問題にならない
  (メモリマネージャのロックが問題なのは、確保の作業量が有界でないため)。 }
var
  i: Integer;
begin
  FLock.Enter;
  try
    if FCount = 0 then
    begin
      FMin := AValue;
      FMax := AValue;
    end
    else
    begin
      if AValue < FMin then FMin := AValue;
      if AValue > FMax then FMax := AValue;
    end;
    Inc(FCount);
    FSum := FSum + AValue;
    if (FBudget > 0) and (AValue > FBudget) then
      Inc(FOverBudget);

    for i := Low(BUCKET_LIMITS) to High(BUCKET_LIMITS) do
      if AValue < BUCKET_LIMITS[i] then
      begin
        Inc(FBuckets[i]);
        Exit;
      end;
    Inc(FBuckets[High(FBuckets)]);
  finally
    FLock.Leave;
  end;
end;

function TObsMetric.Count: Int64;
begin
  FLock.Enter;
  try
    Result := FCount;
  finally
    FLock.Leave;
  end;
end;

function TObsMetric.Mean: Double;
begin
  FLock.Enter;
  try
    if FCount = 0 then Result := 0 else Result := FSum / FCount;
  finally
    FLock.Leave;
  end;
end;

function TObsMetric.MinValue: Double;
begin
  FLock.Enter;
  try
    Result := FMin;
  finally
    FLock.Leave;
  end;
end;

function TObsMetric.MaxValue: Double;
begin
  FLock.Enter;
  try
    Result := FMax;
  finally
    FLock.Leave;
  end;
end;

function TObsMetric.OverBudgetCount: Int64;
begin
  FLock.Enter;
  try
    Result := FOverBudget;
  finally
    FLock.Leave;
  end;
end;

function TObsMetric.DescribeDistribution: string;
var
  i: Integer;
  b: array[0..13] of Int64;
  lbl: string;
begin
  FLock.Enter;
  try
    for i := Low(FBuckets) to High(FBuckets) do
      b[i] := FBuckets[i];
  finally
    FLock.Leave;
  end;
  Result := '';
  for i := Low(b) to High(b) do
  begin
    if b[i] = 0 then Continue;
    { %g は 0.1 を 0.10000000000000001 と出すので使わない }
    if i <= High(BUCKET_LIMITS) then
      lbl := '<' + FormatFloat('0.###', BUCKET_LIMITS[i])
    else
      lbl := '>=' + FormatFloat('0.###', BUCKET_LIMITS[High(BUCKET_LIMITS)]);
    if Result <> '' then Result := Result + ' ';
    Result := Result + Format('%s:%d', [lbl, b[i]]);
  end;
  if Result = '' then Result := '(記録なし)';
end;

function TObsMetric.Describe: string;
begin
  Result := Format('%-24s n=%d  min=%.3f mean=%.3f max=%.3f %s',
    [FName, Count, MinValue, Mean, MaxValue, FUnit]);
  if FBudget > 0 then
    Result := Result + Format('  予算超過 %d 件 (予算 %.3f %s)',
      [OverBudgetCount, FBudget, FUnit]);
  Result := Result + sLineBreak + '    分布: ' + DescribeDistribution;
end;

{ TObsLog }

constructor TObsLog.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity <= 0 then ACapacity := DEFAULT_LOG_CAPACITY;
  FLock := TCriticalSection.Create;
  SetLength(FRing, ACapacity);
  FHead := 0;
  FCount := 0;
  FDropped := 0;
  FTotal := 0;
  FMinSeverity := obsInfo;
end;

destructor TObsLog.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TObsLog.AddRaw(ASeverity: TObsSeverity; ACategory: TObsCategory;
  ACode: TObsCode; const ASource: TObsName;
  AI1, AI2: Int64; AD1, AD2: Double);
var
  idx: Integer;
begin
  if ASeverity < FMinSeverity then Exit;
  FLock.Enter;
  try
    Inc(FTotal);
    if FCount >= Length(FRing) then
    begin
      { 溢れたら最も古いものを捨てる。黙って失わず件数を記録する。 }
      FHead := (FHead + 1) mod Length(FRing);
      Dec(FCount);
      Inc(FDropped);
    end;
    idx := (FHead + FCount) mod Length(FRing);
    FRing[idx].TimestampUtc := LocalTimeToUniversal(Now);
    FRing[idx].Severity := ASeverity;
    FRing[idx].Category := ACategory;
    FRing[idx].Code := ACode;
    FRing[idx].I1 := AI1;
    FRing[idx].I2 := AI2;
    FRing[idx].D1 := AD1;
    FRing[idx].D2 := AD2;
    FRing[idx].Source := ASource;
    Inc(FCount);
  finally
    FLock.Leave;
  end;
end;

procedure TObsLog.Add(ASeverity: TObsSeverity; ACategory: TObsCategory;
  ACode: TObsCode; const ASource: string;
  AI1, AI2: Int64; AD1, AD2: Double);
var
  nm: TObsName;
begin
  SetObsName(nm, ASource);
  AddRaw(ASeverity, ACategory, ACode, nm, AI1, AI2, AD1, AD2);
end;

function TObsLog.Snapshot: TObsRecordArray;
var
  i: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FCount);
    for i := 0 to FCount - 1 do
      Result[i] := FRing[(FHead + i) mod Length(FRing)];
  finally
    FLock.Leave;
  end;
end;

procedure TObsLog.Clear;
begin
  FLock.Enter;
  try
    FHead := 0;
    FCount := 0;
  finally
    FLock.Leave;
  end;
end;

function TObsLog.PendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FCount;
  finally
    FLock.Leave;
  end;
end;

{ TObsRegistry }

constructor TObsRegistry.Create(ALogCapacity: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLog := TObsLog.Create(ALogCapacity);
end;

destructor TObsRegistry.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FMetrics) do
    FMetrics[i].Free;
  SetLength(FMetrics, 0);
  FLog.Free;
  FLock.Free;
  inherited Destroy;
end;

function TObsRegistry.Metric(const AName, AUnit: string;
  ABudget: Double): TObsMetric;
var
  i, n: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FMetrics) do
      if FMetrics[i].Name = AName then
        Exit(FMetrics[i]);
    Result := TObsMetric.Create(AName, AUnit, ABudget);
    n := Length(FMetrics);
    SetLength(FMetrics, n + 1);
    FMetrics[n] := Result;
  finally
    FLock.Leave;
  end;
end;

function TObsRegistry.MetricCount: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FMetrics);
  finally
    FLock.Leave;
  end;
end;

function TObsRegistry.MetricAt(AIndex: Integer): TObsMetric;
begin
  FLock.Enter;
  try
    if (AIndex < 0) or (AIndex > High(FMetrics)) then
      raise Exception.CreateFmt(
        '統計の添字が範囲外です (要求 %d / 登録数 %d)',
        [AIndex, Length(FMetrics)]);
    Result := FMetrics[AIndex];
  finally
    FLock.Leave;
  end;
end;

function TObsRegistry.Export_(AMaxRecords: Integer): string;
var
  sb: TStringList;
  recs: TObsRecordArray;
  i, first: Integer;
begin
  sb := TStringList.Create;
  try
    sb.Add('=== 統計 ===');
    for i := 0 to MetricCount - 1 do
      sb.Add(MetricAt(i).Describe);

    sb.Add('');
    sb.Add(Format('=== 出来事 (保持 %d / 通算 %d / 捨てた %d) ===',
      [FLog.PendingCount, FLog.TotalRecorded, FLog.DroppedCount]));
    recs := FLog.Snapshot;
    first := 0;
    if (AMaxRecords > 0) and (Length(recs) > AMaxRecords) then
      first := Length(recs) - AMaxRecords;
    for i := first to High(recs) do
      sb.Add('  ' + recs[i].Describe);
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

{ TObsBusRecorder }

constructor TObsBusRecorder.Create(ABus: TEventBus; ALog: TObsLog);
begin
  inherited Create;
  if ABus = nil then
    raise Exception.Create('TObsBusRecorder: バスが指定されていません');
  if ALog = nil then
    raise Exception.Create('TObsBusRecorder: 記録先が指定されていません');
  FBus := ABus;
  FLog := ALog;
  FBus.Subscribe(@Handle);
end;

destructor TObsBusRecorder.Destroy;
begin
  if Assigned(FBus) then
    FBus.Unsubscribe(@Handle);
  inherited Destroy;
end;

procedure TObsBusRecorder.Handle(const AEvent: TBusEvent);
{ バスのイベントを記録用の語彙へ翻訳する。
  すべてを記録するのではなく、診断と改善に効くものだけを残す。
  周波数や S メーターのような合流イベントは、値そのものより
  統計の方が意味があるので出来事としては残さない。 }
begin
  case AEvent.Kind of
    bekDecodedSymbol:
      begin
        { アルゴリズム改善のための材料。発行元 (復調戦略名) と
          尺度・SNR を残す。 }
        if Assigned(FDecodeMetric) and (AEvent.D2 <> 0) then
          FDecodeMetric.Observe(AEvent.D2);
        FLog.Add(obsTrace, ocatDsp, ocdDecodeEmitted, AEvent.Source,
          AEvent.I1, AEvent.I2, AEvent.D1, AEvent.D2);
      end;
    bekTrxStateChanged:
      FLog.Add(obsInfo, ocatEngine, ocdTrxStateChanged, AEvent.Source,
        AEvent.I1);
    bekModemChanged:
      FLog.Add(obsInfo, ocatEngine, ocdModemChanged, AEvent.Source, AEvent.I1);
    bekRigChanged:
      FLog.Add(obsInfo, ocatRig, ocdRigChanged, AEvent.Source,
        AEvent.I1, AEvent.I2, AEvent.D1, AEvent.D2);
    bekStatusText:
      FLog.Add(obsInfo, ocatSystem, ocdStatus, AEvent.Source);
    bekError:
      FLog.Add(obsError, ocatSystem, ocdError, AEvent.Source);
  end;
end;

end.
