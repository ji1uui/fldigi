{ ============================================================================
  AdifUdpSender.pas

  1件の QSO を ADIF (Amateur Data Interchange Format) レコードとして組み立て、
  UDP データグラムで外部ロギングアプリへブロードキャスト/送信する。

  fldigi との対応 (fldigi 自体には UDP での ADIF 送信機能は無い点に注意):
    fldigi (C++)                                | Lazarus (Pascal)
    ----------------------------------------------+---------------------------
    src/include/field_def.h の ADIF_FIELD_POS     | 本ユニットの ADIF タグ名定数
    src/logbook/adif_io.cxx の FIELD fields[]      | (enum値ではなく、直接タグ名を使用)
      (enum 値 <-> ADIF タグ名のマッピング表)
    adif_io.cxx の adifmt="<%s:%d>"                | AdifField() ヘルパー関数
      (ADIF フィールド1個の書式)
    adif_io.cxx cAdifIO::writeFile() の            | BuildAdifRecord()
      ADIF_VER/PROGRAMID ヘッダ + 各フィールド出力
    src/logbook/maclogger.cxx (UDP受信の実装例、    | (参考にした実装パターンのみ。
      ただし方向は逆で ADIF でもない)                fldigi にネイティブな
                                                      ADIF-over-UDP送信機能は無い)

  なぜこの方式か (fldigi に前例が無い機能の設計根拠):
  ----------------------------------------------------------------------------
  fldigi のソースコード全体を調査した結果、fldigi 自身には「ADIF データを
  UDP で外部へ送信する」ネイティブ機能は存在しないことを確認した
  (maclogger.cxx は UDP *受信* 専用かつ独自テキスト形式、fd_logger.cxx/
  n3fjp_logger.cxx は TCP、xmlrpc_log.cxx は XML-RPC)。

  一方、アマチュア無線のロギングエコシステムには WSJT-X が
  "Logged ADIF" UDP メッセージ (NetworkMessage.hpp type=12) として導入し、
  JTAlert・N1MM Logger+・GridTracker・Log4OM・HRD Logbook・Winlog32 等
  主要な外部ロガーが軒並み「生ADIFテキストをUDPで受信する」方式に対応した
  という事実上の業界標準が存在する。本ユニットはこの標準的なアプローチ
  (1 QSO = 単体で完結したミニADIFファイルをUDPペイロードとして送信) を
  採用し、外部ロガー側に特別な追加対応を要求せずに連携できるようにする。

  ポート番号の選定:
  ----------------------------------------------------------------------------
  著名な外部ロガーとの待受ポート衝突を避けるため、IANA Service Names and
  Port Numbers Registry (https://www.iana.org/assignments/service-names-
  port-numbers/) を確認し未登録であること、かつ主要ハムログソフトの
  既定ポート (WSJT-X=2237, JTAlert=2333, N1MM Logger+=12060/12061,
  fldigi XML-RPC=7362 等) のいずれとも重複しないことを確認した上で、
  ダイナミック/プライベートポート範囲 (49152-65535) 内の 52099 を
  既定値として採用した。ユーザーが外部ロガー側の設定に合わせて
  TargetPort を変更することも可能。
  ============================================================================ }
unit AdifUdpSender;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Sockets, BaseUnix, StationInfo;

const
  { 本アプリの既定 ADIF-over-UDP 送信先。ユーザー合意により
    IPアドレスは 127.0.0.1 (同一PC上の外部ロガー宛のユニキャスト)、
    ポートは著名アプリと衝突しない 52099 を既定値とする。 }
  ADIF_UDP_DEFAULT_HOST = '127.0.0.1';
  ADIF_UDP_DEFAULT_PORT = 52099;

  { fldigi (adif_io.cxx) と同じ ADIF フィールド名。
    src/include/field_def.h (ADIF_FIELD_POS) / adif_io.cxx (FIELD fields[])
    で確認したタグ文字列をそのまま踏襲することで、fldigi の ADIF ファイルと
    の互換性・移行性を確保する。 }
  ADIF_TAG_CALL              = 'CALL';
  ADIF_TAG_QSO_DATE          = 'QSO_DATE';
  ADIF_TAG_TIME_ON           = 'TIME_ON';
  ADIF_TAG_TIME_OFF          = 'TIME_OFF';
  ADIF_TAG_MODE              = 'MODE';
  ADIF_TAG_FREQ              = 'FREQ';
  ADIF_TAG_RST_SENT          = 'RST_SENT';
  ADIF_TAG_RST_RCVD          = 'RST_RCVD';
  ADIF_TAG_NAME              = 'NAME';
  ADIF_TAG_QTH               = 'QTH';
  ADIF_TAG_GRIDSQUARE        = 'GRIDSQUARE';
  ADIF_TAG_COMMENT           = 'COMMENT';
  ADIF_TAG_STATION_CALLSIGN  = 'STATION_CALLSIGN'; { fldigi: myCall }
  ADIF_TAG_OPERATOR          = 'OPERATOR';         { fldigi: operCall }
  ADIF_TAG_MY_GRIDSQUARE     = 'MY_GRIDSQUARE';    { fldigi: myLocator }
  ADIF_TAG_MY_CITY           = 'MY_CITY';          { fldigi: myQth }
  ADIF_TAG_MY_ANTENNA        = 'MY_ANTENNA';       { fldigi: myAntenna }

  ADIF_PROGRAM_ID      = 'LazarusFldigiPort';
  ADIF_PROGRAM_VERSION = '1.0';
  ADIF_VERSION         = '3.1.4';

