{ ============================================================================
  QsoModel.pas

  Architecture & Requirements Baseline v1.1 §13 の内部交信データモデル。

  §13.4 はこう書いている:
      内部データモデルは ADIF そのものに制約せず、
      Rich Internal Model <-> ADIF Adapter という関係を維持する。

  現行の TQsoRecord (QsoLogbook.pas) は ADIF の 12 フィールドを平坦に並べた
  だけで、この関係になっていない。ADIF に無いものは持てず、ADIF にあっても
  12 個以外は読み捨てる。本ユニットはそれを置き換える内部モデルである。
  ADIF への変換は QsoAdifAdapter.pas が受け持ち、**本ユニットは AdifFile に
  依存しない**。

  後段フェーズが要求するもの (先に列挙してから形を決めた):
  ----------------------------------------------------------------------------
  | 要求元                        | 必要なこと                                |
  |-------------------------------|------------------------------------------|
  | §13.1 / Phase 4               | 値ごとに「出所」と「確定段階」を持つ。     |
  |   Candidate -> Confidence ->  | 受信テキストから抽出した候補と、運用者が   |
  |   Operator Confirmation ->    | 確定した値を区別できないと、確信度つきの   |
  |   Committed QSO               | 表示も訂正の取り消しも成立しない。         |
  | §13.2 / Phase 6               | 1 交信に複数の確認経路を独立に保持する。   |
  |   QSL モデル                  | 紙・eQSL・LoTW・クラウドは別々に進む。     |
  |                               | QSL_RCVD 1 列では表せない。               |
  | §13.3 / Phase 6               | 局所 ID と改訂番号。どちらが新しいかを     |
  |   Offline-first / Eventual    | 判定できないと同期の競合を解決できない。   |
  |   Sync                        | provider ごとの同期状態も要る。            |
  | §11 / Phase 5                 | Plugin が Core 改修なしに項目を足せる。    |
  |   Plugin / Provider           | 固定フィールドの構造体では不可能。         |
  | CNT-010 / Phase 6             | コンテストの交換項目を構造化して持つ。     |
  |                               | コンテストごとに項目が違う。               |
  | Z-05 Reproducibility          | 書き出しの順序が安定していること。         |

  設計の骨子:
  ----------------------------------------------------------------------------
  1. 項目は「名前引きの集合」にする (固定の構造体にしない)。
     Plugin もコンテストも未知の ADIF 項目も、Core を触らずに載る。
     よく使う名前は定数で与えるので、中核のコードは文字列直書きにならない。

  2. 値は単なる文字列ではなく「出所・確定段階・Evidence を伴う値」にする。
     これが Phase 4 の前提であり、同時に「抽出した候補で確定値を
     上書きしない」という運用上の安全にもなる。

  3. Evidence であって Confidence ではない (§7 CF-01 / ADR-010)。
     ここに入るのは校正されていない内部尺度である。表示用の確からしさへの
     変換は Phase 4 の責務で、この層では行わない。

  4. QSL 確認は交信とは別のオブジェクトにする。
     1 交信に何本でもぶら下がる。

  5. ADIF は外側のアダプタにする。本ユニットは ADIF を知らない。
  ============================================================================ }
unit QsoModel;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, DateUtils, fpjson, jsonparser, SafeFileIO;

