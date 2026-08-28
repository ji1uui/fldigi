{ ============================================================================
  DxccDatabase.pas

  AD1C 形式の cty.dat (国別コールサインプリフィクス・データベース) を解析し、
  コールサインから DXCC エンティティ名・CQ Zone・ITU Zone・大陸・緯度経度・
  GMTオフセットを引く機能を Lazarus/FPC へ移植したユニット。fldigi の
  DXCC/Zone 判定エンジン (`src/misc/dxcc.cxx`) に相当する。ContestLog.pas の
  COUNTRY/CQZ/ITUZ/CONT フィールド自動補完、および将来の CallsignLookup.pas
  でも共通基盤として利用する想定のため、コンテスト機能から独立した単体
  ユニットとして切り出した。

  fldigi との対応:
    fldigi (C++)                                  | Lazarus (Pascal)
    --------------------------------------------------+---------------------------
    struct dxcc (dxcc.h)                             | TDxccEntry (本ユニット)
    dxcc_open()/dxcc_close()/dxcc_is_open()          | TDxccDatabase.LoadFromFile/
      (cty.dat をパースし cmap<string,dxcc*> へ登録)    Clear/IsOpen
    dxcc_lookup() (完全一致 "=CALL" → 最長プリフィクス一致) | TDxccDatabase.Lookup
    add_prefix() ((cq)[itu]<lat/lon>および｛cont｝修飾子の解析)  | AddPrefix (private)
    dxcc_entity_list()                               | EntityCount/Entity[]
    src/logbook/cty-dat.cxx の s_ctydat               | (下記「設計方針 1」参照。
      (内蔵フォールバック用 cty.dat 全文字列 約1300行)      本移植版では埋め込まない)

  設計方針・fldigiからの相違点:
  ----------------------------------------------------------------------------
  1. **内蔵フォールバックデータ (s_ctydat) は移植しない**: fldigi は
     cty.dat が見つからない場合に備え、ソースコード中に当時最新版の
     cty.dat 全文 (約1300行、300以上のDXCCエンティティ) を文字列リテラル
     として埋め込んでいる。これは「ロジック」ではなく随時更新される
     「データ」であり、本アプリは新規開発であってfldigiの翻訳ではない
     という方針から、本ユニットには埋め込まない。運用者は
     https://www.country-files.com/ (fldigi と同じ配布元、AD1C氏が
     月次更新) から最新の cty.dat をダウンロードし、`LoadFromFile` で
     読み込む運用とする。ファイルが見つからない/未ロードの場合、
     `IsOpen` は False を返し、呼び出し側 (ContestLog.pas の
     国名バリデーション等) は fldigi の `country_test()` 同様「DXCCデータ
     未ロード時は無条件で有効とみなす」フォールバック動作を取ること。

  2. **連想配列は Generics.Collections.TDictionary を使用**: 実際の
     cty.dat は例外コールサイン (`=AA0O(5)[8]` 等) を含めると数万件の
     プリフィクス/完全一致キーを持つ。他ユニット (AdifFile.pas 等) は
     フィールド数が高々60個程度のため単純な配列・線形探索で十分だが、
     本ユニットは規模が2桁以上大きいため、O(1)平均のハッシュマップ
     (`specialize TDictionary<string, TDxccEntry>`) を採用した
     (FPC 3.2.2 で objfpc モードでも `Generics.Collections` は
     問題なく使用できることを確認済み)。

  3. **エンティティ本体と例外用クローンを別リストで所有**: fldigi の
     add_prefix() は `(cq)[itu]<lat/lon>｛cont｝` 等の修飾子が付いた
     プリフィクスに対して `new dxcc(*entry)` で複製 (クローン) を作る。
     `dxcc_entity_list()` (=国名一覧・国名部分一致検索用) は
     レコード単位 (cty.dat の1エントリにつき1個) の「基底エンティティ」
     のみを返し、例外用クローンは含まない。本移植版もこれを忠実に
     踏襲し、`FBaseEntities` (=EntityCount/Entity[] で公開する基底
     エンティティ一覧) と `FExceptionEntities` (プリフィクス検索専用の
     クローン、一覧には出さないがメモリ解放は本クラスが責任を持つ) を
     分けて保持する。

  4. **"United States"→"USA" の別名エンティティ**: fldigi は
     "United States" レコードを読んだ際、国名検索の利便性のために
     ("USA" と入力しても見つかるように) 同じZone/大陸情報を持つ
     国名だけ異なる別エンティティをもう1つ `dxcc_entity_list()` 側にだけ
     追加する (プリフィクス側は本家 "United States" を指したまま)。
     本移植版もこの挙動をそのまま踏襲している。
  ============================================================================ }
