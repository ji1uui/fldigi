{ ============================================================================
  test_mfsk_modem.lpr

  MFSK16 / MFSK32 をモードとして成立させる試験 (units/MfskModemImpl.pas)。

  何を守るか
  ----------------------------------------------------------------------------
  1. **送って受ければ元の文が出る** (MFSK16 / MFSK32)
  2. 区画の切り方を変えても結果が同じ (Phase 3 の戦略として配れる)
  3. 確定位置 (SamplePos) が区画の先頭を指す
  4. Restart で完全に初期状態へ戻る
  5. 頭のずれ・送受の時計差があっても本文が出る
  6. 雑音の中での文字誤り率を数字で残す
  7. Evidence に尺度と S/N が載る
  8. 文字が出ないブロックで確保しない (X-04)
  9. 送信波形が諸元どおりの帯域に収まる

  ここが主張するのは**層が繋がること**である。各層そのものは
  MDM-009 (符号) / MDM-010 (文字とビット) / MDM-012 (トーン) /
  MDM-013 (同期) がそれぞれ見ている。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_mfsk_modem;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ModemTypes, ModemDSP, Modem, DecodeEvidence, SoundIntf,
  MfskModemImpl, MfskTones, ErrorRate, TestVectors, TestSupport, Requirements;

const
  { 送信の前後に置く無音。実際の受信は音の途中から始まる。 }
  LEAD = 4000;

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

{ ==========================================================================
  受け皿

  NUL は落とす。頭出しの空回し (sendidle) が NUL の符号を使うので、
  本文の前に必ず数個出てくる。**捨てているのは表示の都合であって、
  復調器が出していないのではない** ―― 件数は別に数えてある。
  ========================================================================== }
type
  TSink = class
  public
    Text: string;
    Count: Integer;
    NulCount: Integer;
    BlockStart: Int64;
    PosOk: Boolean;
    PosMonotone: Boolean;
    LastPos: Int64;
    MinMetric, MaxMetric: Double;
    SnrSeen: Boolean;
    LastSnr: Double;
    KindOk: Boolean;
    NameOk: Boolean;
    { 出したものすべての署名。文字だけでなく**位置と尺度**まで混ぜる。
      文字列の比較では、状態が残っていても本文が同じなら気づけない
      (実際、Viterbi を戻さなくても本文は一致してしまう)。 }
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
  PosOk := True;
  PosMonotone := True;
  LastPos := -1;
  BlockStart := -1;
  MinMetric := 1E30;
  MaxMetric := -1E30;
  KindOk := True;
  NameOk := True;
  Signature := 2166136261;
end;

procedure TSink.Decode(Sender: TCustomModem; const AEv: TDecodeEvidence);
var
  c: Integer;
begin
  Inc(Count);
  c := AEv.BestChar;
  if c = 0 then Inc(NulCount)
  else if c > 0 then Text := Text + Chr(c);

  if AEv.BestMetric < MinMetric then MinMetric := AEv.BestMetric;
  if AEv.BestMetric > MaxMetric then MaxMetric := AEv.BestMetric;
  if AEv.MetricKind <> emkLogLikelihood then KindOk := False;
  if AEv.DecoderName <> Sender.DecoderName then NameOk := False;
  if AEv.HasSnr then begin SnrSeen := True; LastSnr := AEv.SnrDb; end;

  if BlockStart >= 0 then
    if AEv.SamplePos <> BlockStart then PosOk := False;
  if AEv.SamplePos < LastPos then PosMonotone := False;
  LastPos := AEv.SamplePos;

  MixIn(Signature, c);
  MixIn(Signature, AEv.SamplePos);
  MixIn(Signature, Round(AEv.BestMetric * 1000));
end;

{ ==========================================================================
  送信と受信
  ========================================================================== }
function Transmit(AMode: TModemMode; const AMsg: string;
  ALead: Integer = LEAD): TDoubleArray;
var
  snd: TCaptureSoundDevice;
  m: TMfskModem;
  src: TTxSource;
  raw: TDoubleArray;
  r, guard, i: Integer;
begin
  snd := TCaptureSoundDevice.Create;
  m := TMfskModem.Create(snd, AMode);
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

{ 区画に分けて器へ流す。**同じ切り方**で流さないと SamplePos が変わり、
  署名の比較が成り立たない。二か所で書くと必ずずれるので関数にしてある。 }
procedure FeedBlocks(AModem: TCustomModem; const AW: TDoubleArray;
  ABlk: Integer; ASink: TSink);
var
  b: TDoubleArray;
  i, n: Integer;
begin
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

function Receive(AMode: TModemMode; const AW: TDoubleArray; ABlk: Integer;
  ASink: TSink = nil): string;
var
  snd: TCaptureSoundDevice;
  m: TMfskModem;
  s: TSink;
  own: Boolean;
begin
  own := ASink = nil;
  if own then s := TSink.Create else s := ASink;
  snd := TCaptureSoundDevice.Create;
  m := TMfskModem.Create(snd, AMode);
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

{ 雑音を足す。決まった種から作るので同じ音が二度作れる。 }
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

{ サンプル速度がずれた音にする (送受の水晶の違い)。 }
function Resample(const AW: TDoubleArray; APpm: Double): TDoubleArray;
var
  i, n, j: Integer;
  pos, frac, ratio: Double;
begin
  ratio := 1.0 + APpm * 1E-6;
  n := Trunc(Length(AW) / ratio) - 1;
  if n < 1 then n := 1;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    pos := i * ratio;
    j := Trunc(pos);
    frac := pos - j;
    if j + 1 <= High(AW) then
      Result[i] := AW[j] * (1 - frac) + AW[j + 1] * frac
    else
      Result[i] := AW[High(AW)];
  end;
end;

const
  MSG = 'CQ CQ DE JI1UUI JI1UUI PSE K';

{ --------------------------------------------------------------------------
  1. 往復
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  w: TDoubleArray;
  s: TSink;
  got: string;
  m: TMfskModem;
  snd: TCaptureSoundDevice;
begin
  WriteLn;
  WriteLn('--- 1. 送って受ければ元の文が出る ---');

  snd := TCaptureSoundDevice.Create;
  m := TMfskModem.Create(snd, mmMFSK16);
  try
    WriteLn(Format('        %s / 空回し %d ビット',
      [m.MfskMode.Describe, m.FlushBits]));
    CheckEqI(m.FlushBits,
      (m.MfskMode.SymBits * 3 * m.MfskMode.Depth) div 2 + 45 + 6,
      '空回しが鎖の遅れから出ている (インタリーバ往復 + 遡り + 符号器の記憶)');
  finally
    m.Free; snd.Free;
  end;

  w := Transmit(mmMFSK16, MSG);
  WriteLn(Format('        送信 %d サンプル = %.2f 秒',
    [Length(w), Length(w) / MFSK16_MODE.SampleRate]));

  s := TSink.Create;
  try
    got := Receive(mmMFSK16, w, 512, s);
    CheckEqS(got, MSG, '**MFSK16 の往復で元の文がそのまま出る**');
    Check(s.NulCount > 0,
      Format('頭出しの NUL も Evidence として上がっている (%d 件)',
        [s.NulCount]));
    Check(s.KindOk, '尺度の種類が対数尤度として申告されている');
    Check(s.NameOk, 'Evidence が出所 (復調器の名前) を名乗る');
  finally
    s.Free;
  end;

  { MFSK32 も同じ鎖である。 }
  w := Transmit(mmMFSK32, MSG);
  got := Receive(mmMFSK32, w, 512);
  CheckEqS(got, MSG, '**MFSK32 の往復でも元の文が出る**');
end;

{ --------------------------------------------------------------------------
  2. 区画の切り方を変えても同じ

  Phase 3 の Algorithm Portfolio は同じ音を複数の戦略に配る。配る側の
  都合で区画長が変われば結果が変わる、というのでは戦略として使えない
  (MDM-008)。
  -------------------------------------------------------------------------- }
procedure TestBlockInvariance;
var
  w: TDoubleArray;
  base, got: string;
  i: Integer;
  blocks: array[0..4] of Integer = (0, 37, 512, 1000, 4096);
  bad: Integer;
begin
  WriteLn;
  WriteLn('--- 2. 区画の切り方を変えても同じ ---');
  w := Transmit(mmMFSK16, MSG);
  base := Receive(mmMFSK16, w, 512);
  bad := 0;
  for i := 0 to High(blocks) do
  begin
    got := Receive(mmMFSK16, w, blocks[i]);
    if got <> base then Inc(bad);
    WriteLn(Format('        区画 %5d: %s', [blocks[i],
      BoolToStr(got = base, '同じ', '違う')]));
  end;
  CheckEqI(bad, 0, '**区画長を変えても同じ文が出る** (MDM-008 の区画不変性)');
  CheckEqS(base, MSG, '前提: その文が正しい');
end;

{ --------------------------------------------------------------------------
  3. 確定位置
  -------------------------------------------------------------------------- }
procedure TestSamplePosition;
var
  w: TDoubleArray;
  s: TSink;
begin
  WriteLn;
  WriteLn('--- 3. 確定位置が区画の先頭を指す ---');
  w := Transmit(mmMFSK16, MSG);
  s := TSink.Create;
  try
    Receive(mmMFSK16, w, 512, s);
    Check(s.Count > 0, '前提: 文字が出ている');
    Check(s.PosOk, '**確定位置がその区画の先頭と一致する**');
    Check(s.PosMonotone, '確定位置が後戻りしない');
    Check((s.LastPos >= 0) and (s.LastPos < Length(w)),
      Format('確定位置が音の範囲に収まる (最後 %d / 全 %d)',
        [s.LastPos, Length(w)]));
  finally
    s.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. Restart で完全に戻る
  -------------------------------------------------------------------------- }
procedure TestRestartResets;
var
  w, wCut: TDoubleArray;
  wOther: TDoubleArray;
  snd: TCaptureSoundDevice;
  m: TMfskModem;
  s1, s2, s3: TSink;
  i, cut: Integer;
begin
  WriteLn;
  WriteLn('--- 4. Restart で完全に初期状態へ戻る ---');
  w := Transmit(mmMFSK16, MSG);

  { --- (a) 同じ器へ二度流しても同じ文 --- }
  snd := TCaptureSoundDevice.Create;
  m := TMfskModem.Create(snd, mmMFSK16);
  s1 := TSink.Create;
  s2 := TSink.Create;
  try
    m.OnDecode := @s1.Decode;
    m.RxInit;
    m.RxProcess(w, Length(w));

    m.OnDecode := @s2.Decode;
    m.Restart;
    m.RxProcess(w, Length(w));

    CheckEqS(s2.Text, s1.Text, '同じ器へ二度流しても同じ文が出る');
    CheckEqS(s2.Text, MSG, '前提: その文が正しい');
    CheckEqI(s2.Count, s1.Count, '件数まで同じ');
    Check(m.RxSymbolCount > 0,
      Format('前提: シンボルを切り出している (%d 個)', [m.RxSymbolCount]));
  finally
    s1.Free; s2.Free; m.Free; snd.Free;
  end;

  { --- (b) **途中から**流す ---
    頭出しの空回しごと切り落とす。ここから流すと、最初の数十ビットは
    「前に何を復号していたか」に左右される ―― Viterbi も戻しの表も
    自分で立て直す性質があるので、頭から流すかぎり状態が残っていても
    本文は一致してしまう。実際、Viterbi を戻さない細工は (a) を
    素通りする。切り落としてはじめて観測できる。

    比べるのは文字列ではなく**署名** (文字 + 位置 + 尺度)。 }
  cut := LEAD + 40000;
  SetLength(wCut, Length(w) - cut);
  for i := 0 to High(wCut) do wCut[i] := w[cut + i];

  wOther := AddNoise(Transmit(mmMFSK16, 'DE JA1ZZZ TEST TEST'), 1.0, 999);

  s1 := TSink.Create;
  s3 := TSink.Create;
  try
    { きれいな器で途中から }
    Receive(mmMFSK16, wCut, 512, s1);

    { 別の音を通したあとの器で、Restart してから途中から }
    snd := TCaptureSoundDevice.Create;
    m := TMfskModem.Create(snd, mmMFSK16);
    try
      m.RxInit;
      m.RxProcess(wOther, Length(wOther));
      m.OnDecode := @s3.Decode;
      m.Restart;
      { 通算サンプル位置は Restart では戻らない。戻すのは流し直す側の
        仕事である (AudioReplay が RxInit のあとに置く)。ここでも
        同じようにしてから比べる ―― 位置が違えば署名も違うのは当然で、
        それは痕跡ではない。 }
      m.StreamPosition := 0;
      FeedBlocks(m, wCut, 512, s3);
    finally
      m.Free; snd.Free;
    end;

    WriteLn(Format('        途中から: %d 文字 / 署名 %s 対 %s',
      [s1.Count, IntToHex(s1.Signature, 8), IntToHex(s3.Signature, 8)]));
    Check(s1.Count > 0, '前提: 途中から流しても何かは出る');
    CheckEqI(s3.Count, s1.Count, '途中から流したときの件数が同じ');
    Check(s1.Signature = s3.Signature,
      '**Restart のあとは前の音の痕跡が一切残らない** (文字・位置・尺度まで)');
  finally
    s1.Free; s3.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 頭のずれと送受の時計差
  -------------------------------------------------------------------------- }
