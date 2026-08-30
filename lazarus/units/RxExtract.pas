{ ============================================================================
  RxExtract.pas

  復号された受信テキストから、交信に必要な値 (相手のコールサイン・RST・
  送信ナンバー・グリッドロケータ) を取り出す。

  なぜ必要か:
  ----------------------------------------------------------------------------
  MacroEngine の局面モデルは「値が入れば局面が自動で進む」形にしてある。
  ctx.Call を入れれば「コール取得」へ、ctx.RstRcvd/SerialIn を入れれば
  「交換受領」へ進み、ExecuteForSequence が次に送るものを返す。
  ところが値を入れるのは運用者の手入力だけだった。つまり
  「入力側が空いたまま」で、せっかくの局面駆動が働き始めなかった。
  本ユニットがその入力側を埋める。

  設計方針:
  ----------------------------------------------------------------------------
  1. 抽出と確定を分ける
     RTTY や CW の復号は誤りを含む。誤ったコールサインを送れば
     交信そのものが無効になるので、**既定では候補を出すだけ**にして、
     どれを採用するかは運用者が決める。自動採用は確信度のしきい値を
     明示的に指定したときだけ行う。

  2. 送信はしない
     本ユニットは値を取り出すところまでで、マクロの自動起動はしない。
     受信内容をきっかけに自動送信するのは「自動運用」の領域であり、
     アマチュア無線では送信の責任が運用者にある。境界をここに引く。

  3. 確信度を返す
     「JA1ZZZ らしきものがあった」だけでは使えない。de の直後にあるか、
     2回繰り返されているか、直近か、といった根拠を点数にして返す。
     運用者が候補を選ぶときの並び順にもなる。

  fldigi との対応:
  ----------------------------------------------------------------------------
  fldigi の rx_extract.cxx は「受信テキストをファイルに保存する」機能で、
  値の抽出はしていない。コールサインの取得は受信ウィンドウ上で
  運用者がダブルクリックする方式 (fl_digi.cxx)。
  本ユニットはそれを自動候補提示に置き換えるもので、fldigi に前例がない。
  ============================================================================ }
unit RxExtract;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, StrUtils, MacroEngine;

type
  ERxExtractError = class(Exception);

  TRxTokenKind = (
    rtkCallsign,   // 相手のコールサイン
    rtkRst,        // RST レポート
    rtkSerial,     // 送信ナンバー
    rtkLocator     // グリッドロケータ
  );

  { 抽出した候補 1 件。 }
  TRxCandidate = record
    Kind: TRxTokenKind;
    Text: string;        // 正規化済み (カットナンバーを数字に戻したもの)
    RawText: string;     // 受信されたそのままの文字列
    Confidence: Integer; // 0..100
    Position: Integer;   // バッファ内の位置 (大きいほど新しい)
  end;
  TRxCandidateArray = array of TRxCandidate;

  { TRxExtractor
    ---------------------------------------------------------------------
    復号文字を流し込み、直近のテキストから候補を取り出す。 }
  TRxExtractor = class
  private
    FBuffer: string;
    FBufferLimit: Integer;
    FMyCallsign: string;
    FMinConfidence: Integer;
    procedure Trim_;
  public
    constructor Create;

    { 復号結果を流し込む。 }
    procedure Feed(const AText: string);
    { 1 文字ずつ流し込む (TModemUI.OnRxChar から直接つなぐ用)。 }
    procedure FeedChar(ACh: Integer);
    procedure Clear;

    { 候補を確信度の高い順に返す。 }
    function Candidates(AKind: TRxTokenKind): TRxCandidateArray;
    { 最有力の候補を返す。無ければ False。 }
    function BestCandidate(AKind: TRxTokenKind;
      out ACandidate: TRxCandidate): Boolean;

    { 自局が呼ばれているか (受信テキストに自局コールが現れたか)。 }
    function IsBeingCalled: Boolean;

    { 候補 1 件をコンテキストへ書き込む (運用者が選んだときに使う)。
      戻り値: 書き込んだか。 }
    function ApplyCandidate(const ACandidate: TRxCandidate;
      ACtx: TMacroContext): Boolean;

    { MinConfidence 以上の候補をまとめて書き込む。
      戻り値: 書き込んだ件数。
      既に値が入っている項目は上書きしない (運用者が手で直した値を
      あとから来た受信で壊さないため)。 }
    function ApplyTo(ACtx: TMacroContext): Integer;

    { 直近の受信テキスト。 }
    property Buffer: string read FBuffer;
    { 保持する文字数 (既定 512)。古いものから捨てる。 }
    property BufferLimit: Integer read FBufferLimit write FBufferLimit;
    { 自局コールサイン。候補から除外し、呼ばれ判定にも使う。 }
    property MyCallsign: string read FMyCallsign write FMyCallsign;
    { ApplyTo が採用する確信度のしきい値 (既定 70)。 }
    property MinConfidence: Integer read FMinConfidence write FMinConfidence;
  end;

