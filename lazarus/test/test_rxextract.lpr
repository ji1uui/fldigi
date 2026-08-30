{ ============================================================================
  test_rxextract.lpr

  受信テキストからの値抽出 (RxExtract.pas) と、
  マクロの宣言的条件分岐 (MacroEngine の <IF>/<REPEAT>) のテスト。

  重点:
    - コールサイン判定が実在する形をすべて通し、定型語を落とすこと
    - 確信度が「de の直後」「繰り返し」「直近」を反映すること
    - 抽出した値が局面を自動的に進めること (MacroEngine との接続)
    - 条件分岐が "展開時に" 解決され、結果が平坦な列になること
      (= 送信前バリデーションがそのまま効くこと)

  実行方法:
    ./run_tests.sh   もしくは
    fpc -Fuunits -FEtest -otest_rxextract test/test_rxextract.lpr
  ============================================================================ }
program test_rxextract;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, MacroEngine, RxExtract, Requirements;

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

procedure CheckEq(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: [', AExpected, ']');
    WriteLn('        実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

procedure TestCallsignShapes;
var
  i: Integer;
const
  GOOD: array[0..13] of string = (
    'JA1ZZZ', 'JI1UUI', 'W1AW', 'K1AB', '7J1ABC', '2E0ABC', '3DA0AB',
    'VK9NS', 'JA1ZZZ/1', 'JI1UUI/P', 'VP2E/W1AW', 'DL1ABC/QRP',
    'G0ABC', 'PY2XYZ');
  BAD: array[0..12] of string = (
    'CQ', 'DE', 'TEST', '599', '5NN', 'TU', 'QRZ', '73', 'ABCDE',
    '12345', 'K1', 'UP1', 'RST');
begin
  WriteLn;
  WriteLn('--- 1. コールサインの形の判定 ---');
  for i := Low(GOOD) to High(GOOD) do
    Check(IsPlausibleCallsign(GOOD[i]), 'コールと認める: ' + GOOD[i]);
  for i := Low(BAD) to High(BAD) do
    Check(not IsPlausibleCallsign(BAD[i]), 'コールと認めない: ' + BAD[i]);
end;

procedure TestRstAndLocator;
begin
  WriteLn;
  WriteLn('--- 2. RST・ロケータ・カットナンバー ---');
  Check(IsPlausibleRst('599'), '599 は RST');
  Check(IsPlausibleRst('59'), '59 は RST (電話)');
  Check(IsPlausibleRst('5NN'), '5NN は RST (カットナンバー)');
  Check(IsPlausibleRst('339'), '339 は RST');
  Check(not IsPlausibleRst('699'), '699 は RST でない (R が範囲外)');
  Check(not IsPlausibleRst('509'), '509 は RST でない (S が 0)');
  Check(not IsPlausibleRst('5999'), '4桁は RST でない');

  CheckEq(FromCutNumbers('5NN'), '599', 'カットナンバーを戻す: 5NN');
  CheckEq(FromCutNumbers('1TT'), '100', 'カットナンバーを戻す: 1TT');
  CheckEq(FromCutNumbers('ABC'), 'ABC', '対象外の英字はそのまま');

  Check(IsPlausibleLocator('PM95'), 'PM95 はロケータ');
  Check(IsPlausibleLocator('PM95UL'), 'PM95UL はロケータ (6桁)');
  Check(not IsPlausibleLocator('ZZ95'), 'ZZ95 はロケータでない (A-R 外)');
  Check(not IsPlausibleLocator('PM9'), '3文字はロケータでない');
end;

procedure TestExtraction;
var
  rx: TRxExtractor;
  c: TRxCandidate;
  list: TRxCandidateArray;
begin
  WriteLn;
  WriteLn('--- 3. 受信テキストからの抽出 ---');
  rx := TRxExtractor.Create;
  try
    rx.MyCallsign := 'JI1UUI';

    { 典型的な呼ばれ方 }
    rx.Feed('JI1UUI DE JA1ZZZ JA1ZZZ K');
    Check(rx.IsBeingCalled, '自局が呼ばれていると判定される');
    Check(rx.BestCandidate(rtkCallsign, c), 'コール候補が見つかる');
    CheckEq(c.Text, 'JA1ZZZ', '呼んできた局のコールが最有力');
    Check(c.Confidence >= 70,
      '確信度が高い (de の直後 + 繰り返し)。実際: ' + IntToStr(c.Confidence));

    { 自局は候補に入らない }
    list := rx.Candidates(rtkCallsign);
    Check(Length(list) = 1,
      '自局コールは候補から外れる (候補数 ' + IntToStr(Length(list)) + ')');

    { 交換の受信 }
    rx.Clear;
    rx.Feed('JI1UUI DE JA1ZZZ 599 032 599 032 K');
    Check(rx.BestCandidate(rtkRst, c), 'RST 候補が見つかる');
    CheckEq(c.Text, '599', 'RST が取れる');
    Check(rx.BestCandidate(rtkSerial, c), 'ナンバー候補が見つかる');
    CheckEq(c.Text, '032', '送信ナンバーが取れる');

    { 599 以外のレポート。「RST の直後が数字」という交換の形を
      手がかりにできないと拾えない (599 なら定番なので拾えてしまうため、
      ここを 579 にしないと検査にならない)。 }
    rx.Clear;
    rx.Feed('JI1UUI DE JA1ZZZ 579 032 K');
    Check(rx.BestCandidate(rtkRst, c), '599 以外の RST も見つかる');
    CheckEq(c.Text, '579', '579 が取れる');
    Check(c.Confidence >= 70,
      '交換の形 (RST の直後が数字) を根拠に採用水準に達する。実際: ' +
      IntToStr(c.Confidence));

    { カットナンバーの交換 }
    rx.Clear;
    rx.Feed('JI1UUI DE JA1ZZZ 5NN TTN');
    Check(rx.BestCandidate(rtkRst, c), 'カットナンバーの RST が見つかる');
    CheckEq(c.Text, '599', 'カットナンバーが数字に戻る');
    CheckEq(c.RawText, '5NN', '受信そのままも保持する');
    Check(rx.BestCandidate(rtkSerial, c), 'カットナンバーのナンバーが見つかる');
    CheckEq(c.Text, '009', 'ナンバーも数字に戻る');

    { ロケータ }
    rx.Clear;
    rx.Feed('DE JA1ZZZ MY LOC IS PM95UL');
    Check(rx.BestCandidate(rtkLocator, c), 'ロケータが取れる');
    CheckEq(c.Text, 'PM95UL', 'ロケータの値');

    { 定型文だけならコール候補は出ない }
    rx.Clear;
    rx.Feed('CQ CQ CQ TEST DE');
    Check(not rx.BestCandidate(rtkCallsign, c),
      '定型語だけならコール候補は出ない');

    { 自局が出てこなければ呼ばれていない }
    rx.Clear;
    rx.Feed('CQ CQ DE JA1ZZZ JA1ZZZ K');
    Check(not rx.IsBeingCalled, '自局が出てこなければ呼ばれていない');
    Check(rx.BestCandidate(rtkCallsign, c), 'それでも相手のコールは取れる');
    CheckEq(c.Text, 'JA1ZZZ', 'CQ を出している局のコール');

    { バッファ長の制限 }
    rx.Clear;
    rx.BufferLimit := 20;
    rx.Feed(StringOfChar('X', 100));
    Check(Length(rx.Buffer) = 20, 'バッファは上限で切り詰められる');
  finally
    rx.Free;
  end;
end;

procedure TestConfidenceOrdering;
var
  rx: TRxExtractor;
  list: TRxCandidateArray;
begin
  WriteLn;
  WriteLn('--- 4. 確信度の順序 ---');
  rx := TRxExtractor.Create;
  try
    rx.MyCallsign := 'JI1UUI';
    { JA1AAA は文中に 1 回、JA1ZZZ は de の直後で 2 回 }
    rx.Feed('TNX JA1AAA QSO JI1UUI DE JA1ZZZ JA1ZZZ K');
    list := rx.Candidates(rtkCallsign);
    Check(Length(list) >= 2, '候補が 2 件以上ある');
    if Length(list) >= 2 then
    begin
      CheckEq(list[0].Text, 'JA1ZZZ', 'de の直後で繰り返された方が上位');
      Check(list[0].Confidence > list[1].Confidence,
        '確信度に差がつく (' + IntToStr(list[0].Confidence) + ' > ' +
        IntToStr(list[1].Confidence) + ')');
    end;
  finally
    rx.Free;
  end;
end;

procedure TestApplyToContext;
{ 抽出した値がコンテキストへ入ると、局面が自動的に進むこと。
  ここが繋がって初めて、局面駆動のマクロ選択が実際に動き始める。 }
var
  rx: TRxExtractor;
  ctx: TMacroContext;
  n: Integer;
  c: TRxCandidate;
begin
  WriteLn;
  WriteLn('--- 5. コンテキストへの適用と局面の前進 ---');
  rx := TRxExtractor.Create;
  ctx := TMacroContext.Create;
  try
    rx.MyCallsign := 'JI1UUI';
    ctx.MyCall := 'JI1UUI';
    Check(ctx.Phase = qpIdle, '前提: 相手なし');

    rx.Feed('JI1UUI DE JA1ZZZ JA1ZZZ K');
    n := rx.ApplyTo(ctx);
    Check(n >= 1, '候補が適用される (' + IntToStr(n) + ' 件)');
    CheckEq(ctx.Call, 'JA1ZZZ', '相手のコールが入る');
    Check(ctx.Phase = qpAnswered,
      'コールが入ったことで局面が「コール取得」へ進む');

    { 続けて交換を受信 }
    rx.Feed(' 599 032 K');
    n := rx.ApplyTo(ctx);
    CheckEq(ctx.RstRcvd, '599', '受信 RST が入る');
    CheckEq(ctx.SerialIn, '032', '受信ナンバーが入る');
    Check(ctx.Phase = qpExchangeRcvd,
      '交換が入ったことで局面が「受領済み」へ進む (ログ可)');

    { 既に入っている値は上書きしない }
    ctx.Call := 'JA1YYY';
    rx.Clear;
    rx.Feed('JI1UUI DE JA1ZZZ JA1ZZZ K');
    rx.ApplyTo(ctx);
    CheckEq(ctx.Call, 'JA1YYY',
      '手で直した値をあとから来た受信で壊さない');

    { しきい値を上げると採用されない }
    ctx.ClearWorkedStation;
    rx.MinConfidence := 100;
    n := rx.ApplyTo(ctx);
    Check(n = 0, '確信度がしきい値に満たなければ採用しない');
    CheckEq(ctx.Call, '', 'コンテキストは変わらない');

    { 運用者が候補を選んで確定する経路 }
    rx.MinConfidence := 70;
    Check(rx.BestCandidate(rtkCallsign, c), '候補を取得できる');
    Check(rx.ApplyCandidate(c, ctx), '選んだ候補を確定できる');
    CheckEq(ctx.Call, 'JA1ZZZ', '確定した候補が入る');
  finally
    ctx.Free;
    rx.Free;
  end;
end;

procedure TestConditionals;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 6. 宣言的な条件分岐 ---');
  ctx := TMacroContext.Create;
  ex := TMacroExpander.Create;
  try
    ctx.MyCall := 'JI1UUI';
    ctx.Call := 'JA1ZZZ';
    ctx.RstSent := '599';
    ctx.Mode := 'CW';

    r := ex.Expand('<IF:MODE=CW><#CUT><ELSE><#><ENDIF>', ctx);
    CheckEq(r.PlainText, 'TT1', 'CW ならカットナンバー');
    Check(not r.HasErrors, 'エラーは出ない');

    ctx.Mode := 'RTTY';
    r := ex.Expand('<IF:MODE=CW><#CUT><ELSE><#><ENDIF>', ctx);
    CheckEq(r.PlainText, '001', 'RTTY なら通常のナンバー');

    r := ex.Expand('<IF:MODE=CW><#CUT><ENDIF>OK', ctx);
    CheckEq(r.PlainText, 'OK', '<ELSE> なしで条件が偽なら何も出ない');

    ctx.IsDuplicate := True;
    r := ex.Expand('<IF:DUPE>QSO B4<ELSE><CALL> 599<ENDIF>', ctx);
    CheckEq(r.PlainText, 'QSO B4', 'デュープで文面を変えられる');
    ctx.IsDuplicate := False;
    r := ex.Expand('<IF:DUPE>QSO B4<ELSE><CALL> 599<ENDIF>', ctx);
    CheckEq(r.PlainText, 'JA1ZZZ 599', 'デュープでなければ通常の交換');

    r := ex.Expand('<IF:EMPTY:NAME>OM<ELSE><NAME><ENDIF>', ctx);
    CheckEq(r.PlainText, 'OM', '名前が空なら OM で代替');
    ctx.Name := 'Taro';
    r := ex.Expand('<IF:HAS:NAME><NAME><ELSE>OM<ENDIF>', ctx);
    CheckEq(r.PlainText, 'Taro', '名前があれば名前');

    ctx.Role := qrSearchPounce;
    r := ex.Expand('<IF:ROLE=SP>call<ELSE>cq<ENDIF>', ctx);
    CheckEq(r.PlainText, 'call', '立場で分岐できる');

    ctx.Phase := qpExchangeRcvd;
    r := ex.Expand('<IF:PHASE GE exchangeRcvd>ok<ELSE>ng<ENDIF>', ctx);
    CheckEq(r.PlainText, 'ok', '局面で分岐できる (GE 比較)');
    r := ex.Expand('<IF:PHASE=exchangeRcvd>ok<ELSE>ng<ENDIF>', ctx);
    CheckEq(r.PlainText, 'ok', '局面の等値比較');

    ctx.ResetSerial(150);
    r := ex.Expand('<IF:SERIAL GT 100>many<ELSE>few<ENDIF>', ctx);
    CheckEq(r.PlainText, 'many', '送信ナンバーの数値比較 (GT)');
    r := ex.Expand('<IF:SERIAL LT 100>few<ELSE>many<ENDIF>', ctx);
    CheckEq(r.PlainText, 'many', '送信ナンバーの数値比較 (LT)');
    r := ex.Expand('<IF:MODE NE CW>notcw<ELSE>cw<ENDIF>', ctx);
    CheckEq(r.PlainText, 'notcw', '文字列の不一致比較 (NE)');

    ctx.ContestName := '';
    r := ex.Expand('<IF:CONTEST>test<ELSE>ragchew<ENDIF>', ctx);
    CheckEq(r.PlainText, 'ragchew', 'コンテスト運用かで分岐できる');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestRepeat;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 7. 反復 ---');
  ctx := TMacroContext.Create;
  ex := TMacroExpander.Create;
  try
    ctx.MyCall := 'JI1UUI';
    r := ex.Expand('<REPEAT:3>CQ <ENDREPEAT>de <MYCALL>', ctx);
    CheckEq(r.PlainText, 'CQ CQ CQ de JI1UUI', '3回繰り返す');

    r := ex.Expand('<REPEAT:0>CQ <ENDREPEAT>de', ctx);
    CheckEq(r.PlainText, 'de', '0回なら何も出ない');

    r := ex.Expand('<REPEAT:999>x<ENDREPEAT>', ctx);
    Check(r.HasErrors, '上限を超える回数はエラー');
    r := ex.Expand('<REPEAT:abc>x<ENDREPEAT>', ctx);
    Check(r.HasErrors, '数値でない回数はエラー');

    { 入れ子 }
    ctx.IsDuplicate := True;
    r := ex.Expand('<REPEAT:2><IF:DUPE>D<ENDIF>x<ENDREPEAT>', ctx);
    CheckEq(r.PlainText, 'DxDx', '反復の中の条件分岐');
    r := ex.Expand('<IF:DUPE><REPEAT:2>y<ENDREPEAT><ENDIF>', ctx);
    CheckEq(r.PlainText, 'yy', '条件分岐の中の反復');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestConditionalErrors;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 8. 分岐の書き間違いを捕まえる ---');
  ctx := TMacroContext.Create;
  ex := TMacroExpander.Create;
  try
    ctx.MyCall := 'JI1UUI';
    ctx.Mode := 'CW';

    r := ex.Expand('<IF:MODE=CW>x', ctx);
    Check(r.HasErrors, '<ENDIF> が無ければエラー');
    r := ex.Expand('<REPEAT:2>x', ctx);
    Check(r.HasErrors, '<ENDREPEAT> が無ければエラー');
    r := ex.Expand('<ENDIF>', ctx);
    Check(r.HasErrors, '対応する開きが無い閉じタグはエラー');
    r := ex.Expand('<ELSE>x', ctx);
    Check(r.HasErrors, '単独の <ELSE> はエラー');

    r := ex.Expand('<IF:DUPE><REPEAT:2>a<ENDIF><ENDREPEAT>', ctx);
    Check(r.HasErrors, 'ブロックが交差していればエラー');
    Check(Pos('交差', r.IssueText) > 0, '交差だと分かる指摘');

    r := ex.Expand('<IF:NOSUCHCOND>x<ENDIF>', ctx);
    Check(r.HasErrors, '知らない条件はエラー');
    r := ex.Expand('<IF:>x<ENDIF>', ctx);
    Check(r.HasErrors, '条件が空ならエラー');
    r := ex.Expand('<IF:HAS:NOSUCHTAG>x<ENDIF>', ctx);
    Check(r.HasErrors, 'HAS: に知らないタグを書けばエラー');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestConditionalsStayValidatable;
{ 条件分岐を "展開時に" 解決していることの確認。
  展開後は条件の無い平坦な列になるので、送信前バリデーションが
  そのまま効く ― つまり「今回実際に送られるもの」を検査できる。
  スクリプト言語を実行時に走らせる設計だとこれが成立しない。 }
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 9. 分岐しても送信前バリデーションが効くこと ---');
  ctx := TMacroContext.Create;
  ex := TMacroExpander.Create;
  try
    ctx.MyCall := 'JI1UUI';
    ctx.Call := 'JA1ZZZ';
    ctx.RstSent := '599';
    ctx.Mode := 'CW';

    { 分岐の片方だけ <RX> を書き忘れている }
    ctx.IsDuplicate := False;
    r := ex.Prepare('<IF:DUPE><TX>B4<RX><ELSE><TX>QSO<ENDIF>', ctx);
    Check(r.HasErrors,
      '選ばれた枝に <RX> が無ければエラーになる');

    ctx.IsDuplicate := True;
    r := ex.Prepare('<IF:DUPE><TX>B4<RX><ELSE><TX>QSO<ENDIF>', ctx);
    Check(not r.HasErrors,
      '選ばれた枝が正しければエラーにならない (検査対象は実際に送るもの)');

    { 選ばれなかった枝のタグは「使ったタグ」に数えない }
    ctx.IsDuplicate := True;
    ctx.Name := '';
    r := ex.Prepare('<IF:DUPE><TX>B4<RX><ELSE><TX>tnx <NAME><RX><ENDIF>', ctx);
    Check(not r.HasWarnings,
      '選ばれなかった枝の <NAME> が空でも警告しない');

    ctx.IsDuplicate := False;
    r := ex.Prepare('<IF:DUPE><TX>B4<RX><ELSE><TX>tnx <NAME><RX><ENDIF>', ctx);
    Check(r.HasWarnings,
      '選ばれた枝の <NAME> が空なら警告する');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

begin
  WriteLn('=== 受信抽出 / 宣言的条件分岐 テスト ===');

  TestCallsignShapes;
  TestRstAndLocator;
  TestExtraction;
  TestConfidenceOrdering;
  TestApplyToContext;
  TestConditionals;
  TestRepeat;
  TestConditionalErrors;
  TestConditionalsStayValidatable;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('CTX-001');
  end;

  if FailCount > 0 then
    Halt(1);
end.
