{ ============================================================================
  OpProfile.pas

  運用プロファイル: 「どの局として・誰が・どこから・何の設備で・どういう
  目的で運用するか」を 1 クリックで切り替えるための構成管理ユニット。

  fldigi との対応:
    fldigi (C++)                                  | Lazarus (Pascal)
    --------------------------------------------------+---------------------------
    progdefaults (configuration.h の ELEM_ マクロ)   | (該当なし。下記参照)
      878 個のフラットな設定項目を単一の
      fldigi_def.xml に保存する
    (運用プロファイルという概念は fldigi に存在しない)  | TOperatingProfile (本ユニット)
    progdefaults.myCall   (MYCALL)                   | TStationIdentity.Callsign
    progdefaults.operCall (OPERCALL)                 | TOperatorInfo.Callsign
    progdefaults.myQth    (MYQTH)                    | TOperatingSite.City
    progdefaults.myLocator(MYLOC)                    | TOperatingSite.GridSquare
    progdefaults.myAntenna(MYANTENNA)                | TEquipmentSet.Antenna
    (該当なし)                                        | TEquipmentSet.Rig / PowerW
    StationInfo.pas の TStationInfo                   | TResolvedStation
      (本ユニットが解決した実効値の受け皿として利用)

  なぜ fldigi の設定構造をそのまま踏襲しないのか:
  ----------------------------------------------------------------------------
  fldigi の設定は `progdefaults` という単一構造体に 878 個の項目
  (src/include/configuration.h の `ELEM_()` を実測) がフラットに並び、
  すべてが 1 個の fldigi_def.xml に保存される。運用形態を切り替える
  概念は存在しないため、自宅運用と移動運用を行き来するたびに
  コールサイン・QTH・グリッドロケータ・空中線電力・アンテナを
  手作業で書き換える必要がある。本移植版は「翻訳ではなく新規開発」の
  方針であり、設定層はまだ StationInfo.pas (6 項目) しか無い段階なので、
  ここで構造から作り直す。

  ユースケースの MECE 分解:
  ----------------------------------------------------------------------------
  運用時に変わりうるものを「何を答える情報か」で分類すると、互いに
  重複せず (Mutually Exclusive)、かつ実運用のケースを網羅する
  (Collectively Exhaustive) 6 つの軸に分かれる。

    (1) 局     Station   : 誰の免許で電波を出しているか
    (2) 運用者 Operator  : 実際に操作しているのは誰か
    (3) 運用地 Site      : どこから出ているか
    (4) 設備   Equipment : どのリグ・アンテナ・電力で出ているか
    (5) 接続   Interface : その設備が「この PC」のどこに繋がっているか
    (6) 形態   Context   : 何のための運用か (通常/コンテスト/記念局…)

  代表的なユースケースがこの 6 軸でどう表現されるか:

    | ユースケース                       | 変わる軸                    |
    |------------------------------------|-----------------------------|
    | 個人局と社団局を使い分ける         | (1)局                       |
    | 同一人が複数コールサインを持つ     | (1)局                       |
    | 記念局・特別局として運用する       | (1)局 + (6)形態             |
    | 常置場所以外へ移動運用する         | (3)運用地 (+ (1)局のポータブル指定) |
    | POTA/SOTA/IOTA として運用する      | (3)運用地 + (6)形態         |
    | リグ/アンテナの組み合わせを変える  | (4)設備                     |
    | QRP 運用に切り替える               | (4)設備                     |
    | クラブ局を複数人が同時に運用する   | (1)局は共通 / (2)運用者と(5)接続が個別 |
    | シャック PC と移動用ノートを使い分け | (5)接続のみ                |
    | 同じ設備を別 PC へ繋ぎ替える       | (5)接続のみ                 |
    | リモート運用する                   | (3)運用地(局の所在地) + (5)接続 |
    | コンテストに参加する               | (6)形態 (+ ログ分割)        |
    | 衛星通信を行う                     | (4)設備 + (6)形態           |

  この分解の要は「クラブ局を複数人が同時に運用する」ケースである。
  これは局 (STATION_CALLSIGN) が共通のまま運用者 (OPERATOR) だけが
  異なることを要求するので、局と運用者が独立した軸であることの証明に
  なっている。ADIF が STATION_CALLSIGN と OPERATOR を別フィールドとして
  定義しているのと同じ構造であり、本ユニットもそれに従う。

  設計方針:
  ----------------------------------------------------------------------------
  1. **軸ごとのマスタ + 組み合わせとしてのプロファイル**: 各軸の実体
     (TStationIdentity / TOperatorInfo / TOperatingSite / TEquipmentSet) を
     独立したマスタとして登録し、TOperatingProfile は「各軸から 1 つずつ
     選んだ参照の束」として持つ。こうすると 3 コール × 4 運用地 × 5 設備 =
     60 通りのプロファイルを個別に作る組み合わせ爆発を避けられ、
     リグを買い替えたときも設備マスタを 1 つ直すだけで全プロファイルに
     反映される。

  2. **参照は Name (軸内で一意) で行う**: GUID ではなく人間が読める名前を
     キーにする。プロファイル JSON はユーザーが直接編集することを
     想定しており (StationInfo.pas と同じく実行ファイルと同じ
     ディレクトリに置く方針)、GUID だと手編集が困難になるため。
     名前の変更時は TProfileRegistry が参照側も追従して書き換える。

  3. **接続軸 (5) だけは本ユニットに含めない**: リグのモデル名や
     ボーレートは「設備」の属性だが、`COM3` / `/dev/ttyUSB0` という
     ポート名は同じ設備でも PC ごとに変わる。本アプリは実行ファイルと
     同じディレクトリに設定を置く = USB メモリごと持ち運ぶ運用を
     想定しているため、可搬な情報 (軸 1〜4,6) と PC 固有の情報 (軸 5) を
     別ファイルに分離する。軸 5 は AppConfig.pas が machine_config.json
     として管理する。

  4. **軸の「掛け算」は解決時に行う**: 移動運用時のコールサインは
     「局のコールサイン」×「運用地のポータブル指定」で決まる
     (例: JA1ABC + "/1" → "JA1ABC/1")。同様に実効空中線電力は
     「免許上の上限」(局軸) と「設備の出力」(設備軸) の小さい方になる。
     こうした軸をまたぐ計算は各マスタには持たせず、
     TProfileRegistry.Resolve() が TResolvedStation を組み立てる際に
     一箇所で行う。

  5. **既存ユニットとの接続**: Resolve 結果は TResolvedStation.ToStationInfo
     で既存の TStationInfo (StationInfo.pas) へ書き出せる。これにより
     QsoLogbook / AdifUdpSender は一切変更せずにプロファイル機能の
     恩恵を受けられる。
  ============================================================================ }
