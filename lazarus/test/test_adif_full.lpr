{ ============================================================================
  test_adif_full.lpr

  AdifFile.pas (完全版ADIF入出力: fldigi cQsoRec/cQsoDb 互換54フィールド +
  独自拡張6フィールド) の結合テスト。

  検証項目:
    1. TAdifRecord の基本フィールド設定・取得 (fldigi互換54フィールド全て)
    2. CheckBand (FREQ<->BAND相互補完)
    3. CheckDateTimes (TIME_ON/OFF, QSO_DATE/DATE_OFF相互補完)
    4. SetCurrentDateTime / SetFrequencyHz / SetFrequencyMHz
    5. TrimFields (前後空白除去 + CALL/MODEの大文字化)
    6. 独自拡張フィールド (QSL_RCVD等) の読み書き
    7. 複数レコードのADIFファイル書き出し -> 読み込みの往復一致
    8. AdifTagStr / BandNameFromFreqMHz / BandFreqMHzFromName ヘルパー関数
  ============================================================================ }
program test_adif_full;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, DateUtils, AdifFile, Requirements;

var
  PassCount, FailCount: Integer;

procedure Check(ACond: Boolean; const AMsg: string);
begin
  if ACond then
  begin
    Inc(PassCount);
    // WriteLn('  [OK] ', AMsg);
  end
  else
  begin
    Inc(FailCount);
    WriteLn('  [NG] ', AMsg);
  end;
end;

procedure CheckStr(const AExpected, AActual, AMsg: string);
begin
  Check(AExpected = AActual, Format('%s (expected="%s" actual="%s")',
    [AMsg, AExpected, AActual]));
end;

{ --------------------------------------------------------------------------
  1. TAdifFieldId 全フィールドの基本設定・取得テスト (fldigi互換54 + 独自拡張6)
  -------------------------------------------------------------------------- }
procedure TestAllFieldsPutGet;
var
  rec: TAdifRecord;
  i: TAdifFieldId;
  testVal: string;
begin
  WriteLn('=== Test 1: 全フィールド PutField/GetField ===');
  rec := TAdifRecord.Create;
  try
    { fldigi field_def.h: FREQ=0 〜 SCOUTR までのデータフィールド数は55
      (EXPORTは内部フラグのため含まない)。本移植版もこれを忠実に踏襲。 }
    Check(ADIF_FLDIGI_FIELD_COUNT = 55, Format('ADIF_FLDIGI_FIELD_COUNT=55 (actual=%d)',
      [ADIF_FLDIGI_FIELD_COUNT]));
    Check(ADIF_FIELD_COUNT = 61, Format('ADIF_FIELD_COUNT=61 (actual=%d)',
      [ADIF_FIELD_COUNT]));

    for i := Low(TAdifFieldId) to High(TAdifFieldId) do
    begin
      if i in ADIF_TIME_FIELDS then
        testVal := '1230'  { -> 123000 に0パディングされるはず }
      else
        { AdifFieldMaxLen による切り詰めの影響を受けないよう、各フィールドの
          最大長に収まる範囲の値を使う (最短でも1文字は確保: MaxLen>=1)。 }
        testVal := Copy('X' + IntToStr(Ord(i)), 1, AdifFieldMaxLen[i]);
      rec.PutField(i, testVal);
    end;

    for i := Low(TAdifFieldId) to High(TAdifFieldId) do
    begin
      if i in ADIF_TIME_FIELDS then
        CheckStr('123000', rec[i], 'TimeField zero-pad: ' + AdifFieldTags[i])
      else
        CheckStr(Copy('X' + IntToStr(Ord(i)), 1, AdifFieldMaxLen[i]), rec[i],
          'Field roundtrip: ' + AdifFieldTags[i]);
    end;

    Check(not rec.IsEmpty, 'IsEmpty=False after PutField');
  finally
    rec.Free;
  end;

  rec := TAdifRecord.Create;
  try
    Check(rec.IsEmpty, 'IsEmpty=True on fresh record');
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. AddToField / MaxLen 切り詰めテスト
  -------------------------------------------------------------------------- }
procedure TestAddToFieldAndMaxLen;
var
  rec: TAdifRecord;
  longVal: string;
