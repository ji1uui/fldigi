{ ============================================================================
  MorseTable.pas

  fldigi の src/include/morse.h / src/cw_rtty/morse.cxx (class cMorse) を
  Lazarus/FPC 向けに移植したモールス符号テーブル。

  設計方針 (fldigi との対応):
    - CWstruct { enabled, chr, prt, rpr } をそのまま TCWEntry として再現。
    - cw_table[] はプロサイン9個 + A-Z + 0-9 + 句読点。
      fldigi はさらにウムラウト等のアクセント文字を持つが、
      progdefaults の既定値がすべて無効 (false) のため本移植版では
      テーブル自体に含めていない (必要になれば追加すればよい)。
    - rx_lookup(): ドット/ダッシュ文字列 → 印字文字
    - tx_lookup(): 文字コード → ドット/ダッシュ文字列
    - tx_length(): 文字の送信に要する「時間単位」数 (tc 単位)
      fldigi と同じ規則 (dot=2, dash=4, 文字間+2) を採用。
  ============================================================================ }
unit MorseTable;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  CW_DOT_REPRESENTATION = '.';
  CW_DASH_REPRESENTATION = '-';

type
  { fldigi: struct CWstruct (morse.h) }
  TCWEntry = record
    Enabled: Boolean;
    Chr_: string;   // fldigi: chr  (プロサイン用の代替表示文字含む)
    Prt: string;    // fldigi: prt  (印字表現)
    Rpr: string;    // fldigi: rpr  (ドット/ダッシュ表現)
  end;

  { TMorseTable
    ---------------------------------------------------------------------
    fldigi: class cMorse (morse.h/morse.cxx) }
  TMorseTable = class
  private
    FTable: array of TCWEntry;
    FToPrint: string; // fldigi: toprint (tx_lookup 後に tx_print() で取得)
    procedure BuildTable;
  public
    constructor Create;
    procedure Init;
    procedure Enable(const AKey: string; AValue: Boolean);
    { fldigi: std::string rx_lookup(std::string rx) }
    function RxLookup(const ARpr: string): string;
    { fldigi: std::string tx_lookup(int c) -- 1バイト文字専用に簡略化 }
    function TxLookup(AChar: Char): string;
    { fldigi: std::string tx_print() }
    function TxPrint: string;
    { fldigi: int tx_length(int c) }
    function TxLength(AChar: Char): Integer;
  end;

implementation

procedure TMorseTable.BuildTable;

  procedure Add(AEnabled: Boolean; const AChr, APrt, ARpr: string);
  var
    idx: Integer;
  begin
    idx := System.Length(FTable);
    SetLength(FTable, idx + 1);
    FTable[idx].Enabled := AEnabled;
    FTable[idx].Chr_ := AChr;
    FTable[idx].Prt := APrt;
    FTable[idx].Rpr := ARpr;
  end;

