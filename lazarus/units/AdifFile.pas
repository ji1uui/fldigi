{ ============================================================================
  AdifFile.pas

  fldigi 本来の ADIF (Amateur Data Interchange Format) 入出力を、複数レコード・
  全56フィールド (fldigi の cQsoRec と同じ集合) 対応で Lazarus/FPC へ移植した
  ユニット。QsoLogbook.pas の簡易版 (11フィールドのみ) を置き換える「完全版」
  ADIF I/O として、コンテストロギング (ContestLog.pas)・コールサイン検索結果の
  格納・QSLアップロード/突合機能 (QslUpload.pas) など、以降のすべての機能実装の
  基盤データ構造として使う。

  fldigi との対応:
    fldigi (C++)                                   | Lazarus (Pascal)
    --------------------------------------------------+---------------------------
    src/include/field_def.h の enum ADIF_FIELD_POS    | TAdifFieldId (本ユニット)
    src/logbook/adif_io.cxx の FIELD fields[]          | AdifFieldTags/AdifFieldMaxLen 配列
    src/logbook/adif_io.cxx の adifmt="<%s:%d>"        | AdifTagStr() 関数
    class cQsoRec (qso_db.h/.cxx)                      | TAdifRecord (本ユニット)
      qsofield[NUMFIELDS] (std::string* 配列)            FFields[TAdifFieldId] (string配列)
      putField/addtoField                                PutField/AddToField
      trimFields                                         TrimFields
      checkBand                                          CheckBand
      checkDateTimes                                     CheckDateTimes
      setDateTime                                        SetCurrentDateTime
      setFrequency                                       SetFrequencyHz
    class cQsoDb (qso_db.h/.cxx)                       | TAdifDatabase (本ユニット)
      newrec()/getRec()/nbrRecs()                        AddRecord/Records[]/Count
    cAdifIO::do_readfile()                             | TAdifDatabase.LoadFromFile
      (<EOH>検索 → レコード毎に<>区切りでフィールド走査)   (同様のアルゴリズムを踏襲)
    cAdifIO::writeFile()                               | TAdifDatabase.SaveToFile
      (ADIF_VER/PROGRAMID ヘッダ + フィールド出力 + <EOR>)
    src/globals/globals.cxx の band_names[]/band()/    | BandNameFromFreqMHz/
      band_name()/band_freq()                            BandFreqMHzFromName (本ユニット)

  設計方針・fldigiからの簡略化点:
  ----------------------------------------------------------------------------
  1. **フィールドの保持方式**: fldigi の cQsoRec は std::string* の固定長配列
     (NUMFIELDS=56要素、EXPORTは内部フラグとして55番目) で全フィールドを保持
     する。本移植版もこれを忠実に踏襲し、TAdifFieldId という enum (fldigi の
     ADIF_FIELD_POS と全く同じ順序・同じフィールド集合) をインデックスとする
     `array[TAdifFieldId] of string` で実装した。

  2. **GUIボタンによる出力可否判定は非対応**: fldigi の writeFile() は各
     フィールドに紐づく GUI チェックボックス (`fields[j].btn`) の選択状態を見て
     「エクスポート時にこのフィールドを出力するか」を判定するが、本移植版は
     GUI非依存のため、この判定は行わず「値が空でなければ常に出力する」という
     単純な方式にした (ADIF ビューア/他ロガーとの相互運用性が高い、より一般的な
     動作)。

  3. **MODE⇔SUBMODE変換 (adif2export/adif2submode) は非対応**: fldigi は内部
     モード名 (例: "PSK31") と ADIF 標準の MODE/SUBMODE (例: MODE="PSK",
     SUBMODE="PSK31") との対応表を持つが、この変換テーブルは
     mode_info[NUM_MODES] という巨大な配列 (100種類以上のモード) に依存して
     おり本移植版のスコープ外とする。本ユニットでは MODE フィールドに
     ADIF 標準のモード名文字列をそのまま格納・出力する方式とし、必要なら
     呼び出し側で SUBMODE フィールドを別途設定する。

  4. **独自拡張フィールド (fldigiのcQsoRecには存在しない)**: ユーザー要望の
     「LoTW/QRZ.com/eQSL.ccへの自動アップロードとQSL情報の突合」という独自機能
     (QslUpload.pas) のために、ADIF標準では定義されているが fldigi の
     cQsoRec には含まれていない QSL_RCVD/QSL_SENT/COMMENT、および LoTW の
     APP_LoTW_* 拡張フィールド (差分同期用) を追加した。これらは
     TAdifFieldId の末尾に追加し、fldigi の55フィールドとは明確に区別できる
     よう本ファイル冒頭にコメントを付した。

  5. **複数行 (multi-line string) フィールドの specifier拡張は非対応**:
     ADIF仕様は `<フィールド名:長さ:タイプ>値` という3要素形式 (タイプ指定
     オプション) も許すが、fldigi 自身も2要素形式 (`<フィールド名:長さ>値`)
     のみを出力するため、本移植版もこれに合わせて2要素形式のみ扱う
     (読み込み時、3要素目がある場合も長さ部分だけを見るため問題なく読める)。
  ============================================================================ }