begin
  WriteLn('=== Test 2: AddToField / MaxLen切り詰め ===');
  rec := TAdifRecord.Create;
  try
    rec.PutField(afCall, 'JI1UUI');
    rec.AddToField(afCall, '/QRP');
    CheckStr('JI1UUI/QRP', rec[afCall], 'AddToField');

    { afCall の MaxLen=30。長い文字列を入れて切り詰められることを確認 }
    longVal := StringOfChar('A', 50);
    rec.PutField(afCall, longVal);
    Check(Length(rec[afCall]) = 30, Format('MaxLen切り詰め: len=%d (expected 30)',
      [Length(rec[afCall])]));
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. CheckBand (FREQ<->BAND相互補完) テスト
  -------------------------------------------------------------------------- }
procedure TestCheckBand;
var
  rec: TAdifRecord;
begin
  WriteLn('=== Test 3: CheckBand ===');

  { FREQのみ -> BANDを補完 }
  rec := TAdifRecord.Create;
  try
    rec.SetFrequencyMHz(14.070);
    rec.CheckBand;
    CheckStr('20m', rec[afBand], 'CheckBand: 14.070MHz -> 20m');
  finally
    rec.Free;
  end;

  { BANDのみ -> FREQを補完 (下端周波数) }
  rec := TAdifRecord.Create;
  try
    rec.PutField(afBand, '40m');
    rec.CheckBand;
    CheckStr('7', Copy(rec[afFreq], 1, 1), 'CheckBand: 40m -> FREQ starts with 7');
  finally
    rec.Free;
  end;

  { 7MHz台 -> 40m }
  rec := TAdifRecord.Create;
  try
    rec.SetFrequencyMHz(7.074);
    rec.CheckBand;
    CheckStr('40m', rec[afBand], 'CheckBand: 7.074MHz -> 40m');
  finally
    rec.Free;
  end;

  { 430MHz -> 70cm }
  rec := TAdifRecord.Create;
  try
    rec.SetFrequencyMHz(430.0);
    rec.CheckBand;
    CheckStr('70cm', rec[afBand], 'CheckBand: 430MHz -> 70cm');
  finally
    rec.Free;
  end;

  { 該当なし -> other }
  rec := TAdifRecord.Create;
  try
    rec.SetFrequencyMHz(999.0);
    rec.CheckBand;
    CheckStr('other', rec[afBand], 'CheckBand: 999MHz -> other');
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. CheckDateTimes テスト
  -------------------------------------------------------------------------- }
procedure TestCheckDateTimes;
var
  rec: TAdifRecord;
begin
  WriteLn('=== Test 4: CheckDateTimes ===');

  rec := TAdifRecord.Create;
  try
    rec.PutField(afQsoDate, '20260828');
    rec.PutField(afTimeOn, '123456');
    rec.CheckDateTimes;
    CheckStr('123456', rec[afTimeOff], 'CheckDateTimes: TimeOn -> TimeOff');
    CheckStr('20260828', rec[afQsoDateOff], 'CheckDateTimes: QsoDate -> QsoDateOff');
  finally
    rec.Free;
  end;

  rec := TAdifRecord.Create;
  try
    rec.PutField(afTimeOff, '235959');
    rec.CheckDateTimes;
    CheckStr('235959', rec[afTimeOn], 'CheckDateTimes: TimeOff -> TimeOn');
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. SetCurrentDateTime / SetFrequencyHz テスト
  -------------------------------------------------------------------------- }
procedure TestSetCurrentDateTimeAndFreq;
var
  rec: TAdifRecord;
  dt: TDateTime;
begin
  WriteLn('=== Test 5: SetCurrentDateTime / SetFrequencyHz ===');

  rec := TAdifRecord.Create;
  try
    dt := EncodeDateTime(2026, 8, 28, 9, 30, 15, 0);
    rec.SetCurrentDateTime(True, dt);
    CheckStr('20260828', rec[afQsoDate], 'SetCurrentDateTime(On): QsoDate');
    CheckStr('093015', rec[afTimeOn], 'SetCurrentDateTime(On): TimeOn');

    rec.SetCurrentDateTime(False, dt);
    CheckStr('20260828', rec[afQsoDateOff], 'SetCurrentDateTime(Off): QsoDateOff');
    CheckStr('093015', rec[afTimeOff], 'SetCurrentDateTime(Off): TimeOff');

    rec.SetFrequencyHz(14070000);
    CheckStr('14.070000', rec[afFreq], 'SetFrequencyHz: 14070000Hz -> 14.070000MHz');
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. TrimFields テスト
  -------------------------------------------------------------------------- }
procedure TestTrimFields;
var
  rec: TAdifRecord;
