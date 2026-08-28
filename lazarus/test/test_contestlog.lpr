{ ============================================================================
  test_contestlog.lpr

  ContestLog (交換ナンバー検証・シリアルナンバー発行・重複チェック・
  AdifFile連携ロギング) / DxccDatabase (cty.dat 解析・DXCC/ゾーン判定) の
  結合テスト。

  実際の cty.dat ファイルや郡(County)CSVファイルは使わず、fldigi の
  cty-dat.cxx (内蔵フォールバックデータ) と counties.cxx (CSVフォーマット)
  を参考にした小規模なサンプルデータを本ファイル内に直接埋め込み、
  実データとして解析・検索させることで検証する
  (test_station_adif.lpr の「自己完結型で実データを検証する」アプローチ
  を踏襲)。

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_contestlog test/test_contestlog.lpr
    ./test/test_contestlog
  ============================================================================ }
program test_contestlog;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, DateUtils, AdifFile, DxccDatabase, ContestLog;

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

const
  SAMPLE_CTY_DAT =
    'Japan:                    45:  45:  AS:   35.67:  -139.65:    -9.0:  JA:'#10 +
    '    JA,JE,JF,JG,JH,JI,JJ,JK,JL,JM,JN,JO,JP,JQ,JR,JS,7J,7K,7L,7M,7N,8J,8K,8L,8M,8N;'#10 +
    'United States:            05:  08:  NA:   37.53:    91.67:     5.0:  K:'#10 +
    '    AA,AB,AC,AD,AE,AF,AG,AI,AJ,AK,K,N,W,=W1AW(5)[8];'#10 +
    'England:                  14:  27:  EU:   51.50:     0.00:     0.0:  G:'#10 +
    '    G,M,2E;'#10;

{ ------------------------------------------------------------------------
  1. 単体フィールド検証関数 (contest.cxx 由来のロジック) の確認
  ------------------------------------------------------------------------ }
procedure TestFieldValidators;
begin
  WriteLn;
  WriteLn('--- 1. 単体フィールド検証関数の確認 ---');

  Check(ContestStateTest('CA'), 'ContestStateTest(CA) = True');
  Check(ContestStateTest('DX'), 'ContestStateTest(DX) = True (DXも有効な州コード)');
  Check(not ContestStateTest('ZZ'), 'ContestStateTest(ZZ) = False (存在しない州)');

  Check(ContestProvinceTest('ON'), 'ContestProvinceTest(ON) = True');
  Check(not ContestProvinceTest('CA'), 'ContestProvinceTest(CA) = False (CAはVE州ではない)');

  Check(ContestSectionTest('WMA'), 'ContestSectionTest(WMA) = True');
  Check(not ContestSectionTest('XXX'), 'ContestSectionTest(XXX) = False');

  Check(ContestClassTest('2A'), 'ContestClassTest(2A) = True (Field Dayクラス)');
  Check(ContestClassTest('14D'), 'ContestClassTest(14D) = True');
  Check(not ContestClassTest('2G'), 'ContestClassTest(2G) = False (Gは無効クラス)');

  Check(ContestWfdClassTest('1I'), 'ContestWfdClassTest(1I) = True (Winter FD)');
  Check(not ContestWfdClassTest('1A'), 'ContestWfdClassTest(1A) = False');

  Check(ContestAscrClassTest('I'), 'ContestAscrClassTest(I) = True');
  Check(not ContestAscrClassTest('X'), 'ContestAscrClassTest(X) = False');

  Check(ContestNumericTest('12345'), 'ContestNumericTest(12345) = True');
  Check(not ContestNumericTest('12A45'), 'ContestNumericTest(12A45) = False');

  Check(ContestCutNumericTest('5N9'), 'ContestCutNumericTest(5N9) = True (N/Tのカットナンバー許容)');
  Check(ContestCutToNumeric('5N9T') = '5990', 'ContestCutToNumeric(5N9T) = 5990 (N->9, T->0)');

  Check(ContestC1010Test('12345'), 'ContestC1010Test(12345) = True');
  Check(not ContestC1010Test('12A45'), 'ContestC1010Test(12A45) = False');

  Check(ContestRstTest('599', True), 'ContestRstTest(599, CW/デジタル) = True');
  Check(not ContestRstTest('59', True), 'ContestRstTest(59, CW/デジタル) = False (3桁必須)');
  Check(ContestRstTest('59', False), 'ContestRstTest(59, フォーン) = True (2桁も可)');
  Check(ContestRstTest('599', False), 'ContestRstTest(599, フォーン) = True (3桁報告も許容)');
  Check(not ContestRstTest('099', True), 'ContestRstTest(099) = False (先頭0は無効)');

  Check(ContestItalianProvinceTest('MI'), 'ContestItalianProvinceTest(MI) = True (ミラノ県)');
  Check(not ContestItalianProvinceTest('ZZ'), 'ContestItalianProvinceTest(ZZ) = False');

  Check(ContestSsPrecTest('A'), 'ContestSsPrecTest(A) = True');
  Check(not ContestSsPrecTest('Z'), 'ContestSsPrecTest(Z) = False');

  Check(ContestRookieTest('2024', EncodeDate(2026, 1, 1)),
    'ContestRookieTest(2024年免許, 2026年時点) = True (3年未満)');
  Check(not ContestRookieTest('2018', EncodeDate(2026, 1, 1)),
    'ContestRookieTest(2018年免許, 2026年時点) = False (3年以上経過)');
