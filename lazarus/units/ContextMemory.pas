{ ============================================================================
  ContextMemory.pas

  Architecture & Requirements Baseline v1.1 §8 Context Engine の
  L5 (Current QSO context) と L6 (Persistent operator knowledge)。

  §8 の表がライフサイクルとユーザー承認をこう定めている。
  ----------------------------------------------------------------------------
  | Level | 内容                          | ライフサイクル | ユーザー承認 |
  |-------|-------------------------------|---------------|-------------|
  | L5    | Current QSO context           | QSO 終了まで   | 原則不要     |
  | L6    | Persistent operator knowledge | 永続           | **必須**     |

  そして §8.1 が L6 について 4 つ課している。

    1. 保存はユーザー操作または明示的承認を前提とし、
       **デフォルトでは L5 内で完結する**。
    2. ユーザーは保存内容を View / Edit / Delete / Export / Import できる。
    3. 保存形式は将来暗号化を可能にする設計とする (SecureStore.pas)。
    4. 個人情報に相当し得る Name、QTH 等は **最小限保持** を原則とする。

  設計の骨子
  ----------------------------------------------------------------------------
  1. 既定は L5 だけ。L6 へ入れるには承認が要る。
     「承認が要る」を注意書きではなくコードの構造にする。L5 への記録
     (NoteL5) と L6 への昇格 (PromoteToL6) を別の入口にし、後者は
     承認が無ければ何もせず False を返す。同じ関数に引数で分けると、
     呼び出し側の書き忘れが素通りする。

  2. QSO が終われば L5 は消える。
     §8 の「L5 は原則 QSO 終了時に破棄する」。EndQso がこれを行う。
     消えることが既定であって、残すのが例外である。

  3. 個人情報は包括承認では上がらない。
     §8.1 の「最小限保持」を、包括承認 (l6Granted) があっても
     Name/QTH/住所などは **項目ごとの明示承認** を別に要求する形にした。
     「一度 OK と言ったら以後すべて保存」は、最小限保持と相容れない。

  4. 出所と時刻を残す。
     View/Edit/Delete を意味のあるものにするには、利用者が
     「これはいつ、何から入ったのか」を見られる必要がある。
     Evidence は校正されていない内部尺度である (§7 CF-01)。

  L5 に入れる条件について
  ----------------------------------------------------------------------------
  §8 は初期実装の L5 登録条件を
  「High Physical Confidence AND Format Validity」と定めている (ADR-008)。
  本ユニットは判定そのものを持たず、呼び出し側が満たしたうえで
  NoteL5 を呼ぶ前提にしている。物理 Evidence の閾値は Phase 3/4 の
  校正に依存するので、ここで数値を固定すると後で二重管理になる。
  ============================================================================ }
unit ContextMemory;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, DateUtils, fpjson, jsonparser,
  SecureStore, SafeFileIO;

