{ ============================================================================
  test_opprofile.lpr

  OpProfile.pas (運用プロファイルの 6 軸分解) / AppConfig.pas (接続軸と
  セッション状態の PC 固有管理) の検証。

  単なる getter/setter の確認ではなく、OpProfile.pas 冒頭コメントに
  列挙した「ユースケースの MECE 分解」の表が実際に表現できることを
  1 ケースずつ実データで確かめる構成にしている。

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -otest/test_opprofile test/test_opprofile.lpr
    ./test/test_opprofile
  ============================================================================ }
program test_opprofile;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, StationInfo, OpProfile, AppConfig;

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

{ 以降のテストで共通に使う、現実的な構成のレジストリを作る。
  個人局 + 社団局、常置場所 + 移動地、固定機 + 移動用QRP機。 }
function BuildRegistry: TProfileRegistry;
var
  r: TProfileRegistry;
  sta: TStationIdentity;
  op: TOperatorInfo;
  site: TOperatingSite;
  eq: TEquipmentSet;
  p: TOperatingProfile;
begin
  r := TProfileRegistry.Create;

  { --- 軸1: 局 (個人局 / 社団局) --- }
  sta := r.AddStation('個人局');
  sta.Callsign := 'JA1ABC';
  sta.MaxPowerW := 50;
  sta.LicenseNote := '第2級 50W';

  sta := r.AddStation('クラブ局');
  sta.Callsign := 'JA1ZZZ';
  sta.OwnerCallsign := 'JA1ABC';
  sta.IsClubStation := True;
  sta.MaxPowerW := 200;

  { --- 軸2: 運用者 (クラブ局を複数人で運用する) --- }
  op := r.AddOperator('自分');
  op.Callsign := 'JA1ABC';
  op.OperatorName := 'TARO';

  op := r.AddOperator('メンバーB');
  op.Callsign := 'JA1DEF';
  op.OperatorName := 'JIRO';

  { --- 軸3: 運用地 (常置場所 / 移動地) --- }
  site := r.AddSite('常置場所');
  site.IsFixed := True;
  site.City := 'Tokyo';
  site.GridSquare := 'PM95TQ';
  site.JccJcgCode := '100104';
  site.CqZone := 25;
  site.ItuZone := 45;

  site := r.AddSite('高尾山移動');
  site.IsFixed := False;
  site.PortableDesignator := '/1';
  site.City := 'Hachioji';
  site.GridSquare := 'PM95SP';
  site.SotaRef := 'JA/TK-005';

  { --- 軸4: 設備 (固定機 / 移動用QRP機) --- }
  eq := r.AddEquipment('固定機');
  eq.Rig := 'FT-991A';
  eq.Antenna := '3ele Yagi';
  eq.PowerW := 100;         // 免許上限50Wを超える設定 (丸められるはず)
  eq.RigModelName := 'FT-991A';

  eq := r.AddEquipment('移動用QRP');
  eq.Rig := 'FT-818';
  eq.Antenna := 'Whip';
  eq.PowerW := 5;

  { --- プロファイル (軸の組み合わせ) --- }
  p := r.AddProfile('自宅HF');
  p.StationName := '個人局';
  p.OperatorRef := '自分';
  p.SiteName := '常置場所';
  p.EquipmentName := '固定機';

  p := r.AddProfile('移動運用');
  p.StationName := '個人局';
  p.OperatorRef := '自分';
  p.SiteName := '高尾山移動';
  p.EquipmentName := '移動用QRP';

  { クラブ局を 2 人が同時に運用する = 局は共通、運用者だけ違う }
  p := r.AddProfile('クラブ局-自分');
  p.StationName := 'クラブ局';
  p.OperatorRef := '自分';
  p.SiteName := '常置場所';
  p.EquipmentName := '固定機';

  p := r.AddProfile('クラブ局-メンバーB');
  p.StationName := 'クラブ局';
  p.OperatorRef := 'メンバーB';
  p.SiteName := '常置場所';
  p.EquipmentName := '固定機';

  Result := r;