unit AdifFile;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, StrUtils;

type
  { TAdifFieldId
    ---------------------------------------------------------------------
    fldigi: src/include/field_def.h の enum ADIF_FIELD_POS。
    先頭から afScoutR までの55項目は fldigi の並び順を完全に踏襲する
    (対応表は AdifFieldTags 配列のコメントを参照)。
    afComment 以降は本移植版の独自拡張 (上記「設計方針 4」参照)。 }
  TAdifFieldId = (
    { --- fldigi cQsoRec 互換の55フィールド (field_def.h と同じ並び) --- }
    afFreq,        afCall,        afMode,        afSubmode,     afName,
    afQsoDate,     afQsoDateOff,  afTimeOff,     afTimeOn,      afQth,
    afRstRcvd,     afRstSent,     afState,       afVeProv,      afNotes,
    afQslRDate,    afQslSDate,    afEqslRDate,   afEqslSDate,   afLotwRDate,
    afLotwSDate,   afGridSquare,  afBand,        afCnty,        afCountry,
    afCqz,         afDxcc,        afQslVia,      afIota,        afItuz,
    afCont,        afSrx,         afStx,         afXchg1,       afMyXchg,
    afClass,       afArrlSect,    afTxPwr,       afOpCall,      afStaCall,
    afMyGrid,      afMyCity,      afSsSerno,     afSsPrec,      afSsChk,
    afSsSec,       afAge,         afTenTen,      afCheck,       afFdClass,
    afFdSection,   afTroopS,      afTroopR,      afScoutS,      afScoutR,
    { --- 本移植版の独自拡張フィールド (fldigi cQsoRec には存在しない) ---
      QslUpload.pas (LoTW/QRZ/eQSL自動アップロード+QSL突合) のために追加。 }
    afComment,          // ADIF標準 COMMENT (fldigiのNOTESとは別に、突合結果メモ等に使用)
    afQslRcvd,          // ADIF標準 QSL_RCVD (Y/N/R/I)
    afQslSent,          // ADIF標準 QSL_SENT (Y/N/R/Q/I)
    afEqslQslRcvd,      // ADIF標準 EQSL_QSL_RCVD (eQSL突合結果)
    afLotwQslRcvd,      // ADIF標準 LOTW_QSL_RCVD (LoTW突合結果)
    afAppQrzLogId       // 独自: QRZ Logbook API の LOGID (再送/削除時に使用)
  );

