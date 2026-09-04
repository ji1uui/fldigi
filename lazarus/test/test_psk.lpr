{ ============================================================================
  test_psk.lpr

  BPSK (PSK31 / PSK63 / PSK125) モデムの試験。

  何を守るか
  ----------------------------------------------------------------------------
  1. 送って受けたら同じ文字列に戻る (3 モード / 全印字文字)
  2. 雑音があっても本文が読める
  3. **軟判定の余裕が本文と雑音を分離する** ── ここがこの試験の中心
  4. Evidence の中身が約束どおり (位置・尺度の種類・復調器名)
  5. 同じインスタンスに流し直しても同じ結果 (X-06 Replay / Z-05)
  6. 復調が確保しない (X-04)

  3 について
  ----------------------------------------------------------------------------
  PSK31 にはスケルチが要る。搬送波が無くても、雑音がたまたま varicode の
  形になれば文字が出てしまうからである (実測で雑音だけ 20 秒に 85 文字)。
  fldigi は metric に閾値を置いて門番するが、**閾値は運用者が回すつまみ**
  であって、正しい位置は信号ごとに違う。

  この移植では、門番の代わりに **1 文字ごとの確からしさ**を Evidence に
  載せる (ADR-002)。その文字を構成したビットのうち、最も判定境界に近かった
  ものの余裕である。捨てるかどうかは上の層が決める。

  それが機能するには、本文と雑音で値が実際に分かれていなければならない。
  実測 (雑音を 64 倍まで振って):

      本文        平均 0.966 〜 1.000
      雑音のゴミ  平均 0.261 〜 0.340

  この分離を試験で固定する。分離しなければ、Phase 4 の Confidence は
  この尺度の上には建てられない。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_psk;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  SoundIntf, ModemTypes, Modem, ModemDSP, PskModemImpl, PskVaricode,
  DecodeEvidence, TestSupport, Requirements;

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

procedure CheckEqS(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: [', AExpected, ']');
    WriteLn('        実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

type
  { 復号された文字と、その根拠を並べて覚える。 }
  TPskSink = class
  private
    FCh: array of Char;
    FMargin: array of Double;
    FPos: array of Int64;
    FKind: array of TEvidenceMetricKind;
    FDecoder: string;
  public
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
    procedure Reset;
    function Count: Integer;
    function Text: string;
    function MarginAt(AIndex: Integer): Double;
    function PosAt(AIndex: Integer): Int64;
    function KindAt(AIndex: Integer): TEvidenceMetricKind;
    property Decoder: string read FDecoder;
  end;

procedure TPskSink.Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
var
  n: Integer;
begin
  if AEvidence.BestChar <= 0 then Exit;
  n := Length(FCh);
  SetLength(FCh, n + 1);
  SetLength(FMargin, n + 1);
  SetLength(FPos, n + 1);
  SetLength(FKind, n + 1);
  FCh[n] := Chr(AEvidence.BestChar);
  FMargin[n] := AEvidence.BestMetric;
  FPos[n] := AEvidence.SamplePos;
  FKind[n] := AEvidence.MetricKind;
  FDecoder := AEvidence.DecoderName;
end;

procedure TPskSink.Reset;
begin
  SetLength(FCh, 0); SetLength(FMargin, 0);
  SetLength(FPos, 0); SetLength(FKind, 0);
  FDecoder := '';
end;

function TPskSink.Count: Integer;
begin
  Result := Length(FCh);
end;

function TPskSink.Text: string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(FCh) do Result := Result + FCh[i];
end;

function TPskSink.MarginAt(AIndex: Integer): Double;
begin Result := FMargin[AIndex]; end;

function TPskSink.PosAt(AIndex: Integer): Int64;
begin Result := FPos[AIndex]; end;

function TPskSink.KindAt(AIndex: Integer): TEvidenceMetricKind;
begin Result := FKind[AIndex]; end;

{ --------------------------------------------------------------------------
  共通: 送って受ける
  -------------------------------------------------------------------------- }
const
  RATE = 8000;

{ AMsg を AMode で送信した波形を作る。 }
function BuildWave(const AMsg: string; AMode: TModemMode): TDoubleArray;
var
  txs: TCaptureSoundDevice;
  tx: TPskModem;
  src: TTxSource;
  guard, r: Integer;
begin
  txs := TCaptureSoundDevice.Create;
  tx := TPskModem.Create(txs, AMode);
  src := TTxSource.Create(AMsg);
  try
    tx.Frequency := 1000;
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    guard := 0;
    repeat
      r := tx.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 200000);
    Result := txs.GetCapturedCopy;
  finally
    src.Free; tx.Free; txs.Free;
  end;
end;

{ 波形に雑音を重ねて受信し、sink に貯める。 }
procedure Receive(const AWave: TDoubleArray; AMode: TModemMode;
  ANoise: Double; ASink: TPskSink; ALeadSec: Double = 0.5);
var
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  sil, w: array of Double;
  i: Integer;
begin
  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, AMode);
  try
    rx.Frequency := 1000;
    rx.OnDecode := @ASink.Decode;

    SetLength(sil, Round(RATE * ALeadSec));
    for i := 0 to High(sil) do sil[i] := ANoise * (Random - 0.5);
    if Length(sil) > 0 then rx.RxProcess(sil, Length(sil));

    SetLength(w, Length(AWave));
    for i := 0 to High(w) do w[i] := AWave[i] + ANoise * (Random - 0.5);
    rx.RxProcess(w, Length(w));

    if Length(sil) > 0 then rx.RxProcess(sil, Length(sil));
  finally
    rx.Free; rxs.Free;
  end;
end;

{ --------------------------------------------------------------------------
  1. 諸元
  -------------------------------------------------------------------------- }
procedure TestParameters;
var
  snd: TCaptureSoundDevice;
  m: TPskModem;
begin
  WriteLn;
  WriteLn('--- 1. 諸元 ---');
  snd := TCaptureSoundDevice.Create;
  try
    m := TPskModem.Create(snd, mmPSK31);
    try
      CheckEqI(m.SymbolLen, 256, 'PSK31 の 1 記号は 256 サンプル');
      Check(Abs(m.BaudRate - 31.25) < 0.001,
        'PSK31 は 31.25 ボー (8000/256)');
      CheckEqI(m.SampleRate, 8000, '標本化周波数は 8000');
    finally m.Free; end;

    m := TPskModem.Create(snd, mmPSK63);
    try
      CheckEqI(m.SymbolLen, 128, 'PSK63 の 1 記号は 128 サンプル');
      Check(Abs(m.BaudRate - 62.5) < 0.001, 'PSK63 は 62.5 ボー');
    finally m.Free; end;

    m := TPskModem.Create(snd, mmPSK125);
    try
      CheckEqI(m.SymbolLen, 64, 'PSK125 の 1 記号は 64 サンプル');
      Check(Abs(m.BaudRate - 125.0) < 0.001, 'PSK125 は 125 ボー');
    finally m.Free; end;

    { スケルチを解釈すると名乗っていること。基底クラスは Squelch を
      全モデムに公開しているが、実際に見るのは PSK だけである。
      名乗っていなければ、呼び出し側は設定が効くかどうか判断できない。 }
    m := TPskModem.Create(snd, mmPSK31);
    try
      Check(mcSquelch in m.Capabilities,
        '**PSK は mcSquelch を名乗る** (Squelch を実際に解釈する)');
    finally m.Free; end;

    { 扱えないモードは受け付けない。黙って別のモードで動くより、
      作れないと言うほうがよい。 }
    Inc(TestCount);
    try
      m := TPskModem.Create(snd, mmRTTY);
      m.Free;
      WriteLn('  [NG] BPSK 以外のモードを拒む');
      Inc(FailCount);
    except
      on E: EPskModemError do
        WriteLn('  [OK] **BPSK 以外のモードを拒む** (黙って別物にならない)');
    end;
  finally
    snd.Free;
  end;
end;

{ --------------------------------------------------------------------------
  2. 雑音なしの往復
  -------------------------------------------------------------------------- }
procedure TestRoundTripClean;
const
  MSG = 'CQ DE JA1ABC K';

  procedure One(AMode: TModemMode; const AName: string);
  var
    sink: TPskSink;
    w: TDoubleArray;
  begin
    sink := TPskSink.Create;
    try
      w := BuildWave(MSG, AMode);
      Receive(w, AMode, 0.0, sink);
      WriteLn(Format('        %s: 波形 %.2f 秒 / %d 文字',
        [AName, Length(w) / RATE, sink.Count]));
      CheckEqS(Trim(sink.Text), MSG,
        Format('**%s で送って受けたら同じ文字列**', [AName]));
    finally
      sink.Free;
    end;
  end;

begin
  WriteLn;
  WriteLn('--- 2. 雑音なしの往復 ---');
  One(mmPSK31, 'PSK31');
  One(mmPSK63, 'PSK63');
  One(mmPSK125, 'PSK125');
end;

{ --------------------------------------------------------------------------
  3. 全印字文字の往復

  varicode の表は 256 文字ぶんあるが、実際に復調まで通るかは別の話で
  ある。記号や数字も含めて端から端まで通す。
  -------------------------------------------------------------------------- }
procedure TestAllPrintable;
var
  msg: string;
  i, chunk: Integer;
  sink: TPskSink;
  w: TDoubleArray;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 3. 全印字文字の往復 ---');
  { 32..126 を 3 つに割って送る (1 回が長くなりすぎないように)。 }
  ok := True;
  for chunk := 0 to 2 do
  begin
    msg := '';
    for i := 32 + chunk * 32 to Min(126, 32 + chunk * 32 + 31) do
      msg := msg + Chr(i);
    if msg = '' then Continue;

    sink := TPskSink.Create;
    try
      w := BuildWave(msg, mmPSK125);
      Receive(w, mmPSK125, 0.0, sink);
      if Trim(sink.Text) <> Trim(msg) then
      begin
        ok := False;
        WriteLn('        期待: [', msg, ']');
        WriteLn('        実際: [', sink.Text, ']');
      end;
    finally
      sink.Free;
    end;
  end;
  Check(ok, '**印字できる 95 文字すべてが往復する** (記号・数字を含む)');
end;

{ --------------------------------------------------------------------------
  4. 雑音があっても本文が読めること

  どこまで耐えるかを先に測った (乱数 5 種 × 雑音 9 段)。送信波形は
  記号ごとに山を 1 へ揃えてあるので、雑音の値はそのまま信号に対する
  比とみて差し支えない。

      雑音 1.00 〜 10.49   5/5 で本文が読める
      雑音 16.78 以上      0/5

  崖はかなり急である。試験では余裕をみて 6.4 までを要求する。
  ここを 10 や 16 に上げると、乱数の巡り合わせで落ちる試験になる。
  -------------------------------------------------------------------------- }
procedure TestNoise;
const
  MSG = 'CQ DE JA1ABC K';
  Levels: array[0..4] of Double = (0.05, 0.2, 0.8, 3.2, 6.4);
var
  k: Integer;
  noise: Double;
  sink: TPskSink;
  w: TDoubleArray;
  txt: string;
begin
  WriteLn;
  WriteLn('--- 4. 雑音耐性 ---');
  w := BuildWave(MSG, mmPSK31);
  for k := 0 to High(Levels) do
  begin
    noise := Levels[k];
    sink := TPskSink.Create;
    try
      Receive(w, mmPSK31, noise, sink);
      txt := sink.Text;
      WriteLn(Format('        雑音 %.2f -> %d 文字 [%s]',
        [noise, sink.Count, txt]));
      Check(Pos(MSG, txt) > 0,
        Format('雑音 %.2f でも本文が読める', [noise]));
    finally
      sink.Free;
    end;
  end;
end;

{ --------------------------------------------------------------------------
  5. 軟判定の余裕が本文と雑音を分離すること  ── この試験の中心
  -------------------------------------------------------------------------- }
procedure TestSoftMarginSeparates;
const
  MSG = 'CQ DE JA1ABC K';
var
  k, i, p, inN, outN: Integer;
  noise, inSum, outSum, inAvg, outAvg: Double;
  sink: TPskSink;
  w: TDoubleArray;
  txt: string;
  worstIn, bestOut: Double;
begin
  WriteLn;
  WriteLn('--- 5. 軟判定が本文と雑音を分離すること (MDM-004) ---');
  w := BuildWave(MSG, mmPSK31);
  worstIn := 1.0;
  bestOut := 0.0;

  for k := 0 to 3 do
  begin
    noise := 0.05 * Power(4, k);
    sink := TPskSink.Create;
    try
      Receive(w, mmPSK31, noise, sink, 1.0);
      txt := sink.Text;
      p := Pos(MSG, txt);
      Check(p > 0, Format('前提: 雑音 %.2f で本文が見つかる', [noise]));
      if p <= 0 then Continue;

      inSum := 0; outSum := 0; inN := 0; outN := 0;
      for i := 0 to sink.Count - 1 do
        if (i >= p - 1) and (i < p - 1 + Length(MSG)) then
        begin
          inSum := inSum + sink.MarginAt(i); Inc(inN);
        end
        else
        begin
          outSum := outSum + sink.MarginAt(i); Inc(outN);
        end;

      inAvg := inSum / Max(1, inN);
      outAvg := outSum / Max(1, outN);
      if inAvg < worstIn then worstIn := inAvg;
      if (outN > 0) and (outAvg > bestOut) then bestOut := outAvg;

      WriteLn(Format('        雑音 %.2f  本文 %d 文字 平均 %.3f / ' +
        'ゴミ %d 文字 平均 %.3f', [noise, inN, inAvg, outN, outAvg]));

      Check(inAvg > 0.9,
        Format('雑音 %.2f: 本文の余裕が 0.9 より大きい', [noise]));
      if outN > 0 then
        Check(outAvg < 0.6,
          Format('雑音 %.2f: 雑音由来の余裕が 0.6 より小さい', [noise]));
    finally
      sink.Free;
    end;
  end;

  WriteLn(Format('        全体: 本文の最悪 %.3f / ゴミの最良 %.3f',
    [worstIn, bestOut]));
  Check(worstIn > bestOut + 0.3,
    '**本文とゴミの間に 0.3 以上の隔たりがある** ' +
    '(この尺度の上に Confidence を建てられる)');
end;

{ --------------------------------------------------------------------------
  6. Evidence の中身 (ADR-002)
  -------------------------------------------------------------------------- }
procedure TestEvidenceShape;
const
  MSG = 'TEST DE JA1ABC';
var
  sink: TPskSink;
  w: TDoubleArray;
  i, badKind, badOrder: Integer;
begin
  WriteLn;
  WriteLn('--- 6. Evidence の中身 ---');
  sink := TPskSink.Create;
  try
    w := BuildWave(MSG, mmPSK63);
    Receive(w, mmPSK63, 0.0, sink);
    Check(sink.Count > 0, '前提: 復号できている');

    badKind := 0;
    for i := 0 to sink.Count - 1 do
      if sink.KindAt(i) <> emkSoftMargin then Inc(badKind);
    CheckEqI(badKind, 0, '**尺度の種類が emkSoftMargin** (種類を名乗っている)');

    Check(sink.Decoder <> '', '復調器の名前が入っている: ' + sink.Decoder);

    badOrder := 0;
    for i := 1 to sink.Count - 1 do
      if sink.PosAt(i) < sink.PosAt(i - 1) then Inc(badOrder);
    CheckEqI(badOrder, 0, '入力位置が単調に増える');
    Check(sink.PosAt(0) > 0, '入力位置が 0 より大きい (進んでいる)');

    for i := 0 to sink.Count - 1 do
      if (sink.MarginAt(i) < 0) or (sink.MarginAt(i) > 1.0000001) then
      begin
        Check(False, '余裕が 0..1 に収まる');
        Exit;
      end;
    Check(True, '余裕が 0..1 に収まる');
  finally
    sink.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 同じインスタンスに流し直しても同じ結果 (X-06 Replay / Z-05)

  README 29 章で CW/RTTY について直したのと同じこと。PSK も RxInit が
  フィルタの遅延線を消さなければ、二度目が一度目と違う結果になる。
  -------------------------------------------------------------------------- }
