{ ============================================================================
  AppConfig.pas

  運用プロファイルの 6 軸のうち「接続」軸 (軸 5) と、セッション状態
  (前回終了時の運用プロファイル・周波数・モード) を管理するユニット。
  OpProfile.pas が可搬な 4 軸 (局/運用者/運用地/設備) を扱うのに対し、
  本ユニットは PC ごとに異なる情報を扱う。

  fldigi との対応:
    fldigi (C++)                                  | Lazarus (Pascal)
    --------------------------------------------------+---------------------------
    progdefaults.HamRigDevice / HamRigBaudrate      | TInterfaceSetup.RigDevice / RigBaudRate
    progdefaults.HamRigName                          | TInterfaceSetup.RigModelName
    progdefaults.PTTdev / RTSptt / DTRptt            | TInterfaceSetup.PttDevice / PttMethod
    progdefaults.PortInDevice / PortOutDevice        | TInterfaceSetup.SoundInputDevice /
                                                          SoundOutputDevice
    (該当なし)                                        | TMachineConfig (本ユニット)
      fldigi は設定を単一の fldigi_def.xml に保存し、
      PC 固有の設定と可搬な設定を区別しない
    progStatus (status.cxx、前回終了時の状態)         | TSessionState (本ユニット)

  なぜ「接続」軸を OpProfile.pas から分離するのか:
  ----------------------------------------------------------------------------
  リグのモデル名 (例: FT-991A) は「設備」の属性なので OpProfile.pas の
  TEquipmentSet が持つ。しかし「そのリグがこの PC のどのポートに
  繋がっているか」(COM3 / /dev/ttyUSB0) や「どのサウンドデバイスを
  使うか」は、同じ設備でも PC ごとに変わる。

  本アプリは実行ファイルと同じディレクトリへ設定を保存する方針
  (= USB メモリにアプリごと入れて持ち運べる) を採っているため、
  可搬な情報と PC 固有の情報を同じ構造に混ぜると、別の PC に挿した
  瞬間にポート名が食い違って動かなくなる。

  設計方針:
  ----------------------------------------------------------------------------
  1. **マシン識別子でセクションを分ける**: PC 固有設定を別ファイルに
     するだけでは、そのファイル自体も USB メモリごと移動してしまい
     解決にならない。そこで machine_config.json の中を
     「マシン識別子 -> そのマシンの設定」という辞書構造にする。
     こうすると 1 個のファイルが USB メモリで複数 PC を渡り歩いても、
     各 PC は自分のセクションだけを読む。シャック PC と移動用ノートの
     使い分け、および同じ設備を別 PC へ繋ぎ替えるケースが
     設定を壊さずに両立する。

  2. **マシン識別子は自動検出 + 明示指定可能**: 環境変数
     (COMPUTERNAME / HOSTNAME) と /etc/hostname から自動検出するが、
     同名ホストの衝突や検出失敗に備えて MachineId は明示的に
     上書きできるようにする。検出できない場合は 'default' を使い、
     単一 PC 運用では何も設定しなくても動く。

  3. **プロファイルごとの接続の上書き**: 通常は 1 台の PC で 1 組の
     接続設定を使うが、同じ PC に 2 台のリグを繋いでいる場合は
     プロファイルごとに接続を変えたい。そこで
     「既定の接続 + プロファイル名ごとの上書き」という 2 段構えにする
     (OpProfile 側にはプロファイル -> 接続の参照を持たせない。
     持たせると可搬な op_profiles.json に PC 固有の情報が混入するため)。

  4. **セッション状態も PC 固有**: 「前回終了時の周波数」はその PC の
     リグに紐づくので、マシンごとのセクションに含める。起動時に
     前回の状態を復元して即運用開始できるようにするのが目的。
  ============================================================================ }
unit AppConfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, Generics.Collections;

