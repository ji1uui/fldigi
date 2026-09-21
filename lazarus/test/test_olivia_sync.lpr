{ ============================================================================
  test_olivia_sync.lpr

  Olivia / Contestia の**ブロックの頭出し**の試験 (units/OliviaSync.pas)。

  何を守るか
  ----------------------------------------------------------------------------
  1. 切れ目の候補の数と、掴んだ位相が受信開始位置と対応すること
  2. **どこから受け始めても本文が出る** (1 ブロックぶん全部の位置を掃く)
      および、切れ目の違う相手に切り替わっても掴み直すこと
  3. 音を入れてから文字が出るまでの遅れを実測で残す
  4. 雑音に対する強さを数字で残す
  5. **無音でも雑音だけでも喋らない** (S/N の門)
  6. 門を下げれば喋り出す (門が効いている証拠)
  7. Contestia でも成立する
  8. 周波数のずれは外から与えれば読める。実際に使われる諸元をひととおり。
      中心周波数の既定値
  9. Reset で前の音を持ち越さない
  10. 確保しない (X-04) / 同じ音から同じ結果 (Z-05)

  2 が核心である。Olivia には前置き符号も同期語も無いので、切れ目は
  **復号してみた結果の良さ**からしか決められない。1 ブロック 64 シンボルの
  どこから聞き始めても同じ文が出ることを、全部の位置で確かめる。

  5 を外すと「受信できている」ように見える試験が作れてしまう ――
  門が無ければ雑音からでも何か出るので、**出ないことも試験に要る**。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_olivia_sync;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, OliviaBlock, OliviaTones, OliviaSync,
  TestVectors, Requirements;

type
  TDArr = array of Double;

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
  MSG = 'CQ CQ DE JI1UUI K ';
  { 尻尾に流す空きブロックの数。鎖の遅れぶん以上に要る。 }
  TAIL_BLOCKS = 12;

{ ==========================================================================
  送信側

  ALeadSymbols だけ遅らせて本文を始める。遅らせるのに無音ではなく
  **NUL を符号化したブロックの途中から**出すのは、実運用に近づけるため
  である。無音から始めると、同期が掴むのは本文の先頭からになってしまい、
  「途中から聞き始める」試験にならない。

  AMsgStart には、本文の最初のブロックを何シンボル目から出したかを返す。
  遅れを実測するのに使う。
  ========================================================================== }
function MakeAudio(const ATone: TOliviaToneMode; const AText: string;
  ALeadSymbols: Integer; ANoiseRms: Double; ASeed: QWord;
  out AMsgStart: Integer; ACentreHz: Double = 1000): TDArr;
var
  bm: TOliviaMode;
  enc: TOliviaBlockEncoder;
  mo: TOliviaModulator;
  chars, syms: array of Byte;
  buf: TDArr;
  rnd: TVectorRandom;
  i, k, p, nblk, total, w, sym: Integer;
begin
  rnd.Seed(ASeed);
  bm := ATone.BlockMode;
  enc := TOliviaBlockEncoder.Create(bm);
  mo := TOliviaModulator.Create(ATone, ACentreHz);
  try
    SetLength(chars, bm.CharsPerBlock);
    SetLength(syms, bm.SymbolsPerBlock);
    SetLength(buf, ATone.SymbolSepar);
    nblk := (Length(AText) + bm.CharsPerBlock - 1) div bm.CharsPerBlock;
    total := (ALeadSymbols + (nblk + TAIL_BLOCKS) * bm.SymbolsPerBlock + 2)
             * ATone.SymbolSepar;
    SetLength(Result, total);
    for i := 0 to total - 1 do Result[i] := 0;
    w := 0;
    sym := 0;

    { 頭: NUL ブロックの途中から。 }
    for i := 0 to bm.CharsPerBlock - 1 do chars[i] := 0;
    enc.EncodeBlock(chars, syms);
    for i := bm.SymbolsPerBlock - ALeadSymbols to bm.SymbolsPerBlock - 1 do
    begin
      if i < 0 then Continue;
      mo.Send(syms[i], buf);
      for k := 0 to ATone.SymbolSepar - 1 do
      begin
        Result[w] := buf[k];
        Inc(w);
      end;
      Inc(sym);
    end;

    AMsgStart := sym;

    { 本文。 }
    for p := 0 to nblk - 1 do
    begin
      for i := 0 to bm.CharsPerBlock - 1 do
        if p * bm.CharsPerBlock + i < Length(AText) then
          chars[i] := Ord(AText[p * bm.CharsPerBlock + i + 1])
        else
          chars[i] := 0;
      enc.EncodeBlock(chars, syms);
      for i := 0 to bm.SymbolsPerBlock - 1 do
      begin
        mo.Send(syms[i], buf);
        for k := 0 to ATone.SymbolSepar - 1 do
        begin
          Result[w] := buf[k];
          Inc(w);
        end;
        Inc(sym);
      end;
    end;

    { 尻尾: NUL ブロックを繰り返して押し出す。 }
    for i := 0 to bm.CharsPerBlock - 1 do chars[i] := 0;
    for p := 0 to TAIL_BLOCKS - 1 do
    begin
      enc.EncodeBlock(chars, syms);
      for i := 0 to bm.SymbolsPerBlock - 1 do
      begin
        mo.Send(syms[i], buf);
        for k := 0 to ATone.SymbolSepar - 1 do
          if w <= High(Result) then
          begin
            Result[w] := buf[k];
            Inc(w);
          end;
      end;
    end;
  finally
    enc.Free; mo.Free;
  end;

  if ANoiseRms > 0 then
    for k := 0 to High(Result) do
      Result[k] := Result[k] + ANoiseRms * rnd.NextGauss;
end;

{ ==========================================================================
  受信側

  AFirstMsgSymbol には、本文の先頭が出てきたときの通算シンボル数を返す
  (出なければ -1)。
  ========================================================================== }
function Receive(const ATone: TOliviaToneMode; const AWave: TDArr;
  out ABestPhase: Integer; out ASnr: Double; out ABlocks: Int64;
  AFreqOffset: Integer = 0; AThreshold: Double = -1;
  AFirstMsgSymbol: PInteger = nil; ACentreHz: Double = 1000): string;
var
  sy: TOliviaSync;
  buf: TDArr;
  i, k, n: Integer;
  ch: Byte;
  firstAt: Integer;
begin
  sy := TOliviaSync.Create(ATone, ACentreHz);
  try
    if AThreshold >= 0 then sy.Threshold := AThreshold;
    sy.FreqOffset := AFreqOffset;
    SetLength(buf, ATone.SymbolSepar);
    Result := '';
    firstAt := -1;
    for i := 0 to Length(AWave) div ATone.SymbolSepar - 1 do
    begin
      for k := 0 to ATone.SymbolSepar - 1 do
        buf[k] := AWave[i * ATone.SymbolSepar + k];
      if sy.Process(buf) then
        for n := 0 to ATone.BlockMode.CharsPerBlock - 1 do
        begin
          ch := sy.OutputChar(n);
          if ch <> 0 then
          begin
            if (firstAt < 0) and (ch = Ord(MSG[1])) then firstAt := i;
            Result := Result + Chr(ch);
          end;
        end;
    end;
    ABestPhase := sy.BestPhase;
    ASnr := sy.SyncSnr;
    ABlocks := sy.BlocksOut;
    if AFirstMsgSymbol <> nil then AFirstMsgSymbol^ := firstAt;
  finally
    sy.Free;
  end;
end;

{ --------------------------------------------------------------------------
  1. 切れ目の候補
  -------------------------------------------------------------------------- }
procedure TestPhaseCount;
var
  m: TOliviaToneMode;
  sy: TOliviaSync;
begin
  WriteLn;
  WriteLn('--- 1. 切れ目の候補 ---');
  m := OLIVIA_32_1000;
  sy := TOliviaSync.Create(m, 1000);
  try
    WriteLn(Format('        %s / 切れ目 %d 通り / 遅れ %d シンボル (%.2f 秒)',
      [m.Describe, sy.BlockPhases, sy.LatencySymbols,
       sy.LatencySymbols / m.BaudRate]));
    CheckEqI(sy.BlockPhases, OLIVIA_SLICES * m.BlockMode.SymbolsPerBlock,
      '切れ目の数は spectrum の枚数 x 1 ブロックのシンボル数');
    CheckEqI(sy.BlockPhases, 128, 'Olivia 32/1000 では 128 通り');
    Check(sy.SyncSnr = 0, '作った直後は S/N が 0');
    CheckEqI(sy.BlocksOut, 0, '作った直後はまだ何も出していない');
  finally
    sy.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. どこから受け始めても本文が出る
  -------------------------------------------------------------------------- }
