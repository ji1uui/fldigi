{ ============================================================================
  test_olivia_block.lpr

  Olivia / Contestia の**符号の層**の試験 (units/OliviaBlock.pas と
  ModemDSP のアダマール変換)。

  何を守るか
  ----------------------------------------------------------------------------
  1. アダマール変換が定義どおりに振る舞う (既知解と往復)
  2. **上流と同じシンボル列が出る** (fldigi の C++ から採った既知解)
  3. 符号化 -> 復号で文字が戻る (Olivia / Contestia / トーン数違い)
  4. Contestia の文字割り当てが上流と一致する
  5. **誤りに対する強さを数字で残す** (何シンボル壊れるまで読めるか)
  6. 軟判定が硬判定より強い
  7. かき混ぜが効いている (同じ文字を並べても音が偏らない)
  8. 斜め置きが効いている (ビット位置を 1 つ潰しても文字が全滅しない)
  9. Signal / NoiseEnergy が「正しいブロック位相」を選ぶ材料になる
  10. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05)

  2 が核心である。この層には自由度がほとんど無く、かき混ぜ符号のずらし量や
  斜めの向きを一つ間違えただけで上流と繋がらなくなる。往復だけでは
  **自分の間違いが打ち消し合って通ってしまう** ので、上流の C++ を
  そのまま動かして採った値を期待値にしてある。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_olivia_block;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, OliviaBlock, TestVectors, Requirements;

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

type
  TByteArr = array of Byte;
  TDblArr = array of Double;

{ シンボル値の並びを軟判定に開く。送信側は「Walsh 値が負ならビット 1」
  なので、受信の軟判定は **正がビット 0 / 負がビット 1** である。 }
procedure SymbolToSoft(const AMode: TOliviaMode; ASym: Byte;
  var ASoft: TDblArr; AAmplitude: Double = 1.0);
var
  f: Integer;
begin
  for f := 0 to AMode.BitsPerSymbol - 1 do
    if (ASym and (1 shl f)) <> 0 then ASoft[f] := -AAmplitude
    else ASoft[f] := AAmplitude;
end;

{ 1 ブロックを符号化して復号し、戻った文字を返す。 }
function RoundTrip(const AMode: TOliviaMode; const AChars: TByteArr;
  ANoiseRms: Double = 0; ASeed: QWord = 1;
  ACorruptCount: Integer = 0): TByteArr;
var
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  syms: TByteArr;
  soft: TDblArr;
  rnd: TVectorRandom;
  t, f, i, victim: Integer;
  corrupted: TByteArr;
begin
  rnd.Seed(ASeed);
  enc := TOliviaBlockEncoder.Create(AMode);
  dec_ := TOliviaBlockDecoder.Create(AMode);
  try
    SetLength(syms, AMode.SymbolsPerBlock);
    SetLength(soft, AMode.BitsPerSymbol);
    enc.EncodeBlock(AChars, syms);

    { 指定された数だけシンボルを丸ごと別の値に化けさせる。
      どこを壊すかは種から決まるので、同じ種なら同じ結果になる。 }
    SetLength(corrupted, AMode.SymbolsPerBlock);
    for t := 0 to AMode.SymbolsPerBlock - 1 do corrupted[t] := 0;
    i := 0;
    while i < ACorruptCount do
    begin
      victim := Integer(rnd.NextU64 mod QWord(AMode.SymbolsPerBlock));
      if corrupted[victim] = 0 then
      begin
        corrupted[victim] := 1;
        syms[victim] := Byte(rnd.NextU64 mod QWord(AMode.Tones));
        Inc(i);
      end;
    end;

    for t := 0 to AMode.SymbolsPerBlock - 1 do
    begin
      SymbolToSoft(AMode, syms[t], soft);
      if ANoiseRms > 0 then
        for f := 0 to AMode.BitsPerSymbol - 1 do
          soft[f] := soft[f] + ANoiseRms * rnd.NextGauss;
      dec_.Input(soft);
    end;
    dec_.Process;

    SetLength(Result, AMode.CharsPerBlock);
    for i := 0 to AMode.CharsPerBlock - 1 do
      Result[i] := dec_.OutputChar(i);
  finally
    enc.Free; dec_.Free;
  end;
