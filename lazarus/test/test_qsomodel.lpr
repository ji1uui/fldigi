{ ============================================================================
  test_qsomodel.lpr

  §13 内部交信データモデル (QsoModel.pas) と ADIF アダプタ
  (QsoAdifAdapter.pas) の検証。

  「新しい型を作った」ことではなく、**旧 TQsoRecord では成立しない性質**が
  実際に成立することを確かめる。確かめる性質は次の 5 つ。

    1. §13.4 未知の ADIF 項目が往復して失われないこと
       旧 TQsoRecord (12 項目) も TAdifRecord (61 項目) も、知らないタグを
       黙って捨てる。他ソフトの ADIF を読んで書き戻すと項目が減るという、
       気づけない壊れ方をする。ここが本モデルの存在理由である。

    2. §13.1 値の出所と確定段階が保たれること
       抽出した候補が運用者の確定値を上書きしないこと、保存して読み直しても
       その区別が消えないこと。

    3. §13.2 1 交信に複数の確認経路を独立に持てること
       QSL_RCVD 1 列では表せない状態 (LoTW 済 / 紙は未) を表せること。

    4. §13.3 改訂番号で「送った後に変わったか」を判定できること

    5. Z-05 同じ内容なら同じバイト列が出ること

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_qsomodel;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils,
  QsoModel, QsoAdifAdapter, AdifFile;

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

function TempName(const ASuffix: string): string;
begin
  Result := GetTempDir(False) + 'test_qsomodel_' +
    IntToStr(GetProcessID) + ASuffix;
end;

{ --------------------------------------------------------------------------
  1. 項目集合の基本と、候補が確定値を壊さないこと (§13.1)
  -------------------------------------------------------------------------- }
procedure TestFieldSetOriginAndState;
var
  e: TQsoEntry;
  ok: Boolean;
  f: TQsoField;
begin
  WriteLn;
  WriteLn('--- 1. 値の出所と確定段階 (§13.1) ---');
  e := TQsoEntry.Create;
  try
    e.Fields.SetValue(QSO_CALL, 'JA1ABC', foOperator);
    CheckEq(e.Fields.Get(QSO_CALL), 'JA1ABC', '確定値が入る');
    Check(e.Fields.GetField(QSO_CALL).State = fsConfirmed,
      '運用者が入れた値は確定段階');

    { 抽出結果が運用者の入力を上書きしないこと。ここが崩れると、
      受信中に打ち間違いのようなコールが勝手に入る。 }
    ok := e.Fields.SetCandidate(QSO_CALL, 'JA1XYZ', foExtracted, 0.9);
    Check(not ok, '確定済みの項目は候補で上書きされない');
    CheckEq(e.Fields.Get(QSO_CALL), 'JA1ABC', '値は運用者の入力のまま');

    ok := e.Fields.SetCandidate(QSO_NAME, 'TARO', foExtracted, 0.72);
    Check(ok, '空の項目には候補が入る');
    f := e.Fields.GetField(QSO_NAME);
    Check(f.State = fsCandidate, '候補は候補段階のまま');
    Check(f.Origin = foExtracted, '出所は抽出');
    Check(f.HasEvidence and (Abs(f.Evidence - 0.72) < 1E-9),
      'Evidence が保たれる');
    CheckEqI(e.Fields.CandidateCount, 1, '未確定は 1 件');

    { Commit = §13.1 の Operator Confirmation。 }
    CheckEqI(e.Commit, 1, 'Commit が候補を 1 件昇格させた');
    CheckEqI(e.Fields.CandidateCount, 0, '未確定が残らない');
    Check(e.State = qeCommitted, '交信が確定した');
    Check(e.Fields.GetField(QSO_NAME).Origin = foExtracted,
      '昇格しても「どこから来たか」は消えない');
  finally
    e.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. Plugin / コンテストの項目 (§11 / CNT-010)
  -------------------------------------------------------------------------- }
procedure TestPluginFields;
var
  e: TQsoEntry;
