{ ============================================================================
  ModemDSP.pas

  RTTY/CW モデム実装 (RttyModemImpl.pas / CwModemImpl.pas) が共通して使う
  DSP (信号処理) ヘルパー。fldigi の以下のファイルに対応する:

    - src/include/complex.h   (typedef std::complex<double> cmplx;)
    - src/include/misc.h      (decayavg(), clamp())
    - src/include/filters.h   (class Cmovavg -- 移動平均フィルタ)
    - src/include/fftfilt.h   (class fftfilt -- FFTオーバーラップ加算フィルタ)

  fftfilt については、fldigi 本体は g_fft (自作FFTテンプレート, gfft.h) を
  用いた本格的な窓関数付きバンドパス/ローパスフィルタだが、本移植版では
  FFTエンジンそのものの移植はスコープ外とし、代わりに
  「mark/space トーンをミキサーでベースバンドに落とした後の包絡線検波」
  という目的に対して十分な特性を持つ複素1次IIRローパスフィルタ
  (TComplexLowpass) で代替する。
  RTTY/CW の実際の変復調アルゴリズム (ステートマシン、Baudot符号、
  モールス符号、AFC、適応速度追跡) は fldigi のソースから忠実に移植し、
  フィルタ部分のみこの簡略化を行っている。
  ============================================================================ }
unit ModemDSP;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

const
  TWOPI = 2.0 * Pi;

type
  { fldigi: typedef std::complex<double> cmplx; (complex.h) }
  TComplex = record
    Re, Im: Double;
  end;

operator + (const A, B: TComplex): TComplex;
operator - (const A, B: TComplex): TComplex;
operator * (const A, B: TComplex): TComplex;
operator * (const A: TComplex; const B: Double): TComplex;
operator * (const A: Double; const B: TComplex): TComplex;

function CplxMake(ARe, AIm: Double): TComplex;
function CplxAbs(const A: TComplex): Double;
function CplxArg(const A: TComplex): Double;
function CplxConj(const A: TComplex): TComplex;

{ fldigi: misc.h の inline double decayavg(double average, double input, int weight) }
function DecayAvg(AAverage, AInput: Double; AWeight: Integer): Double;

{ fldigi: misc.h の inline double clamp(double x, double min, double max) }
function ClampF(AValue, AMin, AMax: Double): Double;

type
  { TMovingAverage
    ---------------------------------------------------------------------
    fldigi: class Cmovavg (filters.h / filters.cxx)
    円環バッファによる単純移動平均。RTTY のビットフィルタ、CW の
    ビットフィルタ・トラッキングフィルタに使用する。 }
  TMovingAverage = class
  private
    FBuf: array of Double;
    FLen: Integer;
    FSum: Double;
    FPtr: Integer;
    FEmpty: Boolean;
  public
    constructor Create(ALen: Integer);
    { fldigi: void Cmovavg::setLength(int) }
    procedure SetLength_(ALen: Integer);
    { fldigi: void Cmovavg::reset() }
    procedure Reset;
    { fldigi: double Cmovavg::run(double) }
    function Run(AValue: Double): Double;
  end;

  { TComplexLowpass
    ---------------------------------------------------------------------
    fldigi の fftfilt (窓関数付き Overlap-Add FFT ローパス/バンドパス
    フィルタ) の簡易代替。1次RC型ローパスを複素信号(I/Q)に適用する。
    カットオフ周波数は fftfilt に渡していた「baud/samplerate」相当の
    値をそのまま Hz 単位で指定する。 }
  TComplexLowpass = class
  private
    FAlpha: Double;
    FState: TComplex;
  public
    constructor Create(ACutoffHz, ASampleRate: Double);
    procedure SetCutoff(ACutoffHz, ASampleRate: Double);
    function Run(const AIn: TComplex): TComplex;
    procedure Reset;
  end;

implementation

