{ ============================================================================
  test_station_adif.lpr

  StationInfo (局情報の入力・記憶) / AdifUdpSender (ADIF-over-UDP 外部送信) /
  QsoLogbook (本アプリ内蔵 QSO ログ) の結合テスト。

  実際のネットワーク越しの外部ロガーは使わず、同一プロセス内で
  127.0.0.1 宛の UDP パケットを自分自身で受信してパースすることで
  「送信されたデータが正しい ADIF フォーマットであること」を検証する
  (test_rigcontrol.lpr の Hamlib Dummy リグと同じ「自己完結型で実データを
  検証する」アプローチ)。

  実行方法:
    fpc -Sood -Mobjfpc -Fuunits -FUunits -FEtest -o test/test_station_adif test/test_station_adif.lpr
    ./test/test_station_adif
  ============================================================================ }
program test_station_adif;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Classes, DateUtils, Sockets, BaseUnix,
  StationInfo, AdifUdpSender, QsoLogbook, Requirements;

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

{ ------------------------------------------------------------------------
  1. TStationInfo: 入力・保存・再読込の往復確認
  ------------------------------------------------------------------------ }
procedure TestStationInfoRoundTrip;
var
  info, info2: TStationInfo;
  path: string;
begin
  WriteLn;
  WriteLn('--- 1. TStationInfo (局情報) の保存/再読込 往復確認 ---');

  path := GetTempDir + 'test_station_info_' + IntToStr(Random(100000)) + '.json';

  info := TStationInfo.Create;
  try
    info.MyCall := 'JA1TEST';
    info.OperCall := 'JA1OPER';
    info.MyName := 'Taro Yamada';
    info.MyQth := 'Tokyo';
    info.MyLocator := 'PM95TQ';
    info.MyAntenna := 'Dipole 20m';
    info.SaveToFile(path);
    Check(FileExists(path), 'SaveToFile でファイルが作成される');
  finally
    info.Free;
  end;

  info2 := TStationInfo.Create;
  try
    info2.LoadFromFile(path);
    Check(info2.MyCall = 'JA1TEST', 'MyCall が往復する: ' + info2.MyCall);
    Check(info2.OperCall = 'JA1OPER', 'OperCall が往復する: ' + info2.OperCall);
    Check(info2.MyName = 'Taro Yamada', 'MyName が往復する: ' + info2.MyName);
    Check(info2.MyQth = 'Tokyo', 'MyQth が往復する: ' + info2.MyQth);
    Check(info2.MyLocator = 'PM95TQ', 'MyLocator が往復する: ' + info2.MyLocator);
    Check(info2.MyAntenna = 'Dipole 20m', 'MyAntenna が往復する: ' + info2.MyAntenna);
  finally
    info2.Free;
  end;

  { 存在しないファイルからの読込は例外を出さず、既定値(空文字)のまま } 
  info2 := TStationInfo.Create;
  try
    info2.LoadFromFile(GetTempDir + 'no_such_file_xyz.json');
    Check(info2.MyCall = '', '存在しないファイルの読込は既定値(空文字)のまま');
  finally
    info2.Free;
  end;

  DeleteFile(path);

  Check(TStationInfo.DefaultFilePath <> '',
    'DefaultFilePath が実行ファイルディレクトリ配下を指す: ' +
    TStationInfo.DefaultFilePath);
  Check(ExtractFilePath(TStationInfo.DefaultFilePath) =
    ExtractFilePath(ParamStr(0)),
    'DefaultFilePath のディレクトリが実行ファイルと一致する');

  { --- 日本語 (非ASCII) の往復。JSON 保存は正しい UTF-8 で書けるのに
    読み戻しでだけ '?' に潰れるという壊れ方をするため、ASCII だけの
    テストでは検出できない。StationInfo.pas の initialization にある
    SetMultiByteConversionCodePage(CP_UTF8) が効いていることの確認。 --- }
  path := GetTempDir + 'test_station_ja_' + IntToStr(Random(100000)) + '.json';
  info := TStationInfo.Create;
  try
    info.MyCall := 'JA1ABC/1';
    info.MyQth := '東京都八王子市';
    info.MyName := '山田太郎';
    info.MyAntenna := '自作ダイポール';
    info.SaveToFile(path);
  finally
    info.Free;
  end;

  info2 := TStationInfo.Create;
  try
    info2.LoadFromFile(path);
    Check(info2.MyQth = '東京都八王子市',
      '日本語の MyQth が往復する: [' + info2.MyQth + ']');
    Check(info2.MyName = '山田太郎',
      '日本語の MyName が往復する: [' + info2.MyName + ']');
    Check(info2.MyAntenna = '自作ダイポール',
      '日本語の MyAntenna が往復する: [' + info2.MyAntenna + ']');
    Check(info2.MyCall = 'JA1ABC/1',
      'ポータブル指定付きコールサインが往復する: ' + info2.MyCall);
  finally
    info2.Free;
  end;
  DeleteFile(path);
