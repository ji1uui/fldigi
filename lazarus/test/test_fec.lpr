{ ============================================================================
  test_fec.lpr

  MFSK 系の誤り訂正層 (units/ConvCodec.pas, units/Interleaver.pas) の試験。

  何を守るか
  ----------------------------------------------------------------------------
  1. 符号化器が **多項式の定義どおり** に動く (fldigi の定数から手で出した既知解)
  2. 誤りが無ければ完全に戻る
  3. 散った誤りを直せる
  4. **軟判定が硬判定より強い** (Phase 3 Soft Decision の根拠)
  5. 消失 (128) は「分からない」として扱われ、嘘の自信にならない
  6. インタリーバが往復で元に戻る
  7. **インタリーバが固まった誤りを散らす** (存在意義そのもの)
  8. **インタリーバ有りなら直る誤りが、無しでは直らない** (統合)
  9. 復号経路で確保しない (X-04) / 同じ入力から同じ出力 (Z-05)

  4 と 8 がこの単元の要点である。誤り訂正は「付けた」だけでは意味がなく、
  **付けなかった場合より良い**ことを示して初めて価値が言える。

  この層にはまだ実行時の利用者が居ない (MFSK モデムは次の段)。
  独立して既知解で確かめられる部品なので先に固めた ―― 復調器を書きながら
  同時に符号も疑うことになると、どちらが原因か切り分けられない。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_fec;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Math,
  ConvCodec, Interleaver, TestVectors, TestSupport, Requirements;

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
  TByteArray = array of Byte;

{ --- 道具 --------------------------------------------------------------- }

{ ビット列 (0/1 の文字列) を符号化し、軟判定の並びにする。
  1 ビットにつき 2 つの軟判定が出る (符号化率 1/2)。 }
function EncodeToSoft(const ABits: string): TByteArray;
var
  enc: TConvEncoder;
  i, v, n: Integer;
begin
  enc := TConvEncoder.Create;
  try
    SetLength(Result, Length(ABits) * 2);
    n := 0;
    for i := 1 to Length(ABits) do
    begin
      v := enc.Encode(Ord(ABits[i]) - Ord('0'));
      { bit0 が poly1、bit1 が poly2。確実な 0/1 として渡す。 }
      Result[n] := Byte((v and 1) * 255); Inc(n);
      Result[n] := Byte(((v shr 1) and 1) * 255); Inc(n);
    end;
  finally
    enc.Free;
  end;
end;

{ 軟判定の並びを復号し、出てきたビットを 0/1 の文字列にする。 }
function DecodeSoft(const ASoft: TByteArray): string;
var
  dec: TViterbiDecoder;
  i, c, met, b: Integer;
begin
  Result := '';
  dec := TViterbiDecoder.Create;
  try
    i := 0;
    while i + 1 < Length(ASoft) do
    begin
      c := dec.Decode(ASoft[i], ASoft[i + 1], met);
      if c <> CONV_NO_OUTPUT then
        for b := 7 downto 0 do
          Result := Result + Chr(Ord('0') + ((c shr b) and 1));
      Inc(i, 2);
    end;
  finally
    dec.Free;
  end;
end;

{ 送った文がそのまま出てきたか。Viterbi は遡ってから確定させるので、
  頭に遅れが付く。位置は問わず **含まれているか** で見る。 }
function Survives(const AMsg, ADecoded: string): Boolean;
begin
  Result := (AMsg <> '') and (Pos(AMsg, ADecoded) > 0);
end;

{ 押し出し用の 0 を足したビット列。Viterbi の遡り分を吐き出させる。 }
function WithFlush(const ABits: string): string;
var
  i: Integer;
begin
  Result := ABits;
  for i := 1 to CONV_MFSK_K * 12 + 64 do
    Result := Result + '0';
end;

function RandomBits(var ARnd: TVectorRandom; ACount: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to ACount do
    if ARnd.NextFloat < 0.5 then Result := Result + '0' else Result := Result + '1';
end;

{ --------------------------------------------------------------------------
  1. 符号化器が多項式の定義どおりに動くこと

  期待値は実装からではなく **多項式から手で** 出す。
  0x6d = 1101101, 0x4f = 1001111。1 を 1 つ入れて 0 を続けると、
  各ビット位置の 1/0 がそのまま 2 ビット出力に現れる。
  -------------------------------------------------------------------------- }
procedure TestEncoderKnownAnswers;
const
  { shreg = 1,2,4,8,16,32,64 のときの出力。
    bit0 = poly1(0x6d) の該当ビット、bit1 = poly2(0x4f) の該当ビット。
      b:      0  1  2  3  4  5  6
      0x6d:   1  0  1  1  0  1  1
      0x4f:   1  1  1  1  0  0  1
    -> 1|2=3, 0|2=2, 1|2=3, 1|2=3, 0|0=0, 1|0=1, 1|2=3 }
  IMPULSE: array[0..6] of Integer = (3, 2, 3, 3, 0, 1, 3);
var
  enc: TConvEncoder;
  i, v: Integer;
  ok: Boolean;
begin
  WriteLn;
  WriteLn('--- 1. 符号化器の既知解 ---');

  CheckEqI(BitParity(0), 0, 'パリティ: 0 -> 0');
  CheckEqI(BitParity(1), 1, 'パリティ: 1 -> 1');
  CheckEqI(BitParity(3), 0, 'パリティ: 3 (11b) -> 0');
  CheckEqI(BitParity(7), 1, 'パリティ: 7 (111b) -> 1');
  CheckEqI(BitParity(CONV_MFSK_POLY1), 1, 'パリティ: 0x6d (1が5本) -> 1');
  CheckEqI(BitParity(CONV_MFSK_POLY2), 1, 'パリティ: 0x4f (1が5本) -> 1');

  enc := TConvEncoder.Create;
  try
    CheckEqI(enc.K, 7, '拘束長は 7 (fldigi NASA_K)');
    CheckEqI(enc.Poly1, $6D, '生成多項式 1 は 0x6d');
    CheckEqI(enc.Poly2, $4F, '生成多項式 2 は 0x4f');

    { 全 0 を入れたら全 0 が出る。 }
    ok := True;
    for i := 1 to 20 do
      if enc.Encode(0) <> 0 then ok := False;
    Check(ok, '全 0 を入れたら全 0 が出る');

    { インパルス応答。 }
    enc.Reset;
    ok := True;
    Write('        インパルス応答:');
    v := enc.Encode(1);
    Write(' ', v);
    if v <> IMPULSE[0] then ok := False;
    for i := 1 to 6 do
    begin
      v := enc.Encode(0);
      Write(' ', v);
      if v <> IMPULSE[i] then ok := False;
    end;
    WriteLn('   期待: 3 2 3 3 0 1 3');
    Check(ok, '**インパルス応答が多項式のビット並びと一致する**');
  finally
    enc.Free;
  end;

  { 作れない指定は断る。 }
  Inc(TestCount);
  ok := False;
  try
    TConvEncoder.Create(7, $6D, $6D).Free;   { 同じ多項式 }
  except
    on E: EConvCodecError do ok := True;
  end;
  if ok then WriteLn('  [OK] **同じ多項式 2 本を断る** (冗長にならない)')
  else begin WriteLn('  [NG] 同じ多項式 2 本を断る'); Inc(FailCount); end;
end;

{ --------------------------------------------------------------------------
  2. 誤りが無ければ完全に戻ること
  -------------------------------------------------------------------------- }
procedure TestCleanRoundTrip;
const
  MSG = '1011001110100011010111000110';
var
  soft: TByteArray;
  outBits: string;
  dec: TViterbiDecoder;
begin
  WriteLn;
  WriteLn('--- 2. 誤りが無ければ完全に戻る ---');
  dec := TViterbiDecoder.Create;
  try
    CheckEqI(dec.StateCount, 64, '状態数は 2^(K-1) = 64');
    CheckEqI(dec.TracebackLen, 7 * 12, '遡る長さは K の 12 倍 (fldigi と同じ)');
    CheckEqI(dec.ChunkSize, 8, '一度に確定するのは 8 ビット');
  finally
    dec.Free;
  end;

  soft := EncodeToSoft(WithFlush(MSG));
  outBits := DecodeSoft(soft);
  WriteLn('        送: ', MSG);
  WriteLn('        受: ', Copy(outBits, 1, 60), '...');
  Check(Survives(MSG, outBits), '**符号化して復号すると元のビット列が出る**');
end;

{ --------------------------------------------------------------------------
  3. 散った誤りを直せること
  -------------------------------------------------------------------------- }
procedure TestScatteredErrors;
const
  MSG = '110100101110001101011100011010010111';
var
  rnd: TVectorRandom;
  soft: TByteArray;
  bits: string;
  nerr, trial, fixed, i, idx: Integer;
  worst: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 散った誤りを直せる ---');
  bits := WithFlush(MSG);
  worst := 0;
  for nerr := 1 to 8 do
  begin
    fixed := 0;
    for trial := 1 to 20 do
    begin
      rnd.Seed(QWord(1000 * nerr + trial));
      soft := EncodeToSoft(bits);
      { まばらに反転させる。間隔を空けて「散った」状態にする。 }
      for i := 1 to nerr do
      begin
        idx := (Integer(rnd.NextU64 mod QWord(Length(soft) div (nerr + 1)))
                + (i - 1) * (Length(soft) div (nerr + 1)));
        if idx < Length(soft) then
          soft[idx] := Byte(255 - soft[idx]);
      end;
      if Survives(MSG, DecodeSoft(soft)) then Inc(fixed);
    end;
    WriteLn(Format('        %d ビット反転 -> 20 回中 %d 回そのまま戻る', [nerr, fixed]));
    if fixed = 20 then worst := nerr;
  end;
  Check(worst >= 3,
    Format('**散った誤りを %d ビットまで確実に直せる** (自由距離 10 の符号)',
      [worst]));
end;

{ --------------------------------------------------------------------------
  4. 軟判定が硬判定より強いこと

  Phase 3 の「Soft Decision」がなぜ効くのかを、ここで数字にする。
  同じ雑音を、軟判定のまま渡した場合と、128 で 0/255 に潰してから渡した
  場合で比べる。潰すと「どちらとも言えない」という情報が消える。
  -------------------------------------------------------------------------- }
procedure TestSoftBeatsHard;
const
  MSG = '1101001011100011010111000110100101110001101011100011';
  TRIALS = 30;
var
  rnd: TVectorRandom;
  bits: string;
  soft, hard: TByteArray;
  i, t, v, okSoft, okHard: Integer;
begin
  WriteLn;
  WriteLn('--- 4. 軟判定が硬判定より強い (Phase 3 Soft Decision の根拠) ---');
  bits := WithFlush(MSG);
  okSoft := 0;
  okHard := 0;
  for t := 1 to TRIALS do
  begin
    rnd.Seed(QWord(7000 + t));
    soft := EncodeToSoft(bits);
    SetLength(hard, Length(soft));
    for i := 0 to High(soft) do
    begin
      { 0/255 に雑音を乗せる。標準偏差 90 はビット誤り率が数 % になる強さ。 }
      v := Round(soft[i] + 90.0 * rnd.NextGauss);
      if v < 0 then v := 0;
      if v > 255 then v := 255;
      soft[i] := Byte(v);
      { 硬判定: 真ん中で 0/255 に倒す。 }
      if v < CONV_SOFT_ERASURE then hard[i] := 0 else hard[i] := 255;
    end;
    if Survives(MSG, DecodeSoft(soft)) then Inc(okSoft);
    if Survives(MSG, DecodeSoft(hard)) then Inc(okHard);
  end;

  WriteLn(Format('        同じ雑音 %d 回: 軟判定 %d 回成功 / 硬判定 %d 回成功',
    [TRIALS, okSoft, okHard]));
  Check(okSoft > okHard,
    '**軟判定のほうが多く復元できる** (潰すと情報が減る)');
  Check(okSoft >= TRIALS div 2, '軟判定は半分以上で復元できている');
end;

{ --------------------------------------------------------------------------
  5. 消失 (128) が「分からない」として扱われること

  戻し側のインタリーバが空の枠を 0 で埋めると、Viterbi に
  「確実に 0」という嘘の自信を与える。128 なら何も主張しない。
  -------------------------------------------------------------------------- }
procedure TestErasureIsNeutral;
const
  MSG = '110100101110001101011100011010010111';
  TRIALS = 24;
var
  rnd: TVectorRandom;
  soft: TByteArray;
  i, t, n, at_, okErasure, okWrong: Integer;
begin
  WriteLn;
  WriteLn('--- 5. 消失は嘘の自信を与えない ---');
  { 比べるのは「消失」と「**自信を持って間違える**」である。
    同じ位置に、(a) 128 を置く場合と (b) 正解の逆を 0/255 で置く場合。
    戻し側の表を 0 で埋める実装にすると (b) になり、Viterbi は
    間違った方向へ強く引っ張られる。

    前に書いた試験は前半 1/4 をまるごと消していた。46 ビット連続の
    欠落は符号の能力を超えるので、消失でも 0 でも等しく失敗する ――
    **どちらが良いかを何も言えない試験**だった。 }
  okErasure := 0;
  okWrong := 0;
  n := 10;
  for t := 1 to TRIALS do
  begin
    rnd.Seed(QWord(5500 + t));
    at_ := 40 + Integer(rnd.NextU64 mod 60);

    soft := EncodeToSoft(WithFlush(MSG));
    for i := at_ to at_ + n - 1 do
      if i <= High(soft) then soft[i] := CONV_SOFT_ERASURE;
    if Survives(MSG, DecodeSoft(soft)) then Inc(okErasure);

    soft := EncodeToSoft(WithFlush(MSG));
    for i := at_ to at_ + n - 1 do
      if i <= High(soft) then soft[i] := Byte(255 - soft[i]);   { 自信を持って逆 }
    if Survives(MSG, DecodeSoft(soft)) then Inc(okWrong);
  end;

  WriteLn(Format('        同じ位置 %d 個: 消失 %d/%d 復元 / 自信を持って逆 %d/%d 復元',
    [n, okErasure, TRIALS, okWrong, TRIALS]));
  Check(okErasure >= okWrong,
    '**「分からない」は「自信を持って間違える」より悪くならない**');
  Check(okErasure > okWrong,
    Format('**消失のほうが実際に強い** (%d 対 %d) ―― 戻し側を 0 で埋めてはいけない理由',
      [okErasure, okWrong]));
end;

{ --------------------------------------------------------------------------
  6. インタリーバが往復で元に戻ること
  -------------------------------------------------------------------------- }
procedure TestInterleaverRoundTrip;
const
  N = 400;
var
  fwd, rev: TInterleaver;
  src, mid, dst: TByteArray;
  blk: TByteArray;
  i, k, sz, delay: Integer;
  rnd: TVectorRandom;
  found, zeros, erasures: Integer;
  s1, s2: string;
begin
  WriteLn;
  WriteLn('--- 6. インタリーバの往復 ---');
  fwd := TInterleaver.Create(INTERLEAVE_MFSK16_SIZE, INTERLEAVE_MFSK16_DEPTH, idForward);
  rev := TInterleaver.Create(INTERLEAVE_MFSK16_SIZE, INTERLEAVE_MFSK16_DEPTH, idReverse);
  try
    sz := fwd.Size;
    delay := fwd.RoundTripDelaySymbols;
    CheckEqI(sz, 4, 'MFSK16 の一辺は 4 (symbits)');
    CheckEqI(fwd.Depth, 10, 'MFSK16 の段数は 10');
    WriteLn(Format('        往復の遅れは (Size-1) x Depth x Size = %d シンボル',
      [delay]));

    rnd.Seed(4242);
    SetLength(src, N * sz);
    for i := 0 to High(src) do src[i] := Byte(rnd.NextU64 and 255);

    SetLength(mid, Length(src));
    SetLength(dst, Length(src));
    SetLength(blk, sz);

    for k := 0 to N - 1 do
    begin
      for i := 0 to sz - 1 do blk[i] := src[k * sz + i];
      fwd.Process(blk);
      for i := 0 to sz - 1 do mid[k * sz + i] := blk[i];
    end;
    for k := 0 to N - 1 do
    begin
      for i := 0 to sz - 1 do blk[i] := mid[k * sz + i];
      rev.Process(blk);
      for i := 0 to sz - 1 do dst[k * sz + i] := blk[i];
    end;

    { 遅れがあるので、元の並びが後ろにずれて出てくる。
      ずれ幅を探し、そこから先が一致することを見る。 }
    found := -1;
    for k := 1 to N div 2 do
    begin
      s1 := ''; s2 := '';
      for i := 0 to 20 * sz - 1 do
      begin
        s1 := s1 + IntToHex(src[i], 2);
        s2 := s2 + IntToHex(dst[k * sz + i], 2);
      end;
      if s1 = s2 then begin found := k * sz; Break; end;
    end;
    WriteLn(Format('        実測のずれ %d シンボル / 計算値 %d シンボル',
      [found, delay]));
    Check(found > 0, '**かき混ぜて戻すと元の並びが出てくる**');
    CheckEqI(found, delay,
      '**遅れが (Size-1) x Depth x Size にぴったり一致する** (行に依らず一定)');
  finally
    fwd.Free; rev.Free;
  end;

  { --- 受信を始めた直後に何を出すか ---
    戻し側の表はまだ空である。そこを 0 で埋めると、Viterbi には
    「確実に 0」が並んで届く ―― **嘘の自信**である。復号器はそれを信じて
    道を選ぶので、受信開始直後やリセット直後に化けた文字が並ぶ。
    消失 (128) なら「分からない」と伝わり、復号器は何も主張しない。

    反証でここが素通りした。往復の試験は頭が流れ切ったあとで重ね合わせて
    いるので、**表の初期値が届く区間をどの主張も見ていなかった**。 }
  WriteLn;
  WriteLn('--- 6b. 受信開始直後に嘘の自信を出さないこと ---');
  rev := TInterleaver.Create(INTERLEAVE_MFSK16_SIZE, INTERLEAVE_MFSK16_DEPTH, idReverse);
  try
    sz := rev.Size;
    SetLength(blk, sz);
    zeros := 0;
    erasures := 0;
    for k := 1 to rev.RoundTripDelayBlocks do
    begin
      { 「確実に 1」だけを入れる。出てくる 0 は表の初期値しかありえない。 }
      for i := 0 to sz - 1 do blk[i] := 255;
      rev.Process(blk);
      for i := 0 to sz - 1 do
      begin
        if blk[i] = 0 then Inc(zeros);
        if blk[i] = INTERLEAVE_ERASURE then Inc(erasures);
      end;
    end;
    WriteLn(Format('        最初の %d 区画: 消失 %d 個 / 「確実に 0」 %d 個',
      [rev.RoundTripDelayBlocks, erasures, zeros]));
    Check(erasures > 0, '前提: まだ埋まっていない枠が出てきている');
    CheckEqI(zeros, 0,
      '**空の枠を「確実に 0」として出さない** (受信開始直後に化けない)');
  finally
    rev.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. インタリーバが固まった誤りを散らすこと

  これが存在意義である。固まったまま Viterbi に渡しても直らない。
  -------------------------------------------------------------------------- }
procedure TestInterleaverScattersBursts;
const
  N = 200;
  BURST = 24;
var
  fwd, rev: TInterleaver;
  blk: TByteArray;
  marked: TByteArray;
  i, k, sz, runNow, runMax, total: Integer;
begin
  WriteLn;
  WriteLn('--- 7. 固まった誤りを散らす ---');
  fwd := TInterleaver.Create;
  rev := TInterleaver.Create(INTERLEAVE_MFSK16_SIZE, INTERLEAVE_MFSK16_DEPTH, idReverse);
  try
    sz := fwd.Size;
    SetLength(marked, N * sz);
    SetLength(blk, sz);

    { 値そのものではなく「壊れた印」を追う。0 = 無事、1 = 壊れた。 }
    for k := 0 to N - 1 do
    begin
      for i := 0 to sz - 1 do blk[i] := 0;
      fwd.Process(blk);
      for i := 0 to sz - 1 do marked[k * sz + i] := blk[i];
    end;
    { 真ん中で BURST シンボルぶん連続して壊す。 }
    for i := (N div 2) * sz to (N div 2) * sz + BURST - 1 do
      marked[i] := 1;

    { 戻すと印がどこへ散るか。 }
    for k := 0 to N - 1 do
    begin
      for i := 0 to sz - 1 do blk[i] := marked[k * sz + i];
      rev.Process(blk);
      for i := 0 to sz - 1 do marked[k * sz + i] := blk[i];
    end;

    runNow := 0; runMax := 0; total := 0;
    for i := 0 to High(marked) do
      if marked[i] <> 0 then
      begin
        Inc(runNow); Inc(total);
        if runNow > runMax then runMax := runNow;
      end
      else
        runNow := 0;

    WriteLn(Format('        %d シンボルの固まり -> 戻すと %d 個に散り、最長の連続は %d',
      [BURST, total, runMax]));
    Check(total > 0, '前提: 印が残っている');
    Check(runMax < BURST,
      Format('**固まりが解ける** (連続 %d -> 最長 %d)', [BURST, runMax]));
  finally
    fwd.Free; rev.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. インタリーバ有りなら直る誤りが、無しでは直らないこと

  誤り訂正は「付けた」だけでは意味がない。**付けなかった場合より良い**
  ことを示して初めて価値が言える。
  -------------------------------------------------------------------------- }
{ 鎖を 1 本通し、**復号したビット列の誤り数**を返す。
  真偽ではなく数で返すのは、前の書き方が真偽だったために
  「有りも無しも全部復元」で差が出ず、**何も言えない試験**になったからである。
  (原因は、探していた文字列が先頭にあるのに、壊す位置を 600 番目に
  置いていたこと ―― 壊した場所が探す場所より後ろだった。) }