const
  { fldigi 互換フィールドの個数 (field_def.h の NUMFIELDS-1 = EXPORTを除く55)。
    ContestLog.pas 等、fldigi互換範囲だけを扱いたいコードのための目安値。 }
  ADIF_FLDIGI_FIELD_COUNT = Ord(afScoutR) + 1;
  ADIF_FIELD_COUNT = Ord(High(TAdifFieldId)) + 1;

  ADIF_VERSION         = '3.1.4';
  ADIF_PROGRAM_ID      = 'LazarusFldigiPort';
  ADIF_PROGRAM_VERSION = '1.0';

  { fldigi: adif_io.cxx の FIELD fields[] 配列 (タグ名部分) をそのまま踏襲。
    独自拡張フィールド (afComment 以降) は ADIF 3.1.4 仕様書のタグ名を使用。 }
  AdifFieldTags: array[TAdifFieldId] of string = (
    'FREQ', 'CALL', 'MODE', 'SUBMODE', 'NAME',
    'QSO_DATE', 'QSO_DATE_OFF', 'TIME_OFF', 'TIME_ON', 'QTH',
    'RST_RCVD', 'RST_SENT', 'STATE', 'VE_PROV', 'NOTES',
    'QSLRDATE', 'QSLSDATE', 'EQSLRDATE', 'EQSLSDATE', 'LOTWRDATE',
    'LOTWSDATE', 'GRIDSQUARE', 'BAND', 'CNTY', 'COUNTRY',
    'CQZ', 'DXCC', 'QSL_VIA', 'IOTA', 'ITUZ',
    'CONT', 'SRX', 'STX', 'SRX_STRING', 'STX_STRING',
    'CLASS', 'ARRL_SECT', 'TX_PWR', 'OPERATOR', 'STATION_CALLSIGN',
    'MY_GRIDSQUARE', 'MY_CITY', 'CWSS_SERNO', 'CWSS_PREC', 'CWSS_CHK',
    'CWSS_SECTION', 'AGE', 'TEN_TEN', 'CHECK', 'FD_CLASS',
    'FD_SECTION', 'TROOPS', 'TROOPR', 'SCOUTS', 'SCOUTR',
    { --- 独自拡張 --- }
    'COMMENT', 'QSL_RCVD', 'QSL_SENT', 'EQSL_QSL_RCVD', 'LOTW_QSL_RCVD',
    'APP_LAZFLDIGI_QRZ_LOGID'
  );

  { fldigi: adif_io.cxx の FIELD fields[] 配列 (fsize = 最大長) をそのまま踏襲。
    読み込み時、指定長がこれを超える場合は fldigi と同様に切り詰める。 }
  AdifFieldMaxLen: array[TAdifFieldId] of Integer = (
    12, 30, 20, 20, 80,
    8,  8,  6,  6,  100,
    3,  3,  20, 20, 512,
    8,  8,  8,  8,  8,
    8,  8,  8,  60, 60,
    8,  8,  256,20, 20,
    60, 50, 50, 100,100,
    20, 20, 8,  30, 30,
    8,  60, 20, 20, 20,
    20, 2,  10, 10, 20,
    20, 20, 20, 20, 20,
    { --- 独自拡張 --- }
    512, 4, 4, 4, 4, 32
  );

  { TIME_ON/TIME_OFF は fldigi 同様、6桁 (HHMMSS) に 0 パディングして格納する
    フィールド。 }
  ADIF_TIME_FIELDS: set of TAdifFieldId = [afTimeOn, afTimeOff];

  { 周波数(MHz文字列) <-> バンド名 の対応表。
    fldigi: src/globals/globals.cxx の static band_freq_t band_names[]。 }
  ADIF_BAND_COUNT = 28;
  AdifBandNames: array[0..ADIF_BAND_COUNT-1] of string = (
    '160m', '80m', '75m', '60m', '40m', '30m', '20m', '17m', '15m', '12m',
    '10m', '6m', '4m', '2m', '1.25m', '70cm', '33cm', '23cm', '13cm', '9cm',
    '6cm', '3cm', '1.25cm', '6mm', '4mm', '2.5mm', '2mm', '1mm'
  );
  AdifBandLowMHz: array[0..ADIF_BAND_COUNT-1] of Double = (
    1.8, 3.5, 4.0, 5.3, 7.0, 10.0, 14.0, 18.0, 21.0, 24.0,
    28.0, 50.0, 70.0, 144.0, 222.0, 420.0, 902.0, 1240.0, 2300.0, 3300.0,
    5650.0, 10000.0, 24000.0, 47000.0, 75500.0, 119980.0, 142000.0, 241000.0
  );
  { 各バンドの上限周波数 (MHz)。fldigi globals.cxx の band() 関数の
    case文範囲 (例: 28...29 => BAND_10M) をそのまま踏襲。 }
  AdifBandHighMHz: array[0..ADIF_BAND_COUNT-1] of Double = (
    2.0, 4.0, 4.1, 5.5, 7.3, 10.15, 14.35, 18.168, 21.45, 24.99,
    29.7, 54.0, 71.0, 148.0, 225.0, 450.0, 928.0, 1325.0, 2450.0, 3500.0,
    5925.0, 10500.0, 24250.0, 47200.0, 81000.0, 120020.0, 149000.0, 250000.0
  );

