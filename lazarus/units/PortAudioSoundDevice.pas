{ ============================================================================
  PortAudioSoundDevice.pas

  fldigi の src/include/sound.h (class SoundPort, USE_PORTAUDIO) /
  src/soundcard/sound.cxx (SoundPort::Open/Close/Read/Write) を
  Lazarus/FPC 向けに移植した「実サウンドカードI/O」の具象実装。

  TCustomSoundDevice (SoundIntf.pas) を継承し、PortAudioBindings.pas 経由で
  PortAudio C API (ブロッキング read/write ストリームモード) を呼び出す。
  Windows / Linux / macOS のいずれでも同じソースでビルドできる
  (クロスプラットフォーム) ことを目的とする。

  fldigi との対応:
  ----------------------------------------------------------------------------
  - fldigi は SoundPort 1インスタンスで RX/TX 両方向 (sd[0]=RX, sd[1]=TX) を
    フルデュプレックスに扱うが、本移植版は TCustomSoundDevice の
    「1インスタンス=1方向 (Open の Direction 引数で決まる)」という
    シンプルな設計に合わせて実装する。RX/TX を両方使う場合は
    TPortAudioSoundDevice を2つ生成し (受信用・送信用)、それぞれ
    Open(sdRead,...) / Open(sdWrite,...) を呼ぶ。
  - サンプル形式は fldigi と同じ Float32 (paFloat32) を使用し、
    モデム側の Double 配列との間で単純にキャストして変換する。
  - PortAudio の「ブロッキング read/write ストリーム」モード
    (streamCallback = nil で Pa_OpenStream) を使用する。
    fldigi の SoundPort もコールバックストリーム + リングバッファという
    より高度な構成だが、本移植版は ModemEngine.pas が既に専用スレッドで
    RxLoopStep/TxLoopStep を回す設計になっているため、単純な
    ブロッキングI/Oで十分に要件を満たす。
  - デバイス選択: コンストラクタでデバイス名 (PaDeviceInfo.name の部分一致)
    を指定できる。空文字列を渡すとその方向の既定デバイス
    (Pa_GetDefaultInputDevice/Pa_GetDefaultOutputDevice) を使用する
    (fldigi の "default" デバイス指定に相当)。

  スレッド安全性について:
  ----------------------------------------------------------------------------
  - Pa_Initialize()/Pa_Terminate() はプロセス全体で一度だけ対にして
    呼ぶ必要がある (PortAudio の仕様)。本ユニットは参照カウント
    (PortAudioRefCount) でラップした ClassInitialize/ClassTerminate を
    提供し、複数の TPortAudioSoundDevice インスタンスが安全に
    生成・解放されるようにしている。
  ============================================================================ }
unit PortAudioSoundDevice;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, SoundIntf, PortAudioBindings;