begin
  WriteLn;
  WriteLn('--- 2. Core を触らずに項目を足せること (§11 / CNT-010) ---');
  e := TQsoEntry.Create;
  try
    e.Fields.SetValue(QSO_PLUGIN_PREFIX + 'JARL.CITYCODE', '10001', foPlugin);
    e.Fields.SetValue('SIG_INFO', 'JA-0012', foPlugin);
    CheckEq(e.Fields.Get('app.jarl.citycode'), '10001',
      'Plugin 項目は大小を無視して引ける');
    CheckEq(e.Fields.Get('SIG_INFO'), 'JA-0012',
      'モデルが知らない標準項目も置ける');
    CheckEq(ModelKeyToAdifTag(QSO_PLUGIN_PREFIX + 'JARL.CITYCODE'),
      'APP_JARL_CITYCODE', 'Plugin 項目名が ADIF 形に写る');
    CheckEq(AdifTagToModelKey('APP_JARL_CITYCODE'),
      'APP.JARL.CITYCODE', 'ADIF 形から戻る');
  finally
    e.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. QSL の複数確認経路 (§13.2)
  -------------------------------------------------------------------------- }
procedure TestMultipleQslRoutes;
var
  e: TQsoEntry;
  q: TQslConfirmation;
begin
  WriteLn;
  WriteLn('--- 3. 1 交信に複数の確認経路 (§13.2) ---');
  e := TQsoEntry.Create;
  try
    Check(not e.IsConfirmed, '最初はどの経路でも未確認');

    q := e.AddQsl(qmPaper, qdSent);
    q.Status := qsSent;
    Check(not e.IsConfirmed, '送っただけでは確認済みにならない');

    q := e.AddQsl(qmLotw, qdReceived);
    q.Status := qsVerified;
    Check(e.IsConfirmed, 'LoTW で受領すれば確認済み');

    q := e.AddQsl(qmPaper, qdReceived);
    q.Status := qsRequested;
    CheckEqI(e.QslCount, 3, '3 本の経路が独立に並ぶ');
    { 旧モデルの QSL_RCVD 1 列ではこの状態を表せない。 }
    Check(e.FindQsl(qmLotw, qdReceived).Status = qsVerified,
      'LoTW は照合済のまま');
    Check(e.FindQsl(qmPaper, qdReceived).Status = qsRequested,
      '紙は要求中のまま (LoTW に引きずられない)');

    Check(e.AddQsl(qmLotw, qdReceived) = e.FindQsl(qmLotw, qdReceived),
      '同じ経路を二重に作らない');
    CheckEqI(e.QslCount, 3, '件数は増えない');
  finally
    e.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 改訂番号と同期判定 (§13.3)
  -------------------------------------------------------------------------- }
procedure TestRevisionAndSync;
var
  st: TQsoStore;
  e: TQsoEntry;
  s: TQsoSync;
  pending: TFPList;
  r0: Int64;
begin
  WriteLn;
  WriteLn('--- 4. Offline-first の同期判定 (§13.3) ---');
  st := TQsoStore.Create;
  try
    e := st.Add;
    e.Fields.SetValue(QSO_CALL, 'JA1ABC');
    e.Commit;
    r0 := e.Revision;
    Check(e.NeedsSync('LoTW'), '一度も送っていなければ送るべき');

    s := e.Sync('LoTW');
    s.State := sySynced;
    s.SyncedRevision := e.Revision;
    Check(not e.NeedsSync('LoTW'), '送った直後は送る必要がない');
    Check(e.NeedsSync('eQSL'), 'provider ごとに独立している');

    { 手元を直したら、また送るべきになる。回線が無い間に直しても
      あとで追いつけるのがこの設計の目的である。 }
    e.Fields.SetValue(QSO_NAME, 'TARO');
    e.Touch;
    Check(e.Revision > r0, '変更で改訂番号が上がる');
    Check(e.NeedsSync('LoTW'), '送った後に変えたら再送が要る');

    pending := st.CollectNeedingSync('LoTW');
    try
      CheckEqI(pending.Count, 1, '同期キューに 1 件');
    finally
      pending.Free;
    end;

    { 下書きは送らない。 }
    e := st.Add;
    e.Fields.SetValue(QSO_CALL, 'JA9ZZZ');
    pending := st.CollectNeedingSync('LoTW');
    try
      CheckEqI(pending.Count, 1, '下書きは同期キューに入らない');
    finally
      pending.Free;
    end;
  finally
    st.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. Store の索引 / 重複 ID
  -------------------------------------------------------------------------- }