end;

{ ------------------------------------------------------------------------
  2. AdifUdpSender: ADIF レコード組み立て内容の確認
  ------------------------------------------------------------------------ }
procedure TestAdifRecordFormat;
var
  sender: TAdifUdpSender;
  station: TStationInfo;
  qso: TAdifQsoData;
  rec: string;
begin
  WriteLn;
  WriteLn('--- 2. ADIF レコード組み立て内容の確認 (BuildAdifRecord) ---');

  station := TStationInfo.Create;
  station.MyCall := 'JA1TEST';
  station.MyLocator := 'PM95TQ';
  station.MyQth := 'Tokyo';
  station.MyAntenna := 'Dipole';

  sender := TAdifUdpSender.Create;
  try
    FillChar(qso, SizeOf(qso), 0);
    qso.Call := 'W1AW';
    qso.QsoDateUtc := EncodeDate(2026, 8, 28);
    qso.TimeOnUtc := EncodeTime(12, 34, 56, 0);
    qso.Mode := 'RTTY';
    qso.FreqMHz := 14.0745;
    qso.RstSent := '599';
    qso.RstRcvd := '599';

    rec := sender.BuildAdifRecord(qso, station);
    WriteLn('生成された ADIF レコード:');
    WriteLn(rec);

    Check(Pos('<ADIF_VER:', rec) > 0, 'ADIF ヘッダに <ADIF_VER:...> が含まれる');
    Check(Pos('<EOH>', rec) > 0, 'ADIF ヘッダに <EOH> が含まれる');
    Check(Pos('<CALL:4>W1AW', rec) > 0, '<CALL:4>W1AW が含まれる (相手局)');
    Check(Pos('<QSO_DATE:8>20260828', rec) > 0, '<QSO_DATE:8>20260828 が含まれる');
    Check(Pos('<TIME_ON:6>123456', rec) > 0, '<TIME_ON:6>123456 が含まれる');
    Check(Pos('<MODE:4>RTTY', rec) > 0, '<MODE:4>RTTY が含まれる');
    Check(Pos('<FREQ:', rec) > 0, '<FREQ:...> が含まれる');
    Check(Pos('<RST_SENT:3>599', rec) > 0, '<RST_SENT:3>599 が含まれる');
    Check(Pos('<STATION_CALLSIGN:7>JA1TEST', rec) > 0,
      '<STATION_CALLSIGN:7>JA1TEST が含まれる (自局コールサイン)');
    Check(Pos('<OPERATOR:7>JA1TEST', rec) > 0,
      '<OPERATOR:7>JA1TEST が含まれる (OperCall未設定時はMyCallを使う)');
    Check(Pos('<MY_GRIDSQUARE:6>PM95TQ', rec) > 0,
      '<MY_GRIDSQUARE:6>PM95TQ が含まれる (自局グリッドロケータ)');
    Check(Pos('<MY_CITY:5>Tokyo', rec) > 0,
      '<MY_CITY:5>Tokyo が含まれる (自局QTH)');
    Check(Pos('<EOR>', rec) > 0, 'レコード末尾に <EOR> が含まれる');
  finally
    sender.Free;
    station.Free;
  end;
end;

{ ------------------------------------------------------------------------
  3. AdifUdpSender: 実際に 127.0.0.1:52099 へ UDP 送信し、自分で受信して
     内容を検証する (自己完結型ループバックテスト)
  ------------------------------------------------------------------------ }
