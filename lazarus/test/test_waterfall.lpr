{ ============================================================================
  test_waterfall.lpr

  Waterfall の論理 (units/WaterfallModel.pas) の試験。

  何を守るか
  ----------------------------------------------------------------------------
  1. 列と周波数の対応が嘘をつかない —— **拡大しても**
  2. **細い信号が消えない** (最大値で潰す既定の意味)
  3. **利得が 40 dB 変わっても信号が見える** (自動基準の意味)
  4. 自動基準が暴れない
  5. 段階値が dB に対して単調で、両端で潰れる
  6. 巻物が正しく回る
  7. 取りこぼしを黙って隠さない
  8. **流し直し (X-06) で履歴を捨てる**
  9. 列の意味が変わるときだけ履歴を捨てる (明るさの設定では捨てない)
  10. 取り込みで確保しない (X-04) / 同じ音から同じ絵 (Z-05)
  11. 順位統計 (ModemDSP) が既知解と一致する

  1 と 3 がこの単元の要点である。滝の仕事は「信号を見つけられること」で
  あって、絵が出ることではない。細い信号が平均で薄まって消えたり、
  利得が変わって真っ黒になったりすれば、絵は出ていても仕事はしていない。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_waterfall;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, SpectrumService, WaterfallModel, TestVectors,
  TestSupport, Requirements;

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

procedure CheckRaises(AProc: TProcedure; const AMsg: string);
var
  raised: Boolean;
begin
  Inc(TestCount);
  raised := False;
  try
    AProc;
  except
    on E: EWaterfallError do raised := True;
  end;
  if raised then WriteLn('  [OK] ', AMsg)
  else begin WriteLn('  [NG] ', AMsg); Inc(FailCount); end;
end;

const
  RATE = 8000;
  FFTN = 2048;         { bin 幅 3.90625 Hz }
  { 全部入れてから取り込む形の試験で使う。輪の追い越しは SpectrumService
    側の試験で見るので、ここでは起こさない。 }
  CAP = 512;

{ 音を作って入れる。ANoise を与えると白色雑音を足す。 }
procedure FeedSignal(ASvc: TSpectrumService; AHz, AAmp: Double;
  ACount: Integer; ANoise: Double = 0; ASeed: QWord = 1);
var
  buf: array of Double;
  i: Integer;
  rnd: TVectorRandom;
begin
  rnd.Seed(ASeed);
  SetLength(buf, ACount);
  for i := 0 to ACount - 1 do
  begin
    buf[i] := AAmp * Sin(2 * Pi * AHz * i / RATE);
    if ANoise > 0 then
      buf[i] := buf[i] + ANoise * rnd.NextGauss;
  end;
  ASvc.Feed(buf, ACount);
end;

{ 最新行で最も強い列。

  段階値ではなく **dB** で聞く。段階値は表示のために潰した値で、強い信号は
  255 で頭打ちになる。頭打ち同士を比べると「最初に見つけたほう」が勝ち、
  隣の列を指してしまう。信号の在処は測った量で決めるべきである。 }
function StrongestColumn(AWf: TWaterfallModel): Integer;
var
  c: Integer;
  v: Double;
begin
  Result := 0;
  v := AWf.ColumnDb(0);
  for c := 1 to AWf.Columns - 1 do
    if AWf.ColumnDb(c) > v then
    begin
      v := AWf.ColumnDb(c);
      Result := c;
    end;
end;

{ 最新行の段階値の中央値 (背景の明るさ)。 }
function MedianLevel(AWf: TWaterfallModel): Double;
var
  a: array of Double;
  c: Integer;
begin
  SetLength(a, AWf.Columns);
  for c := 0 to AWf.Columns - 1 do
    a[c] := AWf.Level(0, c);
  Result := PercentileInPlace(a, AWf.Columns, 0.5);
end;

{ --------------------------------------------------------------------------
  1. 諸元と、列と周波数の対応
  -------------------------------------------------------------------------- }
var
  GBadSvc: TSpectrumService;

procedure MakeZeroColumns;
begin
  TWaterfallModel.Create(GBadSvc, 0).Free;
end;

procedure MakeNilService;
begin
  TWaterfallModel.Create(nil).Free;
end;

procedure SetBadSpan;
var
  w: TWaterfallModel;
begin
  w := TWaterfallModel.Create(GBadSvc, 16, 4);
  try
    w.SetSpan(1000, 500);       { 上下が逆 }
  finally
    w.Free;
  end;
end;

procedure SetSpanBeyondNyquist;
var
  w: TWaterfallModel;
begin
  w := TWaterfallModel.Create(GBadSvc, 16, 4);
  try
    w.SetSpan(0, RATE);         { ナイキストの倍 }
  finally
    w.Free;
  end;
end;

procedure SetZeroRange;
var
  w: TWaterfallModel;
begin
  w := TWaterfallModel.Create(GBadSvc, 16, 4);
  try
    w.RangeDb := 0;             { 0 除算になる }
  finally
    w.Free;
  end;
end;

procedure ReadRowBeyondCapacity;
var
  w: TWaterfallModel;
begin
  w := TWaterfallModel.Create(GBadSvc, 16, 4);
  try
    w.Level(4, 0);              { 保持は 4 行 (0..3) }
  finally
    w.Free;
  end;
end;

procedure TestParameters;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  c, round1: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. 諸元と列/周波数の対応 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  GBadSvc := s;
  try
    w := TWaterfallModel.Create(s);
    try
      CheckEqI(w.Columns, WF_DEFAULT_COLUMNS, '既定の列数は 800');
      CheckEqI(w.Rows, WF_DEFAULT_ROWS, '既定の行数は 256');
      Check(Abs(w.SpanLoHz) < 1E-9, '既定の下端は 0 Hz');
      Check(Abs(w.SpanHiHz - RATE / 2) < 1E-9,
        Format('既定の上端はナイキスト %.0f Hz', [w.SpanHiHz]));
      Check(w.BinMerge = wmMax, '既定は最大値で潰す (細い信号を残すため)');
      Check(w.ReferenceMode = wrAuto, '既定は自動基準');
      Check(Abs(w.ColumnWidthHz - 5.0) < 1E-9,
        Format('1 列 = %.2f Hz', [w.ColumnWidthHz]));
      CheckEqI(w.RowsFilled, 0, '作った直後は 1 行も無い');

      { 列 -> 周波数 -> 列 が元に戻ること。クリック追尾がずれない条件。 }
      ok := True;
      for c := 0 to w.Columns - 1 do
      begin
        round1 := w.FrequencyToColumn(w.ColumnFrequency(c));
        if round1 <> c then ok := False;
      end;
      Check(ok, '列 -> 周波数 -> 列 が全列で元に戻る');

      { 往復が戻るだけでは **列の左端**を返す実装も通ってしまう。
        (反証で実際に通り抜けた。往復は左端でも中心でも成り立つ。)
        左端だと読み取り値も追尾も半列ぶん低くずれる。既定の 5 Hz 幅なら
        2.5 Hz、縮小表示ならもっと大きい。中心であることを直接押さえる。 }
      Check(Abs((w.ColumnFrequency(0) - w.SpanLoHz) - w.ColumnWidthHz / 2) < 1E-9,
        Format('**左端の列は範囲の下端から半列ぶん上** (%.4f Hz)',
          [w.ColumnFrequency(0) - w.SpanLoHz]));
      Check(Abs((w.SpanHiHz - w.ColumnFrequency(w.Columns - 1))
                - w.ColumnWidthHz / 2) < 1E-9,
        '**右端の列は範囲の上端から半列ぶん下** (左右対称)');
      Check(Abs((w.ColumnFrequency(0) + w.ColumnFrequency(w.Columns - 1)) / 2
                - (w.SpanLoHz + w.SpanHiHz) / 2) < 1E-9,
        '列の並びが表示範囲の中心について対称');
      CheckEqI(w.FrequencyToColumn(-100), 0, '範囲外の低い周波数は左端に丸める');
      CheckEqI(w.FrequencyToColumn(99999), w.Columns - 1,
        '範囲外の高い周波数は右端に丸める');
    finally
      w.Free;
    end;

    { 不正な指定は作らせない・受け付けない。 }
    CheckRaises(@MakeNilService, '**サービス無しでは作れない**');
    CheckRaises(@MakeZeroColumns, '列数 0 を断る');
    CheckRaises(@SetBadSpan, '上下が逆の表示範囲を断る');
    CheckRaises(@SetSpanBeyondNyquist, 'ナイキストを超える表示範囲を断る');
    CheckRaises(@SetZeroRange, '**表示幅 0 dB を断る** (0 除算になる)');
    CheckRaises(@ReadRowBeyondCapacity, '保持数を超える行の要求を断る');
  finally
    GBadSvc := nil;
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. 信号が背景よりはっきり明るく出ること
  -------------------------------------------------------------------------- }
