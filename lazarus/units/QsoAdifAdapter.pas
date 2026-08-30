{ ============================================================================
  QsoAdifAdapter.pas

  Architecture & Requirements Baseline v1.1 §13.4:
      内部データモデルは ADIF そのものに制約せず、
      Rich Internal Model <-> ADIF Adapter という関係を維持する。

  その「Adapter」がこのユニットである。QsoModel.pas は ADIF を知らず、
  AdifFile.pas は内部モデルを知らない。両方を知るのはここだけにしてある。

  なぜ AdifFile.TAdifRecord を経由しないのか
  ----------------------------------------------------------------------------
  TAdifRecord は fldigi の cQsoRec を踏襲した固定 61 項目の構造体で、
  TAdifDatabase.LoadFromFile は FieldIdFromTag が -1 を返した項目、つまり
  その 61 個に無いタグを黙って捨てる。ADIF は 150 以上の標準項目に加えて
  APP_ 接頭辞の自由項目を持てる書式なので、これを通すと

      他のログソフトで作った ADIF を読み込んで書き戻すと項目が減る

  という壊し方をする。取り込み → 書き戻しはユーザが日常的に行う操作で、
  しかも減ったことに気づけない。よって本ユニットは ADIF テキストを
  **直接** TQsoStore へ読み込む経路を持ち、未知のタグも名前のまま
  TQsoFieldSet に載せる (QsoModel が名前引きの集合である理由がこれである)。

  TAdifRecord との橋渡し (EntryToAdifRecord / AdifRecordToEntry) も用意して
  あるが、これは既存コード (ContestLog / QslUpload) との接続用であり、
  61 項目に収まらないものは落ちる。落ちる件数は AdifRecordDropCount で
  数えられるようにしてあるので、呼び出し側が黙って失わずに済む。

  保たないもの (明示しておく)
  ----------------------------------------------------------------------------
  - ADIF のデータ型指示子 (<NOTES:12:M> の 'M')。項目名から決まる助言的な
    情報なので、値そのものは往復しても変わらない。
  - タグの出現順。書き出しは内部の挿入順になる (Z-05 再現性のため、
    「読んだ順」ではなく「モデルの順」で安定させる)。

  後段フェーズへの備え
  ----------------------------------------------------------------------------
  | §13.2 / Phase 6 | 複数の確認経路 <-> ADIF の QSL_* 群を双方向に写す。  |
  |                 | LoTW / eQSL / ClubLog / QRZ はそれぞれ別のタグを持つ |
  |                 | ので、1 対 1 で対応させられる。                      |
  | §13.1 / Phase 4 | 取り込んだ値の Origin は foImported で入る。運用者が |
  |                 | 入力した値と取り込んだ値を後から区別できる。         |
  | §11 / Phase 5   | Plugin 項目 'APP.VENDOR.NAME' <-> 'APP_VENDOR_NAME'。|
  ============================================================================ }
unit QsoAdifAdapter;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, StrUtils, QsoModel, AdifFile, SafeFileIO;

type
  EQsoAdifError = class(Exception);

{ --- ADIF テキスト <-> TQsoStore (§13.4 の本体) --- }

{ ADIF テキストを読み込んで AStore に交信を追加する。戻り値: 追加件数。
  AStore は消さない (複数ファイルの取り込みを重ねられるようにするため)。 }
function AdifTextToStore(const AText: string; AStore: TQsoStore): Integer;

{ AStore を ADIF テキストにする。既定では確定した交信だけを書き出す
  (下書きはログではないため / §13.1)。 }
function StoreToAdifText(AStore: TQsoStore;
  AOnlyCommitted: Boolean = True): string;

function LoadAdifFileToStore(const AFileName: string;
  AStore: TQsoStore): Integer;
{ 書き出しは SafeFileIO の一時ファイル + rename。失敗しても例外にせず
  False を返す (交信中に書き出しへ失敗しても運用は続くべきである)。 }
function SaveStoreToAdifFile(const AFileName: string; AStore: TQsoStore;
  AOnlyCommitted: Boolean = True): Boolean;

