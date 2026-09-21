{ ============================================================================
  test_olivia_modem.lpr

  Olivia / Contestia をモードとして成立させる試験 (units/OliviaModemImpl.pas)。

  何を守るか
  ----------------------------------------------------------------------------
  1. **送って受ければ元の文が出る** (Olivia / Contestia)
  2. 前置きと押し出しの長さが鎖の遅れから出ている
  3. 区画の切り方を変えても結果が同じ (Phase 3 の戦略として配れる)
  4. **確定位置が鎖の遅れを引いた値になる** (流し直しの起点に使える)
  5. Restart で完全に初期状態へ戻る
  6. **前の局と切れ目が違っても読める** (前置きが要る理由)
  7. 雑音の中での文字誤り率を数字で残す
  8. Evidence に尺度と S/N と出所が載る
  9. 文字が出ないブロックで確保しない (X-04)
  10. 送信波形が諸元どおりの帯域に収まる
  11. **Frequency を変えると鎖まで同調し直す** (このモード固有の落とし穴)

  4 がこのモードに固有である。Olivia は文字が確定するのが**その文字を
  生んだ音より 9 秒ほど後**になる。そのまま「確定したときの区画」を
  名乗ると、そこから流し直してもその文字は二度と出てこない。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_olivia_modem;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, Modem, DecodeEvidence, SoundIntf,
  OliviaBlock, OliviaTones, OliviaSync, OliviaModemImpl,
  ErrorRate, TestVectors, TestSupport, Requirements;

const
  { 送信の前後に置く無音。実際の受信は音の途中から始まる。 }
  LEAD = 4000;
  MSG = 'CQ CQ DE JI1UUI K';

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

procedure CheckEqS(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: [', AExpected, ']');
    WriteLn('        実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

type
  TSink = class
  public
    Text: string;
    Count: Integer;
    BlockStart: Int64;
    Latency: Int64;
    PosOk: Boolean;
    PosMonotone: Boolean;
    LastPos: Int64;
    KindOk: Boolean;
    NameOk: Boolean;
    SnrSeen: Boolean;
    LastSnr: Double;
    MinMetric, MaxMetric: Double;
    { 同じ位置 (= 同じブロック) から出た文字どうしで尺度が食い違ったら
      立てる。尺度はブロック単位なので、揃っていなければおかしい。 }
    PerBlockOk: Boolean;
    LastMetric: Double;
    Signature: LongWord;
    constructor Create;
    procedure Decode(Sender: TCustomModem; const AEv: TDecodeEvidence);
  end;

{ FNV-1a。 }
{$push}{$Q-}{$R-}   { 2^32 で折り返すのが仕組みそのもの }
procedure MixIn(var AHash: LongWord; AValue: Int64);
var
  i: Integer;
begin
  for i := 0 to 7 do
  begin
    AHash := AHash xor LongWord((AValue shr (i * 8)) and $FF);
    AHash := AHash * 16777619;
  end;
end;
{$pop}

constructor TSink.Create;
begin
  inherited Create;
  BlockStart := -1;
  Latency := -1;
  PosOk := True;
  PosMonotone := True;
  LastPos := -1;
  KindOk := True;
  NameOk := True;
  MinMetric := 1E30;
  MaxMetric := -1E30;
  PerBlockOk := True;
  Signature := 2166136261;
end;

procedure TSink.Decode(Sender: TCustomModem; const AEv: TDecodeEvidence);
var
  want: Int64;
begin
  Inc(Count);
  if AEv.BestChar > 0 then Text := Text + Chr(AEv.BestChar);
  if AEv.MetricKind <> emkCorrelation then KindOk := False;
  if AEv.DecoderName <> Sender.DecoderName then NameOk := False;
  if AEv.HasSnr then begin SnrSeen := True; LastSnr := AEv.SnrDb; end;
  if AEv.BestMetric < MinMetric then MinMetric := AEv.BestMetric;
  if AEv.BestMetric > MaxMetric then MaxMetric := AEv.BestMetric;

  { 確定位置は「いま流している区画の先頭 - 鎖の遅れ」。0 で止める。 }
  if (BlockStart >= 0) and (Latency >= 0) then
  begin
    want := BlockStart - Latency;
    if want < 0 then want := 0;
    if AEv.SamplePos <> want then PosOk := False;
  end;
  { 同じブロックから出た文字は同じ位置を名乗る。そのとき尺度も
    同じであるべきである (尺度はブロック単位の同期 S/N なので)。 }
  if (Count > 1) and (AEv.SamplePos = LastPos)
     and (AEv.BestMetric <> LastMetric) then PerBlockOk := False;
  if AEv.SamplePos < LastPos then PosMonotone := False;
  LastPos := AEv.SamplePos;
  LastMetric := AEv.BestMetric;

  MixIn(Signature, AEv.BestChar);
  MixIn(Signature, AEv.SamplePos);
  MixIn(Signature, Round(AEv.BestMetric * 1000));
end;

{ ==========================================================================
  送信と受信
  ========================================================================== }
function MakeModem(ASound: TCustomSoundDevice;
  AMode: TModemMode = mmOlivia): TOliviaModem;
begin
  Result := TOliviaModem.Create(ASound, AMode, 5, 1000);
end;

function Transmit(const AMsg: string; AMode: TModemMode = mmOlivia;
  ALead: Integer = LEAD): TDoubleArray;
var
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  src: TTxSource;
  raw: TDoubleArray;
  r, guard, i: Integer;
begin
  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd, AMode);
  src := TTxSource.Create(AMsg);
  try
    m.OnGetTxChar := @src.GetTxChar;
    m.TxInit;
    guard := 0;
    repeat
      r := m.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 300000);
    raw := snd.GetCapturedCopy;
  finally
    src.Free; m.Free; snd.Free;
  end;
  SetLength(Result, ALead + Length(raw) + ALead);
  for i := 0 to High(Result) do Result[i] := 0;
  for i := 0 to High(raw) do Result[ALead + i] := raw[i];
end;

procedure FeedBlocks(AModem: TOliviaModem; const AW: TDoubleArray;
  ABlk: Integer; ASink: TSink);
var
  b: TDoubleArray;
  i, n: Integer;
begin
  ASink.Latency := AModem.LatencySamples;
  if ABlk <= 0 then
  begin
    ASink.BlockStart := 0;
    AModem.RxProcess(AW, Length(AW));
    Exit;
  end;
  SetLength(b, ABlk);
  i := 0;
  while i < Length(AW) do
  begin
    n := ABlk;
    if i + n > Length(AW) then n := Length(AW) - i;
    Move(AW[i], b[0], n * SizeOf(Double));
    ASink.BlockStart := i;
    AModem.RxProcess(b, n);
    Inc(i, n);
  end;
end;

function Receive(const AW: TDoubleArray; ABlk: Integer;
  ASink: TSink = nil; AMode: TModemMode = mmOlivia): string;
var
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  s: TSink;
  own: Boolean;
begin
  own := ASink = nil;
  if own then s := TSink.Create else s := ASink;
  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd, AMode);
  try
    m.RxInit;
    m.OnDecode := @s.Decode;
    FeedBlocks(m, AW, ABlk, s);
    Result := s.Text;
  finally
    m.Free; snd.Free;
    if own then s.Free;
  end;
