{ ============================================================================
  test_replay.lpr

  AudioReplay (X-06 Replay Decode) の試験。

  何を守るか
  ----------------------------------------------------------------------------
  履歴を持っているだけでは Replay とは言えない。要求 RT-005 が求めるのは
  **保持した音をもう一度復号できること**である。ここで確かめるのは

  1. 履歴から流し直すと、生で受けたときと同じ文字列が得られる
  2. Evidence の位置が **元の音声の座標**になっている (0 から数え直さない)
  3. 同じ区間を同じ設定で流せば同じ結果になる (Z-05 再現性)
  4. 区間が無いときは **正直に断る** (継ぎはぎの波形を復号しない)
  5. 中断できる / 呼び出し側の handler を壊さない / 同時に走らせられる

  4 が要点である。履歴は輪なので古い区間は上書きされる。上書きされた
  区間を「読めた」ことにすると、前半が古く後半が新しい継ぎはぎの波形を
  復号することになる。それは嘘の録音であって、間違った復号より質が悪い。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_replay;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils,
  SoundIntf, ModemTypes, Modem, ModemEngine, CwModemImpl, DecodeEvidence,
  AudioRing, AudioReplay, TestSupport, Requirements;

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
    WriteLn('        期待: [', AExpected, ']  実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

type
  { 文字と、その文字が出た入力位置を並べて覚える。
    位置まで覚えるのは、Replay が元の音声の座標を載せているかを
    確かめるためである。 }
  TPosSink = class
  private
    FText: string;
    FPos: array of Int64;
  public
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
    procedure Reset;
    function Count: Integer;
    function PosAt(AIndex: Integer): Int64;
    function MinPos: Int64;
    { 空白以外の最初の文字の位置。CW の状態機械は語間の空白を
      時間経過だけで出すので、空白の位置は音の位置を表さない。 }
    function FirstRealPos: Int64;
    function MaxPos: Int64;
    { 文字と位置を並べた 1 本の文字列。再現性の比較に使う。 }
    function Signature: string;
    property Text: string read FText;
  end;

procedure TPosSink.Decode(Sender: TCustomModem;
  const AEvidence: TDecodeEvidence);
begin
  if AEvidence.BestChar > 0 then
  begin
    FText := FText + Chr(AEvidence.BestChar);
    SetLength(FPos, Length(FPos) + 1);
    FPos[High(FPos)] := AEvidence.SamplePos;
  end;
end;

procedure TPosSink.Reset;
begin
  FText := '';
  SetLength(FPos, 0);
end;

function TPosSink.Count: Integer;
begin
  Result := Length(FPos);
end;

function TPosSink.PosAt(AIndex: Integer): Int64;
begin
  Result := FPos[AIndex];
end;

function TPosSink.MinPos: Int64;
var
  i: Integer;
begin
  if Length(FPos) = 0 then Exit(-1);
  Result := FPos[0];
  for i := 1 to High(FPos) do
    if FPos[i] < Result then Result := FPos[i];
end;

function TPosSink.FirstRealPos: Int64;
var
  i: Integer;
begin
  for i := 0 to High(FPos) do
    if FText[i + 1] <> ' ' then
      Exit(FPos[i]);
  Result := -1;
end;

function TPosSink.MaxPos: Int64;
var
  i: Integer;
begin
  if Length(FPos) = 0 then Exit(-1);
  Result := FPos[0];
  for i := 1 to High(FPos) do
    if FPos[i] > Result then Result := FPos[i];
end;

function TPosSink.Signature: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FPos) do
    Result := Result + Format('%s@%d;', [Chr(Ord(FText[i + 1])), FPos[i]]);
end;

{ --------------------------------------------------------------------------
  共通の材料
  -------------------------------------------------------------------------- }
const
  MSG = 'CQ DE JA1ABC K';
  WPM = 12;
  NOISE = 0.001;
  RATE = 8000;

var
  GWave: TDoubleArray;       { CW の送信波形 (雑音なし) }
  GLeadSamples: Integer;     { 履歴の先頭に置いた無音の長さ }

{ MSG を WPM で送った波形を作る。 }
procedure BuildWave;
var
  txs: TCaptureSoundDevice;
  tx: TCwModem;
  src: TTxSource;
  guard, r: Integer;
begin
  txs := TCaptureSoundDevice.Create;
  tx := TCwModem.Create(txs);
  src := TTxSource.Create(MSG);
  try
    tx.Frequency := 700;
    tx.SetCwSpeed(WPM);
    tx.OnGetTxChar := @src.GetTxChar;
    tx.TxInit;
    guard := 0;
    repeat
      r := tx.TxProcess;
      Inc(guard);
    until (r < 0) or (guard > 200000);
    GWave := txs.GetCapturedCopy;
  finally
    src.Free; tx.Free; txs.Free;
  end;
end;

{ 履歴を作り、[無音 ALeadSec][信号][無音 ATrailSec] を書き込む。
  戻り値は履歴。GLeadSamples に無音の長さを入れる。 }
function BuildHistory(ASeconds: Double; ALeadSec, ATrailSec: Double;
  ANoise: Double): TAudioHistory;
var
  h: TAudioHistory;
  sil, sig: array of Double;
  i: Integer;
begin
  h := TAudioHistory.ForSeconds(ASeconds, RATE);

  GLeadSamples := Round(RATE * ALeadSec);
  SetLength(sil, GLeadSamples);
  for i := 0 to High(sil) do sil[i] := ANoise * (Random - 0.5);
  h.Append(sil, Length(sil));

  SetLength(sig, Length(GWave));
  for i := 0 to High(sig) do sig[i] := GWave[i] + ANoise * (Random - 0.5);
  h.Append(sig, Length(sig));

  SetLength(sil, Round(RATE * ATrailSec));
  for i := 0 to High(sil) do sil[i] := ANoise * (Random - 0.5);
  h.Append(sil, Length(sil));

  Result := h;
end;

function NewRxModem(ASink: TPosSink; out ASound: TCaptureSoundDevice): TCwModem;
begin
  ASound := TCaptureSoundDevice.Create;
  Result := TCwModem.Create(ASound);
  Result.Frequency := 700;
  Result.SetCwSpeed(WPM);
  Result.CwTrack := False;
  Result.OnDecode := @ASink.Decode;
end;

{ --------------------------------------------------------------------------
  1. 区画の長さが生の受信と揃っていること

  復調器は渡された長さの単位で内部状態を進める。生の受信と違う長さで
  流すと、同じ音でも結果が変わりうる。定数が別のユニットにあるので、
  片方だけ変えられたことに気づけるようにここで縛る。
  -------------------------------------------------------------------------- }
procedure TestChunkMatchesEngine;
begin
  WriteLn;
  WriteLn('--- 1. 区画長が生の受信と揃っていること ---');
  CheckEqI(REPLAY_CHUNK_SAMPLES, MODEM_BLOCK_SIZE,
    '**REPLAY_CHUNK_SAMPLES = MODEM_BLOCK_SIZE** (片方だけ変えられない)');
end;

{ --------------------------------------------------------------------------
  2. 流し直すと同じ文字列が得られること (端から端まで)
  -------------------------------------------------------------------------- }
procedure TestRoundTrip;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 2. 履歴から流し直すと同じ文字列になる ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    h.LiveRange(first, last);
    res := rp.Run(h, rx, first, last - first);
    WriteLn('        ', res.Describe);
    Check(res.Ok, '全区間を流し終えた');
    CheckEqI(res.SamplesFed, last - first, '求めた長さをすべて流した');
    CheckEqS(Trim(sink.Text), MSG, '**流し直した音から同じ文字列が出る**');
    Check(res.Evidences >= Length(MSG),
      Format('Evidence を数えている (%d 件)', [res.Evidences]));
  finally
    rx.Free; snd.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  3. Evidence の位置が元の音声の座標であること

  ここが崩れると、聞き直した結果を元の音声に対応づけられない。
  履歴の途中から流すので、位置が 0 起点なら先頭が 0 付近に出る。
  -------------------------------------------------------------------------- }