end;

{ ------------------------------------------------------------------------
  1. 軸分解が組み合わせ爆発を防いでいること
  ------------------------------------------------------------------------ }
procedure TestAxisDecomposition;
var
  r: TProfileRegistry;
begin
  WriteLn;
  WriteLn('--- 1. 軸マスタと組み合わせプロファイル ---');
  r := BuildRegistry;
  try
    Check(r.StationCount = 2, '局マスタ 2 件');
    Check(r.OperatorCount = 2, '運用者マスタ 2 件');
    Check(r.SiteCount = 2, '運用地マスタ 2 件');
    Check(r.EquipmentCount = 2, '設備マスタ 2 件');
    Check(r.ProfileCount = 4, 'プロファイル 4 件が上記マスタの参照だけで構成される');
    WriteLn('    → マスタ合計 8 件で 2x2x2x2=16 通りの運用形態を表現可能');
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  2. ユースケース: 複数コールサイン保有 / クラブ局の同時運用
  ------------------------------------------------------------------------ }
procedure TestMultipleCallsignsAndClubStation;
var
  r: TProfileRegistry;
  own, clubA, clubB: TResolvedStation;
begin
  WriteLn;
  WriteLn('--- 2. 複数コールサイン保有 / クラブ局の同時運用 ---');
  r := BuildRegistry;
  try
    own   := r.ResolveByName('自宅HF');
    clubA := r.ResolveByName('クラブ局-自分');
    clubB := r.ResolveByName('クラブ局-メンバーB');

    Check(own.StationCallsign = 'JA1ABC',
      '個人局プロファイルの STATION_CALLSIGN = JA1ABC');
    Check(clubA.StationCallsign = 'JA1ZZZ',
      'クラブ局プロファイルの STATION_CALLSIGN = JA1ZZZ (局が切り替わる)');

    { ここが軸分解の核心: 局は同じで運用者だけが違う }
    Check(clubA.StationCallsign = clubB.StationCallsign,
      'クラブ局の 2 プロファイルは STATION_CALLSIGN が同一');
    Check(clubA.OperatorCallsign = 'JA1ABC',
      '運用者A の OPERATOR = JA1ABC');
    Check(clubB.OperatorCallsign = 'JA1DEF',
      '運用者B の OPERATOR = JA1DEF (同一局・同一時刻でも区別できる)');
    Check(clubA.OperatorName <> clubB.OperatorName,
      '運用者名も別々に解決される (' + clubA.OperatorName + ' / ' + clubB.OperatorName + ')');
    Check(clubA.OwnerCallsign = 'JA1ABC',
      '社団局の OWNER_CALLSIGN が保持される');
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  3. ユースケース: 常置場所以外での運用 (軸の掛け算)
  ------------------------------------------------------------------------ }
procedure TestPortableOperation;
var
  r: TProfileRegistry;
  home, portable: TResolvedStation;
begin
  WriteLn;
  WriteLn('--- 3. 移動運用: 局コールサイン x 運用地のポータブル指定 ---');
  r := BuildRegistry;
  try
    home := r.ResolveByName('自宅HF');
    portable := r.ResolveByName('移動運用');

    Check(home.StationCallsign = 'JA1ABC',
      '常置場所ではポータブル指定が付かない');
    Check(portable.StationCallsign = 'JA1ABC/1',
      '移動地では JA1ABC + "/1" = JA1ABC/1 に解決される (実際: ' +
      portable.StationCallsign + ')');
    Check(portable.GridSquare = 'PM95SP',
      '移動地のグリッドロケータに切り替わる');
    Check(portable.City = 'Hachioji', '移動地の QTH に切り替わる');
    Check(portable.SotaRef = 'JA/TK-005', 'SOTA 参照番号が解決される');
    Check(home.JccJcgCode = '100104', '常置場所の JCC/JCG が解決される');
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  4. ユースケース: リグ/アンテナの組み合わせ と 免許上限による電力の丸め
  ------------------------------------------------------------------------ }