end;

function AddNoise(const AW: TDoubleArray; ARms: Double;
  ASeed: QWord): TDoubleArray;
var
  rnd: TVectorRandom;
  i: Integer;
begin
  rnd.Seed(ASeed);
  SetLength(Result, Length(AW));
  for i := 0 to High(AW) do
    Result[i] := AW[i] + ARms * rnd.NextGauss;
end;

{ --------------------------------------------------------------------------
  1-2. 往復 / 前置きと押し出し
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  w: TDoubleArray;
  s: TSink;
  got: string;
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  lat, need: Integer;
begin
  WriteLn;
  WriteLn('--- 1. 送って受ければ元の文が出る ---');

  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd);
  try
    lat := m.LatencySamples div m.ToneMode.SymbolSepar;
    need := (lat + m.BlockMode.SymbolsPerBlock - 1)
            div m.BlockMode.SymbolsPerBlock;
    WriteLn(Format('        %s / 遅れ %d シンボル (%.2f 秒) / 前置き %d / 押し出し %d ブロック',
      [m.DecoderName, lat, lat / m.ToneMode.BaudRate,
       m.PreambleBlocks, m.FlushBlocks]));
    CheckEqI(m.FlushBlocks, need,
      '押し出しが鎖の遅れを覆う長さになっている');
    Check(m.PreambleBlocks > 0, '前置きがある (掴み直しのため)');
    Check(m.LatencySamples > 0, '遅れが数えられている');
  finally
    m.Free; snd.Free;
  end;

  w := Transmit(MSG);
  WriteLn(Format('        送信 %d サンプル = %.2f 秒',
    [Length(w), Length(w) / 8000]));

  s := TSink.Create;
  try
    got := Receive(w, 512, s);
    CheckEqS(got, MSG, '**Olivia 32/1000 の往復で元の文がそのまま出る**');
    Check(s.KindOk, '尺度の種類が相関として申告されている');
    Check(s.NameOk, 'Evidence が出所 (復調器の名前) を名乗る');
  finally
    s.Free;
  end;

  w := Transmit(MSG, mmContestia);
  got := Receive(w, 512, nil, mmContestia);
  CheckEqS(got, MSG, '**Contestia の往復でも元の文が出る**');