procedure TestPositionsAreAbsolute;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
  from_, count_: Int64;
begin
  WriteLn;
  WriteLn('--- 3. Evidence の位置が元の音声の座標であること ---');
  { 先頭に 3 秒の無音を置く。信号はそのあと。 }
  h := BuildHistory(30, 3.0, 0.5, NOISE);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    { 無音の途中から末尾まで。先頭は 2 秒目とする。 }
    from_ := 2 * RATE;
    count_ := h.TotalWritten - from_;
    res := rp.Run(h, rx, from_, count_);
    Check(res.Ok, '流し終えた');
    Check(sink.Count > 0, '文字が出た');
    WriteLn(Format('        位置の範囲 [%d, %d] / 要求区間 [%d, %d)',
      [sink.MinPos, sink.MaxPos, from_, from_ + count_]));
    WriteLn('        復号: [', sink.Text, ']  署名: ', sink.Signature);
    CheckEqS(Trim(sink.Text), MSG, '途中から流しても同じ文字列が出る');
    Check(sink.MinPos >= from_,
      '**最初の Evidence の位置が区間の先頭以上** (0 から数え直していない)');
    Check(sink.MaxPos <= from_ + count_,
      '最後の Evidence の位置が区間の末尾以内');
    { 信号は 3 秒目から始まるので、**空白以外の**最初の文字はそれ以降に
      出るはず。0 起点なら 1.5 秒付近に出てしまう。
      空白で見ないのは、CW の状態機械が語間の空白を時間経過だけで出す
      ためで、その位置は音の位置を表さないからである
      (実測で先頭の空白は 2.51 秒に出ていた)。 }
    WriteLn(Format('        空白以外の最初の位置 %d (信号開始 %d)',
      [sink.FirstRealPos, 3 * RATE]));
    Check(sink.FirstRealPos >= 3 * RATE,
      '最初の文字が信号の開始より後に出ている (座標がずれていない)');
    CheckEqI(rx.StreamPosition, from_ + count_,
      '流し終えた時点の位置が区間の末尾と一致する');
  finally
    rx.Free; snd.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4. 再現性 (Z-05)

  新しいインスタンスに同じ区間を流せば、文字も位置も完全に一致すること。
  一致しなければ、障害の再現も回帰試験も成り立たない。
  -------------------------------------------------------------------------- }
