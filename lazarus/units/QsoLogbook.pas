{ ============================================================================
  QsoLogbook.pas

  本アプリ内蔵の QSO ログブック機能。1 局と交信するたびに TQsoRecord を
  追加し、実行ファイルと同じディレクトリの JSON ファイル (ADIF ではなく
  アプリ内部形式) へ永続化する。また、追加と同時に AdifUdpSender 経由で
  ADIF レコードを外部ロガーへ UDP 送信する「ロギングは外部アプリに
  任せる」運用にも対応する (両方同時に有効化することも、内蔵ログのみ/
  外部UDPのみに絞ることも可能)。

  fldigi との対応:
    fldigi (C++)                                | Lazarus (Pascal)
    ----------------------------------------------+---------------------------
    class cQsoRec (qso_db.h)                      | TQsoRecord (本ユニット)
    class cQsoDb (qso_db.h/.cxx)                   | TQsoLogbook (本ユニット)
    logsupport.cxx AddRecord()                    | TQsoLogbook.AddQso
      (Station情報のQSOレコードへのコピーを含む)     (StationInfo を引数に取る)
    src/logbook/adif_io.cxx cAdifIO::writeFile()   | (内蔵ログ自体は JSON で
      (.adi ファイルへの永続化)                       保存。外部ロガー連携は
                                                       AdifUdpSender が担当)

  設計方針:
  ----------------------------------------------------------------------------
  - 本アプリ内でのロギング (ユーザー要望「ロギング機能は本アプリ内にも
    実装(スコープ内)」) と、外部ロガーへの ADIF-over-UDP 配信は
    独立した機能として扱う。TQsoLogbook.AddQso() は常に内蔵ログへ
    記録した上で、UdpSender が Assigned かつ Enabled であれば
    追加で UDP 送信も行う。
  - 永続化形式は StationInfo.pas と同じ方針 (JSON、実行ファイルと同じ
    ディレクトリ) に統一する。
  ============================================================================ }
unit QsoLogbook;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, fpjson, jsonparser, AdifUdpSender, StationInfo,
  SafeFileIO;

type
  { TQsoRecord
    ---------------------------------------------------------------------
    fldigi: class cQsoRec (qso_db.h) の主要フィールドを簡略化したもの。
    日時は UTC で保持する (ADIF の慣習に合わせる)。 }
  TQsoRecord = record
    Call: string;
    QsoDateUtc: TDateTime;
    TimeOnUtc: TDateTime;
    TimeOffUtc: TDateTime;
    Mode: string;
    FreqMHz: Double;
    RstSent: string;
    RstRcvd: string;
    Name: string;
    Qth: string;
    GridSquare: string;
    Comment: string;
  end;

  { TQsoLogbook
    ---------------------------------------------------------------------
    fldigi: class cQsoDb (qso_db.h/.cxx) に相当。
    交信記録の追加・保持・JSON永続化・(オプションで) UDP外部送信の
    トリガーを担当する。 }
  TQsoLogbook = class
  private
    FRecords: array of TQsoRecord;
    FStation: TStationInfo;      // 参照のみ。生成/破棄は呼び出し側が担う。
    FUdpSender: TAdifUdpSender;  // 参照のみ。nil なら UDP 送信を行わない。
    function GetCount: Integer;
    function GetRecord(AIndex: Integer): TQsoRecord;
  public
    constructor Create;
    destructor Destroy; override;

    { 1件の QSO を追加する。
      - 内蔵ログ (FRecords) へ常に追加する
        (fldigi: cQsoDb::qsoNewRec() に相当)。
      - Station (Assigned かつ AutoSendUdp=True の場合) が設定されていれば
        AdifUdpSender.SendQso() 経由で外部ロガーへも配信する
        (fldigi: logsupport.cxx AddRecord() が progdefaults の
        Station情報を QSOレコードへコピーしてから保存する処理、および
        「ロギングは外部アプリに任せる」というユーザー要望に対応)。 }
    procedure AddQso(const AQso: TQsoRecord);

    { AddQso の簡易版。良く使うフィールドのみを引数に取る。
      TimeOffUtc は 0 (未設定) として記録される。 }
    procedure AddQso(const ACall, AMode: string; AFreqMHz: Double;
      const ARstSent, ARstRcvd: string);

    property Count: Integer read GetCount;
    property Records[AIndex: Integer]: TQsoRecord read GetRecord; default;

    { 生成時に外部から結び付ける依存オブジェクト。所有権は持たない
      (Free は呼び出し側の責任)。 }
    property Station: TStationInfo read FStation write FStation;
    property UdpSender: TAdifUdpSender read FUdpSender write FUdpSender;

    class function DefaultFilePath: string;
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    procedure LoadDefault;
    procedure SaveDefault;

    procedure Clear;
  end;

  EQsoLogbookError = class(Exception);