unit OpProfile;

{$mode objfpc}{$H+}
{ TResolvedStation は「解決済みの実効値 + それを既存の TStationInfo へ
  書き出すメソッド」を 1 つの値として扱いたいため、レコードにメソッドを
  持たせる advancedrecords を使う (FPC 3.2.2 / Lazarus で標準サポート)。 }
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, Generics.Collections, StationInfo;

type
  { 運用形態 (軸 6)。
    ログの分割単位やマクロセットの選択、コンテスト定義との連動に使う。 }
  TOperatingContextKind = (
    ockNormal,       // 通常運用 (ラバースタンプQSO等)
    ockContest,      // コンテスト運用
    ockSpecialEvent, // 記念局・特別局運用
    ockDxpedition,   // DXペディション
    ockSatellite,    // 衛星通信
    ockEmergency     // 非常通信・訓練
  );

  { すべての軸マスタに共通する基底。Name が軸内で一意な識別子を兼ねる
    (本ファイル冒頭コメント「設計方針 2」参照)。 }
  TProfileEntity = class
  private
    FName: string;
    FNote: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName write FName;
    property Note: string read FNote write FNote; // 自由記入のメモ
  end;

  { TStationIdentity (軸 1: 局)
    ---------------------------------------------------------------------
    「誰の免許で電波を出しているか」。個人局・社団局・記念局を区別する。
    ADIF: STATION_CALLSIGN / OWNER_CALLSIGN }
  TStationIdentity = class(TProfileEntity)
  private
    FCallsign: string;
    FOwnerCallsign: string;
    FIsClubStation: Boolean;
    FMaxPowerW: Integer;
    FLicenseNote: string;
  public
    { 局のコールサイン (ADIF: STATION_CALLSIGN)。
      移動運用時のポータブル指定は含めない (解決時に付与する)。 }
    property Callsign: string read FCallsign write FCallsign;
    { 社団局の場合の免許人 (ADIF: OWNER_CALLSIGN)。個人局では空。 }
    property OwnerCallsign: string read FOwnerCallsign write FOwnerCallsign;
    { 社団局 (クラブ局) かどうか。True の場合、運用者 (軸 2) は
      局のコールサインとは別人になるのが通常。 }
    property IsClubStation: Boolean read FIsClubStation write FIsClubStation;
    { 免許上の空中線電力の上限 (W)。0 = 未設定 (制限なしとして扱う)。
      設備側の出力がこれを超える場合、Resolve() が上限側へ丸める。 }
    property MaxPowerW: Integer read FMaxPowerW write FMaxPowerW;
    property LicenseNote: string read FLicenseNote write FLicenseNote;
  end;

  { TOperatorInfo (軸 2: 運用者)
    ---------------------------------------------------------------------
    「実際に操作しているのは誰か」。クラブ局では局と別人になる。
    ADIF: OPERATOR }
  TOperatorInfo = class(TProfileEntity)
  private
    FCallsign: string;
    FOperatorName: string;
  public
    { 運用者個人のコールサイン (ADIF: OPERATOR)。 }
    property Callsign: string read FCallsign write FCallsign;
    { 運用者名 (交信中に名乗る名前。fldigi: progdefaults.myName)。 }
    property OperatorName: string read FOperatorName write FOperatorName;
  end;

  { TOperatingSite (軸 3: 運用地)
    ---------------------------------------------------------------------
    「どこから出ているか」。常置場所と移動地を同じ型で表現する。
    ADIF: MY_GRIDSQUARE / MY_CITY / MY_CNTY / MY_SOTA_REF / MY_POTA_REF … }
  TOperatingSite = class(TProfileEntity)
  private
    FIsFixed: Boolean;
    FPortableDesignator: string;
    FCity: string;
    FGridSquare: string;
    FJccJcgCode: string;
    FSotaRef: string;
    FPotaRef: string;
    FIotaRef: string;
    FCqZone: Integer;
    FItuZone: Integer;
  public
    { 常置場所かどうか。False = 移動地。 }
    property IsFixed: Boolean read FIsFixed write FIsFixed;
    { 移動運用時にコールサインへ付ける指定 (例: '/1', '/P', '/M')。
      常置場所では空文字。Resolve() が局のコールサインへ連結する。 }
    property PortableDesignator: string read FPortableDesignator write FPortableDesignator;
    property City: string read FCity write FCity;                   // ADIF: MY_CITY
    property GridSquare: string read FGridSquare write FGridSquare; // ADIF: MY_GRIDSQUARE
    { 日本の市郡ナンバー (JCC/JCG)。国内交信の定番交換内容だが
      fldigi には対応する概念が無い (counties.cxx は米国の郡のみ)。 }
    property JccJcgCode: string read FJccJcgCode write FJccJcgCode;
    property SotaRef: string read FSotaRef write FSotaRef;      // ADIF: MY_SOTA_REF
    property PotaRef: string read FPotaRef write FPotaRef;      // ADIF: MY_POTA_REF
    property IotaRef: string read FIotaRef write FIotaRef;      // ADIF: MY_IOTA
    property CqZone: Integer read FCqZone write FCqZone;        // ADIF: MY_CQ_ZONE
    property ItuZone: Integer read FItuZone write FItuZone;     // ADIF: MY_ITU_ZONE
  end;

  { TEquipmentSet (軸 4: 設備)
    ---------------------------------------------------------------------
    「どのリグ・アンテナ・電力で出ているか」。
    ADIF: MY_RIG / MY_ANTENNA / TX_PWR
    リグのモデル名までを保持し、「そのリグがこの PC のどのポートに
    繋がっているか」は保持しない (本ファイル冒頭「設計方針 3」参照)。 }
  TEquipmentSet = class(TProfileEntity)
  private
    FRig: string;
    FAntenna: string;
    FPowerW: Integer;
    FRigModelName: string;
  public
    property Rig: string read FRig write FRig;             // ADIF: MY_RIG
    property Antenna: string read FAntenna write FAntenna; // ADIF: MY_ANTENNA
    { 設備としての送信出力 (W)。局の免許上限を超える場合は
      Resolve() が上限側へ丸める。 }
    property PowerW: Integer read FPowerW write FPowerW;   // ADIF: TX_PWR
    { Hamlib のリグモデル名 (THamlibRigControl.FindRigModelByName へ渡す
      想定)。ポート名やボーレートは PC 固有なので AppConfig 側で持つ。 }
    property RigModelName: string read FRigModelName write FRigModelName;
  end;

  { TResolvedStation
    ---------------------------------------------------------------------
    プロファイルを解決した結果の「実効的な運用情報」。
    軸をまたぐ計算 (コールサインへのポータブル指定付与、免許上限による
    電力の丸め) を済ませた状態であり、そのままログや ADIF 出力に使える。 }
  TResolvedStation = record
    StationCallsign: string;  // ADIF: STATION_CALLSIGN (ポータブル指定込み)
    OwnerCallsign: string;    // ADIF: OWNER_CALLSIGN
    OperatorCallsign: string; // ADIF: OPERATOR
    OperatorName: string;
    City: string;             // ADIF: MY_CITY
    GridSquare: string;       // ADIF: MY_GRIDSQUARE
    JccJcgCode: string;
    SotaRef: string;
    PotaRef: string;
    IotaRef: string;
    CqZone: Integer;
    ItuZone: Integer;
    Rig: string;              // ADIF: MY_RIG
    Antenna: string;          // ADIF: MY_ANTENNA
    PowerW: Integer;          // ADIF: TX_PWR (免許上限で丸め済み)
    PowerWasLimited: Boolean; // 免許上限によって丸められたか
    Context: TOperatingContextKind;
    ContestName: string;

    { 既存の TStationInfo (StationInfo.pas) へ実効値を書き出す。
      これにより QsoLogbook / AdifUdpSender を変更せずに
      プロファイル機能を利用できる。 }
    procedure ToStationInfo(AStationInfo: TStationInfo);
  end;

  { TOperatingProfile
    ---------------------------------------------------------------------
    各軸から 1 つずつ選んだ「組み合わせ」。軸の実体そのものは持たず、
    Name による参照だけを持つ (本ファイル冒頭「設計方針 1」参照)。 }
  TOperatingProfile = class(TProfileEntity)
  private
    FStationName: string;
    FOperatorRef: string;
    FSiteName: string;
    FEquipmentName: string;
    FContext: TOperatingContextKind;
    FContestName: string;
    FLogFileName: string;
  public
    constructor Create(const AName: string);
    property StationName: string read FStationName write FStationName;
    property OperatorRef: string read FOperatorRef write FOperatorRef;
    property SiteName: string read FSiteName write FSiteName;
    property EquipmentName: string read FEquipmentName write FEquipmentName;
    property Context: TOperatingContextKind read FContext write FContext;
    { ockContest のとき、ContestLog.pas の TContestRegistry.FindByName へ
      渡すコンテスト名。プロファイル選択だけでコンテスト定義まで
      切り替えられるようにするための連携点。 }
    property ContestName: string read FContestName write FContestName;
    { このプロファイルで記録するログのファイル名。空なら既定ログ。
      クラブ局の局別ログやコンテスト別ログの分割に使う。 }
    property LogFileName: string read FLogFileName write FLogFileName;
  end;

  { プロファイルの整合性検証結果 (1 件分)。 }
  TProfileIssue = record
    ProfileName: string;
    Axis: string;      // 'station' / 'operator' / 'site' / 'equipment' / 'context'
    Message: string;
  end;
  TProfileIssues = array of TProfileIssue;

  EOpProfileError = class(Exception);

  { TProfileRegistry
    ---------------------------------------------------------------------
    6 軸のうち可搬な 4 軸 (局/運用者/運用地/設備) のマスタと、
    プロファイル一覧を保持し、JSON へ永続化する。
    接続軸は AppConfig.pas (machine_config.json) が持つ。 }
  TProfileRegistry = class
  private
    FStations: specialize TObjectList<TStationIdentity>;
    FOperators: specialize TObjectList<TOperatorInfo>;
    FSites: specialize TObjectList<TOperatingSite>;
    FEquipment: specialize TObjectList<TEquipmentSet>;
    FProfiles: specialize TObjectList<TOperatingProfile>;
    procedure LoadStations(AArr: TJSONArray);
    procedure LoadOperators(AArr: TJSONArray);
    procedure LoadSites(AArr: TJSONArray);
    procedure LoadEquipment(AArr: TJSONArray);
    procedure LoadProfiles(AArr: TJSONArray);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;

    { --- 軸マスタの追加 (同名が既にあれば既存のものを返す) --- }
    function AddStation(const AName: string): TStationIdentity;
    function AddOperator(const AName: string): TOperatorInfo;
    function AddSite(const AName: string): TOperatingSite;
    function AddEquipment(const AName: string): TEquipmentSet;
    function AddProfile(const AName: string): TOperatingProfile;

    { --- 名前による検索 (見つからなければ nil) --- }
    function FindStation(const AName: string): TStationIdentity;
    function FindOperator(const AName: string): TOperatorInfo;
    function FindSite(const AName: string): TOperatingSite;
    function FindEquipment(const AName: string): TEquipmentSet;
    function FindProfile(const AName: string): TOperatingProfile;

    function StationCount: Integer;
    function OperatorCount: Integer;
    function SiteCount: Integer;
    function EquipmentCount: Integer;
    function ProfileCount: Integer;
    function Station(AIndex: Integer): TStationIdentity;
    function OperatorAt(AIndex: Integer): TOperatorInfo;
    function Site(AIndex: Integer): TOperatingSite;
    function Equipment(AIndex: Integer): TEquipmentSet;
    function Profile(AIndex: Integer): TOperatingProfile;

    { 軸マスタの改名。参照しているプロファイル側も追従して書き換える
      (本ファイル冒頭「設計方針 2」参照)。 }
    function RenameStation(const AOldName, ANewName: string): Boolean;
    function RenameOperator(const AOldName, ANewName: string): Boolean;
    function RenameSite(const AOldName, ANewName: string): Boolean;
    function RenameEquipment(const AOldName, ANewName: string): Boolean;

    { プロファイルを解決して実効的な運用情報を組み立てる。
      軸をまたぐ計算 (ポータブル指定の付与・免許上限による電力の丸め)
      はここで行う (本ファイル冒頭「設計方針 4」参照)。
      参照先が見つからない軸は空値のまま埋められる (検証は Validate で行う)。 }
    function Resolve(AProfile: TOperatingProfile): TResolvedStation;
    function ResolveByName(const AProfileName: string): TResolvedStation;

    { 全プロファイルの参照整合性・必須項目を検査する。
      戻り値が空配列なら問題なし。 }
    function Validate: TProfileIssues;

    { --- 永続化 (実行ファイルと同じディレクトリの op_profiles.json) --- }
    class function DefaultFilePath: string;
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    procedure LoadDefault;
    procedure SaveDefault;
  end;