procedure TestDeterminism;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink1, sink2: TPosSink;
  first, last: Int64;
  sig1, sig2: string;
begin
  WriteLn;
  WriteLn('--- 4. 同じ区間を流せば同じ結果になる (Z-05) ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  sink1 := TPosSink.Create;
  sink2 := TPosSink.Create;
  rp := TAudioReplay.Create;
  try
    rx := NewRxModem(sink1, snd);
    try
      rp.Run(h, rx, first, last - first);
      sig1 := sink1.Signature;
    finally
      rx.Free; snd.Free;
    end;

    { 二度目は新しいインスタンス。使い回しは保証の対象外
      (AudioReplay.pas 冒頭の「再現性について」を参照)。 }
    rx := NewRxModem(sink2, snd);
    try
      rp.Run(h, rx, first, last - first);
      sig2 := sink2.Signature;
    finally
      rx.Free; snd.Free;
    end;

    Check(sig1 <> '', '前提: 一度目に文字が出た');
    CheckEqS(sig2, sig1,
      '**新しいインスタンスに二度流しても文字と位置が完全に一致する**');
  finally
    rp.Free; sink1.Free; sink2.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  4b. 同じインスタンスを使い回しても再現すること

  Run は流す前に RxInit を呼ぶ。呼ばなければ前の音がフィルタの遅延線と
  状態機械の時刻に残り、二度目以降が一度目と違う結果になる
  (実際にそうなっていた。AudioReplay.pas 冒頭「再現性について」参照)。

  使い回せることは Phase 3 で効く。複数の戦略を同じ音に当てるときに、
  戦略の数だけ復調器を作り直すのでは高くつく。
  -------------------------------------------------------------------------- }
procedure TestDeterminismOnReuse;
const
  N = 4;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  first, last: Int64;
  sigs: array[0..N-1] of string;
  k: Integer;
  allSame: Boolean;