end;

function SameChars(const A, B: TByteArr): Boolean;
var
  i: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for i := 0 to High(A) do
    if A[i] <> B[i] then Exit(False);
  Result := True;
end;

{ --------------------------------------------------------------------------
  1. アダマール変換
  -------------------------------------------------------------------------- }
procedure TestHadamard;
var
  w, ref: TDblArr;
  n, p, t, k, bad: Integer;
  expect, worst: Double;
  raised: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. アダマール変換 ---');

  { 単位ベクトルの逆変換が定義どおりの ±1 の並びになること。
    期待値は実装ではなく **式から** 出している。
      IFHT(delta_p)[t] = (-1)^(popcount(p) + popcount(p and t)) }
  bad := 0;
  for k := 1 to 6 do
  begin
    n := 1 shl k;
    SetLength(w, n);
    for p := 0 to n - 1 do
    begin
      for t := 0 to n - 1 do w[t] := 0;
      w[p] := 1;
      InverseFastHadamard(w, n);
      for t := 0 to n - 1 do
      begin
        if ((PopCnt(LongWord(p)) + PopCnt(LongWord(p and t))) and 1) = 0 then
          expect := 1
        else
          expect := -1;
        if w[t] <> expect then Inc(bad);
      end;
    end;
  end;
  CheckEqI(bad, 0,
    '**単位ベクトルの逆変換が (-1)^(popcount(p)+popcount(p and t)) と一致**');

  { 順逆を続けると N 倍になること (規約)。 }
  n := 64;
  SetLength(w, n);
  SetLength(ref, n);
  for t := 0 to n - 1 do
  begin
    ref[t] := Sin(t * 0.37) * 3 - 1.25;
    w[t] := ref[t];
  end;
  InverseFastHadamard(w, n);
  FastHadamard(w, n);
  worst := 0;
  for t := 0 to n - 1 do
    if Abs(w[t] - n * ref[t]) > worst then worst := Abs(w[t] - n * ref[t]);
  Check(worst < 1E-9,
    Format('順逆を続けると %d 倍になる (最大差 %.3E)', [n, worst]));

  { 長さが 2 の冪乗でなければ断る。黙って壊れた答えを返さない。 }
  raised := False;
  SetLength(w, 8);
  try
    FastHadamard(w, 6);
  except
    on EDspError do raised := True;
  end;
  Check(raised, '長さが 2 の冪乗でなければ例外にする');

  raised := False;
  SetLength(w, 4);
  try
    FastHadamard(w, 8);
  except
    on EDspError do raised := True;
  end;
  Check(raised, '配列が足りなければ例外にする');
end;

{ --------------------------------------------------------------------------
  2. 上流と同じシンボル列が出る

  期待値は fldigi の src/include/jalocha/pj_mfsk.h (MFSK_Encoder) を
  そのまま C++ で動かして採った。往復だけでは、かき混ぜ符号や斜めの向きを
  取り違えていても符号化と復号で打ち消し合って通ってしまう。
  -------------------------------------------------------------------------- }