const
  { 重ね合わせを探すための比較窓。全長より十分短く取る。 }
  CHAIN_WINDOW = 300;

function ChainErrors(const ABits: string; AUseInterleave: Boolean;
  ABurstBlocks: Integer): Integer;
var
  fwd, rev: TInterleaver;
  soft, work: TByteArray;
  blk: TByteArray;
  decoded: string;
  i, k, sz, nblk, mid, off, best, bestOff, errs, n: Integer;
begin
  soft := EncodeToSoft(ABits);
  sz := INTERLEAVE_MFSK16_SIZE;
  nblk := Length(soft) div sz;
  SetLength(work, nblk * sz);
  for i := 0 to High(work) do work[i] := soft[i];
  SetLength(blk, sz);

  if AUseInterleave then
  begin
    fwd := TInterleaver.Create(sz, INTERLEAVE_MFSK16_DEPTH, idForward);
    try
      for k := 0 to nblk - 1 do
      begin
        for i := 0 to sz - 1 do blk[i] := work[k * sz + i];
        fwd.Process(blk);
        for i := 0 to sz - 1 do work[k * sz + i] := blk[i];
      end;
    finally
      fwd.Free;
    end;
  end;

  { 真ん中を **区画ごと** 消す。空電で連続して潰れた状態。 }
  mid := nblk div 2;
  for k := mid to mid + ABurstBlocks - 1 do
    if k < nblk then
      for i := 0 to sz - 1 do work[k * sz + i] := CONV_SOFT_ERASURE;

  if AUseInterleave then
  begin
    rev := TInterleaver.Create(sz, INTERLEAVE_MFSK16_DEPTH, idReverse);
    try
      for k := 0 to nblk - 1 do
      begin
        for i := 0 to sz - 1 do blk[i] := work[k * sz + i];
        rev.Process(blk);
        for i := 0 to sz - 1 do work[k * sz + i] := blk[i];
      end;
    finally
      rev.Free;
    end;
  end;

  decoded := DecodeSoft(work);

  { --- 2 段構え ---
    (1) **頭の無傷な区間**で重ね合わせを探す。窓は全長より短く取る。
        全長で比べるとずらす余地が無く、探索が働かない。
    (2) 見つけた位置で **全体** の誤りを数える。

    窓のまま数えてはいけない。壊した場所は真ん中なので、頭だけ見ると
    「有りも無しも誤り 0」になる ―― 壊れていない所を測っていることになる。
    ここは二度同じ間違いをした場所である。 }
  best := MaxInt;
  bestOff := 0;
  n := CHAIN_WINDOW;
  for off := 0 to Length(decoded) - n do
  begin
    errs := 0;
    for i := 1 to n do
      if decoded[off + i] <> ABits[i] then Inc(errs);
    if errs < best then begin best := errs; bestOff := off; end;
    if best = 0 then Break;
  end;

  n := Length(ABits);
  if bestOff + n > Length(decoded) then n := Length(decoded) - bestOff;
  errs := 0;
  for i := 1 to n do
    if decoded[bestOff + i] <> ABits[i] then Inc(errs);
  Result := errs;