begin
  WriteLn;
  WriteLn('--- 4b. 同じインスタンスを使い回しても再現すること ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    for k := 0 to N - 1 do
    begin
      sink.Reset;
      rp.Run(h, rx, first, last - first);
      sigs[k] := sink.Signature;
    end;
    Check(sigs[0] <> '', '前提: 一度目に文字が出た');
    allSame := True;
    for k := 1 to N - 1 do
      if sigs[k] <> sigs[0] then allSame := False;
    if not allSame then
    begin
      WriteLn('        1 回目: ', Copy(sigs[0], 1, 70));
      for k := 1 to N - 1 do
        if sigs[k] <> sigs[0] then
          WriteLn(Format('        %d 回目: %s', [k + 1, Copy(sigs[k], 1, 70)]));
    end;
    Check(allSame,
      Format('**同じインスタンスに %d 回流しても毎回同じ結果になる**', [N]));
  finally
    rx.Free; snd.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 区間が無いときは正直に断ること

  履歴は輪なので古い区間は上書きされる。読めなかったものを
  「読めた」ことにして継ぎはぎの波形を復号すると、嘘の録音になる。
  -------------------------------------------------------------------------- }
procedure TestMissingRange;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
  block: array of Double;
  i, k: Integer;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 5. 区間が無いときは正直に断ること ---');
  { 小さい履歴 (1 秒) を作り、3 秒ぶん書いて先頭を追い出す。 }
  h := TAudioHistory.ForSeconds(1.0, RATE);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    SetLength(block, 1000);
    for i := 0 to High(block) do block[i] := 0.1;
    for k := 1 to 24 do
      h.Append(block, Length(block));

    h.LiveRange(first, last);
    WriteLn(Format('        生存区間 [%d, %d) / 書込済 %d',
      [first, last, h.TotalWritten]));

    { (a) 上書きされた区間 }
    res := rp.Run(h, rx, 0, 4000);
    Check(res.Status = rpsOverwritten,
      '**上書きされた区間は rpsOverwritten** (継ぎはぎを復号しない)');
    CheckEqI(res.SamplesFed, 0, '断ったときは 1 サンプルも流していない');
    Check(res.Message <> '', '理由が書かれている');
    CheckEqI(sink.Count, 0, '断ったときは文字も出ていない');

    { (b) まだ録れていない区間 }
    res := rp.Run(h, rx, last, 4000);
    Check(res.Status = rpsNotWritten,
      '**まだ録れていない区間は rpsNotWritten** (上書きとは区別する)');
    CheckEqI(res.SamplesFed, 0, '断ったときは 1 サンプルも流していない');

    { (c) 引数が不正 }
    res := rp.Run(h, rx, first, 0);
    Check(res.Status = rpsBadRequest, '長さ 0 は rpsBadRequest');
    res := rp.Run(h, rx, -1, 100);
    Check(res.Status = rpsBadRequest, '負の開始位置は rpsBadRequest');
    res := rp.Run(nil, rx, first, 100);
    Check(res.Status = rpsBadRequest, '履歴が nil なら rpsBadRequest');
    res := rp.Run(h, nil, first, 100);
    Check(res.Status = rpsBadRequest, '復調器が nil なら rpsBadRequest');
  finally
    rx.Free; snd.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. 流している最中に追い越されたら気づくこと

  長い区間を流している間に書き手が回り込むことがある。まとめて読んで
  から流すのでは遅い。区画ごとに読み直しているかを、進捗の合間に
  書き込むことで確かめる。
  -------------------------------------------------------------------------- }
var
  GOvertakeHistory: TAudioHistory;
  GOvertakeBlock: array of Double;

type
  TOvertaker = class
    Fired: Boolean;
    function Progress(AFed, ATotal: Int64): Boolean;
  end;

function TOvertaker.Progress(AFed, ATotal: Int64): Boolean;
var
  k: Integer;
begin
  { 最初の区画を流した直後に、履歴を一周ぶん書き潰す。 }
  if not Fired then
  begin
    Fired := True;
    for k := 1 to 12 do
      GOvertakeHistory.Append(GOvertakeBlock, Length(GOvertakeBlock));
  end;
  Result := True;
end;