{ --- 既存の TAdifRecord との橋渡し (損失あり) --- }
procedure EntryToAdifRecord(AEntry: TQsoEntry; ARec: TAdifRecord);
procedure AdifRecordToEntry(ARec: TAdifRecord; AEntry: TQsoEntry);
{ TAdifRecord へ写したときに落ちる項目の数。0 でなければ損失がある。 }
function AdifRecordDropCount(AEntry: TQsoEntry): Integer;

{ --- 項目名の対応 (§11) ---
  内部は 'APP.VENDOR.NAME'、ADIF は 'APP_VENDOR_NAME'。
  内部側の区切りは '.' だけに統一すること ('.' と '_' を混ぜると
  ADIF 側で衝突する)。 }
function ModelKeyToAdifTag(const AKey: string): string;
function AdifTagToModelKey(const ATag: string): string;

{ そのタグを QSL 確認 (§13.2) が受け持つか。
  受け持つタグは TQsoFieldSet には入れない (二重に持つと書き戻しで
  食い違うため)。 }
function IsQslOwnedTag(const ATag: string): Boolean;

implementation

const
  { QSL 確認が受け持つ ADIF タグ。ここに挙げたものは項目集合へ入れず、
    TQslConfirmation として持つ (§13.2)。 }
  QSL_OWNED_TAGS: array[0..15] of string = (
    'QSL_SENT', 'QSL_RCVD', 'QSLSDATE', 'QSLRDATE',
    'QSL_SENT_VIA', 'QSL_RCVD_VIA',
    'LOTW_QSL_SENT', 'LOTW_QSL_RCVD', 'LOTW_QSLSDATE', 'LOTW_QSLRDATE',
    'EQSL_QSL_SENT', 'EQSL_QSL_RCVD', 'EQSL_QSLSDATE', 'EQSL_QSLRDATE',
    'CLUBLOG_QSO_UPLOAD_STATUS', 'QRZCOM_QSO_UPLOAD_STATUS'
  );

function IsQslOwnedTag(const ATag: string): Boolean;
var
  i: Integer;
  t: string;
begin
  t := UpperCase(Trim(ATag));
  for i := Low(QSL_OWNED_TAGS) to High(QSL_OWNED_TAGS) do
    if QSL_OWNED_TAGS[i] = t then
      Exit(True);
  Result := False;
end;

function ModelKeyToAdifTag(const AKey: string): string;
begin
  Result := UpperCase(Trim(AKey));
  if AnsiStartsStr(QSO_PLUGIN_PREFIX, Result) then
    Result := StringReplace(Result, '.', '_', [rfReplaceAll]);
end;

function AdifTagToModelKey(const ATag: string): string;
begin
  Result := UpperCase(Trim(ATag));
  if AnsiStartsStr('APP_', Result) then
    Result := StringReplace(Result, '_', '.', [rfReplaceAll]);
end;

{ ---------------------------------------------------------------------------
  QSL 状態 <-> ADIF の 1 文字コード

  ADIF の enumeration:
    QSL_SENT: Y(送った) N(送らない) R(要求された) Q(送信待ち) I(無視)
    QSL_RCVD: Y(受領) N(未) R(要求した) I(無効) V(照合済)
  --------------------------------------------------------------------------- }

function QslStatusToAdif(AStatus: TQslStatus;
  ADirection: TQslDirection): string;
begin
  case AStatus of
    qsRequested: Result := 'R';
    qsQueued:
      if ADirection = qdSent then Result := 'Q' else Result := 'R';
    qsSent:      Result := 'Y';
    qsReceived:  Result := 'Y';
    qsVerified:
      { 'V' は受信側にしかない。送信側は 'Y' が最上位。 }
      if ADirection = qdReceived then Result := 'V' else Result := 'Y';
    qsInvalid:   Result := 'I';
  else
    Result := 'N';
  end;
end;

function AdifToQslStatus(const ACode: string;
  ADirection: TQslDirection): TQslStatus;
var
  c: Char;
