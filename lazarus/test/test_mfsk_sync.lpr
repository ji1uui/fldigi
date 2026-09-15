{ ============================================================================
  test_mfsk_sync.lpr

  MFSK の**シンボル同期の追尾**の試験 (units/MfskTones.pas)。

  何を守るか
  ----------------------------------------------------------------------------
  1. 揃っている音では追尾が悪さをしない
  2. **半シンボルずれた音を引き込む** (追尾を切ると崩れる)
  3. 任意のずれから引き込む (0..SymLen-1 を掃く)
  4. **送受のサンプル速度が違っても追い続ける**
  5. 残るずれが理屈どおりの値になる (比例だけの輪なので残る)
  6. 山が一つに決まらない場合は手を出さない (三つの門)
  7. 補正に上限があり、区切りが消えない
  8. 取り込みで確保しない (X-04) / 同じ音から同じ結果 (Z-05)
  9. MFSK32 でも同じ理屈が通る

  なぜ「ずれた音が復調できる」だけでは足りないか
  ----------------------------------------------------------------------------
  硬判定は**ずれに強い**。窓が二つのシンボルにまたがっても、長く重なった
  ほうのトーンが勝つので、ずれが半シンボルに近づくまで答えは変わらない。
  実測で、追尾を切ったまま 128 サンプル (シンボルの 1/4) ずらしても
  トーンは全部当たる。つまり「ずらして復調できた」という試験は、
  **追尾を消しても通ってしまう**。

  引き込みには時間が要る
  ----------------------------------------------------------------------------
  ちょうど半シンボルずれた状態は、硬判定が五分五分になる**最悪の点**である。
  ここから引き込む間は取りこぼしが出る。追尾が悪いのではなく、
  そもそも判定材料が無い。だから主張は「一つも落とさない」ではなく
  **「1 秒 (16 シンボル) 以内に掴み、以降は落とさない」**にしてある。
  上流が送信の頭に 107 ビットの前置きを流すのも同じ理由である。

  そこで二つの見方を足してある。
    - ずれを**半シンボル**ちょうどに置く。ここだけは硬判定が割れる。
    - 硬判定ではなく**軟判定の余裕**を測る。ずれていれば余裕が痩せる。
      余裕は次段の Viterbi がそのまま食う量なので、実害に直結する。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_mfsk_sync;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, MfskTones, TestSupport, Requirements;

type
  TDoubleArr = array of Double;
  TIntegerArray = array of Integer;

const
  { 引き込みの期限。ちょうど半シンボルずれた最悪の点から掴むまでに
    許す長さ。MFSK16 で 16 シンボル = 1.02 秒。 }
  LOCK_SYMBOLS = 16;

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

{ ==========================================================================
  送信側

  ALeadSamples : 頭に置く無音。受信の区切りを意図的にずらすために使う。
  APpm         : 送信側のサンプル速度のずれ。正なら送信が速い =
                 受信から見てシンボルが短くなる。送受の水晶の違いである。
  ========================================================================== }
function Modulate(const AMode: TMfskMode; const ASymbols: array of Integer;
  ALeadSamples: Integer = 0; APpm: Double = 0): TDoubleArr;
var
  i, k, tone, total, startK, endK: Integer;
  phase, f, step, symLenRx: Double;
begin
  { 受信から見た 1 シンボルのサンプル数。 }
  symLenRx := AMode.SymLen / (1.0 + APpm * 1E-6);
  total := ALeadSamples + Ceil(Length(ASymbols) * symLenRx) + 1;
  SetLength(Result, total);
  for i := 0 to total - 1 do Result[i] := 0;

  phase := 0;
  for i := 0 to High(ASymbols) do
  begin
    tone := MfskSymbolToTone(ASymbols[i]);
    f := AMode.BaseFreqHz + tone * AMode.ToneSpacingHz;
    step := 2 * Pi * f / AMode.SampleRate;
    startK := ALeadSamples + Round(i * symLenRx);
    endK := ALeadSamples + Round((i + 1) * symLenRx);
    for k := startK to endK - 1 do
    begin
      if k <= High(Result) then Result[k] := Cos(phase);
      phase := phase + step;
      if phase > 2 * Pi then phase := phase - 2 * Pi;
    end;
  end;
end;

{ ==========================================================================
  受信して評価する

  戻すのは「送った並びとどれだけ合ったか」。受信の区切りがずれると
  切り出すシンボルが一つ増減するので、**並びのずらし幅を -3..3 で
  探してから**数える。ずらし幅そのものも返す。
  ========================================================================== }
type
  TSyncResult = record
    SymbolCount: Integer;
    IndexShift: Integer;      // 送った並びに対する添字のずれ
    Matched: Integer;         // 合った数 (ずらし幅を合わせたあと)
    Compared: Integer;
    LastMismatch: Integer;    // 最後に外した位置 (-1 なら一度も外していない)
    MeanMargin: Double;       // 後半の軟判定余裕の平均 (128 からの距離)
    FinalSyncError: Double;
    MaxAdjust: Integer;
    Updates: Int64;
  end;

function RunDetector(const AMode: TMfskMode; const AWave: TDoubleArr;
  const ASymbols: array of Integer; ATracking: Boolean): TSyncResult;
var
  det: TMfskToneDetector;
  got, marg: array of Integer;
  i, n, b, sh, ok, best, bestSh, mm, cnt: Integer;
  msum: Double;
begin
  Result := Default(TSyncResult);
  SetLength(got, Length(ASymbols) + 8);
  SetLength(marg, Length(got));
  det := TMfskToneDetector.Create(AMode);
  try
    det.SyncTracking := ATracking;
    n := 0;
    for i := 0 to High(AWave) do
      if det.Feed(AWave[i]) then
      begin
        if n <= High(got) then
        begin
          got[n] := det.Symbol;
          mm := 255;
          for b := 0 to AMode.SymBits - 1 do
            if Abs(Integer(det.SoftBit(b)) - 128) < mm then
              mm := Abs(Integer(det.SoftBit(b)) - 128);
          marg[n] := mm;
        end;
        if Abs(det.SyncAdjust) > Result.MaxAdjust then
          Result.MaxAdjust := Abs(det.SyncAdjust);
        Inc(n);
      end;
    Result.SymbolCount := n;
    Result.FinalSyncError := det.SyncError;
    Result.Updates := det.SyncUpdates;
  finally
    det.Free;
  end;

  if n > High(got) + 1 then n := High(got) + 1;

  { --- 並びのずらし幅を探す --- }
  best := -1; bestSh := 0;
  for sh := -3 to 3 do
  begin
    ok := 0;
    for i := 0 to n - 1 do
      if (i + sh >= 0) and (i + sh <= High(ASymbols)) then
        if got[i] = MfskSymbolToTone(ASymbols[i + sh]) then Inc(ok);
    if ok > best then begin best := ok; bestSh := sh; end;
  end;
  Result.IndexShift := bestSh;
  Result.Matched := best;

  Result.Compared := 0;
  Result.LastMismatch := -1;
  for i := 0 to n - 1 do
    if (i + bestSh >= 0) and (i + bestSh <= High(ASymbols)) then
    begin
      Inc(Result.Compared);
      if got[i] <> MfskSymbolToTone(ASymbols[i + bestSh]) then
        Result.LastMismatch := i;
    end;

  { --- 後半の軟判定余裕 --- }
  msum := 0; cnt := 0;
  for i := n div 2 to n - 1 do
  begin
    msum := msum + marg[i];
    Inc(cnt);
  end;
  if cnt > 0 then Result.MeanMargin := msum / cnt;
end;

{ 決まった並び。隣り合うシンボルが同じにならないようにしてある
  (同じだと追尾の門で見送りになり、追尾そのものを見られない)。 }
function MakeSymbols(ACount, ANumTones: Integer): TIntegerArray;
var
  i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
    Result[i] := (i * 7 + 3) mod ANumTones;
end;

{ --------------------------------------------------------------------------
  1. 揃っている音では悪さをしない
  -------------------------------------------------------------------------- }
procedure TestAlignedIsUndisturbed;
var
  m: TMfskMode;
  syms: TIntegerArray;
  wave: TDoubleArr;
  on_, off: TSyncResult;
begin
  WriteLn;
  WriteLn('--- 1. 揃っている音では追尾が悪さをしない ---');
  m := MFSK16_MODE;
  syms := MakeSymbols(120, m.NumTones);
  wave := Modulate(m, syms);

  on_ := RunDetector(m, wave, syms, True);
  off := RunDetector(m, wave, syms, False);

  WriteLn(Format('        追尾あり: %d/%d 一致 / 余裕 %.1f / 残るずれ %.3f / 最大補正 %d',
    [on_.Matched, on_.Compared, on_.MeanMargin, on_.FinalSyncError, on_.MaxAdjust]));
  WriteLn(Format('        追尾なし: %d/%d 一致 / 余裕 %.1f',
    [off.Matched, off.Compared, off.MeanMargin]));

  CheckEqI(off.Compared - off.Matched, 0, '前提: 追尾なしで全一致 (揃っているので)');
  CheckEqI(on_.Compared - on_.Matched, 0,
    '**追尾を入れても全一致のまま** (揃っている音を壊さない)');
  Check(on_.MeanMargin > off.MeanMargin - 1.0,
    '軟判定の余裕が痩せない');
  { 追尾は動いてはいる (門で全部見送られているのではない) }
  Check(on_.Updates > 100, Format('追尾は働いている (%d 回)', [on_.Updates]));
  Check(Abs(on_.FinalSyncError) < 8.0,
    Format('残るずれが小さい (%.3f サンプル / シンボル %d の %.2f%%)',
      [on_.FinalSyncError, m.SymLen, 100 * Abs(on_.FinalSyncError) / m.SymLen]));
  Check(on_.MaxAdjust <= m.SymLen div m.NumTones + 1,
    Format('補正の大きさが上限 %d を超えない (最大 %d)',
      [m.SymLen div m.NumTones + 1, on_.MaxAdjust]));
end;

{ --------------------------------------------------------------------------
  2. 半シンボルずれ ―― ここが核心
  -------------------------------------------------------------------------- }
procedure TestHalfSymbolOffset;
var
  m: TMfskMode;
  syms: TIntegerArray;
  wave: TDoubleArr;
  on_, off: TSyncResult;
begin
  WriteLn;
  WriteLn('--- 2. 半シンボルずれた音 (硬判定が割れる唯一の点) ---');
  m := MFSK16_MODE;
  syms := MakeSymbols(120, m.NumTones);
  wave := Modulate(m, syms, m.SymLen div 2);

  on_ := RunDetector(m, wave, syms, True);
  off := RunDetector(m, wave, syms, False);

  WriteLn(Format('        追尾あり: %d/%d 一致 / 余裕 %.1f / 最後に外した位置 %d',
    [on_.Matched, on_.Compared, on_.MeanMargin, on_.LastMismatch]));
  WriteLn(Format('        追尾なし: %d/%d 一致 / 余裕 %.1f',
    [off.Matched, off.Compared, off.MeanMargin]));

  Check(on_.LastMismatch < LOCK_SYMBOLS,
    Format('**掴んだあとは一つも落とさない** (最後に外したのは %d 番目 / 期限 %d)',
      [on_.LastMismatch, LOCK_SYMBOLS]));
  Check(on_.Matched >= on_.Compared - LOCK_SYMBOLS,
    Format('落とすのは引き込みの間だけ (%d/%d)', [on_.Matched, on_.Compared]));
  Check(off.Matched < off.Compared * 3 div 4,
    Format('前提: 追尾を切ると最後まで崩れたまま (%d/%d しか当たらない)',
      [off.Matched, off.Compared]));
  Check(on_.MeanMargin > 2 * off.MeanMargin,
    Format('軟判定の余裕が倍以上になる (%.1f 対 %.1f)',
      [on_.MeanMargin, off.MeanMargin]));
end;

{ --------------------------------------------------------------------------
  3. どのずれからでも引き込む
  -------------------------------------------------------------------------- }
procedure TestPullInSweep;
var
  m: TMfskMode;
  syms: TIntegerArray;
  wave: TDoubleArr;
  r: TSyncResult;
  lead, bad, worstSettle: Integer;
  worstMargin: Double;
begin
  WriteLn;
  WriteLn('--- 3. ずれを掃く (0..SymLen-1) ---');
  m := MFSK16_MODE;
  syms := MakeSymbols(120, m.NumTones);
  bad := 0; worstSettle := -1; worstMargin := 255;
  WriteLn('          ずれ    一致     最後に外した位置   軟判定余裕   残るずれ');
  lead := 0;
  while lead < m.SymLen do
  begin
    wave := Modulate(m, syms, lead);
    r := RunDetector(m, wave, syms, True);
    if r.LastMismatch >= LOCK_SYMBOLS then Inc(bad);
    if r.LastMismatch > worstSettle then worstSettle := r.LastMismatch;
    if r.MeanMargin < worstMargin then worstMargin := r.MeanMargin;
    WriteLn(Format('          %4d   %3d/%3d          %4d          %5.1f      %7.3f',
      [lead, r.Matched, r.Compared, r.LastMismatch, r.MeanMargin,
       r.FinalSyncError]));
    Inc(lead, 64);
  end;
  CheckEqI(bad, 0,
    Format('**どのずれからでも %d シンボル以内に掴み、以降は落とさない**',
      [LOCK_SYMBOLS]));
  { 硬判定はずれに強いので、当たっただけでは追尾が効いた証拠にならない。
    軟判定の余裕まで戻っていることを見る。追尾を切ると半シンボルずれで
    44 まで痩せる (試験 2)。 }
  Check(worstMargin > 100,
    Format('**どのずれからでも軟判定の余裕が戻る** (最悪 %.1f)', [worstMargin]));
  Check(worstSettle + 1 <= LOCK_SYMBOLS,
    Format('引き込みに要するのが %d シンボル以内 (最悪 %d = %.2f 秒)',
      [LOCK_SYMBOLS, worstSettle + 1,
       (worstSettle + 1) * m.SymLen / m.SampleRate]));
end;

{ --------------------------------------------------------------------------
  4-5. 送受のサンプル速度差 と 残るずれ
  -------------------------------------------------------------------------- }
procedure TestClockDrift;
var
  m: TMfskMode;
  syms: TIntegerArray;
  wave: TDoubleArr;
  on_, off: TSyncResult;
  i, badOn: Integer;
  ppm, drift, predicted: Double;
  ppms: array[0..3] of Double = (-3000, -1000, 1000, 3000);
  worstRatio: Double;
begin
  WriteLn;
  WriteLn('--- 4-5. 送受のサンプル速度が違う場合 と 残るずれ ---');
  m := MFSK16_MODE;
  syms := MakeSymbols(200, m.NumTones);
  badOn := 0;
  worstRatio := 0;
  WriteLn('           ppm   追尾あり        追尾なし       残るずれ  理屈');
  for i := 0 to High(ppms) do
  begin
    ppm := ppms[i];
    wave := Modulate(m, syms, 0, ppm);
    on_ := RunDetector(m, wave, syms, True);
    off := RunDetector(m, wave, syms, False);
    if on_.LastMismatch >= LOCK_SYMBOLS then Inc(badOn);

    { 1 シンボルあたり何サンプルずれるか。送信が速い (ppm>0) と
      受信から見てシンボルが短くなるので、山は「思ったより新しい」
      側へ動く ―― SyncError は正になる。 }
    drift := m.SymLen * (1.0 - 1.0 / (1.0 + ppm * 1E-6));
    predicted := drift * m.NumTones;
    if Abs(predicted) > 1E-6 then
      if Abs(on_.FinalSyncError - predicted) / Abs(predicted) > worstRatio then
        worstRatio := Abs(on_.FinalSyncError - predicted) / Abs(predicted);

    WriteLn(Format('         %5.0f   %3d/%3d 余裕%5.1f  %3d/%3d 余裕%5.1f   %7.3f  %7.3f',
      [ppm, on_.Matched, on_.Compared, on_.MeanMargin,
       off.Matched, off.Compared, off.MeanMargin,
       on_.FinalSyncError, predicted]));
  end;
  CheckEqI(badOn, 0, '**時計が違っても掴んだあとは落とさない** (±3000 ppm)');
  Check(worstRatio < 0.15,
    Format('残るずれが「1シンボルあたりのずれ x トーン数」に一致する (誤差 %.1f%%)',
      [100 * worstRatio]));

  { 追尾を切ると 3000 ppm で崩れること。掃いた中で最も速い条件を使う。 }
  wave := Modulate(m, syms, 0, 3000);
  off := RunDetector(m, wave, syms, False);
  Check(off.Matched < off.Compared,
    Format('前提: 追尾を切ると 3000 ppm で外し始める (%d/%d)',
      [off.Matched, off.Compared]));
end;

{ --------------------------------------------------------------------------
  6. 山が一つに決まらない場合は手を出さない
  -------------------------------------------------------------------------- }
procedure TestGates;
var
  m: TMfskMode;
  det: TMfskToneDetector;
  syms: TIntegerArray;
  wave: TDoubleArr;
  i, n: Integer;
  updAtFill: Int64;
begin
  WriteLn;
  WriteLn('--- 6. 三つの門 ---');
  m := MFSK16_MODE;

  { (a) 無音では一度も効かない。 }
  det := TMfskToneDetector.Create(m);
  try
    for i := 0 to 20 * m.SymLen - 1 do det.Feed(0);
    CheckEqI(det.SyncUpdates, 0, '無音では追尾が一度も効かない');
    CheckEqI(Round(det.SyncError * 1000), 0, '無音で区切りがずれない');
  finally
    det.Free;
  end;

  { (b) 同じトーンが続くと効かない。境目で大きさが落ちず山が平らになる。 }
  SetLength(syms, 20);
  for i := 0 to High(syms) do syms[i] := 5;
  wave := Modulate(m, syms);
  det := TMfskToneDetector.Create(m);
  try
    for i := 0 to High(wave) do det.Feed(wave[i]);
    CheckEqI(det.SyncUpdates, 0, '同じトーンが続くと追尾が効かない');
  finally
    det.Free;
  end;

  { (c) 一つ前・二つ前が本物になるまで効かない。3 回目の切り出しからである。
    ここを外すと 2 回目から効いてしまう ―― そのとき「二つ前」は
    Reset が置いた作り物であって、判定した結果ではない。 }
  syms := MakeSymbols(6, m.NumTones);
  wave := Modulate(m, syms);
  det := TMfskToneDetector.Create(m);
  try
    n := 0; updAtFill := -1;
    for i := 0 to High(wave) do
      if det.Feed(wave[i]) then
      begin
        Inc(n);
        if n = 1 then updAtFill := det.SyncUpdates;
        if n = 2 then
          CheckEqI(det.SyncUpdates, 0, '2 回目の切り出しでもまだ効かない');
        if n = 3 then
          CheckEqI(det.SyncUpdates, 1, '3 回目の切り出しで初めて効く');
      end;
    CheckEqI(updAtFill, 0, '1 回目の切り出しでは効かない');
    Check(det.SyncUpdates > 0, '揃ったあとは効く');
  finally
    det.Free;
  end;

  { (d) Reset で追尾の状態も戻る。 }
  det := TMfskToneDetector.Create(m);
  try
    syms := MakeSymbols(60, m.NumTones);
    wave := Modulate(m, syms, m.SymLen div 2);
    for i := 0 to High(wave) do det.Feed(wave[i]);
    Check(det.SyncUpdates > 0, '前提: 追尾が動いた状態を作れた');
    det.Reset;
    CheckEqI(det.SyncUpdates, 0, 'Reset で追尾の回数が 0 に戻る');
    CheckEqI(Round(det.SyncError * 1000), 0, 'Reset でずれが 0 に戻る');
  finally
    det.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 区切りが消えない

  補正は FCounter に足し引きされる。もし FCounter が 0 以下になれば
  次のサンプルで即座にもう一度切り出してしまう。|補正| の上限が
  SymLen/NumTones + 1 である以上そうはならないが、**切り出し間隔を
  直に数えて**確かめる。
  -------------------------------------------------------------------------- }