end;

{ ------------------------------------------------------------------------
  2. DxccDatabase を用いた ContestCountryTest の確認
  ------------------------------------------------------------------------ }
procedure TestCountryTestWithDxcc;
var
  dxcc: TDxccDatabase;
  matched: string;
begin
  WriteLn;
  WriteLn('--- 2. ContestCountryTest (DxccDatabase連携) の確認 ---');

  Check(ContestCountryTest(nil, 'ANYTHING', matched),
    'DxccDatabase未指定(nil)なら常にTrue (fldigiのフォールバック挙動)');

  dxcc := TDxccDatabase.Create;
  try
    dxcc.LoadFromString(SAMPLE_CTY_DAT);
    Check(ContestCountryTest(dxcc, 'JAPAN', matched) and (matched = 'Japan'),
      'ContestCountryTest(JAPAN) = True, matched=Japan');
    Check(not ContestCountryTest(dxcc, 'ATLANTIS', matched),
      'ContestCountryTest(存在しない国名) = False');
  finally
    dxcc.Free;
  end;
end;

{ ------------------------------------------------------------------------
  3. TCountyDatabase (郡データCSV読込) の確認
  ------------------------------------------------------------------------ }
procedure TestCountyDatabase;
var
  counties: TCountyDatabase;
  path: string;
begin
  WriteLn;
  WriteLn('--- 3. TCountyDatabase (郡データCSV読込) の確認 ---');

  path := GetTempDir + 'test_counties_' + IntToStr(Random(100000)) + '.csv';
  with TStringList.Create do
  try
    Add('State/Province, ST/PR, County/City/District, CCD');
    Add('Alabama,AL,Autauga,AUT');
    Add('Alabama,AL,Baldwin,BLD');
    Add('Alaska,AK,Anchorage,ANC');
    SaveToFile(path);
  finally
    Free;
  end;

  counties := TCountyDatabase.Create;
  try
    Check(counties.LoadFromFile(path) = 3, 'LoadFromFile が3件読み込む');
    Check(counties.ValidCounty('AL', 'AUT'), 'ValidCounty(AL, AUT) = True (略号一致)');
    Check(counties.ValidCounty('AL', 'Baldwin'), 'ValidCounty(AL, Baldwin) = True (正式名一致)');
    Check(not counties.ValidCounty('AL', 'Anchorage'), 'ValidCounty(AL, Anchorage) = False (州違い)');
    Check(counties.CountyLongName('al', 'aut') = 'Autauga',
      'CountyLongName は大文字小文字を無視して正式名を返す');
    Check(counties.CountyShortName('AL', 'Baldwin') = 'BLD',
      'CountyShortName(AL, Baldwin) = BLD');
    Check(ContestCountyTest(counties, 'AL', 'AUT'), 'ContestCountyTest(AL,AUT) 経由でも True');
    Check(not ContestCountyTest(counties, 'ZZ', 'AUT'), 'ContestCountyTest(存在しない州) = False');
    Check(ContestCountyTest(nil, 'AL', 'NOSUCH'), 'CountyDatabase未指定(nil)なら常にTrue');
  finally
    counties.Free;
  end;

  DeleteFile(path);
