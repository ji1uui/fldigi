{ ============================================================================
  test_portfolio.lpr

  Phase 2 の **完了条件**を試験で固定する。

      「Phase 2 Decoder は Phase 3 の Normal 戦略として再利用可能であること」
      (Baseline v1.1 §12 Phase 2 完了条件)

  なぜ 4 つ目のモードより先なのか
  ----------------------------------------------------------------------------
  ADR-002 が同じことを Phase 0 で言っている ――「復調器を増やしてから型を
  変えると全モデムの書き換えになるため、Phase 0 のうちに確定させる」。
  戦略として使うための契約も同じで、**復調器が 3 つのうちに固めておく**。
  Olivia や MFSK を足してから直せば 4 つ 5 つを書き換えることになる。

  「戦略として再利用可能」を何に分解したか
  ----------------------------------------------------------------------------
      a. 同じ音から同じ結果が出る            戦略を比べるには再現性が要る
      b. 完全にリセットして流し直せる        同じ音を別の設定で再走査する
      c. 区画の切り方を変えても結果が同じ    配る側が区画長を決められる
      d. 同じ音を複数の器が同時に見られる    Algorithm Portfolio の前提
      e. 結果が出所を名乗る                  どの戦略の答えかを識別する
      f. 結果が時間軸上の位置を名乗る        戦略どうしの答えを並べる

  f が今回いちばん問題だった。詳しくは試験 7 を参照。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_portfolio;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  SoundIntf, ModemTypes, Modem, ModemEngine, DecodeEvidence, ErrorRate,
  CwModemImpl, RttyModemImpl, PskModemImpl, TestSupport, Requirements;

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

const
  RATE = 8000;
  MSG = 'CQ DE JA1ABC K';
  { 前後の無音。CW は立ち上がりの整定に要る (MDM-002)。 }
  LEAD = RATE;

type
  TMakeModem = function(ASound: TCustomSoundDevice): TCustomModem;

  { 復号結果と、その素性をすべて控える。 }
  TSink = class
  private
    FText: string;
    FNames: string;
    FPos: array of Int64;
    FSig: QWord;
    FMissingName: Integer;
    FMissingPos: Integer;
    FBlockStart: Int64;
    FNotBlockStart: Integer;
    procedure Absorb(AValue: QWord);
  public
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
    property Text: string read FText;
    property Names: string read FNames;
    function Count: Integer;
    function Pos_(AIndex: Integer): Int64;
    property MissingName: Integer read FMissingName;
    property MissingPos: Integer read FMissingPos;
    { 試験が区画を配っているので、**いま何番目の区画を流しているか**を
      試験は知っている。復調器の外から持ってきたこの基準と突き合わせる
      ことでしか、「区画の先頭」と「区画の末尾」は見分けられない。
      どちらも 512 の倍数で、単調で、範囲内だからである。 }
    property BlockStart: Int64 read FBlockStart write FBlockStart;
    { 区画の先頭を名乗らなかった結果の数。 }
    property NotBlockStart: Integer read FNotBlockStart;
    { 結果の流れ全体の署名 (文字・位置・尺度)。
      **文字だけを比べると鈍い。** フィルタの遅延線が残っていても、
      文字は同じまま軟判定の尺度だけがずれることがある。 }
    function Signature: string;
  end;

{$push}{$Q-}{$R-}
procedure TSink.Absorb(AValue: QWord);
begin
  { FNV-1a。桁あふれは意図どおり。 }
  if FSig = 0 then FSig := (QWord($CBF29CE4) shl 32) or QWord($84222325);
  FSig := (FSig xor AValue) * ((QWord($00000100) shl 32) or QWord($000001B3));
end;
{$pop}

function TSink.Signature: string;
begin
  Result := IntToHex(FSig, 16);
end;

procedure TSink.Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
var
  n: Integer;
  m: Double;
begin
  if AEvidence.BestChar > 0 then
    FText := FText + Chr(AEvidence.BestChar);
  if AEvidence.DecoderName = '' then
    Inc(FMissingName)
  else if System.Pos('[' + AEvidence.DecoderName + ']', FNames) = 0 then
    FNames := FNames + '[' + AEvidence.DecoderName + ']';
  if AEvidence.SamplePos < 0 then Inc(FMissingPos);
  if AEvidence.SamplePos <> FBlockStart then Inc(FNotBlockStart);
  n := Length(FPos);
  SetLength(FPos, n + 1);
  FPos[n] := AEvidence.SamplePos;

  Absorb(QWord(AEvidence.BestChar));
  Absorb(QWord(AEvidence.SamplePos));
  m := AEvidence.BestMetric;
  Absorb(PQWord(@m)^);
end;

function TSink.Count: Integer;
begin
  Result := Length(FPos);
end;

function TSink.Pos_(AIndex: Integer): Int64;
begin
  Result := FPos[AIndex];
end;

{ --- 復調器の作り方。test_regression と同じ設定にしてある --- }
function MakeCw(ASound: TCustomSoundDevice): TCustomModem;
var m: TCwModem;
begin
  m := TCwModem.Create(ASound);
  m.Frequency := 700;
  m.SetCwSpeed(20);
  m.CwTrack := False;
  Result := m;
end;

function MakeRtty(ASound: TCustomSoundDevice): TCustomModem;
var m: TRttyModem;
begin
  m := TRttyModem.Create(ASound);
  m.Frequency := 1000;
  m.AfcOn := True;
  Result := m;
end;

function MakePsk(ASound: TCustomSoundDevice): TCustomModem;
begin
  Result := TPskModem.Create(ASound, mmPSK31);
  Result.Frequency := 1000;
end;

{ 送信して波形を得る。前後に無音を付ける。 }
function Transmit(AMake: TMakeModem; const AMsg: string;
  ALead: Integer = LEAD): TDoubleArray;
var
  snd: TCaptureSoundDevice;
  m: TCustomModem;
  src: TTxSource;
  raw: TDoubleArray;
  guard, r, i: Integer;
begin
  snd := TCaptureSoundDevice.Create;
  m := AMake(snd);
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

{ 区画に分けて 1 つの器に流す。ABlk <= 0 なら一括。 }
function Receive(AMake: TMakeModem; const AW: TDoubleArray; ABlk: Integer;
  ASink: TSink = nil; AStartPos: Int64 = 0): string;
var
  snd: TCaptureSoundDevice;
  m: TCustomModem;
  s: TSink;
  own: Boolean;
  b: TDoubleArray;
  i, n: Integer;
begin
  own := ASink = nil;
  if own then s := TSink.Create else s := ASink;
  snd := TCaptureSoundDevice.Create;
  m := AMake(snd);
  try
    m.RxInit;
    m.StreamPosition := AStartPos;
    m.OnDecode := @s.Decode;
    if ABlk <= 0 then
      m.RxProcess(AW, Length(AW))
    else
    begin
      SetLength(b, ABlk);
      i := 0;
      while i < Length(AW) do
      begin
        n := ABlk;
        if i + n > Length(AW) then n := Length(AW) - i;
        Move(AW[i], b[0], n * SizeOf(Double));
        s.BlockStart := AStartPos + i;   { この区画の先頭 }
        m.RxProcess(b, n);
        Inc(i, n);
      end;
    end;
    Result := s.Text;
  finally
    m.Free; snd.Free;
    if own then s.Free;
  end;
end;

{ 2 つの器に **同じ区画** を配る。Algorithm Portfolio の最小形。 }
procedure ReceiveBoth(AMake1, AMake2: TMakeModem; const AW: TDoubleArray;
  ABlk: Integer; ASink1, ASink2: TSink);
var
  d1, d2: TCaptureSoundDevice;
  m1, m2: TCustomModem;
  b: TDoubleArray;
  i, n: Integer;
begin
  d1 := TCaptureSoundDevice.Create;
  d2 := TCaptureSoundDevice.Create;
  m1 := AMake1(d1);
  m2 := AMake2(d2);
  try
    m1.RxInit; m1.OnDecode := @ASink1.Decode;
    m2.RxInit; m2.OnDecode := @ASink2.Decode;
    SetLength(b, ABlk);
    i := 0;
    while i < Length(AW) do
    begin
      n := ABlk;
      if i + n > Length(AW) then n := Length(AW) - i;
      Move(AW[i], b[0], n * SizeOf(Double));
      ASink1.BlockStart := i;
      ASink2.BlockStart := i;
      m1.RxProcess(b, n);
      m2.RxProcess(b, n);
      Inc(i, n);
    end;
  finally
    m1.Free; m2.Free; d1.Free; d2.Free;
  end;
end;

var
  GMake: array[0..2] of TMakeModem;
  GName: array[0..2] of string;
  GWave: array[0..2] of TDoubleArray;

{ --------------------------------------------------------------------------
  1. 前提: 3 つの復調器がそれぞれ自分の音を復号できる
  -------------------------------------------------------------------------- }
procedure TestBaseline;
var
  i: Integer;
  txt: string;
begin
  WriteLn;
  WriteLn('--- 1. 前提: それぞれ自分の音を復号できる ---');
  for i := 0 to 2 do
  begin
    GWave[i] := Transmit(GMake[i], MSG);
    txt := Trim(Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE));
    WriteLn(Format('        %-6s 波形 %d サンプル -> "%s"',
      [GName[i], Length(GWave[i]), txt]));
    CheckEqS(txt, MSG, Format('%s が基準文を復号できる', [GName[i]]));
  end;