end;

{ --------------------------------------------------------------------------
  3. 区画の切り方
  -------------------------------------------------------------------------- }
procedure TestBlockInvariance;
var
  w: TDoubleArray;
  base, got: string;
  i, bad: Integer;
  blocks: array[0..4] of Integer = (0, 37, 512, 1000, 4096);
begin
  WriteLn;
  WriteLn('--- 3. 区画の切り方を変えても同じ ---');
  w := Transmit(MSG);
  base := Receive(w, 512);
  bad := 0;
  for i := 0 to High(blocks) do
  begin
    got := Receive(w, blocks[i]);
    if got <> base then Inc(bad);
    WriteLn(Format('        区画 %5d: %s',
      [blocks[i], BoolToStr(got = base, '同じ', '違う [' + got + ']')]));
  end;
  CheckEqI(bad, 0, '**区画長を変えても同じ文が出る** (MDM-008 の区画不変性)');
  CheckEqS(base, MSG, '前提: その文が正しい');
end;

{ --------------------------------------------------------------------------
  4. 確定位置
  -------------------------------------------------------------------------- }
procedure TestSamplePosition;
var
  w: TDoubleArray;
  s: TSink;
begin
  WriteLn;
  WriteLn('--- 4. 確定位置が鎖の遅れを引いた値になる ---');
  w := Transmit(MSG);
  s := TSink.Create;
  try
    Receive(w, 512, s);
    Check(s.Count > 0, '前提: 文字が出ている');
    Check(s.PosOk,
      '**確定位置が「区画の先頭 - 鎖の遅れ」と一致する** (流し直しの起点)');
    Check(s.PosMonotone, '確定位置が後戻りしない');
    Check((s.LastPos >= 0) and (s.LastPos < Length(w)),
      Format('確定位置が音の範囲に収まる (最後 %d / 全 %d)',
        [s.LastPos, Length(w)]));
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. Restart
  -------------------------------------------------------------------------- }
procedure TestRestartResets;
var
  w, wOther, wCut: TDoubleArray;
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  s1, s2: TSink;
  i, cut: Integer;
begin
  WriteLn;
  WriteLn('--- 5. Restart で完全に初期状態へ戻る ---');
  w := Transmit(MSG);
  wOther := AddNoise(Transmit('DE JA1ZZZ TEST'), 1.0, 999);

  { 頭出しごと切り落として途中から流す。頭から流すと、掴み直しの間に
    前の状態が洗い流されて差が見えない (MFSK の §44 と同じ)。 }
  cut := LEAD + 100000;
  if cut >= Length(w) then cut := Length(w) div 2;
  SetLength(wCut, Length(w) - cut);
  for i := 0 to High(wCut) do wCut[i] := w[cut + i];

  s1 := TSink.Create;
  s2 := TSink.Create;
  try
    Receive(wCut, 512, s1);

    snd := TCaptureSoundDevice.Create;
    m := MakeModem(snd);
    try
      m.RxInit;
      m.RxProcess(wOther, Length(wOther));
      m.OnDecode := @s2.Decode;
      m.Restart;
      { 通算サンプル位置は Restart では戻らない (戻すのは流し直す側の
        仕事)。位置が違えば署名も違うのは当然で、それは痕跡ではない。 }
      m.StreamPosition := 0;
      FeedBlocks(m, wCut, 512, s2);
    finally
      m.Free; snd.Free;
    end;

    WriteLn(Format('        途中から: %d 件 / 署名 %s 対 %s',
      [s1.Count, IntToHex(s1.Signature, 8), IntToHex(s2.Signature, 8)]));
    Check(s1.Count > 0, '前提: 途中から流しても何かは出る');
    CheckEqI(s2.Count, s1.Count, '件数が同じ');
    Check(s1.Signature = s2.Signature,
      '**Restart のあとは前の音の痕跡が一切残らない** (文字・位置・尺度まで)');
  finally
    s1.Free; s2.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 前の局と切れ目が違っても読める

  前置きを置いている理由そのものである。交信は交互になるので、
  受信側は必ず「前の局の切れ目に寄った記録」から掴み直す。
  -------------------------------------------------------------------------- }