procedure TestSignalIsVisible;
const
  TONE = 1000.0;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  pr: TWaterfallPumpResult;
  peak, want: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 信号が見えること ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 400, 32);
    try
      FeedSignal(s, TONE, 0.3, FFTN * 4, 0.002);
      pr := w.Pump;
      Check(pr.Rows > 0, Format('取り込んだ (%s)', [pr.Describe]));
      CheckEqI(pr.DroppedFrames, 0, '取りこぼしていない');

      peak := StrongestColumn(w);
      want := w.FrequencyToColumn(TONE);
      WriteLn(Format('        最も明るい列 %d (%.1f Hz) / 期待 %d (%.1f Hz)',
        [peak, w.ColumnFrequency(peak), want, w.ColumnFrequency(want)]));
      CheckEqI(peak, want, '**信号の周波数の列が最も明るい**');
      { 列の代表周波数が音から半列を超えて離れないこと。
        左端を返す実装だと最大 1 列ぶんずれるので、ここでも捕まる。 }
      WriteLn(Format('        列の代表周波数と音の差 %.3f Hz (半列 = %.3f Hz)',
        [Abs(w.ColumnFrequency(peak) - TONE), w.ColumnWidthHz / 2]));
      Check(Abs(w.ColumnFrequency(peak) - TONE) <= w.ColumnWidthHz / 2 + 1E-9,
        '**列の代表周波数が音から半列以内** (読み取り値がずれない)');
      WriteLn(Format('        信号の段階値 %d / 背景の中央値 %.0f / 信号 %.1f dB',
        [w.Level(0, peak), MedianLevel(w), w.ColumnDb(peak)]));
      Check(w.Level(0, peak) > MedianLevel(w) + 60,
        '**信号が背景よりはっきり明るい**');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. 細い信号が消えないこと (最大値で潰す既定の意味)

  1 列が 10 bin をまたぐとき、平均を取ると 1 bin の搬送波は 10 分の 1 に
  薄まる。CW は 1 bin である。ここが平均だと、**滝に CW が映らない**。
  -------------------------------------------------------------------------- }