end;

{ ------------------------------------------------------------------------
  4. TContestRegistry.RegisterBuiltins の確認
  ------------------------------------------------------------------------ }
procedure TestContestRegistry;
var
  registry: TContestRegistry;
  def: TContestDefinition;
begin
  WriteLn;
  WriteLn('--- 4. TContestRegistry (組み込みコンテスト定義) の確認 ---');

  registry := TContestRegistry.Create;
  try
    registry.RegisterBuiltins;
    Check(registry.Count >= 14, 'RegisterBuiltins で14件以上登録される (実際: ' +
      IntToStr(registry.Count) + '件)');

    def := registry.FindByName('CQ WW DX');
    Check(Assigned(def), 'FindByName(CQ WW DX) が見つかる');
    if Assigned(def) then
    begin
      Check(def.FieldCount = 2, 'CQ WW DX の交換フィールド数は2 (COUNTRY, ZONE)');
      Check(def[0].Kind = cfCountry, 'CQ WW DX の1番目はCOUNTRY');
      Check(def[1].Kind = cfCqZone, 'CQ WW DX の2番目はZONE');
    end;

    def := registry.FindByName('ARRL November Sweepstakes');
    Check(Assigned(def) and (def.FieldCount = 4),
      'ARRL November Sweepstakes の交換フィールド数は4 (SERNO/PREC/CHECK/SECTION)');

    Check(not Assigned(registry.FindByName('Nonexistent Contest')),
      'FindByName(存在しないコンテスト) = nil');
  finally
    registry.Free;
  end;
end;

{ ------------------------------------------------------------------------
  5. TContestLog: 検証・シリアルナンバー発行・重複チェック・
     DxccDatabase連携による自動補完・ADIF永続化の確認
  ------------------------------------------------------------------------ }
procedure TestContestLogFull;
var
  clog: TContestLog;
  dxcc: TDxccDatabase;
  registry: TContestRegistry;
  exchange: array of TContestFieldValue;
  failures: specialize TArray<string>;
  rec: TAdifRecord;
  dupe: Boolean;
  path: string;
  clog2: TContestLog;