operator + (const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re + B.Re;
  Result.Im := A.Im + B.Im;
end;

operator - (const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re - B.Re;
  Result.Im := A.Im - B.Im;
end;

operator * (const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re * B.Re - A.Im * B.Im;
  Result.Im := A.Re * B.Im + A.Im * B.Re;
end;

operator * (const A: TComplex; const B: Double): TComplex;
begin
  Result.Re := A.Re * B;
  Result.Im := A.Im * B;
end;

operator * (const A: Double; const B: TComplex): TComplex;
begin
  Result.Re := A * B.Re;
  Result.Im := A * B.Im;
end;

function CplxMake(ARe, AIm: Double): TComplex;
begin
  Result.Re := ARe;
  Result.Im := AIm;
end;

function CplxAbs(const A: TComplex): Double;
begin
  Result := Sqrt(A.Re * A.Re + A.Im * A.Im);
end;

function CplxArg(const A: TComplex): Double;
begin
  Result := ArcTan2(A.Im, A.Re);
end;

function CplxConj(const A: TComplex): TComplex;
begin
  Result.Re := A.Re;
  Result.Im := -A.Im;
end;

function DecayAvg(AAverage, AInput: Double; AWeight: Integer): Double;
begin
  // fldigi: if (weight <= 1) return input; return ((input-average)/weight)+average;
  if AWeight <= 1 then
    Result := AInput
  else
    Result := ((AInput - AAverage) / AWeight) + AAverage;
end;

function ClampF(AValue, AMin, AMax: Double): Double;
begin
  if AValue < AMin then
    Result := AMin
  else if AValue > AMax then
    Result := AMax
  else
    Result := AValue;
end;

{ TMovingAverage }

constructor TMovingAverage.Create(ALen: Integer);
begin
  inherited Create;
  if ALen < 1 then
    ALen := 1;
  FLen := ALen;
  SetLength(FBuf, FLen);
  FEmpty := True;
  FSum := 0;
  FPtr := 0;
end;

procedure TMovingAverage.SetLength_(ALen: Integer);
begin
  if ALen < 1 then
    ALen := 1;
  if ALen > FLen then
    SetLength(FBuf, ALen);
  FLen := ALen;
  FEmpty := True;
end;

procedure TMovingAverage.Reset;
begin
  FEmpty := True;
end;

function TMovingAverage.Run(AValue: Double): Double;
var
  i: Integer;
begin
  if FEmpty then
  begin
    FEmpty := False;
    FSum := 0;
    for i := 0 to FLen - 1 do
    begin
      FBuf[i] := AValue;
      FSum := FSum + AValue;
    end;
    FPtr := 0;
    Exit(AValue);
  end;
  FSum := FSum - FBuf[FPtr] + AValue;
  FBuf[FPtr] := AValue;
  Inc(FPtr);
  if FPtr >= FLen then
    FPtr := 0;
  Result := FSum / FLen;
end;

{ TComplexLowpass }

constructor TComplexLowpass.Create(ACutoffHz, ASampleRate: Double);
begin
  inherited Create;
  SetCutoff(ACutoffHz, ASampleRate);
  FState := CplxMake(0, 0);
end;

procedure TComplexLowpass.SetCutoff(ACutoffHz, ASampleRate: Double);
begin
  if ACutoffHz < 0.1 then
    ACutoffHz := 0.1;
  if ASampleRate < 1 then
    ASampleRate := 1;
  // 標準的な1次RCローパスの離散化: alpha = 1 - exp(-2*pi*fc/fs)
  FAlpha := 1.0 - Exp(-TWOPI * ACutoffHz / ASampleRate);
  if FAlpha > 1.0 then
    FAlpha := 1.0;
end;

function TComplexLowpass.Run(const AIn: TComplex): TComplex;
begin
  FState.Re := FState.Re + FAlpha * (AIn.Re - FState.Re);
  FState.Im := FState.Im + FAlpha * (AIn.Im - FState.Im);
  Result := FState;
end;

procedure TComplexLowpass.Reset;
begin
  FState := CplxMake(0, 0);
end;

end.
