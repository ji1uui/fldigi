{ ============================================================================
  test_macro.lpr

  MacroEngine.pas (ラバースタンプ / コンテスト用マクロ展開) の単体テスト。

  重点:
    - 文字列と操作の "順序" が保たれること (ここが設計の要)
    - 送信ナンバーがログするまで進まないこと (コンテストの減点要因)
    - 送信前バリデーションが実際に危険を捕まえること
    - 日本語のマクロ名・注記が JSON 往復で壊れないこと

  実行方法:
    fpc -Fuunits -FEtest -otest_macro test/test_macro.lpr
    ./test/test_macro
  ============================================================================ }
program test_macro;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, DateUtils, MacroEngine, StationInfo;

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

function MakeContext: TMacroContext;
begin
  Result := TMacroContext.Create;
  Result.MyCall := 'JI1UUI';
  Result.MyName := 'Noma';
  Result.MyQth := 'Hachioji Tokyo';
  Result.MyLocator := 'PM95ul';
  Result.MyRig := 'IC-7300';
  Result.MyAntenna := 'Dipole';
  Result.MyPowerW := 50;
  Result.Call := 'JA1ZZZ';
  Result.Name := 'Taro';
  Result.Qth := 'Yokohama';
  Result.RstSent := '599';
  Result.RstRcvd := '579';
  Result.Band := '20m';
  Result.Mode := 'RTTY';
  Result.FreqMHz := 14.083;
  Result.ContestName := 'ALL JA';
  { 2026-08-28 07:05 UTC に固定 (時計に依存しないため) }
  Result.FixedUtcNow := EncodeDateTime(2026, 8, 28, 7, 5, 0, 0);
end;

{ --------------------------------------------------------------------- }

