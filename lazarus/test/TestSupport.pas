{ ============================================================================
  TestSupport.pas

  テスト用の共通部品。v1.1 Phase 0 の成果物「Test framework」にあたる。

  復調器のテストは必ず「送信波形を作る → 復調させる → 結果を検査する」
  という形になるので、そのための道具をここに集約する。
  各テストが自前で用意すると、道具の側の差異でテスト結果が食い違う。

  収録:
    TCaptureSoundDevice : 書き込まれた波形を溜めるサウンドデバイス
    TTxSource           : 送信文字の供給元 (OnGetTxChar 用)
    TEvidenceSink       : 復調 Evidence の記録先 (OnDecode 用)
  ============================================================================ }
unit TestSupport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, DecodeEvidence;

type
  TDoubleArray = array of Double;

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

  TTxSource = class
  private
    FText: string;
    FPos: Integer;
  public
    constructor Create(const AText: string);
    function GetTxChar(Sender: TCustomModem): Integer;
  end;

  { 復調器が出した Evidence を記録する。
    ADR-002 の検査では「型が運べる」ではなく「実際に運んでいる」ことを
    見たいので、尺度・第2候補・SNR・サンプル位置の有無をそれぞれ数える。 }
  TEvidenceSink = class
  private
    FCount: Integer;
    FScored: Integer;
    FWithAlt: Integer;
    FWithSnr: Integer;
    FWithPos: Integer;
    FText: string;
    FMinMargin: Double;
    FMaxMargin: Double;
    FLastDecoder: string;
  public
    constructor Create;
    procedure Reset;
    procedure Decode(Sender: TCustomModem; const AEvidence: TDecodeEvidence);
    property Count: Integer read FCount;
    property Scored: Integer read FScored;
    property WithAlt: Integer read FWithAlt;
    property WithSnr: Integer read FWithSnr;
    property WithPos: Integer read FWithPos;
    { 最有力候補を並べた復調テキスト。 }
    property Text: string read FText;
    property MinMargin: Double read FMinMargin;
    property MaxMargin: Double read FMaxMargin;
    property LastDecoder: string read FLastDecoder;
  end;

implementation

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


{ TEvidenceSink }

constructor TEvidenceSink.Create;
begin
  inherited Create;
  Reset;
end;

procedure TEvidenceSink.Reset;
begin
  FCount := 0;
  FScored := 0;
  FWithAlt := 0;
  FWithSnr := 0;
  FWithPos := 0;
  FText := '';
  FMinMargin := 1E9;
  FMaxMargin := -1E9;
  FLastDecoder := '';
end;

procedure TEvidenceSink.Decode(Sender: TCustomModem;
  const AEvidence: TDecodeEvidence);
var
  ch: Integer;
begin
  Inc(FCount);
  FLastDecoder := AEvidence.DecoderName;
  if AEvidence.MetricKind <> emkNone then
  begin
    Inc(FScored);
    FMinMargin := Min(FMinMargin, AEvidence.BestMetric);
    FMaxMargin := Max(FMaxMargin, AEvidence.BestMetric);
  end;
  if AEvidence.HasAlternatives then Inc(FWithAlt);
  if AEvidence.HasSnr then Inc(FWithSnr);
  if AEvidence.SamplePos >= 0 then Inc(FWithPos);
  ch := AEvidence.BestChar;
  if (ch >= 32) and (ch < 127) then
    FText := FText + Chr(ch)
  else if ch = 13 then
    FText := FText + '<CR>'
  else if ch = 10 then
    FText := FText + '<LF>';
end;

end.