begin
  WriteLn('=== Test 6: TrimFields ===');
  rec := TAdifRecord.Create;
  try
    rec.PutField(afCall, '  ji1uui  ');
    rec.PutField(afMode, '  rtty  ');
    rec.PutField(afName, '  Taro  ');
    rec.TrimFields;
    CheckStr('JI1UUI', rec[afCall], 'TrimFields: Call trimmed+upper');
    CheckStr('RTTY', rec[afMode], 'TrimFields: Mode trimmed+upper');
    CheckStr('Taro', rec[afName], 'TrimFields: Name trimmed (not upper)');
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 独自拡張フィールドテスト
  -------------------------------------------------------------------------- }
procedure TestExtendedFields;
var
  rec: TAdifRecord;
begin
  WriteLn('=== Test 7: 独自拡張フィールド (QSL_RCVD等) ===');
  rec := TAdifRecord.Create;
  try
    rec.PutField(afQslRcvd, 'Y');
    rec.PutField(afQslSent, 'Y');
    rec.PutField(afEqslQslRcvd, 'Y');
    rec.PutField(afLotwQslRcvd, 'N');
    rec.PutField(afAppQrzLogId, '123456789');
    rec.PutField(afComment, 'Test comment for QSL matching');

    CheckStr('Y', rec[afQslRcvd], 'Extended: QslRcvd');
    CheckStr('Y', rec[afQslSent], 'Extended: QslSent');
    CheckStr('Y', rec[afEqslQslRcvd], 'Extended: EqslQslRcvd');
    CheckStr('N', rec[afLotwQslRcvd], 'Extended: LotwQslRcvd');
    CheckStr('123456789', rec[afAppQrzLogId], 'Extended: AppQrzLogId');
    CheckStr('Test comment for QSL matching', rec[afComment], 'Extended: Comment');

    CheckStr('QSL_RCVD', AdifFieldTags[afQslRcvd], 'Tag: QSL_RCVD');
    CheckStr('APP_LAZFLDIGI_QRZ_LOGID', AdifFieldTags[afAppQrzLogId], 'Tag: APP_LAZFLDIGI_QRZ_LOGID');
  finally
    rec.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. AdifTagStr / BandNameFromFreqMHz / BandFreqMHzFromName ヘルパーテスト
  -------------------------------------------------------------------------- }
procedure TestHelperFunctions;
begin
  WriteLn('=== Test 8: ヘルパー関数 ===');
  CheckStr('<CALL:6>JI1UUI', AdifTagStr('CALL', 'JI1UUI'), 'AdifTagStr basic');
  CheckStr('', AdifTagStr('CALL', ''), 'AdifTagStr empty value -> empty string');

  CheckStr('20m', BandNameFromFreqMHz(14.070), 'BandNameFromFreqMHz 14.070->20m');
  CheckStr('160m', BandNameFromFreqMHz(1.9), 'BandNameFromFreqMHz 1.9->160m');
  CheckStr('6m', BandNameFromFreqMHz(50.313), 'BandNameFromFreqMHz 50.313->6m');
  CheckStr('other', BandNameFromFreqMHz(0.5), 'BandNameFromFreqMHz 0.5->other (below all bands)');

  Check(BandFreqMHzFromName('20m') = '14', 'BandFreqMHzFromName 20m->14 (actual=' +
    BandFreqMHzFromName('20m') + ')');
  Check(BandFreqMHzFromName('nonexistent') = '', 'BandFreqMHzFromName unknown->empty');
end;

{ --------------------------------------------------------------------------
  9. TAdifDatabase 複数レコード ADIF ファイル 書き出し->読み込み 往復一致テスト
  -------------------------------------------------------------------------- }
procedure TestDatabaseRoundTrip;
var
  db1, db2: TAdifDatabase;
  rec: TAdifRecord;
  fname: string;
  i: Integer;
  fld: TAdifFieldId;
  matched: Boolean;
