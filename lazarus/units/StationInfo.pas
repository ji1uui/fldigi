{ ============================================================================
  StationInfo.pas

  局情報 (コールサイン/オペレータ名/運用地/グリッドロケータ/アンテナ等) を
  保持し、実行ファイルと同じディレクトリに JSON ファイルとして永続化する。

  fldigi との対応:
    fldigi (C++)                              | Lazarus (Pascal)
    --------------------------------------------+-------------------------
    progdefaults (configuration.h の ELEM_ マクロ) | TStationInfo (本ユニット)
    progdefaults.myCall    (MYCALL)             | MyCall
    progdefaults.operCall  (OPERCALL)           | OperCall
    progdefaults.myName    (MYNAME)             | MyName
    progdefaults.myQth     (MYQTH)              | MyQth
    progdefaults.myLocator (MYLOC)              | MyLocator
    progdefaults.myAntenna (MYANTENNA)          | MyAntenna
    fldigi_def.xml への保存 (INI/XML形式)        | JSON形式での保存 (本ユニット)

  設計方針:
  ----------------------------------------------------------------------------
  1. fldigi は設定全体を XML (実体は INI 相当のキー/値集合、
     `$HOME/.fldigi/fldigi_def.xml`) に保存するが、本移植版では
     ユーザー要望により「実行ファイルと同じディレクトリ」に
     「各OSで標準的な構造化フォーマット」= JSON で保存する
     (FPC 標準の fpjson/jsonparser ユニットのみで実装でき、
     追加の外部ライブラリ依存が不要なため)。

  2. ADIF タグ名との対応も本ユニットの責務ではなく、AdifUdpSender.pas /
     QsoLogRecord.pas 側で TStationInfo のプロパティを参照して
     STATION_CALLSIGN / OPERATOR / MY_GRIDSQUARE / MY_CITY / MY_ANTENNA
     等の ADIF フィールドへ変換する (fldigi の logsupport.cxx
     AddRecord() が progdefaults.myCall 等を QSO レコードへコピーする
     処理に相当)。

  3. Strategy パターンとの整合: 本クラスは GUI/永続化フォーマットに
     依存する具体的な処理を持つが、他ユニット (RigControlIntf 等) と
     同様 GUI (LCL) には一切依存しないため、コンソールのみの環境でも
     単体テスト可能。
  ============================================================================ }
unit StationInfo;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, SafeFileIO;

type
  { TStationInfo
    ---------------------------------------------------------------------
    fldigi: progdefaults の Operator/Station 情報部分 }
  TStationInfo = class
  private
    FMyCall: string;      // 自局コールサイン    (fldigi: myCall    / ADIF: STATION_CALLSIGN)
    FOperCall: string;    // 運用者コールサイン  (fldigi: operCall  / ADIF: OPERATOR)
    FMyName: string;      // 運用者名            (fldigi: myName)
    FMyQth: string;       // 運用地 (QTH)        (fldigi: myQth     / ADIF: MY_CITY)
    FMyLocator: string;   // グリッドロケータ    (fldigi: myLocator / ADIF: MY_GRIDSQUARE)
    FMyAntenna: string;   // アンテナ情報        (fldigi: myAntenna / ADIF: MY_ANTENNA)
    { OpProfile の TEquipmentSet が解決するのに、ここに受け皿が無かったため
      TResolvedStation から先へ渡せていなかった項目 (README 9章の既知の制約)。
      マクロの <MYRIG>/<MYPWR> と ADIF の MY_RIG/TX_PWR の双方で必要になる。 }
    FMyRig: string;       // リグ                (ADIF: MY_RIG)
    FMyPowerW: Integer;   // 送信出力[W] 0=未設定 (ADIF: TX_PWR)
  public
    constructor Create;

    { 実行ファイルと同じディレクトリの既定ファイル名
      (station_info.json) の絶対パスを返す。 }
    class function DefaultFilePath: string;

    { AFileName で指定した JSON ファイルから読み込む。
      ファイルが存在しない場合は何もしない (全フィールド既定値=空文字)。
      不正な JSON の場合は EStationInfoError を送出する。 }
    procedure LoadFromFile(const AFileName: string);

    { AFileName で指定した JSON ファイルへ保存する
      (人間が読みやすいよう整形済み JSON で出力する)。 }
    procedure SaveToFile(const AFileName: string);

    { DefaultFilePath() に対する Load/Save の簡易ラッパー。
      ファイルが存在しない場合、LoadDefault は何もしない
      (初回起動時は全フィールド空文字のまま)。 }
    procedure LoadDefault;
    procedure SaveDefault;

    property MyCall: string read FMyCall write FMyCall;
    property OperCall: string read FOperCall write FOperCall;
    property MyName: string read FMyName write FMyName;
    property MyQth: string read FMyQth write FMyQth;
    property MyLocator: string read FMyLocator write FMyLocator;
    property MyAntenna: string read FMyAntenna write FMyAntenna;
    property MyRig: string read FMyRig write FMyRig;
    property MyPowerW: Integer read FMyPowerW write FMyPowerW;
  end;

  EStationInfoError = class(Exception);

implementation