procedure TestPullInFromAnyOffset;
var
  m: TOliviaToneMode;
  w: TDArr;
  got: string;
  lead, msgStart, phase, bad, phaseBad, worstJunk, at: Integer;
  snr: Double;
  blocks: Int64;
begin
  WriteLn;
  WriteLn('--- 2. どこから受け始めても本文が出る ---');
  m := OLIVIA_32_1000;
  bad := 0; phaseBad := 0; worstJunk := 0;
  WriteLn('          頭の空回し   掴んだ位相   期待   本文の前のごみ');
  lead := 0;
  while lead < m.BlockMode.SymbolsPerBlock do
  begin
    w := MakeAudio(m, MSG, lead, 0, 1, msgStart);
    got := Receive(m, w, phase, snr, blocks);
    at := Pos(MSG, got);
    if at < 1 then Inc(bad)
    else if (at - 1) > worstJunk then worstJunk := at - 1;
    { 1 シンボル遅らせると切れ目は 2 つ進む (spectrum が 2 枚あるため)。
      基準は空回し 0 のときの位相 1。 }
    if phase <> (2 * lead + 1) mod (OLIVIA_SLICES * m.BlockMode.SymbolsPerBlock)
      then Inc(phaseBad);
    if (lead mod 8) = 0 then
      WriteLn(Format('          %8d   %8d   %6d   %s',
        [lead, phase, (2 * lead + 1) mod 128,
         BoolToStr(at >= 1, IntToStr(at - 1) + ' 文字', '出なかった')]));
    Inc(lead);
  end;
  CheckEqI(bad, 0,
    Format('**1 ブロック %d 通りすべての開始位置で本文が出る**',
      [m.BlockMode.SymbolsPerBlock]));
  { 途中から聞き始めると、最初の 1 ブロックは窓が本文にかかりきらず
    ごみになることがある。**1 ブロックぶんを超えてはいけない** ――
    超えるなら切れ目を掴み損ねている。 }
  Check(worstJunk <= m.BlockMode.CharsPerBlock,
    Format('本文の前に出るごみが 1 ブロック (%d 文字) を超えない (最悪 %d)',
      [m.BlockMode.CharsPerBlock, worstJunk]));
  CheckEqI(phaseBad, 0,
    '**掴んだ切れ目が受信開始位置と一対一に対応する** (1 シンボルずれで 2 進む)');
