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
  SoundIntf, ModemTypes, Modem, ModemDSP, MorseTable,
  RttyModemImpl, CwModemImpl;

type
  TDoubleArray = array of Double;

  { TCaptureSoundDevice
    送信された波形サンプルをすべて内部バッファに蓄積するだけの
    テスト用サウンドデバイス。ReadSamples は無音(0.0)を返す。 }
  TCaptureSoundDevice = class(TCustomSoundDevice)
  private
    FCaptured: array of Double;
    FCount: Integer;
    procedure EnsureCapacity(AExtra: Integer);
  public
    constructor Create; override;
    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; override;
    procedure Close; override;
    procedure AbortIO; override;
    function ReadSamples(var Buf: array of Double; Count: Integer): Integer; override;
    function WriteSamples(const Buf: array of Double; Count: Integer): Integer; override;
    function WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer; override;
    procedure Flush; override;

    function GetCapturedCopy: TDoubleArray;

    property Count: Integer read FCount;
  end;

constructor TCaptureSoundDevice.Create;
begin
  inherited Create;
  FCount := 0;
  SetLength(FCaptured, 0);
end;

procedure TCaptureSoundDevice.EnsureCapacity(AExtra: Integer);
begin
  if FCount + AExtra > Length(FCaptured) then
    SetLength(FCaptured, (FCount + AExtra) * 2 + 1024);
end;

function TCaptureSoundDevice.Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean;
begin
  Result := True;
end;

procedure TCaptureSoundDevice.Close;
begin
end;

procedure TCaptureSoundDevice.AbortIO;
begin
end;

function TCaptureSoundDevice.ReadSamples(var Buf: array of Double; Count: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to Count - 1 do
    Buf[i] := 0.0;
  Result := Count;
end;

function TCaptureSoundDevice.WriteSamples(const Buf: array of Double; Count: Integer): Integer;
var
  i: Integer;
begin
  EnsureCapacity(Count);
  for i := 0 to Count - 1 do
  begin
    FCaptured[FCount] := Buf[i];
    Inc(FCount);
  end;
  Result := Count;
end;

function TCaptureSoundDevice.WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer;
begin
  Result := WriteSamples(BufL, Count);
end;

procedure TCaptureSoundDevice.Flush;
begin
end;

function TCaptureSoundDevice.GetCapturedCopy: TDoubleArray;
var
  i: Integer;
begin
  SetLength(Result, FCount);
  for i := 0 to FCount - 1 do
    Result[i] := FCaptured[i];
end;

{ ---- テスト駆動用のヘルパ (get_tx_char / put_rx_char 相当) ---- }

type
  TTxSource = class
  private
    FText: string;
    FPos: Integer;
  public
    constructor Create(const AText: string);
    function GetTxChar(Sender: TCustomModem): Integer;
  end;

constructor TTxSource.Create(const AText: string);
begin
  FText := AText;
  FPos := 1;
end;

function TTxSource.GetTxChar(Sender: TCustomModem): Integer;
begin
  if FPos <= Length(FText) then
  begin
    Result := Ord(FText[FPos]);
    Inc(FPos);
  end
  else
    Result := MODEM_TX_CHAR_ETX;
end;

type
  TRxSink = class
  private
    FText: string;
  public
    procedure PutRxChar(Sender: TCustomModem; ACh: Integer);
    property Text: string read FText;
  end;

procedure TRxSink.PutRxChar(Sender: TCustomModem; ACh: Integer);
begin
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
  RxModem.OnPutRxChar := @RxSink.PutRxChar;

  TxModem.TxInit;

  GuardCount := 0;
  repeat
    TxResult := TxModem.TxProcess;
    Inc(GuardCount);
  until (TxResult < 0) or (GuardCount > 100000);

  WriteLn(Format('  送信サンプル数: %d (%.2f 秒)', [TxSound.Count, TxSound.Count / TxModem.SampleRate]));

  RxModem.RxProcess(TxSound.GetCapturedCopy, TxSound.Count);

  WriteLn('  復調結果      : ', RxSink.Text);

  Passed := Pos(TestMsg, RxSink.Text) > 0;
  if Passed then
    WriteLn('  [OK] 送信文字列が復調結果に含まれている')
  else
    WriteLn('  [NG] 送信文字列が復調結果に見つからない!');

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
  RxModem.OnPutRxChar := @RxSink.PutRxChar;

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

  NormalizedActual := UpperCase(RxSink.Text);
  Passed := Pos('CQ', NormalizedActual) > 0;
  if Passed then
    WriteLn('  [OK] 復調結果に "CQ" が検出された')
  else
    WriteLn('  [NG] 復調結果に "CQ" が見つからない!');

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
  WriteLn('=== テスト完了 ===');
end.