type
  { 送信する 1 QSO 分のデータ。日時は UTC を想定 (ADIF 慣習に合わせる)。
    RstSent/RstRcvd/Name/Qth/GridSquare/Comment は空文字なら出力しない。 }
  TAdifQsoData = record
    Call: string;
    QsoDateUtc: TDateTime;   // 日付部分のみ使用 (YYYYMMDD へ変換)
    TimeOnUtc: TDateTime;    // 時刻部分のみ使用 (HHNNSS へ変換)
    TimeOffUtc: TDateTime;   // 0 (未設定) の場合は出力しない
    Mode: string;
    FreqMHz: Double;         // 0 の場合は出力しない
    RstSent: string;
    RstRcvd: string;
    Name: string;
    Qth: string;
    GridSquare: string;
    Comment: string;
  end;

  { TAdifUdpSender
    ---------------------------------------------------------------------
    fldigi には直接対応するクラスは無い (本ユニットの冒頭コメント参照)。
    Sockets ユニット (fpSocket/fpSendTo、Windows/Linux/macOS で共通の
    API を提供する) のみを使い、外部ライブラリに依存せず UDP 送信する。 }
  TAdifUdpSender = class
  private
    FTargetHost: string;
    FTargetPort: Word;
    FEnabled: Boolean;
    function ResolveHostAddr(const AHost: string; out AAddr: in_addr): Boolean;
  public
    constructor Create(const AHost: string = ADIF_UDP_DEFAULT_HOST;
      APort: Word = ADIF_UDP_DEFAULT_PORT);

    { ADIF ヘッダ (<adif_ver>/<programid>/<EOH>) + 1QSO分のフィールド +
      <EOR> から成る、単体で完結したミニ ADIF ファイルを組み立てて返す。
      (fldigi: adif_io.cxx cAdifIO::writeFile() のヘッダ生成部 + フィールド
      出力ループに相当するが、ファイルではなく1件分の文字列を返す点が異なる)。 }
    function BuildAdifRecord(const AQso: TAdifQsoData;
      const AStation: TStationInfo): string;

    { 組み立てた ADIF レコードを UDP データグラムとして送信する。
      Enabled = False の場合は何もしない (呼び出し側で個別に判定不要にする)。
      戻り値: 送信に成功したら True。ソケットエラー等は例外を投げず False
      を返す (ロギング処理が外部ロガーの生死に引きずられて失敗しないため)。 }
    function SendQso(const AQso: TAdifQsoData;
      const AStation: TStationInfo): Boolean;

    { 任意の文字列を直接 UDP 送信する下位レベル API。テストや
      デバッグ用途、または呼び出し側で ADIF 文字列を独自に組み立てたい
      場合に使う。 }
    function SendRaw(const AData: string): Boolean;

    property TargetHost: string read FTargetHost write FTargetHost;
    property TargetPort: Word read FTargetPort write FTargetPort;
    property Enabled: Boolean read FEnabled write FEnabled;
  end;

  { 1個の ADIF フィールドを "<TAGNAME:長さ>値" 形式に整形する。
    fldigi: adif_io.cxx の adifmt = "<%s:%d>" に相当。
    値が空文字の場合は空文字を返す (フィールド自体を出力しない)。 }
function AdifField(const ATag, AValue: string): string;

implementation

function AdifField(const ATag, AValue: string): string;
begin
  if AValue = '' then
    Result := ''
  else
    Result := Format('<%s:%d>%s', [ATag, Length(AValue), AValue]);
end;

{ TAdifUdpSender }

constructor TAdifUdpSender.Create(const AHost: string; APort: Word);
begin
  inherited Create;
  FTargetHost := AHost;
  FTargetPort := APort;
  FEnabled := False; // 既定は無効。ユーザーが明示的に有効化する運用とする。
end;

function TAdifUdpSender.ResolveHostAddr(const AHost: string;
  out AAddr: in_addr): Boolean;