type
  { PTT (送信制御) の方式。fldigi: progdefaults の RTSptt / DTRptt /
    HamlibPTT / TTYptt 等に相当。 }
  TPttMethod = (
    pttNone,      // PTT 制御なし (VOX 等)
    pttRigCat,    // CAT 経由 (Hamlib の rig_set_ptt)
    pttSerialRts, // シリアルポートの RTS
    pttSerialDtr  // シリアルポートの DTR
  );

  { TInterfaceSetup (軸 5: 接続)
    ---------------------------------------------------------------------
    「設備がこの PC のどこに繋がっているか」。PC 固有の情報のみを持ち、
    リグのモデル名のような設備の属性は OpProfile.TEquipmentSet が持つ。 }
  TInterfaceSetup = class
  private
    FName: string;
    FRigModelName: string;
    FRigDevice: string;
    FRigBaudRate: Integer;
    FPttMethod: TPttMethod;
    FPttDevice: string;
    FSoundInputDevice: string;
    FSoundOutputDevice: string;
    FSampleRate: Integer;
  public
    constructor Create(const AName: string);
    property Name: string read FName write FName;
    { Hamlib のリグモデル名。通常は TEquipmentSet.RigModelName を使うが、
      同じ設備を別の接続方式 (例: 直結 と flrig 経由) で使い分ける場合の
      上書き用。空なら設備側の指定を使う。 }
    property RigModelName: string read FRigModelName write FRigModelName;
    property RigDevice: string read FRigDevice write FRigDevice;   // 'COM3' / '/dev/ttyUSB0'
    property RigBaudRate: Integer read FRigBaudRate write FRigBaudRate;
    property PttMethod: TPttMethod read FPttMethod write FPttMethod;
    property PttDevice: string read FPttDevice write FPttDevice;
    property SoundInputDevice: string read FSoundInputDevice write FSoundInputDevice;
    property SoundOutputDevice: string read FSoundOutputDevice write FSoundOutputDevice;
    property SampleRate: Integer read FSampleRate write FSampleRate;
  end;

  { TSessionState
    ---------------------------------------------------------------------
    前回終了時の状態。起動時に復元して即運用開始できるようにする。
    fldigi: progStatus (status.cxx) に相当。 }
  TSessionState = record
    LastProfileName: string;
    LastFrequencyHz: Int64;
    LastModeName: string;
    LastBandName: string;
  end;

  { TMachineConfig
    ---------------------------------------------------------------------
    1 台の PC 分の設定。machine_config.json の中で
    マシン識別子をキーとして格納される。 }
  TMachineConfig = class
  private
    FMachineId: string;
    FInterfaces: specialize TObjectList<TInterfaceSetup>;
    FDefaultInterfaceName: string;
    FProfileBindings: specialize TDictionary<string, string>; // プロファイル名 -> 接続名
    FSession: TSessionState;
  public
    constructor Create(const AMachineId: string);
    destructor Destroy; override;

    function AddInterface(const AName: string): TInterfaceSetup;
    function FindInterface(const AName: string): TInterfaceSetup;
    function InterfaceCount: Integer;
    function InterfaceAt(AIndex: Integer): TInterfaceSetup;

    { プロファイル名に対して使う接続を指定する (設計方針 3)。 }
    procedure BindProfile(const AProfileName, AInterfaceName: string);
    procedure UnbindProfile(const AProfileName: string);

    { AProfileName に対して実際に使う接続を返す。
      プロファイル固有の割り当てがあればそれを、無ければ既定の接続を返す。
      どちらも無ければ nil。 }
    function ResolveInterface(const AProfileName: string): TInterfaceSetup;

    property MachineId: string read FMachineId write FMachineId;
    property DefaultInterfaceName: string read FDefaultInterfaceName write FDefaultInterfaceName;
    property Session: TSessionState read FSession write FSession;
  end;

  EAppConfigError = class(Exception);

  { TAppConfig
    ---------------------------------------------------------------------
    machine_config.json 全体。複数マシン分の TMachineConfig を保持し、
    現在のマシンのものを選び出す (設計方針 1)。 }
  TAppConfig = class
  private
    FMachines: specialize TObjectList<TMachineConfig>;
    FMachineId: string;
    procedure LoadMachine(const AMachineId: string; AObj: TJSONObject);
    function MachineToJson(AMachine: TMachineConfig): TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;

    { このアプリが動作しているマシンの識別子。既定では環境変数と
      /etc/hostname から自動検出する (設計方針 2)。 }
    property MachineId: string read FMachineId write FMachineId;

    { 現在のマシンの設定を返す。まだ無ければ作成する
      (初回起動時でも必ず有効なインスタンスが返る)。 }
    function CurrentMachine: TMachineConfig;

    function FindMachine(const AMachineId: string): TMachineConfig;
    function MachineCount: Integer;
    function MachineAt(AIndex: Integer): TMachineConfig;

    class function DefaultFilePath: string;
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    procedure LoadDefault;
    procedure SaveDefault;
  end;