begin
  SetLength(FTable, 0);
  // Prosigns (fldigi: 既定 CW_prosigns = "=~<>%+&{}" 相当の代替文字)
  Add(True,  '=', '<BT>',  '-...-');
  Add(False, '~', '<AA>',  '.-.-');
  Add(True,  '<', '<AS>',  '.-...');
  Add(True,  '>', '<AR>',  '.-.-.');
  Add(True,  '%', '<SK>',  '...-.-');
  Add(True,  '+', '<KN>',  '-.--.');
  Add(True,  '&', '<INT>', '..-.-');
  Add(True,  '{', '<HM>',  '....--');
  Add(True,  '}', '<VE>',  '...-.');
  // 大文字
  Add(True, 'A', 'A', '.-');
  Add(True, 'B', 'B', '-...');
  Add(True, 'C', 'C', '-.-.');
  Add(True, 'D', 'D', '-..');
  Add(True, 'E', 'E', '.');
  Add(True, 'F', 'F', '..-.');
  Add(True, 'G', 'G', '--.');
  Add(True, 'H', 'H', '....');
  Add(True, 'I', 'I', '..');
  Add(True, 'J', 'J', '.---');
  Add(True, 'K', 'K', '-.-');
  Add(True, 'L', 'L', '.-..');
  Add(True, 'M', 'M', '--');
  Add(True, 'N', 'N', '-.');
  Add(True, 'O', 'O', '---');
  Add(True, 'P', 'P', '.--.');
  Add(True, 'Q', 'Q', '--.-');
  Add(True, 'R', 'R', '.-.');
  Add(True, 'S', 'S', '...');
  Add(True, 'T', 'T', '-');
  Add(True, 'U', 'U', '..-');
  Add(True, 'V', 'V', '...-');
  Add(True, 'W', 'W', '.--');
  Add(True, 'X', 'X', '-..-');
  Add(True, 'Y', 'Y', '-.--');
  Add(True, 'Z', 'Z', '--..');
  // 小文字 (fldigi は大文字/小文字とも同じ rpr を許容する)
  Add(True, 'a', 'A', '.-');
  Add(True, 'b', 'B', '-...');
  Add(True, 'c', 'C', '-.-.');
  Add(True, 'd', 'D', '-..');
  Add(True, 'e', 'E', '.');
  Add(True, 'f', 'F', '..-.');
  Add(True, 'g', 'G', '--.');
  Add(True, 'h', 'H', '....');
  Add(True, 'i', 'I', '..');
  Add(True, 'j', 'J', '.---');
  Add(True, 'k', 'K', '-.-');
  Add(True, 'l', 'L', '.-..');
  Add(True, 'm', 'M', '--');
  Add(True, 'n', 'N', '-.');
  Add(True, 'o', 'O', '---');
  Add(True, 'p', 'P', '.--.');
  Add(True, 'q', 'Q', '--.-');
  Add(True, 'r', 'R', '.-.');
  Add(True, 's', 'S', '...');
  Add(True, 't', 'T', '-');
  Add(True, 'u', 'U', '..-');
  Add(True, 'v', 'V', '...-');
  Add(True, 'w', 'W', '.--');
  Add(True, 'x', 'X', '-..-');
  Add(True, 'y', 'Y', '-.--');
  Add(True, 'z', 'Z', '--..');
  // 数字
  Add(True, '0', '0', '-----');
  Add(True, '1', '1', '.----');
  Add(True, '2', '2', '..---');
  Add(True, '3', '3', '...--');
  Add(True, '4', '4', '....-');
  Add(True, '5', '5', '.....');
  Add(True, '6', '6', '-....');
  Add(True, '7', '7', '--...');
  Add(True, '8', '8', '---..');
  Add(True, '9', '9', '----.');
  // 句読点 (fldigi の既定はすべて有効)
  Add(True, '\', '\', '.-..-.');
  Add(True, '''', '''', '.----.');
  Add(True, '$', '$', '...-..-');
  Add(True, '(', '(', '-.--.');
  Add(True, ')', ')', '-.--.-');
  Add(True, ',', ',', '--..--');
  Add(True, '-', '-', '-....-');
  Add(True, '.', '.', '.-.-.-');
  Add(True, '/', '/', '-..-.');
  Add(True, ':', ':', '---...');
  Add(True, ';', ';', '-.-.-.');
  Add(True, '?', '?', '..--..');
  Add(True, '_', '_', '..--.-');
  Add(True, '@', '@', '.--.-.');
  Add(True, '!', '!', '-.-.--');
end;

constructor TMorseTable.Create;
begin
  inherited Create;
  BuildTable;
end;

procedure TMorseTable.Init;
begin
  // fldigi: init() はプロサイン/アクセント文字の enable/disable を
  // progdefaults から反映する。本移植版はテーブル生成時に既定値を
  // 適用済みのため、テーブルを作り直すだけでよい。
  BuildTable;
end;

procedure TMorseTable.Enable(const AKey: string; AValue: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(FTable) do
    if (FTable[i].Chr_ = AKey) or (FTable[i].Prt = AKey) then
    begin
      FTable[i].Enabled := AValue;
      Exit;
    end;
end;

function TMorseTable.RxLookup(const ARpr: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FTable) do
    if (FTable[i].Rpr = ARpr) and FTable[i].Enabled then
    begin
      Result := FTable[i].Prt;
      Exit;
    end;
end;

function TMorseTable.TxLookup(AChar: Char): string;
var
  i: Integer;
begin
  Result := '';
  FToPrint := '';
  for i := 0 to High(FTable) do
    if (System.Length(FTable[i].Chr_) = 1) and (FTable[i].Chr_[1] = AChar) then
    begin
      if not FTable[i].Enabled then
        Exit('');
      FToPrint := FTable[i].Prt;
      Result := FTable[i].Rpr;
      Exit;
    end;
end;

function TMorseTable.TxPrint: string;
begin
  Result := FToPrint;
end;

function TMorseTable.TxLength(AChar: Char): Integer;
var
  ms: string;
  i: Integer;
begin
  if AChar = ' ' then
    Exit(4);
  ms := TxLookup(AChar);
  if ms = '' then
    Exit(0);
  Result := 0;
  for i := 1 to System.Length(ms) do
    if ms[i] = '.' then
      Inc(Result, 2)
    else
      Inc(Result, 4);
  Inc(Result, 2);
end;

end.