type
  { PortAudio API 呼び出しが失敗した際に発生する例外
    (fldigi: class SndPortException) }
  EPortAudioError = class(ESoundError)
  private
    FErrorCode: PaError;
  public
    constructor Create(AErrorCode: PaError; const AContext: string);
    property ErrorCode: PaError read FErrorCode;
  end;

  { TPaDeviceEntry
    Pa_GetDeviceInfo() の結果を Pascal 側で保持しやすい形にコピーしたもの
    (PaDeviceInfo へのポインタは Pa_Terminate() 後に無効になるため、
    デバイス一覧表示用に文字列・数値へコピーしておく)。 }
  TPaDeviceEntry = record
    Index: Integer;
    Name: string;
    MaxInputChannels: Integer;
    MaxOutputChannels: Integer;
    DefaultSampleRate: Double;
  end;
  TPaDeviceEntryArray = array of TPaDeviceEntry;

  { TPortAudioSoundDevice
    ---------------------------------------------------------------------
    fldigi: class SoundPort (sound.h) の Read/Write 部分に相当する
    「1方向 (RX または TX) のブロッキングストリーム」実装。 }
  TPortAudioSoundDevice = class(TCustomSoundDevice)
  private
    FStream: PPaStream;
    FDirection: TSoundDirection;
    FDeviceName: string;      // 空文字列 = 既定デバイス
    FResolvedDeviceIndex: PaDeviceIndex;
    FLatencySec: Double;      // fldigi: progdefaults.txoffset 相当ではないが、
                               // suggestedLatency (既定 0.1秒 = 低レイテンシ)
    { --- ストリーム寿命と入出力の直列化 (AUD-07) ---
      Close/AbortIO と Read/Write が同じハンドルを同時に触らないようにする。
      ただしブロッキング中の Pa_ReadStream をロックの中で行うと AbortIO 側が
      待たされて解除できないため、「ハンドルの取得・差し替えだけをロックで
      守り、実際の入出力はロック外で行う」方式を採る。入出力中のスレッド数を
      FIoActive で数え、Close はそれが 0 になるまで実解放を遅らせる。 }
    FLock: TCriticalSection;
    FIoActive: Integer;       // ブロッキング入出力を実行中のスレッド数
    FClosing: Boolean;        // Close/AbortIO 進行中 (新規の入出力を拒む)
    { Open と Close (と Open 冒頭の暗黙 Close) が交錯すると
      「閉じたつもりで開いている」状態が残る。ストリームの生成・破棄という
      粒度の粗い操作は、この専用ロックで丸ごと直列化する。
      ブロッキング入出力はこのロックを取らないので、Close は待たされない。 }
    FLifecycleLock: TCriticalSection;
    { X-04: realtime 経路での動的確保を避けるための変換バッファ。
      以前は ReadSamples / WriteSamples が呼び出しのたびにローカルの
      動的配列を SetLength していた。8000Hz / 512サンプルなら毎秒 16 回、
      さらに送信側でも同数の確保・解放が走る。FPC のメモリマネージャは
      ロックを取るので、これが音声スレッドの deadline を脅かす
      (Z-04 Deterministic Realtime)。
      Open 時に必要量を確保し、以後は伸ばすだけにする。

      【前提】1インスタンスは1方向 (Open の Direction で決まる) であり、
      その方向の入出力は単一スレッドから行う。エンジンは RX 用と TX 用の
      デバイスを別インスタンスで持つ設計なので、この前提は満たされる。 }
    FIoBuf: array of Single;
    procedure EnsureIoBuf(ANeeded: Integer);
    procedure DoClose;
    function FindDeviceIndex(const ANamePart: string; ANeedInput: Boolean): PaDeviceIndex;
    procedure CheckPaError(AErr: PaError; const AContext: string);
    { 入出力を開始してよければ True を返し、使用するハンドルを AStream に
      設定して FIoActive を 1 増やす。呼び出し側は必ず EndIo を呼ぶこと。 }
    function BeginIo(out AStream: PPaStream): Boolean;
    procedure EndIo;
    { 実行中の入出力がすべて抜けるまで待つ (最大 ATimeoutMs)。
      戻り値: すべて抜けたか。False ならハンドルはまだ使用中である。 }
    function WaitForIoIdle(ATimeoutMs: Integer): Boolean;
  public
    constructor Create; override;
    constructor Create(const ADeviceName: string); reintroduce;
    destructor Destroy; override;

    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; override;
    procedure Close; override;
    procedure AbortIO; override;
    function ReadSamples(var Buf: array of Double; Count: Integer): Integer; override;
    function WriteSamples(const Buf: array of Double; Count: Integer): Integer; override;
    function WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer; override;
    procedure Flush; override;

    { fldigi: SoundPort::devices() 相当。PortAudio が初期化済みでなければ
      内部で一時的に初期化して取得する。 }
    class function EnumerateDevices: TPaDeviceEntryArray;

    property DeviceName: string read FDeviceName write FDeviceName;
    property LatencySec: Double read FLatencySec write FLatencySec;
    property ResolvedDeviceIndex: PaDeviceIndex read FResolvedDeviceIndex;
  end;