procedure TestAdifUdpLoopback;
var
  recvSock: cint;
  recvAddr: TInetSockAddr;
  fromLen: tsocklen;
  buf: array[0..4095] of char;
  n: cint;
  received: string;
  sender: TAdifUdpSender;
  station: TStationInfo;
  qso: TAdifQsoData;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 3. UDP ループバック送受信テスト (127.0.0.1:',
    ADIF_UDP_DEFAULT_PORT, ') ---');

  { --- 受信側ソケットを先に bind する --- }
  recvSock := fpSocket(AF_INET, SOCK_DGRAM, 0);
  Check(recvSock >= 0, '受信用ソケットの作成に成功する');

  FillChar(recvAddr, SizeOf(recvAddr), 0);
  recvAddr.sin_family := AF_INET;
  recvAddr.sin_port := htons(ADIF_UDP_DEFAULT_PORT);
  recvAddr.sin_addr := StrToNetAddr(ADIF_UDP_DEFAULT_HOST);

  ok := fpBind(recvSock, @recvAddr, SizeOf(recvAddr)) = 0;
  Check(ok, 'bind(127.0.0.1:' + IntToStr(ADIF_UDP_DEFAULT_PORT) + ') に成功する');

  if not ok then
  begin
    fpClose(recvSock);
    Exit;
  end;

  { --- 送信側: TAdifUdpSender で ADIF レコードを既定設定のまま送信 --- }
  station := TStationInfo.Create;
  station.MyCall := 'JA1LOOP';
  station.MyLocator := 'QM05';
  station.MyQth := 'Osaka';

  sender := TAdifUdpSender.Create; // 既定: 127.0.0.1:52099
  sender.Enabled := True;
  try
    Check(sender.TargetHost = ADIF_UDP_DEFAULT_HOST,
      '既定の送信先ホストが 127.0.0.1 である');
    Check(sender.TargetPort = ADIF_UDP_DEFAULT_PORT,
      '既定の送信先ポートが ' + IntToStr(ADIF_UDP_DEFAULT_PORT) + ' である');

    FillChar(qso, SizeOf(qso), 0);
    qso.Call := 'DL1ABC';
    qso.Mode := 'PSK31';
    qso.FreqMHz := 7.035;
    qso.RstSent := '589';
    qso.RstRcvd := '579';

    ok := sender.SendQso(qso, station);
    Check(ok, 'SendQso が送信成功 (Result=True) を返す');
  finally
    sender.Free;
    station.Free;
  end;

  { --- 受信側で実際にデータグラムを受信して内容を確認 --- }
  fromLen := SizeOf(recvAddr);
  n := fpRecvFrom(recvSock, @buf[0], SizeOf(buf), 0, @recvAddr, @fromLen);
  Check(n > 0, '受信側で UDP データグラムを実際に受信した (n=' + IntToStr(n) + ')');

  if n > 0 then
  begin
    SetLength(received, n);
    Move(buf[0], received[1], n);
    WriteLn('受信したデータ:');
    WriteLn(received);
    Check(Pos('<CALL:6>DL1ABC', received) > 0,
      '受信データに <CALL:6>DL1ABC が含まれる (相手局コールサイン)');
    Check(Pos('<STATION_CALLSIGN:7>JA1LOOP', received) > 0,
      '受信データに <STATION_CALLSIGN:7>JA1LOOP が含まれる (自局)');
    Check(Pos('<MY_GRIDSQUARE:4>QM05', received) > 0,
      '受信データに <MY_GRIDSQUARE:4>QM05 が含まれる');
    Check(Pos('<EOR>', received) > 0, '受信データに <EOR> が含まれる');
  end;

  fpClose(recvSock);
end;

{ ------------------------------------------------------------------------
  4. AdifUdpSender: Enabled=False の場合は送信されないことの確認
  ------------------------------------------------------------------------ }
procedure TestAdifUdpDisabledByDefault;
var
  sender: TAdifUdpSender;
  station: TStationInfo;
  qso: TAdifQsoData;
begin
  WriteLn;
  WriteLn('--- 4. Enabled=False (既定) の場合は送信されないことの確認 ---');

  sender := TAdifUdpSender.Create;
  station := TStationInfo.Create;
  try
    Check(sender.Enabled = False, '既定状態で Enabled = False である');
    FillChar(qso, SizeOf(qso), 0);
    qso.Call := 'XX1XXX';
    Check(sender.SendQso(qso, station) = False,
      'Enabled=False の間は SendQso が False を返し送信しない');
  finally
    sender.Free;
    station.Free;
  end;
end;

{ ------------------------------------------------------------------------
  5. TQsoLogbook: 内蔵ログへの追加・JSON永続化・往復確認、
     および UdpSender と連動した外部送信の確認
  ------------------------------------------------------------------------ }
procedure TestQsoLogbookRoundTrip;
var
  logbook, logbook2: TQsoLogbook;
  station: TStationInfo;
  path: string;
  qso: TQsoRecord;