type
  EQsoModelError = class(Exception);

  { --- 値の出所 (§13.1 / Phase 4) ---
    「誰がこの値を入れたか」。抽出した候補を運用者の入力で上書きしない、
    という判断の根拠になる。 }
  TFieldOrigin = (
    foUnknown,
    foOperator,     // 運用者が入力・確定した
    foExtracted,    // 受信テキストから抽出した (RxExtract)
    foRig,          // CAT から取得した
    foProfile,      // 運用プロファイルから入った
    foImported,     // 外部データ (ADIF 取り込み・クラウド) から
    foPlugin        // Plugin が設定した
  );

  { --- 確定段階 (§13.1) ---
    Candidate -> Confidence -> Operator Confirmation -> Committed QSO
    という流れのうち、値 1 つが今どこにいるか。 }
  TFieldState = (
    fsEmpty,
    fsCandidate,    // 候補。まだ確定していない
    fsConfirmed     // 確定した (運用者の確認、または確実な出所)
  );

  { 値 1 つ。 }
  TQsoField = record
    Value: string;
    Origin: TFieldOrigin;
    State: TFieldState;
    { 出所が抽出のときの内部尺度 (§7 CF-01)。校正されていないので
      Confidence ではない。表示用の確からしさへの変換は Phase 4。 }
    Evidence: Double;
    HasEvidence: Boolean;

    function IsEmpty: Boolean;
    function IsConfirmed: Boolean;
    function Describe: string;
  end;

  { --- 項目の集合 ---
    名前引きにしてあるのは、Plugin (§11)・コンテストの交換項目 (CNT-010)・
    未知の ADIF 項目を Core 改修なしに載せるため。
    挿入順を保つのは書き出しの再現性のため (Z-05)。 }
  TQsoFieldSet = class
  private
    type
      TEntry = record
        Key: string;
        Field: TQsoField;
      end;
  private
    FItems: array of TEntry;
    function IndexOfKey(const AKey: string): Integer;
    function NormalizeKey(const AKey: string): string;
  public
    procedure Clear;
    function Count: Integer;
    function KeyAt(AIndex: Integer): string;
    function FieldAt(AIndex: Integer): TQsoField;

    function Has(const AKey: string): Boolean;
    { 値を取り出す。無ければ空文字。 }
    function Get(const AKey: string): string;
    function GetField(const AKey: string): TQsoField;

    { 確定値として設定する。 }
    procedure SetValue(const AKey, AValue: string;
      AOrigin: TFieldOrigin = foOperator);
    { 候補として設定する。既に確定している項目は上書きしない
      (抽出結果が運用者の入力を壊さないようにするため)。
      戻り値: 設定したか。 }
    function SetCandidate(const AKey, AValue: string; AOrigin: TFieldOrigin;
      AEvidence: Double): Boolean;
    { 候補を確定に昇格させる (§13.1 の Operator Confirmation)。 }
    function Confirm(const AKey: string): Boolean;
    { すべての候補を確定させる。戻り値: 昇格させた件数。 }
    function ConfirmAll: Integer;

    procedure Remove(const AKey: string);
    { 候補のまま残っている項目の数。0 でなければ未確定が残っている。 }
    function CandidateCount: Integer;

    { 出所・確定段階ごと丸ごと入れる。読み込みと ADIF 取り込みのための
      入口で、通常の編集経路では使わない (SetValue / SetCandidate が
      「候補で確定値を壊さない」を守るのに対し、こちらは無条件に置く)。 }
    procedure PutField(const AKey: string; const AField: TQsoField);
  end;

  { --- QSL 確認 (§13.2 / Phase 6) --- }
  TQslMedium = (
    qmPaper,        // 紙 QSL
    qmBureau,       // ビューロー経由
    qmDirect,       // ダイレクト
    qmEqsl,         // eQSL.cc
    qmLotw,         // ARRL LoTW
    qmClubLog,
    qmQrz,
    qmOther
  );
  TQslDirection = (qdSent, qdReceived);
  TQslStatus = (
    qsNone,
    qsRequested,    // 要求した / された
    qsQueued,       // 送信待ち
    qsSent,
    qsReceived,
    qsVerified,     // 相手側でも確認された
    qsInvalid       // 不一致
  );

  { 1 本の確認経路。1 交信に何本でもぶら下がる。 }
  TQslConfirmation = class
  private
    FMedium: TQslMedium;
    FDirection: TQslDirection;
    FStatus: TQslStatus;
    FDateUtc: TDateTime;
    FReference: string;   // provider 側の識別子 (LoTW の QSL ID 等)
    FNote: string;
  public
    constructor Create(AMedium: TQslMedium; ADirection: TQslDirection);
    property Medium: TQslMedium read FMedium write FMedium;
    property Direction: TQslDirection read FDirection write FDirection;
    property Status: TQslStatus read FStatus write FStatus;
    property DateUtc: TDateTime read FDateUtc write FDateUtc;
    property Reference: string read FReference write FReference;
    property Note: string read FNote write FNote;
    function Describe: string;
  end;

  { --- 同期状態 (§13.3 / Phase 6) ---
    Local authoritative + Eventual Sync を成立させるには、
    「こちらの何版を送ったか」を provider ごとに覚えておく必要がある。
    これが無いと、回線が戻ったときにどちらが新しいか判定できない。 }
  TSyncState = (
    syLocalOnly,    // まだ送っていない
    syPending,      // 送信待ち / 送信中
    sySynced,       // 送った版と手元の版が一致
    syConflict,     // 相手も変わっていた
    syFailed
  );

  TQsoSync = class
  private
    FProvider: string;      // 'LoTW' / 'eQSL' / 'ClubLog' / 'QRZ' 等
    FRemoteId: string;
    FState: TSyncState;
    FSyncedRevision: Int64; // 最後に送った時点の Revision
    FLastAttemptUtc: TDateTime;
    FMessage: string;
  public
    constructor Create(const AProvider: string);
    property Provider: string read FProvider;
    property RemoteId: string read FRemoteId write FRemoteId;
    property State: TSyncState read FState write FState;
    property SyncedRevision: Int64 read FSyncedRevision write FSyncedRevision;
    property LastAttemptUtc: TDateTime read FLastAttemptUtc write FLastAttemptUtc;
    property Message: string read FMessage write FMessage;
  end;

  { 交信そのものの段階 (§13.1)。 }
  TQsoEntryState = (
    qeDraft,        // 入力中。まだログではない
    qeCommitted     // ログに記録された
  );

  { --- 1 交信 --- }
  TQsoEntry = class
  private
    FId: string;
    FRevision: Int64;
    FState: TQsoEntryState;
    FCreatedUtc: TDateTime;
    FModifiedUtc: TDateTime;
    FFields: TQsoFieldSet;
    FQsls: array of TQslConfirmation;
    FSyncs: array of TQsoSync;
  public
    constructor Create(const AId: string = '');
    destructor Destroy; override;

    { 変更したことを記録する。Revision が上がるので、同期側が
      「手元が変わった」と判定できる (§13.3)。 }
    procedure Touch;

    { 候補をすべて確定させ、交信をログとして確定する (§13.1)。
      戻り値: 昇格させた候補の件数。 }
    function Commit: Integer;

    { --- QSL 確認 --- }
    function AddQsl(AMedium: TQslMedium;
      ADirection: TQslDirection): TQslConfirmation;
    function FindQsl(AMedium: TQslMedium;
      ADirection: TQslDirection): TQslConfirmation;
    function QslCount: Integer;
    function QslAt(AIndex: Integer): TQslConfirmation;
    { いずれかの経路で受領確認が取れているか (Award 判定の入口)。 }
    function IsConfirmed: Boolean;

    { --- 同期 --- }
    function Sync(const AProvider: string): TQsoSync;   // 無ければ作る
    function SyncCount: Integer;
    function SyncAt(AIndex: Integer): TQsoSync;
    { この provider へ送るべきか (未送信、または送った後に変更された)。 }
    function NeedsSync(const AProvider: string): Boolean;

    property Id: string read FId;
    { 変更のたびに増える。同期の競合検出に使う。 }
    property Revision: Int64 read FRevision;
    property State: TQsoEntryState read FState write FState;
    property CreatedUtc: TDateTime read FCreatedUtc write FCreatedUtc;
    property ModifiedUtc: TDateTime read FModifiedUtc;
    property Fields: TQsoFieldSet read FFields;
  end;

  { --- 交信の集合 --- }
  TQsoStore = class
  private
    FItems: array of TQsoEntry;
    { ID -> TQsoEntry の索引。挿入順は FItems が保つ (Z-05 再現性) ので、
      こちらは整列してよい。Phase 6 の同期は「相手が返した ID で手元を
      引く」を件数分繰り返すため、線形探索では交信数の二乗になる。 }
    FIndex: TStringList;
    FLastSaveError: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;

    function Add(const AId: string = ''): TQsoEntry;
    function Count: Integer;
    function EntryAt(AIndex: Integer): TQsoEntry;
    function FindById(const AId: string): TQsoEntry;
    function Remove(const AId: string): Boolean;

    { 指定 provider へ送るべき交信を集める (§13.3 の同期キュー)。 }
    function CollectNeedingSync(const AProvider: string): TFPList;

    procedure LoadFromFile(const AFileName: string);
    function SaveToFile(const AFileName: string): Boolean;
    function ToJsonString: string;
    procedure FromJsonString(const AJson: string);

    property LastSaveError: string read FLastSaveError;
  end;