begin
  if Trim(ACode) = '' then Exit(qsNone);
  c := UpCase(Trim(ACode)[1]);
  case c of
    'Y': if ADirection = qdSent then Result := qsSent else Result := qsReceived;
    'V': Result := qsVerified;
    'R': Result := qsRequested;
    'Q': Result := qsQueued;
    'I': Result := qsInvalid;
  else
    Result := qsNone;
  end;
end;

function AdifDateToUtc(const A: string): TDateTime;
{ ADIF の日付は 'YYYYMMDD'。 }
var
  y, m, d: Integer;
begin
  Result := 0;
  if Length(Trim(A)) <> 8 then Exit;
  if not TryStrToInt(Copy(Trim(A), 1, 4), y) then Exit;
  if not TryStrToInt(Copy(Trim(A), 5, 2), m) then Exit;
  if not TryStrToInt(Copy(Trim(A), 7, 2), d) then Exit;
  if not TryEncodeDate(y, m, d, Result) then
    Result := 0;
end;

function UtcToAdifDate(A: TDateTime): string;
begin
  if A = 0 then
    Result := ''
  else
    { 区切りを持たない書式なのでロケールの影響を受けないが、
      月の 'mm' と分の 'nn' を取り違えないよう明示しておく。 }
    Result := FormatDateTime('yyyymmdd', A);
end;

{ ---------------------------------------------------------------------------
  QSL 確認 -> ADIF タグ
  --------------------------------------------------------------------------- }

type
  TQslTagSet = record
    Sent, Rcvd, SentDate, RcvdDate: string;
  end;

function QslTagsFor(AMedium: TQslMedium): TQslTagSet;
begin
  case AMedium of
    qmLotw:
      begin
        Result.Sent := 'LOTW_QSL_SENT';   Result.Rcvd := 'LOTW_QSL_RCVD';
        Result.SentDate := 'LOTW_QSLSDATE'; Result.RcvdDate := 'LOTW_QSLRDATE';
      end;
    qmEqsl:
      begin
        Result.Sent := 'EQSL_QSL_SENT';   Result.Rcvd := 'EQSL_QSL_RCVD';
        Result.SentDate := 'EQSL_QSLSDATE'; Result.RcvdDate := 'EQSL_QSLRDATE';
      end;
    qmClubLog:
      begin
        { ClubLog / QRZ は「アップロード状態」しか持たない。
          受信方向と日付は ADIF に置き場所が無い。 }
        Result.Sent := 'CLUBLOG_QSO_UPLOAD_STATUS'; Result.Rcvd := '';
        Result.SentDate := ''; Result.RcvdDate := '';
      end;
    qmQrz:
      begin
        Result.Sent := 'QRZCOM_QSO_UPLOAD_STATUS'; Result.Rcvd := '';
        Result.SentDate := ''; Result.RcvdDate := '';
      end;
  else
    { 紙・ビューロー・ダイレクト・その他は ADIF の QSL_SENT/QSL_RCVD。 }
    Result.Sent := 'QSL_SENT';   Result.Rcvd := 'QSL_RCVD';
    Result.SentDate := 'QSLSDATE'; Result.RcvdDate := 'QSLRDATE';
  end;
end;

function QslViaCode(AMedium: TQslMedium): string;
begin
  case AMedium of
    qmBureau: Result := 'B';
    qmDirect: Result := 'D';
  else
    Result := '';
  end;
end;

function QslMediumFromVia(const AVia: string): TQslMedium;
begin
  if Trim(AVia) = '' then Exit(qmPaper);
  case UpCase(Trim(AVia)[1]) of
    'B': Result := qmBureau;
    'D': Result := qmDirect;
    'E': Result := qmEqsl;   { ADIF の 'E' は electronic }
  else
    Result := qmPaper;
  end;
end;

{ ---------------------------------------------------------------------------
  書き出し
  --------------------------------------------------------------------------- }

procedure AppendQslTags(AEntry: TQsoEntry; var ALine: string);
var
  i: Integer;
  q: TQslConfirmation;
  tags: TQslTagSet;
  via: string;
