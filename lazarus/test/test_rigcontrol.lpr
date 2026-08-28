{ ============================================================================
  test_rigcontrol.lpr

  HamlibBindings.pas / RigControlIntf.pas / HamlibRigControl.pas /
  RigPollThread.pas の動作確認用コンソールプログラム。GUI (LCL) には
  依存しない。

  実オーディオデバイスと同様、実無線機の無いサンドボックス/CI環境でも
  検証できるよう、Hamlib が提供する疑似リグ RIG_MODEL_DUMMY (Hamlib
  Dummy backend) を使って「疑似CAT通信」を検証する。Dummy backend は
  シリアルポートを一切必要とせず、rig_open() 後は内部変数に対して
  実際に rig_set_freq/rig_get_freq/rig_set_ptt/rig_get_ptt/
  rig_set_mode/rig_get_mode がすべて機能するため、CATコマンドの往復
  (fldigi でいう「実機を挿さずに Hamlib 層の配線を確認する」テスト) を
  実施するには最適である。

  実行内容:
    1. Hamlib のバージョン情報表示 (rig_version 相当は cptr 経由)
    2. リグモデル一覧の列挙 (THamlibRigControl.EnumerateRigs) --- 313種
       前後のモデルが登録されていることを確認する
    3. RIG_MODEL_DUMMY を使った基本CAT機能の疑似通信検証:
         Open -> SetFreq/GetFreq -> SetMode/GetMode -> SetPTT/GetPTT
         -> SetVFO/GetVFO -> SetConfStr/GetConfStr -> Close
    4. TRigPollThread による定期ポーリング動作の検証
       (Dummy リグの周波数を裏で変更し、ポーリングスレッドが
       OnFreqChanged イベントを発火することを確認する)

  検証手順の詳細は README.md の
  「6. 無線機 CAT 制御 (Hamlib) の検証手順」を参照。
  ============================================================================ }
program test_rigcontrol;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, ctypes, Math,
  RigControlIntf, HamlibBindings, HamlibRigControl, RigPollThread;

var
  FailCount: Integer;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('  [OK] ', Msg)
  else
  begin
    WriteLn('  [NG] ', Msg);
    Inc(FailCount);
  end;
end;

{ ---------------------------------------------------------------------------
  1. リグモデル一覧の列挙
  --------------------------------------------------------------------------- }
procedure TestEnumerateRigs;
var
  Entries: THamlibRigEntryArray;
  i: Integer;
  FoundDummy: Boolean;
begin
  WriteLn('--- 1. リグモデル一覧の列挙 (EnumerateRigs) ---');
  Entries := THamlibRigControl.EnumerateRigs;
  WriteLn(Format('  登録リグモデル数: %d', [Length(Entries)]));
  Check(Length(Entries) > 100, 'リグモデルが100種類以上登録されている');

  FoundDummy := False;
  for i := 0 to High(Entries) do
    if Entries[i].RigModel = RIG_MODEL_DUMMY then
    begin
      FoundDummy := True;
      WriteLn(Format('  Dummy backend 発見: [%d] %s / %s',
        [Entries[i].RigModel, Entries[i].MfgName, Entries[i].ModelName]));
      Break;
    end;
  Check(FoundDummy, 'RIG_MODEL_DUMMY が一覧に含まれている');

  // 先頭数件を表示 (目視確認用)
  WriteLn('  --- 先頭5件のサンプル表示 ---');
  for i := 0 to Min(4, High(Entries)) do
    WriteLn(Format('    [%d] %s / %s',
      [Entries[i].RigModel, Entries[i].MfgName, Entries[i].ModelName]));
  WriteLn;
end;

{ ---------------------------------------------------------------------------
  3. Dummy リグでの基本CAT機能疑似通信検証
  --------------------------------------------------------------------------- }
procedure TestDummyRigBasicCat;
var
  Rig: THamlibRigControl;
  f: Double;
  m: string;
  w: Integer;
  confVal: string;