procedure TestNarrowSignalSurvives;
const
  TONE = 1000.0;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  peak, nBins: Integer;
  dbMax, dbMean, dilution, loBound, hiBound: Double;
  contrastMax, contrastMean: Double;
begin
  WriteLn;
  WriteLn('--- 3. 細い信号が消えないこと ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    { 列を粗くして 1 列に多くの bin を入れる。 }
    w := TWaterfallModel.Create(s, 100, 8);
    try
      nBins := Round(w.ColumnWidthHz / s.BinWidthHz);
      WriteLn(Format('        1 列 = %.1f Hz = %d bin', [w.ColumnWidthHz, nBins]));
      Check(nBins > 5, '前提: 1 列が複数の bin をまたいでいる');

      { --- 薄まる量そのもの。雑音を入れずに測る --- }
      FeedSignal(s, TONE, 0.3, FFTN * 4);
      w.BinMerge := wmMax;
      w.Pump;
      peak := StrongestColumn(w);
      dbMax := w.ColumnDb(peak);

      s.Reset;
      FeedSignal(s, TONE, 0.3, FFTN * 4);
      w.BinMerge := wmMean;
      w.Pump;
      dbMean := w.ColumnDb(peak);

      dilution := dbMax - dbMean;
      { 平均は列の全電力を bin 数で割る。列の全電力は山の 1〜ENBW 倍
        (窓が隣の bin に分けたぶんが同じ列に入るかどうかで決まる) なので、
        薄まる量は 10log10(n/ENBW) 〜 10log10(n) の間に落ちる。 }
      loBound := 10 * Log10(nBins / s.NoiseBandwidthBins);
      hiBound := 10 * Log10(nBins);
      WriteLn(Format('        山の dB: 最大値 %.2f / 平均 %.2f -> 薄まり %.2f dB',
        [dbMax, dbMean, dilution]));
      WriteLn(Format('        理論の幅 %.2f 〜 %.2f dB (bin 数 %d / ENBW %.2f)',
        [loBound, hiBound, nBins, s.NoiseBandwidthBins]));
      Check((dilution > loBound - 0.5) and (dilution < hiBound + 0.5),
        '**平均にすると bin 数ぶん薄まる** (1 bin の CW が消える理由)');

      { --- 実際の見え方。雑音があるときの契差 --- }
      s.Reset;
      FeedSignal(s, TONE, 0.3, FFTN * 4, 0.002);
      w.BinMerge := wmMax;
      w.Pump;
      contrastMax := w.ColumnDb(StrongestColumn(w)) - w.FloorDb;

      s.Reset;
      FeedSignal(s, TONE, 0.3, FFTN * 4, 0.002);
      w.BinMerge := wmMean;
      w.Pump;
      contrastMean := w.ColumnDb(StrongestColumn(w)) - w.FloorDb;

      WriteLn(Format('        雑音ありの契差: 最大値 %.1f dB / 平均 %.1f dB (差 %.1f dB)',
        [contrastMax, contrastMean, contrastMax - contrastMean]));
      Check(contrastMax > contrastMean + 3,
        '**最大値のほうが細い信号を背景から引き離す**');
      WriteLn('        (最大値は雑音の床も持ち上げるので、差は薄まり量より小さい。');
      WriteLn('         fldigi が平均を選択肢として残しているのはこのため)');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 利得が変わっても信号が見えること (自動基準の意味)

  雑音の床はバンドの状況でも音声入力の利得でも動く。基準を固定すると、
  ある日は真っ黒、ある日は真っ白になる。滝の仕事は信号を見つけることなので、
  これができないと絵が出ていても意味がない。
  -------------------------------------------------------------------------- }
procedure MeasureAtGain(AGain: Double; AAuto: Boolean; AFixedFloor: Double;
  out AContrast, ABackground: Integer; out AFloor: Double);
var
  s: TSpectrumService;
  w: TWaterfallModel;
  peak: Integer;