type
  { TAdifRecord
    ---------------------------------------------------------------------
    fldigi: class cQsoRec (qso_db.h/.cxx) に相当。1件のQSOレコードを表す。 }
  TAdifRecord = class
  private
    FFields: array[TAdifFieldId] of string;
    FExported: Boolean; // fldigi: EXPORTフラグ (内部管理用、ADIFファイルには出力しない)
    function GetField(AId: TAdifFieldId): string;
    procedure SetField(AId: TAdifFieldId; const AValue: string);
    function GetCall: string;
    procedure SetCall(const AValue: string);
    function GetMode: string;
    procedure SetMode(const AValue: string);
    function GetFreqMHzStr: string;
    function GetBand: string;
    procedure SetBand(const AValue: string);
  public
    constructor Create;

    { fldigi: cQsoRec::clearRec() }
    procedure ClearRec;

    { fldigi: cQsoRec::putField(int n, const char *s) }
    procedure PutField(AId: TAdifFieldId; const AValue: string);
    { fldigi: cQsoRec::addtoField(int n, const char *s) }
    procedure AddToField(AId: TAdifFieldId; const AValue: string);

    { fldigi: cQsoRec::checkBand()
      FREQ が空で BAND のみ設定されていれば BAND から FREQ (帯域下端) を補完し、
      逆に BAND が空で FREQ のみ設定されていれば FREQ からバンド名を補完する。 }
    procedure CheckBand;

    { fldigi: cQsoRec::checkDateTimes()
      TIME_ON/TIME_OFF、QSO_DATE/QSO_DATE_OFF のどちらか片方だけが設定されて
      いる場合、もう片方へコピーする (fldigi のロギングUIでは通常「交信開始」
      のみ入力するため)。 }
    procedure CheckDateTimes;

    { fldigi: cQsoRec::setDateTime(bool dtOn)
      現在時刻 (ローカルではなくUTC想定、呼び出し側で ANow に
      LocalTimeToUniversal 済みの値を渡すこと) を QSO_DATE/TIME_ON
      (ADtOn=True) または QSO_DATE_OFF/TIME_OFF (ADtOn=False) に設定する。 }
    procedure SetCurrentDateTime(ADtOn: Boolean; ANowUtc: TDateTime);

    { fldigi: cQsoRec::setFrequency(long long freq) (Hz単位で受け取り、
      内部ではMHz文字列 "%lf" 形式に変換して FREQ フィールドへ格納する)。 }
    procedure SetFrequencyHz(AFreqHz: Int64);
    procedure SetFrequencyMHz(AFreqMHz: Double);

    { fldigi: cQsoRec::trimFields()
      全フィールドの前後空白除去 + CALL/MODE の大文字化。 }
    procedure TrimFields;

    { 全フィールドが空文字かどうか。 }
    function IsEmpty: Boolean;

    property Fields[AId: TAdifFieldId]: string read GetField write SetField; default;
    property Exported: Boolean read FExported write FExported;

    { よく使うフィールドへの簡易アクセサ (内部的には Fields[] と同じ)。 }
    property Call: string read GetCall write SetCall;
    property Mode: string read GetMode write SetMode;
    property FreqMHzStr: string read GetFreqMHzStr;
    property Band: string read GetBand write SetBand;
  end;

  { TAdifDatabase
    ---------------------------------------------------------------------
    fldigi: class cQsoDb (qso_db.h/.cxx) に相当。複数のQSOレコードを保持し、
    ADIFファイルへの入出力を担う。 }
  TAdifDatabase = class
  private
    FRecords: array of TAdifRecord;
    function GetCount: Integer;
    function GetRecord(AIndex: Integer): TAdifRecord;
  public
    destructor Destroy; override;

    { fldigi: cQsoDb::newrec() 相当。新規レコードを追加し、それを返す。
      戻り値の所有権は本データベースが持つ (Free 不要)。 }
    function AddRecord: TAdifRecord;

    { 既存の TAdifRecord をそのまま追加する (所有権も移譲される)。 }
    procedure AddRecord(ARec: TAdifRecord);

    procedure DeleteRecord(AIndex: Integer);
    procedure Clear;

    property Count: Integer read GetCount;
    property Records[AIndex: Integer]: TAdifRecord read GetRecord; default;

    { fldigi: cAdifIO::do_readfile()
      ADIF ファイルを読み込み、既存のレコードに追記する (Clear は呼ばない。
      複数ファイルのマージ読み込みができるよう fldigi の挙動を踏襲)。
      戻り値: 読み込んだレコード数。 }
    function LoadFromFile(const AFileName: string): Integer;

    { fldigi: cAdifIO::writeFile()
      全レコード (AOnlyExported=True の場合は Exported=True のレコードのみ)
      を ADIF ファイルへ書き出す。 }
    procedure SaveToFile(const AFileName: string; AOnlyExported: Boolean = False);
  end;

  EAdifError = class(Exception);