procedure TestBasicSubstitution;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 1. 差し込みタグの置換 ---');
  ctx := MakeContext;
  ex := TMacroExpander.Create;
  try
    r := ex.Expand('CQ de <MYCALL> <MYCALL> k', ctx);
    CheckEq(r.PlainText, 'CQ de JI1UUI JI1UUI k', '自局コールが置換される');

    r := ex.Expand('<CALL> de <MYCALL> ur rst <RST> name <MYNAME>', ctx);
    CheckEq(r.PlainText, 'JA1ZZZ de JI1UUI ur rst 599 name Noma',
      '相手局・RST・名前が置換される');

    r := ex.Expand('rig <MYRIG> pwr <MYPWR>W ant <MYANT>', ctx);
    CheckEq(r.PlainText, 'rig IC-7300 pwr 50W ant Dipole',
      'リグ・出力・アンテナが置換される');

    r := ex.Expand('<BAND> <MODE> <FREQ>', ctx);
    CheckEq(r.PlainText, '20m RTTY 14.083', 'バンド・モード・周波数');

    r := ex.Expand('at <TIME> on <DATE>', ctx);
    CheckEq(r.PlainText, 'at 0705Z on 20260828', 'UTC の時刻と日付');

    r := ex.Expand('tag names are case-insensitive: <mycall> <MyCall>', ctx);
    CheckEq(r.PlainText, 'tag names are case-insensitive: JI1UUI JI1UUI',
      'タグ名の大小は区別しない');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestOrderPreserved;
{ 設計の要。文字列と操作が元の順序どおりに並ばないと、
  「送信を始める前の文が送信後に出る」ような壊れ方をする。 }
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 2. 文字列と操作の順序 ---');
  ctx := MakeContext;
  ex := TMacroExpander.Create;
  try
    r := ex.Expand('<TX>CQ de <MYCALL> k<RX>', ctx);
    Check(r.SegmentCount = 3, '断片は 3 個 (操作/文字列/操作)。実際: ' +
      IntToStr(r.SegmentCount));
    Check((r.Segments[0].Kind = mskAction) and
          (r.Segments[0].Action = makTransmit), '1番目は送信開始');
    Check(r.Segments[1].Kind = mskText, '2番目は文字列');
    CheckEq(r.Segments[1].Text, 'CQ de JI1UUI k', '2番目の内容');
    Check((r.Segments[2].Kind = mskAction) and
          (r.Segments[2].Action = makReceive), '3番目は受信復帰');

    { 操作をまたぐ文字列が正しく分割されるか }
    r := ex.Expand('A<TX>B<RX>C', ctx);
    Check(r.SegmentCount = 5, '文字列/操作/文字列/操作/文字列 の 5 個。実際: ' +
      IntToStr(r.SegmentCount));
    CheckEq(r.Segments[0].Text, 'A', '操作の前の文字列が先に来る');
    CheckEq(r.Segments[2].Text, 'B', '操作にはさまれた文字列');
    CheckEq(r.Segments[4].Text, 'C', '最後の文字列');

    { 連続した文字列断片はまとめられる }
    r := ex.Expand('de <MYCALL> es <MYNAME>', ctx);
    Check(r.SegmentCount = 1, '操作が無ければ断片は 1 個にまとまる。実際: ' +
      IntToStr(r.SegmentCount));
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestSerialNumber;
{ コンテストで最も間違えやすいところ。 }
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 3. 送信ナンバーの扱い (コンテスト) ---');
  ctx := MakeContext;
  ex := TMacroExpander.Create;
  try
    ctx.ResetSerial(1);
    r := ex.Expand('<CALL> 599<#>', ctx);
    CheckEq(r.PlainText, 'JA1ZZZ 599001', '3桁ゼロ詰めで払い出す');

    { 展開を繰り返しても番号は進まない }
    r := ex.Expand('<CALL> 599<#>', ctx);
    CheckEq(r.PlainText, 'JA1ZZZ 599001',
      '再送しても番号は進まない (交信不成立で番号を飛ばさない)');

    ctx.CommitSerial;
    r := ex.Expand('<CALL> 599<#>', ctx);
    CheckEq(r.PlainText, 'JA1ZZZ 599002',
      'ログ確定 (CommitSerial) のあとだけ進む');

    ctx.SerialDigits := 4;
    r := ex.Expand('<#>', ctx);
    CheckEq(r.PlainText, '0002', '桁数を変えられる');

    ctx.SerialDigits := 3;
    ctx.ResetSerial(109);
    r := ex.Expand('<#CUT>', ctx);
    CheckEq(r.PlainText, '1TN', 'カットナンバー (0=T, 9=N)');

    r := ex.Expand('<RST><#CUT>', ctx);
    CheckEq(r.PlainText, '5991TN',
      'RST 自体はカットしない (値をそのまま送る)');

    CheckEq(ToCutNumbers('599'), '5NN', 'ToCutNumbers: 599 -> 5NN');
    CheckEq(ToCutNumbers('100'), '1TT', 'ToCutNumbers: 100 -> 1TT');
    CheckEq(ToCutNumbers('ABC'), 'ABC', 'ToCutNumbers: 数字以外はそのまま');

    { <INCR>/<DECR> は操作として返す (勝手に進めない) }
    ctx.ResetSerial(5);
    r := ex.Expand('<INCR>', ctx);
    Check(r.ContainsAction(makIncSerial), '<INCR> は操作として返る');
    Check(ctx.SerialOut = 5, '展開しただけでは番号は変わらない');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestValidation;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 4. 送信前バリデーション ---');
  ctx := MakeContext;
  ex := TMacroExpander.Create;
  try
    { 正常なマクロ }
    r := ex.Prepare('<TX>CQ de <MYCALL> k<RX>', ctx);
    Check(not r.HasErrors, '正しいマクロはエラーにならない');

    { <RX> が無い = 電波を出しっぱなしにする }
    r := ex.Prepare('<TX>CQ de <MYCALL> k', ctx);
    Check(r.HasErrors, '<RX> が無いマクロはエラー');
    Check(Pos('電波を出し続けます', r.IssueText) > 0,
      'エラー内容が「送信したまま」だと分かる');

    { 二度目の <TX> のあとに <RX> が無い場合も捕まえる }
    r := ex.Prepare('<TX>A<RX><TX>B', ctx);
    Check(r.HasErrors, '最後の <TX> に対応する <RX> が無ければエラー');

    { <TX> より前の本文は送信されない }
    r := ex.Prepare('hello<TX>CQ<RX>', ctx);
    Check(r.HasWarnings, '<TX> より前の本文は警告');

    { 相手コールを使っているのに空 }
    ctx.Call := '';
    r := ex.Prepare('<TX><CALL> de <MYCALL> kn<RX>', ctx);
    Check(r.HasErrors, '<CALL> を使っているのに空ならエラー');

    { CQ のように <CALL> を使わないマクロは、相手が空でも正常 }
    r := ex.Prepare('<TX>CQ de <MYCALL> k<RX>', ctx);
    Check(not r.HasErrors,
      '<CALL> を使わないマクロは相手が空でもエラーにしない');

    { 自局コールが空 }
    ctx := MakeContext;
    ctx.MyCall := '';
    r := ex.Prepare('<TX>CQ de <MYCALL> k<RX>', ctx);
    Check(r.HasErrors, '自局コールが空ならエラー');

    { ログするのに内容が埋まっていない }
    ctx := MakeContext;
    ctx.Call := '';
    r := ex.Prepare('<TX>TU<LOG><RX>', ctx);
    Check(r.HasErrors, '相手コールが空のままログしようとするとエラー');

    ctx := MakeContext;
    ctx.RstRcvd := '';
    r := ex.Prepare('<TX>TU<LOG><RX>', ctx);
    Check(r.HasWarnings, '受信 RST が空のままログしようとすると警告');

    { 送信ナンバーが 0 以下 }
    ctx := MakeContext;
    ctx.SerialOut := 0;
    r := ex.Prepare('<TX><#><RX>', ctx);
    Check(r.HasErrors, '送信ナンバーが 0 ならエラー');

    { 未知タグ }
    ctx := MakeContext;
    r := ex.Prepare('<TX><NOSUCHTAG><RX>', ctx);
    Check(r.HasWarnings, '未知タグは既定で警告');
    CheckEq(r.PlainText, '<NOSUCHTAG>',
      '未知タグは消さずそのまま残す (抜けに気づけるように)');

    ex.StrictUnknownTags := True;
    r := ex.Prepare('<TX><NOSUCHTAG><RX>', ctx);
    Check(r.HasErrors, 'StrictUnknownTags=True なら未知タグはエラー');
    ex.StrictUnknownTags := False;
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestActionsWithArgs;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
  i, idx: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 引数つき操作 ---');
  ctx := MakeContext;
  ex := TMacroExpander.Create;
  try
    r := ex.Expand('<MODE:RTTY>', ctx);
    Check(r.ContainsAction(makSetMode), '<MODE:x> はモード変更操作');
    idx := -1;
    for i := 0 to r.SegmentCount - 1 do
      if (r.Segments[i].Kind = mskAction) and
         (r.Segments[i].Action = makSetMode) then idx := i;
    Check(idx >= 0, 'モード変更操作が見つかる');
    if idx >= 0 then
      CheckEq(r.Segments[idx].Arg, 'RTTY', '引数に元の大小が保たれる');

    r := ex.Expand('<MODE>', ctx);
    CheckEq(r.PlainText, 'RTTY', '引数なし <MODE> は現在のモードを差し込む');

    r := ex.Expand('<FREQ:14.0805>', ctx);
    idx := -1;
    for i := 0 to r.SegmentCount - 1 do
      if (r.Segments[i].Kind = mskAction) and
         (r.Segments[i].Action = makSetFreq) then idx := i;
    Check(idx >= 0, '<FREQ:x> は周波数変更操作');
    if idx >= 0 then
      Check(Abs(r.Segments[idx].ArgNum - 14.0805) < 1E-9,
        '周波数の数値が読めている');

    r := ex.Expand('<FREQ:abc>', ctx);
    Check(r.HasErrors, '数値として読めない周波数はエラー');

    r := ex.Expand('<WAIT:2.5>', ctx);
    Check(r.ContainsAction(makWait), '<WAIT:n> は待ち操作');
    r := ex.Expand('<WAIT:9999>', ctx);
    Check(r.HasErrors, '待ち時間が範囲外ならエラー');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