{ 運用形態 <-> JSON 文字列の相互変換 }
function ContextKindToStr(AKind: TOperatingContextKind): string;
function StrToContextKind(const AStr: string): TOperatingContextKind;

implementation

const
  DEFAULT_FILE_NAME = 'op_profiles.json';
  SCHEMA_VERSION = 1;

  KEY_SCHEMA     = 'schemaVersion';
  KEY_STATIONS   = 'stations';
  KEY_OPERATORS  = 'operators';
  KEY_SITES      = 'sites';
  KEY_EQUIPMENT  = 'equipment';
  KEY_PROFILES   = 'profiles';

  KEY_NAME       = 'name';
  KEY_NOTE       = 'note';

function ContextKindToStr(AKind: TOperatingContextKind): string;
begin
  case AKind of
    ockContest:      Result := 'contest';
    ockSpecialEvent: Result := 'specialEvent';
    ockDxpedition:   Result := 'dxpedition';
    ockSatellite:    Result := 'satellite';
    ockEmergency:    Result := 'emergency';
  else
    Result := 'normal';
  end;
end;

function StrToContextKind(const AStr: string): TOperatingContextKind;
var
  s: string;
begin
  s := LowerCase(Trim(AStr));
  if s = 'contest' then Result := ockContest
  else if s = 'specialevent' then Result := ockSpecialEvent
  else if s = 'dxpedition' then Result := ockDxpedition
  else if s = 'satellite' then Result := ockSatellite
  else if s = 'emergency' then Result := ockEmergency
  else Result := ockNormal;