type
  EContextMemoryError = class(Exception);

  { --- 項目の種類 ---
    種類を持つのは、個人情報かどうかを型で判断するためである
    (§8.1 の最小限保持)。文字列のキーだけだと判断できない。 }
  TContextKind = (
    ckOther,
    ckCallsign,     // コールサイン。公開情報 (免許情報として公開されている)
    ckName,         // 名前。**個人情報**
    ckQth,          // 所在地。**個人情報**
    ckGridSquare,   // グリッド。粗いが場所を示す。**個人情報寄り**
    ckRig,          // 設備
    ckAntenna,
    ckPower,
    ckNote,         // 運用者の覚書。何が書かれるか分からない。**個人情報扱い**
    ckPreference    // 相手局の好み (速度、モード等)
  );

  { --- 保持の層 --- }
  TContextScope = (
    csL5Session,    // QSO 終了で消える
    csL6Persistent  // 永続。承認が要る
  );

  { --- L6 への包括的な同意 (§8.1) ---
    既定は l6AskEveryTime である。l6Granted を既定にしてはならない ── 
    「デフォルトでは L5 内で完結する」に反する。 }
  TL6Consent = (
    l6Denied,        // 保存しない
    l6AskEveryTime,  // 項目ごとに承認を求める (既定)
    l6Granted        // 包括承認。ただし個人情報は別途明示が要る
  );

  TContextItem = record
    Key: string;          // 相手局のコールサイン等、引くための鍵
    Field: string;        // 'NAME' / 'QTH' / 'PREF.SPEED' など
    Value: string;
    Kind: TContextKind;
    Scope: TContextScope;
    Evidence: Double;     // 校正されていない内部尺度 (§7 CF-01)
    HasEvidence: Boolean;
    Source: string;       // 何から入ったか ('RxExtract' / 'operator' 等)
    CreatedUtc: TDateTime;
    UpdatedUtc: TDateTime;
    function IsPersonal: Boolean;
    function Describe: string;
  end;

  TContextItemArray = array of TContextItem;

  { L6 への昇格を求めたときの結果。なぜ上がらなかったかを
    呼び出し側 (= UI) が説明できるようにする。 }
  TPromoteOutcome = (
    promStored,             // 保存した
    promDeniedByConsent,    // 同意が l6Denied
    promNeedsApproval,      // 承認待ち (l6AskEveryTime)
    promNeedsExplicitPersonal, // 個人情報。包括承認では足りない
    promNotFound
  );

  TContextMemory = class
  private
    FItems: array of TContextItem;
    FConsent: TL6Consent;
    { 個人情報について、項目ごとに明示承認された鍵の一覧
      ('JA1ABC/NAME' の形)。 }
    FPersonalApprovals: TStringList;
    FL5DiscardCount: Int64;
    FLastError: string;
    function IndexOf(const AKey, AField: string): Integer;
    function ApprovalToken(const AKey, AField: string): string;
    procedure Upsert(const AItem: TContextItem);
  public
    constructor Create;
    destructor Destroy; override;

    { --- L5: 承認不要 (§8 の表) --- }
    procedure NoteL5(const AKey, AField, AValue: string;
      AKind: TContextKind; const ASource: string = '';
      AEvidence: Double = 0; AHasEvidence: Boolean = False);

    { --- L6: 承認必須 (§8 の表 / §8.1) ---
      承認が無ければ **何もしない**。戻り値で理由が分かる。 }
    function PromoteToL6(const AKey, AField: string): TPromoteOutcome;

    { 個人情報を項目ごとに明示承認する。包括承認とは別に要る。 }
    procedure ApprovePersonal(const AKey, AField: string);
    procedure RevokePersonal(const AKey, AField: string);
    function IsPersonalApproved(const AKey, AField: string): Boolean;

    { 運用者が直接 L6 へ入れる操作 (§8.1「ユーザー操作」)。
      画面で打ち込んで保存する場合にあたる。同意の設定に関わらず
      通すのは、これ自体が明示的な操作だからである。 }
    procedure StoreL6ByOperator(const AKey, AField, AValue: string;
      AKind: TContextKind);

    { --- QSO の終わり (§8「L5 は原則 QSO 終了時に破棄する」) --- }
    procedure EndQso;

    { --- View / Edit / Delete (§8.1) --- }
    function Count: Integer;
    function ItemAt(AIndex: Integer): TContextItem;
    function Find(const AKey, AField: string; out AItem: TContextItem): Boolean;
    function Lookup(const AKey, AField: string): string;
    function ItemsForKey(const AKey: string): TContextItemArray;
    function AllPersistent: TContextItemArray;
    function Edit(const AKey, AField, ANewValue: string): Boolean;
    function Delete(const AKey, AField: string): Boolean;
    { 1 局に関する記憶をすべて消す (「この局のことは忘れて」)。 }
    function ForgetKey(const AKey: string): Integer;
    { L6 をすべて消す。 }
    procedure ForgetAll;

    { --- Export / Import (§8.1) ---
      容器 (SecureStore) を通す。いまは平文だが、暗号を入れても
      呼び出し側は変わらない。 }
    function ExportToJson(AIncludePersonal: Boolean = True): string;
    procedure SaveToFile(const AFileName: string);
    function LoadFromFile(const AFileName: string): Boolean;
    function ImportFromJson(const AJson: string): Integer;

    function CountByScope(AScope: TContextScope): Integer;
    function PersonalCount: Integer;
    function Describe: string;

    { 既定は l6AskEveryTime。ここを l6Granted で初期化してはならない。 }
    property Consent: TL6Consent read FConsent write FConsent;
    { EndQso が捨てた L5 項目の通算。捨てていることを確認できるように。 }
    property L5DiscardCount: Int64 read FL5DiscardCount;
    property LastError: string read FLastError;
  end;