const
  { --- よく使う項目名 ---
    ADIF のタグ名に合わせてある。合わせるのは変換を単純にするためであって、
    ADIF に無い項目を持てないという意味ではない (§13.4)。 }
  QSO_CALL         = 'CALL';
  QSO_QSO_DATE     = 'QSO_DATE';
  QSO_TIME_ON      = 'TIME_ON';
  QSO_TIME_OFF     = 'TIME_OFF';
  QSO_MODE         = 'MODE';
  QSO_SUBMODE      = 'SUBMODE';
  QSO_FREQ         = 'FREQ';
  QSO_BAND         = 'BAND';
  QSO_RST_SENT     = 'RST_SENT';
  QSO_RST_RCVD     = 'RST_RCVD';
  QSO_NAME         = 'NAME';
  QSO_QTH          = 'QTH';
  QSO_GRIDSQUARE   = 'GRIDSQUARE';
  QSO_COMMENT      = 'COMMENT';
  QSO_NOTES        = 'NOTES';
  QSO_TX_PWR       = 'TX_PWR';
  QSO_OPERATOR     = 'OPERATOR';
  QSO_STATION_CALL = 'STATION_CALLSIGN';
  QSO_MY_GRID      = 'MY_GRIDSQUARE';
  QSO_MY_CITY      = 'MY_CITY';
  QSO_MY_RIG       = 'MY_RIG';
  QSO_MY_ANTENNA   = 'MY_ANTENNA';
  QSO_SRX          = 'SRX';          // 受信ナンバー
  QSO_STX          = 'STX';          // 送信ナンバー
  QSO_SRX_STRING   = 'SRX_STRING';   // 受信交換 (文字列)
  QSO_STX_STRING   = 'STX_STRING';   // 送信交換 (文字列)
  QSO_CONTEST_ID   = 'CONTEST_ID';
  QSO_DXCC         = 'DXCC';
  QSO_COUNTRY      = 'COUNTRY';
  QSO_CQZ          = 'CQZ';
  QSO_ITUZ         = 'ITUZ';

  { Plugin が足す項目の接頭辞 (§11)。名前の衝突を避けるための取り決め。
    例: 'APP.MYCONTEST.SECTION' }
  QSO_PLUGIN_PREFIX = 'APP.';

function FieldOriginToStr(A: TFieldOrigin): string;
function StrToFieldOrigin(const A: string): TFieldOrigin;
function FieldStateToStr(A: TFieldState): string;
function StrToFieldState(const A: string): TFieldState;
function QslMediumToStr(A: TQslMedium): string;
function StrToQslMedium(const A: string): TQslMedium;
function QslDirectionToStr(A: TQslDirection): string;
function StrToQslDirection(const A: string): TQslDirection;
function QslStatusToStr(A: TQslStatus): string;
function StrToQslStatus(const A: string): TQslStatus;
function SyncStateToStr(A: TSyncState): string;
function StrToSyncState(const A: string): TSyncState;

{ 局所的に一意な交信 ID を作る (§13.3)。
  外部サービスに依存せず、オフラインでも発行できる必要がある。 }
function NewQsoId: string;

implementation

const
  QSO_JSON_VERSION = 1;

var
  GIdCounter: Int64 = 0;

function NewQsoId: string;
{ 時刻 + 連番 + 乱数。オフラインで発行でき、取り込み時の衝突も避けられる。
  外部サービスの ID に依存しないのは、回線が無くてもログを取れなければ
  ならないため (§13.3 Local authoritative)。 }
begin
  Inc(GIdCounter);
  Result := Format('%s-%.6d-%.4x', [
    FormatDateTime('yyyymmddhhnnss', LocalTimeToUniversal(Now)),
    GIdCounter mod 1000000,
    Random(65536)]);
end;

function FieldOriginToStr(A: TFieldOrigin): string;
begin
  case A of
    foOperator:  Result := 'operator';
    foExtracted: Result := 'extracted';
    foRig:       Result := 'rig';
    foProfile:   Result := 'profile';
    foImported:  Result := 'imported';
    foPlugin:    Result := 'plugin';
  else
    Result := 'unknown';
  end;
end;

function StrToFieldOrigin(const A: string): TFieldOrigin;
var
  t: string;
begin
  t := LowerCase(Trim(A));
  if t = 'operator' then Result := foOperator
  else if t = 'extracted' then Result := foExtracted
  else if t = 'rig' then Result := foRig
  else if t = 'profile' then Result := foProfile
  else if t = 'imported' then Result := foImported
  else if t = 'plugin' then Result := foPlugin
  else Result := foUnknown;
end;