procedure TestStoreIndex;
var
  st: TQsoStore;
  e: TQsoEntry;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 5. 交信の集合 ---');
  st := TQsoStore.Create;
  try
    st.Add('A-1').Fields.SetValue(QSO_CALL, 'JA1AAA');
    st.Add('A-2').Fields.SetValue(QSO_CALL, 'JA1BBB');
    st.Add('A-3').Fields.SetValue(QSO_CALL, 'JA1CCC');
    CheckEqI(st.Count, 3, '3 件');
    CheckEq(st.EntryAt(1).Fields.Get(QSO_CALL), 'JA1BBB', '挿入順が保たれる');

    e := st.FindById('A-2');
    Check((e <> nil) and (e.Fields.Get(QSO_CALL) = 'JA1BBB'), 'ID で引ける');
    Check(st.FindById('NOPE') = nil, '無い ID は nil');

    raised := False;
    try
      st.Add('A-2');
    except
      on EQsoModelError do raised := True;
    end;
    Check(raised, '重複 ID は拒否される');
    CheckEqI(st.Count, 3, '拒否しても件数は変わらない');

    Check(st.Remove('A-2'), '削除できる');
    CheckEqI(st.Count, 2, '件数が減る');
    Check(st.FindById('A-2') = nil, '索引からも消える');
    CheckEq(st.EntryAt(1).Fields.Get(QSO_CALL), 'JA1CCC',
      '削除後も残りの順序が崩れない');
    Check(not st.Remove('A-2'), '二度目の削除は False');

    { 削除した ID を再利用できること (索引に残骸が無い証拠)。 }
    st.Add('A-2');
    CheckEqI(st.Count, 3, '同じ ID を作り直せる');
  finally
    st.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. JSON 往復 (§13.3 の保存先)
  -------------------------------------------------------------------------- }
procedure TestJsonRoundTrip;
var
  a, b: TQsoStore;
  e: TQsoEntry;
  f: TQsoField;
  js1, js2: string;
  fn: string;
begin
  WriteLn;
  WriteLn('--- 6. JSON 往復 ---');
  a := TQsoStore.Create;
  b := TQsoStore.Create;
  try
    e := a.Add('X-1');
    e.Fields.SetValue(QSO_CALL, 'JA1ABC', foOperator);
    e.Fields.SetValue(QSO_QTH, '東京都八王子市', foOperator);
    e.Fields.SetCandidate(QSO_NAME, 'TARO', foExtracted, 0.61);
    e.Fields.SetValue(QSO_PLUGIN_PREFIX + 'JARL.CITYCODE', '10001', foPlugin);
    e.State := qeCommitted;
    e.AddQsl(qmLotw, qdReceived).Status := qsVerified;
    { 実際の改訂番号を送った、という状態にする。ここを実値より大きい
      定数にすると NeedsSync が常に False になり、下の判定が効かない。 }
    e.Sync('LoTW').SyncedRevision := e.Revision;
    e.Sync('LoTW').State := sySynced;

    js1 := a.ToJsonString;
    b.FromJsonString(js1);

    CheckEqI(b.Count, 1, '1 件読めた');
    e := b.FindById('X-1');
    Check(e <> nil, 'ID が保たれる');
    CheckEq(e.Fields.Get(QSO_CALL), 'JA1ABC', '値が保たれる');
    CheckEq(e.Fields.Get(QSO_QTH), '東京都八王子市',
      '日本語が壊れない (UTF-8 の往復)');
    CheckEq(e.Fields.Get(QSO_PLUGIN_PREFIX + 'JARL.CITYCODE'), '10001',
      'Plugin 項目が保たれる');

    { 読み直したときに「候補」が「確定」に化けないこと。
      化けると、未確認の抽出値が確定値として表示される。 }
    f := e.Fields.GetField(QSO_NAME);
    Check(f.State = fsCandidate, '候補は候補のまま読める');
    Check(f.Origin = foExtracted, '出所が保たれる');
    Check(f.HasEvidence and (Abs(f.Evidence - 0.61) < 1E-9),
      'Evidence が保たれる');
    Check(not e.Fields.GetField(QSO_CALL).HasEvidence,
      'Evidence を持たない項目は持たないまま');

    Check(e.FindQsl(qmLotw, qdReceived) <> nil, 'QSL 経路が保たれる');
    Check(e.Sync('LoTW').State = sySynced, '同期状態が保たれる');
    CheckEqI(e.Sync('LoTW').SyncedRevision,
      a.FindById('X-1').Sync('LoTW').SyncedRevision, '送った版が保たれる');

    { 読み込みで Revision がずれないこと。ずれると NeedsSync が
      毎回「変わった」と言い、同期が止まらなくなる。 }
    CheckEqI(e.Revision, a.FindById('X-1').Revision,
      '改訂番号が読み込みで動かない');
    Check(not e.NeedsSync('LoTW'), '読み直した直後に再送が要求されない');

    { Z-05: 同じ内容なら同じバイト列。 }
    js2 := b.ToJsonString;
    Check(js1 = js2, '同じ内容なら同じ JSON が出る (Z-05)');

    fn := TempName('.json');
    Check(a.SaveToFile(fn), 'ファイルに保存できる');
    b.Clear;
    b.LoadFromFile(fn);
    CheckEqI(b.Count, 1, 'ファイルから読める');
    DeleteFile(fn);

    b.Clear;
    b.LoadFromFile(TempName('.missing'));
    CheckEqI(b.Count, 0, '無いファイルは空として扱う (初回起動)');
  finally
    a.Free;
    b.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. §13.4 の核心: 知らない ADIF 項目を落とさないこと
  -------------------------------------------------------------------------- }