procedure TestOffsetAndDrift;
var
  w, w2: TDoubleArray;
  got: string;
  i, k, lead, bad: Integer;
  leads: array[0..3] of Integer = (0, 128, 256, 383);
  ppms: array[0..2] of Double = (-500, 0, 500);
begin
  WriteLn;
  WriteLn('--- 5. 頭のずれ / 送受の時計差 ---');
  w := Transmit(mmMFSK16, MSG);

  bad := 0;
  for i := 0 to High(leads) do
  begin
    lead := leads[i];
    SetLength(w2, Length(w) + lead);
    for k := 0 to High(w2) do w2[k] := 0;
    for k := 0 to High(w) do w2[lead + k] := w[k];
    got := Receive(mmMFSK16, w2, 512);
    if got <> MSG then Inc(bad);
    WriteLn(Format('        ずれ %3d サンプル: %s',
      [lead, BoolToStr(got = MSG, '一致', '[' + got + ']')]));
  end;
  CheckEqI(bad, 0,
    '**受信の開始位置がどこでも本文が出る** (シンボル同期が引き込む)');

  bad := 0;
  for i := 0 to High(ppms) do
  begin
    w2 := Resample(w, ppms[i]);
    got := Receive(mmMFSK16, w2, 512);
    if got <> MSG then Inc(bad);
    WriteLn(Format('        時計差 %5.0f ppm: %s',
      [ppms[i], BoolToStr(got = MSG, '一致', '[' + got + ']')]));
  end;
  CheckEqI(bad, 0, '**送受の時計が ±500 ppm 違っても本文が出る**');