{ 実行中の PC の識別子を推定する。
  COMPUTERNAME (Windows) -> HOSTNAME (一部の Unix シェル) ->
  /etc/hostname (Unix) の順に調べ、いずれも得られなければ 'default'。 }
function DetectMachineId: string;

function PttMethodToStr(AMethod: TPttMethod): string;
function StrToPttMethod(const AStr: string): TPttMethod;

implementation

const
  DEFAULT_FILE_NAME = 'machine_config.json';
  SCHEMA_VERSION = 1;

  KEY_SCHEMA    = 'schemaVersion';
  KEY_MACHINES  = 'machines';

function DetectMachineId: string;
{$IFDEF UNIX}
var
  sl: TStringList;
{$ENDIF}
begin
  Result := Trim(GetEnvironmentVariable('COMPUTERNAME')); // Windows
  if Result = '' then
    Result := Trim(GetEnvironmentVariable('HOSTNAME'));   // 一部の Unix シェル
  {$IFDEF UNIX}
  if (Result = '') and FileExists('/etc/hostname') then
  begin
    sl := TStringList.Create;
    try
      try
        sl.LoadFromFile('/etc/hostname');
        if sl.Count > 0 then
          Result := Trim(sl[0]);
      except
        { 読めなければ既定値へフォールバックする }
      end;
    finally
      sl.Free;
    end;
  end;
  {$ENDIF}
  if Result = '' then
    Result := 'default';
end;

function PttMethodToStr(AMethod: TPttMethod): string;
begin
  case AMethod of
    pttRigCat:    Result := 'rigcat';
    pttSerialRts: Result := 'rts';
    pttSerialDtr: Result := 'dtr';
  else
    Result := 'none';
  end;
end;

function StrToPttMethod(const AStr: string): TPttMethod;
var
  s: string;
begin
  s := LowerCase(Trim(AStr));
  if s = 'rigcat' then Result := pttRigCat
  else if s = 'rts' then Result := pttSerialRts
  else if s = 'dtr' then Result := pttSerialDtr
  else Result := pttNone;
end;

{ ============================================================================
  TInterfaceSetup
  ============================================================================ }

constructor TInterfaceSetup.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FRigBaudRate := 0;   // 0 = Hamlib の既定値に任せる
  FPttMethod := pttNone;
  FSampleRate := 0;    // 0 = モデム側の既定値に任せる
end;

{ ============================================================================
  TMachineConfig
  ============================================================================ }

constructor TMachineConfig.Create(const AMachineId: string);
begin
  inherited Create;
  FMachineId := AMachineId;
  FInterfaces := specialize TObjectList<TInterfaceSetup>.Create(True);
  FProfileBindings := specialize TDictionary<string, string>.Create;
  FSession.LastProfileName := '';
  FSession.LastFrequencyHz := 0;
  FSession.LastModeName := '';
  FSession.LastBandName := '';
end;

destructor TMachineConfig.Destroy;
begin
  FProfileBindings.Free;
  FInterfaces.Free;
  inherited Destroy;
end;

function TMachineConfig.AddInterface(const AName: string): TInterfaceSetup;
begin
  Result := FindInterface(AName);
  if Assigned(Result) then Exit;
  Result := TInterfaceSetup.Create(AName);
  FInterfaces.Add(Result);
  { 最初に登録された接続を既定にしておく (単一 PC 運用では
    これだけで設定が完了する)。 }
  if FDefaultInterfaceName = '' then
    FDefaultInterfaceName := AName;
end;

function TMachineConfig.FindInterface(const AName: string): TInterfaceSetup;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FInterfaces.Count - 1 do
    if SameText(FInterfaces[i].Name, AName) then Exit(FInterfaces[i]);
end;

function TMachineConfig.InterfaceCount: Integer;
begin
  Result := FInterfaces.Count;