end;

{ ============================================================================
  TProfileEntity
  ============================================================================ }

constructor TProfileEntity.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FNote := '';
end;

{ ============================================================================
  TResolvedStation
  ============================================================================ }

procedure TResolvedStation.ToStationInfo(AStationInfo: TStationInfo);
begin
  if not Assigned(AStationInfo) then Exit;
  AStationInfo.MyCall    := StationCallsign;
  AStationInfo.OperCall  := OperatorCallsign;
  AStationInfo.MyName    := OperatorName;
  AStationInfo.MyQth     := City;
  AStationInfo.MyLocator := GridSquare;
  AStationInfo.MyAntenna := Antenna;
end;

{ ============================================================================
  TOperatingProfile
  ============================================================================ }

constructor TOperatingProfile.Create(const AName: string);
begin
  inherited Create(AName);
  FContext := ockNormal;
end;

{ ============================================================================
  TProfileRegistry
  ============================================================================ }

constructor TProfileRegistry.Create;
begin
  inherited Create;
  FStations  := specialize TObjectList<TStationIdentity>.Create(True);
  FOperators := specialize TObjectList<TOperatorInfo>.Create(True);
  FSites     := specialize TObjectList<TOperatingSite>.Create(True);
  FEquipment := specialize TObjectList<TEquipmentSet>.Create(True);
  FProfiles  := specialize TObjectList<TOperatingProfile>.Create(True);