procedure TestEquipmentAndPowerLimit;
var
  r: TProfileRegistry;
  home, portable, club: TResolvedStation;
begin
  WriteLn;
  WriteLn('--- 4. 設備の組み合わせ / 免許上限による空中線電力の丸め ---');
  r := BuildRegistry;
  try
    home := r.ResolveByName('自宅HF');
    portable := r.ResolveByName('移動運用');
    club := r.ResolveByName('クラブ局-自分');

    Check(home.Rig = 'FT-991A', '固定機のリグ名が解決される');
    Check(home.Antenna = '3ele Yagi', '固定機のアンテナが解決される');
    Check(portable.Rig = 'FT-818', '移動用QRP機に切り替わる');
    Check(portable.Antenna = 'Whip', '移動用アンテナに切り替わる');

    { 設備は100W、個人局の免許は50W → 50Wへ丸められる }
    Check(home.PowerW = 50,
      '設備100W x 免許上限50W → 実効50W に丸められる (実際: ' +
      IntToStr(home.PowerW) + 'W)');
    Check(home.PowerWasLimited,
      '免許上限で丸められたことが PowerWasLimited で分かる');

    { 同じ設備でもクラブ局(200W免許)なら丸められない }
    Check(club.PowerW = 100,
      '同じ固定機でもクラブ局(免許200W)では100Wのまま (実際: ' +
      IntToStr(club.PowerW) + 'W)');
    Check(not club.PowerWasLimited, 'クラブ局では丸めが発生しない');

    Check(portable.PowerW = 5, 'QRP機は5Wのまま');
    Check(not portable.PowerWasLimited, 'QRPでは丸めが発生しない');
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  5. マスタ 1 箇所の修正が全プロファイルへ反映されること
  ------------------------------------------------------------------------ }
procedure TestMasterEditPropagation;
var
  r: TProfileRegistry;
  a, b: TResolvedStation;
begin
  WriteLn;
  WriteLn('--- 5. 設備マスタの修正が参照する全プロファイルへ反映される ---');
  r := BuildRegistry;
  try
    { アンテナを張り替えた = 設備マスタを 1 箇所直すだけ }
    r.FindEquipment('固定機').Antenna := '5ele Yagi';

    a := r.ResolveByName('自宅HF');
    b := r.ResolveByName('クラブ局-自分');
    Check(a.Antenna = '5ele Yagi', '自宅HFプロファイルに反映される');
    Check(b.Antenna = '5ele Yagi', 'クラブ局プロファイルにも同時に反映される');
    WriteLn('    → 参照を持つ全プロファイルを個別に直す必要がない');

    { 改名しても参照が壊れないこと }
    Check(r.RenameEquipment('固定機', 'メイン機'), 'RenameEquipment が成功する');
    Check(r.FindProfile('自宅HF').EquipmentName = 'メイン機',
      '改名がプロファイル側の参照へ追従する');
    a := r.ResolveByName('自宅HF');
    Check(a.Rig = 'FT-991A', '改名後も解決結果が壊れない');
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  6. 整合性検証 (Validate)
  ------------------------------------------------------------------------ }
procedure TestValidation;
var
  r: TProfileRegistry;
  issues: TProfileIssues;
  p: TOperatingProfile;
  i: Integer;
  foundMissingSite, foundContestName: Boolean;