end;

{ --------------------------------------------------------------------------
  6. 雑音の中での文字誤り率
  -------------------------------------------------------------------------- }
procedure TestNoise;
var
  w, w2: TDoubleArray;
  got: string;
  i, seed, bad: Integer;
  cer, sum, sigPwr, snr: Double;
  { 崖を跨ぐまで振る。**崖が掃引の外にあると、見つからなかったことを
    「強い」と読み違える** (README 42 章で一度やっている)。 }
  rms: array[0..10] of Double =
    (0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0);
  firstFail: Double;
  foundFail: Boolean;
  k: Integer;
begin
  WriteLn;
  WriteLn('--- 6. 雑音の中での文字誤り率 ---');
  w := Transmit(mmMFSK16, MSG, 0);

  { 本文だけの実効電力。無音の前後を入れると薄まって S/N を過小に
    見積もるので、前後の無音は入れずに送った波形で測る。 }
  sigPwr := 0;
  for k := 0 to High(w) do sigPwr := sigPwr + w[k] * w[k];
  sigPwr := sigPwr / Length(w);

  WriteLn('          雑音rms   広帯域S/N   文字誤り率 (8種の種の平均)');
  foundFail := False;
  firstFail := 0;
  for i := 0 to High(rms) do
  begin
    sum := 0;
    for seed := 1 to 8 do
    begin
      w2 := AddNoise(w, rms[i], seed * 7919);
      got := Receive(mmMFSK16, w2, 512);
      sum := sum + CharErrorRate(MSG, got);
    end;
    cer := sum / 8;
    if rms[i] > 0 then
      snr := 10 * Log10(sigPwr / (rms[i] * rms[i]))
    else
      snr := 999;
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

  bad := 0;
  for seed := 1 to 8 do
  begin
    w2 := AddNoise(w, 2.0, seed * 104729);
    if CharErrorRate(MSG, Receive(mmMFSK16, w2, 512)) > 0 then Inc(bad);
  end;
  CheckEqI(bad, 0, '**雑音 rms 2.0 では 8 種の種すべてで文字誤り 0**');
  if foundFail then
    WriteLn(Format('        誤り率 1%% を初めて超えた広帯域 S/N: %.1f dB',
      [firstFail]))
  else
    WriteLn('        掃引した範囲では誤り率 1% を超えなかった');