unit DxccDatabase;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Generics.Collections;

type
  { TDxccEntry
    ---------------------------------------------------------------------
    fldigi: struct dxcc (dxcc.h) に相当。1個のDXCCエンティティ (または
    その例外プリフィクス用クローン) の情報を保持する。 }
  TDxccEntry = class
  public
    Country: string;      // dxcc::country
    CqZone: Integer;       // dxcc::cq_zone
    ItuZone: Integer;      // dxcc::itu_zone
    Continent: string;     // dxcc::continent (2文字、例: "EU" "NA" "AS")
    Latitude: Double;      // dxcc::latitude
    Longitude: Double;     // dxcc::longitude (cty.dat の慣習で西経が正)
    GmtOffset: Double;     // dxcc::gmt_offset
    constructor Create(const ACountry: string; ACqZone, AItuZone: Integer;
      const AContinent: string; ALatitude, ALongitude, AGmtOffset: Double);
    { fldigi: dxcc::dxcc(const dxcc&) 相当のコピー (add_prefix() の
      修飾子付きプリフィクス用クローン生成に使う)。 }
    function Clone: TDxccEntry;
  end;

  { TDxccDatabase
    ---------------------------------------------------------------------
    fldigi: dxcc.cxx のモジュールレベル関数群 (dxcc_open/dxcc_lookup/…)
    に相当する機能をクラスにまとめたもの。 }
  TDxccDatabase = class
  private
    FBaseEntities: specialize TObjectList<TDxccEntry>;      // dxcc_entity_list() 相当
    FExceptionEntities: specialize TObjectList<TDxccEntry>; // 修飾子付きプリフィクス用クローン (所有のみ)
    FPrefixMap: specialize TDictionary<string, TDxccEntry>; // cmap 相当 (値は借用参照、所有しない)
    FLoaded: Boolean;
    procedure AddPrefix(const AToken: string; ABaseEntry: TDxccEntry);
    procedure ParseRecord(const ARecordText: string);
  public
    constructor Create;
    destructor Destroy; override;

    { fldigi: dxcc_open(const char* filename)
      cty.dat ファイルを読み込む。既に読み込み済みの内容は破棄する
      (fldigi の dxcc_open は多重ロードを弾くが、本移植版は
      reload_cty_dat() 相当の「常に洗い替え」の方が単体テストや
      設定変更後の再読込に便利なため、都度 Clear してから読み直す)。
      戻り値: 1件以上読み込めれば True。 }
    function LoadFromFile(const AFileName: string): Boolean;
    { ファイルではなく文字列から直接読み込む (単体テスト用)。 }
    function LoadFromString(const AData: string): Boolean;

    { fldigi: dxcc_close() }
    procedure Clear;

    { fldigi: dxcc_is_open() }
    function IsOpen: Boolean;

    { fldigi: dxcc_lookup(const char* callsign)
      完全一致 ("=CALL" 形式) → 見つからなければ最長プリフィクス一致、
      の順に検索する。KG4 (グアンタナモ米軍基地/米本土) の特例判定も
      fldigi と同じロジックで再現している。見つからなければ nil。
      戻り値は本データベースが所有する参照であり、呼び出し側で
      Free してはならない。 }
    function Lookup(const ACallsign: string): TDxccEntry;

    { fldigi: dxcc_entity_list() の全走査に相当 (基底エンティティのみ、
      例外クローンは含まない)。 }
    function EntityCount: Integer;
    function Entity(AIndex: Integer): TDxccEntry;

    { fldigi: contest.cxx country_test() の中核ロジック (国名一覧を
      前方一致ではなく部分一致で検索し、最初に見つかった正式国名を返す)
      をこのユニット側の責務として切り出したもの。
      見つかれば正式国名 (Country) を返し、見つからなければ空文字。 }
    function FindCountryByFragment(const AFragment: string): string;

    { fldigi: dxcc_open() が組み立てる cbolist (国名一覧、大文字小文字を
      無視してソート済み、'|' 区切り) に相当。UI のコンボボックス等で
      使うことを想定。 }
    function CountryNames: string;

    property Loaded: Boolean read FLoaded;
  end;