implementation

const
  DEFAULT_FILE_NAME = 'qso_log.json';

  KEY_CALL        = 'call';
  KEY_QSO_DATE    = 'qsoDate';   // ISO8601 (YYYY-MM-DD)
  KEY_TIME_ON     = 'timeOn';    // ISO8601時刻 (HH:NN:SS)
  KEY_TIME_OFF    = 'timeOff';
  KEY_MODE        = 'mode';
  KEY_FREQ_MHZ    = 'freqMHz';
  KEY_RST_SENT    = 'rstSent';
  KEY_RST_RCVD    = 'rstRcvd';
  KEY_NAME        = 'name';
  KEY_QTH         = 'qth';
  KEY_GRIDSQUARE  = 'gridSquare';
  KEY_COMMENT     = 'comment';
  KEY_RECORDS     = 'records';

{ 日付/時刻 <-> 文字列の変換ヘルパー (ISO8601風、TDateTimeが0の場合は
  空文字列として保存・復元する) }

function DateToIso(ADate: TDateTime): string;
begin
  if ADate = 0 then
    Result := ''
  else
    Result := FormatDateTime('YYYY-MM-DD', ADate);
end;

function IsoToDate(const S: string): TDateTime;
begin
  if S = '' then
    Result := 0
  else
    Result := ScanDateTime('YYYY-MM-DD', S);
end;

function TimeToIso(ATime: TDateTime): string;
begin
  if ATime = 0 then
    Result := ''
  else
    Result := FormatDateTime('HH:NN:SS', ATime);
end;

function IsoToTime(const S: string): TDateTime;
begin
  if S = '' then
    Result := 0
  else
    Result := ScanDateTime('HH:NN:SS', S);
end;

{ TQsoLogbook }

constructor TQsoLogbook.Create;
begin
  inherited Create;
  SetLength(FRecords, 0);
  FStation := nil;
  FUdpSender := nil;
end;

destructor TQsoLogbook.Destroy;
begin
  { FStation / FUdpSender は所有していないため Free しない。 }
  inherited Destroy;
end;

function TQsoLogbook.GetCount: Integer;
begin
  Result := Length(FRecords);
end;

function TQsoLogbook.GetRecord(AIndex: Integer): TQsoRecord;
begin
  { 範囲外アクセスはアクセス違反ではなく、原因の分かる例外にする。 }
  if (AIndex < 0) or (AIndex >= Length(FRecords)) then
    raise EQsoLogbookError.CreateFmt(
      'QSO番号が範囲外です: %d (件数 %d)', [AIndex, Length(FRecords)]);
  Result := FRecords[AIndex];
end;

procedure TQsoLogbook.AddQso(const AQso: TQsoRecord);
var
  n: Integer;
  udpQso: TAdifQsoData;
begin
  { --- 内蔵ログへ追加 (fldigi: cQsoDb::qsoNewRec() 相当) --- }
  n := Length(FRecords);
  SetLength(FRecords, n + 1);
  FRecords[n] := AQso;

  { --- 外部ロガーへ ADIF-over-UDP 配信
    (fldigi: logsupport.cxx AddRecord() の Station情報コピー処理 +
    「ロギングは外部アプリに任せる」というユーザー要望への対応) --- }
  if Assigned(FUdpSender) and FUdpSender.Enabled then
  begin
    udpQso.Call := AQso.Call;
    udpQso.QsoDateUtc := AQso.QsoDateUtc;
    udpQso.TimeOnUtc := AQso.TimeOnUtc;
    udpQso.TimeOffUtc := AQso.TimeOffUtc;
    udpQso.Mode := AQso.Mode;
    udpQso.FreqMHz := AQso.FreqMHz;
    udpQso.RstSent := AQso.RstSent;
    udpQso.RstRcvd := AQso.RstRcvd;
    udpQso.Name := AQso.Name;
    udpQso.Qth := AQso.Qth;
    udpQso.GridSquare := AQso.GridSquare;
    udpQso.Comment := AQso.Comment;
    FUdpSender.SendQso(udpQso, FStation);
  end;
end;

procedure TQsoLogbook.AddQso(const ACall, AMode: string; AFreqMHz: Double;
  const ARstSent, ARstRcvd: string);
var
  qso: TQsoRecord;
  nowUtc: TDateTime;
begin
  nowUtc := LocalTimeToUniversal(Now);
  qso.Call := ACall;
  qso.QsoDateUtc := Int(nowUtc);
  qso.TimeOnUtc := Frac(nowUtc);
  qso.TimeOffUtc := 0;
  qso.Mode := AMode;
  qso.FreqMHz := AFreqMHz;
  qso.RstSent := ARstSent;
  qso.RstRcvd := ARstRcvd;
  qso.Name := '';
  qso.Qth := '';
  qso.GridSquare := '';
  qso.Comment := '';
  AddQso(qso);