end;

{ --------------------------------------------------------------------------
  2b. 相手が変わったら掴み直す

  同じ周波数で、**切れ目の違う** 2 つの送信が続けて来る場面である
  (交信相手が変われば必ず起きる)。一度掴んだ切れ目に張り付いてしまうと、
  二人目がまったく読めなくなる。

  記録は「上がったときだけ」ではなく、**いま居る位相のぶんは毎回書き直す**
  必要がある。そうしないと、一度上がった値が下がらず、新しい切れ目が
  古い記録を越えられない。
  -------------------------------------------------------------------------- }
procedure TestReacquireOnNewStation;
const
  MSG_A = 'DE JA1ZZZ JA1ZZZ K ';
  MSG_B = 'DE JI1UUI JI1UUI JI1UUI JI1UUI K ';
  { 掴み直す間に落とす文字を許す数。実測 (下の表) から決めた。 }
  REACQUIRE_LOSS = 12;
var
  m: TOliviaToneMode;
  wa, wb, both: TDArr;
  got, tailB: string;
  i, sa, sb, phase, posA, posB, wantPhase, symsBeforeB: Integer;
  snr: Double;
  blocks: Int64;
begin
  WriteLn;
  WriteLn('--- 2b. 切れ目の違う相手に切り替わっても掴み直す ---');
  m := OLIVIA_32_1000;
  wa := MakeAudio(m, MSG_A, 5, 0, 1, sa);
  wb := MakeAudio(m, MSG_B, 40, 0, 2, sb);

  SetLength(both, Length(wa) + Length(wb));
  for i := 0 to High(wa) do both[i] := wa[i];
  for i := 0 to High(wb) do both[Length(wa) + i] := wb[i];

  got := Receive(m, both, phase, snr, blocks);

  { 二人目の切れ目は、一人目の音の長さと二人目の頭の空回しから決まる。 }
  symsBeforeB := Length(wa) div m.SymbolSepar + sb;
  wantPhase := (2 * symsBeforeB + 1)
               mod (OLIVIA_SLICES * m.BlockMode.SymbolsPerBlock);

  posA := Pos(MSG_A, got);
  { 掴み直す間に頭を落とすので、本文の**後ろ半分**で探す。 }
  tailB := Copy(MSG_B, REACQUIRE_LOSS + 1, Length(MSG_B) - REACQUIRE_LOSS);
  posB := Pos(tailB, got);

  WriteLn('        [', got, ']');
  WriteLn(Format('        一人目 %d 文字目 / 二人目の後半 %d 文字目',
    [posA, posB]));
  WriteLn(Format('        最後に掴んだ切れ目 %d / 二人目の切れ目 %d',
    [phase, wantPhase]));
  Check(posA > 0, '一人目が読める');
  CheckEqI(phase, wantPhase,
    '**二人目の切れ目を掴み直している** (張り付いていない)');
  Check(posB > 0,
    Format('**掴み直したあとの二人目が読める** (頭 %d 文字は落ちる)',
      [REACQUIRE_LOSS]));
  Check(posB > posA, '順番どおりに出る');
