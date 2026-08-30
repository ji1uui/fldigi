{ ============================================================================
  test_requirements.lpr

  Baseline v1.1 §18 要求トレーサビリティの検査と、表の生成。

  この試験は他と役割が違う。**他の試験の結果を材料にする** ので、
  run_tests.sh では最後に走らせる。

  やること
  ----------------------------------------------------------------------------
  1. 要求一覧そのものの整合性を検査する (§18 の項目が揃っているか、
     Primary Foundation が 1 つか、など)。
  2. 各試験が実行時に申告した REQ-ID を集め、
     **「検証済」と書いてあるのに誰も検証していない要求** を落とす。
     これが無いと、表は書いた人の願望になる。
  3. docs/requirements-matrix.md を **生成** する。
     手で書かないので、表と実物がずれようがない。

  被覆の申告がどこから来るか
  ----------------------------------------------------------------------------
  各試験が Requirements.CoverReq を呼び、終了時に
  test/coverage/<試験名>.reqs へ書き出す。申告は
  **その試験が 1 件も失敗しなかったときだけ** 行われるので、
  落ちた試験が「検証した」と言うことはない。

  したがって、この試験を単体で走らせても被覆は空になる (材料が無い)。
  そのときは検査を飛ばし、その旨を印字する ── 材料が無いことを
  「全部通った」と報告してはならない。
  ============================================================================ }
program test_requirements;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils,
  Requirements, SafeFileIO;

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

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

{ --------------------------------------------------------------------------
  1. 要求一覧そのものの整合性 (§18)
  -------------------------------------------------------------------------- }
procedure TestRegistryIsWellFormed;
var
  reg: TRequirementRegistry;
  issues: TReqIssueArray;
  i, errs: Integer;
  r: TRequirement;
  baselineCount: Integer;
begin
  WriteLn;
  WriteLn('--- 1. 要求一覧の整合性 (§18) ---');
  reg := BuildBaselineRegistry;
  try
    Check(reg.Count > 0, '要求が登録されている');

    { §18 の表にそのまま載っている 7 件が入っていること。 }
    baselineCount := 0;
    for i := 0 to reg.Count - 1 do
      if reg.ItemAt(i).IsFromBaseline then Inc(baselineCount);
    CheckEqI(baselineCount, 7, 'Baseline §18 の 7 件がそのまま入っている');

    Check(reg.Has('RTTY-021') and reg.Has('GUI-014') and reg.Has('CTX-008') and
          reg.Has('PLG-002') and reg.Has('QSL-004') and reg.Has('AWD-003') and
          reg.Has('CNT-010'),
      'Baseline が挙げた REQ-ID がすべてある');

    { Baseline の記載と値が合っていること (書き写し間違いの検出)。 }
    Check(reg.Find('RTTY-021', r) and (r.Experience = expCommunicate) and
      (r.Objective = objPerformance) and (r.Primary = fndIntelligentReceiver) and
      (r.Phase = 3) and (not r.ExtensionDependency),
      'RTTY-021 の値が Baseline の表どおり');
    Check(reg.Find('PLG-002', r) and (r.Primary = fndEngineeringQuality) and
      r.ExtensionDependency and (r.Phase = 5),
      'PLG-002 の値が Baseline の表どおり (Extension=Yes)');
    Check(reg.Find('QSL-004', r) and (r.Experience = expCollect) and
      (r.Secondary = []) and r.ExtensionDependency and (r.Phase = 6),
      'QSL-004 の値が Baseline の表どおり (Secondary 空)');

    { こちらで起こしたものは出典が書かれていること。 }
    for i := 0 to reg.Count - 1 do
    begin
      r := reg.ItemAt(i);
      if r.IsFromBaseline then Continue;
      if Trim(r.Source) = '' then
      begin
        Check(False, r.Id + ' に出典が無い');
        Break;
      end;
    end;
    Check(True, 'こちらで起こした要求には Baseline の出典が書かれている');

    { 構造上の誤りが無いこと。被覆はここでは見ない (nil)。 }
    issues := reg.Validate(nil);
    errs := 0;
    for i := 0 to High(issues) do
      if issues[i].Level = rilError then
      begin
        Inc(errs);
        WriteLn('        [error] ', issues[i].ReqId, ': ', issues[i].Message);
      end;
    CheckEqI(errs, 0, '§18 の項目に欠けや矛盾が無い');

    for i := 0 to High(issues) do
      if issues[i].Level = rilWarning then
        WriteLn('        [warn ] ', issues[i].ReqId, ': ', issues[i].Message);
  finally
    reg.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. 検査そのものが働くこと

  「検証済なのに誰も検証していない」を落とせなければ、この仕組みは
  意味が無い。わざとその状態を作って、検出されることを確かめる。
  -------------------------------------------------------------------------- }