{ PortAudio ライブラリ全体の初期化/終了。通常はアプリ起動時に一度
  PortAudioLibInit を呼び、終了時に PortAudioLibDone を呼ぶ
  (Lazarus フォームの FormCreate/FormDestroy 等)。
  TPortAudioSoundDevice.Create は内部でも参照カウント管理しているため、
  呼び忘れても動作するが、明示的に呼ぶ方が起動失敗を早期検出できる。 }
procedure PortAudioLibInit;
procedure PortAudioLibDone;

implementation

const
  { X-04: Open 時に先取りするフレーム数。ModemEngine の
    MODEM_BLOCK_SIZE (512) に合わせてある。これより大きいブロックが
    来たら EnsureIoBuf が一度だけ伸ばす。 }
  DEFAULT_IO_FRAMES = 512;

var
  GRefLock: TCriticalSection;
  GRefCount: Integer = 0;
  GInitialized: Boolean = False;

procedure PaRefAcquire;
var
  err: PaError;
begin
  GRefLock.Enter;
  try
    if GRefCount = 0 then
    begin
      { 以前は条件式と例外生成で Pa_Initialize を 2 回呼んでいた。
        PortAudio 側も内部で参照カウントを持つため二重初期化になり、
        しかも 2 回目は成功するのでエラー文言が
        "PortAudio error in Pa_Initialize: 0 (Success)" という
        意味不明なものになっていた。 }
      err := Pa_Initialize;
      if err <> paNoError then
        raise EPortAudioError.Create(err, 'Pa_Initialize');
      GInitialized := True;
    end;
    Inc(GRefCount);
  finally
    GRefLock.Leave;
  end;
end;

procedure PaRefRelease;
begin
  GRefLock.Enter;
  try
    if GRefCount > 0 then
      Dec(GRefCount);
    if (GRefCount = 0) and GInitialized then
    begin
      Pa_Terminate;
      GInitialized := False;
    end;
  finally
    GRefLock.Leave;
  end;
end;

procedure PortAudioLibInit;
begin
  PaRefAcquire;
end;

procedure PortAudioLibDone;
begin
  PaRefRelease;
end;

{ EPortAudioError }

constructor EPortAudioError.Create(AErrorCode: PaError; const AContext: string);
begin
  FErrorCode := AErrorCode;
  inherited CreateFmt('PortAudio error in %s: %d (%s)',
    [AContext, AErrorCode, Pa_GetErrorText(AErrorCode)]);
end;

{ TPortAudioSoundDevice }

constructor TPortAudioSoundDevice.Create;
begin
  Create('');
end;

constructor TPortAudioSoundDevice.Create(const ADeviceName: string);
begin
  inherited Create;
  FDeviceName := ADeviceName;
  FStream := nil;
  FResolvedDeviceIndex := paNoDevice;
  FLatencySec := 0.1; // 既定 100ms (fldigi の defaultLowLatency相当より少し安全側)
  FLock := TCriticalSection.Create;
  FLifecycleLock := TCriticalSection.Create;
  FIoActive := 0;
  FClosing := False;
  PaRefAcquire;
end;

destructor TPortAudioSoundDevice.Destroy;
begin
  { AUD-04/AUD-07: IsOpen だけを見て Close を飛ばすと、Pa_StartStream 失敗後や
    AbortIO 後に「IsOpen=False なのにストリームは開いたまま」という状態を
    取りこぼし、開いたまま Pa_Terminate へ進んでいた。ハンドルの有無で判断する。 }
  try
    { Close は入出力が終わらないと例外を投げうる (使用中のストリームを
      解放しないため)。破棄処理自体は最後まで進める必要があるので、
      ここでは握り潰す。 }
    Close;
  except
    on E: Exception do ;
  end;
  PaRefRelease;
  FLock.Free;
  FLifecycleLock.Free;
  inherited Destroy;
end;