procedure TestTwoStations;
const
  MSG_A = 'DE JA1ZZZ JA1ZZZ K';
  MSG_B = 'DE JI1UUI JI1UUI K';
var
  wa, wb, both: TDoubleArray;
  got: string;
  i, shift, posA, posB: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 前の局と切れ目が違っても読める ---');
  wa := Transmit(MSG_A, mmOlivia, 0);
  wb := Transmit(MSG_B, mmOlivia, 0);

  { 二人目を半端なサンプル数だけずらして繋ぐ。ぴったり繋ぐと切れ目が
    同じになってしまい、掴み直しの試験にならない。 }
  shift := 37 * 256 + 128;
  SetLength(both, Length(wa) + shift + Length(wb));
  for i := 0 to High(both) do both[i] := 0;
  for i := 0 to High(wa) do both[i] := wa[i];
  for i := 0 to High(wb) do both[Length(wa) + shift + i] := wb[i];

  got := Receive(both, 512);
  posA := Pos(MSG_A, got);
  posB := Pos(MSG_B, got);
  WriteLn('        [', got, ']');
  WriteLn(Format('        一人目 %d 文字目 / 二人目 %d 文字目', [posA, posB]));
  Check(posA > 0, '一人目が読める');
  Check(posB > 0,
    '**切れ目の違う二人目も読める** (前置きが掴み直しの材料になっている)');
  Check(posB > posA, '順番どおりに出る');
end;

{ --------------------------------------------------------------------------
  7. 雑音
  -------------------------------------------------------------------------- }
procedure TestNoise;
const
  TRIALS = 4;