function FieldStateToStr(A: TFieldState): string;
begin
  case A of
    fsCandidate: Result := 'candidate';
    fsConfirmed: Result := 'confirmed';
  else
    Result := 'empty';
  end;
end;

function StrToFieldState(const A: string): TFieldState;
var
  t: string;
begin
  t := LowerCase(Trim(A));
  if t = 'candidate' then Result := fsCandidate
  else if t = 'confirmed' then Result := fsConfirmed
  else Result := fsEmpty;
end;

function QslMediumToStr(A: TQslMedium): string;
begin
  case A of
    qmPaper:   Result := 'paper';
    qmBureau:  Result := 'bureau';
    qmDirect:  Result := 'direct';
    qmEqsl:    Result := 'eqsl';
    qmLotw:    Result := 'lotw';
    qmClubLog: Result := 'clublog';
    qmQrz:     Result := 'qrz';
  else
    Result := 'other';
  end;
end;

function StrToQslMedium(const A: string): TQslMedium;
var
  t: string;
begin
  t := LowerCase(Trim(A));
  if t = 'paper' then Result := qmPaper
  else if t = 'bureau' then Result := qmBureau
  else if t = 'direct' then Result := qmDirect
  else if t = 'eqsl' then Result := qmEqsl
  else if t = 'lotw' then Result := qmLotw
  else if t = 'clublog' then Result := qmClubLog
  else if t = 'qrz' then Result := qmQrz
  else Result := qmOther;
end;

function QslDirectionToStr(A: TQslDirection): string;
begin
  if A = qdSent then Result := 'sent' else Result := 'received';
end;

function StrToQslDirection(const A: string): TQslDirection;
begin
  if LowerCase(Trim(A)) = 'sent' then Result := qdSent else Result := qdReceived;
end;

function QslStatusToStr(A: TQslStatus): string;
begin
  case A of
    qsRequested: Result := 'requested';
    qsQueued:    Result := 'queued';
    qsSent:      Result := 'sent';
    qsReceived:  Result := 'received';
    qsVerified:  Result := 'verified';
    qsInvalid:   Result := 'invalid';
  else
    Result := 'none';
  end;
end;

function StrToQslStatus(const A: string): TQslStatus;
var
  t: string;
begin
  t := LowerCase(Trim(A));
  if t = 'requested' then Result := qsRequested
  else if t = 'queued' then Result := qsQueued
  else if t = 'sent' then Result := qsSent
  else if t = 'received' then Result := qsReceived
  else if t = 'verified' then Result := qsVerified
  else if t = 'invalid' then Result := qsInvalid
  else Result := qsNone;
end;

function SyncStateToStr(A: TSyncState): string;
begin
  case A of
    syPending:  Result := 'pending';
    sySynced:   Result := 'synced';
    syConflict: Result := 'conflict';
    syFailed:   Result := 'failed';
  else
    Result := 'localOnly';
  end;
end;

function StrToSyncState(const A: string): TSyncState;
var
  t: string;
begin
  t := LowerCase(Trim(A));
  if t = 'pending' then Result := syPending
  else if t = 'synced' then Result := sySynced
  else if t = 'conflict' then Result := syConflict
  else if t = 'failed' then Result := syFailed
  else Result := syLocalOnly;
end;

{ ============================ TQsoField ============================ }

function TQsoField.IsEmpty: Boolean;
begin
  Result := Trim(Value) = '';
end;

function TQsoField.IsConfirmed: Boolean;
begin
  Result := State = fsConfirmed;
end;

function TQsoField.Describe: string;
begin
  Result := Value + ' (' + FieldOriginToStr(Origin) + '/' +
    FieldStateToStr(State);
  if HasEvidence then
    Result := Result + Format(' e=%.3f', [Evidence]);
  Result := Result + ')';
end;

{ ============================ TQsoFieldSet ============================ }

function TQsoFieldSet.NormalizeKey(const AKey: string): string;
begin
  Result := UpperCase(Trim(AKey));
end;

function TQsoFieldSet.IndexOfKey(const AKey: string): Integer;
var
  i: Integer;
  k: string;
begin
  k := NormalizeKey(AKey);
  for i := 0 to High(FItems) do
    if FItems[i].Key = k then
      Exit(i);
  Result := -1;
end;

procedure TQsoFieldSet.Clear;
begin
  SetLength(FItems, 0);
end;

function TQsoFieldSet.Count: Integer;
begin
  Result := Length(FItems);
end;