begin
  WriteLn;
  WriteLn('--- 5. TQsoLogbook (本アプリ内蔵ロギング機能) の確認 ---');

  path := GetTempDir + 'test_qso_log_' + IntToStr(Random(100000)) + '.json';
  station := TStationInfo.Create;
  station.MyCall := 'JA1LOG';

  logbook := TQsoLogbook.Create;
  try
    logbook.Station := station;
    Check(logbook.Count = 0, '生成直後は Count=0 である');

    FillChar(qso, SizeOf(qso), 0);
    qso.Call := 'VK2XYZ';
    qso.QsoDateUtc := EncodeDate(2026, 8, 28);
    qso.TimeOnUtc := EncodeTime(9, 0, 0, 0);
    qso.Mode := 'FT8';
    qso.FreqMHz := 14.074;
    qso.RstSent := '-05';
    qso.RstRcvd := '-10';
    logbook.AddQso(qso);
    Check(logbook.Count = 1, 'AddQso 後に Count=1 になる');
    Check(logbook[0].Call = 'VK2XYZ', '追加したレコードの Call が取得できる');

    logbook.AddQso('EA3ABC', 'CW', 21.05, '599', '579');
    Check(logbook.Count = 2, '簡易版 AddQso でも Count が増える');
    Check(logbook[1].Call = 'EA3ABC', '簡易版 AddQso の Call が正しい');
    Check(logbook[1].Mode = 'CW', '簡易版 AddQso の Mode が正しい');

    logbook.SaveToFile(path);
    Check(FileExists(path), 'SaveToFile でファイルが作成される');
  finally
    logbook.Free;
    station.Free;
  end;

  logbook2 := TQsoLogbook.Create;
  try
    logbook2.LoadFromFile(path);
    Check(logbook2.Count = 2, '再読込後も Count=2 が維持される');
    Check(logbook2[0].Call = 'VK2XYZ', '1件目の Call が往復する');
    Check(logbook2[0].Mode = 'FT8', '1件目の Mode が往復する');
    Check(Abs(logbook2[0].FreqMHz - 14.074) < 0.0001, '1件目の FreqMHz が往復する');
    Check(logbook2[1].Call = 'EA3ABC', '2件目の Call が往復する');
  finally
    logbook2.Free;
  end;

  DeleteFile(path);
end;

procedure TestQsoLogbookUdpIntegration;
var
  recvSock: cint;
  recvAddr: TInetSockAddr;
  fromLen: tsocklen;
  buf: array[0..4095] of char;
  n: cint;
  received: string;
  logbook: TQsoLogbook;
  station: TStationInfo;
  sender: TAdifUdpSender;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 6. TQsoLogbook + AdifUdpSender 連携確認 ',
    '(AddQso が自動でUDP送信をトリガーする) ---');

  recvSock := fpSocket(AF_INET, SOCK_DGRAM, 0);
  FillChar(recvAddr, SizeOf(recvAddr), 0);
  recvAddr.sin_family := AF_INET;
  recvAddr.sin_port := htons(ADIF_UDP_DEFAULT_PORT);
  recvAddr.sin_addr := StrToNetAddr(ADIF_UDP_DEFAULT_HOST);
  ok := fpBind(recvSock, @recvAddr, SizeOf(recvAddr)) = 0;
  Check(ok, '(連携テスト用) 受信ソケットの bind に成功する');
  if not ok then
  begin
    fpClose(recvSock);
    Exit;
  end;

  station := TStationInfo.Create;
  station.MyCall := 'JA1INT';
  sender := TAdifUdpSender.Create;
  sender.Enabled := True;

  logbook := TQsoLogbook.Create;
  try
    logbook.Station := station;
    logbook.UdpSender := sender;

    logbook.AddQso('OK1TEST', 'RTTY', 14.08, '599', '599');
    Check(logbook.Count = 1, 'AddQso 後、内蔵ログにも記録される');

    fromLen := SizeOf(recvAddr);
    n := fpRecvFrom(recvSock, @buf[0], SizeOf(buf), 0, @recvAddr, @fromLen);
    Check(n > 0, 'AddQso が内部で UDP 送信もトリガーし、受信できる');
    if n > 0 then
    begin
      SetLength(received, n);
      Move(buf[0], received[1], n);
      Check(Pos('<CALL:7>OK1TEST', received) > 0,
        '連携経由で送信された ADIF に相手局コールサインが含まれる');
      Check(Pos('<STATION_CALLSIGN:6>JA1INT', received) > 0,
        '連携経由で送信された ADIF に自局コールサインが含まれる');
    end;
  finally
    logbook.Free;
    sender.Free;
    station.Free;
    fpClose(recvSock);
  end;
end;

begin
  Randomize;
  WriteLn('=== 局情報記憶 (StationInfo) / ADIF-over-UDP送信 (AdifUdpSender) ',
    '/ 内蔵QSOロギング (QsoLogbook) 検証 ===');

  TestStationInfoRoundTrip;
  TestAdifRecordFormat;
  TestAdifUdpLoopback;
  TestAdifUdpDisabledByDefault;
  TestQsoLogbookRoundTrip;
  TestQsoLogbookUdpIntegration;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('CMP-001');
  end;

  if FailCount > 0 then
    Halt(1);
end.