begin
  for i := 0 to AEntry.QslCount - 1 do
  begin
    q := AEntry.QslAt(i);
    if q.Status = qsNone then Continue;
    tags := QslTagsFor(q.Medium);

    if q.Direction = qdSent then
    begin
      if tags.Sent = '' then Continue;
      ALine := ALine + AdifTagStr(tags.Sent,
        QslStatusToAdif(q.Status, qdSent));
      if tags.SentDate <> '' then
        ALine := ALine + AdifTagStr(tags.SentDate, UtcToAdifDate(q.DateUtc));
      via := QslViaCode(q.Medium);
      if via <> '' then
        ALine := ALine + AdifTagStr('QSL_SENT_VIA', via);
    end
    else
    begin
      if tags.Rcvd = '' then Continue;
      ALine := ALine + AdifTagStr(tags.Rcvd,
        QslStatusToAdif(q.Status, qdReceived));
      if tags.RcvdDate <> '' then
        ALine := ALine + AdifTagStr(tags.RcvdDate, UtcToAdifDate(q.DateUtc));
      via := QslViaCode(q.Medium);
      if via <> '' then
        ALine := ALine + AdifTagStr('QSL_RCVD_VIA', via);
    end;
  end;
end;

function StoreToAdifText(AStore: TQsoStore; AOnlyCommitted: Boolean): string;
var
  sl: TStringList;
  i, k: Integer;
  e: TQsoEntry;
  f: TQsoField;
  line, tag: string;
begin
  sl := TStringList.Create;
  try
    sl.Add(AdifTagStr('ADIF_VER', ADIF_VERSION));
    sl.Add(AdifTagStr('PROGRAMID', ADIF_PROGRAM_ID));
    sl.Add(AdifTagStr('PROGRAMVERSION', ADIF_PROGRAM_VERSION));
    sl.Add('<EOH>');

    for i := 0 to AStore.Count - 1 do
    begin
      e := AStore.EntryAt(i);
      if AOnlyCommitted and (e.State <> qeCommitted) then
        Continue;

      line := '';
      { 挿入順で書く。読んだ順ではなくモデルの順にすることで、
        同じ内容なら常に同じバイト列になる (Z-05)。 }
      for k := 0 to e.Fields.Count - 1 do
      begin
        f := e.Fields.FieldAt(k);
        if f.Value = '' then Continue;
        tag := ModelKeyToAdifTag(e.Fields.KeyAt(k));
        { QSL 系は下の AppendQslTags が受け持つ。項目集合に紛れ込んで
          いても二重に書かない。 }
        if IsQslOwnedTag(tag) then Continue;
        line := line + AdifTagStr(tag, f.Value);
      end;
      AppendQslTags(e, line);

      if line = '' then Continue;
      sl.Add(line + '<EOR>');
    end;

    { 改行は LF に固定する。TStringList.Text は環境依存の改行を使うので
      使わない (ADIF は長さ指定で値を切り出すため、改行の揺れが値の
      長さに影響しない位置であっても、往復の再現性のために固定する)。 }
    Result := '';
    for i := 0 to sl.Count - 1 do
      Result := Result + sl[i] + #10;
  finally
    sl.Free;
  end;
end;

function SaveStoreToAdifFile(const AFileName: string; AStore: TQsoStore;
  AOnlyCommitted: Boolean): Boolean;
begin
  Result := True;
  try
    SaveTextAtomic(AFileName, StoreToAdifText(AStore, AOnlyCommitted));
  except
    Result := False;
  end;
end;

{ ---------------------------------------------------------------------------
  読み込み

  AdifFile.TAdifDatabase.LoadFromFile と同じ走査だが、
  - 未知のタグを捨てない (§13.4 の要点)
  - <EOH> が無くても読む (ADIF 仕様上ヘッダは省略でき、
    交換用に本体だけを渡してくる実装がある)
  という 2 点が違う。
  --------------------------------------------------------------------------- }

