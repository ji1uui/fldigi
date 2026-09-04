{ ============================================================================
  Requirements.pas

  Architecture & Requirements Baseline v1.1 §18 要求トレーサビリティ。

  §18 はこう定めている。

    全要求に REQ-ID、Experience、Objective、Primary Foundation、
    Secondary Foundation、Extension Dependency、Priority、
    Implementation Phase、Verification Method、Status を付与する。
    Primary Foundation は原則 1 つに限定する。
    Extension Dependency は『当該要求が Extension Platform または特定
    Plugin/Provider 機能に依存するか』を表す。

  なぜ表を手で書かないのか
  ----------------------------------------------------------------------------
  トレーサビリティ表がやがて役に立たなくなる理由は決まっている。
  **表と実物がずれても誰も気づかない** からである。とくに Status 欄が

      「検証済み」と書いてあるが、それを確かめる試験は存在しない

  になる。この状態の表は、無いより悪い。無ければ確かめに行くが、あれば
  信じてしまう。

  そこで本ユニットでは、

    1. 要求そのものを **データ** として持つ (この表が正)。
    2. 試験が実行時に「この REQ-ID を検証した」と申告する (CoverReq)。
       文字列を書いておくのではなく、実際に走ったことが記録される。
    3. 突き合わせを **試験で** 行う (test_requirements)。
       検証済みなのに誰も検証していない要求があれば落ちる。
    4. 文書 (docs/requirements-matrix.md) は表から **生成** する。
       手で直せないようにしておけば、ずれようがない。

  REQ-ID の出どころについて
  ----------------------------------------------------------------------------
  Baseline §18 は 7 件の例 (RTTY-021 / GUI-014 / CTX-008 / PLG-002 /
  QSL-004 / AWD-003 / CNT-010) を挙げているが、全要求の一覧は与えて
  いない。したがって:

    - 上記 7 件は Baseline の記載を **そのまま** 使う。
    - それ以外は Baseline 本文からこちらで起こしたものである。
      Source 欄に本文のどこから来たかを必ず書く。

  この区別を曖昧にすると「Baseline にそう書いてある」と誤解される。
  IsFromBaseline がその区別を保持する。
  ============================================================================ }
unit Requirements;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils;

const
  { いま到達しているフェーズ。Status が rsVerified の要求は、この値より
    後のフェーズのものであってはならない (Phase 5 の要求を Phase 0 で
    「検証済み」とは言えない)。

    Phase 0 の項目がすべて揃ったので 1 へ進めた。ここを上げるのは
    「そのフェーズに着手した」という宣言であって、完了の宣言ではない。
    上げた瞬間にそのフェーズの要求が「検証済」を名乗れるようになるので、
    実際に試験が申告しているかは test_requirements が突き合わせる。 }
  CURRENT_PHASE = 2;

type
  ERequirementsError = class(Exception);

  { §2 の Amateur Radio Experience。 }
  TExperience = (
    expNone,
    expCommunicate,
    expDiscover,
    expCompete,
    expCollect,
    expLearn,
    expExperiment
  );

  { §3 の 4 Development Objectives。 }
  TObjective = (
    objCompatibility,   // A
    objRobustness,      // B
    objPerformance,     // C
    objNewExperience    // D
  );

  { §14 の 3 Foundations。 }
  TFoundation = (
    fndNone,
    fndModernComputing,       // X
    fndIntelligentReceiver,   // Y
    fndEngineeringQuality     // Z
  );
  TFoundations = set of TFoundation;

  TPriority = (priMust, priShould, priCould);

  TReqStatus = (
    rsProposed,     // 起こしただけ
    rsAccepted,     // 方針として決まった (ADR など)
    rsImplemented,  // 実装した。ただし試験で固定していない
    rsVerified,     // 実装し、試験で固定した
    rsDeferred      // 後のフェーズへ送った
  );

  TRequirement = record
    Id: string;
    Text: string;
    Experience: TExperience;
    Objective: TObjective;
    { §18「Primary Foundation は原則 1 つに限定する」。 }
    Primary: TFoundation;
    Secondary: TFoundations;
    { §18「Extension Platform または特定 Plugin/Provider 機能に依存するか」。 }
    ExtensionDependency: Boolean;
    Priority: TPriority;
    Phase: Integer;
    Verification: string;
    Status: TReqStatus;
    { Baseline のどこから来たか。'§8.1' など。 }
    Source: string;
    { 関連する ADR。無ければ空。 }
    Adr: string;
    { Baseline §18 の表にそのまま載っているか。
      こちらで起こしたものと区別する。 }
    IsFromBaseline: Boolean;
    function Describe: string;
  end;

  TReqIssueLevel = (rilError, rilWarning);

  TReqIssue = record
    Level: TReqIssueLevel;
    ReqId: string;
    Message: string;
  end;
  TReqIssueArray = array of TReqIssue;

  TRequirementRegistry = class
  private
    FItems: array of TRequirement;
    function IndexOfId(const AId: string): Integer;
  public
    procedure Add(const AReq: TRequirement);
    function Count: Integer;
    function ItemAt(AIndex: Integer): TRequirement;
    function Find(const AId: string; out AReq: TRequirement): Boolean;
    function Has(const AId: string): Boolean;
    function CountByStatus(AStatus: TReqStatus): Integer;
    function CountByPhase(APhase: Integer): Integer;

    { §18 の制約と、表そのものの整合性を検査する。
      ACoveredIds には、実際に試験が申告した REQ-ID を渡す
      (nil なら被覆の検査を行わない)。 }
    function Validate(ACoveredIds: TStrings): TReqIssueArray;

    { 表から文書を作る。手で書かないための出口。 }
    function ToMarkdown(ACoveredIds: TStrings): string;
    function Summary: string;
  end;