end;

procedure TestInterleaverHelpsBurst;
var
  rnd: TVectorRandom;
  bits: string;
  burst, eWith, eWithout, wins: Integer;
begin
  WriteLn;
  WriteLn('--- 8. インタリーバ有り/無しで固まった誤りへの強さを比べる ---');
  rnd.Seed(31337);
  bits := WithFlush(RandomBits(rnd, 600));

  { まず壊さずに測る。ここが 0 でなければ鎖そのものが壊れている。 }
  eWith := ChainErrors(bits, True, 0);
  eWithout := ChainErrors(bits, False, 0);
  WriteLn(Format('        前提: 壊さなければ誤り 0 (有り %d / 無し %d)',
    [eWith, eWithout]));
  Check((eWith = 0) and (eWithout = 0), '前提: 壊さなければ完全に戻る');

  WriteLn('        固まり(区画)   誤りビット数  有り / 無し');
  wins := 0;
  for burst := 5 to 60 do
  begin
    if burst mod 5 <> 0 then Continue;
    eWith := ChainErrors(bits, True, burst);
    eWithout := ChainErrors(bits, False, burst);
    WriteLn(Format('        %3d 区画 (%3d シンボル)   %5d / %5d',
      [burst, burst * INTERLEAVE_MFSK16_SIZE, eWith, eWithout]));
    if eWith < eWithout then Inc(wins);
  end;
  Check(wins > 0,
    Format('**インタリーバ有りのほうが誤りが少ない場面がある** (%d 通りで勝つ)',
      [wins]));
  Check(ChainErrors(bits, True, 8) <= ChainErrors(bits, False, 8),
    'まとまった消失に対して、有りが無しより悪くなることはない');