procedure TestNestedMacros;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  ms: TMacroSet;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 6. 入れ子マクロと循環参照 ---');
  ctx := MakeContext;
  ms := TMacroSet.Create;
  ex := TMacroExpander.Create(ms);
  try
    ms.Add('署名', 'de <MYCALL>');
    ms.Add('CQ', '<TX>CQ CQ <MACRO:署名> k<RX>');
    r := ex.ExpandNamed('CQ', ctx);
    CheckEq(r.PlainText, 'CQ CQ de JI1UUI k', '入れ子マクロが展開される');
    Check(not r.HasErrors, '正常な入れ子はエラーにならない');

    { 循環参照 }
    ms.Add('A', 'a<MACRO:B>');
    ms.Add('B', 'b<MACRO:A>');
    r := ex.ExpandNamed('A', ctx);
    Check(r.HasErrors, '循環参照は上限で止めてエラーにする');
    Check(Pos('入れ子が深すぎます', r.IssueText) > 0, 'エラー内容が分かる');

    { 参照先が無い }
    ms.Add('壊れ', '<MACRO:存在しない>');
    r := ex.ExpandNamed('壊れ', ctx);
    Check(r.HasErrors, '参照先が無ければエラー');
  finally
    ex.Free;
    ms.Free;
    ctx.Free;
  end;
end;

procedure TestMacroSetPersistence;
var
  ms, ms2: TMacroSet;
  fn: string;
  d: TMacroDefinition;
begin
  WriteLn;
  WriteLn('--- 7. マクロ集の保存・読み込み ---');
  fn := GetTempDir + 'test_macro_set.json';
  if FileExists(fn) then DeleteFile(fn);
  ms := TMacroSet.Create;
  ms2 := TMacroSet.Create;
  try
    ms.RegisterBuiltins;
    Check(ms.Count > 0, '標準セットが登録される (' + IntToStr(ms.Count) + ' 件)');
    Check(ms.Find('CQ') <> nil, 'CQ マクロがある');
    Check(ms.Find('交換') <> nil, 'コンテストの交換マクロがある');
    Check(ms.Find('cq') <> nil, 'マクロ名の検索は大小を区別しない');

    { 日本語の名前・注記が往復で壊れないこと (9-2 と同じ落とし穴) }
    ms.Add('ラグチュー導入', 'こんにちは <NAME> さん', mcRubberStamp,
      '和文ラグチューのきっかけ');
    ms.SaveToFile(fn);
    ms2.LoadFromFile(fn);
    Check(ms2.Count = ms.Count, '件数が一致する');
    d := ms2.Find('ラグチュー導入');
    Check(d <> nil, '日本語のマクロ名で引ける');
    if d <> nil then
    begin
      CheckEq(d.Text, 'こんにちは <NAME> さん', '日本語の本文が壊れない');
      CheckEq(d.Note, '和文ラグチューのきっかけ', '日本語の注記が壊れない');
      Check(d.Category = mcRubberStamp, '区分が保たれる');
    end;

    { 重複追加 }
    Check(ms.Find('CQ') <> nil, '追加前の確認');
    ms.AddOrReplace('CQ', '差し替え', mcGeneral);
    CheckEq(ms.Find('CQ').Text, '差し替え', 'AddOrReplace は内容を差し替える');

    Check(ms.Remove('CQ'), '削除できる');
    Check(ms.Find('CQ') = nil, '削除後は見つからない');
    Check(not ms.Remove('CQ'), '存在しないものの削除は False');
  finally
    ms.Free;
    ms2.Free;
    if FileExists(fn) then DeleteFile(fn);
  end;