{ コールサインとして成立しうる形か。
  形式が正しいかを見るだけで、実在するかは判定しない。 }
function IsPlausibleCallsign(const AText: string): Boolean;

{ CW コンテストのカットナンバーを数字へ戻す (T -> 0, N -> 9)。
  MacroEngine.ToCutNumbers の逆変換。 }
function FromCutNumbers(const AText: string): string;

{ RST として成立しうる形か (599 / 59 / 5NN 等)。 }
function IsPlausibleRst(const AText: string): Boolean;

{ グリッドロケータとして成立しうる形か (PM95 / PM95ul)。 }
function IsPlausibleLocator(const AText: string): Boolean;

implementation

const
  DEFAULT_BUFFER_LIMIT = 512;
  DEFAULT_MIN_CONFIDENCE = 70;
  { 推定で到達しうる確信度の上限。 }
  MAX_HEURISTIC_CONFIDENCE = 95;

  { よく流れる定型語。コールサインの形に見えることがあるので明示的に外す。 }
  COMMON_WORDS: array[0..15] of string = (
    'CQ', 'DE', 'TEST', 'TU', 'QRZ', 'AGN', 'PSE', 'TNX', 'HW', 'UR',
    'RST', 'QTH', 'NAME', 'QSL', 'SK', 'BK');

function FromCutNumbers(const AText: string): string;
var
  i: Integer;
begin
  Result := UpperCase(AText);
  for i := 1 to Length(Result) do
    case Result[i] of
      'T': Result[i] := '0';
      'N': Result[i] := '9';
    end;
end;

function IsUpperLetter(C: Char): Boolean;
begin
  Result := (C >= 'A') and (C <= 'Z');
end;

function IsDigitCh(C: Char): Boolean;
begin
  Result := (C >= '0') and (C <= '9');
end;

function IsCommonWord(const AText: string): Boolean;
var
  i: Integer;
begin
  for i := Low(COMMON_WORDS) to High(COMMON_WORDS) do
    if COMMON_WORDS[i] = AText then
      Exit(True);
  Result := False;
end;

function IsCallsignCore(const AText: string): Boolean;
{ 付加記号 (/1, /P 等) を外した本体が成立するか。

  構造: 前置符号 + エリア数字 + 接尾符号
    前置符号 1..3 文字 (英数字。英字を1文字以上含む)   JA / 7J / 3DA / K
    エリア数字 1 文字
    接尾符号 1..4 文字 (英字のみ)                      ZZZ / AW / ABCD

  「エリア数字」は「そのあとが英字だけで 1..4 文字続く最後の数字」として
  求める。こうすると 3DA0AB (前置 3DA) や 7J1ABC (前置 7J) も通り、
  599 や 5NN のような数字だけ・英字だけの語は落ちる。 }
var
  i, areaPos, n: Integer;
  prefix, suffix: string;
  hasLetter: Boolean;
begin
  Result := False;
  n := Length(AText);
  if (n < 3) or (n > 10) then Exit;

  areaPos := 0;
  for i := n downto 2 do
    if IsDigitCh(AText[i]) then
    begin
      areaPos := i;
      Break;
    end;
  if areaPos = 0 then Exit;

  prefix := Copy(AText, 1, areaPos - 1);
  suffix := Copy(AText, areaPos + 1, MaxInt);

  if (Length(prefix) < 1) or (Length(prefix) > 3) then Exit;
  if (Length(suffix) < 1) or (Length(suffix) > 4) then Exit;

  hasLetter := False;
  for i := 1 to Length(prefix) do
  begin
    if IsUpperLetter(prefix[i]) then
      hasLetter := True
    else if not IsDigitCh(prefix[i]) then
      Exit;
  end;
  if not hasLetter then Exit;

  for i := 1 to Length(suffix) do
    if not IsUpperLetter(suffix[i]) then
      Exit;

  Result := True;