{ 1個の ADIF フィールドを "<TAGNAME:長さ>値" 形式に整形する。
  fldigi: adif_io.cxx の adifmt = "<%s:%d>" に相当。
  値が空文字の場合は空文字を返す (フィールド自体を出力しない)。 }
function AdifTagStr(const ATag, AValue: string): string;

{ fldigi: src/globals/globals.cxx の band_name(const char* freq_mhz)。
  周波数(MHz)からバンド名 ("20m" 等) を求める。該当バンドが無ければ
  'other' を返す。 }
function BandNameFromFreqMHz(AFreqMHz: Double): string;

{ fldigi: src/globals/globals.cxx の band_freq(const char* band_name)。
  バンド名からそのバンドの下端周波数(MHz)の文字列表現を求める。
  該当バンドが無ければ空文字を返す。 }
function BandFreqMHzFromName(const ABandName: string): string;

implementation

{ ============================================================================
  ヘルパー関数
  ============================================================================ }

function AdifTagStr(const ATag, AValue: string): string;
begin
  if AValue = '' then
    Result := ''
  else
    Result := Format('<%s:%d>%s', [ATag, Length(AValue), AValue]);
end;

function BandNameFromFreqMHz(AFreqMHz: Double): string;
var
  i: Integer;
begin
  Result := 'other';
  if AFreqMHz <= 0 then Exit;
  for i := 0 to ADIF_BAND_COUNT - 1 do
    if (AFreqMHz >= AdifBandLowMHz[i]) and (AFreqMHz <= AdifBandHighMHz[i]) then
    begin
      Result := AdifBandNames[i];
      Exit;
    end;
end;

function BandFreqMHzFromName(const ABandName: string): string;
var
  i: Integer;
  lowerName: string;
begin
  Result := '';
  lowerName := LowerCase(Trim(ABandName));
  for i := 0 to ADIF_BAND_COUNT - 1 do
    if LowerCase(AdifBandNames[i]) = lowerName then
    begin
      Result := FloatToStr(AdifBandLowMHz[i]);
      Exit;
    end;
end;

function FieldIdFromTag(const ATag: string): Integer;
  { 戻り値: TAdifFieldId の Ord() 値。見つからなければ -1。
    fldigi: adif_io.cxx の findfield() に相当 (fastlookup による高速化は行わず、
    フィールド数が高々60個程度のため単純な線形探索で十分)。 }
var
  i: TAdifFieldId;
  upTag: string;
begin
  Result := -1;
  upTag := UpperCase(ATag);
  for i := Low(TAdifFieldId) to High(TAdifFieldId) do
    if AdifFieldTags[i] = upTag then
    begin
      Result := Ord(i);
      Exit;
    end;