end;

destructor TProfileRegistry.Destroy;
begin
  FProfiles.Free;
  FEquipment.Free;
  FSites.Free;
  FOperators.Free;
  FStations.Free;
  inherited Destroy;
end;

procedure TProfileRegistry.Clear;
begin
  FProfiles.Clear;
  FEquipment.Clear;
  FSites.Clear;
  FOperators.Clear;
  FStations.Clear;
end;

function TProfileRegistry.AddStation(const AName: string): TStationIdentity;
begin
  Result := FindStation(AName);
  if Assigned(Result) then Exit;
  Result := TStationIdentity.Create(AName);
  FStations.Add(Result);
end;

function TProfileRegistry.AddOperator(const AName: string): TOperatorInfo;
begin
  Result := FindOperator(AName);
  if Assigned(Result) then Exit;
  Result := TOperatorInfo.Create(AName);
  FOperators.Add(Result);
end;

function TProfileRegistry.AddSite(const AName: string): TOperatingSite;
begin
  Result := FindSite(AName);
  if Assigned(Result) then Exit;
  Result := TOperatingSite.Create(AName);
  FSites.Add(Result);
end;

function TProfileRegistry.AddEquipment(const AName: string): TEquipmentSet;
begin
  Result := FindEquipment(AName);
  if Assigned(Result) then Exit;
  Result := TEquipmentSet.Create(AName);
  FEquipment.Add(Result);
end;

function TProfileRegistry.AddProfile(const AName: string): TOperatingProfile;
begin
  Result := FindProfile(AName);
  if Assigned(Result) then Exit;
  Result := TOperatingProfile.Create(AName);
  FProfiles.Add(Result);
end;

function TProfileRegistry.FindStation(const AName: string): TStationIdentity;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FStations.Count - 1 do
    if SameText(FStations[i].Name, AName) then Exit(FStations[i]);
end;

function TProfileRegistry.FindOperator(const AName: string): TOperatorInfo;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FOperators.Count - 1 do
    if SameText(FOperators[i].Name, AName) then Exit(FOperators[i]);
end;

function TProfileRegistry.FindSite(const AName: string): TOperatingSite;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FSites.Count - 1 do
    if SameText(FSites[i].Name, AName) then Exit(FSites[i]);
end;

function TProfileRegistry.FindEquipment(const AName: string): TEquipmentSet;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FEquipment.Count - 1 do
    if SameText(FEquipment[i].Name, AName) then Exit(FEquipment[i]);
end;

function TProfileRegistry.FindProfile(const AName: string): TOperatingProfile;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FProfiles.Count - 1 do
    if SameText(FProfiles[i].Name, AName) then Exit(FProfiles[i]);
end;

function TProfileRegistry.StationCount: Integer;   begin Result := FStations.Count;  end;
function TProfileRegistry.OperatorCount: Integer;  begin Result := FOperators.Count; end;
function TProfileRegistry.SiteCount: Integer;      begin Result := FSites.Count;     end;
function TProfileRegistry.EquipmentCount: Integer; begin Result := FEquipment.Count; end;
function TProfileRegistry.ProfileCount: Integer;   begin Result := FProfiles.Count;  end;

function TProfileRegistry.Station(AIndex: Integer): TStationIdentity;  begin Result := FStations[AIndex];  end;
function TProfileRegistry.OperatorAt(AIndex: Integer): TOperatorInfo;  begin Result := FOperators[AIndex]; end;
function TProfileRegistry.Site(AIndex: Integer): TOperatingSite;       begin Result := FSites[AIndex];     end;
function TProfileRegistry.Equipment(AIndex: Integer): TEquipmentSet;   begin Result := FEquipment[AIndex]; end;
function TProfileRegistry.Profile(AIndex: Integer): TOperatingProfile; begin Result := FProfiles[AIndex];  end;

function TProfileRegistry.RenameStation(const AOldName, ANewName: string): Boolean;
var
  ent: TStationIdentity;
  i: Integer;
begin
  ent := FindStation(AOldName);
  Result := Assigned(ent);
  if not Result then Exit;
  ent.Name := ANewName;
  for i := 0 to FProfiles.Count - 1 do
    if SameText(FProfiles[i].StationName, AOldName) then
      FProfiles[i].StationName := ANewName;
end;

function TProfileRegistry.RenameOperator(const AOldName, ANewName: string): Boolean;
var
  ent: TOperatorInfo;
  i: Integer;
begin
  ent := FindOperator(AOldName);
  Result := Assigned(ent);
  if not Result then Exit;
  ent.Name := ANewName;
  for i := 0 to FProfiles.Count - 1 do
    if SameText(FProfiles[i].OperatorRef, AOldName) then
      FProfiles[i].OperatorRef := ANewName;