end;

{ --------------------------------------------------------------------------
  3. 遅れの実測
  -------------------------------------------------------------------------- }
procedure TestLatency;
var
  m: TOliviaToneMode;
  w: TDArr;
  msgStart, firstAt, phase: Integer;
  snr: Double;
  blocks: Int64;
  sy: TOliviaSync;
  theory: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 音を入れてから文字が出るまでの遅れ ---');
  m := OLIVIA_32_1000;
  w := MakeAudio(m, MSG, 17, 0, 1, msgStart);
  Receive(m, w, phase, snr, blocks, 0, -1, @firstAt);

  sy := TOliviaSync.Create(m, 1000);
  try
    theory := sy.LatencySymbols;
  finally
    sy.Free;
  end;

  WriteLn(Format('        本文を %d シンボル目から出し、%d シンボル目に出てきた',
    [msgStart, firstAt]));
  WriteLn(Format('        遅れ 実測 %d シンボル (%.2f 秒) / 計算 %d',
    [firstAt - msgStart, (firstAt - msgStart) / m.BaudRate, theory]));
  Check(firstAt > msgStart, '前提: 本文が出てきている');
  Check(Abs((firstAt - msgStart) - theory) <= m.BlockMode.SymbolsPerBlock,
    Format('**遅れが計算どおり** (実測 %d / 計算 %d / 許容 ±%d)',
      [firstAt - msgStart, theory, m.BlockMode.SymbolsPerBlock]));
end;

{ --------------------------------------------------------------------------
  4. 雑音に対する強さ
  -------------------------------------------------------------------------- }