function ContextKindToStr(A: TContextKind): string;
function StrToContextKind(const A: string): TContextKind;
function IsPersonalKind(A: TContextKind): Boolean;
function ConsentToStr(A: TL6Consent): string;
function PromoteOutcomeToStr(A: TPromoteOutcome): string;

implementation

const
  CTX_JSON_VERSION = 1;

function IsPersonalKind(A: TContextKind): Boolean;
begin
  { §8.1「個人情報に相当し得る Name、QTH 等は最小限保持を原則とする」。

    コールサインを個人情報に含めていないのは、免許情報として公開されて
    いるためである。ただしコールサインと結び付いた名前・所在地は
    公開情報ではない ── だから Name/QTH をここに入れている。
    Note は何が書かれるか分からないので個人情報として扱う。 }
  Result := A in [ckName, ckQth, ckGridSquare, ckNote];
end;

function ContextKindToStr(A: TContextKind): string;
begin
  case A of
    ckCallsign:   Result := 'callsign';
    ckName:       Result := 'name';
    ckQth:        Result := 'qth';
    ckGridSquare: Result := 'grid';
    ckRig:        Result := 'rig';
    ckAntenna:    Result := 'antenna';
    ckPower:      Result := 'power';
    ckNote:       Result := 'note';
    ckPreference: Result := 'preference';
  else
    Result := 'other';
  end;
end;

function StrToContextKind(const A: string): TContextKind;
var
  k: TContextKind;
begin
  for k := Low(TContextKind) to High(TContextKind) do
    if ContextKindToStr(k) = LowerCase(Trim(A)) then
      Exit(k);
  Result := ckOther;
end;

function ConsentToStr(A: TL6Consent): string;
begin
  case A of
    l6Denied:  Result := 'denied';
    l6Granted: Result := 'granted';
  else
    Result := 'ask';
  end;
end;

function StrToConsent(const A: string): TL6Consent;
var
  t: string;
begin
  t := LowerCase(Trim(A));
  if t = 'denied' then Result := l6Denied
  else if t = 'granted' then Result := l6Granted
  else Result := l6AskEveryTime;   { 分からなければ最も慎重な側へ }
end;

function PromoteOutcomeToStr(A: TPromoteOutcome): string;
begin
  case A of
    promStored:                Result := '保存した';
    promDeniedByConsent:       Result := '同意が無い';
    promNeedsApproval:         Result := '項目ごとの承認が必要';
    promNeedsExplicitPersonal: Result := '個人情報なので明示の承認が必要';
  else
    Result := '項目が無い';
  end;
end;

{ ============================ TContextItem ============================ }

function TContextItem.IsPersonal: Boolean;
begin
  Result := IsPersonalKind(Kind);
end;

function TContextItem.Describe: string;
begin
  Result := Format('%s/%s = %s [%s/%s]',
    [Key, Field, Value, ContextKindToStr(Kind),
     specialize IfThen<string>(Scope = csL6Persistent, 'L6', 'L5')]);
  if IsPersonal then
    Result := Result + ' (個人情報)';
end;

{ ============================ TContextMemory ============================ }

