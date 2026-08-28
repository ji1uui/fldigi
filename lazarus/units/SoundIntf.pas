{ ============================================================================
  SoundIntf.pas

  fldigi の src/include/sound.h (class SoundBase) を Lazarus/FPC 向けに
  移植した「サウンドカード入出力」の抽象基底クラス。

  設計方針 (fldigi との対応):
    - C++ の SoundBase (純粋仮想 Open/Close/Read/Write) を
      TCustomSoundDevice (abstract メソッド) として再現。
    - 実際のデバイス依存部 (PortAudio/ALSA/WASAPI 等) は派生クラスで実装する。
      本ユニットには「何もしない」テスト用実装 TNullSoundDevice も同梱。
    - モデム側 (TModem) はこのインターフェースだけに依存し、
      具体的なオーディオAPIには依存しない (fldigi の RXscard/TXscard と同じ役割)。
  ============================================================================ }
unit SoundIntf;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { fldigi sound.h の SoundBase::Open() 第一引数 (Mode_RX / Mode_TX) に相当 }
  TSoundDirection = (sdRead, sdWrite);

  ESoundError = class(Exception);

  { TCustomSoundDevice
    ---------------------------------------------------------------------
    fldigi: class SoundBase (sound.h)
    - サンプルレート・チャネル等の共通プロパティを保持し、
      Open/Close/Read/Write を派生クラスに強制する抽象クラス。 }
  TCustomSoundDevice = class abstract
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FIsOpen: Boolean;
  protected
    property IsOpenFlag: Boolean read FIsOpen write FIsOpen;

    { Read/Write 系に共通の引数検査 (AUD-05)。
      Count<0 や Count>バッファ長 を検証せずに @Buf[0] や Buf[i] へ
      アクセスしていたため、範囲チェックを無効にした Release ビルドでは
      メモリ破壊になっていた。Count=0 でも空配列の先頭アドレスを
      C API へ渡していた。
      戻り値: True なら処理を続行してよい。False は「Count=0 なので
      何もせず 0 件成功として返す」ことを意味する。
      不正な値 (負数 / バッファ長超過 / 未Open) は ESoundError を送出する。 }
    function ValidateIoCount(ACount, ABufLen: Integer;
      const AOpName: string): Boolean;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { fldigi: virtual int Open(int mode, int freq) }
    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; virtual; abstract;
    { fldigi: virtual void Close(unsigned dir) }
    procedure Close; virtual; abstract;
    { fldigi: virtual void Abort(unsigned dir)
      進行中のブロッキング入出力を直ちに解除する。エンジンの終了時に
      ワーカーが Read/Write の中で止まったままにならないようにするための
      入口であり、「解除のためにストリームを閉じてよい」と定義する
      (= 呼び出し後は IsOpen が False になりうる)。
      再び使うには Open からやり直すこと。 }
    procedure AbortIO; virtual; abstract;

    { fldigi: virtual size_t Read(float *buf, size_t count)
      戻り値: 実際に読み込んだサンプル数 }
    function ReadSamples(var Buf: array of Double; Count: Integer): Integer; virtual; abstract;

    { fldigi: virtual size_t Write(double *buf, size_t count) }
    function WriteSamples(const Buf: array of Double; Count: Integer): Integer; virtual; abstract;

    { fldigi: virtual size_t Write_stereo(double *L, double *R, size_t count) }
    function WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer; virtual; abstract;

    { fldigi: virtual void flush(unsigned dir) }
    procedure Flush; virtual; abstract;

    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property IsOpen: Boolean read FIsOpen;
  end;

  { TNullSoundDevice
    ---------------------------------------------------------------------
    fldigi: class SoundNull (sound.h)
    デバイスを一切使わないダミー実装。単体テストや GUI 無し環境での
    モデムエンジン検証に使用する。 }
  TNullSoundDevice = class(TCustomSoundDevice)
  public
    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; override;
    procedure Close; override;
    procedure AbortIO; override;
    function ReadSamples(var Buf: array of Double; Count: Integer): Integer; override;
    function WriteSamples(const Buf: array of Double; Count: Integer): Integer; override;
    function WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer; override;
    procedure Flush; override;
  end;

implementation

{ TCustomSoundDevice }

constructor TCustomSoundDevice.Create;
begin
  inherited Create;
  FSampleRate := 8000;
  FChannels := 1;
  FIsOpen := False;
end;

destructor TCustomSoundDevice.Destroy;
begin
  { 派生クラスは自分のデストラクタで確実に解放し切ること。ここでの
    Close は「解放し忘れ」に対する最後の保険であり、派生クラスの
    フィールドが既に無効な状態で仮想メソッドを呼ぶ可能性があるため、
    例外は握り潰して破棄処理自体は完了させる。 }
  try
    if FIsOpen then
      Close;
  except
    on E: Exception do
      ; // 破棄中の例外は伝播させない
  end;
  inherited Destroy;
end;

function TCustomSoundDevice.ValidateIoCount(ACount, ABufLen: Integer;
  const AOpName: string): Boolean;
begin
  if not FIsOpen then
    raise ESoundError.CreateFmt(
      '%s: デバイスが未オープンです', [AOpName]);
  if ACount < 0 then
    raise ESoundError.CreateFmt(
      '%s: サンプル数が負です (%d)', [AOpName, ACount]);
  if ACount > ABufLen then
    raise ESoundError.CreateFmt(
      '%s: サンプル数がバッファ長を超えています (要求 %d / バッファ %d)',
      [AOpName, ACount, ABufLen]);
  Result := ACount > 0;
end;

{ TNullSoundDevice }

function TNullSoundDevice.Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean;
begin
  FSampleRate := ASampleRate;
  IsOpenFlag := True;
  Result := True;
end;

procedure TNullSoundDevice.Close;
begin
  IsOpenFlag := False;
end;

procedure TNullSoundDevice.AbortIO;
begin
  IsOpenFlag := False;
end;

{ テストダブルであっても本番と同じ契約違反を返す (AUD-05 / CORE-02)。
  Null 実装が黙って受理してしまうと、単体テストが不正な呼び出しを
  検出できず、実デバイスに差し替えた時だけ壊れることになる。 }
function TNullSoundDevice.ReadSamples(var Buf: array of Double; Count: Integer): Integer;
var
  i: Integer;
begin
  if not ValidateIoCount(Count, Length(Buf), 'ReadSamples') then
    Exit(0);
  for i := 0 to Count - 1 do
    Buf[i] := 0.0;
  Result := Count;
end;

function TNullSoundDevice.WriteSamples(const Buf: array of Double; Count: Integer): Integer;
begin
  if not ValidateIoCount(Count, Length(Buf), 'WriteSamples') then
    Exit(0);
  Result := Count;
end;

function TNullSoundDevice.WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer;
begin
  if not ValidateIoCount(Count, Length(BufL), 'WriteStereo(L)') then
    Exit(0);
  if Count > Length(BufR) then
    raise ESoundError.CreateFmt(
      'WriteStereo: R チャネルのバッファ長が不足しています (要求 %d / バッファ %d)',
      [Count, Length(BufR)]);
  Result := Count;
end;

procedure TNullSoundDevice.Flush;
begin
  // 何もしない
end;

end.