begin
  { StrToNetAddr は "127.0.0.1" のような IPv4 ドット表記文字列を
    そのままネットワークバイトオーダの in_addr に変換する
    (ホスト名の DNS 解決は行わない、UDP ロガー連携はローカル/固定IP
    運用が前提のため本ユニットのスコープでは十分)。 }
  AAddr := StrToNetAddr(AHost);
  Result := True;
end;

function TAdifUdpSender.BuildAdifRecord(const AQso: TAdifQsoData;
  const AStation: TStationInfo): string;
var
  header, body: string;
  freqStr: string;
begin
  { --- ADIF ヘッダ (fldigi: adif_io.cxx ADIFHEADER と同じ構成) --- }
  header := AdifField('ADIF_VER', ADIF_VERSION)
    + AdifField('PROGRAMID', ADIF_PROGRAM_ID)
    + AdifField('PROGRAMVERSION', ADIF_PROGRAM_VERSION)
    + '<EOH>' + LineEnding;

  { --- 1 QSO 分のフィールド --- }
  body := AdifField(ADIF_TAG_CALL, AQso.Call);

  if AQso.QsoDateUtc <> 0 then
    body += AdifField(ADIF_TAG_QSO_DATE, FormatDateTime('YYYYMMDD', AQso.QsoDateUtc));
  if AQso.TimeOnUtc <> 0 then
    body += AdifField(ADIF_TAG_TIME_ON, FormatDateTime('HHNNSS', AQso.TimeOnUtc));
  if AQso.TimeOffUtc <> 0 then
    body += AdifField(ADIF_TAG_TIME_OFF, FormatDateTime('HHNNSS', AQso.TimeOffUtc));

  body += AdifField(ADIF_TAG_MODE, AQso.Mode);

  if AQso.FreqMHz > 0 then
  begin
    { fldigi の adif_io.cxx と同様、小数点はカンマではなくドット固定で
      出力する (ロケール依存を避けるため FormatFloat ではなく手動組立)。 }
    freqStr := FloatToStr(AQso.FreqMHz);
    freqStr := StringReplace(freqStr, ',', '.', [rfReplaceAll]);
    body += AdifField(ADIF_TAG_FREQ, freqStr);
  end;

  body += AdifField(ADIF_TAG_RST_SENT, AQso.RstSent);
  body += AdifField(ADIF_TAG_RST_RCVD, AQso.RstRcvd);
  body += AdifField(ADIF_TAG_NAME, AQso.Name);
  body += AdifField(ADIF_TAG_QTH, AQso.Qth);
  body += AdifField(ADIF_TAG_GRIDSQUARE, AQso.GridSquare);
  body += AdifField(ADIF_TAG_COMMENT, AQso.Comment);

  { --- 自局 (Station) 情報。fldigi: logsupport.cxx AddRecord() が
    progdefaults.myCall 等を QSO レコードへコピーする処理に相当 --- }
  if Assigned(AStation) then
  begin
    body += AdifField(ADIF_TAG_STATION_CALLSIGN, AStation.MyCall);
    if AStation.OperCall <> '' then
      body += AdifField(ADIF_TAG_OPERATOR, AStation.OperCall)
    else
      body += AdifField(ADIF_TAG_OPERATOR, AStation.MyCall);
    body += AdifField(ADIF_TAG_MY_GRIDSQUARE, AStation.MyLocator);
    body += AdifField(ADIF_TAG_MY_CITY, AStation.MyQth);
    body += AdifField(ADIF_TAG_MY_ANTENNA, AStation.MyAntenna);
  end;

  body += '<EOR>' + LineEnding;

  Result := header + body;
end;

function TAdifUdpSender.SendRaw(const AData: string): Boolean;
var
  sock: cint;
  addr: TInetSockAddr;
  hostAddr: in_addr;
  sentLen: cint;
begin
  Result := False;
  if AData = '' then Exit;

  if not ResolveHostAddr(FTargetHost, hostAddr) then Exit;

  sock := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if sock < 0 then Exit;
  try
    FillChar(addr, SizeOf(addr), 0);
    addr.sin_family := AF_INET;
    addr.sin_port := htons(FTargetPort);
    addr.sin_addr := hostAddr;

    sentLen := fpSendTo(sock, @AData[1], Length(AData), 0,
      @addr, SizeOf(addr));
    Result := sentLen = Length(AData);
  finally
    fpClose(sock);
  end;
end;

function TAdifUdpSender.SendQso(const AQso: TAdifQsoData;
  const AStation: TStationInfo): Boolean;
var
  record_: string;
begin
  if not FEnabled then
  begin
    Result := False;
    Exit;
  end;
  record_ := BuildAdifRecord(AQso, AStation);
  Result := SendRaw(record_);
end;

end.