end;

{ ============================================================================
  TAdifRecord
  ============================================================================ }

constructor TAdifRecord.Create;
begin
  inherited Create;
  ClearRec;
  FExported := True; { 既定でエクスポート対象とする (GUI選択機能が無いため) }
end;

procedure TAdifRecord.ClearRec;
var
  i: TAdifFieldId;
begin
  for i := Low(TAdifFieldId) to High(TAdifFieldId) do
    FFields[i] := '';
end;

function TAdifRecord.GetField(AId: TAdifFieldId): string;
begin
  Result := FFields[AId];
end;

procedure TAdifRecord.SetField(AId: TAdifFieldId; const AValue: string);
begin
  PutField(AId, AValue);
end;

procedure TAdifRecord.PutField(AId: TAdifFieldId; const AValue: string);
var
  v: string;
begin
  v := AValue;
  if (AId in ADIF_TIME_FIELDS) and (v <> '') then
    while Length(v) < 6 do v := v + '0';
  if Length(v) > AdifFieldMaxLen[AId] then
    SetLength(v, AdifFieldMaxLen[AId]);
  FFields[AId] := v;
end;

procedure TAdifRecord.AddToField(AId: TAdifFieldId; const AValue: string);
begin
  FFields[AId] := FFields[AId] + AValue;
end;

function TAdifRecord.GetCall: string;
begin
  Result := FFields[afCall];
end;

procedure TAdifRecord.SetCall(const AValue: string);
begin
  PutField(afCall, UpperCase(Trim(AValue)));
end;

function TAdifRecord.GetMode: string;
begin
  Result := FFields[afMode];
end;

procedure TAdifRecord.SetMode(const AValue: string);
begin
  PutField(afMode, UpperCase(Trim(AValue)));
end;

function TAdifRecord.GetFreqMHzStr: string;
begin
  Result := FFields[afFreq];
end;

function TAdifRecord.GetBand: string;
begin
  Result := FFields[afBand];
end;

procedure TAdifRecord.SetBand(const AValue: string);
begin
  PutField(afBand, AValue);
end;

procedure TAdifRecord.CheckBand;
var
  freqMHz: Double;
  fmtSettings: TFormatSettings;
begin
  fmtSettings := DefaultFormatSettings;
  fmtSettings.DecimalSeparator := '.';
  if (FFields[afFreq] = '') and (FFields[afBand] <> '') then
  begin
    { fldigi: BAND を小文字化してから band_freq() で検索 }
    FFields[afBand] := LowerCase(FFields[afBand]);
    FFields[afFreq] := BandFreqMHzFromName(FFields[afBand]);
  end
  else if (FFields[afBand] = '') and (FFields[afFreq] <> '') then
  begin
    if TryStrToFloat(FFields[afFreq], freqMHz, fmtSettings) then
      FFields[afBand] := BandNameFromFreqMHz(freqMHz);
  end;
end;

procedure TAdifRecord.CheckDateTimes;
begin
  if (FFields[afTimeOn] = '') and (FFields[afTimeOff] <> '') then
    FFields[afTimeOn] := FFields[afTimeOff]
  else if (FFields[afTimeOn] <> '') and (FFields[afTimeOff] = '') then
    FFields[afTimeOff] := FFields[afTimeOn];

  if (FFields[afQsoDate] = '') and (FFields[afQsoDateOff] <> '') then
    FFields[afQsoDate] := FFields[afQsoDateOff]
  else if (FFields[afQsoDate] <> '') and (FFields[afQsoDateOff] = '') then
    FFields[afQsoDateOff] := FFields[afQsoDate];
end;

procedure TAdifRecord.SetCurrentDateTime(ADtOn: Boolean; ANowUtc: TDateTime);
var
  dateStr, timeStr: string;
begin
  dateStr := FormatDateTime('YYYYMMDD', ANowUtc);
  timeStr := FormatDateTime('HHNNSS', ANowUtc);
  if ADtOn then
  begin
    PutField(afQsoDate, dateStr);
    PutField(afTimeOn, timeStr);
  end
  else
  begin
    PutField(afQsoDateOff, dateStr);
    PutField(afTimeOff, timeStr);
  end;