function AdifTextToStore(const AText: string; AStore: TQsoStore): Integer;
var
  buf, lowBuf: string;
  p, ptr, tagStart, gtPos, colonPos, tagEnd, nextPtr: SizeInt;
  tag, valStr, key: string;
  fldSize: Integer;
  entry: TQsoEntry;
  fld: TQsoField;

  { 現在のレコードの QSL 系タグを溜めておき、<EOR> でまとめて解釈する。
    LOTW_QSL_RCVD と LOTW_QSLRDATE のように、状態と日付が別タグに
    分かれているため、1 タグずつでは組み立てられない。 }
  qslVals: TStringList;

  procedure EnsureEntry;
  begin
    if entry = nil then
    begin
      entry := AStore.Add;
      { 取り込んだ値は「運用者が確定した」ものではないが、過去のログ
        として確定している。候補ではない (§13.1)。 }
      entry.State := qeCommitted;
    end;
  end;

  procedure FlushQsl;
  { 溜めたタグから TQslConfirmation を組み立てる。 }
    function V(const AName: string): string;
    begin
      Result := qslVals.Values[AName];
    end;

    procedure OneMedium(AMedium: TQslMedium);
    var
      tags: TQslTagSet;
      st: TQslStatus;
      q: TQslConfirmation;
      m: TQslMedium;
    begin
      tags := QslTagsFor(AMedium);

      if (tags.Sent <> '') and (V(tags.Sent) <> '') then
      begin
        st := AdifToQslStatus(V(tags.Sent), qdSent);
        if st <> qsNone then
        begin
          m := AMedium;
          if AMedium = qmPaper then
            m := QslMediumFromVia(V('QSL_SENT_VIA'));
          q := entry.AddQsl(m, qdSent);
          q.Status := st;
          if tags.SentDate <> '' then
            q.DateUtc := AdifDateToUtc(V(tags.SentDate));
        end;
      end;

      if (tags.Rcvd <> '') and (V(tags.Rcvd) <> '') then
      begin
        st := AdifToQslStatus(V(tags.Rcvd), qdReceived);
        if st <> qsNone then
        begin
          m := AMedium;
          if AMedium = qmPaper then
            m := QslMediumFromVia(V('QSL_RCVD_VIA'));
          q := entry.AddQsl(m, qdReceived);
          q.Status := st;
          if tags.RcvdDate <> '' then
            q.DateUtc := AdifDateToUtc(V(tags.RcvdDate));
        end;
      end;
    end;

  begin
    if (entry = nil) or (qslVals.Count = 0) then Exit;
    OneMedium(qmPaper);
    OneMedium(qmLotw);
    OneMedium(qmEqsl);
    OneMedium(qmClubLog);
    OneMedium(qmQrz);
  end;

  procedure CloseRecord;
  begin
    if entry <> nil then
    begin
      FlushQsl;
      { 取り込みは 1 版目として確定させる。ここで Revision を 1 に
        しておくと、まだ一度も同期していないことが NeedsSync で
        正しく出る (§13.3)。 }
      entry.Touch;
      Inc(Result);
    end;
    entry := nil;
    qslVals.Clear;
  end;