end;

function IsPlausibleCallsign(const AText: string): Boolean;
var
  t, core, part: string;
  slash1, slash2: Integer;
begin
  Result := False;
  t := UpperCase(Trim(AText));
  if t = '' then Exit;
  if IsCommonWord(t) then Exit;

  slash1 := Pos('/', t);
  if slash1 = 0 then
    Exit(IsCallsignCore(t));

  { 前置形式 (VP2E/W1AW) と後置形式 (JA1ZZZ/1, JI1UUI/P) の両方を許す。
    どちらか一方が本体として成立していればよい。 }
  core := Copy(t, 1, slash1 - 1);
  part := Copy(t, slash1 + 1, MaxInt);

  slash2 := Pos('/', part);
  if slash2 > 0 then
    part := Copy(part, 1, slash2 - 1);   { JA1ZZZ/QRP/P のような多重は先頭まで }

  if IsCallsignCore(core) and (Length(part) >= 1) and (Length(part) <= 4) then
    Exit(True);
  if IsCallsignCore(part) and (Length(core) >= 1) and (Length(core) <= 4) then
    Exit(True);
end;

function IsPlausibleRst(const AText: string): Boolean;
var
  t: string;
  i: Integer;
begin
  Result := False;
  t := FromCutNumbers(Trim(AText));
  if (Length(t) <> 2) and (Length(t) <> 3) then Exit;
  for i := 1 to Length(t) do
    if not IsDigitCh(t[i]) then Exit;
  { R は 1..5、S は 1..9、T は 1..9 }
  if (t[1] < '1') or (t[1] > '5') then Exit;
  if (t[2] < '1') or (t[2] > '9') then Exit;
  if (Length(t) = 3) and ((t[3] < '1') or (t[3] > '9')) then Exit;
  Result := True;
end;

function IsPlausibleLocator(const AText: string): Boolean;
var
  t: string;
begin
  Result := False;
  t := UpperCase(Trim(AText));
  if (Length(t) <> 4) and (Length(t) <> 6) then Exit;
  if not ((t[1] >= 'A') and (t[1] <= 'R')) then Exit;
  if not ((t[2] >= 'A') and (t[2] <= 'R')) then Exit;
  if not IsDigitCh(t[3]) then Exit;
  if not IsDigitCh(t[4]) then Exit;
  if Length(t) = 6 then
  begin
    if not ((t[5] >= 'A') and (t[5] <= 'X')) then Exit;
    if not ((t[6] >= 'A') and (t[6] <= 'X')) then Exit;
  end;
  Result := True;
end;

{ ============================ TRxExtractor ============================ }

constructor TRxExtractor.Create;
begin
  inherited Create;
  FBuffer := '';
  FBufferLimit := DEFAULT_BUFFER_LIMIT;
  FMinConfidence := DEFAULT_MIN_CONFIDENCE;
end;

procedure TRxExtractor.Trim_;
begin
  if FBufferLimit <= 0 then Exit;
  if Length(FBuffer) > FBufferLimit then
    FBuffer := Copy(FBuffer, Length(FBuffer) - FBufferLimit + 1, MaxInt);
end;

procedure TRxExtractor.Feed(const AText: string);
begin
  FBuffer := FBuffer + AText;
  Trim_;
end;

procedure TRxExtractor.FeedChar(ACh: Integer);
begin
  { 制御文字は空白扱いにする (改行やタブで語が繋がらないように)。 }
  if (ACh < 32) or (ACh > 126) then
    FBuffer := FBuffer + ' '
  else
    FBuffer := FBuffer + Chr(ACh);
  Trim_;
end;

procedure TRxExtractor.Clear;
begin
  FBuffer := '';
end;

type
  TRxToken = record
    Text: string;
    Position: Integer;
  end;
  TRxTokenArray = array of TRxToken;

function Tokenize(const ABuffer: string): TRxTokenArray;
{ 英数字と '/' を語の構成文字とみなす。それ以外は区切り。 }
var
  i, n, startPos: Integer;
  cur: string;

  procedure Flush(APos: Integer);
  begin
    if cur = '' then Exit;
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Text := cur;
    Result[n].Position := APos;
    cur := '';
  end;