end;

{ --------------------------------------------------------------------------
  7. Evidence に S/N が載る
  -------------------------------------------------------------------------- }
procedure TestEvidenceSnr;
var
  w: TDoubleArray;
  sClean, sNoisy: TSink;
begin
  WriteLn;
  WriteLn('--- 7. Evidence の S/N ---');
  w := Transmit(mmMFSK16, MSG);

  sClean := TSink.Create;
  sNoisy := TSink.Create;
  try
    Receive(mmMFSK16, w, 512, sClean);
    Receive(mmMFSK16, AddNoise(w, 2.0, 4242), 512, sNoisy);
    WriteLn(Format('        無雑音 %.1f dB / 雑音 rms 2.0 %.1f dB',
      [sClean.LastSnr, sNoisy.LastSnr]));
    Check(sClean.SnrSeen and sNoisy.SnrSeen, 'S/N が Evidence に載っている');
    Check(sNoisy.LastSnr < sClean.LastSnr,
      '**雑音を足すと申告される S/N が下がる**');
    Check(sClean.LastSnr <= 60.0,
      Format('無雑音でも申告を 60 dB で切る (実測 %.1f dB)',
        [sClean.LastSnr]));
    Check(sClean.MinMetric > sNoisy.MinMetric,
      Format('雑音があると尺度も下がる (%.1f 対 %.1f)',
        [sClean.MinMetric, sNoisy.MinMetric]));
  finally
    sClean.Free; sNoisy.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 文字が出ないブロックで確保しない (X-04)
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
  m: TMfskModem;
  s: TSink;
  buf: array[0..511] of Double;
  i, k, n: Integer;