end;

{ --------------------------------------------------------------------------
  2. 同じ音から同じ結果 (a) / 3. 完全にリセットできる (b)

  戦略を比べるには、同じ入力に同じ答えが返ることが前提になる。
  返らなければ、差が戦略の差なのか偶然なのか分からない。
  -------------------------------------------------------------------------- }
procedure TestDeterminismAndReset;
var
  i: Integer;
  a, b: string;
  bare: TDoubleArray;
  snd: TCaptureSoundDevice;
  m: TCustomModem;
  s1, s2: TSink;
begin
  WriteLn;
  WriteLn('--- 2. 同じ音から同じ結果 (別の器) ---');
  for i := 0 to 2 do
  begin
    s1 := TSink.Create;
    s2 := TSink.Create;
    try
      Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE, s1);
      Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE, s2);
      CheckEqS(s2.Signature, s1.Signature,
        Format('%s: 新しい器 2 つが同じ答えを返す (署名で比較)', [GName[i]]));
    finally
      s1.Free; s2.Free;
    end;
  end;

  WriteLn;
  WriteLn('--- 3. 同じ器を RxInit で流し直しても同じ結果 ---');
  { **前後の無音を外して測る。**
    無音を 1 秒付けたままだと、前の音の残りがフィルタの遅延線から抜けきって
    しまい、リセット漏れを隠す。実際、PSK の FFir1.Reset を消す改竄が
    無音つきでは 1 件も落ちなかった。信号がいきなり始まる波形なら残る。

    さらに **文字ではなく署名で比べる**。文字は同じまま軟判定の尺度だけが
    ずれることがあり、文字だけの比較では気づけない。 }
  for i := 0 to 2 do
  begin
    bare := Transmit(GMake[i], MSG, 0);
    snd := TCaptureSoundDevice.Create;
    m := GMake[i](snd);
    s1 := TSink.Create;
    s2 := TSink.Create;
    try
      { **Restart で流し直す。** RxInit は復調器の状態だけを戻し、
        AFC が動かした周波数は戻さない —— fldigi の rx_init() と同じ分担で、
        運用中は相手の周波数を憶えていてほしいからである。
        戦略を同じ音に当て直すときに要るのは「最初の状態に戻す」ほうなので
        Restart を使う。ここを RxInit にすると、AFC を入れた RTTY で
        1 回目と 2 回目の軟判定の尺度がずれる (実測で確認)。

        StreamPosition は **音声側の座標**なので、戻すのは使う側の仕事である
        (AudioReplay も RxInit のあとに入れている)。復調器が勝手に 0 に
        戻すと、途中から流す Replay の座標を壊す。ここでも同じ順序で置く。 }
      m.RxInit; m.StreamPosition := 0; m.OnDecode := @s1.Decode;
      m.RxProcess(bare, Length(bare));
      m.Restart; m.StreamPosition := 0; m.OnDecode := @s2.Decode;
      m.RxProcess(bare, Length(bare));
      WriteLn(Format('        %-6s 無音なし %d サンプル / 署名 %s (%d 件)',
        [GName[i], Length(bare), s1.Signature, s1.Count]));
      Check(s1.Count > 0, Format('前提: %s が無音なしでも結果を出す', [GName[i]]));
      CheckEqS(s2.Signature, s1.Signature,
        Format('**%s: Restart が状態を残さない** (遅延線・状態機械・周波数)',
          [GName[i]]));
    finally
      s1.Free; s2.Free; m.Free; snd.Free;
    end;
  end;