function TQsoFieldSet.KeyAt(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EQsoModelError.CreateFmt(
      '項目の添字が範囲外です (要求 %d / 件数 %d)', [AIndex, Length(FItems)]);
  Result := FItems[AIndex].Key;
end;

function TQsoFieldSet.FieldAt(AIndex: Integer): TQsoField;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EQsoModelError.CreateFmt(
      '項目の添字が範囲外です (要求 %d / 件数 %d)', [AIndex, Length(FItems)]);
  Result := FItems[AIndex].Field;
end;

function TQsoFieldSet.Has(const AKey: string): Boolean;
begin
  Result := IndexOfKey(AKey) >= 0;
end;

function TQsoFieldSet.Get(const AKey: string): string;
var
  i: Integer;
begin
  i := IndexOfKey(AKey);
  if i < 0 then Result := '' else Result := FItems[i].Field.Value;
end;

function TQsoFieldSet.GetField(const AKey: string): TQsoField;
var
  i: Integer;
begin
  i := IndexOfKey(AKey);
  if i < 0 then
  begin
    Result.Value := '';
    Result.Origin := foUnknown;
    Result.State := fsEmpty;
    Result.Evidence := 0;
    Result.HasEvidence := False;
  end
  else
    Result := FItems[i].Field;
end;

procedure TQsoFieldSet.SetValue(const AKey, AValue: string;
  AOrigin: TFieldOrigin);
var
  i, n: Integer;
begin
  i := IndexOfKey(AKey);
  if i < 0 then
  begin
    n := Length(FItems);
    SetLength(FItems, n + 1);
    FItems[n].Key := NormalizeKey(AKey);
    i := n;
  end;
  FItems[i].Field.Value := AValue;
  FItems[i].Field.Origin := AOrigin;
  FItems[i].Field.Evidence := 0;
  FItems[i].Field.HasEvidence := False;
  if Trim(AValue) = '' then
    FItems[i].Field.State := fsEmpty
  else
    FItems[i].Field.State := fsConfirmed;
end;

function TQsoFieldSet.SetCandidate(const AKey, AValue: string;
  AOrigin: TFieldOrigin; AEvidence: Double): Boolean;
var
  i, n: Integer;
begin
  Result := False;
  if Trim(AValue) = '' then Exit;
  i := IndexOfKey(AKey);
  if (i >= 0) and (FItems[i].Field.State = fsConfirmed) then
    Exit;   { 確定済みの値は候補で上書きしない }
  if i < 0 then
  begin
    n := Length(FItems);
    SetLength(FItems, n + 1);
    FItems[n].Key := NormalizeKey(AKey);
    i := n;
  end;
  FItems[i].Field.Value := AValue;
  FItems[i].Field.Origin := AOrigin;
  FItems[i].Field.State := fsCandidate;
  FItems[i].Field.Evidence := AEvidence;
  FItems[i].Field.HasEvidence := True;
  Result := True;
end;

function TQsoFieldSet.Confirm(const AKey: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  i := IndexOfKey(AKey);
  if i < 0 then Exit;
  if FItems[i].Field.State <> fsCandidate then Exit;
  FItems[i].Field.State := fsConfirmed;
  Result := True;
end;

function TQsoFieldSet.ConfirmAll: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Field.State = fsCandidate then
    begin
      FItems[i].Field.State := fsConfirmed;
      Inc(Result);
    end;
end;

procedure TQsoFieldSet.Remove(const AKey: string);
var
  i, j: Integer;
begin
  i := IndexOfKey(AKey);
  if i < 0 then Exit;
  for j := i to High(FItems) - 1 do
    FItems[j] := FItems[j + 1];
  SetLength(FItems, Length(FItems) - 1);
end;

function TQsoFieldSet.CandidateCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Field.State = fsCandidate then
      Inc(Result);
end;

procedure TQsoFieldSet.PutField(const AKey: string; const AField: TQsoField);
var
  i, n: Integer;
  k: string;
begin
  k := NormalizeKey(AKey);
  if k = '' then Exit;
  i := IndexOfKey(k);
  if i < 0 then
  begin
    n := Length(FItems);
    SetLength(FItems, n + 1);
    FItems[n].Key := k;
    i := n;
  end;
  FItems[i].Field := AField;
end;

{ ============================ TQslConfirmation ============================ }

constructor TQslConfirmation.Create(AMedium: TQslMedium;
  ADirection: TQslDirection);
begin
  inherited Create;
  FMedium := AMedium;
  FDirection := ADirection;
  FStatus := qsNone;
  FDateUtc := 0;
end;

function TQslConfirmation.Describe: string;
begin
  Result := QslMediumToStr(FMedium) + '/' + QslDirectionToStr(FDirection) +
    ': ' + QslStatusToStr(FStatus);
  if FDateUtc <> 0 then
    Result := Result + ' ' + FormatDateTime('yyyy-mm-dd', FDateUtc);
  if FReference <> '' then
    Result := Result + ' [' + FReference + ']';
end;

{ ============================ TQsoSync ============================ }

constructor TQsoSync.Create(const AProvider: string);
begin
  inherited Create;
  FProvider := AProvider;
  FState := syLocalOnly;
  FSyncedRevision := -1;
end;

{ ============================ TQsoEntry ============================ }

constructor TQsoEntry.Create(const AId: string);
begin
  inherited Create;
  if Trim(AId) = '' then
    FId := NewQsoId
  else
    FId := AId;
  FRevision := 0;
  FState := qeDraft;
  FCreatedUtc := LocalTimeToUniversal(Now);
  FModifiedUtc := FCreatedUtc;
  FFields := TQsoFieldSet.Create;
end;

destructor TQsoEntry.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FQsls) do
    FQsls[i].Free;
  SetLength(FQsls, 0);
  for i := 0 to High(FSyncs) do
    FSyncs[i].Free;
  SetLength(FSyncs, 0);
  FFields.Free;
  inherited Destroy;
end;

procedure TQsoEntry.Touch;
begin
  Inc(FRevision);
  FModifiedUtc := LocalTimeToUniversal(Now);
end;

function TQsoEntry.Commit: Integer;
begin
  Result := FFields.ConfirmAll;
  FState := qeCommitted;
  Touch;
end;

function TQsoEntry.AddQsl(AMedium: TQslMedium;
  ADirection: TQslDirection): TQslConfirmation;
var
  n: Integer;
begin
  Result := FindQsl(AMedium, ADirection);
  if Result <> nil then Exit;
  Result := TQslConfirmation.Create(AMedium, ADirection);
  n := Length(FQsls);
  SetLength(FQsls, n + 1);
  FQsls[n] := Result;
  Touch;
end;

function TQsoEntry.FindQsl(AMedium: TQslMedium;
  ADirection: TQslDirection): TQslConfirmation;
var
  i: Integer;
begin
  for i := 0 to High(FQsls) do
    if (FQsls[i].Medium = AMedium) and (FQsls[i].Direction = ADirection) then
      Exit(FQsls[i]);
  Result := nil;
end;

function TQsoEntry.QslCount: Integer;
begin
  Result := Length(FQsls);
end;

function TQsoEntry.QslAt(AIndex: Integer): TQslConfirmation;
begin
  if (AIndex < 0) or (AIndex > High(FQsls)) then
    raise EQsoModelError.CreateFmt(
      'QSL の添字が範囲外です (要求 %d / 件数 %d)', [AIndex, Length(FQsls)]);
  Result := FQsls[AIndex];
end;

function TQsoEntry.IsConfirmed: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FQsls) do
    if (FQsls[i].Direction = qdReceived) and
       (FQsls[i].Status in [qsReceived, qsVerified]) then
      Exit(True);
  Result := False;
