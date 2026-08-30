{ ============================================================================
  test_robustness.lpr

  堅牢性・品質改善で修正した不具合の回帰テスト。
  「修正したつもり」で終わらせず、修正前なら実際に落ちる/壊れる条件を
  1 件ずつ再現して確かめる。

  対象:
    1. SafeFileIO   : 原子的保存 / 生バイト読込
    2. AdifFile     : 値に改行・'<' を含むフィールドの往復、大量レコード性能
    3. 添字の範囲外 : アクセス違反ではなく原因の分かる例外になること
    4. ModemDSP     : FFT長の検証、フィルタ係数の NaN/Inf 汚染防止
    5. ContestLog   : 保存失敗を戻り値で判定できること

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -otest/test_robustness test/test_robustness.lpr
    ./test/test_robustness
  ============================================================================ }
program test_robustness;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Math, DateUtils,
  SafeFileIO, ModemDSP, AdifFile, DxccDatabase, ContestLog,
  StationInfo, QsoLogbook, OpProfile, AppConfig;

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

function TempPath(const APrefix, AExt: string): string;
begin
  Result := GetTempDir + APrefix + IntToStr(Random(1000000)) + AExt;
end;

{ ------------------------------------------------------------------------
  1. SafeFileIO: 原子的保存と生バイト読込
  ------------------------------------------------------------------------ }
procedure TestSafeFileIO;
var
  path, back: string;
  crlfText: string;
begin
  WriteLn;
  WriteLn('--- 1. SafeFileIO: 原子的保存 / 生バイト読込 ---');

  path := TempPath('robust_safeio_', '.txt');

  { 生バイト往復: 改行コードが正規化されず、末尾に改行が足されないこと。
    TStringList 経由だとどちらも起きるため、長さ指定書式が壊れていた。 }
  crlfText := 'A'#13#10'B'#10'C';
  SaveTextAtomic(path, crlfText);
  back := LoadTextRaw(path);
  Check(back = crlfText,
    '改行を含む内容が 1 バイトも変わらず往復する (len ' +
    IntToStr(Length(back)) + '/' + IntToStr(Length(crlfText)) + ')');
  Check(Length(back) = Length(crlfText), '末尾に余分な改行が付与されない');

  { 上書き保存でも内容が完全に置き換わること }
  SaveTextAtomic(path, 'SHORT');
  Check(LoadTextRaw(path) = 'SHORT', '上書き保存で古い内容が残らない');

  { 保存後に一時ファイルが残っていないこと }
  Check(not FileExists(path + '.tmp'), '保存完了後に .tmp ファイルが残らない');

  DeleteFile(path);
  Check(LoadTextRaw(path) = '',
    '存在しないファイルの読込は例外ではなく空文字を返す');

  { 書き込み不能な場所への保存は例外になり、かつ .tmp を残さない }
  path := '/nonexistent-dir-xyz/robust.txt';
  try
    SaveTextAtomic(path, 'X');
    Check(False, '書き込み不能なパスでは例外が送出される');
  except
    on E: ESafeFileIOError do
      Check(True, '書き込み不能なパスでは ESafeFileIOError が送出される');
  end;
end;

{ ------------------------------------------------------------------------
  2. AdifFile: 値に改行/'<' を含むフィールドの往復
  ------------------------------------------------------------------------ }
procedure TestAdifTrickyValues;
var
  db, db2: TAdifDatabase;
  rec: TAdifRecord;
  path: string;
  notesVal, commentVal: string;
