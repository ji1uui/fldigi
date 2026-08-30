{ ============================================================================
  AudioCapture.pas

  Architecture & Requirements Baseline v1.1 §4 X-01

      Audio I/O 専用経路を DSP 重処理から分離する。

  と、Phase 1 の完了条件「長時間受信で dropout がない」の実体。

  何を分離するのか
  ----------------------------------------------------------------------------
  これまで TModemEngine.RxLoopStep は

      ReadSamples() でブロックして読む → その場で RxProcess() で復調

  という一本道だった。この形は **復調にかかった時間だけ次の読み出しが
  遅れる**。音声デバイスは待ってくれないので、遅れた分の音は
  デバイス側のバッファから溢れて消える。しかも消えたことは
  こちら側に伝わらない ── 「なんとなく復調率が悪い」という形でしか出ない。

  そこで読み出しだけを別スレッドにする。

      [取り込みスレッド]  ReadSamples → リングへ書く      (軽い・止まらない)
      [復調スレッド]      リングから読む → RxProcess      (重い・遅れてよい)

  復調が一時的に遅れてもリングが吸収する。リングも溢れれば落ちるが、
  そのときは **何サンプル落ちたかが数として残る** (ADR-010)。
  「たぶん大丈夫」ではなく「何件落ちた」と言えるようになる。

  取り込みスレッドがやってはいけないこと
  ----------------------------------------------------------------------------
  このスレッドが止まると、その間の音はデバイス側で失われる。だから

    - 確保しない (X-04)。バッファは生成時に確保し、以後伸ばさない。
    - 待たない。リングが満杯でも待たず、捨てて数える (WriteOrDrop)。
    - 重い処理をしない。復調も解析もここではやらない。

  ここに「ついでに何かする」を足したくなるが、足した分だけ
  取りこぼしの原因が増える。History への複写だけは例外で、これは
  Replay (X-06) に必要な最小限であり、単純な複写しかしない。

  停止のしかた
  ----------------------------------------------------------------------------
  ReadSamples はブロックするので、Terminate だけでは抜けられない。
  デバイスの AbortIO を叩いて I/O ごと解除する。SoundIntf の規約どおり
  「解除のためにストリームを閉じてよい」ので、停止後の再利用は
  Open からやり直す。
  ============================================================================ }
unit AudioCapture;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SoundIntf, AudioRing, Observability;

const
  { 1 回の読み出し長。小さすぎると syscall が増え、大きすぎると
    リングへ届くまでの遅れが増える。 }
  CAPTURE_BLOCK_SIZE = 512;
  { リングの既定容量。既定のブロック長の 64 倍 = 8000Hz で約 4 秒。
    復調が数秒詰まっても吸収できる長さにしてある。 }
  DEFAULT_RING_CAPACITY = CAPTURE_BLOCK_SIZE * 64;

type
  EAudioCaptureError = class(Exception);

  { --- 取り込み専用スレッド ---
    デバイスから読んでリング (と履歴) へ渡すだけ。
    音声デバイスは借り物で、解放はしない。 }
  TAudioCapture = class(TThread)
  private
    FSound: TCustomSoundDevice;
    FRing: TAudioRing;            // 所有する
    FHistory: TAudioHistory;      // 所有する。nil なら履歴を取らない
    { 生成時に確保し、ループ中では触らない (X-04)。 }
    FBuf: array[0..CAPTURE_BLOCK_SIZE - 1] of Double;
    FTotalCaptured: Int64;
    FReadErrors: Int64;
    FIdleReads: Int64;            // 0 件しか読めなかった回数
    FStopping: Boolean;
    { TThread.Started は FPC 3.2.2 に無いので自前で持つ。
      一度も走らせていないスレッドを止めようとしないため。 }
    FStarted: Boolean;
    { nil なら測らない。エンジンと同じく外から注入する
      ── 取り込み経路が診断機構を知る必要はない。 }
    FCaptureMetric: TObsMetric;
  protected
    procedure Execute; override;
  public
    procedure Start;   { FStarted を立ててから走らせる }
    { AHistorySeconds > 0 なら履歴も持つ (X-06 / Replay)。 }
    constructor Create(ASound: TCustomSoundDevice;
      ARingCapacity: Integer = DEFAULT_RING_CAPACITY;
      AHistorySeconds: Double = 0; ASampleRate: Integer = 8000);
    destructor Destroy; override;

    { 止める。ブロック中の ReadSamples も解除する。
      Terminate だけでは読み出しから抜けられない。 }
    procedure RequestStop;

    property Ring: TAudioRing read FRing;
    { 履歴を取らない設定なら nil。 }
    property History: TAudioHistory read FHistory;
    property TotalCaptured: Int64 read FTotalCaptured;
    property ReadErrors: Int64 read FReadErrors;
    property IdleReads: Int64 read FIdleReads;
    { 1 回の読み出しにかかった時間の統計 (nil 可)。 }
    property CaptureMetric: TObsMetric read FCaptureMetric write FCaptureMetric;
    function Describe: string;
  end;

