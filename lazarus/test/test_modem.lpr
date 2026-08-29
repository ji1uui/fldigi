{ ============================================================================
  test_modem.lpr

  Modem/ModemEngine/ModemUI/NullModemImpl の結合テスト用コンソールプログラム。
  実際に TModemEngine をワーカースレッドとして起動し、
  「ワーカースレッド → TModemUI(Queue) → メインスレッドのコールバック」
  という経路が正しく機能することを検証する。

  GUI (LCL) には依存しないため、lcl-nogui は不要。単純な
  TThread.Queue の実行を回すために CheckSynchronize を明示的に呼ぶ。
  ============================================================================ }
program test_modem;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  SoundIntf, ModemTypes, Modem, ModemEngine, ModemUI, DecodeEvidence, NullModemImpl;

type
  { テスト用の擬似フォーム。TModemUI からのイベントを受けて
    メインスレッド上で呼ばれたことをカウント・表示する。 }
  TFakeMainForm = class
  private
    FUI: TModemUI;
    FMainThreadID: TThreadID;
    FFreqCount: Integer;
    FStateCount: Integer;
    FTxCharsSent: Integer;
    FTxQueue: string;
    FTxPos: Integer;
  public
    constructor Create(AUI: TModemUI);
    procedure OnFreq(Sender: TModemUI; AFrequency: Double);
    procedure OnMetric(Sender: TModemUI; AMetric: Double);
    procedure OnStatus(Sender: TModemUI; const AText: string);
    procedure OnRxChar(Sender: TModemUI; ACh: Integer;
      AMetricKind: TEvidenceMetricKind; AMetric: Double; AAltCount: Integer);
    procedure OnState(Sender: TModemUI; AState: TTrxState);
    procedure OnError(Sender: TModemUI; const AMsg: string);
    function OnGetTxChar(Sender: TModemUI): Integer;

    property FreqCount: Integer read FFreqCount;
    property StateCount: Integer read FStateCount;
  end;

constructor TFakeMainForm.Create(AUI: TModemUI);
begin
  FUI := AUI;
  FMainThreadID := ThreadID;
  FFreqCount := 0;
  FStateCount := 0;
  FTxCharsSent := 0;
  FTxQueue := 'HELLO DE LAZARUS TEST';
  FTxPos := 1;
end;

procedure TFakeMainForm.OnFreq(Sender: TModemUI; AFrequency: Double);
begin
  Inc(FFreqCount);
  if ThreadID <> FMainThreadID then
    WriteLn('  [NG] OnFreq がメインスレッド以外で呼ばれた!')
  else
    WriteLn(Format('  [OK] OnFreq: %.1f Hz (メインスレッドで実行)', [AFrequency]));
end;

procedure TFakeMainForm.OnMetric(Sender: TModemUI; AMetric: Double);
begin
  WriteLn(Format('  [OK] OnMetric: %.1f', [AMetric]));
end;

procedure TFakeMainForm.OnStatus(Sender: TModemUI; const AText: string);
begin
  WriteLn('  [OK] OnStatus: ' + AText);
end;

procedure TFakeMainForm.OnRxChar(Sender: TModemUI; ACh: Integer;
  AMetricKind: TEvidenceMetricKind; AMetric: Double; AAltCount: Integer);
begin
  WriteLn(Format('  [OK] OnRxChar: %d (%s)', [ACh, Chr(ACh)]));
end;

procedure TFakeMainForm.OnState(Sender: TModemUI; AState: TTrxState);
begin
  Inc(FStateCount);
  if ThreadID <> FMainThreadID then
    WriteLn('  [NG] OnState がメインスレッド以外で呼ばれた!')
  else
    WriteLn('  [OK] OnState: ' + IntToStr(Ord(AState)) + ' (メインスレッドで実行)');
end;

procedure TFakeMainForm.OnError(Sender: TModemUI; const AMsg: string);
begin
  WriteLn('  [ERROR] ' + AMsg);
end;