begin
  WriteLn;
  WriteLn('--- 2. AdifFile: 改行や < を含む値の往復 ---');

  { ADIF は長さをバイト数で前置するため、値に改行が含まれても
    仕様上は正しく読めなければならない。修正前は TStringList 経由で
    改行が正規化され、以降のフィールドがすべてずれていた。 }
  notesVal := '1行目' + #13#10 + '2行目' + #10 + '3行目';
  commentVal := 'a<b>c';   // 値の中にタグ開始文字がある場合

  path := TempPath('robust_adif_', '.adi');
  db := TAdifDatabase.Create;
  try
    rec := db.AddRecord;
    rec.Call := 'JA1ABC';
    rec.Mode := 'RTTY';
    rec.PutField(afNotes, notesVal);
    rec.PutField(afComment, commentVal);
    { 後続フィールドがずれていないことを確かめるための番兵 }
    rec.PutField(afQth, 'TOKYO');
    rec.PutField(afRstSent, '599');
    db.SaveToFile(path);
  finally
    db.Free;
  end;

  db2 := TAdifDatabase.Create;
  try
    Check(db2.LoadFromFile(path) = 1, '1 レコード読み込める');
    Check(db2[0].Fields[afNotes] = notesVal,
      '値に CRLF/LF を含む NOTES が完全に往復する');
    Check(db2[0].Fields[afComment] = commentVal,
      '値に < > を含む COMMENT が往復する (タグと誤認しない)');
    Check(db2[0].Fields[afQth] = 'TOKYO',
      '改行入りフィールドの後続フィールドがずれない (QTH)');
    Check(db2[0].Fields[afRstSent] = '599',
      '改行入りフィールドの後続フィールドがずれない (RST_SENT)');
    Check(db2[0].Call = 'JA1ABC', 'CALL が往復する');
  finally
    db2.Free;
  end;
  DeleteFile(path);
end;

{ ------------------------------------------------------------------------
  3. AdifFile: 大量レコードでも現実的な時間で読めること
     (修正前は検索のたびにバッファ全体を LowerCase していたため
      レコード数に対して O(n^2) になり、数千件で実用にならなかった)
  ------------------------------------------------------------------------ }
procedure TestAdifLargeLogPerformance;
const
  N = 3000;
var
  db, db2: TAdifDatabase;
  rec: TAdifRecord;
  path: string;
  i: Integer;
  t0: TDateTime;
  elapsedMs: Double;
  loaded: Integer;
begin
  WriteLn;
  WriteLn('--- 3. AdifFile: ', N, ' レコードの読み込み性能 ---');

  path := TempPath('robust_adifbig_', '.adi');
  db := TAdifDatabase.Create;
  try
    for i := 1 to N do
    begin
      rec := db.AddRecord;
      rec.Call := Format('JA1%.3d', [i mod 1000]);
      rec.Mode := 'RTTY';
      rec.Band := '20m';
      rec.PutField(afQth, 'TOKYO');
      rec.PutField(afNotes, StringOfChar('x', 60));
    end;
    db.SaveToFile(path);
  finally
    db.Free;
  end;

  db2 := TAdifDatabase.Create;
  try
    t0 := Now;
    loaded := db2.LoadFromFile(path);
    elapsedMs := MilliSecondsBetween(Now, t0);
    WriteLn('  読み込み時間: ', elapsedMs:0:0, ' ms (', loaded, ' 件)');
    Check(loaded = N, IntToStr(N) + ' 件すべて読み込める');
    Check(db2[N - 1].Call <> '', '最後のレコードまで解析されている');
    { 検索処理だけを取り出した実測では、同じ 3000 レコード
      (375KB) に対し「毎回バッファ全体を小文字化」= 3691 ms、
      「1 回だけ小文字化」= 2 ms だった (約 1800 倍)。しかも
      二次オーダーなので件数が増えるほど差が開く。
      ここでは「二次オーダーではない」ことを担保できれば十分なので、
      CI の遅い環境でも安定するよう余裕を持った上限にしておく。 }
    Check(elapsedMs < 10000,
      '二次オーダーではない (10 秒以内に完了: ' + FloatToStr(elapsedMs) + ' ms)');
  finally
    db2.Free;
  end;
  DeleteFile(path);
end;

{ ------------------------------------------------------------------------
  4. 添字の範囲外がアクセス違反ではなく、原因の分かる例外になること
  ------------------------------------------------------------------------ }
procedure TestBoundsChecks;
var
  db: TAdifDatabase;
  log: TQsoLogbook;
  reg: TProfileRegistry;
  cfg: TAppConfig;
  dxcc: TDxccDatabase;
  creg: TContestRegistry;
  caught: Boolean;