implementation

{ ============================================================================
  TDxccEntry
  ============================================================================ }

constructor TDxccEntry.Create(const ACountry: string; ACqZone, AItuZone: Integer;
  const AContinent: string; ALatitude, ALongitude, AGmtOffset: Double);
begin
  inherited Create;
  Country := ACountry;
  CqZone := ACqZone;
  ItuZone := AItuZone;
  Continent := Copy(AContinent, 1, 2);
  Latitude := ALatitude;
  Longitude := ALongitude;
  GmtOffset := AGmtOffset;
end;

function TDxccEntry.Clone: TDxccEntry;
begin
  Result := TDxccEntry.Create(Country, CqZone, ItuZone, Continent,
    Latitude, Longitude, GmtOffset);
end;

{ ============================================================================
  TDxccDatabase
  ============================================================================ }

constructor TDxccDatabase.Create;
begin
  inherited Create;
  FBaseEntities := specialize TObjectList<TDxccEntry>.Create(True);
  FExceptionEntities := specialize TObjectList<TDxccEntry>.Create(True);
  FPrefixMap := specialize TDictionary<string, TDxccEntry>.Create;
  FLoaded := False;
end;

destructor TDxccDatabase.Destroy;
begin
  FPrefixMap.Free;
  FExceptionEntities.Free; // OwnsObjects=True によりクローンも解放される
  FBaseEntities.Free;      // OwnsObjects=True により基底エンティティも解放される
  inherited Destroy;
end;

procedure TDxccDatabase.Clear;
begin
  FPrefixMap.Clear;
  FExceptionEntities.Clear;
  FBaseEntities.Clear;
  FLoaded := False;
end;

function TDxccDatabase.IsOpen: Boolean;
begin
  Result := FLoaded;
end;

{ 文字列 S 内の丸カッコ開始・角カッコ開始・山カッコ開始・波カッコ開始の
  4種の修飾子開始記号のうち、AFrom 以降で最初に現れる位置を返す
  (fldigi: add_prefix() の prefix.find_first_of(...) に相当)。
  見つからなければ 0。 }
function FirstBracketPos(const S: string; AFrom: SizeInt): SizeInt;
var
  p1, p2, p3, p4: SizeInt;
begin
  p1 := PosEx('(', S, AFrom);
  p2 := PosEx('[', S, AFrom);
  p3 := PosEx('<', S, AFrom);
  p4 := PosEx('{', S, AFrom);
  Result := 0;
  if p1 > 0 then Result := p1;
  if (p2 > 0) and ((Result = 0) or (p2 < Result)) then Result := p2;
  if (p3 > 0) and ((Result = 0) or (p3 < Result)) then Result := p3;
  if (p4 > 0) and ((Result = 0) or (p4 < Result)) then Result := p4;
end;

procedure TDxccDatabase.AddPrefix(const AToken: string; ABaseEntry: TDxccEntry);
{ fldigi: add_prefix(std::string& prefix, dxcc* entry)
  修飾子が無ければ ABaseEntry をそのままキーに関連付ける (複製しない・
  共有参照)。修飾子があればクローンを1つ作り、すべての修飾子グループを
  順に適用してからキー (先頭の修飾子より前の部分。"=" が付いている場合は
  それも含む) に関連付ける。 }
var
  bracketPos, closePos, slashPos, i: SizeInt;
  key: string;
  entry: TDxccEntry;
  fmt: TFormatSettings;