end;

{ --------------------------------------------------------------------------
  4. 区画の切り方を変えても結果が同じ (c)

  戦略を配る側が区画長を決められるようにするには、復調器が区画境界に
  依存していてはならない。**依存していないことは自明ではない** ――
  内部にフィルタの遅延線や状態機械を持っているので、区画で切れる位置が
  変われば結果が変わりうる。だから測る。
  -------------------------------------------------------------------------- }
procedure TestBlockSizeInvariance;
const
  BLKS: array[0..4] of Integer = (MODEM_BLOCK_SIZE, 256, 1024, 4096, 0);
var
  i, k: Integer;
  base, a: string;
  same: Boolean;
begin
  WriteLn;
  WriteLn('--- 4. 区画長を変えても同じ結果 ---');
  for i := 0 to 2 do
  begin
    base := Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE);
    same := True;
    Write('        ', GName[i], ': ');
    for k := 0 to High(BLKS) do
    begin
      a := Receive(GMake[i], GWave[i], BLKS[k]);
      if BLKS[k] = 0 then Write('一括:') else Write(BLKS[k], ':');
      Write(a = base, ' ');
      if a <> base then same := False;
    end;
    WriteLn;
    Check(same, Format('**%s は区画境界に依存しない** (配る側が区画長を決められる)',
      [GName[i]]));
  end;