procedure TestOvertakenMidReplay;
var
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
  ov: TOvertaker;
  i, k: Integer;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 6. 流している最中に追い越されたら気づくこと ---');
  GOvertakeHistory := TAudioHistory.ForSeconds(1.0, RATE);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  ov := TOvertaker.Create;
  rx := NewRxModem(sink, snd);
  try
    SetLength(GOvertakeBlock, 1000);
    for i := 0 to High(GOvertakeBlock) do GOvertakeBlock[i] := 0.1;
    for k := 1 to 8 do
      GOvertakeHistory.Append(GOvertakeBlock, Length(GOvertakeBlock));

    GOvertakeHistory.LiveRange(first, last);
    rp.OnProgress := @ov.Progress;
    res := rp.Run(GOvertakeHistory, rx, first, last - first);
    WriteLn('        ', res.Describe);

    Check(ov.Fired, '前提: 途中で書き潰した');
    Check(res.Status = rpsOverwritten,
      '**追い越されたことに気づいて rpsOverwritten** (区画ごとに読み直している)');
    Check(res.SamplesFed > 0, '途中まで流していたことが結果に残る');
    Check(res.SamplesFed < last - first, '最後までは流していない');
  finally
    rx.Free; snd.Free; ov.Free; rp.Free; sink.Free;
    GOvertakeHistory.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 中断できること
  -------------------------------------------------------------------------- }
type
  TStopper = class
    Limit: Int64;
    Calls: Integer;
    function Progress(AFed, ATotal: Int64): Boolean;
  end;

function TStopper.Progress(AFed, ATotal: Int64): Boolean;
begin
  Inc(Calls);
  Result := AFed < Limit;
end;

procedure TestCancel;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
  st: TStopper;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 7. 中断できること ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  st := TStopper.Create;
  rx := NewRxModem(sink, snd);
  try
    st.Limit := (last - first) div 4;
    rp.OnProgress := @st.Progress;
    res := rp.Run(h, rx, first, last - first);
    WriteLn('        ', res.Describe);
    Check(res.Status = rpsCancelled, '**中断が結果に出る**');
    Check(res.SamplesFed >= st.Limit, '中断の直前まで流している');
    Check(res.SamplesFed < last - first, '最後までは流していない');
    Check(st.Calls > 1, '進捗が区画ごとに呼ばれている');
    Check(not rp.Busy, '中断しても Busy が残らない');
  finally
    rx.Free; snd.Free; st.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. 呼び出し側の handler を壊さないこと

  Evidence を数えるために handler を差し込んでいる。差し込んだまま
  返すと、呼び出し側の handler が消える。
  -------------------------------------------------------------------------- }
procedure TestHandlerPreserved;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  before: TDecodeEvent;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 8. 呼び出し側の handler を壊さないこと ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    before := rx.OnDecode;
    rp.Run(h, rx, first, last - first);
    Check(rx.OnDecode = before, '**流し終えたあと handler が元に戻っている**');
    Check(sink.Count > 0, '流している間は呼び出し側の handler も呼ばれた');

    { 断られたときも壊れないこと。 }
    rp.Run(h, rx, last, 4000);
    Check(rx.OnDecode = before, '断られたときも handler が元のまま');
  finally
    rx.Free; snd.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. RunLatest — 「さっきのをもう一度」

  履歴に無い長さを求められたら、あるだけを流す。断るのは答になっていない。
  -------------------------------------------------------------------------- }
procedure TestRunLatest;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 9. 直近 N 秒を流し直す ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    { 履歴にある長さより長く求める。 }
    res := rp.RunLatest(h, rx, 600.0);
    WriteLn('        ', res.Describe);
    Check(res.Ok, '履歴より長い秒数でも成功する');
    CheckEqI(res.SamplesFed, last - first, '**あるだけを流す** (断らない)');
    CheckEqS(Trim(sink.Text), MSG, '直近の全区間から同じ文字列が出る');

    sink.Reset;
    res := rp.RunLatest(h, rx, 0.0);
    Check(res.Status = rpsBadRequest, '0 秒は rpsBadRequest');
    res := rp.RunLatest(nil, rx, 1.0);
    Check(res.Status = rpsBadRequest, '履歴が nil なら rpsBadRequest');
  finally
    rx.Free; snd.Free; rp.Free; sink.Free; h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  10. 同じ履歴を同時に流し直せること

  Phase 3 の Algorithm Portfolio は、同じ区間を複数の戦略に同時に当てる。
  履歴の読み出しが読み手側の状態を変えないことを、実際に走らせて確かめる。
  -------------------------------------------------------------------------- }
type
  TReplayThread = class(TThread)
  private
    FHistory: TAudioHistory;
    FFrom, FCount: Int64;
    FSig: string;
    FOk: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AHistory: TAudioHistory; AFrom, ACount: Int64);
    property Sig: string read FSig;
    property Ok: Boolean read FOk;
  end;