begin
  WriteLn('--- 3. RIG_MODEL_DUMMY による基本CAT機能の疑似通信検証 ---');
  Rig := THamlibRigControl.Create(RIG_MODEL_DUMMY);
  try
    WriteLn('  RigName: ', Rig.RigName);
    Check(Rig.RigName <> '', 'RigName が取得できる');

    // Dummy リグはデバイスパス不要
    Rig.Device := '';
    Check(Rig.Open, 'Open が成功する (rig_open)');
    Check(Rig.IsOnLine, 'IsOnLine = True (Open後)');

    // --- 周波数 ---
    Rig.SetFreq(14074000.0); // 14.074MHz (FT8の周波数帯を例として使用)
    f := Rig.GetFreq;
    WriteLn(Format('  SetFreq(14074000) -> GetFreq() = %.0f', [f]));
    Check(Abs(f - 14074000.0) < 1.0, 'SetFreq/GetFreq の往復値が一致する');

    Rig.SetFreq(7040000.0);
    f := Rig.GetFreq;
    WriteLn(Format('  SetFreq(7040000) -> GetFreq() = %.0f', [f]));
    Check(Abs(f - 7040000.0) < 1.0, '2回目の SetFreq/GetFreq も一致する');

    // --- モード ---
    Rig.SetMode('USB', 2400);
    m := Rig.GetMode(w);
    WriteLn(Format('  SetMode(USB,2400) -> GetMode() = %s / width=%d', [m, w]));
    Check(m = 'USB', 'SetMode/GetMode でモード文字列が往復する (USB)');

    Rig.SetMode('CW', 500);
    m := Rig.GetMode(w);
    WriteLn(Format('  SetMode(CW,500) -> GetMode() = %s / width=%d', [m, w]));
    Check(m = 'CW', 'SetMode/GetMode でモード文字列が往復する (CW)');

    // --- PTT ---
    Check(not Rig.GetPTT, 'Open直後の GetPTT は false (送信していない)');
    Rig.SetPTT(True);
    Check(Rig.GetPTT, 'SetPTT(True) 後、GetPTT が true になる');
    Rig.SetPTT(False);
    Check(not Rig.GetPTT, 'SetPTT(False) 後、GetPTT が false に戻る');

    // --- VFO ---
    Rig.SetVFO(rvA);
    WriteLn('  SetVFO(rvA) -> GetVFO() = ', Ord(Rig.GetVFO));

    // --- ConfStr (rig_pathname を読み書きして conf 汎用アクセスを確認) ---
    try
      Rig.SetConfStr('rig_pathname', '/dev/ttyDUMMY');
      confVal := Rig.GetConfStr('rig_pathname');
      WriteLn('  SetConfStr/GetConfStr(rig_pathname) = ', confVal);
      Check(confVal = '/dev/ttyDUMMY', 'SetConfStr/GetConfStr が往復する');
    except
      on E: Exception do
        Check(False, 'SetConfStr/GetConfStr で例外: ' + E.Message);
    end;

    // --- GetNativeHandle (エスケープハッチ確認) ---
    Check(Rig.GetNativeHandle <> nil, 'GetNativeHandle が非nilを返す');

    Rig.Close;
    Check(not Rig.IsOnLine, 'Close 後は IsOnLine = False');
  finally
    Rig.Free;
  end;
  WriteLn;
end;

{ ---------------------------------------------------------------------------
  4. TRigPollThread の動作検証

  TRigPollThread のイベント型 (TRigFreqEvent 等) は「of object」の
  メソッドポインタなので、単純な手続き (@OnPollFreqChanged 形式) では
  代入できない。テスト用のイベントシンクをオブジェクトとして用意する。
  --------------------------------------------------------------------------- }
type
  TPollEventSink = class
  public
    FreqEventCount: Integer;
    LastFreq: Double;
    ModeEventCount: Integer;
    ErrorCount: Integer;
    procedure OnPollFreqChanged(Sender: TRigPollThread; FreqHz: Double);
    procedure OnPollModeChanged(Sender: TRigPollThread; const Mode: string; Width: Integer);
    procedure OnPollError(Sender: TRigPollThread; const Msg: string);
  end;

procedure TPollEventSink.OnPollFreqChanged(Sender: TRigPollThread; FreqHz: Double);
begin
  Inc(FreqEventCount);
  LastFreq := FreqHz;
  WriteLn(Format('  [イベント] OnFreqChanged: %.0f Hz (%d回目)', [FreqHz, FreqEventCount]));