procedure TPortAudioSoundDevice.EnsureIoBuf(ANeeded: Integer);
{ 伸ばすだけ。縮めないのは、ブロック長が変動しても確保が再発しないようにするため。 }
begin
  if Length(FIoBuf) < ANeeded then
    SetLength(FIoBuf, ANeeded);
end;

function TPortAudioSoundDevice.BeginIo(out AStream: PPaStream): Boolean;
begin
  FLock.Enter;
  try
    Result := (FStream <> nil) and IsOpen and (not FClosing);
    if Result then
    begin
      AStream := FStream;
      Inc(FIoActive);
    end
    else
      AStream := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TPortAudioSoundDevice.EndIo;
begin
  FLock.Enter;
  try
    if FIoActive > 0 then
      Dec(FIoActive);
  finally
    FLock.Leave;
  end;
end;

function TPortAudioSoundDevice.WaitForIoIdle(ATimeoutMs: Integer): Boolean;
var
  waited: Integer;
  busy: Boolean;
begin
  waited := 0;
  repeat
    FLock.Enter;
    try
      busy := FIoActive > 0;
    finally
      FLock.Leave;
    end;
    if not busy then Exit(True);
    Sleep(1);
    Inc(waited);
  until waited >= ATimeoutMs;
  Result := False;
end;

procedure TPortAudioSoundDevice.CheckPaError(AErr: PaError; const AContext: string);
begin
  if AErr <> paNoError then
    raise EPortAudioError.Create(AErr, AContext);
end;

function TPortAudioSoundDevice.FindDeviceIndex(const ANamePart: string;
  ANeedInput: Boolean): PaDeviceIndex;
var
  n, i: Integer;
  di: PPaDeviceInfo;
  DevName: string;
begin
  if ANamePart = '' then
  begin
    if ANeedInput then
      Result := Pa_GetDefaultInputDevice
    else
      Result := Pa_GetDefaultOutputDevice;
    Exit;
  end;

  Result := paNoDevice;
  n := Pa_GetDeviceCount;
  for i := 0 to n - 1 do
  begin
    di := Pa_GetDeviceInfo(i);
    if di = nil then Continue;
    DevName := di^.name;
    if ((ANeedInput and (di^.maxInputChannels > 0)) or
        ((not ANeedInput) and (di^.maxOutputChannels > 0))) and
       (Pos(LowerCase(ANamePart), LowerCase(DevName)) > 0) then
    begin
      Result := i;
      Exit;
    end;
  end;
  // 見つからなければ既定デバイスにフォールバック
  if ANeedInput then
    Result := Pa_GetDefaultInputDevice
  else
    Result := Pa_GetDefaultOutputDevice;
end;

function TPortAudioSoundDevice.Open(Direction: TSoundDirection;
  ASampleRate: Integer): Boolean;
var
  Params: TPaStreamParameters;
  ErrCode: PaError;
  IsInput: Boolean;
  di: PPaDeviceInfo;
  LocalStream: PPaStream;