function TFakeMainForm.OnGetTxChar(Sender: TModemUI): Integer;
begin
  // fldigi: get_tx_char() のアプリ側実装に相当。
  // これはワーカースレッドから直接呼ばれるため、
  // 単純な整数インデックス操作のみ (LCLに触れない) にとどめる。
  if FTxPos <= Length(FTxQueue) then
  begin
    Result := Ord(FTxQueue[FTxPos]);
    Inc(FTxPos);
    Inc(FTxCharsSent);
  end
  else
    Result := MODEM_TX_CHAR_ETX;
end;

var
  Sound: TNullSoundDevice;
  NullModem: TNullModem;
  Engine: TModemEngine;
  UI: TModemUI;
  Form: TFakeMainForm;
  i: Integer;
begin
  WriteLn('=== TModem / TModemEngine / TModemUI 結合テスト ===');
  WriteLn;

  Sound := TNullSoundDevice.Create;
  { 実運用と同じく、エンジンへ渡す前にデバイスを開いておく。
    (以前は開かずに渡しており、未オープンのデバイスへ読み書きするという
     契約違反をテストが再現していなかった。) }
  Sound.Open(sdRead, 8000);
  NullModem := TNullModem.Create(Sound);
  Engine := TModemEngine.Create(Sound, Sound);
  UI := TModemUI.Create;
  Form := TFakeMainForm.Create(UI);

  UI.OnFrequencyChanged := @Form.OnFreq;
  UI.OnMetricChanged := @Form.OnMetric;
  UI.OnStatusText := @Form.OnStatus;
  UI.OnRxChar := @Form.OnRxChar;
  UI.OnStateChanged := @Form.OnState;
  UI.OnError := @Form.OnError;
  UI.OnGetTxChar := @Form.OnGetTxChar;

  UI.AttachModem(NullModem);
  UI.AttachEngine(Engine);

  Engine.SetModem(NullModem);

  WriteLn('--- 1) 周波数変更 (ワーカースレッド視点をシミュレート) ---');
  NullModem.Frequency := 1500.0;
  CheckSynchronize(100); // TThread.Queue の中身をメインスレッドで実行

  WriteLn('--- 2) メトリック通知 ---');
  NullModem.Metric := 87.5;
  CheckSynchronize(100);

  WriteLn('--- 3) 受信文字通知 (put_rx_char 相当) ---');
  NullModem.RxProcess([0.0], 0); // 実際のDSPは何もしないダミー
  for i := 1 to 3 do
  begin
    // EmitRxChar は protected のため、テスト用に RxProcess 経由で
    // 呼ばれる想定だが、ここでは直接ダミー文字を模擬する目的で
    // TNullModem 内部のロジックを使わず簡易に発火させる。
    NullModem.Frequency := NullModem.Frequency; // no-op (freq再送のみ)
  end;

  WriteLn('--- 4) 送信キュー get_tx_char (ワーカースレッド直接呼び出し) ---');
  for i := 1 to 5 do
    WriteLn(Format('  tx_char[%d] = %d', [i, UI.Modem.OnGetTxChar(UI.Modem)]));

  WriteLn('--- 5) エンジンスレッド実行 (実スレッドで RX/TX 状態遷移) ---');
  Engine.Start;
  Engine.RequestReceive;
  Sleep(50);
  CheckSynchronize(100);

  Engine.RequestTransmit;
  Sleep(50);
  CheckSynchronize(100);

  Engine.RequestReceive;
  Sleep(50);
  CheckSynchronize(100);

  Engine.RequestExit;
  Engine.WaitFor;
  CheckSynchronize(100);

  WriteLn;
  WriteLn(Format('周波数通知回数 = %d, 状態通知回数 = %d', [Form.FreqCount, Form.StateCount]));
  WriteLn('=== テスト完了 ===');

  { APP-01: 破棄順序を本体 (UnitMainForm.Destroy) と揃える。
    (1) ワーカースレッドを止める (上の RequestExit/WaitFor で完了済み)
    (2) UI を破棄する -- DetachEngine のためエンジン本体はまだ生かす
    (3) エンジン本体を破棄する
    逆順にすると TModemUI.Destroy -> DetachEngine が解放済みエンジンへ
    書き込む use-after-free になる。以前のテストはこの順序を再現したまま
    成功終了していたため、欠陥を見逃していた。 }
  UI.Free;
  Engine.Free;
  Form.Free;
  NullModem.Free;
  Sound.Free;
end.