end;

procedure TestBuiltinsAreSafe;
{ 標準セットそのものが送信前バリデーションを通ること。
  雛形が「送信したまま戻らない」形だと、利用者は気づかず事故る。 }
var
  ctx: TMacroContext;
  ms: TMacroSet;
  ex: TMacroExpander;
  r: TMacroExpansion;
  i, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 8. 標準セットが安全な形になっているか ---');
  ctx := MakeContext;
  ctx.ExchangeOut := '10M';
  ctx.ExchangeIn := '13H';
  ctx.SerialIn := '045';
  ms := TMacroSet.Create;
  ex := TMacroExpander.Create(ms);
  try
    ms.RegisterBuiltins;
    bad := 0;
    for i := 0 to ms.Count - 1 do
    begin
      r := ex.Prepare(ms[i].Text, ctx);
      if r.HasErrors then
      begin
        Inc(bad);
        WriteLn('        エラーのある標準マクロ: ', ms[i].Name);
        WriteLn(r.IssueText);
      end;
    end;
    Check(bad = 0, '標準マクロはすべて検査を通る (エラー ' +
      IntToStr(bad) + ' 件)');

    { <TX> と <RX> が対になっているか個別に確認 }
    for i := 0 to ms.Count - 1 do
    begin
      r := ex.Expand(ms[i].Text, ctx);
      if r.ContainsAction(makTransmit) then
        Check(r.ContainsAction(makReceive),
          ms[i].Name + ': <TX> があるなら <RX> もある');
    end;
  finally
    ex.Free;
    ms.Free;
    ctx.Free;
  end;
end;

procedure TestEdgeCases;
var
  ctx: TMacroContext;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 9. 境界と異常系 ---');
  ctx := MakeContext;
  ex := TMacroExpander.Create;
  try
    r := ex.Expand('', ctx);
    CheckEq(r.PlainText, '', '空文字列は空のまま');
    Check(r.SegmentCount = 0, '空文字列では断片が作られない');

    r := ex.Expand('5 < 10 and 10 > 5', ctx);
    CheckEq(r.PlainText, '5 < 10 and 10 > 5',
      '閉じない < は本文としてそのまま残す');

    r := ex.Expand('<>', ctx);
    CheckEq(r.PlainText, '<>', '空のタグはそのまま残す');

    r := ex.Expand('< MYCALL >', ctx);
    CheckEq(r.PlainText, 'JI1UUI', 'タグ内の空白は無視する');

    ctx.MyPowerW := 0;
    r := ex.Expand('pwr <MYPWR>W', ctx);
    CheckEq(r.PlainText, 'pwr W', '出力 0 は数字を出さない');

    CheckEq(FormatSerial(7, 3), '007', 'FormatSerial: 3桁');
    CheckEq(FormatSerial(1234, 3), '1234', 'FormatSerial: 桁を超えたら切らない');
    CheckEq(FormatSerial(7, 1), '7', 'FormatSerial: 1桁');

    { ClearWorkedStation は相手だけ消す }
    ctx := MakeContext;
    ctx.ResetSerial(42);
    ctx.ClearWorkedStation;
    CheckEq(ctx.Call, '', '相手コールが消える');
    CheckEq(ctx.RstRcvd, '', '受信 RST が消える');
    CheckEq(ctx.MyCall, 'JI1UUI', '自局は残る');
    CheckEq(ctx.RstSent, '599', '送信 RST は残る');
    Check(ctx.SerialOut = 42, '送信ナンバーは残る');

    { nil コンテキスト }
    try
      ex.Expand('x', nil);
      Check(False, 'nil コンテキストは例外になる');
    except
      on E: EMacroError do
        Check(True, 'nil コンテキストは EMacroError');
    end;

    { マクロ集なしで <MACRO:> }
    r := ex.Expand('<MACRO:何か>', ctx);
    Check(r.HasErrors, 'マクロ集が無ければ <MACRO:> はエラー');
  finally
    ex.Free;
    ctx.Free;
  end;
end;

type
  { 宿主のテスト実装。実機の代わりに「何がどの順で起きたか」を記録する。

    送信は非同期なので、送信終了の折り返し (NotifyTxFinished) を
    自動で返すか、テストが手で返すかを選べるようにしてある。
    手で返せることが重要 — 「送信中にログが走っていないか」は
    折り返しを保留したまま確かめないと検証にならない。 }
  TRecordingHost = class(TMacroHost)
  private
    FLog: TStringList;
    FLogOk: Boolean;
    FAutoFinishTx: Boolean;
    FAutoFireTimer: Boolean;
    FTxPending: Boolean;
    FTimerPending: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SendText(const AText: string); override;
    procedure StartTransmit; override;
    procedure RequestReceive; override;
    procedure AbortTransmit; override;
    function LogCurrentQso: Boolean; override;
    procedure ClearRxWindow; override;
    procedure ClearTxWindow; override;
    procedure SetMode(const AMode: string); override;
    procedure SetFreqMHz(AFreqMHz: Double); override;
    procedure StartTimer(ASeconds: Double); override;

    { 保留していた送信終了を折り返す (実機で送信が終わった相当)。 }
    procedure FinishTx;
    procedure FireTimer;

    property LogOk: Boolean read FLogOk write FLogOk;
    property AutoFinishTx: Boolean read FAutoFinishTx write FAutoFinishTx;
    property AutoFireTimer: Boolean read FAutoFireTimer write FAutoFireTimer;
    property TxPending: Boolean read FTxPending;
    property Log: TStringList read FLog;
  end;