constructor TContextMemory.Create;
begin
  inherited Create;
  { 既定は「毎回聞く」。§8.1 の「デフォルトでは L5 内で完結する」を
    守るため、ここを l6Granted にしてはならない。 }
  FConsent := l6AskEveryTime;
  FPersonalApprovals := TStringList.Create;
  FPersonalApprovals.CaseSensitive := False;
  FPersonalApprovals.Sorted := True;
  FPersonalApprovals.Duplicates := dupIgnore;
end;

destructor TContextMemory.Destroy;
begin
  FPersonalApprovals.Free;
  inherited Destroy;
end;

function TContextMemory.ApprovalToken(const AKey, AField: string): string;
begin
  Result := UpperCase(Trim(AKey)) + '/' + UpperCase(Trim(AField));
end;

function TContextMemory.IndexOf(const AKey, AField: string): Integer;
var
  i: Integer;
  k, f: string;
begin
  k := UpperCase(Trim(AKey));
  f := UpperCase(Trim(AField));
  for i := 0 to High(FItems) do
    if (UpperCase(FItems[i].Key) = k) and (UpperCase(FItems[i].Field) = f) then
      Exit(i);
  Result := -1;
end;

procedure TContextMemory.Upsert(const AItem: TContextItem);
var
  i, n: Integer;
begin
  i := IndexOf(AItem.Key, AItem.Field);
  if i >= 0 then
  begin
    { 既存を更新する。作成時刻と層は保つ ── L6 に上がったものが
      L5 の記録で L5 に落ちてしまうと、永続の意味が無くなる。 }
    FItems[i].Value := AItem.Value;
    FItems[i].Kind := AItem.Kind;
    FItems[i].Evidence := AItem.Evidence;
    FItems[i].HasEvidence := AItem.HasEvidence;
    FItems[i].Source := AItem.Source;
    FItems[i].UpdatedUtc := AItem.UpdatedUtc;
    if AItem.Scope = csL6Persistent then
      FItems[i].Scope := csL6Persistent;
    Exit;
  end;
  n := Length(FItems);
  SetLength(FItems, n + 1);
  FItems[n] := AItem;
end;

procedure TContextMemory.NoteL5(const AKey, AField, AValue: string;
  AKind: TContextKind; const ASource: string;
  AEvidence: Double; AHasEvidence: Boolean);
var
  it: TContextItem;
begin
  if (Trim(AKey) = '') or (Trim(AField) = '') then Exit;
  it.Key := Trim(AKey);
  it.Field := UpperCase(Trim(AField));
  it.Value := AValue;
  it.Kind := AKind;
  { L5 で入る。承認は要らないが、永続もしない。 }
  it.Scope := csL5Session;
  it.Evidence := AEvidence;
  it.HasEvidence := AHasEvidence;
  it.Source := ASource;
  it.CreatedUtc := LocalTimeToUniversal(Now);
  it.UpdatedUtc := it.CreatedUtc;
  Upsert(it);
end;

function TContextMemory.PromoteToL6(const AKey, AField: string): TPromoteOutcome;
var
  i: Integer;
begin
  i := IndexOf(AKey, AField);
  if i < 0 then Exit(promNotFound);
  if FItems[i].Scope = csL6Persistent then Exit(promStored);

  { --- §8.1 の関門 --- }
  case FConsent of
    l6Denied:
      Exit(promDeniedByConsent);
    l6AskEveryTime:
      { 包括承認が無いので、項目ごとの明示承認だけが通り道。 }
      if not IsPersonalApproved(AKey, AField) then
        Exit(promNeedsApproval);
    l6Granted:
      { 包括承認があっても、個人情報は別途明示が要る。
        「一度 OK と言ったら以後すべて保存」は最小限保持と相容れない。 }
      if FItems[i].IsPersonal and not IsPersonalApproved(AKey, AField) then
        Exit(promNeedsExplicitPersonal);
  end;

  FItems[i].Scope := csL6Persistent;
  FItems[i].UpdatedUtc := LocalTimeToUniversal(Now);
  Result := promStored;
end;

procedure TContextMemory.ApprovePersonal(const AKey, AField: string);
begin
  FPersonalApprovals.Add(ApprovalToken(AKey, AField));
