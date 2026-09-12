{ ============================================================================
  test_mfsk_varicode.lpr

  MFSK Varicode (units/MfskVaricode.pas) と Gray 符号の試験。

  何を守るか
  ----------------------------------------------------------------------------
  1. 符号が **一意に切り出せる条件** を満たしている
       先頭が 1 / 末尾が 00 / 内部に 001 が無い / 重複が無い
  2. **上流のもう一方の表と 256 件すべて一致する** (書き写しの検算)
  3. 往復して戻る
  4. 連ねたビット列から、受信の規則どおりに文字が切り出せる
  5. Gray 符号が隣接 1 bit の性質を持ち、往復する

  2 が移植の要である。fldigi は同じ内容をビット文字列と数値の 2 つの形で
  持っており、こちらはビット文字列だけを写した。**もう一方の形**を期待値
  として置けば、写し間違いはまず通らない。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_mfsk_varicode;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils,
  ModemDSP, MfskVaricode, Requirements;

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  Inc(TestCount);
  if ACondition then WriteLn('  [OK] ', AMsg)
  else begin WriteLn('  [NG] ', AMsg); Inc(FailCount); end;
end;

procedure CheckEqI(AActual, AExpected: Int64; const AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected, '  実際: ', AActual);
    Inc(FailCount);
  end;
end;

const
  { fldigi src/mfsk/mfskvaricode.cxx の varidecode[] をそのまま写したもの。
    units/MfskVaricode.pas が写したのは **もう一方の** varicode[]
    (ビット文字列) なので、これは独立な出どころの期待値になる。 }
  UPSTREAM: array[0..255] of LongWord = (
    $75C, $760, $768, $76C, $770, $774, $778, $77C,   // 0..7
    $0A8, $780, $7A0, $7A8, $7AC, $0AC, $7B0, $7B4,   // 8..15
    $7B8, $7BC, $7C0, $7D0, $7D4, $7D8, $7DC, $7E0,   // 16..23
    $7E8, $7EC, $7F0, $7F4, $7F8, $7FC, $800, $A00,   // 24..31
    $004, $1C0, $1FC, $2D8, $2A8, $2A0, $200, $1BC,   // 32..39
    $1F4, $1F0, $2B4, $1E0, $0A0, $1D8, $1D4, $1E8,   // 40..47
    $0E0, $0F0, $140, $154, $174, $160, $16C, $1A0,   // 48..55
    $180, $1AC, $1EC, $1F8, $2C0, $1DC, $2BC, $1D0,   // 56..63
    $280, $0BC, $100, $0D4, $0DC, $0B8, $0F8, $150,   // 64..71
    $158, $0C0, $1B4, $17C, $0F4, $0E8, $0FC, $0D0,   // 72..79
    $0EC, $1B0, $0D8, $0B4, $0B0, $15C, $1A8, $168,   // 80..87
    $170, $178, $1B8, $2E8, $2D0, $2EC, $2D4, $2B0,   // 88..95
    $2AC, $014, $060, $038, $034, $008, $050, $058,   // 96..103
    $030, $018, $080, $070, $02C, $040, $01C, $010,   // 104..111
    $054, $078, $020, $028, $00C, $03C, $06C, $068,   // 112..119
    $074, $05C, $07C, $2DC, $2B8, $2E0, $2F0, $A80,   // 120..127
    $AA0, $AA8, $AAC, $AB0, $AB4, $AB8, $ABC, $AC0,   // 128..135
    $AD0, $AD4, $AD8, $ADC, $AE0, $AE8, $AEC, $AF0,   // 136..143
    $AF4, $AF8, $AFC, $B00, $B40, $B50, $B54, $B58,   // 144..151
    $B5C, $B60, $B68, $B6C, $B70, $B74, $B78, $B7C,   // 152..159
    $2F4, $2F8, $2FC, $300, $340, $350, $354, $358,   // 160..167
    $35C, $360, $368, $36C, $370, $374, $378, $37C,   // 168..175
    $380, $3A0, $3A8, $3AC, $3B0, $3B4, $3B8, $3BC,   // 176..183
    $3C0, $3D0, $3D4, $3D8, $3DC, $3E0, $3E8, $3EC,   // 184..191
    $3F0, $3F4, $3F8, $3FC, $400, $500, $540, $550,   // 192..199
    $554, $558, $55C, $560, $568, $56C, $570, $574,   // 200..207
    $578, $57C, $580, $5A0, $5A8, $5AC, $5B0, $5B4,   // 208..215
    $5B8, $5BC, $5C0, $5D0, $5D4, $5D8, $5DC, $5E0,   // 216..223
    $5E8, $5EC, $5F0, $5F4, $5F8, $5FC, $600, $680,   // 224..231
    $6A0, $6A8, $6AC, $6B0, $6B4, $6B8, $6BC, $6C0,   // 232..239
    $6D0, $6D4, $6D8, $6DC, $6E0, $6E8, $6EC, $6F0,   // 240..247
    $6F4, $6F8, $6FC, $700, $740, $750, $754, $758   // 248..255
  );

{ --------------------------------------------------------------------------
  1. 符号が一意に切り出せる条件を満たしていること

  受信は「下位 3 bit が 001 になったら区切り」で切り出す。これが働くには
  三つが要る —— 先頭が 1、末尾が 00、内部に 001 が無いこと。
  表を写し損なうと必ずどれかが崩れるので、移植の検算として有効である。
  -------------------------------------------------------------------------- }
procedure TestStructure;
var
  i, k: Integer;
  s, inner: string;
  badHead, badTail, badInner, dup, minLen, maxLen: Integer;
  seen: array of Boolean;
  v: LongWord;
begin
  WriteLn;
  WriteLn('--- 1. 符号が一意に切り出せる条件 ---');
  badHead := 0; badTail := 0; badInner := 0; dup := 0;
  minLen := 99; maxLen := 0;
  SetLength(seen, MFSKVC_TABLE_SIZE);
  for i := 0 to High(seen) do seen[i] := False;

  for i := 0 to 255 do
  begin
    s := MfskVaricodeEncode(Byte(i));
    if Length(s) < minLen then minLen := Length(s);
    if Length(s) > maxLen then maxLen := Length(s);
    if (Length(s) < 3) or (s[1] <> '1') then Inc(badHead);
    if (Length(s) < 3) or (Copy(s, Length(s) - 1, 2) <> '00') then Inc(badTail);
    { 末尾の 00 を除いた部分に 001 が現れてはいけない。
      現れると、その時点で区切りと誤認されて符号が途中で切れる。 }
    inner := Copy(s, 1, Length(s) - 2);
    if Pos('001', inner) > 0 then Inc(badInner);

    v := MfskVaricodeValue(Byte(i));
    if v >= MFSKVC_TABLE_SIZE then Inc(dup)
    else if seen[v] then Inc(dup)
    else seen[v] := True;
  end;

  WriteLn(Format('        長さ %d..%d bit', [minLen, maxLen]));
  CheckEqI(badHead, 0, '**256 文字すべて 1 で始まる**');
  CheckEqI(badTail, 0, '**256 文字すべて 00 で終わる**');
  CheckEqI(badInner, 0, '**内部に 001 が現れない** (途中で切れない)');
  CheckEqI(dup, 0, '**符号が重複しない** (引いた文字が一意に決まる)');
  Check((minLen >= 3) and (maxLen <= 12), '長さが 3..12 bit に収まる');

  { 符号値 0 は文字に対応しない —— 受信開始直後の空振りがここに落ちる。 }
  CheckEqI(MfskVaricodeDecode(0), MFSKVC_NO_CHAR, '符号値 0 は文字ではない');
  CheckEqI(MfskVaricodeDecode(MFSKVC_TABLE_SIZE), MFSKVC_NO_CHAR,
    '表の外を引いても落ちない');
  k := 0;
  for i := 0 to MFSKVC_TABLE_SIZE - 1 do
    if MfskVaricodeDecode(LongWord(i)) <> MFSKVC_NO_CHAR then Inc(k);
  CheckEqI(k, 256, '引ける符号はちょうど 256 個');
end;

{ --------------------------------------------------------------------------
  2. 上流のもう一方の表と一致すること (書き写しの検算)
  -------------------------------------------------------------------------- }
procedure TestAgainstUpstream;
var
  i, bad, firstBad: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 上流のもう一方の表と突き合わせる ---');
  bad := 0; firstBad := -1;
  for i := 0 to 255 do
    if MfskVaricodeValue(Byte(i)) <> UPSTREAM[i] then
    begin
      Inc(bad);
      if firstBad < 0 then firstBad := i;
    end;
  if bad > 0 then
    WriteLn(Format('        最初の食い違い: %d 番 実測 $%03X / 上流 $%03X',
      [firstBad, MfskVaricodeValue(Byte(firstBad)), UPSTREAM[firstBad]]));
  CheckEqI(bad, 0,
    '**256 件すべてが fldigi の varidecode[] と一致する** (写し間違いが無い)');
  WriteLn(Format('        例: NUL=$%03X  BS=$%03X  CR=$%03X  空白=$%03X  e=$%03X',
    [MfskVaricodeValue(0), MfskVaricodeValue(8), MfskVaricodeValue(13),
     MfskVaricodeValue(32), MfskVaricodeValue(101)]));
end;

{ --------------------------------------------------------------------------
  3. 往復して戻ること
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  i, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 往復 ---');
  bad := 0;
  for i := 0 to 255 do
    if MfskVaricodeDecode(MfskVaricodeValue(Byte(i))) <> i then Inc(bad);
  CheckEqI(bad, 0, '**256 文字すべてが符号を経て元の文字に戻る**');
end;

{ --------------------------------------------------------------------------
  4. 連ねたビット列から文字を切り出せること

  これが実使用の形である。fldigi の受信規則
      shreg = (shreg << 1) or bit;  区切りは (shreg and 7) = 1
  をそのまま使い、文を通す。
  -------------------------------------------------------------------------- }
function DecodeStream(const ABits: string; out ASpurious: Integer): string;
var
  shreg: LongWord;
  i, c: Integer;
begin
  Result := '';
  ASpurious := 0;
  shreg := 0;
  for i := 1 to Length(ABits) do
  begin
    shreg := ((shreg shl 1) or LongWord(Ord(ABits[i]) - Ord('0')))
             and (MFSKVC_TABLE_SIZE * 2 - 1);
    if MfskVaricodeIsBoundary(shreg) then
    begin
      c := MfskVaricodeDecode(MfskVaricodeSymbolOf(shreg));
      if c = MFSKVC_NO_CHAR then Inc(ASpurious)
      else Result := Result + Chr(c);
      shreg := 1;
    end;
  end;
end;

procedure TestStreamBoundaries;
const
  MSG = 'CQ DE JA1ABC K';
var
  bits, got: string;
  i, spurious: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 4. 連ねたビット列から切り出す ---');
  bits := '';
  for i := 1 to Length(MSG) do
    bits := bits + MfskVaricodeEncode(Byte(Ord(MSG[i])));
  { 最後の文字の 00 のあとに次の 1 が来ないと区切りが立たない。
    実際の送信も idle の 1 を続けるので、それに倣う。 }
  bits := bits + '1';
  WriteLn(Format('        %d 文字 -> %d bit (1 文字あたり %.1f bit)',
    [Length(MSG), Length(bits), Length(bits) / Length(MSG)]));

  got := DecodeStream(bits, spurious);
  WriteLn('        復号: [', got, ']');
  Check(got = MSG, '**連ねたビット列から元の文が出る**');
  { 受信開始直後、最初の 1 が入った時点で shreg = 1 になり、
    (1 and 7) = 1 で区切りが立つ。符号値 0 を引いて空振りする。
    これは自己同期の代償で、無害でなければならない。 }
  WriteLn(Format('        空振り %d 回 (受信開始直後の自己同期)', [spurious]));
  Check(spurious <= 1, '空振りは受信開始直後の 1 回だけ');

  { 全 256 文字を通しても崩れないこと。 }
  bits := '';
  for i := 0 to 255 do
    bits := bits + MfskVaricodeEncode(Byte(i));
  bits := bits + '1';
  got := DecodeStream(bits, spurious);
  CheckEqI(Length(got), 256, '**256 文字を連ねても 256 文字に切り出せる**');
  ok := Length(got) = 256;
  if ok then
    for i := 0 to 255 do
      if Ord(got[i + 1]) <> i then begin ok := False; Break; end;
  Check(ok, '切り出した順序も一致する');
end;

{ --------------------------------------------------------------------------
  5. Gray 符号

  トーンを取り違えたときにビット誤りを 1 本で済ませるための並べ替え。
  隣接が 1 bit しか違わないことが性質そのものなので、そこを直接見る。
  -------------------------------------------------------------------------- }
function PopCount(AValue: LongWord): Integer;
var
  v: LongWord;
begin
  Result := 0;
  v := AValue;
  while v <> 0 do
  begin
    Inc(Result, Integer(v and 1));
    v := v shr 1;
  end;
end;

procedure TestGray;
const
  { 0..15 の Gray 符号。手で書ける既知解。 }
  EXPECT: array[0..15] of LongWord =
    (0, 1, 3, 2, 6, 7, 5, 4, 12, 13, 15, 14, 10, 11, 9, 8);
var
  i, bad, worst: Integer;
begin
  WriteLn;
  WriteLn('--- 5. Gray 符号 ---');
  bad := 0;
  for i := 0 to 15 do
    if GrayEncode(LongWord(i)) <> EXPECT[i] then Inc(bad);
  CheckEqI(bad, 0, '**0..15 の Gray 符号が既知解と一致する**');

  bad := 0;
  for i := 0 to 65535 do
    if GrayDecode(GrayEncode(LongWord(i))) <> LongWord(i) then Inc(bad);
  CheckEqI(bad, 0, '**0..65535 すべてで往復する**');

  { 隣り合う値の符号が 1 bit しか違わないこと —— これが Gray の意味。 }
  worst := 0;
  for i := 0 to 65534 do
  begin
    bad := PopCount(GrayEncode(LongWord(i)) xor GrayEncode(LongWord(i + 1)));
    if bad > worst then worst := bad;
  end;
  CheckEqI(worst, 1,
    '**隣り合う値は必ず 1 bit しか違わない** (トーンを取り違えても 1 bit)');

  { 素の 2 進だとどうなるか。効果を数字で残す。 }
  worst := 0;
  for i := 0 to 65534 do
  begin
    bad := PopCount(LongWord(i) xor LongWord(i + 1));
    if bad > worst then worst := bad;
  end;
  WriteLn(Format('        素の 2 進では隣り合う値が最大 %d bit 違う', [worst]));
  Check(worst > 1, '前提: 素の 2 進では 1 bit に収まらない (だから Gray を使う)');

  CheckEqI(GrayEncode(0), 0, '0 は 0 のまま');
  CheckEqI(GrayDecode(0), 0, '復号も 0 は 0 のまま');
end;

begin
  WriteLn('=== MFSK Varicode と Gray 符号の試験 ===');

  TestStructure;
  TestAgainstUpstream;
  TestRoundTrip;
  TestStreamBoundaries;
  TestGray;

  if FailCount = 0 then
    CoverReq('MDM-010');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
