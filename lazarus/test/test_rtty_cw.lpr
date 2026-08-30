{ ============================================================================
  test_rtty_cw.lpr

  RttyModemImpl.pas (TRttyModem) / CwModemImpl.pas (TCwModem) の
  ループバック単体テスト。

  TCaptureSoundDevice で送信側の WriteSamples() 呼び出しをそのまま
  1本の Double 配列として蓄積し、それを別インスタンスの受信モデムの
  RxProcess() に流し込むことで「送信 → 復調」の往復が正しく機能するか
  (元の文字列が復元できるか) を検証する。GUI (LCL) には依存しない。
  ============================================================================ }
program test_rtty_cw;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  SoundIntf, ModemTypes, Modem, ModemDSP, DecodeEvidence, MorseTable, TestSupport,
  RttyModemImpl, CwModemImpl, Requirements;

{ この試験は [NG] を印字しても終了コードを 0 のままにしていた。
  run_tests.sh は [NG] を grep するので battery では捕まっていたが、
  binary を直接動かした側 (CI など) は失敗に気づけない。数えて返す。 }
var
  FailCount: Integer = 0;

procedure Fail(const AMsg: string);
begin
  Inc(FailCount);
  WriteLn('  [NG] ', AMsg);
end;


type
  TDoubleArray = array of Double;

  { TCaptureSoundDevice
    送信された波形サンプルをすべて内部バッファに蓄積するだけの
    テスト用サウンドデバイス。ReadSamples は無音(0.0)を返す。 }
  TRxSink = class
  private
    FText: string;
    FAltCount: Integer;
    FScoredCount: Integer;
    FMinMargin: Double;
  public
    constructor Create;
    { ADR-002: 復調結果は Evidence で届く。表示には最有力候補を使い、
      第2候補と軟判定余裕は別に集計して、型が実際に値を運んでいることを
      確かめる。 }
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
    property Text: string read FText;
    property AltCount: Integer read FAltCount;
    property ScoredCount: Integer read FScoredCount;
    property MinMargin: Double read FMinMargin;
  end;

constructor TRxSink.Create;
begin
  inherited Create;
  FMinMargin := 1.0;
end;

procedure TRxSink.Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
var
  ACh: Integer;
begin
  ACh := AEvidence.BestChar;
  if ACh = DECODE_NO_CHAR then Exit;
  if AEvidence.HasAlternatives then
    Inc(FAltCount);
  if AEvidence.MetricKind <> emkNone then
  begin
    Inc(FScoredCount);
    if AEvidence.BestMetric < FMinMargin then
      FMinMargin := AEvidence.BestMetric;
  end;
  if (ACh >= 32) and (ACh < 127) then
    FText := FText + Chr(ACh)
  else if ACh = 13 then
    FText := FText + '<CR>'
  else if ACh = 10 then
    FText := FText + '<LF>'
  else if ACh <> 0 then
    FText := FText + '[' + IntToStr(ACh) + ']';
end;

{ ---- RTTY ループバックテスト ---- }

procedure RunRttyLoopbackTest;
const
  TestMsg = 'HELLO WORLD 12345';
var
  TxSound, RxSound: TCaptureSoundDevice;
  TxModem, RxModem: TRttyModem;
  TxSrc: TTxSource;
  RxSink: TRxSink;
  GuardCount: Integer;
  TxResult: Integer;
  Passed: Boolean;
begin
  WriteLn('=== RTTY 送受信ループバックテスト ===');
  WriteLn('送信文字列: ', TestMsg);

  TxSound := TCaptureSoundDevice.Create;
  RxSound := TCaptureSoundDevice.Create;
  TxModem := TRttyModem.Create(TxSound);
  RxModem := TRttyModem.Create(RxSound);

  // 送受信とも同一パラメータ (既定 45.45baud/85Hz/5bit) を使用
  TxModem.Frequency := 1000;
  RxModem.Frequency := 1000;
  RxModem.AfcOn := False; // テストでは周波数が既知のため AFC を無効化

  TxSrc := TTxSource.Create(TestMsg);
  RxSink := TRxSink.Create;
  TxModem.OnGetTxChar := @TxSrc.GetTxChar;
  RxModem.OnDecode := @RxSink.Decode;

  TxModem.TxInit;

  GuardCount := 0;
  repeat
    TxResult := TxModem.TxProcess;
    Inc(GuardCount);
  until (TxResult < 0) or (GuardCount > 100000);

  WriteLn(Format('  送信サンプル数: %d (%.2f 秒)', [TxSound.Count, TxSound.Count / TxModem.SampleRate]));

  RxModem.RxProcess(TxSound.GetCapturedCopy, TxSound.Count);

  WriteLn('  復調結果      : ', RxSink.Text);
  { ADR-002 の実効確認: 型が「運べる」だけでなく、RTTY が実際に
    軟判定の値を載せていること。載せていなければ ScoredCount が 0 になる。 }
  WriteLn(Format('  Evidence      : 尺度つき %d 文字 / 第2候補あり %d 文字 / 最小余裕 %.3f',
    [RxSink.ScoredCount, RxSink.AltCount, RxSink.MinMargin]));
  if RxSink.ScoredCount > 0 then
    WriteLn('  [OK] RTTY が軟判定の余裕を Evidence として出している (ADR-002)')
  else
    Fail('Evidence に尺度が載っていない (ADR-002)');

  Passed := Pos(TestMsg, RxSink.Text) > 0;
  if Passed then
    WriteLn('  [OK] 送信文字列が復調結果に含まれている')
  else
    Fail('送信文字列が復調結果に見つからない!');

  TxModem.Free;
  RxModem.Free;
  TxSrc.Free;
  RxSink.Free;
  TxSound.Free;
  RxSound.Free;

  WriteLn;