end;

procedure TPollEventSink.OnPollModeChanged(Sender: TRigPollThread; const Mode: string; Width: Integer);
begin
  Inc(ModeEventCount);
  WriteLn(Format('  [イベント] OnModeChanged: %s / width=%d (%d回目)', [Mode, Width, ModeEventCount]));
end;

procedure TPollEventSink.OnPollError(Sender: TRigPollThread; const Msg: string);
begin
  Inc(ErrorCount);
  WriteLn('  [イベント] OnError: ', Msg);
end;

procedure TestPollThread;
var
  Rig: THamlibRigControl;
  Poll: TRigPollThread;
  Sink: TPollEventSink;
  i: Integer;
begin
  WriteLn('--- 4. TRigPollThread による定期ポーリング動作の検証 ---');

  Rig := THamlibRigControl.Create(RIG_MODEL_DUMMY);
  Poll := nil;
  Sink := TPollEventSink.Create;
  try
    Rig.Device := '';
    Check(Rig.Open, 'Open が成功する (ポーリングテスト用)');
    Rig.SetFreq(10000000.0);
    Rig.SetMode('USB', 2400);

    Poll := TRigPollThread.Create(Rig);
    Poll.PollIntervalMs := 100; // テスト高速化のため短めに設定
    Poll.OnFreqChanged := @Sink.OnPollFreqChanged;
    Poll.OnModeChanged := @Sink.OnPollModeChanged;
    Poll.OnError := @Sink.OnPollError;
    Poll.Start;

    // ポーリング開始直後、初回の周波数/モード変化イベントを待つ
    for i := 1 to 20 do
    begin
      Sleep(100);
      if (Sink.FreqEventCount > 0) and (Sink.ModeEventCount > 0) then Break;
    end;
    Check(Sink.FreqEventCount > 0, '初回ポーリングで OnFreqChanged が発火する');
    Check(Sink.ModeEventCount > 0, '初回ポーリングで OnModeChanged が発火する');
    Check(Abs(Sink.LastFreq - 10000000.0) < 1.0, 'ポーリングで取得した周波数が一致する');

    // 裏で周波数を変更し、ポーリングスレッドが変化を検出できるか確認
    WriteLn('  周波数を 21000000 Hz に変更し、ポーリングでの検出を待ちます...');
    Rig.SetFreq(21000000.0);
    for i := 1 to 20 do
    begin
      Sleep(100);
      if Abs(Sink.LastFreq - 21000000.0) < 1.0 then Break;
    end;
    Check(Abs(Sink.LastFreq - 21000000.0) < 1.0, '周波数変更がポーリングスレッド経由で検出される');

    // Bypass (PTT送信中の監視休止) の動作確認
    Poll.Bypass := True;
    Sink.FreqEventCount := 0;
    Rig.SetFreq(28000000.0);
    Sleep(500);
    Check(Sink.FreqEventCount = 0, 'Bypass=True の間はポーリングイベントが発火しない');
    Poll.Bypass := False;
    for i := 1 to 20 do
    begin
      Sleep(100);
      if Abs(Sink.LastFreq - 28000000.0) < 1.0 then Break;
    end;
    Check(Abs(Sink.LastFreq - 28000000.0) < 1.0, 'Bypass=False に戻すとポーリングが再開する');

    Poll.Terminate;
    Poll.WaitFor;
    Rig.Close;
  finally
    Poll.Free;
    Rig.Free;
    Sink.Free;
  end;
  WriteLn;
end;

begin
  // Hamlib の内部デバッグログ (rig_debug) はデフォルトで詳細度が高く
  // テスト結果の標準出力を埋めてしまうため、抑制しておく
  // (fldigi も起動時に rig_set_debug(RIG_DEBUG_NONE) 相当の設定を行う)。
  rig_set_debug(RIG_DEBUG_NONE);

  WriteLn('=== Hamlib CAT制御バインディング 検証 (RIG_MODEL_DUMMY 疑似CAT通信) ===');
  WriteLn;
  FailCount := 0;

  TestEnumerateRigs;
  TestDummyRigBasicCat;
  TestPollThread;

  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 ===');
  if FailCount > 0 then
    Halt(1);
end.