var
  w, w2: TDoubleArray;
  got: string;
  i, k, bad: Integer;
  cer, sum, sigPwr, snr, firstFail: Double;
  foundFail: Boolean;
  rms: array[0..6] of Double = (0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
begin
  WriteLn;
  WriteLn('--- 7. 雑音の中での文字誤り率 ---');
  w := Transmit(MSG, mmOlivia, 0);
  sigPwr := 0;
  for k := 0 to High(w) do sigPwr := sigPwr + w[k] * w[k];
  sigPwr := sigPwr / Length(w);

  WriteLn('          雑音rms   広帯域S/N   文字誤り率 (4種の種の平均)');
  foundFail := False; firstFail := 0;
  for i := 0 to High(rms) do
  begin
    sum := 0;
    for k := 1 to TRIALS do
    begin
      w2 := AddNoise(w, rms[i], QWord(7919 * k + 3));
      sum := sum + CharErrorRate(MSG, Receive(w2, 512));
    end;
    cer := sum / TRIALS;
    if rms[i] > 0 then snr := 10 * Log10(sigPwr / (rms[i] * rms[i]))
    else snr := 0;
    if rms[i] > 0 then
      WriteLn(Format('          %6.2f   %7.1f dB   %.3f', [rms[i], snr, cer]))
    else
      WriteLn(Format('          %6.2f    (無雑音)   %.3f', [rms[i], cer]));
    if (not foundFail) and (cer > 0.01) then
    begin
      foundFail := True;
      firstFail := snr;
    end;
  end;
  Check(foundFail, '掃引が崖を跨いでいる');
  if foundFail then
    WriteLn(Format('        誤り率 1%% を初めて超えた広帯域 S/N: %.1f dB',
      [firstFail]));

  bad := 0;
  for k := 1 to TRIALS do
  begin
    w2 := AddNoise(w, 3.0, QWord(104729 * k + 11));
    if CharErrorRate(MSG, Receive(w2, 512)) > 0 then Inc(bad);
  end;
  CheckEqI(bad, 0, '**雑音 rms 3.0 では 4 種の種すべてで文字誤り 0**');
end;

{ --------------------------------------------------------------------------
  8. Evidence の S/N
  -------------------------------------------------------------------------- }
procedure TestEvidenceSnr;
var
  w: TDoubleArray;
  sClean, sNoisy: TSink;
begin
  WriteLn;
  WriteLn('--- 8. Evidence の S/N と尺度 ---');
  w := Transmit(MSG);
  sClean := TSink.Create;
  sNoisy := TSink.Create;
  try
    Receive(w, 512, sClean);
    Receive(AddNoise(w, 3.0, 4242), 512, sNoisy);
    WriteLn(Format('        無雑音 %.1f dB (尺度 %.2f) / 雑音 rms 3.0 %.1f dB (尺度 %.2f)',
      [sClean.LastSnr, sClean.MaxMetric, sNoisy.LastSnr, sNoisy.MaxMetric]));
    Check(sClean.SnrSeen and sNoisy.SnrSeen, 'S/N が Evidence に載っている');
    Check(sNoisy.LastSnr < sClean.LastSnr,
      '**雑音を足すと申告される S/N が下がる**');
    Check(sNoisy.MaxMetric < sClean.MaxMetric, '雑音があると尺度も下がる');
    { 尺度はブロック単位の同期 S/N である。同じブロックから出た文字
      (= 同じ位置を名乗る文字) どうしでは一致し、ブロックが変われば
      変わる。**文字ごとの確からしさではない**ことを固定しておく ――
      Phase 4 の Confidence がここを取り違えると、同じブロックの
      5 文字を別々に重み付けしてしまう。 }
    Check(sClean.PerBlockOk and sNoisy.PerBlockOk,
      '**尺度はブロック単位** (同じ位置を名乗る文字どうしで一致する)');
    Check(sClean.MaxMetric > sClean.MinMetric,
      Format('ブロックが変われば尺度も変わる (%.2f..%.2f)',
        [sClean.MinMetric, sClean.MaxMetric]));
  finally
    sClean.Free; sNoisy.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. 確保しない
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

procedure TestNoAllocation;
const
  BLOCKS = 100;
var
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  s: TSink;
  buf: array[0..511] of Double;
  i, k, n: Integer;
begin
  WriteLn;
  WriteLn('--- 9. 文字が出ないブロックで確保しない (X-04) ---');
  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd);
  s := TSink.Create;
  try
    m.RxInit;
    m.OnDecode := @s.Decode;
    for i := 0 to High(buf) do buf[i] := 0.001 * Sin(i * 0.37);
    m.RxProcess(buf, Length(buf));

    GetMemoryManager(GOldMM);
    GNewMM := GOldMM;
    GNewMM.GetMem := @CountingGetMem;
    GNewMM.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(GNewMM);
    try
      GAllocCount := 0;
      GCounting := True;
      for k := 1 to BLOCKS do m.RxProcess(buf, Length(buf));
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    WriteLn(Format('        %d ブロック復調 (出力 %d 文字): 確保 %d 回',
      [BLOCKS, s.Count, n]));
    CheckEqI(s.Count, 0, '前提: 無信号なので文字は出ていない');
    CheckEqI(n, 0, '受信ブロック処理で一切確保していない');
  finally
    s.Free; m.Free; snd.Free;
  end;
end;

{ --------------------------------------------------------------------------
  10. 送信帯域
  -------------------------------------------------------------------------- }
procedure TestTransmitSpectrum;
const
  NFFT = 8192;
var
  w: TDoubleArray;
  buf: TComplexArray;
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  tm: TOliviaToneMode;
  i, bin, loBin, hiBin: Integer;
  mag, inBand, outBand, total, centre: Double;
begin
  WriteLn;
  WriteLn('--- 10. 送信波形が諸元どおりの帯域に収まる ---');
  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd);
  try
    tm := m.ToneMode;
    centre := m.Frequency;
  finally
    m.Free; snd.Free;
  end;

  w := Transmit(MSG, mmOlivia, 0);
  SetLength(buf, NFFT);
  for i := 0 to NFFT - 1 do
    buf[i] := CplxMake(w[Length(w) div 2 - NFFT div 2 + i], 0);
  ComplexFFT(buf);

  loBin := Floor((centre - tm.OccupiedBandwidthHz / 2 - 2 * tm.ToneSpacingHz)
           * NFFT / tm.SampleRate);
  hiBin := Ceil((centre + tm.OccupiedBandwidthHz / 2 + 2 * tm.ToneSpacingHz)
           * NFFT / tm.SampleRate);
  inBand := 0; outBand := 0;
  for bin := 0 to NFFT div 2 - 1 do
  begin
    mag := buf[bin].Re * buf[bin].Re + buf[bin].Im * buf[bin].Im;
    if (bin >= loBin) and (bin <= hiBin) then inBand := inBand + mag
    else outBand := outBand + mag;
  end;
  total := inBand + outBand;
  WriteLn(Format('        %.1f..%.1f Hz に %.3f%%',
    [loBin * tm.SampleRate / NFFT, hiBin * tm.SampleRate / NFFT,
     100 * inBand / total]));
  Check(inBand / total > 0.99, '**送信電力の 99% 以上が諸元の帯域に収まる**');