constructor TReplayThread.Create(AHistory: TAudioHistory; AFrom, ACount: Int64);
begin
  FHistory := AHistory;
  FFrom := AFrom;
  FCount := ACount;
  FOk := False;
  inherited Create(False);
end;

procedure TReplayThread.Execute;
var
  rp: TAudioReplay;
  rx: TCwModem;
  snd: TCaptureSoundDevice;
  sink: TPosSink;
  res: TReplayResult;
begin
  sink := TPosSink.Create;
  rp := TAudioReplay.Create;
  rx := NewRxModem(sink, snd);
  try
    res := rp.Run(FHistory, rx, FFrom, FCount);
    FOk := res.Ok;
    FSig := sink.Signature;
  finally
    rx.Free; snd.Free; rp.Free; sink.Free;
  end;
end;

procedure TestConcurrentReplays;
const
  N = 4;
var
  h: TAudioHistory;
  th: array[0..N-1] of TReplayThread;
  i: Integer;
  first, last: Int64;
  allSame: Boolean;
begin
  WriteLn;
  WriteLn('--- 10. 同じ履歴を同時に流し直せること ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  try
    for i := 0 to N - 1 do
      th[i] := TReplayThread.Create(h, first, last - first);
    for i := 0 to N - 1 do
      th[i].WaitFor;

    allSame := True;
    for i := 0 to N - 1 do
    begin
      Check(th[i].Ok, Format('%d 本目が成功した', [i + 1]));
      if th[i].Sig <> th[0].Sig then allSame := False;
    end;
    Check(allSame, '**同時に走らせても全員が同じ結果を得る**');
    Check(Pos(MSG[1], th[0].Sig) > 0, '前提: 実際に復号している');

    for i := 0 to N - 1 do
      th[i].Free;
  finally
    h.Free;
  end;
end;

{ --------------------------------------------------------------------------
  11. 生の受信を壊さないこと

  流し直しは呼び出し側が用意した別のインスタンスに対して行う約束である。
  約束が守られていれば、生の復調器の状態は流し直しの前後で変わらない。
  -------------------------------------------------------------------------- }
procedure TestLiveModemUntouched;
var
  h: TAudioHistory;
  rp: TAudioReplay;
  live, replayRx: TCwModem;
  sndL, sndR: TCaptureSoundDevice;
  sinkL, sinkR: TPosSink;
  posBefore: Int64;
  textBefore: string;
  first, last: Int64;
begin
  WriteLn;
  WriteLn('--- 11. 生の受信を壊さないこと ---');
  h := BuildHistory(30, 1.0, 0.5, NOISE);
  h.LiveRange(first, last);
  sinkL := TPosSink.Create;
  sinkR := TPosSink.Create;
  rp := TAudioReplay.Create;
  live := NewRxModem(sinkL, sndL);
  replayRx := NewRxModem(sinkR, sndR);
  try
    { 生の側に半分だけ流して途中の状態にする。 }
    rp.Run(h, live, first, (last - first) div 2);
    posBefore := live.StreamPosition;
    textBefore := sinkL.Text;

    { 別インスタンスで聞き直す。 }
    rp.Run(h, replayRx, first, last - first);

    CheckEqI(live.StreamPosition, posBefore,
      '**聞き直しても生の側の位置は動かない**');
    CheckEqS(sinkL.Text, textBefore, '生の側の復号結果も増えていない');
    Check(sinkR.Count > 0, '聞き直した側では復号できている');
  finally
    live.Free; sndL.Free; replayRx.Free; sndR.Free;
    rp.Free; sinkL.Free; sinkR.Free; h.Free;
  end;
end;

begin
  WriteLn('=== Replay Decode (X-06) の試験 ===');
  { Z-05 再現性: 種を固定する。 }
  RandSeed := 20260831;

  BuildWave;
  WriteLn(Format('  送信波形 %d サンプル (%.2f 秒)',
    [Length(GWave), Length(GWave) / RATE]));

  TestChunkMatchesEngine;
  TestRoundTrip;
  TestPositionsAreAbsolute;
  TestDeterminism;
  TestDeterminismOnReuse;
  TestMissingRange;
  TestOvertakenMidReplay;
  TestCancel;
  TestHandlerPreserved;
  TestRunLatest;
  TestConcurrentReplays;
  TestLiveModemUntouched;

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
    CoverReq('RT-005');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