constructor TRecordingHost.Create;
begin
  inherited Create;
  FLog := TStringList.Create;
  FLogOk := True;
  FAutoFinishTx := True;
  FAutoFireTimer := True;
end;

destructor TRecordingHost.Destroy;
begin
  FLog.Free;
  inherited Destroy;
end;

procedure TRecordingHost.SendText(const AText: string);
begin
  FLog.Add('TEXT:' + AText);
end;

procedure TRecordingHost.StartTransmit;
begin
  FLog.Add('TX');
end;

procedure TRecordingHost.RequestReceive;
begin
  FLog.Add('RX-REQ');
  FTxPending := True;
  if FAutoFinishTx then
    FinishTx;
end;

procedure TRecordingHost.FinishTx;
begin
  if not FTxPending then Exit;
  FTxPending := False;
  FLog.Add('TX-END');
  if Assigned(Runner) then
    Runner.NotifyTxFinished;
end;

procedure TRecordingHost.AbortTransmit;
begin
  FTxPending := False;
  FLog.Add('ABORT');
end;

function TRecordingHost.LogCurrentQso: Boolean;
begin
  Result := FLogOk;
  if Result then
    FLog.Add('LOG-OK')
  else
    FLog.Add('LOG-FAIL');
end;

procedure TRecordingHost.ClearRxWindow;
begin
  FLog.Add('CLRRX');
end;

procedure TRecordingHost.ClearTxWindow;
begin
  FLog.Add('CLRTX');
end;

procedure TRecordingHost.SetMode(const AMode: string);
begin
  FLog.Add('MODE:' + AMode);
end;

procedure TRecordingHost.SetFreqMHz(AFreqMHz: Double);
begin
  FLog.Add('FREQ:' + FormatFloat('0.000', AFreqMHz));
end;

procedure TRecordingHost.StartTimer(ASeconds: Double);
begin
  FLog.Add('TIMER:' + FormatFloat('0.0', ASeconds));
  FTimerPending := True;
  if FAutoFireTimer then
    FireTimer;
end;

procedure TRecordingHost.FireTimer;
begin
  if not FTimerPending then Exit;
  FTimerPending := False;
  if Assigned(Runner) then
    Runner.NotifyTimerElapsed;
end;

{ --------------------------------------------------------------------- }

procedure TestPhaseTracking;
{ 局面は「値を入れる」という自然な操作で自動的に進む必要がある。
  別作業にすると必ず忘れられる (実際、以前の設計では
  ClearWorkedStation を実装しながらどこからも呼んでいなかった)。 }
var
  ctx: TMacroContext;
begin
  WriteLn;
  WriteLn('--- 10. 局面の自動追跡 ---');
  ctx := TMacroContext.Create;
  try
    Check(ctx.Phase = qpIdle, '初期状態は相手なし');
    Check(ctx.Role = qrRun, '既定の立場は CQ を出す側');

    ctx.Call := 'JA1ZZZ';
    Check(ctx.Phase = qpAnswered,
      '相手のコールを入れると「コール取得」へ進む。実際: ' +
      QsoPhaseDescription(ctx.Phase));

    ctx.Phase := qpExchangeSent;
    ctx.RstRcvd := '599';
    Check(ctx.Phase = qpExchangeRcvd,
      '相手のレポートを入れると「受領済み」へ進む');

    { 打ち直しても局面は後戻りしない }
    ctx.Call := 'JA1ZZ';
    Check(ctx.Phase = qpExchangeRcvd,
      'コールを打ち直しても局面は戻らない');

    { 受信ナンバー・交換ナンバーでも進む }
    ctx.ClearWorkedStation;
    Check(ctx.Phase = qpIdle, 'ClearWorkedStation で相手なしへ戻る');
    ctx.SerialIn := '045';
    Check(ctx.Phase = qpExchangeRcvd, '受信ナンバーでも受領済みへ進む');

    ctx.ClearWorkedStation;
    ctx.ExchangeIn := '10M';
    Check(ctx.Phase = qpExchangeRcvd, '交換ナンバーでも受領済みへ進む');

    { 空文字を入れても進まない }
    ctx.ClearWorkedStation;
    ctx.Call := '';
    Check(ctx.Phase = qpIdle, '空文字では局面は進まない');
  finally
    ctx.Free;
  end;
end;

procedure TestSequenceSelection;
{ 立場 × 局面で「次に押すべきマクロ」が一意に決まること (ESM の土台)。 }
var
  ms: TMacroSet;
  d: TMacroDefinition;