procedure TestReplayDeterminism;
const
  MSG = 'CQ DE JA1ABC K';
var
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  sink: TPskSink;
  w: TDoubleArray;
  sigs: array[0..3] of string;
  k, i: Integer;
  allSame: Boolean;
begin
  WriteLn;
  WriteLn('--- 7. 同じインスタンスに流し直しても同じ結果 ---');
  w := BuildWave(MSG, mmPSK63);
  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, mmPSK63);
  sink := TPskSink.Create;
  try
    rx.Frequency := 1000;
    rx.OnDecode := @sink.Decode;
    for k := 0 to 3 do
    begin
      sink.Reset;
      rx.RxInit;
      rx.RxProcess(w, Length(w));
      sigs[k] := '';
      for i := 0 to sink.Count - 1 do
        sigs[k] := sigs[k] + Format('%s@%.3f;',
          [sink.Text[i + 1], sink.MarginAt(i)]);
    end;
    Check(sigs[0] <> '', '前提: 一度目に復号できた');
    allSame := True;
    for k := 1 to 3 do
      if sigs[k] <> sigs[0] then allSame := False;
    if not allSame then
      for k := 0 to 3 do
        WriteLn(Format('        %d 回目: %s', [k + 1, Copy(sigs[k], 1, 60)]));
    Check(allSame,
      '**4 回流しても文字も余裕も毎回同じ** (前の音が残らない)');
  finally
    sink.Free; rx.Free; rxs.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 復調が確保しないこと (X-04)
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