end;

{ --------------------------------------------------------------------------
  5. 同じ音を複数の器が同時に見られる (d)

  Algorithm Portfolio は「複数戦略が同じ音を見る」。同じ区画を 2 つの器に
  配って、単独で流したときと同じ答えになることを見る。
  片方が他方の状態に触っていれば、ここで崩れる。
  -------------------------------------------------------------------------- }
procedure TestConcurrentSameKind;
var
  i: Integer;
  solo: string;
  s1, s2: TSink;
begin
  WriteLn;
  WriteLn('--- 5. 同種 2 器に同じ音を配る ---');
  for i := 0 to 2 do
  begin
    solo := Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE);
    s1 := TSink.Create;
    s2 := TSink.Create;
    try
      ReceiveBoth(GMake[i], GMake[i], GWave[i], MODEM_BLOCK_SIZE, s1, s2);
      CheckEqS(s1.Text, solo,
        Format('%s: 並行させても単独と同じ答え (器1)', [GName[i]]));
      CheckEqS(s2.Signature, s1.Signature,
        Format('%s: 2 つの器が互いに同じ答え (署名まで一致 = 状態を共有していない)',
          [GName[i]]));
    finally
      s1.Free; s2.Free;
    end;
  end;
end;

{ --------------------------------------------------------------------------
  6. 異種 2 器を同じ音で走らせ、Evidence で選べること (d, e)

  Algorithm Portfolio の最小形。同じ音に合う戦略と合わない戦略を当て、
  **結果を見て選べる**ことを確かめる。選ぶ材料は
  「どちらが名乗っているか」ではなく **CER** である。
  -------------------------------------------------------------------------- }
procedure TestConcurrentDifferentKind;
var
  s1, s2: TSink;
  cerFit, cerUnfit: Double;