end;

function TProfileRegistry.RenameSite(const AOldName, ANewName: string): Boolean;
var
  ent: TOperatingSite;
  i: Integer;
begin
  ent := FindSite(AOldName);
  Result := Assigned(ent);
  if not Result then Exit;
  ent.Name := ANewName;
  for i := 0 to FProfiles.Count - 1 do
    if SameText(FProfiles[i].SiteName, AOldName) then
      FProfiles[i].SiteName := ANewName;
end;

function TProfileRegistry.RenameEquipment(const AOldName, ANewName: string): Boolean;
var
  ent: TEquipmentSet;
  i: Integer;
begin
  ent := FindEquipment(AOldName);
  Result := Assigned(ent);
  if not Result then Exit;
  ent.Name := ANewName;
  for i := 0 to FProfiles.Count - 1 do
    if SameText(FProfiles[i].EquipmentName, AOldName) then
      FProfiles[i].EquipmentName := ANewName;
end;

function TProfileRegistry.Resolve(AProfile: TOperatingProfile): TResolvedStation;
{ 軸をまたぐ計算を一箇所で行う (本ファイル冒頭「設計方針 4」参照)。 }
var
  sta: TStationIdentity;
  op: TOperatorInfo;
  loc: TOperatingSite;
  eq: TEquipmentSet;
begin
  { TResolvedStation は string フィールドを含む (= 管理型) ため、
    FillChar による一括ゼロ埋めは参照カウントを壊す。全フィールドを
    明示的に初期化する。 }
  Result.StationCallsign := '';
  Result.OwnerCallsign := '';
  Result.OperatorCallsign := '';
  Result.OperatorName := '';
  Result.City := '';
  Result.GridSquare := '';
  Result.JccJcgCode := '';
  Result.SotaRef := '';
  Result.PotaRef := '';
  Result.IotaRef := '';
  Result.Rig := '';
  Result.Antenna := '';
  Result.ContestName := '';
  Result.Context := ockNormal;
  Result.CqZone := 0;
  Result.ItuZone := 0;
  Result.PowerW := 0;
  Result.PowerWasLimited := False;
  if not Assigned(AProfile) then Exit;

  sta := FindStation(AProfile.StationName);
  op  := FindOperator(AProfile.OperatorRef);
  loc := FindSite(AProfile.SiteName);
  eq  := FindEquipment(AProfile.EquipmentName);

  Result.Context := AProfile.Context;
  Result.ContestName := AProfile.ContestName;

  if Assigned(sta) then
  begin
    Result.StationCallsign := sta.Callsign;
    Result.OwnerCallsign := sta.OwnerCallsign;
  end;

  if Assigned(op) then
  begin
    Result.OperatorCallsign := op.Callsign;
    Result.OperatorName := op.OperatorName;
  end;

  if Assigned(loc) then
  begin
    Result.City := loc.City;
    Result.GridSquare := loc.GridSquare;
    Result.JccJcgCode := loc.JccJcgCode;
    Result.SotaRef := loc.SotaRef;
    Result.PotaRef := loc.PotaRef;
    Result.IotaRef := loc.IotaRef;
    Result.CqZone := loc.CqZone;
    Result.ItuZone := loc.ItuZone;

    { 軸の掛け算 (1): 局のコールサイン × 運用地のポータブル指定。
      移動運用では JA1ABC + '/1' → 'JA1ABC/1' となる。 }
    if (Result.StationCallsign <> '') and (Trim(loc.PortableDesignator) <> '') then
      Result.StationCallsign := Result.StationCallsign + Trim(loc.PortableDesignator);
  end;

  if Assigned(eq) then
  begin
    Result.Rig := eq.Rig;
    Result.Antenna := eq.Antenna;
    Result.PowerW := eq.PowerW;
  end;

  { 軸の掛け算 (2): 実効空中線電力 = min(免許上限, 設備出力)。
    免許を超える設定のまま運用してしまう事故を防ぐ。 }
  if Assigned(sta) and (sta.MaxPowerW > 0) and (Result.PowerW > sta.MaxPowerW) then
  begin
    Result.PowerW := sta.MaxPowerW;
    Result.PowerWasLimited := True;
  end;
end;

function TProfileRegistry.ResolveByName(const AProfileName: string): TResolvedStation;
begin
  Result := Resolve(FindProfile(AProfileName));
end;

function TProfileRegistry.Validate: TProfileIssues;
var
  issues: TProfileIssues;

  procedure AddIssue(const AProfileName, AAxis, AMessage: string);
  begin
    SetLength(issues, Length(issues) + 1);
    issues[High(issues)].ProfileName := AProfileName;
    issues[High(issues)].Axis := AAxis;
    issues[High(issues)].Message := AMessage;
  end;

var
  i: Integer;
  p: TOperatingProfile;
  sta: TStationIdentity;
  op: TOperatorInfo;