begin
  WriteLn;
  WriteLn('--- 11. 局面からマクロを選ぶ (ESM) ---');
  ms := TMacroSet.Create;
  try
    ms.RegisterBuiltins;

    d := ms.FindForSequence(qrRun, qpIdle);
    Check(d <> nil, 'Run/相手なし → マクロが決まる');
    if d <> nil then CheckEq(d.Name, 'CQ', 'Run/相手なし は CQ');

    d := ms.FindForSequence(qrRun, qpAnswered);
    if d <> nil then CheckEq(d.Name, 'レポート', 'Run/コール取得 はレポート');

    d := ms.FindForSequence(qrRun, qpExchangeRcvd);
    if d <> nil then CheckEq(d.Name, '73', 'Run/受領済み は 73 (ログ付き)');

    d := ms.FindForSequence(qrSearchPounce, qpIdle);
    Check(d <> nil, 'S&P/相手なし → マクロが決まる');
    if d <> nil then CheckEq(d.Name, '呼ぶ', 'S&P/相手なし は「呼ぶ」');

    d := ms.FindForSequence(qrSearchPounce, qpAnswered);
    if d <> nil then CheckEq(d.Name, '応答レポート',
      'S&P/コール取得 は応答レポート');

    { 同じ局面でも立場が違えば別のマクロが返る — これが要点 }
    Check(ms.FindForSequence(qrRun, qpIdle) <>
          ms.FindForSequence(qrSearchPounce, qpIdle),
      '同じ局面でも立場が違えば別のマクロになる');

    { 順序を宣言していないマクロは選ばれない }
    d := ms.Find('AGN?');
    Check(d <> nil, '補助マクロは存在する');
    if d <> nil then
      Check(not d.MatchesSequence(qrRun, qpIdle),
        '順序を宣言していないマクロは自動選択の対象外');
  finally
    ms.Free;
  end;
end;

procedure TestAsyncSequence;
{ 設計変更の本丸。<RX> の後ろに置いた <LOG> が、送信を送り切ってから
  実行されること。同期実装では送信をキューに積んだ直後にログしていた。 }
var
  ctx: TMacroContext;
  ms: TMacroSet;
  ex: TMacroExpander;
  host: TRecordingHost;
  runner: TMacroRunner;
  rr: TMacroRunResult;
begin
  WriteLn;
  WriteLn('--- 12. 送信完了を待ってからログすること ---');
  ctx := MakeContext;
  ms := TMacroSet.Create;
  ex := TMacroExpander.Create(ms);
  host := TRecordingHost.Create;
  runner := TMacroRunner.Create(host, ex);
  try
    ms.RegisterBuiltins;
    host.AutoFinishTx := False;   { 送信終了を手で返す }

    ctx.Role := qrRun;
    ctx.Phase := qpExchangeRcvd;
    rr := runner.ExecuteNamed('TU', ctx);
    Check(rr.Started, 'マクロが起動する');
    Check(not rr.Completed, '送信終了待ちで止まっている');
    Check(runner.State = mrsWaitingTxEnd, '状態は送信終了待ち');
    Check(runner.Busy, '実行中と判定される');
    Check(host.Log.IndexOf('LOG-OK') < 0,
      '送信が終わるまでログは実行されない (ここが同期実装との違い)');

    { 実行中に別のマクロを起動できないこと }
    rr := runner.ExecuteNamed('CQコンテスト', ctx);
    Check(not rr.Started, '実行中は別のマクロを受け付けない');
    Check(Pos('実行中', rr.RefusalReason) > 0, '拒否理由が分かる');

    { 送信完了を折り返す }
    host.FinishTx;
    Check(runner.State = mrsDone, '折り返しで最後まで進む');
    Check(host.Log.IndexOf('LOG-OK') >= 0, '送信完了後にログが実行される');
    Check(host.Log.IndexOf('TX-END') < host.Log.IndexOf('LOG-OK'),
      'ログは必ず送信完了より後');
    Check(not runner.Busy, '完了後は実行中ではない');
  finally
    runner.Free;
    host.Free;
    ex.Free;
    ms.Free;
    ctx.Free;
  end;
end;

procedure TestPostLogTransition;
{ ログに成功したら、相手局情報を消して局面を戻すところまでが 1 つの操作。
  以前はここが抜けており、次の交信で前の局のコールを送っていた。 }
var
  ctx: TMacroContext;
  ms: TMacroSet;
  ex: TMacroExpander;
  host: TRecordingHost;
  runner: TMacroRunner;
  rr: TMacroRunResult;