begin
  Result := False;
  FLifecycleLock.Enter;
  try
    DoClose;

    FDirection := Direction;
    IsInput := (Direction = sdRead);
    FResolvedDeviceIndex := FindDeviceIndex(FDeviceName, IsInput);
    if FResolvedDeviceIndex = paNoDevice then
      raise EPortAudioError.Create(PaError(-1), 'FindDeviceIndex (デバイスが見つからない)');

    if Channels < 1 then
      raise ESoundError.CreateFmt('チャネル数が不正です: %d', [Channels]);

    FillChar(Params, SizeOf(Params), 0);
    Params.device := FResolvedDeviceIndex;
    Params.channelCount := Channels; // TCustomSoundDevice.Channels (既定1=モノラル)
    Params.sampleFormat := paFloat32;
    Params.suggestedLatency := FLatencySec;
    Params.hostApiSpecificStreamInfo := nil;

    di := Pa_GetDeviceInfo(FResolvedDeviceIndex);
    if di <> nil then
    begin
      { AUD-03: 出力にも defaultLowInputLatency を使っていたため、出力側の
        レイテンシ指定が実態と合っていなかった。方向ごとの既定値を使う。 }
      if IsInput then
        Params.suggestedLatency := di^.defaultLowInputLatency
      else
        Params.suggestedLatency := di^.defaultLowOutputLatency;
      if (IsInput and (di^.maxInputChannels < Channels)) or
         ((not IsInput) and (di^.maxOutputChannels < Channels)) then
        raise ESoundError.CreateFmt(
          'デバイスが要求チャネル数に対応していません (要求 %d)', [Channels]);
    end;

    { AUD-04: ローカルハンドルで組み立て、全段成功して初めてコミットする。
      以前は Pa_OpenStream 成功後に Pa_StartStream が失敗すると、FStream に
      ハンドルが残ったまま IsOpen は False になり、デストラクタが Close を
      飛ばして「開いたまま Pa_Terminate」になっていた。 }
    LocalStream := nil;
    if IsInput then
      ErrCode := Pa_OpenStream(LocalStream, @Params, nil, ASampleRate,
        paFramesPerBufferUnspecified, 0, nil, nil)
    else
      ErrCode := Pa_OpenStream(LocalStream, nil, @Params, ASampleRate,
        paFramesPerBufferUnspecified, 0, nil, nil);
    CheckPaError(ErrCode, 'Pa_OpenStream');

    ErrCode := Pa_StartStream(LocalStream);
    if ErrCode <> paNoError then
    begin
      { 開いてしまったストリームを必ず片付けてから例外にする。 }
      Pa_CloseStream(LocalStream);
      raise EPortAudioError.Create(ErrCode, 'Pa_StartStream');
    end;

    FLock.Enter;
    try
      FStream := LocalStream;
      FClosing := False;
      SampleRate := ASampleRate;
      IsOpenFlag := True;
    finally
      FLock.Leave;
    end;
    { X-04: 想定ブロック長ぶんを先に確保し、以後の入出力で確保が
      走らないようにする。足りなければ EnsureIoBuf が伸ばす。 }
    EnsureIoBuf(DEFAULT_IO_FRAMES * Channels);
    Result := True;
  finally
    FLifecycleLock.Leave;
  end;
end;

procedure TPortAudioSoundDevice.Close;
begin
  { Open との交錯を防ぐため、ストリームの生成・破棄は直列化する。 }
  FLifecycleLock.Enter;
  try
    DoClose;
  finally
    FLifecycleLock.Leave;
  end;
end;

procedure TPortAudioSoundDevice.DoClose;
{ AUD-07: ブロッキング入出力中に呼ばれても安全に閉じる。
  手順は「新規入出力を止める → 実行中のブロッキング呼び出しを
  Pa_AbortStream で解除する → 全員が抜けるまで待つ → 実際に閉じる」。
  実行中スレッドはローカルにハンドルを保持しているため、最後まで
  待ってから Pa_CloseStream しないと解放済みハンドルを触ることになる。
  呼び出し元は FLifecycleLock を保持していること。 }
const
  IO_DRAIN_TIMEOUT_MS = 2000;
var
  h: PPaStream;
  drained: Boolean;