begin
  SetLength(issues, 0);
  for i := 0 to FProfiles.Count - 1 do
  begin
    p := FProfiles[i];

    sta := FindStation(p.StationName);
    if not Assigned(sta) then
      AddIssue(p.Name, 'station', Format('局 "%s" が登録されていません', [p.StationName]))
    else if Trim(sta.Callsign) = '' then
      AddIssue(p.Name, 'station', Format('局 "%s" のコールサインが未設定です', [sta.Name]));

    op := FindOperator(p.OperatorRef);
    if not Assigned(op) then
      AddIssue(p.Name, 'operator', Format('運用者 "%s" が登録されていません', [p.OperatorRef]));

    if not Assigned(FindSite(p.SiteName)) then
      AddIssue(p.Name, 'site', Format('運用地 "%s" が登録されていません', [p.SiteName]));

    if not Assigned(FindEquipment(p.EquipmentName)) then
      AddIssue(p.Name, 'equipment', Format('設備 "%s" が登録されていません', [p.EquipmentName]));

    { 社団局なのに運用者コールサインが空というのは通常あり得ない
      (誰が運用したかがログに残らない)。 }
    if Assigned(sta) and sta.IsClubStation and Assigned(op) then
      if Trim(op.Callsign) = '' then
        AddIssue(p.Name, 'operator',
          Format('社団局 "%s" の運用では運用者コールサインが必要です', [sta.Name]));

    if (p.Context = ockContest) and (Trim(p.ContestName) = '') then
      AddIssue(p.Name, 'context', 'コンテスト運用ですがコンテスト名が未設定です');
  end;
  Result := issues;
end;

{ ============================================================================
  永続化
  ============================================================================ }

class function TProfileRegistry.DefaultFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + DEFAULT_FILE_NAME;
end;

procedure TProfileRegistry.LoadStations(AArr: TJSONArray);
var
  i: Integer;
  o: TJSONObject;
  e: TStationIdentity;
begin
  for i := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[i] is TJSONObject) then Continue;
    o := TJSONObject(AArr.Items[i]);
    e := AddStation(o.Get(KEY_NAME, ''));
    e.Note          := o.Get(KEY_NOTE, '');
    e.Callsign      := o.Get('callsign', '');
    e.OwnerCallsign := o.Get('ownerCallsign', '');
    e.IsClubStation := o.Get('isClubStation', False);
    e.MaxPowerW     := o.Get('maxPowerW', 0);
    e.LicenseNote   := o.Get('licenseNote', '');
  end;
end;

procedure TProfileRegistry.LoadOperators(AArr: TJSONArray);
var
  i: Integer;
  o: TJSONObject;
  e: TOperatorInfo;
begin
  for i := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[i] is TJSONObject) then Continue;
    o := TJSONObject(AArr.Items[i]);
    e := AddOperator(o.Get(KEY_NAME, ''));
    e.Note         := o.Get(KEY_NOTE, '');
    e.Callsign     := o.Get('callsign', '');
    e.OperatorName := o.Get('operatorName', '');
  end;
end;

procedure TProfileRegistry.LoadSites(AArr: TJSONArray);
var
  i: Integer;
  o: TJSONObject;
  e: TOperatingSite;
begin
  for i := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[i] is TJSONObject) then Continue;
    o := TJSONObject(AArr.Items[i]);
    e := AddSite(o.Get(KEY_NAME, ''));
    e.Note               := o.Get(KEY_NOTE, '');
    e.IsFixed            := o.Get('isFixed', False);
    e.PortableDesignator := o.Get('portableDesignator', '');
    e.City               := o.Get('city', '');
    e.GridSquare         := o.Get('gridSquare', '');
    e.JccJcgCode         := o.Get('jccJcgCode', '');
    e.SotaRef            := o.Get('sotaRef', '');
    e.PotaRef            := o.Get('potaRef', '');
    e.IotaRef            := o.Get('iotaRef', '');
    e.CqZone             := o.Get('cqZone', 0);
    e.ItuZone            := o.Get('ituZone', 0);
  end;
end;

procedure TProfileRegistry.LoadEquipment(AArr: TJSONArray);
var
  i: Integer;
  o: TJSONObject;
  e: TEquipmentSet;
begin
  for i := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[i] is TJSONObject) then Continue;
    o := TJSONObject(AArr.Items[i]);
    e := AddEquipment(o.Get(KEY_NAME, ''));
    e.Note         := o.Get(KEY_NOTE, '');
    e.Rig          := o.Get('rig', '');
    e.Antenna      := o.Get('antenna', '');
    e.PowerW       := o.Get('powerW', 0);
    e.RigModelName := o.Get('rigModelName', '');
  end;
end;

procedure TProfileRegistry.LoadProfiles(AArr: TJSONArray);
var
  i: Integer;
  o: TJSONObject;
  e: TOperatingProfile;
begin
  for i := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[i] is TJSONObject) then Continue;
    o := TJSONObject(AArr.Items[i]);
    e := AddProfile(o.Get(KEY_NAME, ''));
    e.Note          := o.Get(KEY_NOTE, '');
    e.StationName   := o.Get('station', '');
    e.OperatorRef   := o.Get('operator', '');
    e.SiteName      := o.Get('site', '');
    e.EquipmentName := o.Get('equipment', '');
    e.Context       := StrToContextKind(o.Get('context', 'normal'));
    e.ContestName   := o.Get('contestName', '');
    e.LogFileName   := o.Get('logFileName', '');
  end;
end;

procedure TProfileRegistry.LoadFromFile(const AFileName: string);
var
  sl: TStringList;
  data: TJSONData;
  root: TJSONObject;

  function ArrOf(const AKey: string): TJSONArray;
  var
    d: TJSONData;
  begin
    Result := nil;
    d := root.Find(AKey);
    if (d <> nil) and (d is TJSONArray) then
      Result := TJSONArray(d);
  end;

var
  a: TJSONArray;