end;

{ --------------------------------------------------------------------------
  11. 同調

  Olivia はトーンの置き場所を **bin** で持っている。周波数を変えたら
  鎖に伝えないと、**指令だけ変わって音が動かない**。ほかのモデムは送受の
  たびに Frequency を読んでいるので要らない用心だが、このモードは
  持ち方が違う。

  実際、最初の実装はここが抜けていた。「送信だけ 60 Hz ずらして受信できる
  はずがない」を確かめようとして、**ずれていないことに気づいた**。
  -------------------------------------------------------------------------- }
function TransmitAt(const AMsg: string; ACentreHz: Double): TDoubleArray;
var
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  src: TTxSource;
  r, guard: Integer;
begin
  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd);
  src := TTxSource.Create(AMsg);
  try
    m.Frequency := ACentreHz;     { ここが鎖に伝わらないと音が動かない }
    m.OnGetTxChar := @src.GetTxChar;
    m.TxInit;
    guard := 0;
    repeat
      r := m.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 300000);
    Result := snd.GetCapturedCopy;
  finally
    src.Free; m.Free; snd.Free;
  end;
end;

function ReceiveAt(const AW: TDoubleArray; ACentreHz: Double): string;
var
  snd: TCaptureSoundDevice;
  m: TOliviaModem;
  s: TSink;
begin
  snd := TCaptureSoundDevice.Create;
  m := MakeModem(snd);
  s := TSink.Create;
  try
    m.Frequency := ACentreHz;
    m.RxInit;
    m.OnDecode := @s.Decode;
    m.RxProcess(AW, Length(AW));
    Result := s.Text;
  finally
    s.Free; m.Free; snd.Free;
  end;
end;

procedure TestTuning;
var
  w: TDoubleArray;
  i: Integer;
  cer, worstOk: Double;
  offs: array[0..5] of Double = (0, 10, 20, 30, 45, 60);
  bad: Integer;
  freqs: array[0..2] of Double = (800, 1000, 1400);
begin
  WriteLn;
  WriteLn('--- 11. 同調 ---');

  { (a) 送受を同じだけ動かせば、どの周波数でも通る。 }
  bad := 0;
  for i := 0 to High(freqs) do
  begin
    w := TransmitAt(MSG, freqs[i]);
    if ReceiveAt(w, freqs[i]) <> MSG then Inc(bad);
    WriteLn(Format('          %4.0f Hz: %s',
      [freqs[i], BoolToStr(ReceiveAt(w, freqs[i]) = MSG, '一致', '×')]));
  end;
  CheckEqI(bad, 0,
    '**Frequency を変えると送受とも本当に動く** (指令が鎖に伝わっている)');

  { (b) 送信だけずらすと、ずれに応じて崩れる。
    崩れなければ (a) は「どちらも動いていない」でも通ってしまう。 }
  WriteLn('          送信だけずらしたとき (受信は 1000 Hz 固定)');
  WriteLn('            ずれ[Hz]  bin   トーン   文字誤り率');
  worstOk := 0;
  for i := 0 to High(offs) do
  begin
    w := TransmitAt(MSG, 1000 + offs[i]);
    cer := CharErrorRate(MSG, ReceiveAt(w, 1000));
    WriteLn(Format('            %6.0f   %4.1f   %4.1f    %.3f',
      [offs[i], offs[i] / 15.625, offs[i] / 31.25, cer]));
    if cer = 0 then worstOk := offs[i];
  end;
  Check(worstOk >= 20,
    Format('**±%.0f Hz のずれまでは通る** (トーン間隔 31.25 Hz の %.0f%%)',
      [worstOk, 100 * worstOk / 31.25]));
  w := TransmitAt(MSG, 1060);
  Check(CharErrorRate(MSG, ReceiveAt(w, 1000)) > 0.5,
    '**前提: 60 Hz ずれれば崩れる** (AFC が無いので当然。Phase 3 の宿題)');
end;

begin
  WriteLn('=== Olivia / Contestia モデムの試験 ===');

  TestRoundTrip;
  TestBlockInvariance;
  TestSamplePosition;
  TestRestartResets;
  TestTwoStations;
  TestNoise;
  TestEvidenceSnr;
  TestNoAllocation;
  TestTransmitSpectrum;
  TestTuning;

  if FailCount = 0 then
    CoverReq('OLV-002');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