procedure TestSymbolSpacingStaysSane;
var
  m: TMfskMode;
  det: TMfskToneDetector;
  syms: TIntegerArray;
  wave: TDoubleArr;
  i, last, gap, minGap, maxGap, n: Integer;
begin
  WriteLn;
  WriteLn('--- 7. 区切りの間隔が壊れない ---');
  m := MFSK16_MODE;
  syms := MakeSymbols(200, m.NumTones);
  { 最も追い込まれる条件: 半シンボルずれ + 速度差 }
  wave := Modulate(m, syms, m.SymLen div 2, 3000);
  det := TMfskToneDetector.Create(m);
  try
    last := -1; minGap := MaxInt; maxGap := 0; n := 0;
    for i := 0 to High(wave) do
      if det.Feed(wave[i]) then
      begin
        if last >= 0 then
        begin
          gap := i - last;
          if gap < minGap then minGap := gap;
          if gap > maxGap then maxGap := gap;
        end;
        last := i;
        Inc(n);
      end;
    WriteLn(Format('        切り出し %d 回 / 間隔 %d..%d (公称 %d)',
      [n, minGap, maxGap, m.SymLen]));
    Check(minGap >= m.SymLen - (m.SymLen div m.NumTones + 1),
      Format('間隔が縮みすぎない (最小 %d)', [minGap]));
    Check(maxGap <= m.SymLen + (m.SymLen div m.NumTones + 1),
      Format('間隔が延びすぎない (最大 %d)', [maxGap]));
  finally
    det.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 確保しない (X-04) / 同じ音から同じ結果 (Z-05)
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
var
  m: TMfskMode;
  det: TMfskToneDetector;
  syms: TIntegerArray;
  wave: TDoubleArr;
  r1, r2: TSyncResult;
  i, n: Integer;