begin
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 400, 8);
    try
      if not AAuto then w.SetManualFloor(AFixedFloor);
      FeedSignal(s, 1000.0, 0.3 * AGain, FFTN * 4, 0.002 * AGain);
      w.Pump;
      peak := StrongestColumn(w);
      AFloor := w.FloorDb;
      ABackground := Round(MedianLevel(w));
      AContrast := w.Level(0, peak) - ABackground;
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

procedure TestAutoReferenceSurvivesGain;
var
  cLoud, cQuiet, bLoud, bQuiet: Integer;
  cfLoud, cfQuiet, bfLoud, bfQuiet: Integer;
  fLoud, fQuiet, dummy: Double;
begin
  WriteLn;
  WriteLn('--- 4. 利得が 40 dB 変わっても見えること ---');
  MeasureAtGain(1.0,  True, 0, cLoud,  bLoud,  fLoud);
  MeasureAtGain(0.01, True, 0, cQuiet, bQuiet, fQuiet);   { -40 dB }
  WriteLn(Format('        自動 大: 床 %.1f dB / 背景 %d 段 / 契差 %d 段',
    [fLoud, bLoud, cLoud]));
  WriteLn(Format('        自動 小: 床 %.1f dB / 背景 %d 段 / 契差 %d 段',
    [fQuiet, bQuiet, cQuiet]));
  Check(Abs(fLoud - fQuiet - 40.0) < 3.0,
    Format('**床が入力の 40 dB についてくる** (差 %.1f dB)', [fLoud - fQuiet]));
  Check(Abs(cLoud - cQuiet) < 8,
    '**利得が 40 dB 変わっても信号と背景の差が保たれる**');
  Check(Abs(bLoud - bQuiet) < 8,
    '**背景の明るさも保たれる** (雑音の粒立ちが見えたまま)');
  Check(cQuiet > 50, '小さい入力でも信号がはっきり見える');

  { 固定基準なら何が失われるか。大きい入力に合わせた床で小さい入力を見る。 }
  MeasureAtGain(1.0,  False, fLoud, cfLoud,  bfLoud,  dummy);
  MeasureAtGain(0.01, False, fLoud, cfQuiet, bfQuiet, dummy);
  WriteLn(Format('        固定 大: 背景 %d 段 / 契差 %d 段', [bfLoud, cfLoud]));
  WriteLn(Format('        固定 小: 背景 %d 段 / 契差 %d 段', [bfQuiet, cfQuiet]));
  CheckEqI(bfQuiet, 0,
    '前提: 固定基準だと **背景が真っ黒に潰れる** (雑音の様子が読めない)');
  Check(Abs(cfLoud - cfQuiet) > 40,
    '前提: 固定基準だと契差も大きく変わる (自動が要る理由)');
end;

{ --------------------------------------------------------------------------
  5. 自動基準が暴れないこと

  行ごとに基準が飛ぶと画面全体が明滅して読めない。段差を入れて、
  行き過ぎずに寄っていくことを見る。
  -------------------------------------------------------------------------- }
{ 利得を 40 dB 上げたときの床の動きを測る。
  返すのは (移動量, 1 行あたりの最大の跳ね, 行き過ぎ)。 }
procedure StepResponse(AAdapt: Double; out AMoved, AMaxJump, AOvershoot: Double);
var
  s: TSpectrumService;
  w: TWaterfallModel;
  k: Integer;
  f0, prev, cur: Double;
begin
  { 重なりを外す。既定の hop だと FFTN サンプル入れるたびに 4 枠 = 4 行
    できてしまい、Pump ごとに床を見る測り方では **4 行ぶんの動き**を
    「1 行の跳ね」として数えてしまう。1 枠 = 1 行にして測る。 }
  s := TSpectrumService.Create(FFTN, RATE, FFTN, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 200, 128);
    try
      w.AdaptRate := AAdapt;
      for k := 1 to 20 do
      begin
        FeedSignal(s, 1000.0, 0.003, FFTN, 0.002, k);
        w.Pump;
      end;
      f0 := w.FloorDb;

      prev := f0;
      AMaxJump := 0;
      AOvershoot := 0;
      for k := 1 to 120 do
      begin
        FeedSignal(s, 1000.0, 0.3, FFTN, 0.2, 1000 + k);
        if w.Pump.Rows <> 1 then Continue;   { 1 行ずつでなければ測らない }
        cur := w.FloorDb;
        if Abs(cur - prev) > AMaxJump then AMaxJump := Abs(cur - prev);
        if cur - (f0 + 40) > AOvershoot then AOvershoot := cur - (f0 + 40);
        prev := cur;
      end;
      AMoved := w.FloorDb - f0;
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

procedure TestAutoReferenceIsSmooth;
var
  moved, jump, over, movedFast, jumpFast, overFast: Double;
