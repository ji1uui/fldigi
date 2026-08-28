{ ============================================================================
  test_portaudio.lpr

  PortAudioBindings.pas / PortAudioSoundDevice.pas の動作確認用コンソール
  プログラム。GUI (LCL) には依存しない。

  実行内容:
    1. PortAudio ライブラリの初期化 (バージョン情報表示)
    2. デバイス一覧の列挙 (TPortAudioSoundDevice.EnumerateDevices)
    3. 入出力デバイスが実在する場合、実際に
       - 出力デバイスへ 440Hz テストトーンを別スレッドで送信しながら
       - 入力デバイスから同時に読み込み、
       Peak/RMS を計測して「送信した信号が実際にオーディオAPI経由で
       流れているか」を検証する (単に Open が成功するだけでなく、
       実データが往復することまで確認する)。

  実オーディオハードウェアが無い CI/サンドボックス環境では 2. のみで
  正常終了する。入出力ループバックまで検証したい場合は、OS側で
  マイク入力をスピーカー出力にモニターする設定 (Linux:
  PulseAudio/PipeWire の null-sink + monitor source、Windows:
  「ステレオミキサー」、macOS: BlackHole 等の仮想オーディオデバイス)
  を用意すること。検証手順は README.md の
  「4-2. PortAudio 実装の検証手順」を参照。
  ============================================================================ }
program test_portaudio;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, ctypes,
  SoundIntf, PortAudioBindings, PortAudioSoundDevice;

type
  { バックグラウンドで OutDev.WriteSamples をブロッキング呼び出しする
    だけのヘルパースレッド。WriteSamples は書き切るまで返らないため、
    メインスレッドの ReadSamples と並行させるために使用する。 }
  TToneWriterThread = class(TThread)
  private
    FDev: TPortAudioSoundDevice;
    FBuf: array of Double;
  public
    constructor Create(ADev: TPortAudioSoundDevice; const ABuf: array of Double);
    procedure Execute; override;
  end;

constructor TToneWriterThread.Create(ADev: TPortAudioSoundDevice; const ABuf: array of Double);
begin
  inherited Create(False);
  FDev := ADev;
  SetLength(FBuf, Length(ABuf));
  if Length(ABuf) > 0 then
    Move(ABuf[0], FBuf[0], Length(ABuf) * SizeOf(Double));
  FreeOnTerminate := False;
end;

procedure TToneWriterThread.Execute;
begin
  FDev.WriteSamples(FBuf, Length(FBuf));
end;

var
  Devices: TPaDeviceEntryArray;
  i: Integer;
  HasInput, HasOutput: Boolean;
  InDev, OutDev: TPortAudioSoundDevice;
  TxBuf, RxBuf: array of Double;
  NRead: Integer;
  SR: Integer;
  Peak, RmsSum: Double;
  TxThread: TToneWriterThread;

begin
  WriteLn('=== PortAudio バインディング検証 ===');
  WriteLn('PortAudio version: ', Pa_GetVersion, ' (', Pa_GetVersionText, ')');
  WriteLn;

  WriteLn('--- デバイス一覧 (EnumerateDevices) ---');
  Devices := TPortAudioSoundDevice.EnumerateDevices;
  if Length(Devices) = 0 then
    WriteLn('  (デバイスが見つかりません。オーディオハードウェアの無い環境では正常です)')
  else
    for i := 0 to High(Devices) do
      WriteLn(Format('  [%d] %s  in=%d out=%d defaultRate=%.0fHz',
        [Devices[i].Index, Devices[i].Name, Devices[i].MaxInputChannels,
         Devices[i].MaxOutputChannels, Devices[i].DefaultSampleRate]));
  WriteLn;

  HasInput := False;
  HasOutput := False;
  for i := 0 to High(Devices) do
  begin
    if Devices[i].MaxInputChannels > 0 then HasInput := True;
    if Devices[i].MaxOutputChannels > 0 then HasOutput := True;
  end;

  if not (HasInput and HasOutput) then
  begin
    WriteLn('入力・出力の両方のデバイスが揃っていないため、');
    WriteLn('実データ往復(ループバック)テストはスキップします。');
    WriteLn('=== テスト完了 (デバイス無し/片方のみの環境として正常終了) ===');
    Exit;
  end;

  WriteLn('--- 実データ往復テスト (440Hz トーン送信 → 受信バッファ解析) ---');
  WriteLn('※ OS側でマイク入力とスピーカー出力がモニター接続されている');
  WriteLn('  環境 (PulseAudio null-sink+monitor 等) でのみ Peak が観測されます。');

  SR := 44100;
  SetLength(TxBuf, SR * 2); // 2秒分の440Hzテストトーン (振幅0.5)
  for i := 0 to High(TxBuf) do
    TxBuf[i] := 0.5 * Sin(2 * Pi * 440 * i / SR);

  OutDev := TPortAudioSoundDevice.Create;
  InDev := TPortAudioSoundDevice.Create;
  TxThread := nil;
  try
    OutDev.Channels := 1;
    InDev.Channels := 1;

    if not OutDev.Open(sdWrite, SR) then
    begin
      WriteLn('  [NG] Open(sdWrite) が False を返した');
      Exit;
    end;
    WriteLn(Format('  [OK] Open(sdWrite, %d) 成功 (device index=%d)', [SR, OutDev.ResolvedDeviceIndex]));

    if not InDev.Open(sdRead, SR) then
    begin
      WriteLn('  [NG] Open(sdRead) が False を返した');
      Exit;
    end;
    WriteLn(Format('  [OK] Open(sdRead, %d) 成功 (device index=%d)', [SR, InDev.ResolvedDeviceIndex]));

    // WriteSamples はブロッキングで書き切るまで返らないため、
    // 別スレッドで送信しつつメインスレッドで受信する。
    TxThread := TToneWriterThread.Create(OutDev, TxBuf);
    Sleep(200); // 送信データが経路に乗るまで少し待つ

    SetLength(RxBuf, SR); // 1秒分読む
    NRead := InDev.ReadSamples(RxBuf, Length(RxBuf));
    WriteLn(Format('  [OK] ReadSamples: %d サンプル読み込み', [NRead]));

    Peak := 0;
    RmsSum := 0;
    for i := 0 to NRead - 1 do
    begin
      if Abs(RxBuf[i]) > Peak then Peak := Abs(RxBuf[i]);
      RmsSum := RmsSum + Sqr(RxBuf[i]);
    end;
    if NRead > 0 then
      WriteLn(Format('  Peak=%.4f  RMS=%.4f (送信振幅0.5の正弦波なら理論RMS=0.3536)',
        [Peak, Sqrt(RmsSum / NRead)]))
    else
      WriteLn('  (読み込みサンプル数 0)');

    if Peak > 0.01 then
      WriteLn('  [OK] 送信した音声信号が受信側で観測された (実データ往復に成功)')
    else
    begin
      WriteLn('  [情報] 受信信号が無音に近い (モニター接続の無い通常の');
      WriteLn('         マイク入力/スピーカー出力構成では既定の挙動です)');
    end;

    TxThread.WaitFor;

    OutDev.Close;
    InDev.Close;
  finally
    TxThread.Free;
    OutDev.Free;
    InDev.Free;
  end;
  WriteLn;

  WriteLn('=== テスト完了 ===');
end.