begin
  WriteLn;
  WriteLn('--- 6. 参照整合性・必須項目の検証 ---');
  r := BuildRegistry;
  try
    issues := r.Validate;
    Check(Length(issues) = 0, '正しく構成されたレジストリでは指摘ゼロ (実際: ' +
      IntToStr(Length(issues)) + '件)');

    { 存在しない運用地を参照させる }
    p := r.AddProfile('壊れたプロファイル');
    p.StationName := '個人局';
    p.OperatorRef := '自分';
    p.SiteName := '存在しない場所';
    p.EquipmentName := '固定機';

    { コンテスト運用なのにコンテスト名が空 }
    p := r.AddProfile('コンテスト');
    p.StationName := '個人局';
    p.OperatorRef := '自分';
    p.SiteName := '常置場所';
    p.EquipmentName := '固定機';
    p.Context := ockContest;

    issues := r.Validate;
    foundMissingSite := False;
    foundContestName := False;
    for i := 0 to High(issues) do
    begin
      if (issues[i].ProfileName = '壊れたプロファイル') and (issues[i].Axis = 'site') then
        foundMissingSite := True;
      if (issues[i].ProfileName = 'コンテスト') and (issues[i].Axis = 'context') then
        foundContestName := True;
    end;
    Check(foundMissingSite, '存在しない運用地への参照を検出する');
    Check(foundContestName, 'コンテスト運用でコンテスト名未設定を検出する');
    for i := 0 to High(issues) do
      WriteLn('    指摘: [', issues[i].ProfileName, '/', issues[i].Axis, '] ', issues[i].Message);
  finally
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  7. 既存 TStationInfo への解決 (QsoLogbook/AdifUdpSender との接続)
  ------------------------------------------------------------------------ }
procedure TestResolveToStationInfo;
var
  r: TProfileRegistry;
  res: TResolvedStation;
  si: TStationInfo;
begin
  WriteLn;
  WriteLn('--- 7. TStationInfo への解決 (既存ユニットへの橋渡し) ---');
  r := BuildRegistry;
  si := TStationInfo.Create;
  try
    res := r.ResolveByName('移動運用');
    res.ToStationInfo(si);

    Check(si.MyCall = 'JA1ABC/1', 'MyCall にポータブル指定込みで入る');
    Check(si.OperCall = 'JA1ABC', 'OperCall に運用者コールが入る');
    Check(si.MyName = 'TARO', 'MyName に運用者名が入る');
    Check(si.MyQth = 'Hachioji', 'MyQth に運用地が入る');
    Check(si.MyLocator = 'PM95SP', 'MyLocator にグリッドが入る');
    Check(si.MyAntenna = 'Whip', 'MyAntenna に設備のアンテナが入る');
    WriteLn('    → QsoLogbook / AdifUdpSender は無変更でプロファイルの恩恵を受ける');
  finally
    si.Free;
    r.Free;
  end;
end;

{ ------------------------------------------------------------------------
  8. JSON 永続化の往復
  ------------------------------------------------------------------------ }
procedure TestProfileJsonRoundTrip;
var
  r, r2: TProfileRegistry;
  path: string;
  res: TResolvedStation;