const
  KA_O32_ABCDE: array[0..63] of Byte = (
    14, 14, 13,  2,  6, 10,  6, 18,  7, 28, 15, 27,  5,  5, 28,  3,
     7,  6, 26, 25,  9, 27, 26, 12, 20, 19,  8, 25, 20, 13, 18,  7,
    25, 24,  8,  9, 23, 30, 24,  2, 16, 29, 14, 26,  5, 20, 22, 27,
    24,  5,  5,  7,  4, 26, 26, 31,  5, 10,  1, 27, 28,  4, 31,  5);

  { 上位ビットが立つ文字 (>= SymbolsPerBlock) を含む場合。
    Walsh の符号が反転する枝をここで踏む。 }
  KA_O32_HIGH: array[0..63] of Byte = (
    23, 31,  0, 16, 12, 31, 10, 14, 12, 26, 16,  6,  5, 13, 21, 16,
    29, 23,  5, 22,  9, 25, 16, 16,  8, 11, 30, 16, 17, 23, 20,  9,
     8, 19,  7, 22, 21, 30,  4, 11,  8, 14,  7,  0, 31,  0, 24,  3,
    30, 25, 15, 17, 18, 31,  9, 25, 29, 31, 22,  4, 29,  4, 17, 17);

  KA_C32_ABCDE: array[0..31] of Byte = (
    14,  3, 10, 13, 11, 20,  5, 29, 15, 14,  4, 23, 16, 15,  2, 20,
    21, 22,  4,  0, 25, 28,  0, 23, 27, 11, 19, 10,  3, 12, 15, 20);

  { 空白・CR・小文字・表に無い制御文字を混ぜた Contestia。 }
  KA_C32_MIX: array[0..31] of Byte = (
     3,  9,  0, 27, 28, 19,  4, 30, 26,  1, 13, 21,  2,  8, 23, 23,
    24, 13, 14, 16, 13,  5, 13, 15, 13, 14, 22,  1, 24, 31, 31,  5);

  { トーン数が違う場合 (16 トーン Olivia)。1 ブロック 4 文字になる。 }
  KA_O16: array[0..63] of Byte = (
    15,  4, 11, 12,  5, 14, 11, 14, 15, 13,  2,  7,  2,  7,  9,  4,
     9, 15,  5, 12, 11,  7,  0,  9,  1, 15,  2,  3,  2, 13,  9,  9,
     3,  5,  6,  2, 14, 12,  8,  8, 15, 10,  2,  2, 13, 14,  2, 12,
     5,  1, 13, 10, 15,  2, 15,  8,  6,  4,  1,  9,  0,  5, 13,  4);

procedure CheckKnownAnswer(const AName: string; const AMode: TOliviaMode;
  const AChars: array of Byte; const AExpect: array of Byte);
var
  enc: TOliviaBlockEncoder;
  syms: TByteArr;
  t, bad, firstBad: Integer;
begin
  enc := TOliviaBlockEncoder.Create(AMode);
  try
    SetLength(syms, AMode.SymbolsPerBlock);
    enc.EncodeBlock(AChars, syms);
    bad := 0; firstBad := -1;
    for t := 0 to AMode.SymbolsPerBlock - 1 do
      if syms[t] <> AExpect[t] then
      begin
        Inc(bad);
        if firstBad < 0 then firstBad := t;
      end;
    if bad = 0 then
      Check(True, Format('**%s が上流と一致** (%d シンボル)',
        [AName, AMode.SymbolsPerBlock]))
    else
    begin
      Check(False, Format('%s が上流と一致', [AName]));
      WriteLn(Format('        %d / %d 個ちがう。最初は %d 番目 (期待 %d / 実際 %d)',
        [bad, AMode.SymbolsPerBlock, firstBad, AExpect[firstBad],
         syms[firstBad]]));
    end;
  finally
    enc.Free;
  end;
end;

procedure TestKnownAnswers;
var
  m: TOliviaMode;
begin
  WriteLn;
  WriteLn('--- 2. 上流 (fldigi の C++) と同じシンボル列が出る ---');
  m := OLIVIA_32_MODE;
  WriteLn('        ', m.Describe);
  CheckKnownAnswer('Olivia 32 / ABCDE', m, [65, 66, 67, 68, 69], KA_O32_ABCDE);
  CheckKnownAnswer('Olivia 32 / 上位ビットあり', m, [100, 0, 127, 64, 63],
    KA_O32_HIGH);

  m := CONTESTIA_32_MODE;
  WriteLn('        ', m.Describe);
  CheckKnownAnswer('Contestia 32 / ABCDE', m, [65, 66, 67, 68, 69],
    KA_C32_ABCDE);
  CheckKnownAnswer('Contestia 32 / 空白と制御文字', m, [32, 13, 97, 7, 63],
    KA_C32_MIX);

  m := OLIVIA_16_MODE;
  WriteLn('        ', m.Describe);
  CheckKnownAnswer('Olivia 16 / 4 文字', m, [81, 90, 32, 48], KA_O16);
end;