begin
  Result := nil;
  cur := '';
  startPos := 1;
  for i := 1 to Length(ABuffer) do
  begin
    if IsUpperLetter(UpCase(ABuffer[i])) or IsDigitCh(ABuffer[i]) or
       (ABuffer[i] = '/') then
    begin
      if cur = '' then startPos := i;
      cur := cur + UpCase(ABuffer[i]);
    end
    else
      Flush(startPos);
  end;
  Flush(startPos);
end;

function LooksLikeSerial(const AText: string): Boolean;
{ 1..4 桁の数字 (カットナンバー表記を含む)。 }
var
  t: string;
  i: Integer;
begin
  Result := False;
  t := FromCutNumbers(Trim(AText));
  if (Length(t) < 1) or (Length(t) > 4) then Exit;
  for i := 1 to Length(t) do
    if not IsDigitCh(t[i]) then Exit;
  Result := True;
end;

function CountOccurrences(const ATokens: TRxTokenArray;
  const AText: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(ATokens) do
    if ATokens[i].Text = AText then
      Inc(Result);
end;

function TRxExtractor.Candidates(AKind: TRxTokenKind): TRxCandidateArray;
var
  tokens: TRxTokenArray;
  i, j, conf, lastIdx: Integer;
  t, myCall: string;
  ok: Boolean;
  tmp: TRxCandidate;

  procedure AddCand(const AText, ARaw: string; AConf, APos: Integer);
  var
    k, m: Integer;
  begin
    if AConf < 0 then AConf := 0;
    { 上限を 95 にとどめる。復号誤りがありうる以上、推定だけで
      「確実 (100)」を名乗るべきではない。100 は「運用者が確定した」
      という意味に残しておく。 }
    if AConf > MAX_HEURISTIC_CONFIDENCE then
      AConf := MAX_HEURISTIC_CONFIDENCE;
    { 同じ値が既にあれば確信度の高い方を残す }
    for k := 0 to High(Result) do
      if Result[k].Text = AText then
      begin
        if AConf > Result[k].Confidence then
        begin
          Result[k].Confidence := AConf;
          Result[k].Position := APos;
        end;
        Exit;
      end;
    m := Length(Result);
    SetLength(Result, m + 1);
    Result[m].Kind := AKind;
    Result[m].Text := AText;
    Result[m].RawText := ARaw;
    Result[m].Confidence := AConf;
    Result[m].Position := APos;
  end;

begin
  Result := nil;
  tokens := Tokenize(FBuffer);
  if Length(tokens) = 0 then Exit;
  lastIdx := High(tokens);
  myCall := UpperCase(Trim(FMyCallsign));

  for i := 0 to lastIdx do
  begin
    t := tokens[i].Text;
    ok := False;
    conf := 0;

    case AKind of
      rtkCallsign:
        begin
          if not IsPlausibleCallsign(t) then Continue;
          if (myCall <> '') and (t = myCall) then Continue;  { 自局は候補外 }
          ok := True;
          conf := 45;
          { de の直後は「送ってきた局のコール」= 最も確からしい }
          if (i > 0) and (tokens[i - 1].Text = 'DE') then
            Inc(conf, 30);
          { 自局コールのすぐ後ろの de に続く = 自分が呼ばれている }
          if (i >= 2) and (tokens[i - 1].Text = 'DE') and
             (myCall <> '') and (tokens[i - 2].Text = myCall) then
            Inc(conf, 15);
          { 繰り返し送られている (JA1ZZZ JA1ZZZ) }
          if CountOccurrences(tokens, t) >= 2 then
            Inc(conf, 15);
          { 直近ほど関係が深い }
          if i >= lastIdx - 3 then
            Inc(conf, 10);
        end;

      rtkRst:
        begin
          if not IsPlausibleRst(t) then Continue;
          ok := True;
          conf := 50;
          { rst / ur の直後 }
          if (i > 0) and ((tokens[i - 1].Text = 'RST') or
                          (tokens[i - 1].Text = 'UR')) then
            Inc(conf, 30);
          { 直後が数字 = コンテストの交換 (599 032) の形。
            これが最も多い形なので、拾えないと実用にならない。 }
          if (i < lastIdx) and LooksLikeSerial(tokens[i + 1].Text) then
            Inc(conf, 20);
          { 599 / 59 は圧倒的に多いレポート }
          if (FromCutNumbers(t) = '599') or (FromCutNumbers(t) = '59') then
            Inc(conf, 10);
          if CountOccurrences(tokens, t) >= 2 then
            Inc(conf, 15);
          if i >= lastIdx - 3 then
            Inc(conf, 10);
        end;

      rtkSerial:
        begin
          { RST の直後に来る 1..4 桁を送信ナンバーとみなす。
            単独の数字はバンド名や時刻など紛らわしいものが多いので、
            RST に隣接する場合だけを高い確信度で拾う。 }
          if i = 0 then Continue;
          if not IsPlausibleRst(tokens[i - 1].Text) then Continue;
          if not LooksLikeSerial(t) then Continue;
          t := FromCutNumbers(t);
          ok := True;
          conf := 75;
          if i >= lastIdx - 2 then
            Inc(conf, 15);
        end;

      rtkLocator:
        begin
          if not IsPlausibleLocator(t) then Continue;
          ok := True;
          conf := 70;
          if i >= lastIdx - 3 then
            Inc(conf, 15);
        end;
    end;

    if ok then
    begin
      if AKind = rtkRst then
        AddCand(FromCutNumbers(t), tokens[i].Text, conf, tokens[i].Position)
      else
        AddCand(t, tokens[i].Text, conf, tokens[i].Position);
    end;
  end;

  { 確信度の高い順、同点なら新しい順に並べる (件数が少ないので挿入ソート) }
  for i := 1 to High(Result) do
  begin
    tmp := Result[i];
    j := i - 1;
    while (j >= 0) and
          ((tmp.Confidence > Result[j].Confidence) or
           ((tmp.Confidence = Result[j].Confidence) and
            (tmp.Position > Result[j].Position))) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := tmp;
  end;
end;

function TRxExtractor.BestCandidate(AKind: TRxTokenKind;
  out ACandidate: TRxCandidate): Boolean;
var
  list: TRxCandidateArray;
begin
  list := Candidates(AKind);
  Result := Length(list) > 0;
  if Result then
    ACandidate := list[0];
end;

function TRxExtractor.IsBeingCalled: Boolean;
var
  tokens: TRxTokenArray;
  i: Integer;
  myCall: string;
begin
  Result := False;
  myCall := UpperCase(Trim(FMyCallsign));
  if myCall = '' then Exit;
  tokens := Tokenize(FBuffer);
  for i := 0 to High(tokens) do
    if tokens[i].Text = myCall then
      Exit(True);
end;

function TRxExtractor.ApplyCandidate(const ACandidate: TRxCandidate;
  ACtx: TMacroContext): Boolean;
begin
  Result := False;
  if ACtx = nil then
    raise ERxExtractError.Create('コンテキストが nil です');
  case ACandidate.Kind of
    rtkCallsign:
      begin
        ACtx.Call := ACandidate.Text;
        Result := True;
      end;
    rtkRst:
      begin
        ACtx.RstRcvd := ACandidate.Text;
        Result := True;
      end;
    rtkSerial:
      begin
        ACtx.SerialIn := ACandidate.Text;
        Result := True;
      end;
    rtkLocator:
      begin
        ACtx.Locator := ACandidate.Text;
        Result := True;
      end;
  end;
end;

function TRxExtractor.ApplyTo(ACtx: TMacroContext): Integer;

  function TryOne(AKind: TRxTokenKind; const AExisting: string): Boolean;
  var
    c: TRxCandidate;
  begin
    Result := False;
    if Trim(AExisting) <> '' then Exit;   { 手で入れた値は壊さない }
    if not BestCandidate(AKind, c) then Exit;
    if c.Confidence < FMinConfidence then Exit;
    Result := ApplyCandidate(c, ACtx);
  end;

begin
  if ACtx = nil then
    raise ERxExtractError.Create('コンテキストが nil です');
  Result := 0;
  if TryOne(rtkCallsign, ACtx.Call) then Inc(Result);
  if TryOne(rtkRst, ACtx.RstRcvd) then Inc(Result);
  if TryOne(rtkSerial, ACtx.SerialIn) then Inc(Result);
  if TryOne(rtkLocator, ACtx.Locator) then Inc(Result);
end;

end.
