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
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { fldigi: virtual int Open(int mode, int freq) }
    function Open(Direction: TSoundDirection; ASampleRate: Integer): Boolean; virtual; abstract;
    { fldigi: virtual void Close(unsigned dir) }
    procedure Close; virtual; abstract;
    { fldigi: virtual void Abort(unsigned dir) }
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
  if FIsOpen then
    Close;
  inherited Destroy;
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

function TNullSoundDevice.ReadSamples(var Buf: array of Double; Count: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to Count - 1 do
    Buf[i] := 0.0;
  Result := Count;
end;

function TNullSoundDevice.WriteSamples(const Buf: array of Double; Count: Integer): Integer;
begin
  Result := Count;
end;

function TNullSoundDevice.WriteStereo(const BufL, BufR: array of Double; Count: Integer): Integer;
begin
  Result := Count;
end;

procedure TNullSoundDevice.Flush;
begin
  // 何もしない
end;

end.