begin
  Result := 0;
  buf := AText;
  if Trim(buf) = '' then Exit;
  lowBuf := LowerCase(buf);

  { ヘッダがあれば本体はその後ろ。無ければ先頭から。 }
  p := Pos('<eoh>', lowBuf);
  if p > 0 then
    p := p + 5
  else
    p := 1;

  p := PosEx('<', buf, p);
  if p = 0 then Exit;

  entry := nil;
  qslVals := TStringList.Create;
  try
    ptr := p;
    while ptr > 0 do
    begin
      tagStart := ptr + 1;
      gtPos := PosEx('>', buf, tagStart);
      if gtPos = 0 then Break;

      colonPos := PosEx(':', buf, tagStart);
      nextPtr := PosEx('<', buf, ptr + 1);

      if (colonPos > 0) and (colonPos < gtPos) then
      begin
        tag := UpperCase(Trim(Copy(buf, tagStart, colonPos - tagStart)));
        { <TAG:len> と <TAG:len:type> の両方。型指示子は保たない。 }
        tagEnd := PosEx(':', buf, colonPos + 1);
        if (tagEnd > 0) and (tagEnd < gtPos) then
          fldSize := StrToIntDef(
            Copy(buf, colonPos + 1, tagEnd - colonPos - 1), -1)
        else
          fldSize := StrToIntDef(
            Copy(buf, colonPos + 1, gtPos - colonPos - 1), -1);

        if fldSize >= 0 then
        begin
          valStr := Copy(buf, gtPos + 1, fldSize);
          if tag <> '' then
          begin
            EnsureEntry;
            if IsQslOwnedTag(tag) then
              qslVals.Values[tag] := valStr
            else
            begin
              key := AdifTagToModelKey(tag);
              { 未知のタグもここに載る。これが本ユニットの存在理由である。 }
              fld.Value       := valStr;
              fld.Origin      := foImported;
              fld.State       := fsConfirmed;
              fld.Evidence    := 0;
              fld.HasEvidence := False;
              entry.Fields.PutField(key, fld);
            end;
          end;
          { 値の中の '<' をタグと誤認しないよう、長さ分だけ確実に飛ばす。 }
          nextPtr := PosEx('<', buf, gtPos + 1 + fldSize);
        end;
      end
      else
      begin
        { 長さを持たないタグ。<EOR> と <EOH> だけが該当する。 }
        tag := UpperCase(Trim(Copy(buf, tagStart, gtPos - tagStart)));
        if tag = 'EOR' then
          CloseRecord;
      end;

      ptr := nextPtr;
    end;
    { <EOR> で終わっていないファイルでも最後のレコードを失わない。 }
    CloseRecord;
  finally
    qslVals.Free;
  end;
end;

function LoadAdifFileToStore(const AFileName: string;
  AStore: TQsoStore): Integer;
begin
  if not FileExists(AFileName) then
    raise EQsoAdifError.CreateFmt(
      'ADIF ファイルが見つかりません: %s', [AFileName]);
  { 生バイトで読む。TStringList 経由だと改行が正規化され、値に改行を
    含む NOTES/COMMENT で長さがずれて以降を全部誤って切り出す。 }
  Result := AdifTextToStore(LoadTextRaw(AFileName), AStore);
end;

{ ---------------------------------------------------------------------------
  既存の TAdifRecord との橋渡し (61 項目に収まるものだけ)
  --------------------------------------------------------------------------- }

procedure EntryToAdifRecord(AEntry: TQsoEntry; ARec: TAdifRecord);
var
  k, idOrd: Integer;
  f: TQsoField;
begin
  ARec.ClearRec;
  for k := 0 to AEntry.Fields.Count - 1 do
  begin
    f := AEntry.Fields.FieldAt(k);
    if f.Value = '' then Continue;
    idOrd := FieldIdFromTag(ModelKeyToAdifTag(AEntry.Fields.KeyAt(k)));
    if idOrd >= 0 then
      ARec.PutField(TAdifFieldId(idOrd), f.Value);
  end;
end;

procedure AdifRecordToEntry(ARec: TAdifRecord; AEntry: TQsoEntry);
var
  id: TAdifFieldId;
  fld: TQsoField;
begin
  for id := Low(TAdifFieldId) to High(TAdifFieldId) do
  begin
    if ARec[id] = '' then Continue;
    fld.Value       := ARec[id];
    fld.Origin      := foImported;
    fld.State       := fsConfirmed;
    fld.Evidence    := 0;
    fld.HasEvidence := False;
    AEntry.Fields.PutField(AdifTagToModelKey(AdifFieldTags[id]), fld);
  end;
end;

function AdifRecordDropCount(AEntry: TQsoEntry): Integer;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to AEntry.Fields.Count - 1 do
  begin
    if AEntry.Fields.FieldAt(k).Value = '' then Continue;
    if FieldIdFromTag(ModelKeyToAdifTag(AEntry.Fields.KeyAt(k))) < 0 then
      Inc(Result);
  end;
end;

end.