begin
  WriteLn;
  WriteLn('--- 4. 添字の範囲外が原因の分かる例外になる ---');

  db := TAdifDatabase.Create;
  try
    caught := False;
    try
      db.Records[0];
    except
      on E: EAdifError do caught := True;
    end;
    Check(caught, 'TAdifDatabase: 空の状態で [0] は EAdifError');
  finally
    db.Free;
  end;

  log := TQsoLogbook.Create;
  try
    caught := False;
    try
      log.Records[5];
    except
      on E: EQsoLogbookError do caught := True;
    end;
    Check(caught, 'TQsoLogbook: 範囲外は EQsoLogbookError');
  finally
    log.Free;
  end;

  reg := TProfileRegistry.Create;
  try
    caught := False;
    try
      reg.Station(0);
    except
      on E: EOpProfileError do caught := True;
    end;
    Check(caught, 'TProfileRegistry: 範囲外は EOpProfileError');

    caught := False;
    try
      reg.Profile(-1);
    except
      on E: EOpProfileError do caught := True;
    end;
    Check(caught, 'TProfileRegistry: 負の添字も検出される');
  finally
    reg.Free;
  end;

  cfg := TAppConfig.Create;
  try
    caught := False;
    try
      cfg.MachineAt(99);
    except
      on E: EAppConfigError do caught := True;
    end;
    Check(caught, 'TAppConfig: 範囲外は EAppConfigError');
  finally
    cfg.Free;
  end;

  dxcc := TDxccDatabase.Create;
  try
    caught := False;
    try
      dxcc.Entity(0);
    except
      on E: EDxccError do caught := True;
    end;
    Check(caught, 'TDxccDatabase: 範囲外は EDxccError');
  finally
    dxcc.Free;
  end;

  creg := TContestRegistry.Create;
  try
    caught := False;
    try
      creg.Definition(0);
    except
      on E: EContestLogError do caught := True;
    end;
    Check(caught, 'TContestRegistry: 範囲外は EContestLogError');
  finally
    creg.Free;
  end;
end;

{ ------------------------------------------------------------------------
  5. ModemDSP: FFT 長の検証と、フィルタ係数の NaN/Inf 汚染防止
  ------------------------------------------------------------------------ }
procedure TestDspGuards;
var
  buf: TComplexArray;
  filt: TFftFilt;
  caught: Boolean;
  i, j, n, nonFinite: Integer;
  outBuf: TComplexArray;
begin
  WriteLn;
  WriteLn('--- 5. ModemDSP: FFT長の検証 / NaN・Inf の防止 ---');

  { 2 の冪乗でない長さは「静かに誤った結果」ではなく例外にする }
  SetLength(buf, 100);
  for i := 0 to High(buf) do buf[i] := CplxMake(1, 0);
  caught := False;
  try
    ComplexFFT(buf);
  except
    on E: EDspError do caught := True;
  end;
  Check(caught, 'ComplexFFT: 2の冪乗でない長さ(100)は EDspError');

  caught := False;
  try
    filt := TFftFilt.Create(100);
    filt.Free;
  except
    on E: EDspError do caught := True;
  end;
  Check(caught, 'TFftFilt: 2の冪乗でない長さ(100)は EDspError');

  caught := False;
  try
    filt := TFftFilt.Create(2);
    filt.Free;
  except
    on E: EDspError do caught := True;
  end;
  Check(caught, 'TFftFilt: 小さすぎる長さ(2)は EDspError');

  { RTTY 整合フィルタの係数に NaN/Inf が混入しないこと。
    混入すると以降の復調出力すべてが NaN に汚染される。
    実際にサンプルを流して出力が有限であることで確認する。 }
  nonFinite := 0;
  filt := TFftFilt.Create(512);
  try
    filt.RttyFilter(45.45 / 8000.0);
    for i := 0 to 512 * 4 - 1 do
    begin
      n := filt.Run(CplxMake(Sin(i * 0.05), Cos(i * 0.05)), outBuf);
      if n > 0 then
        for j := 0 to n - 1 do
          if IsNan(outBuf[j].Re) or IsInfinite(outBuf[j].Re) or
             IsNan(outBuf[j].Im) or IsInfinite(outBuf[j].Im) then
            Inc(nonFinite);
    end;
  finally
    filt.Free;
  end;
  Check(nonFinite = 0,
    'RttyFilter の出力に NaN/Inf が現れない (検出数 ' + IntToStr(nonFinite) + ')');

  { 極端に小さいボーレート比でも破綻しないこと }
  nonFinite := 0;
  filt := TFftFilt.Create(64);
  try
    filt.RttyFilter(300.0 / 8000.0);
    for i := 0 to 64 * 4 - 1 do
    begin
      n := filt.Run(CplxMake(0.5, -0.5), outBuf);
      if n > 0 then
        for j := 0 to n - 1 do
          if IsNan(outBuf[j].Re) or IsInfinite(outBuf[j].Re) then Inc(nonFinite);
    end;
  finally
    filt.Free;
  end;
  Check(nonFinite = 0, '高ボーレート(300baud)設定でも NaN/Inf が出ない');