begin
  WriteLn('=== Test 9: TAdifDatabase 複数レコード往復テスト ===');
  fname := GetTempDir + 'test_adif_roundtrip.adi';

  db1 := TAdifDatabase.Create;
  try
    { レコード1: RTTYコンテストQSO風 }
    rec := db1.AddRecord;
    rec.Call := 'JA1XYZ';
    rec.Mode := 'RTTY';
    rec.SetFrequencyMHz(14.080);
    rec.PutField(afQsoDate, '20260828');
    rec.PutField(afTimeOn, '103000');
    rec.PutField(afRstSent, '599');
    rec.PutField(afRstRcvd, '599');
    rec.PutField(afName, 'Taro');
    rec.PutField(afQth, 'Tokyo');
    rec.PutField(afGridSquare, 'PM95');
    rec.PutField(afSrx, '001');
    rec.PutField(afStx, '042');
    rec.CheckBand;
    rec.CheckDateTimes;

    { レコード2: CWコンテストQSO風 (独自拡張フィールド含む) }
    rec := db1.AddRecord;
    rec.Call := 'W1ABC';
    rec.Mode := 'CW';
    rec.SetFrequencyMHz(7.030);
    rec.PutField(afQsoDate, '20260828');
    rec.PutField(afTimeOn, '110000');
    rec.PutField(afRstSent, '589');
    rec.PutField(afRstRcvd, '599');
    rec.PutField(afArrlSect, 'CT');
    rec.PutField(afCqz, '5');
    rec.PutField(afItuz, '8');
    rec.PutField(afDxcc, '291');
    rec.PutField(afCountry, 'USA');
    rec.PutField(afQslRcvd, 'Y');
    rec.PutField(afLotwQslRcvd, 'Y');
    rec.CheckBand;
    rec.CheckDateTimes;

    { レコード3: FT8的なQSO (日本語コメント含む、UTF-8対応確認) }
    rec := db1.AddRecord;
    rec.Call := 'JR1ABC';
    rec.Mode := 'FT8';
    rec.SetFrequencyMHz(50.313);
    rec.PutField(afQsoDate, '20260828');
    rec.PutField(afTimeOn, '120500');
    rec.PutField(afRstSent, '-05');
    rec.PutField(afRstRcvd, '+02');
    rec.PutField(afComment, 'こんにちは 日本語コメントテスト');
    rec.CheckBand;
    rec.CheckDateTimes;

    Check(db1.Count = 3, Format('db1.Count=3 (actual=%d)', [db1.Count]));

    db1.SaveToFile(fname);
    Check(FileExists(fname), 'ADIFファイルが作成された: ' + fname);
  finally
    db1.Free;
  end;

  db2 := TAdifDatabase.Create;
  try
    i := db2.LoadFromFile(fname);
    Check(i = 3, Format('LoadFromFile読み込み件数=3 (actual=%d)', [i]));
    Check(db2.Count = 3, Format('db2.Count=3 (actual=%d)', [db2.Count]));

    if db2.Count >= 1 then
    begin
      CheckStr('JA1XYZ', db2[0].Call, 'RoundTrip rec0 Call');
      CheckStr('RTTY', db2[0].Mode, 'RoundTrip rec0 Mode');
      CheckStr('14.080000', db2[0][afFreq], 'RoundTrip rec0 Freq');
      CheckStr('20m', db2[0][afBand], 'RoundTrip rec0 Band (checkband前に保存済み)');
      CheckStr('599', db2[0][afRstSent], 'RoundTrip rec0 RstSent');
      CheckStr('PM95', db2[0][afGridSquare], 'RoundTrip rec0 GridSquare');
      CheckStr('001', db2[0][afSrx], 'RoundTrip rec0 Srx');
      CheckStr('042', db2[0][afStx], 'RoundTrip rec0 Stx');
    end;

    if db2.Count >= 2 then
    begin
      CheckStr('W1ABC', db2[1].Call, 'RoundTrip rec1 Call');
      CheckStr('CW', db2[1].Mode, 'RoundTrip rec1 Mode');
      CheckStr('40m', db2[1][afBand], 'RoundTrip rec1 Band');
      CheckStr('CT', db2[1][afArrlSect], 'RoundTrip rec1 ArrlSect');
      CheckStr('5', db2[1][afCqz], 'RoundTrip rec1 Cqz');
      CheckStr('291', db2[1][afDxcc], 'RoundTrip rec1 Dxcc');
      CheckStr('Y', db2[1][afQslRcvd], 'RoundTrip rec1 QslRcvd (独自拡張)');
      CheckStr('Y', db2[1][afLotwQslRcvd], 'RoundTrip rec1 LotwQslRcvd (独自拡張)');
    end;

    if db2.Count >= 3 then
    begin
      CheckStr('JR1ABC', db2[2].Call, 'RoundTrip rec2 Call');
      CheckStr('FT8', db2[2].Mode, 'RoundTrip rec2 Mode');
      CheckStr('6m', db2[2][afBand], 'RoundTrip rec2 Band');
      CheckStr('こんにちは 日本語コメントテスト', db2[2][afComment],
        'RoundTrip rec2 Comment (UTF-8日本語)');
    end;

    { 全フィールドタグが読めることを確認 (fldigi互換54フィールドすべて
      走査してもエラーにならないこと) }
    matched := True;
    for fld := Low(TAdifFieldId) to High(TAdifFieldId) do
    begin
      if db2.Count > 0 then
        db2[0][fld]; { just access, should not raise }
    end;
    Check(matched, '全フィールドアクセスがエラーなく完了');
  finally
    db2.Free;
  end;

  { AOnlyExported=True のテスト }
  db1 := TAdifDatabase.Create;
  try
    rec := db1.AddRecord;
    rec.Call := 'EXPORT1';
    rec.Exported := True;

    rec := db1.AddRecord;
    rec.Call := 'NOEXPORT1';
    rec.Exported := False;

    db1.SaveToFile(fname, True);
  finally
    db1.Free;
  end;

  db2 := TAdifDatabase.Create;
  try
    db2.LoadFromFile(fname);
    Check(db2.Count = 1, Format('AOnlyExported: Count=1 (actual=%d)', [db2.Count]));
    if db2.Count = 1 then
      CheckStr('EXPORT1', db2[0].Call, 'AOnlyExported: only exported rec saved');
  finally
    db2.Free;
  end;

  if FileExists(fname) then
    DeleteFile(fname);