begin
  WriteLn;
  WriteLn('--- 5. TContestLog (検証+シリアル発行+重複チェック+ADIF連携) の確認 ---');

  dxcc := TDxccDatabase.Create;
  dxcc.LoadFromString(SAMPLE_CTY_DAT);

  registry := TContestRegistry.Create;
  registry.RegisterBuiltins;

  clog := TContestLog.Create;
  try
    clog.Dxcc := dxcc;
    clog.Definition := registry.FindByName('CQ WW DX');
    Check(Assigned(clog.Definition), 'Definition に CQ WW DX を設定できる');

    { --- 正しい交換ナンバー --- }
    SetLength(exchange, 2);
    exchange[0].FieldId := afCountry; exchange[0].Value := 'JAPAN';
    exchange[1].FieldId := afCqz;     exchange[1].Value := '25';
    failures := clog.ValidateExchange(exchange);
    Check(Length(failures) = 0, '正しい交換ナンバー(JAPAN, Zone 25)は全項目が有効');

    { --- 不正な交換ナンバー (存在しない国名 + 範囲外ゾーン) --- }
    exchange[0].Value := 'ATLANTIS';
    exchange[1].Value := '99';
    failures := clog.ValidateExchange(exchange);
    Check(Length(failures) = 2, '不正な交換ナンバーは2項目とも失敗として検出される (実際: ' +
      IntToStr(Length(failures)) + '件)');

    { --- 実際のロギング: W1AW (cty.dat上でCQ=5/ITU=8に例外上書き) --- }
    exchange[0].Value := 'United States';
    exchange[1].Value := '5';
    clog.ResetSerial(1);
    rec := clog.LogQso('W1AW', '20m', 'RTTY', '599', '579', exchange, True, dupe);
    Check(Assigned(rec), 'LogQso がレコードを返す');
    Check(not dupe, '1件目は重複ではない');
    Check(rec.Call = 'W1AW', 'Call が W1AW として記録される');
    Check(rec.Fields[afCountry] = 'United States',
      'Dxcc自動補完で COUNTRY=United States が設定される (実際: ' + rec.Fields[afCountry] + ')');
    Check(rec.Fields[afCqz] = '5', 'Dxcc自動補完で CQZ=5 (W1AWの例外上書き) が設定される (実際: ' +
      rec.Fields[afCqz] + ')');
    Check(rec.Fields[afItuz] = '8', 'Dxcc自動補完で ITUZ=8 が設定される');
    Check(rec.Fields[afCont] = 'NA', 'Dxcc自動補完で CONT=NA が設定される');
    Check(rec.Fields[afStx] = '1', '自動採番されたSTX(送信シリアル)は1');
    Check(clog.NextSerial = 2, 'NextSerial が2にインクリメントされる');

    { --- 2件目 (別コールサイン) --- }
    rec := clog.LogQso('JA1TEST', '20m', 'RTTY', '599', '599', exchange, True, dupe);
    Check(not dupe, '2件目 (別コール) は重複ではない');
    Check(rec.Fields[afStx] = '2', '2件目のSTXは2 (連番)');

    { --- 重複チェック: 同一コール・同一バンド・同一モードで再度交信 --- }
    Check(clog.IsDuplicate('W1AW', '20m', 'RTTY'), 'IsDuplicate(W1AW,20m,RTTY) = True (1件目と同条件)');
    Check(not clog.IsDuplicate('W1AW', '40m', 'RTTY'), 'IsDuplicate(W1AW,40m,RTTY) = False (バンド違い)');
    Check(not clog.IsDuplicate('W1AW', '20m', 'PSK31'), 'IsDuplicate(W1AW,20m,PSK31) = False (モード違い)');

    rec := clog.LogQso('W1AW', '20m', 'RTTY', '599', '599', exchange, True, dupe);
    Check(dupe, '同一条件で3回目のLogQsoはDupe=Trueを返す (記録自体は行う)');
    Check(clog.Database.Count = 3, 'Dupeでも記録件数は3件に増える (除外は呼び出し側の判断)');

    { --- ADIF永続化の往復確認 --- }
    path := GetTempDir + 'test_contestlog_' + IntToStr(Random(100000)) + '.adi';
    Check(clog.SaveToAdif(path), 'SaveToAdif が成功する');
    Check(FileExists(path), 'ADIFファイルが作成される');

    clog2 := TContestLog.Create;
    try
      Check(clog2.LoadFromAdif(path) = 3, 'LoadFromAdif で3件読み込む');
      Check(clog2.Database[0].Call = 'W1AW', '1件目のCallが往復する');
      Check(clog2.Database[0].Fields[afCqz] = '5', '1件目のCQZが往復する');
      Check(clog2.Database[1].Call = 'JA1TEST', '2件目のCallが往復する');
    finally
      clog2.Free;
    end;
    DeleteFile(path);
  finally
    clog.Free;
    registry.Free;
    dxcc.Free;
  end;
end;

begin
  Randomize;
  WriteLn('=== コンテストロギング (ContestLog) / DXCC・ゾーン判定 (DxccDatabase) 検証 ===');

  TestFieldValidators;
  TestCountryTestWithDxcc;
  TestCountyDatabase;
  TestContestRegistry;
  TestContestLogFull;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