begin
  FLock.Enter;
  try
    h := FStream;
    FStream := nil;        // これ以降の BeginIo は失敗する
    FClosing := True;
    IsOpenFlag := False;
  finally
    FLock.Leave;
  end;

  if h = nil then
  begin
    FLock.Enter;
    try
      FClosing := False;
    finally
      FLock.Leave;
    end;
    Exit;
  end;

  { ブロッキング中の Pa_ReadStream/Pa_WriteStream を解除する。
    戻り値は見ない (既に停止しているケースもあるため)。 }
  Pa_AbortStream(h);
  drained := WaitForIoIdle(IO_DRAIN_TIMEOUT_MS);

  FLock.Enter;
  try
    FClosing := False;
  finally
    FLock.Leave;
  end;

  if not drained then
  begin
    { まだ Pa_ReadStream/Pa_WriteStream の中にいるスレッドが、このハンドルを
      ローカル変数で保持している。ここで Pa_CloseStream すると
      「使用中のストリームを解放する」ことになり未定義動作になるので、
      あえてハンドルを解放しない (漏らす)。デバイスの抜去などで
      PortAudio が戻ってこないときにだけ起きる異常系であり、
      1個のストリームを漏らす方がクラッシュより害が小さい。
      黙って続行はせず、呼び出し元に事実を伝える。 }
    raise ESoundError.CreateFmt(
      'サウンドストリームを閉じられませんでした: 入出力が %d ms 以内に ' +
      '終了しません (デバイスが応答していない可能性があります)',
      [IO_DRAIN_TIMEOUT_MS]);
  end;

  Pa_StopStream(h);   // エラーは無視 (fldigi: Close() も戻り値を見ない)
  Pa_CloseStream(h);
end;

procedure TPortAudioSoundDevice.AbortIO;
{ AUD-07: 以前は Pa_AbortStream を呼んで IsOpen=False にするだけで、
  ハンドルを閉じalso nil 化もしていなかった。結果、その後デストラクタが
  Close を飛ばし、開いたままのストリームを残して Pa_Terminate に進んでいた。
  AbortIO は「ブロッキング入出力を直ちに解除して閉じる」と定義し、
  Close に処理を委ねる。 }
begin
  Close;
end;

function TPortAudioSoundDevice.ReadSamples(var Buf: array of Double;
  Count: Integer): Integer;
{ AUD-06: Pa_ReadStream の第3引数は「サンプル数」ではなく「フレーム数」で、
  実際には frames x Channels 個のサンプルが書き込まれる。以前は Count 個
  しか確保していなかったため、Channels>1 でヒープを破壊していた。
  多チャネル入力からは先頭チャネル (ch0) を取り出してモノラルとして返す。
  AUD-05: Count の範囲検査も行う。 }
var
  i, ch: Integer;
  ErrCode: PaError;
  h: PPaStream;
begin
  Result := 0;
  if not ValidateIoCount(Count, Length(Buf), 'ReadSamples') then Exit;
  if not BeginIo(h) then Exit;
  try
    ch := Channels;
    if ch < 1 then ch := 1;
    EnsureIoBuf(Count * ch);   // X-04: 通常は既に足りていて何もしない

    ErrCode := Pa_ReadStream(h, @FIoBuf[0], culong(Count));
    // paInputOverflowed はデータ自体は取得できているため致命的エラーとしない
    // (fldigi: SoundPort::Read も同様に overflow を許容してログのみ出す)
    if (ErrCode <> paNoError) and (ErrCode <> paInputOverflowed) then
      raise EPortAudioError.Create(ErrCode, 'Pa_ReadStream');

    for i := 0 to Count - 1 do
      Buf[i] := FIoBuf[i * ch];   // インターリーブの先頭チャネル
    Result := Count;
  finally
    EndIo;
  end;
end;

function TPortAudioSoundDevice.WriteSamples(const Buf: array of Double;
  Count: Integer): Integer;
{ AUD-06: Pa_WriteStream もフレーム単位なので、Channels>1 のストリームへは
  frames x Channels 個のサンプルを渡す必要がある。以前は多チャネル時に
  インターリーブせず Count 個だけ渡していたため、再生内容が壊れていた。
  モノラル入力は全チャネルへ複製する。 }
var
  i, c, ch: Integer;
  ErrCode: PaError;
  h: PPaStream;