end;

class function TQsoLogbook.DefaultFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + DEFAULT_FILE_NAME;
end;

procedure TQsoLogbook.LoadFromFile(const AFileName: string);
var
  sl: TStringList;
  data: TJSONData;
  root: TJSONObject;
  arr: TJSONArray;
  i: Integer;
  itemObj: TJSONObject;
  qso: TQsoRecord;
begin
  if not FileExists(AFileName) then
    Exit;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    try
      data := GetJSON(sl.Text);
    except
      on E: Exception do
        raise EQsoLogbookError.Create(
          'qso_log.json の解析に失敗しました: ' + E.Message);
    end;
    try
      if not (data is TJSONObject) then
        raise EQsoLogbookError.Create(
          'qso_log.json の内容が JSON オブジェクトではありません');
      root := TJSONObject(data);
      if root.Find(KEY_RECORDS) = nil then
      begin
        SetLength(FRecords, 0);
        Exit;
      end;
      arr := root.Arrays[KEY_RECORDS];
      SetLength(FRecords, arr.Count);
      for i := 0 to arr.Count - 1 do
      begin
        itemObj := arr.Objects[i];
        qso.Call       := itemObj.Get(KEY_CALL, '');
        qso.QsoDateUtc := IsoToDate(itemObj.Get(KEY_QSO_DATE, ''));
        qso.TimeOnUtc  := IsoToTime(itemObj.Get(KEY_TIME_ON, ''));
        qso.TimeOffUtc := IsoToTime(itemObj.Get(KEY_TIME_OFF, ''));
        qso.Mode       := itemObj.Get(KEY_MODE, '');
        qso.FreqMHz    := itemObj.Get(KEY_FREQ_MHZ, Double(0));
        qso.RstSent    := itemObj.Get(KEY_RST_SENT, '');
        qso.RstRcvd    := itemObj.Get(KEY_RST_RCVD, '');
        qso.Name       := itemObj.Get(KEY_NAME, '');
        qso.Qth        := itemObj.Get(KEY_QTH, '');
        qso.GridSquare := itemObj.Get(KEY_GRIDSQUARE, '');
        qso.Comment    := itemObj.Get(KEY_COMMENT, '');
        FRecords[i] := qso;
      end;
    finally
      data.Free;
    end;
  finally
    sl.Free;
  end;
end;

procedure TQsoLogbook.SaveToFile(const AFileName: string);
var
  root: TJSONObject;
  arr: TJSONArray;
  itemObj: TJSONObject;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    arr := TJSONArray.Create;
    for i := 0 to High(FRecords) do
    begin
      itemObj := TJSONObject.Create;
      itemObj.Add(KEY_CALL, FRecords[i].Call);
      itemObj.Add(KEY_QSO_DATE, DateToIso(FRecords[i].QsoDateUtc));
      itemObj.Add(KEY_TIME_ON, TimeToIso(FRecords[i].TimeOnUtc));
      itemObj.Add(KEY_TIME_OFF, TimeToIso(FRecords[i].TimeOffUtc));
      itemObj.Add(KEY_MODE, FRecords[i].Mode);
      itemObj.Add(KEY_FREQ_MHZ, FRecords[i].FreqMHz);
      itemObj.Add(KEY_RST_SENT, FRecords[i].RstSent);
      itemObj.Add(KEY_RST_RCVD, FRecords[i].RstRcvd);
      itemObj.Add(KEY_NAME, FRecords[i].Name);
      itemObj.Add(KEY_QTH, FRecords[i].Qth);
      itemObj.Add(KEY_GRIDSQUARE, FRecords[i].GridSquare);
      itemObj.Add(KEY_COMMENT, FRecords[i].Comment);
      arr.Add(itemObj);
    end;
    root.Add(KEY_RECORDS, arr);

    { 一時ファイル + rename による原子的保存 (SafeFileIO 参照)。
      移動運用中にバッテリーが切れても交信ログが失われない。 }
    SaveTextAtomic(AFileName, root.FormatJSON);
  finally
    root.Free;
  end;
end;

procedure TQsoLogbook.LoadDefault;
begin
  LoadFromFile(DefaultFilePath);
end;

procedure TQsoLogbook.SaveDefault;
begin
  SaveToFile(DefaultFilePath);
end;

procedure TQsoLogbook.Clear;
begin
  SetLength(FRecords, 0);
end;

initialization
  { 日本語 (相手局の名前・QTH 等) を JSON 往復で壊さないための必須設定。
    理由と詳細は StationInfo.pas の initialization のコメントを参照。
    プロセス全体に効く冪等な設定であり、JSON 永続化を行う各ユニットが
    リンク順に依存せず単体で正しく動くよう、ここでも宣言している。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