procedure TestValidatorCatchesLies;
var
  reg: TRequirementRegistry;
  r: TRequirement;
  covered: TStringList;
  issues: TReqIssueArray;
  i: Integer;
  found: Boolean;

  procedure Base(const AId: string; AStatus: TReqStatus; APhase: Integer);
  begin
    r.Id := AId;
    r.Text := 'テスト用';
    r.Experience := expCommunicate;
    r.Objective := objRobustness;
    r.Primary := fndEngineeringQuality;
    r.Secondary := [];
    r.ExtensionDependency := False;
    r.Priority := priMust;
    r.Phase := APhase;
    r.Verification := 'テスト';
    r.Status := AStatus;
    r.Source := '§0';
    r.Adr := '';
    r.IsFromBaseline := False;
  end;

  function HasErrorFor(const AId, AFragment: string): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    for k := 0 to High(issues) do
      if (issues[k].Level = rilError) and SameText(issues[k].ReqId, AId) and
         (Pos(AFragment, issues[k].Message) > 0) then
        Exit(True);
  end;

begin
  WriteLn;
  WriteLn('--- 2. 検査そのものが働くこと ---');
  covered := TStringList.Create;
  reg := TRequirementRegistry.Create;
  try
    { (a) 検証済だが誰も検証していない }
    Base('TST-001', rsVerified, 0);
    reg.Add(r);
    { (b) 検証済で、実際に申告がある }
    Base('TST-002', rsVerified, 0);
    reg.Add(r);
    covered.Add('TST-002');
    { (c) Primary が Secondary にも入っている (§18 違反) }
    Base('TST-003', rsAccepted, 0);
    r.Secondary := [fndEngineeringQuality];
    reg.Add(r);
    { (d) Verification Method が空 }
    Base('TST-004', rsAccepted, 0);
    r.Verification := '';
    reg.Add(r);
    { (e) Primary 未指定 }
    Base('TST-005', rsAccepted, 0);
    r.Primary := fndNone;
    reg.Add(r);
    { (f) 後段フェーズなのに検証済 }
    Base('TST-006', rsVerified, 5);
    reg.Add(r);
    covered.Add('TST-006');
    { (g) REQ-ID の重複 }
    Base('TST-007', rsAccepted, 0);
    reg.Add(r);
    Base('TST-007', rsAccepted, 0);
    reg.Add(r);
    { (h) 表に無い REQ-ID を試験が申告している }
    covered.Add('TST-999');

    issues := reg.Validate(covered);

    Check(HasErrorFor('TST-001', '申告した試験がありません'),
      '**「検証済」なのに誰も検証していない要求を落とす**');
    found := False;
    for i := 0 to High(issues) do
      if SameText(issues[i].ReqId, 'TST-002') then found := True;
    Check(not found, '申告がある要求は落とさない');
    Check(HasErrorFor('TST-003', 'Primary は 1 つ'),
      'Primary が Secondary にも入っていれば落とす (§18)');
    Check(HasErrorFor('TST-004', 'Verification Method'),
      'Verification Method が空なら落とす (§18)');
    Check(HasErrorFor('TST-005', 'Primary Foundation'),
      'Primary Foundation 未指定なら落とす (§18)');
    Check(HasErrorFor('TST-006', '現在 Phase'),
      '後段フェーズの要求を「検証済」にしていれば落とす');
    Check(HasErrorFor('TST-007', '重複'), 'REQ-ID の重複を落とす');
    Check(HasErrorFor('TST-999', '要求一覧にありません'),
      '表に無い REQ-ID の申告を落とす (綴り誤り・追加忘れ)');
  finally
    reg.Free;
    covered.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. 実際の被覆との突き合わせ
  -------------------------------------------------------------------------- }