{ --------------------------------------------------------------------------
  3. 往復
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  m: TOliviaMode;
  chars, got: TByteArr;
  base, i, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 符号化 -> 復号で文字が戻る ---');

  { Olivia は 7 bit すべて。5 文字ずつ 26 ブロックに分けて全数見る。 }
  m := OLIVIA_32_MODE;
  SetLength(chars, m.CharsPerBlock);
  bad := 0;
  base := 0;
  while base < 128 do
  begin
    for i := 0 to m.CharsPerBlock - 1 do chars[i] := Byte((base + i) and 127);
    got := RoundTrip(m, chars);
    for i := 0 to m.CharsPerBlock - 1 do
      if got[i] <> chars[i] then Inc(bad);
    Inc(base, m.CharsPerBlock);
  end;
  CheckEqI(bad, 0, '**Olivia: 0..127 の全文字が戻る**');

  { Contestia は表にある文字だけが戻る。表に無いものは ? になる約束。 }
  m := CONTESTIA_32_MODE;
  SetLength(chars, m.CharsPerBlock);
  bad := 0;
  base := 32;
  while base <= 90 do
  begin
    for i := 0 to m.CharsPerBlock - 1 do
      chars[i] := Byte(Min(90, base + i));
    got := RoundTrip(m, chars);
    for i := 0 to m.CharsPerBlock - 1 do
      if got[i] <> chars[i] then Inc(bad);
    Inc(base, m.CharsPerBlock);
  end;
  CheckEqI(bad, 0, '**Contestia: 表にある 32..90 の文字が戻る**');

  { 16 トーンでも成り立つ。 }
  m := OLIVIA_16_MODE;
  SetLength(chars, m.CharsPerBlock);
  for i := 0 to m.CharsPerBlock - 1 do chars[i] := Byte(70 + i);
  got := RoundTrip(m, chars);
  Check(SameChars(got, chars), '16 トーンでも戻る');
end;

{ --------------------------------------------------------------------------
  4. Contestia の文字割り当て
  -------------------------------------------------------------------------- }
procedure TestContestiaAlphabet;
var
  m: TOliviaMode;
  i, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 4. Contestia の文字割り当て ---');
  m := CONTESTIA_32_MODE;

  CheckEqI(OliviaCharToCode(m, Ord(' ')), 59, '空白は 59');
  CheckEqI(OliviaCharToCode(m, 13), 60, 'CR は 60');
  CheckEqI(OliviaCharToCode(m, 8), 61, 'BS は 61');
  CheckEqI(OliviaCharToCode(m, Ord('A')), 33, '''A'' は 33');
  CheckEqI(OliviaCharToCode(m, Ord('a')), 33, '小文字は大文字に畳まれる');
  CheckEqI(OliviaCharToCode(m, 7), Ord('?') - 32, '表に無い文字は ?');
  CheckEqI(OliviaCharToCode(m, 10), 0, 'LF は 0 に潰れる (上流のまま)');
  CheckEqI(OliviaCodeToChar(m, 0), 0, '0 は NUL のまま (LF には戻らない)');

  { 表にある符号は往復する。 }
  bad := 0;
  for i := 1 to 61 do
    if OliviaCharToCode(m, OliviaCodeToChar(m, Byte(i))) <> i then Inc(bad);
  CheckEqI(bad, 0, '符号 1..61 が文字を経て同じ符号に戻る');

  { Olivia 側は 7 bit の素通し。 }
  m := OLIVIA_32_MODE;
  bad := 0;
  for i := 0 to 255 do
    if OliviaCharToCode(m, Byte(i)) <> (i and 127) then Inc(bad);
  CheckEqI(bad, 0, 'Olivia は下位 7 bit をそのまま使う');
end;

{ --------------------------------------------------------------------------
  5. 誤りに対する強さ

  Olivia の売りそのものである。1 文字を 64 シンボルに広げてあるので、
  半分近くが化けても山は正しい位置に立つ。**どこまで持つか**を数字で残す。
  -------------------------------------------------------------------------- }
procedure TestErrorTolerance;
const
  TRIALS = 40;
var
  m: TOliviaMode;
  chars, got: TByteArr;
  i, k, n, bad, total: Integer;
  cer, lastGood: Double;
  firstFail: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 何シンボル壊れるまで読めるか (Olivia 32 / 64 シンボル) ---');
  m := OLIVIA_32_MODE;
  SetLength(chars, m.CharsPerBlock);
  for i := 0 to m.CharsPerBlock - 1 do chars[i] := Ord('A') + i;

  WriteLn('          壊したシンボル数   文字誤り率');
  firstFail := -1;
  lastGood := 0;
  n := 0;
  while n <= 40 do
  begin
    bad := 0; total := 0;
    for k := 1 to TRIALS do
    begin
      got := RoundTrip(m, chars, 0, QWord(7919 * k + 13), n);
      for i := 0 to m.CharsPerBlock - 1 do
      begin
        Inc(total);
        if got[i] <> chars[i] then Inc(bad);
      end;
    end;
    cer := bad / total;
    WriteLn(Format('          %10d          %.3f', [n, cer]));
    { 「まだ一度も誤っていない間の最大」。あとで 0 に戻っても数えない ――
      崖の向こう側でたまたま 0 が出たものを上限と呼ばないためである。 }
    if (firstFail < 0) then
    begin
      if cer = 0 then lastGood := n
      else firstFail := n;
    end;
    Inc(n, 4);
  end;
  WriteLn(Format('        全数正しく読めた上限: %.0f シンボル (全 %d の %.0f%%)',
    [lastGood, m.SymbolsPerBlock, 100 * lastGood / m.SymbolsPerBlock]));
  Check(lastGood >= 16,
    Format('**64 シンボル中 16 個化けても全文字読める** (実測 %.0f)',
      [lastGood]));
  Check(firstFail > 0, '掃引が崖を跨いでいる (壊しすぎれば読めなくなる)');
end;

{ 軟判定と硬判定を比べる。丸めるかどうかだけが違う。 }
function RoundTripNoisy(const AMode: TOliviaMode; const AChars: TByteArr;
  ANoiseRms: Double; ASeed: QWord; AHardDecision: Boolean): TByteArr;
var
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  syms: TByteArr;
  soft: TDblArr;
  rnd: TVectorRandom;
  t, f, i: Integer;
begin
  rnd.Seed(ASeed);
  enc := TOliviaBlockEncoder.Create(AMode);
  dec_ := TOliviaBlockDecoder.Create(AMode);
  try
    SetLength(syms, AMode.SymbolsPerBlock);
    SetLength(soft, AMode.BitsPerSymbol);
    enc.EncodeBlock(AChars, syms);
    for t := 0 to AMode.SymbolsPerBlock - 1 do
    begin
      SymbolToSoft(AMode, syms[t], soft);
      for f := 0 to AMode.BitsPerSymbol - 1 do
      begin
        soft[f] := soft[f] + ANoiseRms * rnd.NextGauss;
        if AHardDecision then
          if soft[f] >= 0 then soft[f] := 1 else soft[f] := -1;
      end;
      dec_.Input(soft);
    end;
    dec_.Process;
    SetLength(Result, AMode.CharsPerBlock);
    for i := 0 to AMode.CharsPerBlock - 1 do Result[i] := dec_.OutputChar(i);
  finally
    enc.Free; dec_.Free;
  end;
end;

procedure TestSoftBeatsHard;
const
  TRIALS = 60;
var
  m: TOliviaMode;
  chars, got: TByteArr;
  i, k, ki, badS, badH, total: Integer;
  rms: array[0..5] of Double = (0.5, 1.0, 1.5, 2.0, 2.5, 3.0);
  softWins: Integer;
  cerS, cerH: Double;
begin
  WriteLn;
  WriteLn('--- 6. 軟判定が硬判定より強い ---');
  m := OLIVIA_32_MODE;
  SetLength(chars, m.CharsPerBlock);
  for i := 0 to m.CharsPerBlock - 1 do chars[i] := Ord('A') + i;

  WriteLn('          雑音rms   軟判定CER  硬判定CER');
  softWins := 0;
  for ki := 0 to High(rms) do
  begin
    badS := 0; badH := 0; total := 0;
    for k := 1 to TRIALS do
    begin
      got := RoundTripNoisy(m, chars, rms[ki], QWord(104729 * k + 5), False);
      for i := 0 to m.CharsPerBlock - 1 do
      begin
        Inc(total);
        if got[i] <> chars[i] then Inc(badS);
      end;
      got := RoundTripNoisy(m, chars, rms[ki], QWord(104729 * k + 5), True);
      for i := 0 to m.CharsPerBlock - 1 do
        if got[i] <> chars[i] then Inc(badH);
    end;
    cerS := badS / total;
    cerH := badH / total;
    WriteLn(Format('          %6.2f    %.3f      %.3f', [rms[ki], cerS, cerH]));
    if cerS < cerH then Inc(softWins);
  end;
  Check(softWins >= 3,
    Format('**軟判定のほうが強い条件が多い** (%d / %d)',
      [softWins, Length(rms)]));
end;

{ --------------------------------------------------------------------------
  7. かき混ぜが効いている

  同じ文字を CharsPerBlock 個並べると、かき混ぜが無ければ 5 つの Walsh
  関数がまったく同じになる。斜めに置いても時刻ごとに全ビットが揃うので、
  シンボル値は 0 か Tones-1 の二種類しか出なくなる。
  かき混ぜはこれを崩すためにある。
  -------------------------------------------------------------------------- }
procedure TestScramblingSpreadsTones;
var
  m: TOliviaMode;
  enc: TOliviaBlockEncoder;
  chars, syms: TByteArr;
  seen: array[0..255] of Boolean;
  t, i, distinct, extremes: Integer;
begin
  WriteLn;
  WriteLn('--- 7. かき混ぜが音を散らす ---');
  m := OLIVIA_32_MODE;
  enc := TOliviaBlockEncoder.Create(m);
  try
    SetLength(chars, m.CharsPerBlock);
    SetLength(syms, m.SymbolsPerBlock);
    for i := 0 to m.CharsPerBlock - 1 do chars[i] := Ord('X');
    enc.EncodeBlock(chars, syms);

    for i := 0 to 255 do seen[i] := False;
    extremes := 0;
    for t := 0 to m.SymbolsPerBlock - 1 do
    begin
      seen[syms[t]] := True;
      if (syms[t] = 0) or (syms[t] = m.Tones - 1) then Inc(extremes);
    end;
    distinct := 0;
    for i := 0 to 255 do if seen[i] then Inc(distinct);

    WriteLn(Format('        同じ文字 %d 個: 現れたトーン %d 種 / 端 (0 か %d) は %d 個',
      [m.CharsPerBlock, distinct, m.Tones - 1, extremes]));
    Check(distinct >= 12,
      Format('**同じ文字を並べてもトーンが散る** (%d 種)', [distinct]));
    Check(extremes <= m.SymbolsPerBlock div 4,
      Format('端のトーンに偏らない (%d / %d)',
        [extremes, m.SymbolsPerBlock]));
  finally
    enc.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 斜め置きが効いている

  文字 f のビットを時刻ごとにずらして置いてあるので、特定のビット位置が
  まるごと潰れても、どの文字も 1/BitsPerSymbol しか失わない。
  斜めが無ければ、ビット f が潰れた時点で文字 f だけが全滅する。
  -------------------------------------------------------------------------- }
procedure TestDiagonalSpreadsCharacters;
var
  m: TOliviaMode;
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  chars, syms: TByteArr;
  soft: TDblArr;
  t, i, killed, bad: Integer;
begin
  WriteLn;
  WriteLn('--- 8. 斜め置きが 1 文字の全滅を防ぐ ---');
  m := OLIVIA_32_MODE;
  SetLength(chars, m.CharsPerBlock);
  for i := 0 to m.CharsPerBlock - 1 do chars[i] := Ord('A') + i;

  for killed := 0 to m.BitsPerSymbol - 1 do
  begin
    enc := TOliviaBlockEncoder.Create(m);
    dec_ := TOliviaBlockDecoder.Create(m);
    try
      SetLength(syms, m.SymbolsPerBlock);
      SetLength(soft, m.BitsPerSymbol);
      enc.EncodeBlock(chars, syms);
      for t := 0 to m.SymbolsPerBlock - 1 do
      begin
        SymbolToSoft(m, syms[t], soft);
        { そのビット位置だけを消失 (0 = 分からない) にする。
          トーンの片側の帯が潰れた、という状況に当たる。 }
        soft[killed] := 0;
        dec_.Input(soft);
      end;
      dec_.Process;
      bad := 0;
      for i := 0 to m.CharsPerBlock - 1 do
        if dec_.OutputChar(i) <> chars[i] then Inc(bad);
      if killed = 0 then
        WriteLn(Format('        ビット位置 %d を消失させても誤り %d 文字',
          [killed, bad]));
      Check(bad = 0,
        Format('ビット位置 %d を丸ごと失っても全文字読める', [killed]));
    finally
      enc.Free; dec_.Free;
    end;
  end;

  { 念のため、2 つ潰しても持つか。持てば余裕がある。 }
  enc := TOliviaBlockEncoder.Create(m);
  dec_ := TOliviaBlockDecoder.Create(m);
  try
    enc.EncodeBlock(chars, syms);
    for t := 0 to m.SymbolsPerBlock - 1 do
    begin
      SymbolToSoft(m, syms[t], soft);
      soft[0] := 0;
      soft[2] := 0;
      dec_.Input(soft);
    end;
    dec_.Process;
    bad := 0;
    for i := 0 to m.CharsPerBlock - 1 do
      if dec_.OutputChar(i) <> chars[i] then Inc(bad);
    WriteLn(Format('        2 つのビット位置を消失させたときの誤り: %d 文字',
      [bad]));
    Check(bad = 0, '2 つのビット位置を失っても読める');
  finally
    enc.Free; dec_.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. Signal / NoiseEnergy が同期の材料になる

  次の層 (ブロックの頭出し) は、ブロック位相ごとに復号器を並べて
  S/N の一番良いものを採る。正しい位相で高く、ずれた位相で低く
  なっていなければ、その選び方が成り立たない。
  -------------------------------------------------------------------------- }
procedure TestSyncMetric;
var
  m: TOliviaMode;
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  chars, syms: TByteArr;
  soft: TDblArr;
  rnd: TVectorRandom;
  t, f, i, shift: Integer;
  alignedSnr, worstOff, bestOff, snr: Double;
begin
  WriteLn;
  WriteLn('--- 9. Signal / NoiseEnergy がブロック位相を選べる ---');
  m := OLIVIA_32_MODE;
  SetLength(chars, m.CharsPerBlock);
  for i := 0 to m.CharsPerBlock - 1 do chars[i] := Ord('A') + i;

  enc := TOliviaBlockEncoder.Create(m);
  try
    SetLength(syms, m.SymbolsPerBlock);
    SetLength(soft, m.BitsPerSymbol);
    enc.EncodeBlock(chars, syms);
  finally
    enc.Free;
  end;

  { **雑音を入れて測る。** 無雑音だと揃った位相の NoiseEnergy が
    ちょうど 0 になり、S/N が無限大の番兵になってしまう。それでは
    「桁違いに高い」が番兵のおかげで通り、尺度そのものを見ていない。 }
  alignedSnr := 0;
  worstOff := 1E30;
  bestOff := 0;
  for shift := 0 to m.SymbolsPerBlock - 1 do
  begin
    dec_ := TOliviaBlockDecoder.Create(m);
    try
      rnd.Seed(20260916);
      for t := 0 to m.SymbolsPerBlock - 1 do
      begin
        i := (shift + t) mod m.SymbolsPerBlock;
        SymbolToSoft(m, syms[i], soft);
        for f := 0 to m.BitsPerSymbol - 1 do
          soft[f] := soft[f] + 0.8 * rnd.NextGauss;
        dec_.Input(soft);
      end;
      dec_.Process;
      snr := dec_.Signal * dec_.Signal / dec_.NoiseEnergy;
      if shift = 0 then
        alignedSnr := snr
      else
      begin
        if snr < worstOff then worstOff := snr;
        if snr > bestOff then bestOff := snr;
      end;
    finally
      dec_.Free;
    end;
  end;
  WriteLn(Format('        揃った位相 %.1f / ずれた位相 %.1f..%.1f (雑音 rms 0.8)',
    [alignedSnr, worstOff, bestOff]));
  Check(alignedSnr > 4 * bestOff,
    Format('**揃った位相の S/N が、ずれた位相のどれよりはっきり高い** (%.1f 対 最大 %.1f)',
      [alignedSnr, bestOff]));
  Check(worstOff > 0, '前提: ずれた位相でも 0 割りにならない (雑音が入っている)');
end;

{ --------------------------------------------------------------------------
  10. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05)
  -------------------------------------------------------------------------- }
var
  GOldMM: TMemoryManager;
  GNewMM: TMemoryManager;
  GAllocCount: Integer = 0;
  GCounting: Boolean = False;

function CountingGetMem(ASize: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GOldMM.GetMem(ASize);
end;

function CountingReAllocMem(var P: Pointer; ASize: PtrUInt): Pointer;
begin
  if GCounting then Inc(GAllocCount);
  Result := GOldMM.ReAllocMem(P, ASize);
end;

procedure TestNoAllocationAndDeterminism;
const
  BLOCKS = 200;
var
  m: TOliviaMode;
  enc: TOliviaBlockEncoder;
  dec_: TOliviaBlockDecoder;
  chars, syms, g1, g2: TByteArr;
  soft: TDblArr;
  t, i, k, n: Integer;
begin
  WriteLn;
  WriteLn('--- 10. 確保しない (X-04) / 同じ入力から同じ結果 (Z-05) ---');
  m := OLIVIA_32_MODE;
  enc := TOliviaBlockEncoder.Create(m);
  dec_ := TOliviaBlockDecoder.Create(m);
  try
    SetLength(chars, m.CharsPerBlock);
    SetLength(syms, m.SymbolsPerBlock);
    SetLength(soft, m.BitsPerSymbol);
    for i := 0 to m.CharsPerBlock - 1 do chars[i] := Ord('A') + i;
    enc.EncodeBlock(chars, syms);   { 初回ぶんを済ませる }
    for t := 0 to m.SymbolsPerBlock - 1 do
    begin
      SymbolToSoft(m, syms[t], soft);
      dec_.Input(soft);
    end;
    dec_.Process;

    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for k := 1 to BLOCKS do
      begin
        enc.EncodeBlock(chars, syms);
        for t := 0 to m.SymbolsPerBlock - 1 do
        begin
          SymbolToSoft(m, syms[t], soft);
          dec_.Input(soft);
        end;
        dec_.Process;
      end;
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0,
      Format('%d ブロックの符号化と復号で確保 0 回 (実測 %d)', [BLOCKS, n]));
  finally
    enc.Free; dec_.Free;
  end;

  g1 := RoundTripNoisy(m, chars, 1.5, 12345, False);
  g2 := RoundTripNoisy(m, chars, 1.5, 12345, False);
  Check(SameChars(g1, g2), '同じ入力から同じ結果 (Z-05)');

  { Reset で環が空になり、前のブロックを持ち越さない。 }
  dec_ := TOliviaBlockDecoder.Create(m);
  try
    enc := TOliviaBlockEncoder.Create(m);
    try
      enc.EncodeBlock(chars, syms);
    finally
      enc.Free;
    end;
    for t := 0 to m.SymbolsPerBlock - 1 do
    begin
      SymbolToSoft(m, syms[t], soft);
      dec_.Input(soft);
    end;
    CheckEqI(dec_.FedSymbols, m.SymbolsPerBlock, '入れたシンボル数を数えている');
    dec_.Reset;
    CheckEqI(dec_.FedSymbols, 0, 'Reset でシンボル数が 0 に戻る');
    dec_.Process;
    n := 0;
    for i := 0 to m.CharsPerBlock - 1 do
      if dec_.OutputChar(i) <> 0 then Inc(n);
    CheckEqI(n, 0, 'Reset 直後は空の環を読むので文字は出ない');
  finally
    dec_.Free;
  end;
end;

begin
  WriteLn('=== Olivia / Contestia の符号の層の試験 ===');

  TestHadamard;
  TestKnownAnswers;
  TestRoundTrip;
  TestContestiaAlphabet;
  TestErrorTolerance;
  TestSoftBeatsHard;
  TestScramblingSpreadsTones;
  TestDiagonalSpreadsCharacters;
  TestSyncMetric;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('OLV-001');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