end;

function TQsoEntry.Sync(const AProvider: string): TQsoSync;
var
  i, n: Integer;
begin
  for i := 0 to High(FSyncs) do
    if SameText(FSyncs[i].Provider, AProvider) then
      Exit(FSyncs[i]);
  Result := TQsoSync.Create(AProvider);
  n := Length(FSyncs);
  SetLength(FSyncs, n + 1);
  FSyncs[n] := Result;
end;

function TQsoEntry.SyncCount: Integer;
begin
  Result := Length(FSyncs);
end;

function TQsoEntry.SyncAt(AIndex: Integer): TQsoSync;
begin
  if (AIndex < 0) or (AIndex > High(FSyncs)) then
    raise EQsoModelError.CreateFmt(
      '同期状態の添字が範囲外です (要求 %d / 件数 %d)',
      [AIndex, Length(FSyncs)]);
  Result := FSyncs[AIndex];
end;

function TQsoEntry.NeedsSync(const AProvider: string): Boolean;
var
  i: Integer;
begin
  { 一度も送っていない、または送った後に手元が変わった場合。
    Revision の比較でこれが判定できるのが、この設計の要点である。 }
  for i := 0 to High(FSyncs) do
    if SameText(FSyncs[i].Provider, AProvider) then
    begin
      if FSyncs[i].State = sySynced then
        Exit(FRevision > FSyncs[i].SyncedRevision);
      Exit(FSyncs[i].State <> syPending);
    end;
  Result := True;   { 記録が無い = 未送信 }
end;

{ ============================================================================
  日時の文字列化

  ロケールに依存しない形にしてある。FormatDateTime の 'yyyy-mm-dd' は
  ロケールの DateSeparator を使ってしまうので、区切りは引用符で固定する。
  (AdifFile.pas に残っている FloatToStr のロケール依存と同じ罠である。)
  ============================================================================ }

function UtcToIso(A: TDateTime): string;
begin
  if A = 0 then
    Result := ''
  else
    Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', A);
end;

function IsoToUtc(const A: string): TDateTime;
{ 'YYYY-MM-DDTHH:NN:SSZ'。壊れていたら 0 を返す (読み込みを止めない)。
  ログは局所が正 (§13.3) なので、1 項目の破損で全体を失うほうが害が大きい。 }
var
  y, mo, d, h, mi, s: Integer;
begin
  Result := 0;
  if Length(A) < 19 then Exit;
  if not TryStrToInt(Copy(A, 1, 4), y) then Exit;
  if not TryStrToInt(Copy(A, 6, 2), mo) then Exit;
  if not TryStrToInt(Copy(A, 9, 2), d) then Exit;
  if not TryStrToInt(Copy(A, 12, 2), h) then Exit;
  if not TryStrToInt(Copy(A, 15, 2), mi) then Exit;
  if not TryStrToInt(Copy(A, 18, 2), s) then Exit;
  if not TryEncodeDateTime(y, mo, d, h, mi, s, 0, Result) then
    Result := 0;
end;

{ ============================================================================
  TQsoStore
  ============================================================================ }

constructor TQsoStore.Create;
begin
  inherited Create;
  { ID 索引。Phase 6 の同期は「相手から返ってきた ID で手元を引く」を
    件数分繰り返すので、線形探索だと交信数の二乗になる。
    挿入順は FItems が保つ (Z-05 再現性)。 }
  FIndex := TStringList.Create;
  FIndex.CaseSensitive := False;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupError;
end;

destructor TQsoStore.Destroy;
begin
  Clear;
  FIndex.Free;
  inherited Destroy;
end;

procedure TQsoStore.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Free;
  SetLength(FItems, 0);
  FIndex.Clear;
end;

function TQsoStore.Add(const AId: string): TQsoEntry;
var
  n: Integer;
begin
  if (Trim(AId) <> '') and (FIndex.IndexOf(Trim(AId)) >= 0) then
    raise EQsoModelError.CreateFmt(
      '交信 ID が重複しています: %s', [Trim(AId)]);

  Result := TQsoEntry.Create(AId);
  try
    FIndex.AddObject(Result.Id, Result);
  except
    { 生成した ID が偶然衝突した場合。捨てて呼び出し側に返さない。 }
    Result.Free;
    raise;
  end;
  n := Length(FItems);
  SetLength(FItems, n + 1);
  FItems[n] := Result;
end;

function TQsoStore.Count: Integer;
begin
  Result := Length(FItems);
end;

function TQsoStore.EntryAt(AIndex: Integer): TQsoEntry;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EQsoModelError.CreateFmt(
      '交信の添字が範囲外です (要求 %d / 件数 %d)',
      [AIndex, Length(FItems)]);
  Result := FItems[AIndex];
end;

function TQsoStore.FindById(const AId: string): TQsoEntry;
var
  i: Integer;
begin
  Result := nil;
  i := FIndex.IndexOf(Trim(AId));
  if i >= 0 then
    Result := TQsoEntry(FIndex.Objects[i]);
end;

function TQsoStore.Remove(const AId: string): Boolean;
var
  i, j, k: Integer;
  e: TQsoEntry;