begin
  WriteLn;
  WriteLn('--- 13. ログ後の遷移 ---');
  ctx := MakeContext;
  ms := TMacroSet.Create;
  ex := TMacroExpander.Create(ms);
  host := TRecordingHost.Create;
  runner := TMacroRunner.Create(host, ex);
  try
    ms.RegisterBuiltins;
    ctx.Role := qrRun;
    ctx.ResetSerial(7);
    ctx.Call := 'JA1ZZZ';
    ctx.RstRcvd := '599';     { → qpExchangeRcvd }

    rr := runner.ExecuteNamed('TU', ctx);
    Check(rr.Completed, 'TU が最後まで走る');
    Check(runner.Logged, 'ログに記録された');
    Check(ctx.SerialOut = 8, '送信ナンバーが進む。実際: ' +
      IntToStr(ctx.SerialOut));
    CheckEq(ctx.Call, '', 'ログ後に相手のコールが消える');
    CheckEq(ctx.RstRcvd, '', 'ログ後に受信 RST が消える');
    Check(ctx.Phase = qpIdle,
      'ログ後は「相手なし」へ戻る (次の CQ が正しい局面から始まる)。実際: ' +
      QsoPhaseDescription(ctx.Phase));
    CheckEq(ctx.MyCall, 'JI1UUI', '自局は残る');

    { ログに失敗したら何も進めない }
    ctx.ResetSerial(7);
    ctx.Call := 'JA1YYY';
    ctx.RstRcvd := '579';
    host.LogOk := False;
    rr := runner.ExecuteNamed('TU', ctx);
    Check(not runner.Logged, 'ログに失敗した');
    Check(ctx.SerialOut = 7, 'ログ失敗なら送信ナンバーは進まない');
    CheckEq(ctx.Call, 'JA1YYY', 'ログ失敗なら相手局情報も消さない');
    host.LogOk := True;
  finally
    runner.Free;
    host.Free;
    ex.Free;
    ms.Free;
    ctx.Free;
  end;
end;

procedure TestFullQsoSequence;
{ Run 側の 1 交信を頭から通す。ESM (局面から自動選択) だけで
  最後まで進めることを確かめる。 }
var
  ctx: TMacroContext;
  ms: TMacroSet;
  ex: TMacroExpander;
  host: TRecordingHost;
  runner: TMacroRunner;
  rr: TMacroRunResult;
begin
  WriteLn;
  WriteLn('--- 14. コンテスト 1 交信を局面駆動で通す ---');
  ctx := MakeContext;
  ctx.Call := '';
  ctx.RstRcvd := '';
  ctx.Phase := qpIdle;
  ms := TMacroSet.Create;
  ex := TMacroExpander.Create(ms);
  host := TRecordingHost.Create;
  runner := TMacroRunner.Create(host, ex);
  try
    { コンテスト用だけを登録する (ラバースタンプと競合させない) }
    ms.AddOrReplace('CQ TEST', '<TX>CQ TEST de <MYCALL> TEST<RX>', mcContest)
      .DeclareSequence(mrfRun, [qpIdle], qpCalling);
    ms.AddOrReplace('EXCH', '<TX><CALL> <RST><#><RX>', mcContest)
      .DeclareSequence(mrfRun, [qpAnswered], qpExchangeSent);
    ms.AddOrReplace('TU!', '<TX>TU <MYCALL> TEST<RX><LOG>', mcContest)
      .DeclareSequence(mrfRun, [qpExchangeRcvd, qpConfirmed], qpConfirmed);

    ctx.Role := qrRun;
    ctx.ResetSerial(1);

    { (1) CQ }
    rr := runner.ExecuteForSequence(ctx);
    Check(rr.Started, '(1) 局面から CQ が選ばれて実行される');
    Check(ctx.Phase = qpCalling, '(1) 局面が「呼びかけ中」へ');

    { (2) 相手のコールを取得 (オペレータが打ち込む相当) }
    ctx.Call := 'JA1ZZZ';
    Check(ctx.Phase = qpAnswered, '(2) 局面が「コール取得」へ自動で進む');

    { (3) 交換を送る }
    host.Log.Clear;
    rr := runner.ExecuteForSequence(ctx);
    Check(rr.Started, '(3) 局面から交換マクロが選ばれる');
    CheckEq(host.Log[1], 'TEXT:JA1ZZZ 599001',
      '(3) 相手のコールと送信ナンバーが乗る');
    Check(ctx.Phase = qpExchangeSent, '(3) 局面が「送出済み」へ');

    { (4) 相手の交換を受領 }
    ctx.SerialIn := '032';
    Check(ctx.Phase = qpExchangeRcvd, '(4) 局面が「受領済み」へ自動で進む');

    { (5) TU + ログ }
    host.Log.Clear;
    rr := runner.ExecuteForSequence(ctx);
    Check(rr.Started, '(5) 局面から TU が選ばれる');
    Check(runner.Logged, '(5) ログに記録された');
    Check(ctx.SerialOut = 2, '(5) 送信ナンバーが 2 へ。実際: ' +
      IntToStr(ctx.SerialOut));
    Check(ctx.Phase = qpIdle, '(5) 局面が「相手なし」へ戻る');
    CheckEq(ctx.Call, '', '(5) 相手のコールが消えている');

    { (6) 次の CQ が、前の局のコールを含まないこと }
    host.Log.Clear;
    rr := runner.ExecuteForSequence(ctx);
    Check(rr.Started, '(6) 次の CQ が選ばれる');
    Check(Pos('JA1ZZZ', host.Log.Text) = 0,
      '(6) 次の CQ に前の局のコールが混ざらない');
  finally
    runner.Free;
    host.Free;
    ex.Free;
    ms.Free;
    ctx.Free;
  end;
end;

procedure TestRunnerGuards;
var
  ctx: TMacroContext;
  ms: TMacroSet;
  ex: TMacroExpander;
  host: TRecordingHost;
  runner: TMacroRunner;
  rr: TMacroRunResult;
