{ ============================================================================
  test_cw_leading.lpr

  CW の先頭文字が失われる欠陥の回帰試験。

  何が起きていたか
  ----------------------------------------------------------------------------
  送信 "CQ CQ DE TEST 599 K" に対し、復調が "EQ CQ DE TEST 599 K" になって
  いた。先頭の C (-.-.) が E (.) になる ── 4 要素のうち最後の 1 つしか
  残らない。

  原因は AGC でも閾値でもなく、**雑音スパイクの棄却が進行中の文字を
  破棄していた** ことだった。キーイベントを実際に観測して分かった:

      KeyUp len=2384 -> "-"     (正しい長点)
      KeyDown ...              (雑音スパイク。棄却されて状態が Idle へ)
      KeyDown ...              (次の KeyDown が「idle からの開始」とみなし
      KeyDown ...               rx_rep_buf を空にする)
      KeyUp len=800  -> "."     (buf は "-." ではなく "." になっている)

  受信開始直後は AGC が整定しておらず、閾値が一時的に逆転する
  (実測で upper=64 / lower=96) ため、この短いスパイクが多発する。
  棄却したのは雑音であって、既に受け取った本物の要素ではないのに、
  それまでの要素まで一緒に捨てていた。

  fldigi 本体も同じ実装なので、これは移植の誤りではなく **fldigi から
  受け継いだ欠陥** である。

  この試験が守るもの
  ----------------------------------------------------------------------------
  先頭文字は雑音スパイクの影響を最も受けやすい場所なので、
  速度・雑音量・先頭文字の種類を振って、送信文字列と完全に一致することを
  要求する。以前の判定 (Pos('CQ') > 0) では、先頭が化けていても
  2 番目の CQ で見つかって通ってしまい、長らく気づかれなかった。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_cw_leading;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils,
  SoundIntf, ModemTypes, Modem, CwModemImpl, DecodeEvidence,
  TestSupport, Requirements;

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

type
  TSink = class
  private
    FText: string;
  public
    procedure Decode(Sender: TCustomModem; const AEv: TDecodeEvidence);
    property Text: string read FText;
  end;

procedure TSink.Decode(Sender: TCustomModem; const AEv: TDecodeEvidence);
begin
  if AEv.BestChar > 0 then
    FText := FText + Chr(AEv.BestChar);
end;

{ 送信 → 受信を通して復調文字列を返す。
  実運用と同じく、信号の前後に受信機の雑音を流す。 }
function RoundTrip(const AMsg: string; AWpm: Integer;
  ANoise: Double): string;
var
  txSound, rxSound: TCaptureSoundDevice;
  tx, rx: TCwModem;
  src: TTxSource;
  sink: TSink;
  guard, res, i: Integer;
  wave: TDoubleArray;
  noise: array of Double;

  procedure FeedNoise(ASeconds: Double);
  var
    k: Integer;
  begin
    SetLength(noise, Round(rx.SampleRate * ASeconds));
    for k := 0 to High(noise) do
      noise[k] := ANoise * (Random - 0.5);
    rx.RxProcess(noise, Length(noise));
  end;

begin
  txSound := TCaptureSoundDevice.Create;
  rxSound := TCaptureSoundDevice.Create;
  tx := TCwModem.Create(txSound);
  rx := TCwModem.Create(rxSound);
  src := TTxSource.Create(AMsg);
  sink := TSink.Create;
  try
    tx.Frequency := 700;
    rx.Frequency := 700;
    tx.SetCwSpeed(AWpm);
    rx.SetCwSpeed(AWpm);
    rx.CwTrack := False;   { 速度は既知なので追従は切る }
    tx.OnGetTxChar := @src.GetTxChar;
    rx.OnDecode := @sink.Decode;

    tx.TxInit;
    guard := 0;
    repeat
      res := tx.TxProcess;
      Inc(guard);
    until (res < 0) or (guard > 200000);
    wave := txSound.GetCapturedCopy;

    { 実際の受信機は送信開始前から雑音を受け続けている。 }
    FeedNoise(1.0);

    for i := 0 to High(wave) do
      wave[i] := wave[i] + ANoise * (Random - 0.5);
    rx.RxProcess(wave, Length(wave));

    { 最後の文字は「次のトーンが来ない」ことで確定するので、
      末尾にも雑音を流す。 }
    FeedNoise(0.5);

    Result := Trim(UpperCase(sink.Text));
  finally
    src.Free;
    sink.Free;
    tx.Free;
    rx.Free;
    txSound.Free;
    rxSound.Free;
  end;
end;

procedure CheckRoundTrip(const AMsg: string; AWpm: Integer;
  ANoise: Double; const AWhat: string);
var
  got: string;
begin
  got := RoundTrip(AMsg, AWpm, ANoise);
  Inc(TestCount);
  if got = AMsg then
    WriteLn(Format('  [OK] %s  [%s]', [AWhat, got]))
  else
  begin
    WriteLn(Format('  [NG] %s', [AWhat]));
    WriteLn(Format('        期待: [%s]  実際: [%s]', [AMsg, got]));
    Inc(FailCount);
  end;
end;

{ --------------------------------------------------------------------------
  1. 先頭文字が失われないこと ── この試験の中心
  -------------------------------------------------------------------------- }
procedure TestLeadingCharacter;
begin
  WriteLn;
  WriteLn('--- 1. 先頭文字が失われないこと ---');

  { 元の不具合そのもの。C (-.-.) が E (.) になっていた。 }
  CheckRoundTrip('CQ CQ DE TEST 599 K', 12, 0.001,
    '元の不具合の再現条件 (C が E になっていた)');

  { 先頭の符号の種類を振る。短点始まり・長点始まり・長い符号。 }
  CheckRoundTrip('A', 12, 0.001, '先頭が短点始まりの 1 文字 (A = .-)');
  CheckRoundTrip('T', 12, 0.001, '先頭が長点のみの 1 文字 (T = -)');
  CheckRoundTrip('E', 12, 0.001, '先頭が短点のみの 1 文字 (E = .)');
  CheckRoundTrip('EEEEE', 12, 0.001, '短点だけが連続する (E x5)');
  CheckRoundTrip('TTTTT', 12, 0.001, '長点だけが連続する (T x5)');
  CheckRoundTrip('OOOOO', 12, 0.001, '長点 3 つの符号が連続する (O x5)');
  CheckRoundTrip('55555', 12, 0.001, '5 要素の符号が連続する (5 = .....)');
  CheckRoundTrip('SOS SOS', 12, 0.001, '語間を挟む');
end;

{ --------------------------------------------------------------------------
  2. 速度を振る
  -------------------------------------------------------------------------- }
procedure TestSpeeds;
begin
  WriteLn;
  WriteLn('--- 2. 速度を振る ---');
  CheckRoundTrip('CQ CQ DE TEST 599 K', 12, 0.001, '12 WPM');
  CheckRoundTrip('CQ CQ DE TEST 599 K', 18, 0.001, '18 WPM');
  CheckRoundTrip('CQ CQ DE TEST 599 K', 25, 0.001, '25 WPM');
end;

{ --------------------------------------------------------------------------
  3. 雑音量を振る

  雑音スパイクの棄却が絡む欠陥なので、雑音の量で挙動が変わらないことを
  確かめる意味がある。
  -------------------------------------------------------------------------- }
procedure TestNoiseLevels;
begin
  WriteLn;
  WriteLn('--- 3. 雑音量を振る ---');
  CheckRoundTrip('CQ DE JA1ABC K', 12, 0.001, '雑音 0.001');
  CheckRoundTrip('CQ DE JA1ABC K', 12, 0.01, '雑音 0.01');
  CheckRoundTrip('CQ DE JA1ABC K', 12, 0.05, '雑音 0.05');
  CheckRoundTrip('CQ DE JA1ABC K', 12, 0.10, '雑音 0.10');
end;

{ --------------------------------------------------------------------------
  4. 進行中の文字が雑音スパイクで壊れないこと (機構そのものの確認)

  上の試験は「結果が正しい」を見ている。ここでは原因側、つまり
  「文字の途中で状態が Idle に落ちても、それまでの要素が残る」ことを
  長い符号で確かめる。要素数が多いほど途中でスパイクを踏む機会が増える。
  -------------------------------------------------------------------------- }
procedure TestLongSymbols;
begin
  WriteLn;
  WriteLn('--- 4. 要素数の多い符号 ---');
  { 数字はすべて 5 要素。途中でスパイクを踏めば前半が消える。 }
  CheckRoundTrip('01234', 12, 0.001, '5 要素の数字 (前半)');
  CheckRoundTrip('56789', 12, 0.001, '5 要素の数字 (後半)');
  { 記号は 5〜6 要素。 }
  CheckRoundTrip('J1ABC', 12, 0.001, '英数混在');
end;

begin
  WriteLn('=== CW 先頭文字欠けの回帰試験 ===');
  Randomize;

  TestLeadingCharacter;
  TestSpeeds;
  TestNoiseLevels;
  TestLongSymbols;

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
    CoverReq('CMP-003');

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