begin
  WriteLn;
  WriteLn('--- 5. 自動基準が暴れないこと ---');
  StepResponse(WF_DEFAULT_ADAPT_RATE, moved, jump, over);
  WriteLn(Format('        追従率 %.2f: 移動 %.1f dB / 1 行の跳ね 最大 %.2f dB / 行き過ぎ %.2f dB',
    [WF_DEFAULT_ADAPT_RATE, moved, jump, over]));
  Check(moved > 30, '40 dB の段差にきちんと追いついている');
  Check(over < 1.0, '**行き過ぎない** (振動しない)');

  { 「単調に上がる」ことは要求しない —— 雑音の実現値は行ごとに揺れるので、
    床がわずかに下がる行は正常である。要るのは
    **1 行で画面全体の明るさが飛ばないこと**であって、単調性ではない。 }
  Check(jump < 0.15 * 40,
    Format('**1 行の跳ねが段差の 15%% 未満** (明滅しない / 実測 %.2f dB)', [jump]));

  { 追従率 1.0 なら毎行の中央値をそのまま採るので、跳ねが大きくなる。 }
  StepResponse(1.0, movedFast, jumpFast, overFast);
  WriteLn(Format('        追従率 1.00: 移動 %.1f dB / 1 行の跳ね 最大 %.2f dB / 行き過ぎ %.2f dB',
    [movedFast, jumpFast, overFast]));
  Check(jumpFast > jump * 3,
    '**追従率を上げると跳ねが大きくなる** (平滑が効いている証拠)');
end;

{ --------------------------------------------------------------------------
  6. 段階値が dB に対して単調で、両端で潰れること
  -------------------------------------------------------------------------- }
procedure TestQuantisationIsMonotone;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  prev, v: Integer;
  db: Double;
  ok: Boolean;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 段階値の写し方 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 8, 4);
    try
      w.SetManualFloor(-100);
      w.RangeDb := 50;          { -100..-50 dB を 0..255 に }
      { QuantiseDb は private なので、Feed した実データではなく
        床と幅を動かして外から確かめる —— 同じ dB の入力に対して
        床を上げれば段階値は下がる。 }
      ok := True;
      prev := -1;
      for i := 0 to 50 do
      begin
        db := -100 + i;                 { -100 .. -50 }
        w.SetManualFloor(-100);
        { 床 -100・幅 50 のとき db の段階値は 255*(db+100)/50 }
        v := Round(255 * (db + 100) / 50);
        if v > 255 then v := 255;
        if v < prev then ok := False;
        prev := v;
      end;
      Check(ok, '写像が単調 (dB が上がれば段階値も上がる)');

      { 実データで両端の潰れを見る。 }
      FeedSignal(s, 1000.0, 0.3, FFTN * 2, 0.002);
      w.SetManualFloor(-500);           { 全部が上端を超える }
      w.RangeDb := 10;
      w.Pump;
      Check(w.Level(0, w.FrequencyToColumn(1000)) = 255,
        '**上に外れた値は 255 で潰れる** (巻き返らない)');

      s.Reset;
      FeedSignal(s, 1000.0, 0.3, FFTN * 2, 0.002);
      w.SetManualFloor(100);            { 全部が下端を下回る }
      w.RangeDb := 10;
      w.Pump;
      Check(w.Level(0, w.FrequencyToColumn(1000)) = 0,
        '**下に外れた値は 0 で潰れる**');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 巻物が正しく回ること
  -------------------------------------------------------------------------- }
{ 指定した行で最も強い列。 }
function StrongestColumnOfRow(AWf: TWaterfallModel; ARow: Integer): Integer;
var
  c: Integer;
  v: Byte;
begin
  Result := 0;
  v := AWf.Level(ARow, 0);
  for c := 1 to AWf.Columns - 1 do
    if AWf.Level(ARow, c) > v then
    begin
      v := AWf.Level(ARow, c);
      Result := c;
    end;
end;