procedure TestNoAllocation;
var
  rxs: TCaptureSoundDevice;
  rx: TPskModem;
  buf: array of Double;
  i, n: Integer;
  mm: TMemoryManager;
begin
  WriteLn;
  WriteLn('--- 8. 復調が確保しないこと (X-04) ---');
  rxs := TCaptureSoundDevice.Create;
  rx := TPskModem.Create(rxs, mmPSK31);
  try
    rx.Frequency := 1000;
    { OnDecode は繋がない。純音を流すので位相反転が起きず、DCD が
      立たないため文字も出ない。ここで見たいのは **復調そのもの**が
      確保しないことである。

      文字が出る瞬間は Evidence の候補配列を作るので確保が 1 回入る。
      これは意図した設計で、test_realtime の RTTY 受信の試験も同じ
      立場を取っている (PSK31 は毎秒 3 文字程度で、音声ブロックの
      16 回/秒と比べて支配的でない)。 }
    SetLength(buf, 512);
    for i := 0 to High(buf) do
      buf[i] := 0.5 * Sin(2 * Pi * 1000 * i / RATE);
    rx.RxProcess(buf, Length(buf));

    GAllocCount := 0;
    GetMemoryManager(GOldMM);
    mm := GOldMM;
    mm.GetMem := @CountingGetMem;
    mm.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(mm);
    GCounting := True;
    try
      for i := 1 to 100 do
        rx.RxProcess(buf, Length(buf));
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0, Format('51200 サンプルの復調で確保 0 回 (実測 %d)', [n]));
  finally
    rx.Free; rxs.Free;
  end;
end;

begin
  WriteLn('=== BPSK (PSK31/63/125) モデムの試験 ===');
  { Z-05 再現性: 種を固定する。 }
  RandSeed := 20260901;

  TestParameters;
  TestRoundTripClean;
  TestAllPrintable;
  TestNoise;
  TestSoftMarginSeparates;
  TestEvidenceShape;
  TestReplayDeterminism;
  TestNoAllocation;

  if FailCount = 0 then
  begin
    CoverReq('MDM-003');
    CoverReq('MDM-004');
  end;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