end;

procedure TAdifRecord.SetFrequencyHz(AFreqHz: Int64);
begin
  SetFrequencyMHz(AFreqHz / 1000000.0);
end;

procedure TAdifRecord.SetFrequencyMHz(AFreqMHz: Double);
var
  fmtSettings: TFormatSettings;
  s: string;
begin
  fmtSettings := DefaultFormatSettings;
  fmtSettings.DecimalSeparator := '.';
  s := FormatFloat('0.000000', AFreqMHz, fmtSettings);
  PutField(afFreq, s);
end;

procedure TAdifRecord.TrimFields;
var
  i: TAdifFieldId;
begin
  for i := Low(TAdifFieldId) to High(TAdifFieldId) do
    FFields[i] := Trim(FFields[i]);
  FFields[afCall] := UpperCase(FFields[afCall]);
  FFields[afMode] := UpperCase(FFields[afMode]);
end;

function TAdifRecord.IsEmpty: Boolean;
var
  i: TAdifFieldId;
begin
  Result := True;
  for i := Low(TAdifFieldId) to High(TAdifFieldId) do
    if FFields[i] <> '' then
    begin
      Result := False;
      Exit;
    end;
end;

{ ============================================================================
  TAdifDatabase
  ============================================================================ }

destructor TAdifDatabase.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TAdifDatabase.GetCount: Integer;
begin
  Result := Length(FRecords);
end;

function TAdifDatabase.GetRecord(AIndex: Integer): TAdifRecord;
begin
  Result := FRecords[AIndex];
end;

function TAdifDatabase.AddRecord: TAdifRecord;
var
  n: Integer;
begin
  Result := TAdifRecord.Create;
  n := Length(FRecords);
  SetLength(FRecords, n + 1);
  FRecords[n] := Result;
end;

procedure TAdifDatabase.AddRecord(ARec: TAdifRecord);
var
  n: Integer;
begin
  n := Length(FRecords);
  SetLength(FRecords, n + 1);
  FRecords[n] := ARec;
end;

procedure TAdifDatabase.DeleteRecord(AIndex: Integer);
var
  i: Integer;
begin
  FRecords[AIndex].Free;
  for i := AIndex to Length(FRecords) - 2 do
    FRecords[i] := FRecords[i + 1];
  SetLength(FRecords, Length(FRecords) - 1);
end;

procedure TAdifDatabase.Clear;
var
  i: Integer;
begin
  for i := 0 to Length(FRecords) - 1 do
    FRecords[i].Free;
  SetLength(FRecords, 0);
end;

function TAdifDatabase.LoadFromFile(const AFileName: string): Integer;
{ fldigi: cAdifIO::do_readfile() のアルゴリズムを踏襲。
  ファイル全体を1つの文字列として読み込み、<EOH> の後から '<' 区切りで
  フィールドを走査し、フィールド名が見つかったらその値を現在のレコードへ
  格納、<EOR> でレコード確定、という単純なステートマシンで解析する。 }
var
  sl: TStringList;
  buf: string;
  p, recEnd, ptr, ptr2, tagStart, tagEnd: SizeInt;
  tag, valStr: string;
  fldIdOrd: Integer;
  colonPos, gtPos: SizeInt;
  fldSize: Integer;
  rec: TAdifRecord;
  startCount: Integer;

  function FindCI(const ASub: string; AFrom: SizeInt): SizeInt;
  begin
    Result := PosEx(LowerCase(ASub), LowerCase(buf), AFrom);
  end;