end;

{ --------------------------------------------------------------------------
  9. 確保しない (X-04) / 同じ入力から同じ出力 (Z-05)
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

procedure TestNoAllocationAndDeterminism;
var
  enc: TConvEncoder;
  dec: TViterbiDecoder;
  il: TInterleaver;
  blk: TByteArray;
  mm: TMemoryManager;
  i, k, n, met, c: Integer;
  a, b: string;
begin
  WriteLn;
  WriteLn('--- 9. 確保しない (X-04) / 同じ入力から同じ出力 (Z-05) ---');
  enc := TConvEncoder.Create;
  dec := TViterbiDecoder.Create;
  il := TInterleaver.Create;
  SetLength(blk, il.Size);
  try
    { 初回の遅延確保を済ませる。 }
    for i := 1 to 100 do
    begin
      enc.Encode(i and 1);
      dec.Decode(Byte(i and 255), Byte((i * 7) and 255), met);
      il.Process(blk);
    end;

    GAllocCount := 0;
    GetMemoryManager(GOldMM);
    mm := GOldMM;
    mm.GetMem := @CountingGetMem;
    mm.ReAllocMem := @CountingReAllocMem;
    SetMemoryManager(mm);
    GCounting := True;
    try
      for k := 1 to 5000 do
      begin
        enc.Encode(k and 1);
        c := dec.Decode(Byte(k and 255), Byte((k * 7) and 255), met);
        if c = CONV_NO_OUTPUT then ;
        il.Process(blk);
      end;
      n := GAllocCount;
    finally
      GCounting := False;
      SetMemoryManager(GOldMM);
    end;
    CheckEqI(n, 0, Format('5000 回の符号化・復号・かき混ぜで確保 0 回 (実測 %d)', [n]));
  finally
    enc.Free; dec.Free; il.Free;
  end;

  a := DecodeSoft(EncodeToSoft(WithFlush('1011001110100011')));
  b := DecodeSoft(EncodeToSoft(WithFlush('1011001110100011')));
  Check(a = b, '**同じ入力から同じ出力** (Z-05)');
end;

begin
  WriteLn('=== MFSK 系の誤り訂正層 (畳み込み符号 + インタリーバ) の試験 ===');

  TestEncoderKnownAnswers;
  TestCleanRoundTrip;
  TestScatteredErrors;
  TestSoftBeatsHard;
  TestErasureIsNeutral;
  TestInterleaverRoundTrip;
  TestInterleaverScattersBursts;
  TestInterleaverHelpsBurst;
  TestNoAllocationAndDeterminism;

  if FailCount = 0 then
    CoverReq('MDM-009');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