const
  { 他ソフトが書き出した ADIF のつもり。SIG / SIG_INFO / MY_SOTA_REF /
    APP_N1MM_POINTS は AdifFile.TAdifFieldId (61 項目) に無い。 }
  FOREIGN_ADIF =
    '<ADIF_VER:5>3.1.4<PROGRAMID:9>OtherLog<EOH>' + #10 +
    '<CALL:6>DL1XYZ<QSO_DATE:8>20260214<TIME_ON:4>1234' +
    '<MODE:4>RTTY<BAND:3>20m<RST_SENT:3>599<RST_RCVD:3>599' +
    '<SIG:4>POTA<SIG_INFO:7>JA-0012<MY_SOTA_REF:9>JA/TK-001' +
    '<APP_N1MM_POINTS:1>3' +
    '<EOR>' + #10;

procedure TestUnknownAdifFieldsSurvive;
var
  st: TQsoStore;
  db: TAdifDatabase;
  e: TQsoEntry;
  n: Integer;
  outText, fn: string;
begin
  WriteLn;
  WriteLn('--- 7. 知らない ADIF 項目が往復すること (§13.4) ---');

  { まず、既存の TAdifRecord 経路では実際に落ちることを示す。
    落ちないなら本モデルは要らない。 }
  fn := TempName('_foreign.adi');
  with TStringList.Create do
  try
    Text := FOREIGN_ADIF;
    SaveToFile(fn);
  finally
    Free;
  end;
  db := TAdifDatabase.Create;
  try
    db.LoadFromFile(fn);
    CheckEqI(db.Count, 1, '既存経路でも 1 件は読める');
    { TAdifFieldId に SIG_INFO は無い。あることを示す手段が無い
      = 落ちている、ということをここで固定しておく。 }
    Check(FieldIdFromTag('SIG_INFO') < 0,
      '前提: SIG_INFO は TAdifRecord の 61 項目に無い');
    Check(FieldIdFromTag('APP_N1MM_POINTS') < 0,
      '前提: APP_ 項目は TAdifRecord に無い');
  finally
    db.Free;
  end;

  st := TQsoStore.Create;
  try
    n := AdifTextToStore(FOREIGN_ADIF, st);
    CheckEqI(n, 1, '1 件取り込んだ');
    CheckEqI(st.Count, 1, 'Store に 1 件');
    e := st.EntryAt(0);

    CheckEq(e.Fields.Get(QSO_CALL), 'DL1XYZ', '既知の項目が入る');
    CheckEq(e.Fields.Get('SIG'), 'POTA', '知らない項目 SIG が残る');
    CheckEq(e.Fields.Get('SIG_INFO'), 'JA-0012',
      '知らない項目 SIG_INFO が残る');
    CheckEq(e.Fields.Get('MY_SOTA_REF'), 'JA/TK-001',
      '知らない項目 MY_SOTA_REF が残る');
    CheckEq(e.Fields.Get(QSO_PLUGIN_PREFIX + 'N1MM.POINTS'), '3',
      '他ソフトの APP_ 項目が残る');
    Check(e.Fields.GetField('SIG_INFO').Origin = foImported,
      '取り込んだ値は出所が imported');
    Check(e.State = qeCommitted, '取り込んだ交信は確定扱い');

    { 落ちる件数を呼び出し側が知れること。 }
    Check(AdifRecordDropCount(e) >= 4,
      'TAdifRecord へ写すと 4 項目以上落ちると分かる');

    { 書き戻して、もう一度読んでも減らないこと。これが「気づけない
      壊れ方」を防いでいる証拠になる。 }
    outText := StoreToAdifText(st);
    Check(Pos('<SIG_INFO:7>JA-0012', outText) > 0,
      '書き戻しに SIG_INFO が出る');
    Check(Pos('<APP_N1MM_POINTS:1>3', outText) > 0,
      '書き戻しに APP_N1MM_POINTS が出る');
    Check(Pos('<MY_SOTA_REF:9>JA/TK-001', outText) > 0,
      '書き戻しに MY_SOTA_REF が出る');

    st.Clear;
    CheckEqI(AdifTextToStore(outText, st), 1, '書き戻しを読み直せる');
    e := st.EntryAt(0);
    CheckEq(e.Fields.Get('SIG_INFO'), 'JA-0012', '二度目も残っている');
    CheckEq(e.Fields.Get(QSO_PLUGIN_PREFIX + 'N1MM.POINTS'), '3',
      'APP_ 項目も二度目まで残る');
  finally
    st.Free;
  end;
  DeleteFile(fn);