begin
  startCount := Count;
  if not FileExists(AFileName) then
    raise EAdifError.CreateFmt('ADIFファイルが見つかりません: %s', [AFileName]);

  sl := TStringList.Create;
  try
    { バイナリ的に読み込み、改行コードの相違による文字化けを避ける }
    sl.LoadFromFile(AFileName);
    buf := sl.Text;
  finally
    sl.Free;
  end;

  p := FindCI('<EOH>', 1);
  if p = 0 then
    raise EAdifError.Create('<EOH> が見つかりません。ADIFファイルではない可能性があります。');

  if (FindCI('<EOR>', 1) = 0) then
    raise EAdifError.Create('<EOR> が1件も見つかりません (空のログファイル)。');

  p := PosEx('<', buf, p + 1);
  while p > 0 do
  begin
    recEnd := FindCI('<EOR>', p);
    if recEnd = 0 then Break;

    ptr := p;
    rec := nil;
    while ptr > 0 do
    begin
      ptr2 := PosEx('<', buf, ptr + 1);
      if ptr2 = 0 then Break;

      { ptr+1 の位置から始まる '<TAG:len>value' を解析する }
      tagStart := ptr + 1;
      colonPos := PosEx(':', buf, tagStart);
      gtPos := PosEx('>', buf, tagStart);

      { <EOR> チェック (大文字小文字を無視) }
      if (gtPos > 0) and (LowerCase(Copy(buf, tagStart, 4)) = 'eor>') then
        Break;

      if (colonPos > 0) and (gtPos > 0) and (colonPos < gtPos) then
      begin
        tag := Copy(buf, tagStart, colonPos - tagStart);
        { <TAG:len> または <TAG:len:type> の両形式に対応するため、
          コロン以降・'>'までの部分文字列からさらに ':' で区切って
          最初の要素 (長さ) だけを取り出す (Split拡張メソッドは使わず、
          PosEx による明示的な走査で確実にコンパイルできるようにする)。 }
        tagEnd := PosEx(':', buf, colonPos + 1);
        if (tagEnd > 0) and (tagEnd < gtPos) then
          fldSize := StrToIntDef(Copy(buf, colonPos + 1, tagEnd - colonPos - 1), -1)
        else
          fldSize := StrToIntDef(Copy(buf, colonPos + 1, gtPos - colonPos - 1), -1);
        if fldSize >= 0 then
        begin
          valStr := Copy(buf, gtPos + 1, fldSize);
          fldIdOrd := FieldIdFromTag(tag);
          if fldIdOrd >= 0 then
          begin
            if not Assigned(rec) then
              rec := AddRecord;
            rec.PutField(TAdifFieldId(fldIdOrd), valStr);
          end;
        end;
      end;

      ptr := ptr2;
    end;

    p := PosEx('<', buf, recEnd + 1);
  end;

  Result := Count - startCount;
end;

procedure TAdifDatabase.SaveToFile(const AFileName: string;
  AOnlyExported: Boolean);
var
  sl: TStringList;
  i: Integer;
  fld: TAdifFieldId;
  rec: TAdifRecord;
  line: string;
begin
  sl := TStringList.Create;
  try
    { --- ADIF ヘッダ (fldigi: adif_io.cxx cAdifIO::writeFile() の
      ADIFHEADER 相当) --- }
    sl.Add(AdifTagStr('ADIF_VER', ADIF_VERSION));
    sl.Add(AdifTagStr('PROGRAMID', ADIF_PROGRAM_ID));
    sl.Add(AdifTagStr('PROGRAMVERSION', ADIF_PROGRAM_VERSION));
    sl.Add('<EOH>');

    for i := 0 to Count - 1 do
    begin
      rec := FRecords[i];
      if AOnlyExported and not rec.Exported then
        Continue;

      line := '';
      for fld := Low(TAdifFieldId) to High(TAdifFieldId) do
      begin
        if rec[fld] = '' then Continue;
        if fld = afFreq then
          { ADIF準拠のため、小数点はカンマではなくドット固定
            (fldigi: adif_io.cxx のカンマ→ドット変換処理に相当。
            本移植版は FormatFloat 側で既にドット固定のため単純追加のみ)。 }
          line := line + AdifTagStr(AdifFieldTags[fld], rec[fld])
        else
          line := line + AdifTagStr(AdifFieldTags[fld], rec[fld]);
      end;
      line := line + '<EOR>';
      sl.Add(line);
    end;

    sl.SaveToFile(AFileName);
  finally
    sl.Free;
  end;
end;

end.