begin
  fmt := DefaultFormatSettings;
  fmt.DecimalSeparator := '.';

  bracketPos := FirstBracketPos(AToken, 1);
  if bracketPos = 0 then
  begin
    FPrefixMap.AddOrSetValue(AToken, ABaseEntry);
    Exit;
  end;

  entry := ABaseEntry.Clone;
  FExceptionEntities.Add(entry);

  i := bracketPos;
  while i > 0 do
  begin
    case AToken[i] of
      '(':
        begin
          closePos := PosEx(')', AToken, i + 1);
          if closePos = 0 then Break;
          entry.CqZone := StrToIntDef(Copy(AToken, i + 1, closePos - i - 1), entry.CqZone);
          i := closePos + 1;
        end;
      '[':
        begin
          closePos := PosEx(']', AToken, i + 1);
          if closePos = 0 then Break;
          entry.ItuZone := StrToIntDef(Copy(AToken, i + 1, closePos - i - 1), entry.ItuZone);
          i := closePos + 1;
        end;
      '<':
        begin
          slashPos := PosEx('/', AToken, i + 1);
          closePos := PosEx('>', AToken, i + 1);
          if (slashPos = 0) or (closePos = 0) or (slashPos > closePos) then Break;
          entry.Latitude := StrToFloatDef(Copy(AToken, i + 1, slashPos - i - 1), entry.Latitude, fmt);
          entry.Longitude := StrToFloatDef(Copy(AToken, slashPos + 1, closePos - slashPos - 1), entry.Longitude, fmt);
          i := closePos + 1;
        end;
      '{':
        begin
          closePos := PosEx('}', AToken, i + 1);
          if closePos = 0 then Break;
          entry.Continent := Copy(AToken, i + 1, closePos - i - 1);
          i := closePos + 1;
        end;
    else
      Break;
    end;
    i := FirstBracketPos(AToken, i);
  end;

  key := Copy(AToken, 1, bracketPos - 1);
  FPrefixMap.AddOrSetValue(key, entry);
end;

procedure TDxccDatabase.ParseRecord(const ARecordText: string);
{ fldigi: dxcc_open() の while(getline(in,record,';')) ループ本体1回分。
  ARecordText は ';' で区切られた1レコード分の生テキスト
  (末尾の ';' 自身は含まない)。 }
var
  chunk, headerLine, tail: string;
  nlPos, colonPos, startPos, tokenStart, commaPos: SizeInt;
  parts: array[0..7] of string;
  partCount: Integer;
  entry: TDxccEntry;
  cq, itu: Integer;
  lat, lon, gmt: Double;
  fmt: TFormatSettings;
  tok: string;