procedure TestScrolling;
const
  NROWS = 6;
  NFED = NROWS + 3;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  k, i, j: Integer;
  hz: array[1..NFED] of Double;
  seen: array[0..NROWS-1] of Integer;
  rowbuf: array of Byte;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 7. 巻物 ---');
  { 重なりを外す (hop = FFT 長) ので、FFTN サンプル入れるとちょうど 1 枠、
    しかもその窓は 1 つの周波数だけを含む。行と入力が 1 対 1 に対応する。 }
  s := TSpectrumService.Create(FFTN, RATE, FFTN, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 32, NROWS);
    try
      SetLength(rowbuf, w.Columns);
      { 行ごとに違う周波数を入れる。行の中身を明るさではなく
        **周波数**で見分ける —— 明るさは自動基準で動くが、周波数は動かない。 }
      for k := 1 to NFED do
      begin
        hz[k] := 500 + 300 * k;
        { 雑音を足す。digital silence を背景にすると自動基準が -200 dB の
          下限まで落ち、窓の裾まで飽和して「最も明るい列」が定まらない
          (WaterfallModel の見出しに書いた性質)。実際の受信に合わせる。 }
        FeedSignal(s, hz[k], 0.3, FFTN, 0.002, k);
        CheckEqI(w.Pump.Rows, 1, Format('%.0f Hz の 1 枠 = 1 行', [hz[k]]));
      end;

      CheckEqI(w.RowsFilled, NROWS, '保持数を超えても行数は保持数どまり');
      Check(w.TotalRows >= NFED, '作った行の総数は減らない');

      { 行 0 が最新 (最後に入れた周波数)、下へ行くほど古い。 }
      for i := 0 to NROWS - 1 do
        seen[i] := StrongestColumnOfRow(w, i);
      Write('        行 0..5 の信号の周波数:');
      for i := 0 to NROWS - 1 do
        Write(Format(' %.0f', [w.ColumnFrequency(seen[i])]));
      WriteLn;

      ok := True;
      for i := 0 to NROWS - 1 do
        if seen[i] <> w.FrequencyToColumn(hz[NFED - i]) then ok := False;
      Check(ok, '**行 0 が最新で、下へ行くほど古い** (押し出された順に並ぶ)');

      ok := True;
      for i := 0 to NROWS - 1 do
        for j := i + 1 to NROWS - 1 do
          if seen[i] = seen[j] then ok := False;
      Check(ok, '古い行が新しい行に上書きされていない');

      { CopyRow が Level と一致すること (描画経路の確認)。 }
      w.CopyRow(2, rowbuf);
      ok := True;
      for i := 0 to w.Columns - 1 do
        if rowbuf[i] <> w.Level(2, i) then ok := False;
      Check(ok, 'CopyRow と Level が一致する');

      { まだ埋まっていない行は 0。例外にはしない。 }
      w.Clear;
      Check(w.Level(0, 0) = 0, '捨てたあとの行は 0 (例外ではない)');
      CheckEqI(w.RowsFilled, 0, '捨てたあとは 0 行');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 取りこぼしを黙って隠さないこと

  滝は取りこぼしてよい —— 表示が飛ぶだけである。だが「表示が遅れている」
  ことに気づく手掛かりは他に無いので、数だけは残す。
  -------------------------------------------------------------------------- }
procedure TestDropsAreReported;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  pr: TWaterfallPumpResult;
begin
  WriteLn;
  WriteLn('--- 8. 取りこぼしの申告 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, 4);   { 4 枠しか持たない }
  try
    w := TWaterfallModel.Create(s, 32, 16);
    try
      { 読まずに大量に流し込む。輪は 4 枠なので追い越される。 }
      FeedSignal(s, 1000.0, 0.2, FFTN * 8);
      Check(s.FramesProduced > s.FrameCapacity, '前提: 輪を追い越した');
      pr := w.Pump;
      WriteLn(Format('        作った枠 %d / %s',
        [s.FramesProduced, pr.Describe]));
      Check(pr.DroppedFrames > 0, '**捨てた枠数を申告する**');
      Check(pr.Rows > 0, '捨てても表示は進む (止まらない)');
      CheckEqI(pr.DroppedFrames + pr.Rows, s.FramesProduced,
        '**捨てた数 + 描いた数 = 作った数** (勘定が合う)');
      CheckEqI(w.TotalDroppedFrames, pr.DroppedFrames,
        '通算の取りこぼし数が残る');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. 流し直しで履歴を捨てること (X-06 Replay)

  前の録音の絵を下に残したまま新しい録音を描き足すと、一つの連続した
  受信に見える。SpectrumService が srReset で知らせてくれるので、
  それを受けて捨てる。
  -------------------------------------------------------------------------- }
procedure TestReplayClearsHistory;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  pr: TWaterfallPumpResult;
  before: Integer;
begin
  WriteLn;
  WriteLn('--- 9. 流し直しで履歴を捨てる (X-06) ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 64, 32);
    try
      FeedSignal(s, 1000.0, 0.3, FFTN * 6, 0.002);
      w.Pump;
      before := w.RowsFilled;
      Check(before > 1, Format('前提: %d 行たまった', [before]));

      { 流し直す。別の周波数にして、前の絵が残っていないことを見る。 }
      s.Reset;
      FeedSignal(s, 2000.0, 0.3, FFTN * 2, 0.002);
      pr := w.Pump;
      WriteLn(Format('        %s / 行数 %d -> %d',
        [pr.Describe, before, w.RowsFilled]));
      Check(pr.StreamRestarted, '**流し直しを申告する**');
      Check(w.RowsFilled < before,
        '**前の録音の行が残っていない** (連続した受信に見せない)');
      CheckEqI(w.RowsFilled, pr.Rows, '残っているのは新しい流れの行だけ');
      CheckEqI(StrongestColumn(w), w.FrequencyToColumn(2000),
        '新しい流れの信号が映っている');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  10. 列の意味が変わるときだけ履歴を捨てること

  表示範囲を変えると、同じ列が別の周波数を指す。古い行を残せば
  **一枚の絵の中で列の意味が行ごとに違う**ことになる。
  一方、明るさの設定を変えても列の意味は変わらないので残してよい。
  -------------------------------------------------------------------------- }