end;

{ --------------------------------------------------------------------------
  10. DeleteRecord / Clear テスト
  -------------------------------------------------------------------------- }
procedure TestDeleteAndClear;
var
  db: TAdifDatabase;
  rec: TAdifRecord;
begin
  WriteLn('=== Test 10: DeleteRecord / Clear ===');
  db := TAdifDatabase.Create;
  try
    rec := db.AddRecord; rec.Call := 'AAA';
    rec := db.AddRecord; rec.Call := 'BBB';
    rec := db.AddRecord; rec.Call := 'CCC';
    Check(db.Count = 3, 'Before delete: Count=3');

    db.DeleteRecord(1); { BBBを削除 }
    Check(db.Count = 2, Format('After delete: Count=2 (actual=%d)', [db.Count]));
    CheckStr('AAA', db[0].Call, 'After delete: rec0=AAA');
    CheckStr('CCC', db[1].Call, 'After delete: rec1=CCC (shifted)');

    db.Clear;
    Check(db.Count = 0, Format('After clear: Count=0 (actual=%d)', [db.Count]));
  finally
    db.Free;
  end;
end;

{ --------------------------------------------------------------------------
  11. 既存の壊れたファイル / 空ファイルのエラーハンドリングテスト
  -------------------------------------------------------------------------- }
procedure TestErrorHandling;
var
  db: TAdifDatabase;
  fname: string;
  sl: TStringList;
  gotException: Boolean;
begin
  WriteLn('=== Test 11: エラーハンドリング ===');
  db := TAdifDatabase.Create;
  try
    gotException := False;
    try
      db.LoadFromFile(GetTempDir + 'nonexistent_file_12345.adi');
    except
      on E: EAdifError do
        gotException := True;
    end;
    Check(gotException, 'LoadFromFile: 存在しないファイルで EAdifError');

    fname := GetTempDir + 'test_adif_noeoh.adi';
    sl := TStringList.Create;
    try
      sl.Add('this is not an adif file');
      sl.SaveToFile(fname);
    finally
      sl.Free;
    end;
    gotException := False;
    try
      db.LoadFromFile(fname);
    except
      on E: EAdifError do
        gotException := True;
    end;
    Check(gotException, 'LoadFromFile: <EOH>なしファイルで EAdifError');
    DeleteFile(fname);
  finally
    db.Free;
  end;
end;

begin
  PassCount := 0;
  FailCount := 0;

  WriteLn('AdifFile.pas 結合テスト開始');
  WriteLn('============================');

  TestAllFieldsPutGet;
  TestAddToFieldAndMaxLen;
  TestCheckBand;
  TestCheckDateTimes;
  TestSetCurrentDateTimeAndFreq;
  TestTrimFields;
  TestExtendedFields;
  TestHelperFunctions;
  TestDatabaseRoundTrip;
  TestDeleteAndClear;
  TestErrorHandling;

  WriteLn('============================');
  WriteLn(Format('結果: %d 件成功 / %d 件失敗 (計 %d 件)',
    [PassCount, FailCount, PassCount + FailCount]));

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
    CoverReq('CMP-001');

  if FailCount > 0 then
    Halt(1)
  else
    Halt(0);
end.