begin
  WriteLn;
  WriteLn('--- 6. 異種 2 器を同じ音に当てる (Portfolio の最小形) ---');
  s1 := TSink.Create;
  s2 := TSink.Create;
  try
    { PSK の音に PSK と CW を当てる。 }
    ReceiveBoth(@MakePsk, @MakeCw, GWave[2], MODEM_BLOCK_SIZE, s1, s2);
    cerFit := MessageCharErrorRate(MSG, Trim(s1.Text));
    cerUnfit := MessageCharErrorRate(MSG, Trim(s2.Text));
    WriteLn(Format('        合う戦略  %-8s "%s" CER %.3f',
      [s1.Names, Trim(s1.Text), cerFit]));
    WriteLn(Format('        合わない  %-8s "%s" CER %.3f',
      [s2.Names, Trim(s2.Text), cerUnfit]));

    Check(s1.Count > 0, '合う戦略は結果を出す');
    CheckEqS(s1.Names, '[PSK31]', '合う戦略が自分の名を名乗る');
    Check(s2.Names <> s1.Names, '**2 つの戦略の名が区別できる**');
    Check(cerFit < 0.05, '合う戦略の CER が低い');
    Check(cerUnfit > cerFit + 0.5,
      Format('**CER で戦略を選べる** (%.3f 対 %.3f)', [cerFit, cerUnfit]));
    Check(s2.Count >= 0, '合わない戦略も落ちずに走り切る (fail-soft)');
  finally
    s1.Free; s2.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. 結果が時間軸上の位置を名乗ること (f)

  ここが今回いちばん問題だった。

  `AdvanceStreamPos(ALen)` を RxProcess の **先頭** で呼んでいたため、
  区画の処理中 FStreamPos は既に区画の末尾を指していた。その結果、
  その区画で確定した文字がすべて「区画の末尾」を名乗る。末尾はその文字を
  生んだ音より後ろなので、そこから流し直しても同じ文字は出てこない ――
  Replay Decode (X-06) にも障害再現にも使えない位置である。
  しかも波形を 1 回で流すと **全文字が同じ値 (波形長)** を名乗っていた。

  どの試験もこれを捕まえていなかった。test_replay は範囲
  (区間の先頭以上・末尾以内) しか見ておらず、先頭でも末尾でも通る。

  契約を「確定した区画の先頭」と定め、ここで固定する。
  -------------------------------------------------------------------------- }
procedure TestPositionContract;
var
  i, k: Integer;
  s: TSink;
  aligned, increasing, inRange: Boolean;
  sA, sB: TSink;
  samePos: Boolean;