end;

{ ---- CW ループバックテスト ---- }

procedure RunCwLoopbackTest;
const
  TestMsg = 'CQ CQ DE TEST 599 K';
var
  TxSound, RxSound: TCaptureSoundDevice;
  TxModem, RxModem: TCwModem;
  TxSrc: TTxSource;
  RxSink: TRxSink;
  GuardCount: Integer;
  TxResult: Integer;
  Passed: Boolean;
  NormalizedActual: string;
  i: Integer;
  Silence: array of Double;
begin
  WriteLn('=== CW 送受信ループバックテスト ===');
  WriteLn('送信文字列: ', TestMsg);

  TxSound := TCaptureSoundDevice.Create;
  RxSound := TCaptureSoundDevice.Create;
  TxModem := TCwModem.Create(TxSound);
  RxModem := TCwModem.Create(RxSound);

  TxModem.Frequency := 700;
  RxModem.Frequency := 700;

  // 復調を容易にするため低速 (12WPM) に設定
  TxModem.SetCwSpeed(12);
  RxModem.SetCwSpeed(12);
  RxModem.CwTrack := False; // テストでは速度が既知のためトラッキング無効化

  TxSrc := TTxSource.Create(TestMsg);
  RxSink := TRxSink.Create;
  TxModem.OnGetTxChar := @TxSrc.GetTxChar;
  RxModem.OnDecode := @RxSink.Decode;

  TxModem.TxInit;

  GuardCount := 0;
  repeat
    TxResult := TxModem.TxProcess;
    Inc(GuardCount);
  until (TxResult < 0) or (GuardCount > 100000);

  WriteLn(Format('  送信サンプル数: %d (%.2f 秒)', [TxSound.Count, TxSound.Count / TxModem.SampleRate]));

  // 実運用では受信機は送信開始前からずっと無音(またはノイズ)を
  // 受信し続けており、AGC/ノイズフロアの追跡はその間に馴染んでいる。
  // rx_init() 直後は agc_peak=0 から始まる (fldigi と同じ) ため、
  // コールドスタート直後の最初の1文字はAGC馴染み不足で誤読され得る。
  // これはfldigiの実装そのものの特性であり、実運用を模してAGCが
  // 馴染むだけの無音区間を先頭に追加してから信号を流し込む。
  SetLength(Silence, RxModem.SampleRate); // 1秒分の無音(+微弱ノイズ)
  for i := 0 to High(Silence) do
    Silence[i] := 0.001 * (Random - 0.5); // 実際の受信機は完全な無音ではない
  RxModem.RxProcess(Silence, Length(Silence));

  RxModem.RxProcess(TxSound.GetCapturedCopy, TxSound.Count);
  // decode_stream の QUERY イベントは「次のトーンが来るまでの無音」で
  // 駆動されるため、最後の文字を確定させるために追加の無音サンプルを
  // 流し込む (fldigi でも受信は継続的な音声ストリームを前提とする)。
  RxModem.RxProcess(Silence, Length(Silence));

  WriteLn('  復調結果      : ', RxSink.Text);

  NormalizedActual := Trim(UpperCase(RxSink.Text));

  { --- 判定を全文一致にした理由 ---
    以前は Pos('CQ') > 0 だけを見ていた。これだと先頭の C が E に
    化けていても "CQ" は 2 番目の CQ で見つかるので通ってしまい、
    実際に長らく気づかれないままだった (送信 CQ CQ... に対し
    復調 EQ CQ... で [OK] が出ていた)。

    先頭文字は雑音スパイクの棄却で壊れやすい場所なので、
    そこを名指しで見る判定にする。 }
  Passed := NormalizedActual = TestMsg;
  if Passed then
    WriteLn('  [OK] 復調結果が送信文字列と完全に一致した')
  else
    Fail(Format('復調結果が一致しない! 期待[%s] 実際[%s]',
      [TestMsg, NormalizedActual]));

  if Copy(NormalizedActual, 1, 1) = Copy(TestMsg, 1, 1) then
    WriteLn('  [OK] 先頭文字が失われていない')
  else
    Fail(Format('先頭文字が失われた! 期待[%s] 実際[%s]',
      [Copy(TestMsg, 1, 1), Copy(NormalizedActual, 1, 1)]));

  TxModem.Free;
  RxModem.Free;
  TxSrc.Free;
  RxSink.Free;
  TxSound.Free;
  RxSound.Free;

  WriteLn;
end;

begin
  RunRttyLoopbackTest;
  RunCwLoopbackTest;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 ===');

  { §18 要求トレーサビリティ: 通ったときだけ被覆を申告する。 }
  if FailCount = 0 then
    CoverReq('CMP-002');

  if FailCount > 0 then
    Halt(1);
end.