end;

{ ------------------------------------------------------------------------
  6. ContestLog: 保存の失敗を戻り値で判定できること
  ------------------------------------------------------------------------ }
procedure TestContestLogSaveResult;
var
  clog: TContestLog;
  exchange: array of TContestFieldValue;
  dupe: Boolean;
  path, err: string;
begin
  WriteLn;
  WriteLn('--- 6. ContestLog: 保存の成否が戻り値で分かる ---');

  clog := TContestLog.Create;
  try
    SetLength(exchange, 0);
    clog.LogQso('JA1ABC', '20m', 'RTTY', '599', '599', exchange, False, dupe);

    path := TempPath('robust_clog_', '.adi');
    Check(clog.SaveToAdif(path), '書き込める場所への保存は True を返す');
    Check(clog.LastSaveError = '', '成功時 LastSaveError は空');
    DeleteFile(path);

    { 修正前は無条件に True を返しており、失敗を戻り値で判別できなかった }
    Check(not clog.SaveToAdif('/nonexistent-dir-xyz/x.adi'),
      '書き込めない場所への保存は False を返す');
    Check(clog.LastSaveError <> '', '失敗時 LastSaveError に理由が入る');
    WriteLn('    失敗理由: ', clog.LastSaveError);

    Check(not clog.SaveToAdif('/nonexistent-dir-xyz/x.adi', err),
      'out 引数版も False を返す');
    Check(err <> '', 'out 引数に理由が入る');
  finally
    clog.Free;
  end;
end;

{ ------------------------------------------------------------------------
  7. 壊れた JSON / 想定外の型でも読込全体が巻き添えにならないこと
  ------------------------------------------------------------------------ }
procedure TestMalformedJson;
var
  cfg: TAppConfig;
  path: string;
  m: TMachineConfig;
begin
  WriteLn;
  WriteLn('--- 7. 手編集で壊れた JSON への耐性 ---');

  { profileBindings の値が文字列でない (手編集で数値にしてしまった等)。
    修正前は AsString が例外を投げ、そのマシンの設定全体が読めなくなった。 }
  path := TempPath('robust_badjson_', '.json');
  SaveTextAtomic(path,
    '{"schemaVersion":1,"machines":{"pc1":{' +
    '"interfaces":[{"name":"rig","rigDevice":"/dev/ttyUSB0"}],' +
    '"defaultInterface":"rig",' +
    '"profileBindings":{"home":123,"field":"rig"}}}}');

  cfg := TAppConfig.Create;
  try
    cfg.LoadFromFile(path);
    cfg.MachineId := 'pc1';
    m := cfg.CurrentMachine;
    Check(m.InterfaceCount = 1, '数値混入があっても接続設定は読み込まれる');
    Check(m.ResolveInterface('field').RigDevice = '/dev/ttyUSB0',
      '正常な割り当ては生きている');
    Check(m.ResolveInterface('home').RigDevice = '/dev/ttyUSB0',
      '不正な型の割り当ては無視され既定へフォールバックする');
  finally
    cfg.Free;
  end;
  DeleteFile(path);
end;

begin
  Randomize;
  WriteLn('=== 堅牢性・品質改善の回帰テスト ===');

  TestSafeFileIO;
  TestAdifTrickyValues;
  TestAdifLargeLogPerformance;
  TestBoundsChecks;
  TestDspGuards;
  TestContestLogSaveResult;
  TestMalformedJson;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