begin
  WriteLn;
  WriteLn('--- 8. op_profiles.json 永続化の往復 ---');
  path := GetTempDir + 'test_op_profiles_' + IntToStr(Random(100000)) + '.json';
  r := BuildRegistry;
  try
    r.FindProfile('自宅HF').Context := ockContest;
    r.FindProfile('自宅HF').ContestName := 'CQ WW DX';
    r.FindProfile('自宅HF').LogFileName := 'cqww.adi';
    r.SaveToFile(path);
    Check(FileExists(path), 'SaveToFile でファイルが作成される');
  finally
    r.Free;
  end;

  r2 := TProfileRegistry.Create;
  try
    r2.LoadFromFile(path);
    Check(r2.StationCount = 2, '局マスタが往復する');
    Check(r2.OperatorCount = 2, '運用者マスタが往復する');
    Check(r2.SiteCount = 2, '運用地マスタが往復する');
    Check(r2.EquipmentCount = 2, '設備マスタが往復する');
    Check(r2.ProfileCount = 4, 'プロファイルが往復する');

    Check(r2.FindStation('クラブ局').IsClubStation, '社団局フラグが往復する');
    Check(r2.FindStation('個人局').MaxPowerW = 50, '免許上限が往復する');
    Check(r2.FindSite('高尾山移動').PortableDesignator = '/1',
      'ポータブル指定が往復する');
    Check(r2.FindSite('高尾山移動').SotaRef = 'JA/TK-005', 'SOTA参照が往復する');
    Check(r2.FindSite('常置場所').CqZone = 25, 'CQゾーンが往復する');
    Check(r2.FindEquipment('移動用QRP').PowerW = 5, '設備出力が往復する');
    Check(r2.FindProfile('自宅HF').Context = ockContest, '運用形態が往復する');
    Check(r2.FindProfile('自宅HF').ContestName = 'CQ WW DX',
      'コンテスト名が往復する (ContestLog との連携点)');
    Check(r2.FindProfile('自宅HF').LogFileName = 'cqww.adi', 'ログ分割指定が往復する');

    { 往復後も解決結果が同じであること }
    res := r2.ResolveByName('移動運用');
    Check(res.StationCallsign = 'JA1ABC/1', '往復後も移動運用の解決結果が同じ');
    Check(r2.ResolveByName('自宅HF').PowerW = 50, '往復後も電力の丸めが働く');
  finally
    r2.Free;
  end;
  DeleteFile(path);
end;

{ ------------------------------------------------------------------------
  9. AppConfig: 接続軸の PC 固有管理 (USBメモリ可搬性)
  ------------------------------------------------------------------------ }
procedure TestMachineLocalConfig;
var
  cfg, cfg2: TAppConfig;
  m: TMachineConfig;
  intf: TInterfaceSetup;
  path: string;
  sess: TSessionState;
begin
  WriteLn;
  WriteLn('--- 9. AppConfig: マシン識別子によるセクション分離 ---');
  path := GetTempDir + 'test_machine_' + IntToStr(Random(100000)) + '.json';

  cfg := TAppConfig.Create;
  try
    Check(cfg.MachineId <> '', 'マシン識別子が自動検出される (' + cfg.MachineId + ')');

    { --- シャックPC の設定 --- }
    cfg.MachineId := 'shack-pc';
    m := cfg.CurrentMachine;
    intf := m.AddInterface('IC-7300直結');
    intf.RigDevice := '/dev/ttyUSB0';
    intf.RigBaudRate := 115200;
    intf.PttMethod := pttRigCat;
    intf.SoundInputDevice := 'USB Audio CODEC';
    Check(m.DefaultInterfaceName = 'IC-7300直結',
      '最初に追加した接続が自動的に既定になる');

    sess.LastProfileName := '自宅HF';
    sess.LastFrequencyHz := 14074000;
    sess.LastModeName := 'RTTY';
    sess.LastBandName := '20m';
    m.Session := sess;

    { --- 移動用ノートPC の設定 (同じファイル内の別セクション) --- }
    cfg.MachineId := 'mobile-note';
    m := cfg.CurrentMachine;
    intf := m.AddInterface('FT-818直結');
    intf.RigDevice := 'COM3';         // 同じ設備でもポート名が違う
    intf.RigBaudRate := 38400;
    intf.PttMethod := pttSerialRts;

    Check(cfg.MachineCount = 2, '1 ファイルに 2 台分の設定が共存する');
    cfg.SaveToFile(path);
    Check(FileExists(path), 'machine_config.json が作成される');
  finally
    cfg.Free;
  end;

  { --- 別マシンとして読み直す = USBメモリを挿し替えた状況 --- }
  cfg2 := TAppConfig.Create;
  try
    cfg2.LoadFromFile(path);
    Check(cfg2.MachineCount = 2, '読込後も 2 台分が保持される');

    cfg2.MachineId := 'shack-pc';
    m := cfg2.CurrentMachine;
    Check(m.ResolveInterface('自宅HF').RigDevice = '/dev/ttyUSB0',
      'shack-pc では /dev/ttyUSB0 が解決される');
    Check(m.Session.LastFrequencyHz = 14074000,
      'shack-pc のセッション状態(前回周波数)が復元される');
    Check(m.Session.LastProfileName = '自宅HF',
      'shack-pc の前回プロファイルが復元される');

    cfg2.MachineId := 'mobile-note';
    m := cfg2.CurrentMachine;
    Check(m.ResolveInterface('移動運用').RigDevice = 'COM3',
      '同じファイルでも mobile-note では COM3 が解決される');
    Check(m.ResolveInterface('移動運用').PttMethod = pttSerialRts,
      'PTT 方式もマシンごとに保持される');
    WriteLn('    → USBメモリで PC を渡り歩いてもポート設定が壊れない');

    { --- 未知のマシンでは空の設定が自動生成される --- }
    cfg2.MachineId := 'unknown-pc';
    m := cfg2.CurrentMachine;
    Check(Assigned(m), '未知のマシンでも CurrentMachine が nil を返さない');
    Check(m.InterfaceCount = 0, '未知のマシンの接続設定は空から始まる');
    Check(m.ResolveInterface('自宅HF') = nil, '接続未設定なら ResolveInterface は nil');
  finally
    cfg2.Free;
  end;
  DeleteFile(path);