end;

procedure TContextMemory.RevokePersonal(const AKey, AField: string);
var
  i: Integer;
begin
  i := FPersonalApprovals.IndexOf(ApprovalToken(AKey, AField));
  if i >= 0 then
    FPersonalApprovals.Delete(i);
end;

function TContextMemory.IsPersonalApproved(const AKey, AField: string): Boolean;
begin
  Result := FPersonalApprovals.IndexOf(ApprovalToken(AKey, AField)) >= 0;
end;

procedure TContextMemory.StoreL6ByOperator(const AKey, AField,
  AValue: string; AKind: TContextKind);
var
  it: TContextItem;
begin
  if (Trim(AKey) = '') or (Trim(AField) = '') then Exit;
  it.Key := Trim(AKey);
  it.Field := UpperCase(Trim(AField));
  it.Value := AValue;
  it.Kind := AKind;
  { 運用者自身の操作なので L6 に入る (§8.1「ユーザー操作または明示的承認」)。
    ただし承認の記録も残す ── 後で「なぜこれが保存されているのか」を
    説明できるようにするため。 }
  it.Scope := csL6Persistent;
  it.Evidence := 0;
  it.HasEvidence := False;
  it.Source := 'operator';
  it.CreatedUtc := LocalTimeToUniversal(Now);
  it.UpdatedUtc := it.CreatedUtc;
  Upsert(it);
  if it.IsPersonal then
    ApprovePersonal(it.Key, it.Field);
end;

procedure TContextMemory.EndQso;
var
  i, w: Integer;
begin
  { L5 を捨てる。§8「L5 は原則 QSO 終了時に破棄する」。
    消えるのが既定であって、残るのが例外である。 }
  w := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Scope = csL6Persistent then
    begin
      if w <> i then
        FItems[w] := FItems[i];
      Inc(w);
    end
    else
      Inc(FL5DiscardCount);
  SetLength(FItems, w);
end;

function TContextMemory.Count: Integer;
begin
  Result := Length(FItems);
end;

function TContextMemory.ItemAt(AIndex: Integer): TContextItem;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EContextMemoryError.CreateFmt(
      '記憶項目の添字が範囲外です (要求 %d / 件数 %d)',
      [AIndex, Length(FItems)]);
  Result := FItems[AIndex];
end;

function TContextMemory.Find(const AKey, AField: string;
  out AItem: TContextItem): Boolean;
var
  i: Integer;
begin
  FillChar(AItem, SizeOf(AItem), 0);
  i := IndexOf(AKey, AField);
  Result := i >= 0;
  if Result then
    AItem := FItems[i];
end;

function TContextMemory.Lookup(const AKey, AField: string): string;
var
  i: Integer;
begin
  i := IndexOf(AKey, AField);
  if i < 0 then Exit('');
  Result := FItems[i].Value;
end;

function TContextMemory.ItemsForKey(const AKey: string): TContextItemArray;
var
  i, n: Integer;
  k: string;
begin
  Result := nil;
  k := UpperCase(Trim(AKey));
  n := 0;
  for i := 0 to High(FItems) do
    if UpperCase(FItems[i].Key) = k then
    begin
      SetLength(Result, n + 1);
      Result[n] := FItems[i];
      Inc(n);
    end;
end;

function TContextMemory.AllPersistent: TContextItemArray;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Scope = csL6Persistent then
    begin
      SetLength(Result, n + 1);
      Result[n] := FItems[i];
      Inc(n);
    end;
end;

function TContextMemory.Edit(const AKey, AField, ANewValue: string): Boolean;
var
  i: Integer;
begin
  i := IndexOf(AKey, AField);
  Result := i >= 0;
  if not Result then Exit;
  FItems[i].Value := ANewValue;
  { 運用者が直したものは出所が変わる。元の Evidence は意味を失う。 }
  FItems[i].Source := 'operator';
  FItems[i].HasEvidence := False;
  FItems[i].Evidence := 0;
  FItems[i].UpdatedUtc := LocalTimeToUniversal(Now);