begin
  WriteLn;
  WriteLn('--- 15. 実行時の防御 ---');
  ctx := MakeContext;
  ms := TMacroSet.Create;
  ex := TMacroExpander.Create(ms);
  host := TRecordingHost.Create;
  runner := TMacroRunner.Create(host, ex);
  try
    ms.RegisterBuiltins;

    { エラーのあるマクロは実行しない }
    host.Log.Clear;
    rr := runner.Execute('<TX>CQ de <MYCALL> k', ctx);   { <RX> が無い }
    Check(not rr.Started, 'エラーのあるマクロは実行されない');
    Check(host.Log.Count = 0, '拒否時は宿主が一切呼ばれない');
    Check(Pos('電波を出し続けます', rr.RefusalReason) > 0, '拒否理由が分かる');

    { 交換を受け取る前のログはエラー }
    ctx.ClearWorkedStation;
    ctx.Call := 'JA1ZZZ';      { qpAnswered まで }
    rr := runner.Execute('<TX>TU<RX><LOG>', ctx);
    Check(not rr.Started, '交換を受け取る前のログは実行されない');
    Check(Pos('交換を受け取る前', rr.RefusalReason) > 0,
      '局面に基づく拒否理由が出る');

    { 局面が合わないマクロは警告どまり (押した本人の判断を尊重) }
    ctx.ClearWorkedStation;
    rr := runner.ExecuteNamed('73', ctx);   { qpIdle なのに 73 }
    Check(not rr.Started,
      '相手不在で 73 は実行されない (ログ内容が空のため)');

    { デュープは止めない }
    ctx.ClearWorkedStation;
    ctx.Call := 'JA1ZZZ';
    ctx.RstRcvd := '599';
    ctx.IsDuplicate := True;
    rr := runner.ExecuteNamed('TU', ctx);
    Check(rr.Started, 'デュープでも実行は止めない (得点0で記録する運用がある)');

    { 中断 }
    host.AutoFinishTx := False;
    ctx.ClearWorkedStation;
    rr := runner.Execute('<TX>CQ de <MYCALL> k<RX>', ctx);
    Check(runner.Busy, '送信終了待ちで実行中');
    runner.Abort;
    Check(runner.State = mrsAborted, '中断できる');
    Check(not runner.Busy, '中断後は実行中でない');
    host.AutoFinishTx := True;

    { 差し替え方針 }
    host.AutoFinishTx := False;
    rr := runner.Execute('<TX>A<RX>', ctx);
    Check(runner.Busy, '前提: 実行中');
    runner.BusyPolicy := mbpReplace;
    rr := runner.Execute('<TX>B<RX>', ctx);
    Check(rr.Started, 'mbpReplace なら実行中でも差し替えられる');
    runner.BusyPolicy := mbpReject;
    host.AutoFinishTx := True;
    runner.Abort;

    { 想定外の折り返しは無視する }
    runner.NotifyTxFinished;
    Check(True, '実行していないときの折り返しは無視される');

    { 展開器が無い }
    runner.Expander := nil;
    try
      runner.Execute('x', ctx);
      Check(False, '展開器が無ければ例外');
    except
      on E: EMacroError do Check(True, '展開器が無ければ EMacroError');
    end;
    runner.Expander := ex;
  finally
    runner.Free;
    host.Free;
    ex.Free;
    ms.Free;
    ctx.Free;
  end;
end;

procedure TestStationInfoBridge;
{ 運用プロファイルの実効値がマクロまで届くこと。
  ここが切れていると、移動運用でコールが /1 になってもマクロは
  古いコールを送り続ける。 }
var
  ctx: TMacroContext;
  info: TStationInfo;
  ex: TMacroExpander;
  r: TMacroExpansion;
begin
  WriteLn;
  WriteLn('--- 16. 局情報からコンテキストへの流し込み ---');
  ctx := TMacroContext.Create;
  info := TStationInfo.Create;
  ex := TMacroExpander.Create;
  try
    info.MyCall := 'JI1UUI/1';
    info.MyName := 'Noma';
    info.MyQth := 'Chichibu';
    info.MyLocator := 'PM95';
    info.MyAntenna := 'Whip';
    info.MyRig := 'IC-705';
    info.MyPowerW := 5;

    ctx.LoadFromStationInfo(info);
    r := ex.Expand('<MYCALL> <MYRIG> <MYPWR>W <MYANT> <MYQTH>', ctx);
    CheckEq(r.PlainText, 'JI1UUI/1 IC-705 5W Whip Chichibu',
      '局情報の全項目がマクロへ届く');
  finally
    ex.Free;
    info.Free;
    ctx.Free;
  end;
end;

begin
  WriteLn('=== マクロ展開エンジン (ラバースタンプ/コンテスト) テスト ===');

  TestBasicSubstitution;
  TestOrderPreserved;
  TestSerialNumber;
  TestValidation;
  TestActionsWithArgs;
  TestNestedMacros;
  TestMacroSetPersistence;
  TestBuiltinsAreSafe;
  TestEdgeCases;
  TestPhaseTracking;
  TestSequenceSelection;
  TestAsyncSequence;
  TestPostLogTransition;
  TestFullQsoSequence;
  TestRunnerGuards;
  TestStationInfoBridge;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