begin
  chunk := TrimLeft(ARecordText);
  if chunk = '' then Exit;

  { ヘッダ行 (国名:CQ:ITU:大陸:緯度:経度:GMT:主プリフィクス:) と、
    それ以降のプリフィクス/例外リスト部分 (tail) に分割する。
    主プリフィクスフィールドは fldigi 同様パースせず読み捨てる
    (dxcc_open(): (is >> entry->gmt_offset).ignore(256, '\n') が
    行末までスキップしているのと同じ)。 }
  nlPos := Pos(#10, chunk);
  if nlPos = 0 then
  begin
    headerLine := chunk;
    tail := '';
  end
  else
  begin
    headerLine := Copy(chunk, 1, nlPos - 1);
    tail := Copy(chunk, nlPos + 1, MaxInt);
  end;

  partCount := 0;
  startPos := 1;
  colonPos := Pos(':', headerLine);
  while (colonPos > 0) and (partCount < 8) do
  begin
    parts[partCount] := Trim(Copy(headerLine, startPos, colonPos - startPos));
    Inc(partCount);
    startPos := colonPos + 1;
    colonPos := PosEx(':', headerLine, startPos);
  end;
  if partCount < 7 then Exit; { フィールド不足の壊れたレコードは無視する }

  fmt := DefaultFormatSettings;
  fmt.DecimalSeparator := '.';
  cq := StrToIntDef(parts[1], 0);
  itu := StrToIntDef(parts[2], 0);
  lat := StrToFloatDef(parts[4], 0.0, fmt);
  lon := StrToFloatDef(parts[5], 0.0, fmt);
  gmt := StrToFloatDef(parts[6], 0.0, fmt);

  entry := TDxccEntry.Create(parts[0], cq, itu, parts[3], lat, lon, gmt);
  FBaseEntities.Add(entry);

  { fldigi: dxcc_open() の「"United States" なら "USA" という別名の
    エンティティも国名一覧に追加する」特例処理をそのまま踏襲。 }
  if parts[0] = 'United States' then
    FBaseEntities.Add(TDxccEntry.Create('USA', cq, itu, parts[3], lat, lon, gmt));

  { tail (プリフィクス/例外リスト、複数行にまたがる場合あり) を ','
    区切りで走査する。改行はトークンの前後空白として Trim で除去される
    ため、複数行にまたがっていても単純な ',' 分割で正しく処理できる。 }
  tokenStart := 1;
  commaPos := PosEx(',', tail, tokenStart);
  while True do
  begin
    if commaPos = 0 then
      tok := Trim(Copy(tail, tokenStart, MaxInt))
    else
      tok := Trim(Copy(tail, tokenStart, commaPos - tokenStart));
    if tok <> '' then
      AddPrefix(tok, entry);
    if commaPos = 0 then Break;
    tokenStart := commaPos + 1;
    commaPos := PosEx(',', tail, tokenStart);
  end;
end;

function TDxccDatabase.LoadFromString(const AData: string): Boolean;
var
  buf: string;
  startPos, semiPos: SizeInt;
begin
  Clear;
  buf := StringReplace(AData, #13, '', [rfReplaceAll]);

  startPos := 1;
  semiPos := Pos(';', buf);
  while semiPos > 0 do
  begin
    ParseRecord(Copy(buf, startPos, semiPos - startPos));
    startPos := semiPos + 1;
    semiPos := PosEx(';', buf, startPos);
  end;

  FLoaded := FBaseEntities.Count > 0;
  Result := FLoaded;
end;

function TDxccDatabase.LoadFromFile(const AFileName: string): Boolean;
var
  sl: TStringList;
  buf: string;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    buf := sl.Text;
  finally
    sl.Free;
  end;
  Result := LoadFromString(buf);
end;

function TDxccDatabase.Lookup(const ACallsign: string): TDxccEntry;
{ fldigi: dxcc_lookup(const char* callsign) }
var
  s: string;
  len: SizeInt;
begin
  Result := nil;
  if (not FLoaded) or (Trim(ACallsign) = '') then Exit;

  s := UpperCase(Trim(ACallsign));

  { 完全一致 (cty.dat 上で "=CALL" と記載された例外コールサイン) を優先。 }
  if FPrefixMap.TryGetValue('=' + s, Result) then Exit;

  { fldigi: KG4 特例。2文字サフィックスの KG4xx (計5文字) のみ
    グアンタナモ米軍基地 (KG4 エントリ) として扱い、それ以外の桁数
    (KG4x=4文字, KG4xxx=6文字等) は通常の米本土 "K" として扱う。 }
  if (Pos('KG4', s) > 0) and ((Length(s) = 4) or (Length(s) = 6)) then
    s := 'K';

  len := Length(s);
  while len > 0 do
  begin
    if FPrefixMap.TryGetValue(Copy(s, 1, len), Result) then Exit;
    Dec(len);
  end;
  Result := nil;
end;

function TDxccDatabase.EntityCount: Integer;
begin
  Result := FBaseEntities.Count;
end;

function TDxccDatabase.Entity(AIndex: Integer): TDxccEntry;
begin
  Result := FBaseEntities[AIndex];
end;

function TDxccDatabase.FindCountryByFragment(const AFragment: string): string;
{ fldigi: contest.cxx country_test()
  国名一覧に対する部分一致検索 (前方一致ではない)。最初に見つかった
  正式国名を返す。見つからなければ空文字。 }
var
  i: Integer;
  frag: string;
begin
  Result := '';
  frag := UpperCase(Trim(AFragment));
  if frag = '' then Exit;
  for i := 0 to FBaseEntities.Count - 1 do
    if Pos(frag, UpperCase(FBaseEntities[i].Country)) > 0 then
    begin
      Result := FBaseEntities[i].Country;
      Exit;
    end;
end;

function TDxccDatabase.CountryNames: string;
var
  names: TStringList;
  i: Integer;
begin
  names := TStringList.Create;
  try
    names.CaseSensitive := False;
    names.Sorted := True;
    names.Duplicates := dupAccept;
    for i := 0 to FBaseEntities.Count - 1 do
      names.Add(FBaseEntities[i].Country);
    Result := '';
    for i := 0 to names.Count - 1 do
    begin
      if i > 0 then Result := Result + '|';
      Result := Result + names[i];
    end;
  finally
    names.Free;
  end;
end;

end.