procedure TestActualCoverage;
var
  reg: TRequirementRegistry;
  covered: TStringList;
  issues: TReqIssueArray;
  i, files, errs, verified: Integer;
  r: TRequirement;
begin
  WriteLn;
  WriteLn('--- 3. 実際の被覆との突き合わせ ---');
  reg := BuildBaselineRegistry;
  covered := TStringList.Create;
  try
    covered.Sorted := True;
    covered.Duplicates := dupIgnore;
    covered.CaseSensitive := False;
    files := LoadCoverage(CoverageDir, covered);

    WriteLn(Format('  被覆の申告: %d 個の試験から %d 件の REQ-ID',
      [files, covered.Count]));

    if files = 0 then
    begin
      { 材料が無いのに「全部通った」と言ってはならない。 }
      WriteLn('  [--] 他の試験がまだ走っていないため、突き合わせを飛ばす。');
      WriteLn('       (./run_tests.sh から実行すると突き合わせが行われる)');
      Exit;
    end;

    verified := reg.CountByStatus(rsVerified);
    WriteLn(Format('  「検証済」の要求: %d 件', [verified]));

    issues := reg.Validate(covered);
    errs := 0;
    for i := 0 to High(issues) do
      if issues[i].Level = rilError then
      begin
        Inc(errs);
        WriteLn('        [error] ', issues[i].ReqId, ': ', issues[i].Message);
      end;
    CheckEqI(errs, 0,
      '「検証済」の要求すべてに、実際に検証した試験がある');

    { 申告されたのに「検証済」でない要求があれば、表の更新漏れの可能性。
      落とさず注意にとどめる (先に試験を書くこともあるため)。 }
    for i := 0 to covered.Count - 1 do
      if reg.Find(covered[i], r) and (r.Status <> rsVerified) then
        WriteLn('        [warn ] ', r.Id,
          ': 試験は検証しているが Status が「', ReqStatusToStr(r.Status),
          '」のまま。');
  finally
    reg.Free;
    covered.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 表の生成
  -------------------------------------------------------------------------- }
procedure GenerateMatrix;
var
  reg: TRequirementRegistry;
  covered: TStringList;
  md, path: string;
begin
  WriteLn;
  WriteLn('--- 4. 表の生成 ---');
  reg := BuildBaselineRegistry;
  covered := TStringList.Create;
  try
    covered.Sorted := True;
    covered.Duplicates := dupIgnore;
    covered.CaseSensitive := False;
    LoadCoverage(CoverageDir, covered);

    md := reg.ToMarkdown(covered);
    Check(Pos('RTTY-021', md) > 0, '表に Baseline の要求が出る');
    Check(Pos('直接編集しないこと', md) > 0, '生成物である旨が書かれている');

    { 実行位置は test/ なので 1 つ上が lazarus/。 }
    path := ExtractFilePath(ParamStr(0)) + '../docs/requirements-matrix.md';
    try
      SaveTextAtomic(path, md);
      WriteLn('  生成: docs/requirements-matrix.md');
      Check(True, '表を書き出せた');
    except
      on E: Exception do
        Check(False, '表の書き出しに失敗: ' + E.Message);
    end;

    WriteLn('  ', reg.Summary);
  finally
    reg.Free;
    covered.Free;
  end;
end;

begin
  WriteLn('=== §18 要求トレーサビリティ 検査 ===');

  TestRegistryIsWellFormed;
  TestValidatorCatchesLies;
  TestActualCoverage;
  GenerateMatrix;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