begin
  Clear;
  if not FileExists(AFileName) then
    Exit; // 初回起動時はファイルが無いのが正常系。

  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    try
      data := GetJSON(sl.Text);
    except
      on E: Exception do
        raise EOpProfileError.Create(
          DEFAULT_FILE_NAME + ' の解析に失敗しました: ' + E.Message);
    end;
    try
      if not (data is TJSONObject) then
        raise EOpProfileError.Create(
          DEFAULT_FILE_NAME + ' の内容が JSON オブジェクトではありません');
      root := TJSONObject(data);

      a := ArrOf(KEY_STATIONS);  if a <> nil then LoadStations(a);
      a := ArrOf(KEY_OPERATORS); if a <> nil then LoadOperators(a);
      a := ArrOf(KEY_SITES);     if a <> nil then LoadSites(a);
      a := ArrOf(KEY_EQUIPMENT); if a <> nil then LoadEquipment(a);
      a := ArrOf(KEY_PROFILES);  if a <> nil then LoadProfiles(a);
    finally
      data.Free;
    end;
  finally
    sl.Free;
  end;
end;

procedure TProfileRegistry.SaveToFile(const AFileName: string);
var
  root: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  sl: TStringList;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add(KEY_SCHEMA, SCHEMA_VERSION);

    arr := TJSONArray.Create;
    for i := 0 to FStations.Count - 1 do
    begin
      o := TJSONObject.Create;
      o.Add(KEY_NAME, FStations[i].Name);
      o.Add('callsign', FStations[i].Callsign);
      o.Add('ownerCallsign', FStations[i].OwnerCallsign);
      o.Add('isClubStation', FStations[i].IsClubStation);
      o.Add('maxPowerW', FStations[i].MaxPowerW);
      o.Add('licenseNote', FStations[i].LicenseNote);
      o.Add(KEY_NOTE, FStations[i].Note);
      arr.Add(o);
    end;
    root.Add(KEY_STATIONS, arr);

    arr := TJSONArray.Create;
    for i := 0 to FOperators.Count - 1 do
    begin
      o := TJSONObject.Create;
      o.Add(KEY_NAME, FOperators[i].Name);
      o.Add('callsign', FOperators[i].Callsign);
      o.Add('operatorName', FOperators[i].OperatorName);
      o.Add(KEY_NOTE, FOperators[i].Note);
      arr.Add(o);
    end;
    root.Add(KEY_OPERATORS, arr);

    arr := TJSONArray.Create;
    for i := 0 to FSites.Count - 1 do
    begin
      o := TJSONObject.Create;
      o.Add(KEY_NAME, FSites[i].Name);
      o.Add('isFixed', FSites[i].IsFixed);
      o.Add('portableDesignator', FSites[i].PortableDesignator);
      o.Add('city', FSites[i].City);
      o.Add('gridSquare', FSites[i].GridSquare);
      o.Add('jccJcgCode', FSites[i].JccJcgCode);
      o.Add('sotaRef', FSites[i].SotaRef);
      o.Add('potaRef', FSites[i].PotaRef);
      o.Add('iotaRef', FSites[i].IotaRef);
      o.Add('cqZone', FSites[i].CqZone);
      o.Add('ituZone', FSites[i].ItuZone);
      o.Add(KEY_NOTE, FSites[i].Note);
      arr.Add(o);
    end;
    root.Add(KEY_SITES, arr);

    arr := TJSONArray.Create;
    for i := 0 to FEquipment.Count - 1 do
    begin
      o := TJSONObject.Create;
      o.Add(KEY_NAME, FEquipment[i].Name);
      o.Add('rig', FEquipment[i].Rig);
      o.Add('antenna', FEquipment[i].Antenna);
      o.Add('powerW', FEquipment[i].PowerW);
      o.Add('rigModelName', FEquipment[i].RigModelName);
      o.Add(KEY_NOTE, FEquipment[i].Note);
      arr.Add(o);
    end;
    root.Add(KEY_EQUIPMENT, arr);

    arr := TJSONArray.Create;
    for i := 0 to FProfiles.Count - 1 do
    begin
      o := TJSONObject.Create;
      o.Add(KEY_NAME, FProfiles[i].Name);
      o.Add('station', FProfiles[i].StationName);
      o.Add('operator', FProfiles[i].OperatorRef);
      o.Add('site', FProfiles[i].SiteName);
      o.Add('equipment', FProfiles[i].EquipmentName);
      o.Add('context', ContextKindToStr(FProfiles[i].Context));
      o.Add('contestName', FProfiles[i].ContestName);
      o.Add('logFileName', FProfiles[i].LogFileName);
      o.Add(KEY_NOTE, FProfiles[i].Note);
      arr.Add(o);
    end;
    root.Add(KEY_PROFILES, arr);

    sl := TStringList.Create;
    try
      sl.Text := root.FormatJSON;
      sl.SaveToFile(AFileName);
    finally
      sl.Free;
    end;
  finally
    root.Free;
  end;
end;

procedure TProfileRegistry.LoadDefault;
begin
  LoadFromFile(DefaultFilePath);
end;

procedure TProfileRegistry.SaveDefault;
begin
  SaveToFile(DefaultFilePath);
end;

initialization
  { 日本語を含む設定値 (局名「クラブ局」、運用地「高尾山移動」等) を
    JSON 往復で壊さないための必須設定。理由と詳細は StationInfo.pas の
    initialization のコメントを参照。プロセス全体に効く冪等な設定であり、
    JSON 永続化を行う各ユニットがリンク順に依存せず単体で正しく動くよう、
    ここでも宣言している。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