end;

{ ------------------------------------------------------------------------
  10. AppConfig: 1台のPCに複数リグを繋ぐケース (プロファイル別の接続)
  ------------------------------------------------------------------------ }
procedure TestPerProfileInterfaceBinding;
var
  cfg: TAppConfig;
  m: TMachineConfig;
  a, b: TInterfaceSetup;
begin
  WriteLn;
  WriteLn('--- 10. 同一PCに複数リグ: プロファイル別の接続割り当て ---');
  cfg := TAppConfig.Create;
  try
    cfg.MachineId := 'dual-rig-pc';
    m := cfg.CurrentMachine;

    a := m.AddInterface('HF機');
    a.RigDevice := '/dev/ttyUSB0';
    b := m.AddInterface('V/UHF機');
    b.RigDevice := '/dev/ttyUSB1';

    m.BindProfile('自宅HF', 'HF機');
    m.BindProfile('衛星', 'V/UHF機');

    Check(m.ResolveInterface('自宅HF').RigDevice = '/dev/ttyUSB0',
      '自宅HFプロファイルは HF機 に解決される');
    Check(m.ResolveInterface('衛星').RigDevice = '/dev/ttyUSB1',
      '衛星プロファイルは V/UHF機 に解決される');
    Check(m.ResolveInterface('未割当プロファイル').RigDevice = '/dev/ttyUSB0',
      '未割当のプロファイルは既定の接続へフォールバックする');

    { 別PCで設定されたバインドが残っていても壊れないこと }
    m.BindProfile('移動運用', '存在しない接続');
    Check(m.ResolveInterface('移動運用').RigDevice = '/dev/ttyUSB0',
      '存在しない接続への割り当ては既定へフォールバックする');

    m.UnbindProfile('衛星');
    Check(m.ResolveInterface('衛星').RigDevice = '/dev/ttyUSB0',
      'UnbindProfile 後は既定へ戻る');
  finally
    cfg.Free;
  end;
end;

begin
  Randomize;
  WriteLn('=== 運用プロファイル (OpProfile) / PC固有設定 (AppConfig) 検証 ===');

  TestAxisDecomposition;
  TestMultipleCallsignsAndClubStation;
  TestPortableOperation;
  TestEquipmentAndPowerLimit;
  TestMasterEditPropagation;
  TestValidation;
  TestResolveToStationInfo;
  TestProfileJsonRoundTrip;
  TestMachineLocalConfig;
  TestPerProfileInterfaceBinding;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
