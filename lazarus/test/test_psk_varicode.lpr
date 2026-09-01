{ ============================================================================
  test_psk_varicode.lpr

  PSK31 Varicode の試験。

  なぜ表そのものを試験するのか
  ----------------------------------------------------------------------------
  256 行の表を書き写す移植では、**間違いが静かに入る**。1 文字だけ符号が
  違っていても、その文字が現れるまで誰も気づかない。しかも現れたときの
  症状は「たまに変な字が出る」で、原因を表に結びつけるのは難しい。

  幸い varicode には強い構造がある。

  1. 符号は必ず 1 で始まり 1 で終わる
  2. 符号の中に 00 が現れない (00 は文字の区切りだから)
  3. 1・2 から、長さ n の符号の数はフィボナッチ数列になる
     (1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, ...)
  4. 256 個すべて一意

  1 文字でも書き間違えれば、1〜4 のどれかが必ず崩れる。表の中身を
  1 つずつ目で照合するより、この 4 つを機械に確かめさせるほうが確実である。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_psk_varicode;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, PskVaricode, Requirements;

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

procedure CheckEqI(AActual, AExpected: Int64; const AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected, '  実際: ', AActual);
    Inc(FailCount);
  end;
end;

{ --------------------------------------------------------------------------
  1. 全 256 文字が往復すること
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  i, bad, dec: Integer;
begin
  WriteLn;
  WriteLn('--- 1. 全 256 文字の往復 ---');
  bad := 0;
  for i := 0 to 255 do
  begin
    dec := PskVaricodeDecode(PskVaricodeValue(i));
    if dec <> i then
    begin
      if bad < 5 then
        WriteLn(Format('        %d -> 0x%x -> %d', [i, PskVaricodeValue(i), dec]));
      Inc(bad);
    end;
  end;
  CheckEqI(bad, 0, '**全 256 文字が符号化して復号すると元に戻る**');
end;

{ --------------------------------------------------------------------------
  2. 符号の形が varicode の規則に従うこと
  -------------------------------------------------------------------------- }
procedure TestShape;
var
  i, k, badEnds, badZeros, badChars: Integer;
  s: string;
begin
  WriteLn;
  WriteLn('--- 2. 符号の形 ---');
  badEnds := 0; badZeros := 0; badChars := 0;
  for i := 0 to 255 do
  begin
    s := PskVaricodeEncode(i);
    if (Length(s) = 0) or (s[1] <> '1') or (s[Length(s)] <> '1') then
      Inc(badEnds);
    if Pos('00', s) > 0 then
      Inc(badZeros);
    for k := 1 to Length(s) do
      if (s[k] <> '0') and (s[k] <> '1') then
      begin
        Inc(badChars);
        Break;
      end;
  end;
  CheckEqI(badEnds, 0, '**すべての符号が 1 で始まり 1 で終わる**');
  CheckEqI(badZeros, 0, '**符号の中に 00 が現れない** (00 は文字の区切り)');
  CheckEqI(badChars, 0, '符号が 0 と 1 だけでできている');
end;

{ --------------------------------------------------------------------------
  3. 長さの分布がフィボナッチ数列になること

  1 文字でも書き写しを誤れば、この分布が崩れる。
  -------------------------------------------------------------------------- }
procedure TestFibonacci;
var
  hist: array[0..20] of Integer;
  fib: array[0..20] of Integer;
  i, n, maxLen: Integer;
  ok: Boolean;
  line: string;
begin
  WriteLn;
  WriteLn('--- 3. 長さの分布がフィボナッチ数列になること ---');
  for i := 0 to 20 do hist[i] := 0;
  maxLen := 0;
  for i := 0 to 255 do
  begin
    n := Length(PskVaricodeEncode(i));
    if n <= 20 then Inc(hist[n]);
    if n > maxLen then maxLen := n;
  end;

  { 長さ n の符号の数 = fib(n)。1 で始まり 1 で終わり 00 を含まない
    長さ n の並びの数がフィボナッチになるため。 }
  fib[1] := 1; fib[2] := 1;
  for i := 3 to 20 do fib[i] := fib[i-1] + fib[i-2];

  line := '';
  for i := 1 to maxLen do
    line := line + Format('%d:%d/%d ', [i, hist[i], fib[i]]);
  WriteLn('        長さ:実際/期待 ', line);

  ok := True;
  { 最長の桁だけは 256 個で打ち切られるので期待値に満たない。
    それ以外は一致するはず。 }
  for i := 1 to maxLen - 1 do
    if hist[i] <> fib[i] then ok := False;
  Check(ok, '**長さごとの個数がフィボナッチ数列と一致する** (書き写し誤りを弾く)');
  Check(hist[maxLen] <= fib[maxLen],
    '最長の桁は 256 個で打ち切られるので期待値以下');

  n := 0;
  for i := 1 to maxLen do n := n + hist[i];
  CheckEqI(n, 256, '合計が 256 文字');
end;

{ --------------------------------------------------------------------------
  4. 符号が一意であること
  -------------------------------------------------------------------------- }
procedure TestUnique;
var
  i, dup, outOfRange: Integer;
  seen: array[0..PSKVC_TABLE_SIZE-1] of Boolean;
  v: LongWord;
begin
  WriteLn;
  WriteLn('--- 4. 符号の一意性 ---');
  for i := 0 to PSKVC_TABLE_SIZE - 1 do seen[i] := False;
  dup := 0;
  outOfRange := 0;
  for i := 0 to 255 do
  begin
    v := PskVaricodeValue(i);
    if v >= PSKVC_TABLE_SIZE then
    begin
      Inc(outOfRange);
      Continue;
    end;
    if seen[v] then Inc(dup) else seen[v] := True;
  end;
  CheckEqI(outOfRange, 0, 'すべての符号値が表の範囲に収まる');
  CheckEqI(dup, 0, '**256 個の符号がすべて異なる**');
end;

{ --------------------------------------------------------------------------
  5. よく知られた符号が正しいこと

  上の 4 つは構造の試験なので、表全体がずれていても通ってしまう
  (例えば全体を 1 文字ずらしても構造は保たれる)。**具体的な値**を
  いくつか固定して、位置がずれていないことを確かめる。
  -------------------------------------------------------------------------- }
procedure TestKnownCodes;
begin
  WriteLn;
  WriteLn('--- 5. 具体的な符号 (位置ずれを弾く) ---');
  { PSK31 でよく引かれる値。fldigi の表と照合済み。 }
  Check(PskVaricodeEncode(Ord(' ')) = '1', '空白は "1" (1 bit。最短)');
  Check(PskVaricodeEncode(Ord('e')) = '11', '"e" は "11" (最も使われる文字)');
  Check(PskVaricodeEncode(Ord('t')) = '101', '"t" は "101"');
  Check(PskVaricodeEncode(Ord('a')) = '1011', '"a" は "1011"');
  Check(PskVaricodeEncode(0) = '1010101011', 'NUL は "1010101011"');
  Check(PskVaricodeEncode(13) = '11111', 'CR は "11111"');
  Check(PskVaricodeEncode(10) = '11101', 'LF は "11101"');
  CheckEqI(PskVaricodeValue(Ord('e')), 3, '"e" の符号値は 0b11 = 3');
  CheckEqI(PskVaricodeDecode(3), Ord('e'), '符号値 3 は "e"');
  CheckEqI(PskVaricodeDecode(1), Ord(' '), '符号値 1 は空白');
end;

{ --------------------------------------------------------------------------
  6. 表に無い符号を引いたとき
  -------------------------------------------------------------------------- }
procedure TestMisses;
begin
  WriteLn;
  WriteLn('--- 6. 表に無い符号 ---');
  { 0 は符号になりえない (1 で始まらない)。 }
  CheckEqI(PskVaricodeDecode(0), PSKVC_NO_CHAR, '0 は符号でない');
  { 00 を含む値。 }
  CheckEqI(PskVaricodeDecode($100), PSKVC_NO_CHAR,
    '00 を含む値は符号でない');
  { 表の範囲外。 }
  CheckEqI(PskVaricodeDecode(PSKVC_TABLE_SIZE), PSKVC_NO_CHAR,
    '範囲外でも落ちずに「符号なし」を返す');
  CheckEqI(PskVaricodeDecode($FFFFFFFF), PSKVC_NO_CHAR,
    '極端な値でも落ちない');
end;

begin
  WriteLn('=== PSK31 Varicode の試験 ===');

  TestRoundTrip;
  TestShape;
  TestFibonacci;
  TestUnique;
  TestKnownCodes;
  TestMisses;

  if FailCount = 0 then
    CoverReq('MDM-005');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