end;

function TMachineConfig.InterfaceAt(AIndex: Integer): TInterfaceSetup;
begin
  Result := FInterfaces[AIndex];
end;

procedure TMachineConfig.BindProfile(const AProfileName, AInterfaceName: string);
begin
  FProfileBindings.AddOrSetValue(LowerCase(AProfileName), AInterfaceName);
end;

procedure TMachineConfig.UnbindProfile(const AProfileName: string);
begin
  FProfileBindings.Remove(LowerCase(AProfileName));
end;

function TMachineConfig.ResolveInterface(const AProfileName: string): TInterfaceSetup;
var
  ifName: string;
begin
  Result := nil;
  if FProfileBindings.TryGetValue(LowerCase(AProfileName), ifName) then
  begin
    Result := FindInterface(ifName);
    if Assigned(Result) then Exit;
    { 割り当て先の接続がこのマシンに存在しない (別 PC で設定された
      バインドが残っている等) 場合は既定へフォールバックする。 }
  end;
  if FDefaultInterfaceName <> '' then
    Result := FindInterface(FDefaultInterfaceName);
end;

{ ============================================================================
  TAppConfig
  ============================================================================ }

constructor TAppConfig.Create;
begin
  inherited Create;
  FMachines := specialize TObjectList<TMachineConfig>.Create(True);
  FMachineId := DetectMachineId;
end;

destructor TAppConfig.Destroy;
begin
  FMachines.Free;
  inherited Destroy;
end;

procedure TAppConfig.Clear;
begin
  FMachines.Clear;
end;

function TAppConfig.FindMachine(const AMachineId: string): TMachineConfig;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FMachines.Count - 1 do
    if SameText(FMachines[i].MachineId, AMachineId) then Exit(FMachines[i]);
end;

function TAppConfig.CurrentMachine: TMachineConfig;
begin
  Result := FindMachine(FMachineId);
  if Assigned(Result) then Exit;
  Result := TMachineConfig.Create(FMachineId);
  FMachines.Add(Result);
end;

function TAppConfig.MachineCount: Integer;
begin
  Result := FMachines.Count;
end;

function TAppConfig.MachineAt(AIndex: Integer): TMachineConfig;
begin
  Result := FMachines[AIndex];
end;

class function TAppConfig.DefaultFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + DEFAULT_FILE_NAME;
end;

procedure TAppConfig.LoadMachine(const AMachineId: string; AObj: TJSONObject);
var
  m: TMachineConfig;
  arr: TJSONArray;
  d: TJSONData;
  o: TJSONObject;
  i: Integer;
  intf: TInterfaceSetup;
  sess: TSessionState;
begin
  m := FindMachine(AMachineId);
  if not Assigned(m) then
  begin
    m := TMachineConfig.Create(AMachineId);
    FMachines.Add(m);
  end;

  d := AObj.Find('interfaces');
  if (d <> nil) and (d is TJSONArray) then
  begin
    arr := TJSONArray(d);
    for i := 0 to arr.Count - 1 do
    begin
      if not (arr.Items[i] is TJSONObject) then Continue;
      o := TJSONObject(arr.Items[i]);
      intf := m.AddInterface(o.Get('name', ''));
      intf.RigModelName      := o.Get('rigModelName', '');
      intf.RigDevice         := o.Get('rigDevice', '');
      intf.RigBaudRate       := o.Get('rigBaudRate', 0);
      intf.PttMethod         := StrToPttMethod(o.Get('pttMethod', 'none'));
      intf.PttDevice         := o.Get('pttDevice', '');
      intf.SoundInputDevice  := o.Get('soundInputDevice', '');
      intf.SoundOutputDevice := o.Get('soundOutputDevice', '');
      intf.SampleRate        := o.Get('sampleRate', 0);
    end;
  end;

  m.DefaultInterfaceName := AObj.Get('defaultInterface', '');

  d := AObj.Find('profileBindings');
  if (d <> nil) and (d is TJSONObject) then
  begin
    o := TJSONObject(d);
    for i := 0 to o.Count - 1 do
      m.BindProfile(o.Names[i], o.Items[i].AsString);
  end;

  d := AObj.Find('session');
  if (d <> nil) and (d is TJSONObject) then
  begin
    o := TJSONObject(d);
    sess.LastProfileName := o.Get('lastProfile', '');
    sess.LastFrequencyHz := o.Get('lastFrequencyHz', Int64(0));
    sess.LastModeName    := o.Get('lastMode', '');
    sess.LastBandName    := o.Get('lastBand', '');
    m.Session := sess;
  end;