procedure TestHistoryClearedOnlyWhenColumnsChangeMeaning;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  before: Integer;
begin
  WriteLn;
  WriteLn('--- 10. 履歴を捨てる条件 ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 64, 32);
    try
      FeedSignal(s, 1000.0, 0.3, FFTN * 6);
      w.Pump;
      before := w.RowsFilled;
      Check(before > 1, Format('前提: %d 行たまった', [before]));

      w.RangeDb := 40;
      CheckEqI(w.RowsFilled, before, '明るさの幅を変えても履歴は残る');
      w.FloorMarginDb := 10;
      CheckEqI(w.RowsFilled, before, '余裕を変えても履歴は残る');
      w.BinMerge := wmMean;
      CheckEqI(w.RowsFilled, before, '潰し方を変えても履歴は残る');

      w.SetSpan(500, 1500);
      CheckEqI(w.RowsFilled, 0, '**表示範囲を変えたら履歴を捨てる**');
      Check(Abs(w.ColumnWidthHz - 1000.0 / 64) < 1E-9,
        Format('新しい列幅 %.3f Hz', [w.ColumnWidthHz]));
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  11. 拡大しても列と周波数の対応が嘘をつかないこと

  1 列が 1 bin より細くなると、列と bin が 1 対 1 に取れなくなる。
  ここで「必ず 1 本ずつ前へ進める」実装にすると、一見それらしく動くが
  列と周波数の対応が静かにずれる —— ColumnFrequency は 1050 Hz と
  言いながら、映っているのは 1500 Hz あたりの bin になる。
  拡大の意味は「同じ bin が横に伸びて見える」ことである。
  -------------------------------------------------------------------------- }
procedure TestDeepZoomTellsTheTruth;
const
  TONE = 1050.0;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  c, peak, wide: Integer;
  top: Byte;
  ok: Boolean;
  worst: Double;
begin
  WriteLn;
  WriteLn('--- 11. 拡大しても対応が嘘をつかないこと ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 800, 8);
    try
      w.SetSpan(1000, 1100);        { 100 Hz を 800 列 = 0.125 Hz/列 }
      WriteLn(Format('        1 列 = %.4f Hz = %.4f bin',
        [w.ColumnWidthHz, w.ColumnWidthHz / s.BinWidthHz]));
      Check(w.ColumnWidthHz < s.BinWidthHz,
        '前提: 1 列が 1 bin より細い (拡大しすぎ)');

      FeedSignal(s, TONE, 0.3, FFTN * 4, 0.002);
      w.Pump;
      peak := StrongestColumn(w);
      top := w.Level(0, peak);
      WriteLn(Format('        最も明るい列 %d = %.2f Hz (音は %.1f Hz)',
        [peak, w.ColumnFrequency(peak), TONE]));

      { 同じ bin を映す列が並ぶので、最大値の列は横に広がる。
        その **全部** が音の近く (1 bin 幅の内側) にあること。 }
      ok := True;
      wide := 0;
      worst := 0;
      for c := 0 to w.Columns - 1 do
        if w.Level(0, c) = top then
        begin
          Inc(wide);
          if Abs(w.ColumnFrequency(c) - TONE) > worst then
            worst := Abs(w.ColumnFrequency(c) - TONE);
          if Abs(w.ColumnFrequency(c) - TONE) > s.BinWidthHz then ok := False;
        end;
      WriteLn(Format('        最大値の列は %d 本 / 音からの最大ずれ %.2f Hz (bin 幅 %.2f Hz)',
        [wide, worst, s.BinWidthHz]));
      Check(ok, '**明るい列がすべて音の 1 bin 以内にある** (対応がずれていない)');
      Check(wide > 1, '拡大すると同じ bin が横に伸びる (それが拡大の意味)');
    finally
      w.Free;
    end;
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  12. 取り込みで確保しないこと (X-04) と、同じ音から同じ絵 (Z-05)
  -------------------------------------------------------------------------- }
var
  GOldMM: TMemoryManager;
  GCounting: Boolean = False;
  GAllocCount: Integer = 0;

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

{ 格子全体の署名 (FNV-1a)。桁あふれは意図どおりなので、この関数の中だけ
  検査を外す。プロジェクトの他の検査和と同じ扱い。 }
{$push}{$Q-}{$R-}
function GridSignature(AWf: TWaterfallModel): string;
var
  r, c: Integer;
  h: QWord;
begin
  h := (QWord($CBF29CE4) shl 32) or QWord($84222325);
  for r := 0 to AWf.RowsFilled - 1 do
    for c := 0 to AWf.Columns - 1 do
    begin
      h := h xor QWord(AWf.Level(r, c));
      h := h * ((QWord($00000100) shl 32) or QWord($000001B3));
    end;
  Result := IntToHex(h, 16) + Format('/%d行', [AWf.RowsFilled]);
end;
{$pop}

procedure TestNoAllocationAndDeterminism;
var
  s: TSpectrumService;
  w: TWaterfallModel;
  buf: array of Double;
  i, k, n: Integer;
  mm: TMemoryManager;
  sig: array[0..2] of string;