procedure TestNoise;
const
  TRIALS = 4;
var
  m: TOliviaToneMode;
  w, clean: TDArr;
  got: string;
  i, k, msgStart, phase, ok: Integer;
  snr, sigPwr, wideSnr, firstFail: Double;
  blocks: Int64;
  foundFail: Boolean;
  rms: array[0..6] of Double = (0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
begin
  WriteLn;
  WriteLn('--- 4. 雑音に対する強さ ---');
  m := OLIVIA_32_1000;
  clean := MakeAudio(m, MSG, 17, 0, 1, msgStart);
  sigPwr := 0;
  for k := 0 to High(clean) do sigPwr := sigPwr + clean[k] * clean[k];
  sigPwr := sigPwr / Length(clean);

  WriteLn('          雑音rms   広帯域S/N   本文が出た回数   同期S/N');
  foundFail := False; firstFail := 0;
  for i := 0 to High(rms) do
  begin
    ok := 0; snr := 0;
    for k := 1 to TRIALS do
    begin
      w := MakeAudio(m, MSG, 17, rms[i], QWord(7919 * k + 5), msgStart);
      got := Receive(m, w, phase, snr, blocks);
      if Pos(MSG, got) > 0 then Inc(ok);
    end;
    if rms[i] > 0 then wideSnr := 10 * Log10(sigPwr / (rms[i] * rms[i]))
    else wideSnr := 0;
    if rms[i] > 0 then
      WriteLn(Format('          %6.2f   %7.1f dB   %8d / %d      %6.2f',
        [rms[i], wideSnr, ok, TRIALS, snr]))
    else
      WriteLn(Format('          %6.2f    (無雑音)   %8d / %d      %6.2f',
        [rms[i], ok, TRIALS, snr]));
    if (not foundFail) and (ok < TRIALS) then
    begin
      foundFail := True;
      firstFail := wideSnr;
    end;
  end;
  Check(foundFail, '掃引が崖を跨いでいる (雑音を増やせば必ず崩れる)');
  if foundFail then
    WriteLn(Format('        初めて落とした広帯域 S/N: %.1f dB', [firstFail]));

  { 実用域の主張。 }
  ok := 0;
  for k := 1 to TRIALS do
  begin
    w := MakeAudio(m, MSG, 17, 3.0, QWord(104729 * k + 7), msgStart);
    got := Receive(m, w, phase, snr, blocks);
    if Pos(MSG, got) = 1 then Inc(ok);
  end;
  CheckEqI(ok, TRIALS, '**雑音 rms 3.0 では 4 種の種すべてで本文が出る**');
end;

{ --------------------------------------------------------------------------
  5-6. 喋らないこと / 門を下げれば喋ること
  -------------------------------------------------------------------------- }
procedure TestSquelch;
var
  m: TOliviaToneMode;
  w: TDArr;
  got: string;
  i, k, phase, msgStart: Integer;
  snr: Double;
  blocks, loudBlocks: Int64;
  rnd: TVectorRandom;
begin
  WriteLn;
  WriteLn('--- 5. 無音でも雑音だけでも喋らない ---');
  m := OLIVIA_32_1000;

  { 無音。 }
  SetLength(w, 600 * m.SymbolSepar);
  for i := 0 to High(w) do w[i] := 0;
  got := Receive(m, w, phase, snr, blocks);
  WriteLn(Format('        無音 %d シンボル: ブロック %d / 文字 %d / S/N %.3f',
    [600, blocks, Length(got), snr]));
  CheckEqI(blocks, 0, '**無音では一つも出さない**');

  { 雑音だけ。信号と同じくらいの大きさで。 }
  rnd.Seed(20260920);
  for i := 0 to High(w) do w[i] := 1.0 * rnd.NextGauss;
  got := Receive(m, w, phase, snr, blocks);
  WriteLn(Format('        雑音だけ rms 1.0: ブロック %d / 文字 %d / S/N %.3f',
    [blocks, Length(got), snr]));
  CheckEqI(blocks, 0, '**雑音だけでは一つも出さない**');

  WriteLn;
  WriteLn('--- 6. 門を下げれば喋り出す ---');
  { 門が 0 なら、同じ雑音から何か出るはず。出なければ門が効いている
    証拠にならない ―― 出ないのが門のおかげなのか、そもそも出ないのかを
    区別できない。 }
  got := Receive(m, w, phase, snr, loudBlocks, 0, 0.0);
  WriteLn(Format('        門を 0 にすると: ブロック %d / 文字 %d',
    [loudBlocks, Length(got)]));
  Check(loudBlocks > 0,
    Format('**門を下げると雑音からでも出す** (%d ブロック)', [loudBlocks]));
  Check(loudBlocks > blocks, '門が出力を止めていた');
end;

{ --------------------------------------------------------------------------
  7. Contestia
  -------------------------------------------------------------------------- }
procedure TestContestia;
var
  m: TOliviaToneMode;
  w: TDArr;
  got, want: string;
  msgStart, phase: Integer;
  snr: Double;
  blocks: Int64;
begin
  WriteLn;
  WriteLn('--- 7. Contestia ---');
  m := CONTESTIA_32_1000;
  { Contestia の表は大文字だけである。小文字を送ると大文字で戻る。 }
  want := 'CQ CQ DE JI1UUI K ';
  w := MakeAudio(m, want, 11, 0, 1, msgStart);
  got := Receive(m, w, phase, snr, blocks);
  WriteLn(Format('        1 ブロック %d シンボル / 切れ目 %d 通り / S/N %.2f',
    [m.BlockMode.SymbolsPerBlock,
     OLIVIA_SLICES * m.BlockMode.SymbolsPerBlock, snr]));
  WriteLn('        [', got, ']');
  Check(Pos(want, got) > 0, '**Contestia でも本文が出る**');
end;

{ --------------------------------------------------------------------------
  8. 周波数のずれ
  -------------------------------------------------------------------------- }
procedure TestFrequencyOffset;
var
  m: TOliviaToneMode;
  w: TDArr;
  got: string;
  msgStart, phase, off, okWith, okWithout, i: Integer;
  snr: Double;
  blocks: Int64;
  offs: array[0..2] of Integer = (-4, 0, 4);
begin
  WriteLn;
  WriteLn('--- 8. 周波数のずれは外から与えれば読める ---');
  m := OLIVIA_32_1000;
  okWith := 0; okWithout := 0;
  for i := 0 to High(offs) do
  begin
    off := offs[i];
    w := MakeAudio(m, MSG, 17, 0, 1, msgStart,
      1000 + off * m.BinWidthHz);
    got := Receive(m, w, phase, snr, blocks, off);
    if Pos(MSG, got) = 1 then Inc(okWith);
    got := Receive(m, w, phase, snr, blocks, 0);
    if Pos(MSG, got) = 1 then Inc(okWithout);
    WriteLn(Format('          ずれ %2d bin: 補正あり %s / 補正なし %s',
      [off, BoolToStr(okWith > i, '一致', '×'),
       BoolToStr(Pos(MSG, got) = 1, '一致', '×')]));
  end;
  CheckEqI(okWith, Length(offs), '**ずらし量を与えれば読める**');
  CheckEqI(okWithout, 1, '前提: 与えなければ合っている 1 つしか読めない');
end;

{ --------------------------------------------------------------------------
  8b. 諸元をひととおり

  要求の文面は「Olivia/Contestia」であって「Olivia 32/1000」ではない。
  ここまでの試験は 32/1000 を中心に見てきたので、**実際に使われる諸元を
  ひととおり**通しておく。要求の覆う範囲と試験の範囲を合わせるためで、
  §36 §37 §40 で繰り返した轍を踏まないための試験である。

  1 ブロックのシンボル数は文字あたりのビット数だけで決まるので、
  トーン数を変えても切れ目の候補は 128 (Contestia は 64) のまま。
  変わるのは 1 ブロックが運ぶ文字数と、シンボル長である。
  -------------------------------------------------------------------------- }
type
  TVariantCase = record
    Bits, Bw: Integer;
    Variant_: TOliviaVariant;
    Centre: Double;
  end;

function RunVariant(const AC: TVariantCase; out ANote: string): Boolean;
var
  m: TOliviaToneMode;
  bm: TOliviaMode;
  w: TDArr;
  got: string;
  msgStart, phase: Integer;
  snr: Double;
  blocks: Int64;
begin
  m.Variant_ := AC.Variant_;
  m.BitsPerSymbol := AC.Bits;
  m.BandwidthHz := AC.Bw;
  m.SampleRate := 8000;
  bm := m.BlockMode;
  w := MakeAudio(m, MSG, 7, 0, 1, msgStart, AC.Centre);
  got := Receive(m, w, phase, snr, blocks, 0, -1, nil, AC.Centre);
  Result := Pos(MSG, got) > 0;
  ANote := Format('SymLen %4d / %.3f baud / 1ブロック %d 文字 / 切れ目 %3d / S/N %5.2f',
    [m.SymbolLen, m.BaudRate, bm.CharsPerBlock,
     OLIVIA_SLICES * bm.SymbolsPerBlock, snr]);
  if not Result then ANote := ANote + '  [' + got + ']';
end;

procedure TestStandardVariants;
var
  cases: array[0..8] of TVariantCase = (
    (Bits: 2; Bw:  125; Variant_: ovOlivia;    Centre: 1000),
    (Bits: 3; Bw:  250; Variant_: ovOlivia;    Centre: 1000),
    (Bits: 3; Bw:  500; Variant_: ovOlivia;    Centre: 1000),
    (Bits: 4; Bw:  500; Variant_: ovOlivia;    Centre: 1000),
    (Bits: 4; Bw: 1000; Variant_: ovOlivia;    Centre: 1500),
    (Bits: 5; Bw:  500; Variant_: ovOlivia;    Centre: 1000),
    (Bits: 5; Bw: 1000; Variant_: ovOlivia;    Centre: 1000),
    (Bits: 6; Bw: 2000; Variant_: ovOlivia;    Centre: 1500),
    (Bits: 5; Bw: 1000; Variant_: ovContestia; Centre: 1000));
  i, bad: Integer;
  note: string;
begin
  WriteLn;
  WriteLn('--- 8b. 実際に使われる諸元をひととおり ---');
  bad := 0;
  for i := 0 to High(cases) do
  begin
    if not RunVariant(cases[i], note) then Inc(bad);
    WriteLn(Format('          %s %3d/%-4d  %s  %s',
      [BoolToStr(cases[i].Variant_ = ovContestia, 'C', 'O'),
       1 shl cases[i].Bits, cases[i].Bw,
       BoolToStr(Pos('[', note) = 0, '出た', '出ない'), note]));
  end;
  CheckEqI(bad, 0,
    Format('**%d 通りの諸元すべてで本文が出る** (Olivia 4..64 トーン / Contestia)',
      [Length(cases)]));
end;

{ --------------------------------------------------------------------------
  8c. 中心周波数を指定しなかったとき

  既定値は黙って効く。試験から呼ばれていないと、変えたことに誰も
  気づかない ―― 実際、説明できない式が既定になっていた。
  -------------------------------------------------------------------------- }
procedure TestDefaultCentre;
var
  m: TOliviaToneMode;
  mo: TOliviaModulator;
  de: TOliviaDemodulator;
  sy: TOliviaSync;
begin
  WriteLn;
  WriteLn('--- 8c. 中心周波数の既定値 ---');
  m := OLIVIA_32_1000;
  mo := TOliviaModulator.Create(m);
  de := TOliviaDemodulator.Create(m);
  sy := TOliviaSync.Create(m);
  try
    WriteLn(Format('        既定 %.1f Hz / 送信の bin %d / 受信の bin %d / 探索幅 ±%d bin',
      [mo.CentreHz, mo.FirstCarrier, de.FirstCarrier, sy.DecodeMargin]));
    Check(mo.CentreHz = OLIVIA_DEFAULT_CENTRE_HZ,
      Format('既定の中心周波数は %.0f Hz', [OLIVIA_DEFAULT_CENTRE_HZ]));
    CheckEqI(mo.FirstCarrier, de.FirstCarrier, '送受で同じ bin に置く');
    CheckEqI(mo.FirstCarrier, 33, 'Olivia 32/1000 の既定では bin 33');
    Check(sy.DecodeMargin > 0, '周波数のずれを探せる幅がある');
  finally
    mo.Free; de.Free; sy.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9-10. Reset / 確保しない / 決定性
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

procedure TestResetAndDeterminism;
var
  m: TOliviaToneMode;
  w, other: TDArr;
  got1, got2: string;
  sy: TOliviaSync;
  buf: TDArr;
  i, k, n, msgStart, phase: Integer;
  snr: Double;
  blocks: Int64;
begin
  WriteLn;
  WriteLn('--- 9. Reset で前の音を持ち越さない ---');
  m := OLIVIA_32_1000;
  w := MakeAudio(m, MSG, 17, 0, 1, msgStart);
  other := MakeAudio(m, 'DE JA1ZZZ TEST ', 5, 1.0, 999, i);

  got1 := Receive(m, w, phase, snr, blocks);

  sy := TOliviaSync.Create(m, 1000);
  try
    SetLength(buf, m.SymbolSepar);
    { 別の音を通してから Reset し、同じ音を流す。 }
    for i := 0 to Length(other) div m.SymbolSepar - 1 do
    begin
      for k := 0 to m.SymbolSepar - 1 do
        buf[k] := other[i * m.SymbolSepar + k];
      sy.Process(buf);
    end;
    sy.Reset;
    got2 := '';
    for i := 0 to Length(w) div m.SymbolSepar - 1 do
    begin
      for k := 0 to m.SymbolSepar - 1 do
        buf[k] := w[i * m.SymbolSepar + k];
      if sy.Process(buf) then
        for n := 0 to m.BlockMode.CharsPerBlock - 1 do
          if sy.OutputChar(n) <> 0 then
            got2 := got2 + Chr(sy.OutputChar(n));
    end;
  finally
    sy.Free;
  end;
  Check(got1 = got2,
    '**Reset のあとは前の音の痕跡が残らない** (文字列まで一致)');
  Check(Pos(MSG, got1) = 1, '前提: その文が正しい');

  WriteLn;
  WriteLn('--- 10. 確保しない (X-04) / 同じ音から同じ結果 (Z-05) ---');
  sy := TOliviaSync.Create(m, 1000);
  try
    SetLength(buf, m.SymbolSepar);
    for k := 0 to m.SymbolSepar - 1 do buf[k] := w[k];
    sy.Process(buf);    { 初回ぶんを済ませる }

    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for i := 1 to 300 do
      begin
        for k := 0 to m.SymbolSepar - 1 do
          buf[k] := w[(i mod 100) * m.SymbolSepar + k];
        sy.Process(buf);
      end;
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0, Format('300 シンボル処理で確保 0 回 (実測 %d)', [n]));
  finally
    sy.Free;
  end;

  got2 := Receive(m, w, phase, snr, blocks);
  Check(got1 = got2, '同じ音から同じ結果 (Z-05)');
end;

begin
  WriteLn('=== Olivia / Contestia のブロックの頭出しの試験 ===');

  TestPhaseCount;
  TestPullInFromAnyOffset;
  TestReacquireOnNewStation;
  TestLatency;
  TestNoise;
  TestSquelch;
  TestContestia;
  TestFrequencyOffset;
  TestStandardVariants;
  TestDefaultCentre;
  TestResetAndDeterminism;

  if FailCount = 0 then
    CoverReq('OLV-004');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