begin
  Result := 0;
  if not ValidateIoCount(Count, Length(Buf), 'WriteSamples') then Exit;
  if not BeginIo(h) then Exit;
  try
    ch := Channels;
    if ch < 1 then ch := 1;
    EnsureIoBuf(Count * ch);   // X-04
    for i := 0 to Count - 1 do
      for c := 0 to ch - 1 do
        FIoBuf[i * ch + c] := Buf[i];

    ErrCode := Pa_WriteStream(h, @FIoBuf[0], culong(Count));
    if (ErrCode <> paNoError) and (ErrCode <> paOutputUnderflowed) then
      raise EPortAudioError.Create(ErrCode, 'Pa_WriteStream');

    Result := Count;
  finally
    EndIo;
  end;
end;

function TPortAudioSoundDevice.WriteStereo(const BufL, BufR: array of Double;
  Count: Integer): Integer;
{ AUD-06: 「Channels=2 でOpenされている前提」を検証していなかったため、
  モノラルで開いたストリームへ 2 倍のデータを渡すと壊れていた。
  両バッファの長さも検証する。 }
var
  i: Integer;
  ErrCode: PaError;
  h: PPaStream;
begin
  Result := 0;
  if not ValidateIoCount(Count, Length(BufL), 'WriteStereo(L)') then Exit;
  if Count > Length(BufR) then
    raise ESoundError.CreateFmt(
      'WriteStereo: R チャネルのバッファ長が不足しています (要求 %d / バッファ %d)',
      [Count, Length(BufR)]);
  if Channels <> 2 then
    raise ESoundError.CreateFmt(
      'WriteStereo にはステレオ (Channels=2) で開いたストリームが必要です (現在 %d)',
      [Channels]);
  if not BeginIo(h) then Exit;
  try
    // インターリーブ (L,R,L,R,...) で書き込む
    EnsureIoBuf(Count * 2);   // X-04
    for i := 0 to Count - 1 do
    begin
      FIoBuf[i * 2] := BufL[i];
      FIoBuf[i * 2 + 1] := BufR[i];
    end;

    ErrCode := Pa_WriteStream(h, @FIoBuf[0], culong(Count));
    if (ErrCode <> paNoError) and (ErrCode <> paOutputUnderflowed) then
      raise EPortAudioError.Create(ErrCode, 'Pa_WriteStream (stereo)');

    Result := Count;
  finally
    EndIo;
  end;
end;

procedure TPortAudioSoundDevice.Flush;
begin
  // PortAudio のブロッキング書き込みストリームには明示的な flush API が無い
  // (Pa_WriteStream は呼び出しがブロックして書き切るまで返らないため、
  //  戻った時点で全データはOS側バッファへ渡っている)。
  // fldigi の SoundPort::flush() もリングバッファのドレインのみで
  // 同様に「待つだけ」の処理のため、ここでは何もしない。
end;

class function TPortAudioSoundDevice.EnumerateDevices: TPaDeviceEntryArray;
var
  NeedTerm: Boolean;
  n, i: Integer;
  di: PPaDeviceInfo;
begin
  Result := nil;
  { 以前は GRefCount を見て自前で Pa_Initialize/Pa_Terminate していたため、
    列挙中に他スレッドがデバイスを開くと、この関数の Pa_Terminate が
    そのストリームごと PortAudio を落としていた。参照カウントに一本化する。 }
  NeedTerm := False;
  try
    PaRefAcquire;
    NeedTerm := True;
  except
    on E: Exception do
      Exit;   // PortAudio が使えない環境では空リストを返す
  end;

  try
    n := Pa_GetDeviceCount;
    if n < 0 then Exit;
    SetLength(Result, n);
    for i := 0 to n - 1 do
    begin
      di := Pa_GetDeviceInfo(i);
      Result[i].Index := i;
      if di <> nil then
      begin
        Result[i].Name := di^.name;
        Result[i].MaxInputChannels := di^.maxInputChannels;
        Result[i].MaxOutputChannels := di^.maxOutputChannels;
        Result[i].DefaultSampleRate := di^.defaultSampleRate;
      end;
    end;
  finally
    if NeedTerm then
      PaRefRelease;
  end;
end;

initialization
  GRefLock := TCriticalSection.Create;

finalization
  GRefLock.Free;

end.