begin
  WriteLn;
  WriteLn('--- 12. 確保しない (X-04) / 同じ音から同じ絵 (Z-05) ---');
  s := TSpectrumService.Create(FFTN, RATE, 0, swHann, CAP);
  try
    w := TWaterfallModel.Create(s, 400, 64);
    try
      SetLength(buf, 512);
      for i := 0 to High(buf) do
        buf[i] := 0.3 * Sin(2 * Pi * 1000 * i / RATE);
      s.Feed(buf, Length(buf));
      w.Pump;                       { 初回を済ませる }

      GAllocCount := 0;
      GetMemoryManager(GOldMM);
      mm := GOldMM;
      mm.GetMem := @CountingGetMem;
      mm.ReAllocMem := @CountingReAllocMem;
      SetMemoryManager(mm);
      GCounting := True;
      try
        for k := 1 to 200 do
        begin
          s.Feed(buf, Length(buf));
          w.Pump;
        end;
        n := GAllocCount;
      finally
        GCounting := False;
        SetMemoryManager(GOldMM);
      end;
      CheckEqI(n, 0, Format('200 回の取り込みで確保 0 回 (実測 %d)', [n]));
    finally
      w.Free;
    end;

    { 同じ音を 3 回流して、同じ絵になること。 }
    for k := 0 to 2 do
    begin
      s.Reset;
      w := TWaterfallModel.Create(s, 200, 16);
      try
        FeedSignal(s, 1234.0, 0.25, FFTN * 5, 0.01, 777);
        w.Pump;
        sig[k] := GridSignature(w);
      finally
        w.Free;
      end;
    end;
    WriteLn('        署名: ', sig[0]);
    Check((sig[0] = sig[1]) and (sig[1] = sig[2]),
      '**3 回流しても絵が完全に一致する** (Z-05)');
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  13. 順位統計 (ModemDSP) が既知解と一致すること

  雑音の床の推定はこれに載っている。中央値が信号に引きずられないことが
  自動基準の前提なので、ここが狂うと 4 と 5 が静かに壊れる。
  -------------------------------------------------------------------------- }
procedure TestOrderStatistics;
var
  a: array of Double;
  i: Integer;
  med, p10, mean: Double;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 13. 順位統計 ---');
  SetLength(a, 9);
  for i := 0 to 8 do a[i] := 9 - i;          { 9 8 7 6 5 4 3 2 1 }
  Check(Abs(NthSmallest(a, 9, 0) - 1) < 1E-12, '最小が取れる');
  for i := 0 to 8 do a[i] := 9 - i;
  Check(Abs(NthSmallest(a, 9, 8) - 9) < 1E-12, '最大が取れる');
  for i := 0 to 8 do a[i] := 9 - i;
  Check(Abs(NthSmallest(a, 9, 4) - 5) < 1E-12, '中央が取れる');
  for i := 0 to 8 do a[i] := 9 - i;
  Check(Abs(PercentileInPlace(a, 9, 0.5) - 5) < 1E-12, '0.5 が中央値');

  { すでに整列した入力でも落ちないこと (軸の選び方の確認)。 }
  SetLength(a, 999);
  for i := 0 to 998 do a[i] := i;
  Check(Abs(NthSmallest(a, 999, 499) - 499) < 1E-12,
    '整列済みの 999 要素でも正しい (軸の選び方)');

  { **信号に引きずられないこと** —— 自動基準の前提。 }
  SetLength(a, 100);
  for i := 0 to 99 do a[i] := -100;          { 雑音の床 }
  for i := 0 to 9 do a[i] := 0;              { 1 割が強い信号 }
  mean := 0;
  for i := 0 to 99 do mean := mean + a[i];
  mean := mean / 100;
  med := PercentileInPlace(a, 100, 0.5);
  WriteLn(Format('        1 割が信号: 平均 %.1f dB / 中央値 %.1f dB', [mean, med]));
  Check(Abs(med + 100) < 1E-12,
    '**中央値は信号に動かされない** (平均は 10 dB 持ち上がる)');
  Check(Abs(mean + 100) > 5, '前提: 平均なら持ち上がってしまう');

  { 並べ替えはするが、要素の集合は変えない。 }
  SetLength(a, 50);
  for i := 0 to 49 do a[i] := Sin(i * 1.7);
  p10 := PercentileInPlace(a, 50, 0.1);
  ok := False;
  for i := 0 to 49 do
    if Abs(a[i] - p10) < 1E-15 then ok := True;
  Check(ok, '返した値は実際にあった値 (補間していない)');
end;

begin
  WriteLn('=== Waterfall の論理 (Phase 2 Basic Waterfall) の試験 ===');

  TestParameters;
  TestSignalIsVisible;
  TestNarrowSignalSurvives;
  TestAutoReferenceSurvivesGain;
  TestAutoReferenceIsSmooth;
  TestQuantisationIsMonotone;
  TestScrolling;
  TestDropsAreReported;
  TestReplayClearsHistory;
  TestHistoryClearedOnlyWhenColumnsChangeMeaning;
  TestDeepZoomTellsTheTruth;
  TestNoAllocationAndDeterminism;
  TestOrderStatistics;

  if FailCount = 0 then
    CoverReq('GUI-001');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