{ Baseline v1.1 から起こした要求一覧を返す。呼び出し側が解放する。 }
function BuildBaselineRegistry: TRequirementRegistry;

{ ---------------------------------------------------------------------------
  被覆の申告

  試験がこれを呼ぶ。呼ばれた事実が記録されるので、
  「書いてあるだけ」にはならない。
  プログラム終了時に test/coverage/<実行ファイル名>.reqs へ書き出す。
  --------------------------------------------------------------------------- }
procedure CoverReq(const AReqId: string);
function CoveredCount: Integer;
{ 収集した申告を読み込む (test_requirements が使う)。
  戻り値: 読み込んだファイル数。 }
function LoadCoverage(const ADir: string; ACoveredIds: TStrings): Integer;
{ 書き出し先。既定は実行ファイルの隣の coverage/。 }
function CoverageDir: string;

function ExperienceToStr(A: TExperience): string;
function ObjectiveToStr(A: TObjective): string;
function FoundationToStr(A: TFoundation): string;
function FoundationsToStr(A: TFoundations): string;
function PriorityToStr(A: TPriority): string;
function ReqStatusToStr(A: TReqStatus): string;

implementation

var
  GCovered: TStringList = nil;

{ ============================ 名前 ============================ }

function ExperienceToStr(A: TExperience): string;
begin
  case A of
    expCommunicate: Result := 'Communicate';
    expDiscover:    Result := 'Discover';
    expCompete:     Result := 'Compete';
    expCollect:     Result := 'Collect';
    expLearn:       Result := 'Learn';
    expExperiment:  Result := 'Experiment';
  else
    Result := '-';
  end;
end;

function ObjectiveToStr(A: TObjective): string;
begin
  case A of
    objCompatibility: Result := 'A';
    objRobustness:    Result := 'B';
    objPerformance:   Result := 'C';
  else
    Result := 'D';
  end;
end;

function FoundationToStr(A: TFoundation): string;
begin
  case A of
    fndModernComputing:     Result := 'X';
    fndIntelligentReceiver: Result := 'Y';
    fndEngineeringQuality:  Result := 'Z';
  else
    Result := '-';
  end;
end;

function FoundationsToStr(A: TFoundations): string;
var
  f: TFoundation;
begin
  Result := '';
  for f := fndModernComputing to fndEngineeringQuality do
    if f in A then
    begin
      if Result <> '' then Result := Result + '/';
      Result := Result + FoundationToStr(f);
    end;
  if Result = '' then Result := '-';
end;

function PriorityToStr(A: TPriority): string;
begin
  case A of
    priMust:   Result := 'Must';
    priShould: Result := 'Should';
  else
    Result := 'Could';
  end;
end;

function ReqStatusToStr(A: TReqStatus): string;
begin
  case A of
    rsProposed:    Result := '起案';
    rsAccepted:    Result := '方針決定';
    rsImplemented: Result := '実装済';
    rsVerified:    Result := '検証済';
  else
    Result := '後送り';
  end;
end;

function TRequirement.Describe: string;
begin
  Result := Format('%s %s [%s/%s/%s] Phase %d %s',
    [Id, Text, ExperienceToStr(Experience), ObjectiveToStr(Objective),
     FoundationToStr(Primary), Phase, ReqStatusToStr(Status)]);
end;

{ ============================ 被覆の申告 ============================ }

function CoverageDir: string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + 'coverage');
end;

procedure CoverReq(const AReqId: string);
begin
  if Trim(AReqId) = '' then Exit;
  if GCovered = nil then
  begin
    GCovered := TStringList.Create;
    GCovered.Sorted := True;
    GCovered.Duplicates := dupIgnore;
    GCovered.CaseSensitive := False;
  end;
  GCovered.Add(UpperCase(Trim(AReqId)));
end;

function CoveredCount: Integer;
begin
  if GCovered = nil then Exit(0);
  Result := GCovered.Count;
end;