begin
  Result := False;
  i := FIndex.IndexOf(Trim(AId));
  if i < 0 then Exit;
  e := TQsoEntry(FIndex.Objects[i]);
  FIndex.Delete(i);

  for j := 0 to High(FItems) do
    if FItems[j] = e then
    begin
      for k := j to High(FItems) - 1 do
        FItems[k] := FItems[k + 1];
      SetLength(FItems, Length(FItems) - 1);
      Break;
    end;

  e.Free;
  Result := True;
end;

function TQsoStore.CollectNeedingSync(const AProvider: string): TFPList;
var
  i: Integer;
begin
  { 呼び出し側がリストを解放する。中身の TQsoEntry は Store の持ち物で、
    リストは参照を並べただけである。 }
  Result := TFPList.Create;
  for i := 0 to High(FItems) do
    { 下書きは送らない。ログとして確定したものだけが同期対象 (§13.1)。 }
    if (FItems[i].State = qeCommitted) and FItems[i].NeedsSync(AProvider) then
      Result.Add(FItems[i]);
end;

{ ---------------------------------------------------------------------------
  JSON 表現

  この形式は「手元が正」の保存先である (§13.3)。将来 SQLite 等へ移す場合も
  version を見て移行できるようにしてある。
  項目を配列にしてあるのは、順序を保証するため (Z-05)。JSON オブジェクトの
  キー順は仕様上意味を持たないので、順序を意味に使ってはならない。
  --------------------------------------------------------------------------- }

function TQsoStore.ToJsonString: string;
var
  root: TJSONObject;
  arr: TJSONArray;
  i: Integer;

  function FieldsOf(AEntry: TQsoEntry): TJSONArray;
  var
    k: Integer;
    f: TQsoField;
    o: TJSONObject;
  begin
    Result := TJSONArray.Create;
    for k := 0 to AEntry.Fields.Count - 1 do
    begin
      f := AEntry.Fields.FieldAt(k);
      o := TJSONObject.Create;
      o.Add('key', AEntry.Fields.KeyAt(k));
      o.Add('value', f.Value);
      o.Add('origin', FieldOriginToStr(f.Origin));
      o.Add('state', FieldStateToStr(f.State));
      { Evidence は持っているときだけ書く。0.0 と「無い」は違う (§7 CF-01)。 }
      if f.HasEvidence then
        o.Add('evidence', f.Evidence);
      Result.Add(o);
    end;
  end;

  function QslsOf(AEntry: TQsoEntry): TJSONArray;
  var
    k: Integer;
    q: TQslConfirmation;
    o: TJSONObject;
  begin
    Result := TJSONArray.Create;
    for k := 0 to AEntry.QslCount - 1 do
    begin
      q := AEntry.QslAt(k);
      o := TJSONObject.Create;
      o.Add('medium', QslMediumToStr(q.Medium));
      o.Add('direction', QslDirectionToStr(q.Direction));
      o.Add('status', QslStatusToStr(q.Status));
      o.Add('date', UtcToIso(q.DateUtc));
      o.Add('reference', q.Reference);
      o.Add('note', q.Note);
      Result.Add(o);
    end;
  end;

  function SyncsOf(AEntry: TQsoEntry): TJSONArray;
  var
    k: Integer;
    s: TQsoSync;
    o: TJSONObject;
  begin
    Result := TJSONArray.Create;
    for k := 0 to AEntry.SyncCount - 1 do
    begin
      s := AEntry.SyncAt(k);
      o := TJSONObject.Create;
      o.Add('provider', s.Provider);
      o.Add('remoteId', s.RemoteId);
      o.Add('state', SyncStateToStr(s.State));
      o.Add('syncedRevision', s.SyncedRevision);
      o.Add('lastAttempt', UtcToIso(s.LastAttemptUtc));
      o.Add('message', s.Message);
      Result.Add(o);
    end;
  end;

  function EntryOf(AEntry: TQsoEntry): TJSONObject;
  begin
    Result := TJSONObject.Create;
    Result.Add('id', AEntry.Id);
    Result.Add('revision', AEntry.Revision);
    if AEntry.State = qeCommitted then
      Result.Add('state', 'committed')
    else
      Result.Add('state', 'draft');
    Result.Add('created', UtcToIso(AEntry.CreatedUtc));
    Result.Add('modified', UtcToIso(AEntry.ModifiedUtc));
    Result.Add('fields', FieldsOf(AEntry));
    Result.Add('qsls', QslsOf(AEntry));
    Result.Add('syncs', SyncsOf(AEntry));
  end;

begin
  root := TJSONObject.Create;
  try
    root.Add('version', QSO_JSON_VERSION);
    arr := TJSONArray.Create;
    root.Add('qsos', arr);
    for i := 0 to High(FItems) do
      arr.Add(EntryOf(FItems[i]));
    Result := root.FormatJSON;
  finally
    root.Free;
  end;
end;