begin
  WriteLn;
  WriteLn('--- 7. 位置の契約 (確定した区画の先頭) ---');
  for i := 0 to 2 do
  begin
    s := TSink.Create;
    try
      Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE, s);
      Check(s.Count > 0, Format('前提: %s が結果を出した (%d 件)',
        [GName[i], s.Count]));
      CheckEqI(s.MissingPos, 0, Format('%s: 位置が未設定 (-1) の結果が無い',
        [GName[i]]));

      aligned := True; increasing := True; inRange := True;
      for k := 0 to s.Count - 1 do
      begin
        if (s.Pos_(k) mod MODEM_BLOCK_SIZE) <> 0 then aligned := False;
        if (k > 0) and (s.Pos_(k) < s.Pos_(k - 1)) then increasing := False;
        if (s.Pos_(k) < 0) or (s.Pos_(k) >= Length(GWave[i])) then inRange := False;
      end;
      WriteLn(Format('        %-6s 位置 %d..%d (波形長 %d)',
        [GName[i], s.Pos_(0), s.Pos_(s.Count - 1), Length(GWave[i])]));
      Check(aligned,
        Format('**%s: 位置が区画の先頭に揃う** (%d の倍数)',
          [GName[i], MODEM_BLOCK_SIZE]));
      Check(increasing, Format('%s: 位置が単調非減少 (時間順)', [GName[i]]));
      Check(inRange, Format('%s: 位置が波形の範囲内', [GName[i]]));

      { 末尾ではなく先頭であること。末尾なら最初の結果は
        「最初の音より 1 区画ぶん後ろ」を指す。信号は LEAD から始まるので、
        先頭ならば最初の結果は LEAD より前を指しえない。 }
      Check(s.Pos_(0) >= 0,
        Format('%s: 最初の位置が 0 以上', [GName[i]]));
    finally
      s.Free;
    end;
  end;

  { --- ここが要点 ---
    上の「512 の倍数・単調・範囲内」は、**先頭でも末尾でも成り立つ**。
    実際、位置を進める場所を戻して末尾を名乗らせても、上の主張は
    1 件も落ちなかった (値が一律 512 ずれるだけ)。§38 の
    ColumnFrequency と同じ形の穴である。

    見分けるには復調器の外に基準が要る。区画を配っているのは試験なので、
    **いま何番目の区画を流しているか**を試験は知っている。
    区画 k を流している最中に確定した結果は、区画 k の先頭を名乗るはず。
    末尾を名乗る実装なら、これは区画 k+1 の先頭になって食い違う。 }
  WriteLn;
  WriteLn('--- 7b. 区画の先頭か末尾かを見分ける ---');
  for i := 0 to 2 do
  begin
    s := TSink.Create;
    try
      Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE, s);
      Check(s.Count > 0, Format('前提: %s が結果を出した', [GName[i]]));
      CheckEqI(s.NotBlockStart, 0,
        Format('**%s: すべての結果が「いま流している区画の先頭」を名乗る**',
          [GName[i]]));
    finally
      s.Free;
    end;
  end;

  { 起点を入れたときも同じ規則が保たれること (Replay の座標)。 }
  s := TSink.Create;
  try
    Receive(GMake[1], GWave[1], MODEM_BLOCK_SIZE, s, 100000);
    Check(s.Count > 0, '前提: 起点を入れても結果が出る');
    Check(s.Pos_(0) >= 100000, '起点から数え直す (0 起点に戻らない)');
    CheckEqI(s.NotBlockStart, 0,
      '**起点を入れても区画の先頭を名乗る** (Replay の座標が保たれる)');
    WriteLn(Format('        起点 100000 -> 最初の位置 %d (差 %d = %d 区画)',
      [s.Pos_(0), s.Pos_(0) - 100000,
       (s.Pos_(0) - 100000) div MODEM_BLOCK_SIZE]));
  finally
    s.Free;
  end;

  { 2 つの戦略に同じ区画を配ったとき、位置がぴったり並ぶこと。
    これが無いと Phase 3 で戦略どうしの答えを時間軸で突き合わせられない。 }
  WriteLn;
  WriteLn('--- 7c. 戦略どうしの位置が並ぶこと ---');
  sA := TSink.Create;
  sB := TSink.Create;
  try
    ReceiveBoth(GMake[2], GMake[2], GWave[2], MODEM_BLOCK_SIZE, sA, sB);
    samePos := sA.Count = sB.Count;
    if samePos then
      for k := 0 to sA.Count - 1 do
        if sA.Pos_(k) <> sB.Pos_(k) then samePos := False;
    Check(sA.Count > 0, '前提: 並行して結果が出た');
    Check(samePos,
      '**同じ区画を配れば戦略どうしの位置がぴったり一致する** (突き合わせられる)');
  finally
    sA.Free; sB.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. すべての結果が出所を名乗ること (e)
  -------------------------------------------------------------------------- }
procedure TestDecoderNames;
var
  i: Integer;
  s: TSink;
  seen: string;
begin
  WriteLn;
  WriteLn('--- 8. 出所の名乗り ---');
  seen := '';
  for i := 0 to 2 do
  begin
    s := TSink.Create;
    try
      Receive(GMake[i], GWave[i], MODEM_BLOCK_SIZE, s);
      Check(s.Count > 0, Format('前提: %s が結果を出した', [GName[i]]));
      CheckEqI(s.MissingName, 0,
        Format('**%s: 名無しの結果が 1 件も無い**', [GName[i]]));
      WriteLn(Format('        %-6s 名乗り %s', [GName[i], s.Names]));
      Check(System.Pos(s.Names, seen) = 0,
        Format('%s の名が他のモデムと重ならない', [GName[i]]));
      seen := seen + s.Names;
    finally
      s.Free;
    end;
  end;
end;

begin
  WriteLn('=== Phase 2 完了条件: 復調器を Phase 3 の戦略として再利用できるか ===');

  GMake[0] := @MakeCw;   GName[0] := 'CW';
  GMake[1] := @MakeRtty; GName[1] := 'RTTY';
  GMake[2] := @MakePsk;  GName[2] := 'PSK31';

  TestBaseline;
  TestDeterminismAndReset;
  TestBlockSizeInvariance;
  TestConcurrentSameKind;
  TestConcurrentDifferentKind;
  TestPositionContract;
  TestDecoderNames;

  if FailCount = 0 then
    CoverReq('MDM-008');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