begin
  WriteLn;
  WriteLn('--- 8. 文字が出ないブロックで確保しない (X-04) ---');
  snd := TCaptureSoundDevice.Create;
  m := TMfskModem.Create(snd, mmMFSK16);
  s := TSink.Create;
  try
    m.RxInit;
    m.OnDecode := @s.Decode;
    for i := 0 to High(buf) do buf[i] := 0.001 * Sin(i * 0.37);
    m.RxProcess(buf, Length(buf));   { 初回ぶんを済ませる }

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
  9. 送信波形が諸元どおりの帯域に収まる

  トーンの本数ぶんの線が、決めた間隔で、決めた位置に立つこと。
  ここを外すと、電波を出したときに隣へはみ出す。
  -------------------------------------------------------------------------- }
procedure TestTransmitSpectrum;
const
  NFFT = 8192;
var
  w: TDoubleArray;
  buf: TComplexArray;
  i, bin, loBin, hiBin: Integer;
  mag, inBand, outBand, total: Double;
  m: TMfskModem;
  snd: TCaptureSoundDevice;
  mode: TMfskMode;
begin
  WriteLn;
  WriteLn('--- 9. 送信波形が諸元どおりの帯域に収まる ---');
  snd := TCaptureSoundDevice.Create;
  m := TMfskModem.Create(snd, mmMFSK16);
  try
    mode := m.MfskMode;
  finally
    m.Free; snd.Free;
  end;

  w := Transmit(mmMFSK16, MSG, 0);
  SetLength(buf, NFFT);
  { 頭の空回しを避けて真ん中から取る。 }
  for i := 0 to NFFT - 1 do
    buf[i] := CplxMake(w[Length(w) div 2 + i], 0);
  ComplexFFT(buf);

  { 帯域は「最低トーンから最高トーンまで」+ 両側に間隔 2 本ぶんの余裕。
    上流の帯域通過フィルタ (flo/fhi) と同じ取り方である。 }
  loBin := Floor((mode.BaseFreqHz - 2 * mode.ToneSpacingHz)
           * NFFT / mode.SampleRate);
  hiBin := Ceil((mode.BaseFreqHz + mode.BandwidthHz + 2 * mode.ToneSpacingHz)
           * NFFT / mode.SampleRate);

  inBand := 0; outBand := 0;
  for bin := 0 to NFFT div 2 - 1 do
  begin
    mag := buf[bin].Re * buf[bin].Re + buf[bin].Im * buf[bin].Im;
    if (bin >= loBin) and (bin <= hiBin) then
      inBand := inBand + mag
    else
      outBand := outBand + mag;
  end;
  total := inBand + outBand;
  WriteLn(Format('        %.1f..%.1f Hz (bin %d..%d) に %.3f%%',
    [loBin * mode.SampleRate / NFFT, hiBin * mode.SampleRate / NFFT,
     loBin, hiBin, 100 * inBand / total]));
  Check(inBand / total > 0.99,
    '**送信の電力の 99% 以上が諸元の帯域に収まる**');
end;

begin
  WriteLn('=== MFSK16 / MFSK32 モデムの試験 ===');

  TestRoundTrip;
  TestBlockInvariance;
  TestSamplePosition;
  TestRestartResets;
  TestOffsetAndDrift;
  TestNoise;
  TestEvidenceSnr;
  TestNoAllocation;
  TestTransmitSpectrum;

  if FailCount = 0 then
    CoverReq('MDM-011');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