end;

function TContextMemory.Delete(const AKey, AField: string): Boolean;
var
  i, j: Integer;
begin
  i := IndexOf(AKey, AField);
  Result := i >= 0;
  if not Result then Exit;
  { 承認も一緒に取り消す。項目を消したのに承認だけ残っていると、
    次に同じ値が抽出されたとき黙って保存されてしまう。 }
  RevokePersonal(AKey, AField);
  for j := i to High(FItems) - 1 do
    FItems[j] := FItems[j + 1];
  SetLength(FItems, Length(FItems) - 1);
end;

function TContextMemory.ForgetKey(const AKey: string): Integer;
var
  i, w: Integer;
  k: string;
begin
  Result := 0;
  k := UpperCase(Trim(AKey));
  w := 0;
  for i := 0 to High(FItems) do
    if UpperCase(FItems[i].Key) = k then
    begin
      RevokePersonal(FItems[i].Key, FItems[i].Field);
      Inc(Result);
    end
    else
    begin
      if w <> i then
        FItems[w] := FItems[i];
      Inc(w);
    end;
  SetLength(FItems, w);
end;

procedure TContextMemory.ForgetAll;
begin
  SetLength(FItems, 0);
  FPersonalApprovals.Clear;
end;

function TContextMemory.CountByScope(AScope: TContextScope): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Scope = AScope then Inc(Result);
end;

function TContextMemory.PersonalCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].IsPersonal then Inc(Result);
end;

function TContextMemory.Describe: string;
begin
  Result := Format(
    '同意=%s / 全%d件 (L5 %d / L6 %d) / 個人情報 %d件 / 明示承認 %d件 / L5破棄 %d件',
    [ConsentToStr(FConsent), Count, CountByScope(csL5Session),
     CountByScope(csL6Persistent), PersonalCount,
     FPersonalApprovals.Count, FL5DiscardCount]);
end;

{ ---------------------------------------------------------------------------
  Export / Import (§8.1)
  --------------------------------------------------------------------------- }

function TContextMemory.ExportToJson(AIncludePersonal: Boolean): string;
var
  root: TJSONObject;
  arr, appr: TJSONArray;
  o: TJSONObject;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add('version', CTX_JSON_VERSION);
    root.Add('consent', ConsentToStr(FConsent));
    arr := TJSONArray.Create;
    root.Add('items', arr);

    for i := 0 to High(FItems) do
    begin
      { 持ち出すのは L6 だけ。L5 は QSO 内の一時的なもので、
        永続の書き出しに混ぜる意味が無い。 }
      if FItems[i].Scope <> csL6Persistent then Continue;
      { 個人情報を外す選択肢を用意する (§8.1 の最小限保持)。
        設定を他所へ持っていくときに、名前や所在地まで一緒に
        運ばずに済むようにするため。 }
      if FItems[i].IsPersonal and not AIncludePersonal then Continue;

      o := TJSONObject.Create;
      o.Add('key', FItems[i].Key);
      o.Add('field', FItems[i].Field);
      o.Add('value', FItems[i].Value);
      o.Add('kind', ContextKindToStr(FItems[i].Kind));
      o.Add('source', FItems[i].Source);
      o.Add('created', FormatDateTime(
        'yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', FItems[i].CreatedUtc));
      o.Add('updated', FormatDateTime(
        'yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', FItems[i].UpdatedUtc));
      arr.Add(o);
    end;

    { 承認の記録も持ち出す。持ち出さないと、取り込んだ先で
      「保存されているのに承認が無い」状態になる。 }
    appr := TJSONArray.Create;
    root.Add('personalApprovals', appr);
    if AIncludePersonal then
      for i := 0 to FPersonalApprovals.Count - 1 do
        appr.Add(FPersonalApprovals[i]);

    Result := root.FormatJSON;
  finally
    root.Free;
  end;
end;

function IsoToUtc(const A: string): TDateTime;
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