end;

{ --------------------------------------------------------------------------
  8. ADIF の細かい所 (ヘッダ省略 / 値の中の '<' / 改行を含む値)
  -------------------------------------------------------------------------- }
procedure TestAdifEdgeCases;
var
  st: TQsoStore;
  e: TQsoEntry;
  txt: string;
begin
  WriteLn;
  WriteLn('--- 8. ADIF の境界的な入力 ---');

  { <EOH> が無いもの。ADIF 仕様上ヘッダは省略でき、交換用に本体だけを
    渡してくる実装がある。既存の TAdifDatabase.LoadFromFile はこれを
    例外にしてしまう。 }
  st := TQsoStore.Create;
  try
    CheckEqI(AdifTextToStore('<CALL:6>JA1ABC<MODE:2>CW<EOR>' + #10, st), 1,
      'ヘッダが無くても読める');
    CheckEq(st.EntryAt(0).Fields.Get(QSO_CALL), 'JA1ABC', '値が取れる');
  finally
    st.Free;
  end;

  { 値の中に '<' がある場合。長さ分だけ読み飛ばさないと、中身をタグと
    誤認して以降が全部ずれる。 }
  st := TQsoStore.Create;
  try
    AdifTextToStore('<CALL:6>JA1ABC<COMMENT:9>a<b:1>c d<MODE:4>RTTY<EOR>', st);
    e := st.EntryAt(0);
    CheckEq(e.Fields.Get(QSO_COMMENT), 'a<b:1>c d',
      '値の中の < をタグと誤認しない');
    CheckEq(e.Fields.Get(QSO_MODE), 'RTTY', '後続の項目もずれない');
    { 値そのものは長さで切り出すので常に正しく取れる。壊れ方が出るのは
      「次にどこから読み直すか」で、値の中を走査してしまうと存在しない
      項目 B が生える。件数まで見ないとこの壊れ方は捕まえられない。 }
    Check(not e.Fields.Has('B'),
      '値の中のタグらしき文字列から項目を作らない');
    CheckEqI(e.Fields.Count, 3, '項目は CALL/COMMENT/MODE の 3 つだけ');
  finally
    st.Free;
  end;

  { 値に改行を含む場合。 }
  st := TQsoStore.Create;
  try
    AdifTextToStore('<CALL:6>JA1ABC<NOTES:6>ab' + #10 + 'cde<MODE:2>CW<EOR>', st);
    e := st.EntryAt(0);
    CheckEq(e.Fields.Get(QSO_NOTES), 'ab' + #10 + 'cde', '改行を含む値が読める');
    CheckEq(e.Fields.Get(QSO_MODE), 'CW', '後続の項目もずれない');

    txt := StoreToAdifText(st);
    st.Clear;
    AdifTextToStore(txt, st);
    CheckEq(st.EntryAt(0).Fields.Get(QSO_NOTES), 'ab' + #10 + 'cde',
      '改行を含む値が往復する');
  finally
    st.Free;
  end;

  { <EOR> で終わっていないもの。 }
  st := TQsoStore.Create;
  try
    CheckEqI(AdifTextToStore('<CALL:6>JA1ABC<MODE:2>CW', st), 1,
      '<EOR> が無くても最後のレコードを失わない');
  finally
    st.Free;
  end;

  { 複数レコード。 }
  st := TQsoStore.Create;
  try
    CheckEqI(AdifTextToStore(
      '<CALL:6>JA1AAA<EOR><CALL:6>JA1BBB<EOR><CALL:6>JA1CCC<EOR>', st), 3,
      '3 レコード読める');
    CheckEq(st.EntryAt(2).Fields.Get(QSO_CALL), 'JA1CCC', '順序が保たれる');
  finally
    st.Free;
  end;

  { 空入力。 }
  st := TQsoStore.Create;
  try
    CheckEqI(AdifTextToStore('', st), 0, '空入力は 0 件 (例外にしない)');
    CheckEqI(AdifTextToStore('<ADIF_VER:5>3.1.4<EOH>' + #10, st), 0,
      'ヘッダだけなら 0 件');
  finally
    st.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. QSL <-> ADIF の双方向 (§13.2)
  -------------------------------------------------------------------------- }
procedure TestQslAdifMapping;
var
  st: TQsoStore;
  e: TQsoEntry;
  txt: string;
begin
  WriteLn;
  WriteLn('--- 9. QSL 経路と ADIF の対応 (§13.2) ---');
  st := TQsoStore.Create;
  try
    e := st.Add;
    e.Fields.SetValue(QSO_CALL, 'W1AW');
    e.AddQsl(qmLotw, qdReceived).Status := qsVerified;
    e.AddQsl(qmBureau, qdSent).Status := qsSent;
    e.FindQsl(qmBureau, qdSent).DateUtc := EncodeDate(2026, 2, 14);
    e.State := qeCommitted;

    txt := StoreToAdifText(st);
    Check(Pos('<LOTW_QSL_RCVD:1>V', txt) > 0, 'LoTW 受領が V で出る');
    Check(Pos('<QSL_SENT:1>Y', txt) > 0, '紙系の送信が Y で出る');
    Check(Pos('<QSLSDATE:8>20260214', txt) > 0, '送信日が出る');
    Check(Pos('<QSL_SENT_VIA:1>B', txt) > 0, 'ビューロー経由が出る');
    { 未設定の経路は書かない。 }
    Check(Pos('<QSL_RCVD:', txt) = 0, '設定していない QSL_RCVD は出さない');

    st.Clear;
    AdifTextToStore(txt, st);
    e := st.EntryAt(0);
    Check(e.FindQsl(qmLotw, qdReceived) <> nil, 'LoTW 受領が戻る');
    Check(e.FindQsl(qmLotw, qdReceived).Status = qsVerified,
      'LoTW の照合済が戻る');
    Check(e.FindQsl(qmBureau, qdSent) <> nil, 'ビューロー送信が戻る');
    Check(e.FindQsl(qmBureau, qdSent).Status = qsSent, '送信済が戻る');
    Check(Abs(e.FindQsl(qmBureau, qdSent).DateUtc -
      EncodeDate(2026, 2, 14)) < 1E-6, '送信日が戻る');
    Check(e.IsConfirmed, '受領があるので確認済み');

    { QSL タグが項目集合に二重に入っていないこと。入っていると
      書き戻しで 2 回出て、他ソフトが読んだときに壊れる。 }
    Check(not e.Fields.Has('LOTW_QSL_RCVD'),
      'QSL タグは項目集合に入らない (二重に持たない)');
    Check(not e.Fields.Has('QSL_SENT'),
      'QSL_SENT も項目集合に入らない');
  finally
    st.Free;
  end;
end;

{ --------------------------------------------------------------------------
  10. 既存 TAdifRecord との橋渡し
  -------------------------------------------------------------------------- }
procedure TestAdifRecordBridge;
var
  st: TQsoStore;
  e: TQsoEntry;
  rec: TAdifRecord;
begin
  WriteLn;
  WriteLn('--- 10. 既存 TAdifRecord との橋渡し ---');
  st := TQsoStore.Create;
  rec := TAdifRecord.Create;
  try
    e := st.Add;
    e.Fields.SetValue(QSO_CALL, 'JA1ABC');
    e.Fields.SetValue(QSO_MODE, 'RTTY');
    e.Fields.SetValue('SIG_INFO', 'JA-0012');

    EntryToAdifRecord(e, rec);
    CheckEq(rec.Call, 'JA1ABC', '既知の項目は写る');
    CheckEq(rec.Mode, 'RTTY', 'MODE も写る');
    CheckEqI(AdifRecordDropCount(e), 1, '写せない項目が 1 件と分かる');

    st.Clear;
    e := st.Add;
    AdifRecordToEntry(rec, e);
    CheckEq(e.Fields.Get(QSO_CALL), 'JA1ABC', '逆向きにも写る');
    Check(e.Fields.GetField(QSO_CALL).Origin = foImported,
      '取り込みとして出所が付く');
  finally
    rec.Free;
    st.Free;
  end;
end;

{ --------------------------------------------------------------------------
  11. Z-05 書き出しの再現性
  -------------------------------------------------------------------------- }
procedure TestDeterministicOutput;
var
  a, b: TQsoStore;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 11. 書き出しの再現性 (Z-05) ---');
  a := TQsoStore.Create;
  b := TQsoStore.Create;
  try
    for i := 1 to 5 do
    begin
      { 両方に同じ内容を、同じ順で入れる。 }
      a.Add('R-' + IntToStr(i)).Fields.SetValue(QSO_CALL, 'JA1A' + IntToStr(i));
      b.Add('R-' + IntToStr(i)).Fields.SetValue(QSO_CALL, 'JA1A' + IntToStr(i));
      a.EntryAt(i - 1).State := qeCommitted;
      b.EntryAt(i - 1).State := qeCommitted;
    end;
    CheckEq(StoreToAdifText(a), StoreToAdifText(b),
      '同じ内容なら同じ ADIF が出る');
    CheckEq(StoreToAdifText(a), StoreToAdifText(a),
      '同じ Store を二度書いても同じ');

    { 下書きは書き出さない。 }
    a.Add('R-9').Fields.SetValue(QSO_CALL, 'JA9ZZZ');
    Check(Pos('JA9ZZZ', StoreToAdifText(a)) = 0,
      '下書きは既定で書き出さない');
    Check(Pos('JA9ZZZ', StoreToAdifText(a, False)) > 0,
      '明示すれば下書きも書き出せる');
  finally
    a.Free;
    b.Free;
  end;
end;

{ --------------------------------------------------------------------------
  12. 壊れた入力で落ちないこと
  -------------------------------------------------------------------------- }
procedure TestBadInput;
var
  st: TQsoStore;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 12. 壊れた入力 ---');
  st := TQsoStore.Create;
  try
    raised := False;
    try
      st.FromJsonString('{ this is not json');
    except
      on EQsoModelError do raised := True;
    end;
    Check(raised, '壊れた JSON は EQsoModelError になる');

    raised := False;
    try
      st.FromJsonString('{"version":99,"qsos":[]}');
    except
      on EQsoModelError do raised := True;
    end;
    Check(raised, '新しすぎる形式は読まずに拒否する (項目を失わないため)');

    st.FromJsonString('');
    CheckEqI(st.Count, 0, '空文字は 0 件');

    st.FromJsonString('{"version":1}');
    CheckEqI(st.Count, 0, 'qsos が無くても落ちない');

    { 長さが壊れているタグ。 }
    st.Clear;
    AdifTextToStore('<CALL:xx>JA1ABC<MODE:2>CW<EOR>', st);
    Check(st.Count <= 1, '長さが壊れたタグでも落ちない');

    { 途中で切れたタグ。 }
    st.Clear;
    AdifTextToStore('<CALL:6>JA1ABC<MODE', st);
    Check(True, '閉じていないタグでも落ちない');
  finally
    st.Free;
  end;
end;

begin
  WriteLn('=== §13 交信データモデル / ADIF アダプタ テスト ===');

  TestFieldSetOriginAndState;
  TestPluginFields;
  TestMultipleQslRoutes;
  TestRevisionAndSync;
  TestStoreIndex;
  TestJsonRoundTrip;
  TestUnknownAdifFieldsSurvive;
  TestAdifEdgeCases;
  TestQslAdifMapping;
  TestAdifRecordBridge;
  TestDeterministicOutput;
  TestBadInput;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