end;

procedure TAppConfig.LoadFromFile(const AFileName: string);
var
  sl: TStringList;
  data: TJSONData;
  root, machines: TJSONObject;
  d: TJSONData;
  i: Integer;
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
        raise EAppConfigError.Create(
          DEFAULT_FILE_NAME + ' の解析に失敗しました: ' + E.Message);
    end;
    try
      if not (data is TJSONObject) then
        raise EAppConfigError.Create(
          DEFAULT_FILE_NAME + ' の内容が JSON オブジェクトではありません');
      root := TJSONObject(data);
      d := root.Find(KEY_MACHINES);
      if (d <> nil) and (d is TJSONObject) then
      begin
        machines := TJSONObject(d);
        for i := 0 to machines.Count - 1 do
          if machines.Items[i] is TJSONObject then
            LoadMachine(machines.Names[i], TJSONObject(machines.Items[i]));
      end;
    finally
      data.Free;
    end;
  finally
    sl.Free;
  end;
end;

function TAppConfig.MachineToJson(AMachine: TMachineConfig): TJSONObject;
var
  arr: TJSONArray;
  o, bindings, sess: TJSONObject;
  i: Integer;
  intf: TInterfaceSetup;
  pair: specialize TPair<string, string>;
begin
  Result := TJSONObject.Create;

  arr := TJSONArray.Create;
  for i := 0 to AMachine.InterfaceCount - 1 do
  begin
    intf := AMachine.InterfaceAt(i);
    o := TJSONObject.Create;
    o.Add('name', intf.Name);
    o.Add('rigModelName', intf.RigModelName);
    o.Add('rigDevice', intf.RigDevice);
    o.Add('rigBaudRate', intf.RigBaudRate);
    o.Add('pttMethod', PttMethodToStr(intf.PttMethod));
    o.Add('pttDevice', intf.PttDevice);
    o.Add('soundInputDevice', intf.SoundInputDevice);
    o.Add('soundOutputDevice', intf.SoundOutputDevice);
    o.Add('sampleRate', intf.SampleRate);
    arr.Add(o);
  end;
  Result.Add('interfaces', arr);
  Result.Add('defaultInterface', AMachine.DefaultInterfaceName);

  bindings := TJSONObject.Create;
  for pair in AMachine.FProfileBindings do
    bindings.Add(pair.Key, pair.Value);
  Result.Add('profileBindings', bindings);

  sess := TJSONObject.Create;
  sess.Add('lastProfile', AMachine.Session.LastProfileName);
  sess.Add('lastFrequencyHz', AMachine.Session.LastFrequencyHz);
  sess.Add('lastMode', AMachine.Session.LastModeName);
  sess.Add('lastBand', AMachine.Session.LastBandName);
  Result.Add('session', sess);
end;

procedure TAppConfig.SaveToFile(const AFileName: string);
var
  root, machines: TJSONObject;
  sl: TStringList;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add(KEY_SCHEMA, SCHEMA_VERSION);
    machines := TJSONObject.Create;
    for i := 0 to FMachines.Count - 1 do
      machines.Add(FMachines[i].MachineId, MachineToJson(FMachines[i]));
    root.Add(KEY_MACHINES, machines);

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

procedure TAppConfig.LoadDefault;
begin
  LoadFromFile(DefaultFilePath);
end;

procedure TAppConfig.SaveDefault;
begin
  SaveToFile(DefaultFilePath);
end;

initialization
  { 日本語を含む設定値 (マシン名・接続名等) を JSON 往復で壊さないための
    必須設定。理由と詳細は StationInfo.pas の initialization のコメントを
    参照。プロセス全体に効く冪等な設定であり、JSON 永続化を行う各ユニットが
    リンク順に依存せず単体で正しく動くよう、ここでも宣言している。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