function TContextMemory.ImportFromJson(const AJson: string): Integer;
var
  data: TJSONData;
  root: TJSONObject;
  d: TJSONData;
  arr: TJSONArray;
  o: TJSONObject;
  i, ver: Integer;
  it: TContextItem;
begin
  Result := 0;
  FLastError := '';
  if Trim(AJson) = '' then Exit;

  try
    data := GetJSON(AJson);
  except
    on E: Exception do
      raise EContextMemoryError.Create(
        '記憶の取り込みに失敗しました: ' + E.Message);
  end;

  try
    if not (data is TJSONObject) then
      raise EContextMemoryError.Create(
        '記憶ファイルが JSON オブジェクトではありません');
    root := TJSONObject(data);

    ver := root.Get('version', 0);
    if ver > CTX_JSON_VERSION then
      raise EContextMemoryError.CreateFmt(
        '記憶の形式が新しすぎます (ファイル %d / このプログラム %d)。',
        [ver, CTX_JSON_VERSION]);

    { 承認を先に読む。項目より後に読むと、取り込んだ項目が
      「承認されていない」と見えてしまう瞬間ができる。 }
    d := root.Find('personalApprovals');
    if (d <> nil) and (d is TJSONArray) then
      for i := 0 to TJSONArray(d).Count - 1 do
        FPersonalApprovals.Add(TJSONArray(d).Items[i].AsString);

    d := root.Find('items');
    if (d <> nil) and (d is TJSONArray) then
    begin
      arr := TJSONArray(d);
      for i := 0 to arr.Count - 1 do
      begin
        if not (arr.Items[i] is TJSONObject) then Continue;
        o := TJSONObject(arr.Items[i]);
        it.Key := Trim(o.Get('key', ''));
        it.Field := UpperCase(Trim(o.Get('field', '')));
        if (it.Key = '') or (it.Field = '') then Continue;
        it.Value := o.Get('value', '');
        it.Kind := StrToContextKind(o.Get('kind', ''));
        { 取り込んだものは L6 に入る。書き出しが L6 だけなので、
          取り込みも L6 として戻すのが対称である。 }
        it.Scope := csL6Persistent;
        it.Evidence := 0;
        it.HasEvidence := False;
        it.Source := o.Get('source', 'imported');
        it.CreatedUtc := IsoToUtc(o.Get('created', ''));
        if it.CreatedUtc = 0 then
          it.CreatedUtc := LocalTimeToUniversal(Now);
        it.UpdatedUtc := IsoToUtc(o.Get('updated', ''));
        if it.UpdatedUtc = 0 then
          it.UpdatedUtc := it.CreatedUtc;
        Upsert(it);
        Inc(Result);
      end;
    end;
  finally
    data.Free;
  end;
end;

procedure TContextMemory.SaveToFile(const AFileName: string);
begin
  { 容器を通す。いまは平文だが、暗号を入れても呼び出し側は変わらない。 }
  SaveSealedFileStr(AFileName, ExportToJson(True));
end;

function TContextMemory.LoadFromFile(const AFileName: string): Boolean;
var
  txt, err: string;
begin
  FLastError := '';
  if not FileExists(AFileName) then
    Exit(True);   { 初回起動でファイルが無いのは正常系 }

  if not LoadSealedFileStr(AFileName, txt, err) then
  begin
    { 開けない理由をそのまま持ち上げる。「暗号化されていて読めない」と
      「壊れている」を利用者に区別させる必要がある。 }
    FLastError := err;
    Exit(False);
  end;
  ImportFromJson(txt);
  Result := True;
end;

initialization
  { 日本語を含む値 (NAME「たろう」、QTH「東京都八王子市」等) を JSON 往復で
    壊さないための必須設定。理由の詳細は StationInfo.pas の initialization
    のコメントを参照。プロセス全体に効く冪等な設定であり、JSON 永続化を
    行う各ユニットがリンク順に依存せず単体で正しく動くよう、ここでも
    宣言している。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