begin
  WriteLn;
  WriteLn('--- 8. 確保しない (X-04) / 同じ音から同じ結果 (Z-05) ---');
  m := MFSK16_MODE;
  syms := MakeSymbols(60, m.NumTones);
  wave := Modulate(m, syms, m.SymLen div 2, 1000);

  det := TMfskToneDetector.Create(m);
  try
    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for i := 0 to High(wave) do det.Feed(wave[i]);
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0, Format('%d サンプル投入で確保 0 回 (追尾を入れたまま / 実測 %d)',
      [Length(wave), n]));
  finally
    det.Free;
  end;

  r1 := RunDetector(m, wave, syms, True);
  r2 := RunDetector(m, wave, syms, True);
  Check((r1.SymbolCount = r2.SymbolCount) and (r1.Matched = r2.Matched) and
        (r1.FinalSyncError = r2.FinalSyncError),
    '**同じ音から同じ追尾の結果** (Z-05)');
end;

{ --------------------------------------------------------------------------
  9. MFSK32 でも同じ理屈が通る
  -------------------------------------------------------------------------- }
procedure TestOtherMode;
var
  m: TMfskMode;
  syms: TIntegerArray;
  wave: TDoubleArr;
  on_, off: TSyncResult;
begin
  WriteLn;
  WriteLn('--- 9. MFSK32 (SymLen が半分) ---');
  m := MFSK32_MODE;
  syms := MakeSymbols(200, m.NumTones);
  wave := Modulate(m, syms, m.SymLen div 2);
  on_ := RunDetector(m, wave, syms, True);
  off := RunDetector(m, wave, syms, False);
  WriteLn(Format('        追尾あり %d/%d 余裕 %.1f / 追尾なし %d/%d 余裕 %.1f',
    [on_.Matched, on_.Compared, on_.MeanMargin,
     off.Matched, off.Compared, off.MeanMargin]));
  Check(on_.LastMismatch < LOCK_SYMBOLS,
    Format('**MFSK32 でも半シンボルずれを掴む** (最後に外したのは %d 番目)',
      [on_.LastMismatch]));
  Check(off.Matched < off.Compared, '前提: 追尾を切ると MFSK32 でも崩れる');
end;

begin
  WriteLn('=== MFSK のシンボル同期の追尾の試験 ===');

  TestAlignedIsUndisturbed;
  TestHalfSymbolOffset;
  TestPullInSweep;
  TestClockDrift;
  TestGates;
  TestSymbolSpacingStaysSane;
  TestNoAllocationAndDeterminism;
  TestOtherMode;

  if FailCount = 0 then
    CoverReq('MDM-013');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