procedure TQsoStore.FromJsonString(const AJson: string);
var
  data: TJSONData;
  root: TJSONObject;
  arr: TJSONData;
  i: Integer;
  ver: Integer;

  procedure LoadFields(AEntry: TQsoEntry; AArr: TJSONArray);
  var
    k: Integer;
    o: TJSONObject;
    f: TQsoField;
    key: string;
    ev: TJSONData;
  begin
    for k := 0 to AArr.Count - 1 do
    begin
      if not (AArr.Items[k] is TJSONObject) then Continue;
      o := TJSONObject(AArr.Items[k]);
      key := o.Get('key', '');
      if Trim(key) = '' then Continue;

      { 出所と確定段階まで復元する。ここを落とすと、読み直した瞬間に
        「運用者が確定した値」と「抽出した候補」の区別が消える (§13.1)。 }
      f.Value       := o.Get('value', '');
      f.Origin      := StrToFieldOrigin(o.Get('origin', ''));
      f.State       := StrToFieldState(o.Get('state', ''));
      ev            := o.Find('evidence');
      f.HasEvidence := (ev <> nil) and (ev is TJSONNumber);
      if f.HasEvidence then
        f.Evidence := ev.AsFloat
      else
        f.Evidence := 0;

      AEntry.Fields.PutField(key, f);
    end;
  end;

  procedure LoadQsls(AEntry: TQsoEntry; AArr: TJSONArray);
  var
    k: Integer;
    o: TJSONObject;
    q: TQslConfirmation;
  begin
    for k := 0 to AArr.Count - 1 do
    begin
      if not (AArr.Items[k] is TJSONObject) then Continue;
      o := TJSONObject(AArr.Items[k]);
      q := AEntry.AddQsl(StrToQslMedium(o.Get('medium', '')),
                         StrToQslDirection(o.Get('direction', '')));
      q.Status    := StrToQslStatus(o.Get('status', ''));
      q.DateUtc   := IsoToUtc(o.Get('date', ''));
      q.Reference := o.Get('reference', '');
      q.Note      := o.Get('note', '');
    end;
  end;

  procedure LoadSyncs(AEntry: TQsoEntry; AArr: TJSONArray);
  var
    k: Integer;
    o: TJSONObject;
    s: TQsoSync;
    p: string;
  begin
    for k := 0 to AArr.Count - 1 do
    begin
      if not (AArr.Items[k] is TJSONObject) then Continue;
      o := TJSONObject(AArr.Items[k]);
      p := o.Get('provider', '');
      if Trim(p) = '' then Continue;
      s := AEntry.Sync(p);
      s.RemoteId       := o.Get('remoteId', '');
      s.State          := StrToSyncState(o.Get('state', ''));
      s.SyncedRevision := o.Get('syncedRevision', Int64(0));
      s.LastAttemptUtc := IsoToUtc(o.Get('lastAttempt', ''));
      s.Message        := o.Get('message', '');
    end;
  end;

  procedure LoadEntry(AObj: TJSONObject);
  var
    e: TQsoEntry;
    d: TJSONData;
  begin
    e := Add(AObj.Get('id', ''));
    if SameText(Trim(AObj.Get('state', '')), 'committed') then
      e.State := qeCommitted
    else
      e.State := qeDraft;
    e.CreatedUtc := IsoToUtc(AObj.Get('created', ''));
    if e.CreatedUtc = 0 then
      e.CreatedUtc := LocalTimeToUniversal(Now);

    d := AObj.Find('fields');
    if (d <> nil) and (d is TJSONArray) then LoadFields(e, TJSONArray(d));
    d := AObj.Find('qsls');
    if (d <> nil) and (d is TJSONArray) then LoadQsls(e, TJSONArray(d));
    d := AObj.Find('syncs');
    if (d <> nil) and (d is TJSONArray) then LoadSyncs(e, TJSONArray(d));

    { Revision と ModifiedUtc は最後に戻す。AddQsl / Sync が Touch を
      呼んで Revision を進めてしまうため、先に入れると保存した版と
      ずれる。ずれると NeedsSync が「変更された」と誤判定し、
      同期が無限に走る (§13.3)。 }
    e.FRevision := AObj.Get('revision', Int64(0));
    e.FModifiedUtc := IsoToUtc(AObj.Get('modified', ''));
    if e.FModifiedUtc = 0 then
      e.FModifiedUtc := e.CreatedUtc;
  end;

begin
  Clear;
  if Trim(AJson) = '' then Exit;

  try
    data := GetJSON(AJson);
  except
    on E: Exception do
      raise EQsoModelError.Create('交信ログの解析に失敗しました: ' + E.Message);
  end;

  try
    if not (data is TJSONObject) then
      raise EQsoModelError.Create('交信ログが JSON オブジェクトではありません');
    root := TJSONObject(data);

    ver := root.Get('version', 0);
    if ver > QSO_JSON_VERSION then
      raise EQsoModelError.CreateFmt(
        '交信ログの形式が新しすぎます (ファイル %d / このプログラム %d)。' +
        '古い版で開くと項目を失うため、読み込みを中止しました。',
        [ver, QSO_JSON_VERSION]);

    arr := root.Find('qsos');
    if (arr <> nil) and (arr is TJSONArray) then
      for i := 0 to TJSONArray(arr).Count - 1 do
        if TJSONArray(arr).Items[i] is TJSONObject then
          LoadEntry(TJSONObject(TJSONArray(arr).Items[i]));
  finally
    data.Free;
  end;
end;

procedure TQsoStore.LoadFromFile(const AFileName: string);
begin
  Clear;
  if not FileExists(AFileName) then
    Exit;   { 初回起動でファイルが無いのは正常系。 }
  FromJsonString(LoadTextRaw(AFileName));
end;

function TQsoStore.SaveToFile(const AFileName: string): Boolean;
begin
  FLastSaveError := '';
  Result := True;
  try
    SaveTextAtomic(AFileName, ToJsonString);
  except
    on E: Exception do
    begin
      { 例外で落とさない。交信中に保存へ失敗しても運用は続くべきで、
        失敗したことだけ呼び出し側が知れればよい。 }
      FLastSaveError := E.Message;
      Result := False;
    end;
  end;
end;

initialization
  { 日本語を含む値 (QTH「東京都八王子市」、NAME「のま」等) を JSON 往復で
    壊さないための必須設定。理由の詳細は StationInfo.pas の initialization
    のコメントを参照。プロセス全体に効く冪等な設定であり、JSON 永続化を
    行う各ユニットがリンク順に依存せず単体で正しく動くよう、ここでも
    宣言している。 }
  SetMultiByteConversionCodePage(CP_UTF8);

  { NewQsoId の乱数部分。誰も種を撒いていないときだけ撒く。
    他のユニットが再現性のために固定した種を、こちらが黙って壊さない。 }
  if RandSeed = 0 then
    Randomize;

end.