function LoadCoverage(const ADir: string; ACoveredIds: TStrings): Integer;
var
  rec: TSearchRec;
  sl: TStringList;
  i: Integer;
  dir: string;
begin
  Result := 0;
  dir := IncludeTrailingPathDelimiter(ADir);
  if not DirectoryExists(dir) then Exit;
  if FindFirst(dir + '*.reqs', faAnyFile, rec) <> 0 then Exit;
  try
    sl := TStringList.Create;
    try
      repeat
        if (rec.Attr and faDirectory) <> 0 then Continue;
        sl.LoadFromFile(dir + rec.Name);
        for i := 0 to sl.Count - 1 do
          if Trim(sl[i]) <> '' then
            ACoveredIds.Add(UpperCase(Trim(sl[i])));
        Inc(Result);
      until FindNext(rec) <> 0;
    finally
      sl.Free;
    end;
  finally
    FindClose(rec);
  end;
end;

{ ============================ TRequirementRegistry ============================ }

function TRequirementRegistry.IndexOfId(const AId: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if SameText(FItems[i].Id, AId) then Exit(i);
  Result := -1;
end;

procedure TRequirementRegistry.Add(const AReq: TRequirement);
var
  n: Integer;
begin
  n := Length(FItems);
  SetLength(FItems, n + 1);
  FItems[n] := AReq;
end;

function TRequirementRegistry.Count: Integer;
begin
  Result := Length(FItems);
end;

function TRequirementRegistry.ItemAt(AIndex: Integer): TRequirement;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise ERequirementsError.CreateFmt(
      '要求の添字が範囲外です (要求 %d / 件数 %d)', [AIndex, Length(FItems)]);
  Result := FItems[AIndex];
end;

function TRequirementRegistry.Find(const AId: string;
  out AReq: TRequirement): Boolean;
var
  i: Integer;
begin
  FillChar(AReq, SizeOf(AReq), 0);
  i := IndexOfId(AId);
  Result := i >= 0;
  if Result then
    AReq := FItems[i];
end;

function TRequirementRegistry.Has(const AId: string): Boolean;
begin
  Result := IndexOfId(AId) >= 0;
end;

function TRequirementRegistry.CountByStatus(AStatus: TReqStatus): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Status = AStatus then Inc(Result);
end;

function TRequirementRegistry.CountByPhase(APhase: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Phase = APhase then Inc(Result);
end;

function TRequirementRegistry.Validate(ACoveredIds: TStrings): TReqIssueArray;
var
  i, j, n: Integer;
  r: TRequirement;

  procedure Issue(ALevel: TReqIssueLevel; const AId, AMsg: string);
  begin
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Level := ALevel;
    Result[n].ReqId := AId;
    Result[n].Message := AMsg;
  end;

begin
  Result := nil;
  for i := 0 to High(FItems) do
  begin
    r := FItems[i];

    if Trim(r.Id) = '' then
      Issue(rilError, '(空)', 'REQ-ID が空です。');

    { REQ-ID の一意性。重複すると被覆の突き合わせが意味を失う。 }
    for j := i + 1 to High(FItems) do
      if SameText(FItems[j].Id, r.Id) then
        Issue(rilError, r.Id, 'REQ-ID が重複しています。');

    if Trim(r.Text) = '' then
      Issue(rilError, r.Id, '要求の本文が空です。');

    { §18「Primary Foundation は原則 1 つに限定する」。 }
    if r.Primary = fndNone then
      Issue(rilError, r.Id, 'Primary Foundation が指定されていません (§18)。');
    if r.Primary in r.Secondary then
      Issue(rilError, r.Id,
        'Primary Foundation が Secondary にも入っています (§18: Primary は 1 つ)。');

    if Trim(r.Verification) = '' then
      Issue(rilError, r.Id, 'Verification Method が空です (§18)。');

    if (r.Phase < 0) or (r.Phase > 7) then
      Issue(rilError, r.Id,
        Format('Implementation Phase が範囲外です (%d)。', [r.Phase]));

    if Trim(r.Source) = '' then
      Issue(rilWarning, r.Id, 'Baseline のどこから来たかが書かれていません。');

    { --- Status と実物の突き合わせ --- }
    if r.Status = rsVerified then
    begin
      if r.Phase > CURRENT_PHASE then
        Issue(rilError, r.Id, Format(
          'Phase %d の要求が「検証済」になっています (現在 Phase %d)。',
          [r.Phase, CURRENT_PHASE]));

      if ACoveredIds <> nil then
        if ACoveredIds.IndexOf(UpperCase(r.Id)) < 0 then
          { これがこの仕組みの要点。「検証済」と書いてあるのに、
            それを申告した試験が 1 つも無い状態を落とす。 }
          Issue(rilError, r.Id,
            '「検証済」ですが、この REQ-ID を検証したと申告した試験が' +
            'ありません。');
    end;

    if (r.Status = rsDeferred) and (r.Phase <= CURRENT_PHASE) then
      Issue(rilWarning, r.Id, Format(
        '「後送り」ですが Phase %d は現在フェーズ以下です。', [r.Phase]));
  end;

  { 表に無い REQ-ID を試験が申告している = 綴り誤りか、表への追加忘れ。 }
  if ACoveredIds <> nil then
    for i := 0 to ACoveredIds.Count - 1 do
      if not Has(ACoveredIds[i]) then
        Issue(rilError, ACoveredIds[i],
          '試験が申告した REQ-ID が要求一覧にありません。');
end;

function TRequirementRegistry.Summary: string;
begin
  Result := Format(
    '要求 %d 件 (検証済 %d / 実装済 %d / 方針決定 %d / 起案 %d / 後送り %d)',
    [Count, CountByStatus(rsVerified), CountByStatus(rsImplemented),
     CountByStatus(rsAccepted), CountByStatus(rsProposed),
     CountByStatus(rsDeferred)]);
end;

function TRequirementRegistry.ToMarkdown(ACoveredIds: TStrings): string;
var
  i, ph: Integer;
  r: TRequirement;
  sl: TStringList;
  ext, cov: string;
begin
  sl := TStringList.Create;
  try
    sl.Add('# 要求トレーサビリティ表 (Baseline v1.1 §18)');
    sl.Add('');
    sl.Add('**この文書は `units/Requirements.pas` から生成されている。' +
           '直接編集しないこと。**');
    sl.Add('生成しなおすには `./test/test_requirements` を実行する。');
    sl.Add('');
    sl.Add('項目は §18 の定めるとおり REQ-ID / Experience / Objective /');
    sl.Add('Primary / Secondary / Extension / Priority / Phase /');
    sl.Add('Verification / Status。Primary Foundation は 1 つに限る。');
    sl.Add('');
    sl.Add('「検証」欄の ✓ は、その REQ-ID を検証したと **試験が実行時に');
    sl.Add('申告した** ことを示す。表に書いてあるだけではこの印は付かない。');
    sl.Add('');
    sl.Add('出典が `§18` の行は Baseline の表にそのまま載っているもの、');
    sl.Add('それ以外は Baseline 本文からこのプロジェクトで起こしたもの。');
    sl.Add('');
    sl.Add(Summary);
    sl.Add('');

    for ph := 0 to 7 do
    begin
      if CountByPhase(ph) = 0 then Continue;
      sl.Add(Format('## Phase %d', [ph]));
      sl.Add('');
      sl.Add('| REQ-ID | 要求 | Exp | Obj | Pri | Sec | Ext | Prio | Verification | Status | 検証 | 出典 | ADR |');
      sl.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
      for i := 0 to High(FItems) do
      begin
        r := FItems[i];
        if r.Phase <> ph then Continue;
        if r.ExtensionDependency then ext := 'Yes' else ext := 'No';
        cov := '';
        if (ACoveredIds <> nil) and
           (ACoveredIds.IndexOf(UpperCase(r.Id)) >= 0) then
          cov := '✓';
        sl.Add(Format('| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |',
          [r.Id, r.Text, ExperienceToStr(r.Experience),
           ObjectiveToStr(r.Objective), FoundationToStr(r.Primary),
           FoundationsToStr(r.Secondary), ext, PriorityToStr(r.Priority),
           r.Verification, ReqStatusToStr(r.Status), cov, r.Source, r.Adr]));
      end;
      sl.Add('');
    end;

    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

{ ============================================================================
  Baseline v1.1 から起こした要求一覧
  ============================================================================ }

function BuildBaselineRegistry: TRequirementRegistry;
var
  reg: TRequirementRegistry;

  procedure R(const AId, AText: string; AExp: TExperience; AObj: TObjective;
    APri: TFoundation; ASec: TFoundations; AExt: Boolean; APrio: TPriority;
    APhase: Integer; const AVerify: string; AStatus: TReqStatus;
    const ASource, AAdr: string; AFromBaseline: Boolean = False);
  var
    q: TRequirement;
  begin
    q.Id := AId;
    q.Text := AText;
    q.Experience := AExp;
    q.Objective := AObj;
    q.Primary := APri;
    q.Secondary := ASec;
    q.ExtensionDependency := AExt;
    q.Priority := APrio;
    q.Phase := APhase;
    q.Verification := AVerify;
    q.Status := AStatus;
    q.Source := ASource;
    q.Adr := AAdr;
    q.IsFromBaseline := AFromBaseline;
    reg.Add(q);
  end;

begin
  reg := TRequirementRegistry.Create;
  Result := reg;

  { ======================================================================
    Baseline §18 の表にそのまま載っている 7 件。

    Status の付け方 (Baseline §18 の表には Status/Priority の欄が無いので
    こちらで補う):
      rsAccepted  — ADR で設計が決まっているもの。実装の一部が Phase 0 に
                    あっても、要求そのものは後段フェーズのものなので
                    「実装済」とは言わない。
      rsProposed  — まだ決めていないもの。
    たとえば QSL-004 (複数 QSL Confirmation) の **データモデル** は
    Phase 0 で実装し試験もしたが、要求そのものは Phase 6 の
    「QSL Provider との送受信・同期」まで含む。Phase 0 で終えた部分は
    LOG-001..004 として別に立ててある。混ぜると進捗を過大に報告する。
    値は Baseline の記載どおり。Priority と Status は §18 の表に欄が
    無いのでこちらで補う (本文は 10 項目を要求している)。
    ====================================================================== }
  R('RTTY-021', 'QSB時に複数復調戦略を比較', expCommunicate, objPerformance,
    fndIntelligentReceiver, [fndModernComputing, fndEngineeringQuality],
    False, priMust, 3, 'Golden WAV BER/CER', rsProposed, '§18', 'ADR-002', True);
  R('GUI-014', '低Confidence文字を視覚表示', expCommunicate, objNewExperience,
    fndIntelligentReceiver, [fndEngineeringQuality],
    False, priMust, 4, 'UI検証・ユーザーテスト', rsProposed, '§18', '', True);
  R('CTX-008', 'Context補正をReject可能', expCommunicate, objNewExperience,
    fndIntelligentReceiver, [fndEngineeringQuality],
    False, priMust, 4, '機能・Undo回帰試験', rsProposed, '§18', '', True);
  R('PLG-002', '外部Modem Pluginをロード', expExperiment, objNewExperience,
    fndEngineeringQuality, [fndModernComputing],
    True, priMust, 5, 'RTTY Plugin Acceptance', rsProposed, '§18',
    'ADR-004/005', True);
  R('QSL-004', '複数QSL Confirmationを保持', expCollect, objNewExperience,
    fndEngineeringQuality, [],
    True, priMust, 6, 'Data model / sync test', rsAccepted, '§18',
    'ADR-011', True);
  R('AWD-003', 'QSO後にAward進捗更新', expCollect, objNewExperience,
    fndEngineeringQuality, [],
    True, priMust, 6, 'Rule test / regression', rsProposed, '§18', '', True);
  R('CNT-010', 'Contest Exchangeを構造化', expCompete, objNewExperience,
    fndIntelligentReceiver, [fndEngineeringQuality],
    True, priMust, 6, 'Contest vector test', rsAccepted, '§18',
    'ADR-011', True);

  { ======================================================================
    Phase 0 — ここから下は Baseline 本文からこちらで起こしたもの。
    Source 欄に本文の位置を書く。
    ====================================================================== }
  R('ARC-001', 'Audio/IQ/SpectrumをEvent Busに流さない',
    expCommunicate, objRobustness, fndEngineeringQuality,
    [fndModernComputing], False, priMust, 0,
    'test_eventbus / test_realtime', rsVerified, '§12, §19 ADR-001', 'ADR-001');
  R('ARC-002', 'Modem APIが複数候補とEvidenceを返せる',
    expCommunicate, objNewExperience, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priMust, 0,
    'test_evidence', rsVerified, '§6, §19 ADR-002', 'ADR-002');
  R('ARC-003', 'Subscriber例外でEvent Bus全体を停止させない',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priMust, 0, 'test_eventbus', rsVerified, '§12', 'ADR-001');
  R('ARC-004', '高頻度イベントで復調文字を押し出さない (conflation)',
    expCommunicate, objRobustness, fndEngineeringQuality,
    [fndModernComputing], False, priShould, 0,
    'test_eventbus / test_observability', rsVerified, '§12', 'ADR-001');

  R('RT-001', 'realtime経路で動的確保を行わない',
    expCommunicate, objPerformance, fndModernComputing,
    [fndEngineeringQuality], False, priMust, 0,
    'test_realtime (**全モデム**の送受信経路で確保回数を実測)', rsVerified,
    '§4 X-04。モデムを足したら試験も足すこと (PSK を足したとき漏れた)',
    'ADR-009');
  R('RT-002', 'ブロック処理がdeadlineを守る',
    expCommunicate, objPerformance, fndModernComputing,
    [fndEngineeringQuality], False, priMust, 0,
    'test_realtime (**全モデム**の受信ブロックで deadline 比を実測)',
    rsVerified,
    '§14 Z-04。モデムを足したら試験も足すこと (PSK を足したとき漏れた)',
    'ADR-009');
  R('RT-003', '並行性は要求から導き、並列性は実測から導く',
    expCommunicate, objPerformance, fndModernComputing, [], False,
    priShould, 0, '実測 (README §16)', rsAccepted, '§4 X-03', 'ADR-009');

  { --- Phase 1 Modern Runtime --- }
  R('RT-004', '取り込みと復調をRing Bufferで分離する',
    expCommunicate, objRobustness, fndModernComputing,
    [fndEngineeringQuality], False, priMust, 1,
    'test_audioring (2スレッド通し番号照合)', rsVerified, '§4 X-01, §5.1', '');
  R('RT-005', 'Audio History Bufferを保持しReplay Decodeを可能とする',
    expExperiment, objNewExperience, fndModernComputing,
    [fndIntelligentReceiver], False, priMust, 1,
    'test_audioring (並行書込下の整合性) / test_replay (流し直しの再現性)', rsVerified, '§4 X-06', '');
  R('RT-006', 'CPU core数を正しく検出しWorker数の根拠にする',
    expCommunicate, objPerformance, fndModernComputing, [],
    False, priMust, 1, 'test_audioring (TThread比較)', rsVerified,
    '§4 X-03, X-07', 'ADR-009');

  R('RT-007', 'Audio I/O専用経路をDSP重処理から分離する',
    expCommunicate, objRobustness, fndModernComputing,
    [fndEngineeringQuality], False, priMust, 1,
    'test_capture (実時間デバイスで欠落を実測)', rsVerified, '§4 X-01', '');

  R('RT-008', 'FFT等を共有サービス化し資源の重複を無くす',
    expCommunicate, objPerformance, fndModernComputing,
    [fndEngineeringQuality], False, priShould, 1,
    'test_fftshared (直接DFTとの照合・並行使用)', rsVerified, '§4 X-05', '');

  R('OBS-001', '障害診断のため出来事を時系列で残す',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priMust, 0, 'test_observability', rsVerified, '§14 Z-01', 'ADR-010');
  R('OBS-002', '観測の記録が動的確保を行わない',
    expCommunicate, objPerformance, fndEngineeringQuality,
    [fndModernComputing], False, priMust, 0,
    'test_observability (確保回数を実測)', rsVerified, '§14 Z-01, X-04', 'ADR-010');
  R('OBS-003', 'アルゴリズム改善のため数値の分布を残す',
    expCommunicate, objPerformance, fndEngineeringQuality, [],
    False, priShould, 0, 'test_observability', rsVerified, '§14 Z-01', 'ADR-010');

  R('LOG-001', '内部データモデルをADIFに制約しない',
    expCollect, objCompatibility, fndEngineeringQuality, [],
    False, priMust, 0, 'test_qsomodel (未知項目の往復)', rsVerified,
    '§13.4', 'ADR-011');
  R('LOG-002', '値ごとに出所と確定段階を持つ',
    expCommunicate, objNewExperience, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priMust, 0,
    'test_qsomodel', rsVerified, '§13.1', 'ADR-011');
  R('LOG-003', '局所IDと改訂番号で同期の競合を判定できる',
    expCollect, objRobustness, fndEngineeringQuality, [],
    True, priMust, 0, 'test_qsomodel', rsVerified, '§13.3', 'ADR-011');
  R('LOG-004', '書き出しの順序が安定している',
    expCollect, objRobustness, fndEngineeringQuality, [],
    False, priShould, 0, 'test_qsomodel', rsVerified, '§14 Z-05', 'ADR-011');

  R('PLG-001', 'Plugin互換性をSemVerとCapability Negotiationで扱う',
    expExperiment, objNewExperience, fndEngineeringQuality, [],
    True, priMust, 0, 'test_plugin', rsVerified, '§11.1, §19 ADR-004',
    'ADR-004');
  R('PLG-003', 'Plugin障害をCoreや他Pluginへ波及させない',
    expExperiment, objRobustness, fndEngineeringQuality, [],
    True, priMust, 0, 'test_plugin (壊れたPluginを実際に登録)', rsVerified,
    '§11.1', 'ADR-005');
  R('PLG-004', 'APIが将来のサブプロセス化・Sandbox化を妨げない',
    expExperiment, objRobustness, fndEngineeringQuality,
    [fndModernComputing], True, priMust, 0,
    'test_plugin (境界型のバイト列往復)', rsVerified, '§11.1, §19 ADR-005',
    'ADR-005');
  R('PLG-005', '外部Modem PluginはTest vectorsを必須提供する',
    expExperiment, objRobustness, fndEngineeringQuality, [],
    True, priMust, 0, 'test_plugin (交渉で拒否)', rsVerified,
    '§11.1', 'ADR-004');

  R('SEC-001', 'L6への保存はユーザー操作または明示的承認を前提とする',
    expCommunicate, objNewExperience, fndEngineeringQuality, [],
    False, priMust, 0, 'test_context_memory', rsVerified, '§8.1', 'ADR-003');
  R('SEC-002', '既定ではL5内で完結する',
    expCommunicate, objNewExperience, fndEngineeringQuality, [],
    False, priMust, 0, 'test_context_memory', rsVerified, '§8, §8.1',
    'ADR-003');
  R('SEC-003', '保存内容をView/Edit/Delete/Export/Importできる',
    expCommunicate, objNewExperience, fndEngineeringQuality, [],
    False, priMust, 0, 'test_context_memory', rsVerified, '§8.1', 'ADR-003');
  R('SEC-004', '保存形式は将来暗号化を可能にする設計とする',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priMust, 0, 'test_context_memory (容器の検査)', rsVerified,
    '§8.1', 'ADR-003');
  R('SEC-005', 'Name/QTH等の個人情報は最小限保持を原則とする',
    expCommunicate, objNewExperience, fndEngineeringQuality, [],
    False, priMust, 0, 'test_context_memory', rsVerified, '§8.1', 'ADR-003');
  R('SEC-006', '暗号化の実装方式をPhase 0で決定する',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priMust, 0, 'ADR-003 の記載 / 試験ベクタ照合', rsVerified,
    '§8.1', 'ADR-003');

  R('CMP-001', 'fldigi互換のADIF入出力を行う',
    expCollect, objCompatibility, fndEngineeringQuality, [],
    False, priMust, 0, 'test_adif_full / test_station_adif', rsVerified,
    '§3 A Compatibility', '');
  R('CMP-003', 'CW受信で先頭文字が失われない',
    expCommunicate, objRobustness, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priMust, 0,
    'test_cw_leading (速度/雑音/符号種を振って全文一致)', rsVerified,
    '§3 A Compatibility (fldigi 由来の欠陥の是正)', '');

  R('CMP-002', 'RTTY/CWの送受信がfldigi相当に成立する',
    expCommunicate, objCompatibility, fndIntelligentReceiver, [],
    False, priMust, 0, 'test_rtty_cw (ループバック)', rsVerified,
    '§3 A Compatibility', '');

  R('MAC-001', 'マクロがQSOの文脈と手順に沿って展開される',
    expCommunicate, objNewExperience, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priShould, 0,
    'test_macro', rsVerified, '§9', '');
  R('CTX-001', '受信テキストからコール/RST/ナンバーを抽出する',
    expCommunicate, objNewExperience, fndIntelligentReceiver, [],
    False, priShould, 0, 'test_rxextract', rsVerified, '§8 L2/L3', '');

  { ======================================================================
    後段フェーズ — いま着手しないもの。
    ここに並べておくのは、Phase 0 の設計がこれらを支えられているかを
    見るためである (支えられていなければ Phase 0 で直すべきだった)。
    ====================================================================== }
  { --- 保留 (2026-08) ---
    どちらも外部の暗号ライブラリを入れないと着手できない。方針は
    ADR-003 で決まっており、容器 (SecureStore) も入っているので、
    残っているのは中身の入れ替えだけである。

    保留してよいと判断した根拠 (README §30):
      - L6 は既定で無効 (SEC-002 検証済) で、保存には明示的承認が要る
        (SEC-001 検証済)。既定の運用では L6 に何も書かれない。
      - 保存形式は暗号化を前提に作ってある (SEC-004 検証済)。容器を
        通す設計なので、入れ替えても呼び出し側は変わらない。
    保留をやめる条件:
      - L6 を既定で有効にするとき
      - 保存先を利用者の管理下にない場所へ移すとき
      - 実機配布を始めるとき
    Context/L6 を実際に使い始める Phase 4 へ送る。 }
  R('ARC-005', 'L6 Persistent Memoryを実際に暗号化する',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priShould, 4, '外部ライブラリ導入後の往復試験', rsDeferred,
    '§8.1。方針は決定済み、実装のみ保留 (README §30)', 'ADR-003');
  R('ARC-006', 'OSの鍵保管と連携する',
    expCommunicate, objRobustness, fndModernComputing, [],
    False, priCould, 4, 'プラットフォーム別の結合試験', rsDeferred,
    '§8.1。ARC-005 の後でなければ意味がない (README §30)', 'ADR-003');
  R('MDM-002', 'CW受信の整定過渡で先頭要素を失わない',
    expCommunicate, objRobustness, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priShould, 1,
    'test_cw_leading (整定過渡・低S/N・雑音のみ) / test_cw_tone', rsVerified,
    '§3 A / §16。README §28', '');

  R('MDM-003', 'BPSK (PSK31/63/125) の送受信が成立する',
    expCommunicate, objCompatibility, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priMust, 2,
    'test_psk (往復・雑音耐性・全印字文字)', rsVerified,
    'Baseline Phase 2 Practical Compatible Core', '');
  R('MDM-004', 'PSK復調が軟判定の尺度をEvidenceに載せる',
    expCommunicate, objNewExperience, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priShould, 2,
    'test_psk (本文と雑音の余裕が分離することを実測)', rsVerified,
    'ADR-002 / §7 Phase 4 の Confidence の材料', 'ADR-002');
  R('MDM-005', 'PSK31 VaricodeがfldigiのTableと一致する',
    expCommunicate, objCompatibility, fndEngineeringQuality, [],
    False, priMust, 2,
    'test_psk_varicode (往復・符号の形・長さ分布・一意性)', rsVerified,
    'fldigi src/psk/pskvaricode.cxx', '');

  { --- 品質工学 (2026-09 のレビューで判明した欠落) ---
    Phase 2 で登録するのは、実際にこのフェーズで手を入れたからである。
    Phase 0/1 に遡って足すと「そのとき済んでいた」という嘘になる。 }
  R('QLT-001', '試験をアプリと同じ検査設定 (範囲/オーバーフロー) で実行する',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priMust, 2,
    'test_regression ({$IFOPT} でビルド指定そのものを検査)', rsVerified,
    '§14 Z-02。アプリ側 .lpi は有効、試験は無効という食い違いがあった', '');
  { 状態を rsVerified にしないのは、この表の定義では rsVerified が
    「試験で固定した」を意味するからである。解放漏れの照合は試験
    バイナリではなく run_tests.sh が行っており、CoverReq で申告できない。
    実行のたびに強制されてはいるが、定義に合わせて rsImplemented とする。
    過大に申告しない。 }
  R('QLT-003', '試験が解放漏れを起こさない',
    expCommunicate, objRobustness, fndEngineeringQuality, [],
    False, priMust, 2,
    'run_tests.sh が heaptrc を常時有効にし、スイートごとの許容数と照合して' +
    '超えたら失敗させる (試験バイナリからは申告できないため rsImplemented)',
    rsImplemented,
    '§14 Z-02。try..finally の欠落はこの言語で最も事故が多い形である', '');
  R('QLT-002', 'Test vectorsの波形が版を越えて同一である',
    expExperiment, objRobustness, fndEngineeringQuality, [],
    False, priMust, 2,
    'test_regression (乱数列と10分類の検査和を既知解で固定)', rsVerified,
    '§14.1 Golden WAV。同一性を謳いながら固定していなかった', '');

  { 品質レビューで挙がったが、**いま作ると作り直しになる**ので送る。
    Phase 5 の外部 Modem Plugin (PLG-002) が「Plugin が自分を登録する」
    機構を定めるので、モードからクラスへの対応表はその形に合わせるべき
    である。3 クラスのために別の機構を先に作ると二重になる。 }
  R('MDM-007', 'モードから復調器を作る窓口を一箇所に置く',
    expCommunicate, objNewExperience, fndEngineeringQuality, [],
    True, priShould, 5,
    'Plugin 登録機構と同じ表を使って全モードを生成できること', rsDeferred,
    '2026-09 の品質レビュー。PLG-002 の登録機構に合わせる', 'ADR-004');

  R('MDM-006', 'PSKがAFCで周波数ドリフトに追従する',
    expCommunicate, objRobustness, fndIntelligentReceiver, [],
    False, priShould, 3,
    'test_regression (Frequency drift の上限を既知の限界から引き下げる)',
    rsDeferred,
    'Baseline Phase 3 Adaptive Receiver の AFC。実測: 60Hz ドリフトで ' +
    'PSK31/63 は本文CER 0.79/0.86、CW と RTTY(AFC) は 0.00', '');

  R('MDM-001', '劣悪条件のTest vectorsで回帰試験を行う',
    expCommunicate, objRobustness, fndEngineeringQuality,
    [fndIntelligentReceiver], False, priMust, 2,
    'test_regression (4モード×10条件×8種の乱数でCER/BER)', rsVerified,
    '§14 Z-02, §14.1, §16, §17', '');
  R('CTX-002', 'Contextは強い物理Evidenceを安易に上書きしない',
    expCommunicate, objNewExperience, fndIntelligentReceiver, [],
    False, priMust, 4, 'Context回帰試験', rsDeferred, '§7', '');
  R('CTX-003', 'Confidenceを校正された確率として扱う',
    expCommunicate, objNewExperience, fndIntelligentReceiver,
    [fndEngineeringQuality], False, priMust, 4,
    'ECE / Brier Score / Reliability Diagram', rsDeferred, '§7 CF-01, §17.1',
    'ADR-002');
  R('CTX-004', 'L5登録条件をHigh Physical Confidence AND Format Validityとする',
    expCommunicate, objNewExperience, fndIntelligentReceiver, [],
    False, priMust, 4, 'Context回帰試験', rsDeferred, '§8, §19 ADR-008', '');
end;

initialization

finalization
  { 申告があれば書き出す。無ければ何もしない ── 被覆を使わない既存の
    試験に余計なファイルを作らせないため。 }
  if (GCovered <> nil) and (GCovered.Count > 0) then
  begin
    try
      ForceDirectories(CoverageDir);
      GCovered.SaveToFile(CoverageDir +
        ChangeFileExt(ExtractFileName(ParamStr(0)), '') + '.reqs');
    except
      { 書き出せなくても試験そのものを落とさない。 }
    end;
  end;
  GCovered.Free;

end.