const
  { fldigi の MYCALL/MYQTH/MYNAME/MYLOC/MYANTENNA/OPERCALL という
    INI キー名の役割を果たす JSON キー名。 }
  KEY_MY_CALL    = 'myCall';
  KEY_OPER_CALL  = 'operCall';
  KEY_MY_NAME    = 'myName';
  KEY_MY_QTH     = 'myQth';
  KEY_MY_LOCATOR = 'myLocator';
  KEY_MY_ANTENNA = 'myAntenna';
  KEY_MY_RIG     = 'myRig';
  KEY_MY_POWER_W = 'myPowerW';

  DEFAULT_FILE_NAME = 'station_info.json';

{ TStationInfo }

constructor TStationInfo.Create;
begin
  inherited Create;
  FMyCall := '';
  FOperCall := '';
  FMyName := '';
  FMyQth := '';
  FMyLocator := '';
  FMyAntenna := '';
  FMyRig := '';
  FMyPowerW := 0;
end;

class function TStationInfo.DefaultFilePath: string;
begin
  { ParamStr(0) = 実行ファイルのパス。ユーザー要望「実行ファイルと
    同じディレクトリ」に保存するため ExtractFilePath で
    ディレクトリ部分のみを取り出す。 }
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + DEFAULT_FILE_NAME;
end;

procedure TStationInfo.LoadFromFile(const AFileName: string);
var
  sl: TStringList;
  data: TJSONData;
  obj: TJSONObject;
begin
  if not FileExists(AFileName) then
    Exit; // 初回起動等、ファイルが無いのは正常系。既定値(空文字)のまま。

  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    try
      data := GetJSON(sl.Text);
    except
      on E: Exception do
        raise EStationInfoError.Create(
          'station_info.json の解析に失敗しました: ' + E.Message);
    end;
    try
      if not (data is TJSONObject) then
        raise EStationInfoError.Create(
          'station_info.json の内容が JSON オブジェクトではありません');
      obj := TJSONObject(data);
      FMyCall    := obj.Get(KEY_MY_CALL, '');
      FOperCall  := obj.Get(KEY_OPER_CALL, '');
      FMyName    := obj.Get(KEY_MY_NAME, '');
      FMyQth     := obj.Get(KEY_MY_QTH, '');
      FMyLocator := obj.Get(KEY_MY_LOCATOR, '');
      FMyAntenna := obj.Get(KEY_MY_ANTENNA, '');
      { 旧いファイルにはこの2項目が無いので、既定値で補う
        (キーが無いだけで読み込み全体を失敗させない)。 }
      FMyRig := obj.Get(KEY_MY_RIG, '');
      FMyPowerW := obj.Get(KEY_MY_POWER_W, 0);
    finally
      data.Free;
    end;
  finally
    sl.Free;
  end;
end;

procedure TStationInfo.SaveToFile(const AFileName: string);
var
  obj: TJSONObject;
begin
  obj := TJSONObject.Create;
  try
    obj.Add(KEY_MY_CALL, FMyCall);
    obj.Add(KEY_OPER_CALL, FOperCall);
    obj.Add(KEY_MY_NAME, FMyName);
    obj.Add(KEY_MY_QTH, FMyQth);
    obj.Add(KEY_MY_LOCATOR, FMyLocator);
    obj.Add(KEY_MY_ANTENNA, FMyAntenna);
    obj.Add(KEY_MY_RIG, FMyRig);
    obj.Add(KEY_MY_POWER_W, FMyPowerW);

    { 一時ファイル + rename による原子的保存 (SafeFileIO 参照)。
      書き込み途中で電源が落ちても局情報が消えない。 }
    SaveTextAtomic(AFileName, obj.FormatJSON);
  finally
    obj.Free;
  end;
end;

procedure TStationInfo.LoadDefault;
begin
  LoadFromFile(DefaultFilePath);
end;

procedure TStationInfo.SaveDefault;
begin
  SaveToFile(DefaultFilePath);
end;

initialization
  { --- 日本語を含む設定値を JSON 往復で壊さないための必須設定 ---
    FPC の `string` は AnsiString(CP_ACP) であり、Unix では CP_ACP の実体
    (DefaultSystemCodePage) が既定で 0 のままになる。この状態で fpjson が
    内部の UnicodeString から AnsiString へ変換すると、非 ASCII 文字が
    すべて '?' に潰れる。書き出しは正しい UTF-8 になるため、保存した
    ファイルを読み直した瞬間にだけ壊れるという分かりにくい壊れ方をする
    (MyQth := '東京都八王子市' が再読込で '???????' になる)。

    SetMultiByteConversionCodePage(CP_UTF8) で CP_ACP の実体を UTF-8 に
    固定すると変換が無損失になり、往復が保証される。ロケール環境変数に
    依存しないので LANG が未設定の環境でも安全。

    プロセス全体に効くグローバル設定だが冪等なので、JSON 永続化を行う
    各ユニット (本ユニット / QsoLogbook.pas / OpProfile.pas /
    AppConfig.pas) がそれぞれ宣言し、リンク順に依存せず単体でも
    正しく動くようにしている。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