implementation

constructor TAudioCapture.Create(ASound: TCustomSoundDevice;
  ARingCapacity: Integer; AHistorySeconds: Double; ASampleRate: Integer);
begin
  if ASound = nil then
    raise EAudioCaptureError.Create('取り込み対象の音声デバイスが nil です');
  inherited Create(True);   { 停止状態で作る。Start は呼び出し側が行う }
  FreeOnTerminate := False;
  FSound := ASound;
  FRing := TAudioRing.Create(ARingCapacity);
  if AHistorySeconds > 0 then
    FHistory := TAudioHistory.ForSeconds(AHistorySeconds, ASampleRate);
end;

procedure TAudioCapture.Start;
begin
  FStarted := True;
  inherited Start;
end;

destructor TAudioCapture.Destroy;
begin
  { スレッドが動いたままだと FRing を解放した先を触りうる。
    走らせたものだけを止める ── 一度も Start していないスレッドを
    WaitFor すると戻ってこない。 }
  if FStarted and not Finished then
  begin
    RequestStop;
    WaitFor;
  end
  else if not FStarted then
    { 一度も走らせていない。TThread.Destroy が WaitFor で止まらないよう、
      走らせてから終わらせる。 }
    inherited Start;
  inherited Destroy;   { TThread.Destroy が Terminate + WaitFor を行う }
  FRing.Free;
  FHistory.Free;
end;

procedure TAudioCapture.RequestStop;
begin
  FStopping := True;
  Terminate;
  { ReadSamples はブロックする。Terminate だけでは抜けられないので
    I/O ごと叩き落とす。 }
  if (FSound <> nil) and FSound.IsOpen then
    try
      FSound.AbortIO;
    except
      { 停止手順の中の例外は握る。ここで投げても止められない。 }
    end;
end;

procedure TAudioCapture.Execute;
var
  n: Integer;
  t0: Double;
  measuring: Boolean;
begin
  while not Terminated do
  begin
    if (FSound = nil) or (not FSound.IsOpen) then
    begin
      { まだ開いていない / 閉じられた。異常ではないので待つ。 }
      Sleep(5);
      Continue;
    end;

    measuring := Assigned(FCaptureMetric);
    if measuring then
      t0 := ObsHiResSeconds;

    n := 0;
    try
      n := FSound.ReadSamples(FBuf, CAPTURE_BLOCK_SIZE);
    except
      { AbortIO による解除もここへ来る。停止中なら黙って抜ける
        ── 毎回の終了時に偽のエラーを数えないため。 }
      on E: Exception do
      begin
        if FStopping or Terminated then Break;
        Inc(FReadErrors);
        Sleep(5);
        Continue;
      end;
    end;

    if measuring then
      FCaptureMetric.Observe((ObsHiResSeconds - t0) * 1000);

    if n <= 0 then
    begin
      Inc(FIdleReads);
      { 読めるものが無い。ここで回し続けると 1 コア食い潰す。 }
      Sleep(1);
      Continue;
    end;

    Inc(FTotalCaptured, n);

    { 待たない。満杯なら捨てて数える ── 取り込みは止められない。 }
    FRing.WriteOrDrop(FBuf, n);

    { 履歴は常に全部入る (古い方を上書きするため)。 }
    if FHistory <> nil then
      FHistory.Append(FBuf, n);
  end;
end;

function TAudioCapture.Describe: string;
begin
  Result := Format('取り込み %d サンプル / 読み出し失敗 %d / 空読み %d / %s',
    [FTotalCaptured, FReadErrors, FIdleReads, FRing.Describe]);
  if FHistory <> nil then
    Result := Result + ' / ' + FHistory.Describe;
end;

end.
