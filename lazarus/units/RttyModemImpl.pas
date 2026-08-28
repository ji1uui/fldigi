{ ============================================================================
  RttyModemImpl.pas

  fldigi の src/include/rtty.h / src/cw_rtty/rtty.cxx (class rtty) を
  Lazarus/FPC 向けに移植した RTTY (Radio Teletype / Baudot) モデムの
  具象実装。TCustomModem (Modem.pas) を継承する。

  fldigi との対応 (実装した範囲):
  ----------------------------------------------------------------------------
  - Baudot 5bit 符号表 (letters[]/figures[]) と baudot_enc/baudot_dec
  - Mark/Space ミキサー (rtty::mixer) + 包絡線検波
    ※ fldigi 本体は fftfilt (FFTオーバーラップ加算窓関数フィルタ) を
       使うが、本移植版は ModemDSP.TComplexLowpass (1次IIR) で代替する
       (フィルタの通過帯域特性は簡略化されるが、ステートマシン自体の
       アルゴリズムは fldigi と同一)。
  - 受信ステートマシン (rtty::rx(): IDLE→START→DATA→STOP) をそのまま移植
  - decode_char() (パリティ検査 + Baudot デコード)
  - AFC (自動周波数制御。マーク/スペール履歴の位相差から周波数誤差を算出)
  - 送信: NCO (rtty::nco), send_symbol/send_char/send_idle,
    UOS (unshift-on-space), LETTERS/FIGURES シフト管理

  実装を省略した範囲 (fldigi固有のGUI/外部ハードウェア依存のため):
  - ウォーターフォール表示 (Metric() の S/N比計算は簡略化)
  - rttyviewer (複数chビューア)
  - synop (気象データ SYNOP デコード)
  - FLRIG/nanoIO/WinKeyer 等の外部 FSK ハードウェア
  - シンボル整形 (SymbolShaper: sinc補間による波形整形) は省略し、
    単純な NCO 矩形波送信のみ実装 (progStatus.shaped_rtty=false 相当)
  ============================================================================ }
unit RttyModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP;

const
  RTTY_SAMPLE_RATE = 8000;      // fldigi: #define RTTY_SampleRate 8000
  RTTY_MAXBITS = 2 * RTTY_SAMPLE_RATE div 23 + 1; // fldigi: #define MAXBITS
  RTTY_LETTERS = $100;          // fldigi: #define LETTERS 0x100
  RTTY_FIGURES = $200;          // fldigi: #define FIGURES 0x200
  RTTY_MAXPIPE = 1024;          // fldigi: #define MAXPIPE 1024

  { fldigi: rtty::SHIFT[] / BAUD[] / BITS[] }
  RttyShiftTable: array[0..9] of Double = (23, 85, 160, 170, 182, 200, 240, 350, 425, 850);
  RttyBaudTable: array[0..9] of Double = (45, 45.45, 50, 56, 75, 100, 110, 150, 200, 300);
  RttyBitsTable: array[0..2] of Integer = (5, 7, 8);

type
  TRttyRxState = (
    rrsIdle,
    rrsStart,
    rrsData,
    rrsStop
  );

  TRttyParity = (
    rpNone,
    rpEven,
    rpOdd,
    rpZero,
    rpOne
  );

  { TRttyModem
    ---------------------------------------------------------------------
    fldigi: class rtty : public modem (rtty.h / rtty.cxx) }
  TRttyModem = class(TCustomModem)
  private
    // --- Baudot テーブル (fldigi: static char letters[32]/figures[32]) ---
    // (implementation セクションの定数配列を参照する)

    // --- 設定パラメータ (fldigi: rtty_shift, rtty_baud, rtty_bits, ...) ---
    FShift: Double;          // fldigi: shift / rtty_shift
    FBaud: Double;           // fldigi: rtty_baud
    FBits: Integer;          // fldigi: rtty_bits (5/7/8)
    FParity: TRttyParity;    // fldigi: rtty_parity
    FStopBits: Double;       // fldigi: rtty_stop -> stl (1.0/1.5/2.0)
    FSymbolLen: Integer;     // fldigi: symbollen
    FStopLen: Integer;       // fldigi: stoplen

    // --- 受信 DSP 状態 ---
    FMarkPhase: Double;      // fldigi: mark_phase
    FSpacePhase: Double;     // fldigi: space_phase
    FMarkFilt: TComplexLowpass; // fldigi: fftfilt *mark_filt (簡略化)
    FSpaceFilt: TComplexLowpass;// fldigi: fftfilt *space_filt (簡略化)
    FBitBuf: array[0..RTTY_MAXBITS-1] of Boolean; // fldigi: bit_buf[MAXBITS]
    FMarkEnv, FMarkNoise: Double;  // fldigi: mark_env, mark_noise
    FSpaceEnv, FSpaceNoise: Double;// fldigi: space_env, space_noise
    FNoiseFloor: Double;          // fldigi: noise_floor
    FBit: Boolean;                // fldigi: bit

    FRxState: TRttyRxState;  // fldigi: rxstate
    FRxMode: Integer;        // fldigi: rxmode (LETTERS/FIGURES)
    FShiftState: Integer;    // fldigi: shift_state (送信用)
    FCounter: Integer;       // fldigi: counter
    FBitCntr: Integer;       // fldigi: bitcntr
    FRxData: Integer;        // fldigi: rxdata
    FLastChar: Integer;      // fldigi: lastchar

    // --- AFC ---
    FMarkHistory: array[0..RTTY_MAXPIPE-1] of TComplex; // fldigi: mark_history[]
    FSpaceHistory: array[0..RTTY_MAXPIPE-1] of TComplex;// fldigi: space_history[]
    FInpPtr: Integer;        // fldigi: inp_ptr
    FFreqErr: Double;        // fldigi: freqerr
    FAfcOn: Boolean;         // fldigi: progStatus.afconoff 相当 (公開プロパティ化)
    FAfcSpeed: Integer;      // fldigi: progdefaults.rtty_afcspeed (0=slow,1=med,2=fast)

    // --- 送信 DSP 状態 ---
    FPhaseAcc: Double;       // fldigi: phaseacc
    FPreamble: Boolean;      // fldigi: preamble
    FLineCharCount: Integer; // fldigi: line_char_count (static local -> field)

    // Metric 計算用
    FSigPwr, FNoisePwr: Double;

    function Mixer(var APhase: Double; AFreq: Double; const AIn: TComplex): TComplex;
    function DecodeChar: Integer;
    function IsMark: Boolean;
    function IsMarkSpace(out ACorrection: Integer): Boolean;
    function RxBit(ABit: Boolean): Boolean; // fldigi: rtty::rx(bool bit)

    function Nco(AFreq: Double): Double;    // fldigi: rtty::nco()
    procedure SendSymbol(ASymbol: Integer; ALen: Integer; ASoundOut: Boolean = True);
    procedure SendStop;
    procedure SendChar(AChar: Integer);
    procedure SendIdle;
    function BaudotEnc(AData: Byte): Integer;
    function BaudotDec(AData: Byte): Char;

    procedure ComputeMetric;
    procedure ApplyBaudSettings;
  public
    constructor Create(ASound: TCustomSoundDevice); reintroduce;
    destructor Destroy; override;

    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer; override;
    function TxProcess: Integer; override;

    procedure SearchDown; override;
    procedure SearchUp; override;

    { RTTY パラメータ設定 (fldigi: progdefaults.rtty_shift/baud/bits/parity/stop) }
    procedure SetShiftIndex(AIndex: Integer);   // 0..9 -> RttyShiftTable
    procedure SetBaudIndex(AIndex: Integer);    // 0..9 -> RttyBaudTable
    procedure SetBitsIndex(AIndex: Integer);    // 0..2 -> RttyBitsTable
    procedure SetParity(AParity: TRttyParity);
    procedure SetStopBits(AStopIndex: Integer); // 0=1bit,1=1.5bit,2=2bit
    procedure SetUnshiftOnSpaceTx(AOn: Boolean);
    procedure SetUnshiftOnSpaceRx(AOn: Boolean);

    property Shift: Double read FShift;
    property Baud: Double read FBaud;
    property AfcOn: Boolean read FAfcOn write FAfcOn;
  end;

implementation

const
  { fldigi: static char letters[32] (rtty.cxx) }
  RttyLetters: array[0..31] of Char = (
    #0,  'E', #10, 'A', ' ', 'S', 'I', 'U',
    #13, 'D', 'R', 'J', 'N', 'F', 'C', 'K',
    'T', 'Z', 'L', 'W', 'H', 'Y', 'P', 'Q',
    'O', 'B', 'G', ' ', 'M', 'X', 'V', ' '
  );
  { fldigi: static char figures[32] (US version) }
  RttyFigures: array[0..31] of Char = (
    #0,  '3', #10, '-', ' ', #7,  '8', '7',
    #13, '$', '4', '''', ',', '!', ':', '(',
    '5', '"', ')', '2', '#', '6', '0', '1',
    '9', '?', '&', ' ', '.', '/', ';', ' '
  );

var
  UOSTx: Boolean = True;  // fldigi: progdefaults.UOStx
  UOSRx: Boolean = True;  // fldigi: progdefaults.UOSrx

{ ---- パリティ計算 (fldigi: static int rparity() / int rttyparity()) ---- }

function RParity(AValue: Integer): Integer;
var
  w, p: Integer;
begin
  w := AValue;
  p := 0;
  while w <> 0 do
  begin
    p := p + (w and 1);
    w := w shr 1;
  end;
  Result := p and 1;
end;

function RttyParityBit(AValue: Integer; ANBits: Integer; AParity: TRttyParity): Integer;
var
  c: Integer;
begin
  c := AValue and ((1 shl ANBits) - 1);
  case AParity of
    rpOdd:  Result := RParity(c);
    rpEven: Result := 1 - RParity(c);
    rpZero: Result := 0;
    rpOne:  Result := 1;
  else
    Result := 0; // rpNone
  end;
end;

{ TRttyModem }

constructor TRttyModem.Create(ASound: TCustomSoundDevice);
begin
  inherited Create(ASound, mmRTTY);
  SampleRate := RTTY_SAMPLE_RATE;
  Capabilities := Capabilities + [mcAFC, mcReverse, mcBandwidth, mcRx, mcTx];

  FAfcOn := True;
  FAfcSpeed := 1; // fldigi 既定: progdefaults.rtty_afcspeed = 1 (medium)
  FShift := RttyShiftTable[1];   // 既定 85Hz
  FBaud := RttyBaudTable[1];     // 既定 45.45 baud
  FBits := 5;
  FParity := rpNone;
  FStopBits := 1.5;

  FMarkFilt := TComplexLowpass.Create(FBaud, SampleRate);
  FSpaceFilt := TComplexLowpass.Create(FBaud, SampleRate);

  FRxMode := RTTY_LETTERS;
  FShiftState := RTTY_LETTERS;
  FLastChar := 0;

  Restart;
end;

destructor TRttyModem.Destroy;
begin
  FMarkFilt.Free;
  FSpaceFilt.Free;
  inherited Destroy;
end;

procedure TRttyModem.ApplyBaudSettings;
var
  i: Integer;
begin
  FSymbolLen := Round(SampleRate / FBaud); // fldigi: (int)(samplerate/rtty_baud + 0.5)
  FStopLen := Round(FStopBits * SampleRate / FBaud);
  Bandwidth := FShift;

  FMarkFilt.SetCutoff(FBaud, SampleRate);
  FSpaceFilt.SetCutoff(FBaud, SampleRate);

  for i := 0 to RTTY_MAXBITS - 1 do
    FBitBuf[i] := False;

  FMarkNoise := 0;
  FSpaceNoise := 0;
  FBit := True;
end;

procedure TRttyModem.TxInit;
begin
  // fldigi: rtty::tx_init()
  FPhaseAcc := 0;
  FPreamble := True;
end;

procedure TRttyModem.RxInit;
begin
  // fldigi: rtty::rx_init()
  FRxState := rrsIdle;
  FRxMode := RTTY_LETTERS;
  FPhaseAcc := 0;

  FMarkPhase := 0;
  FSpacePhase := 0;

  FMarkEnv := 0;
  FSpaceEnv := 0;
  FInpPtr := 0;
  FLastChar := 0;

  EmitStatus(GetModeName);
end;

procedure TRttyModem.Restart;
begin
  // fldigi: rtty::restart()
  ApplyBaudSettings;
  FShiftState := RTTY_LETTERS;
  FRxMode := RTTY_LETTERS;
  FFreqErr := 0;
  RxInit;
end;

procedure TRttyModem.SetShiftIndex(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex <= High(RttyShiftTable)) then
  begin
    FShift := RttyShiftTable[AIndex];
    ApplyBaudSettings;
  end;
end;

procedure TRttyModem.SetBaudIndex(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex <= High(RttyBaudTable)) then
  begin
    FBaud := RttyBaudTable[AIndex];
    ApplyBaudSettings;
  end;
end;

procedure TRttyModem.SetBitsIndex(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex <= High(RttyBitsTable)) then
  begin
    FBits := RttyBitsTable[AIndex];
    if FBits = 5 then
      FParity := rpNone;
  end;
end;

procedure TRttyModem.SetParity(AParity: TRttyParity);
begin
  if FBits <> 5 then
    FParity := AParity;
end;

procedure TRttyModem.SetStopBits(AStopIndex: Integer);
begin
  case AStopIndex of
    0: FStopBits := 1.0;
    1: FStopBits := 1.5;
  else
    FStopBits := 2.0;
  end;
  ApplyBaudSettings;
end;

procedure TRttyModem.SetUnshiftOnSpaceTx(AOn: Boolean);
begin
  UOSTx := AOn;
end;

procedure TRttyModem.SetUnshiftOnSpaceRx(AOn: Boolean);
begin
  UOSRx := AOn;
end;

{ ---- 受信 DSP ---- }

function TRttyModem.Mixer(var APhase: Double; AFreq: Double; const AIn: TComplex): TComplex;
var
  z: TComplex;
begin
  // fldigi: cmplx rtty::mixer(double &phase, double f, cmplx in)
  z := CplxMake(Cos(APhase), Sin(APhase)) * AIn;
  APhase := APhase - TWOPI * AFreq / SampleRate;
  if APhase < -TWOPI then
    APhase := APhase + TWOPI;
  Result := z;
end;

function TRttyModem.IsMark: Boolean;
begin
  // fldigi: bool rtty::is_mark() { return bit_buf[symbollen/2]; }
  Result := FBitBuf[FSymbolLen div 2];
end;

function TRttyModem.IsMarkSpace(out ACorrection: Integer): Boolean;
var
  i: Integer;
begin
  // fldigi: bool rtty::is_mark_space(int &correction)
  ACorrection := 0;
  Result := False;
  if FBitBuf[0] and (not FBitBuf[FSymbolLen - 1]) then
  begin
    for i := 0 to FSymbolLen - 1 do
      if FBitBuf[i] then
        Inc(ACorrection);
    if Abs(FSymbolLen div 2 - ACorrection) < 6 then
      Result := True;
  end;
end;

function TRttyModem.DecodeChar: Integer;
var
  ParBit, Par, Data: Integer;
begin
  // fldigi: int rtty::decode_char()
  ParBit := (FRxData shr FBits) and 1;
  Par := RttyParityBit(FRxData, FBits, FParity);
  if (FParity <> rpNone) and (ParBit <> Par) then
    Exit(0);
  Data := FRxData and ((1 shl FBits) - 1);
  if FBits = 5 then
    Result := Ord(BaudotDec(Data))
  else
    Result := Data;
end;

function TRttyModem.RxBit(ABit: Boolean): Boolean;
var
  i, Correction, C: Integer;
  ParityBits: Integer;
begin
  // fldigi: bool rtty::rx(bool bit)
  Result := False;

  for i := 1 to FSymbolLen - 1 do
    FBitBuf[i-1] := FBitBuf[i];
  FBitBuf[FSymbolLen - 1] := ABit;

  case FRxState of
    rrsIdle:
      if IsMarkSpace(Correction) then
      begin
        FRxState := rrsStart;
        FCounter := Correction;
      end;

    rrsStart:
      begin
        Dec(FCounter);
        if FCounter = 0 then
        begin
          if not IsMark then
          begin
            FRxState := rrsData;
            FCounter := FSymbolLen;
            FBitCntr := 0;
            FRxData := 0;
          end
          else
            FRxState := rrsIdle;
        end;
      end;

    rrsData:
      begin
        if FParity <> rpNone then
          ParityBits := 1
        else
          ParityBits := 0;
        Dec(FCounter);
        if FCounter = 0 then
        begin
          if IsMark then
            FRxData := FRxData or (1 shl FBitCntr);
          Inc(FBitCntr);
          FCounter := FSymbolLen;
        end;
        if FBitCntr = FBits + ParityBits then
          FRxState := rrsStop;
      end;

    rrsStop:
      begin
        Dec(FCounter);
        if FCounter = 0 then
        begin
          if IsMark then
          begin
            C := DecodeChar;
            if C <> 0 then
            begin
              // fldigi: <CR><CR> / <LF><LF> の連続抑制
              if (C = 13) and (FLastChar = 13) then
                // 抑制
              else if (C = 10) and (FLastChar = 10) then
                // 抑制
              else
                EmitRxChar(C);
              FLastChar := C;
            end;
            Result := True;
          end;
          FRxState := rrsIdle;
        end;
      end;
  end;
end;

procedure TRttyModem.ComputeMetric;
var
  Snr: Double;
begin
  // fldigi: void rtty::Metric() の簡略版。
  // wf->powerDensity() (ウォーターフォールのスペクトル密度) の代わりに
  // 復調後の mark/space 包絡線・ノイズフロアから概算する。
  FSigPwr := DecayAvg(FSigPwr, Sqr(FMarkEnv) + Sqr(FSpaceEnv), 4);
  FNoisePwr := DecayAvg(FNoisePwr, Sqr(FNoiseFloor) + 1e-10, 16);
  // FSigPwr / FNoisePwr のいずれか(特に起動直後の FSigPwr)がゼロに近いと
  // Log10(0) = -Infinity となり x87 FPU の "divide by zero" 例外
  // (EZeroDivide) が発生するため、両者を下限クランプしてから比を取る。
  if (FNoisePwr > 1e-12) and (FSigPwr > 1e-12) then
    Snr := 10 * Log10(FSigPwr / FNoisePwr)
  else
    Snr := 0;
  SetMetric(ClampF(Snr * 5.0, 0.0, 100.0));
end;

function TRttyModem.RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
var
  i: Integer;
  Sample, ZMark, ZSpace: TComplex;
  MarkMag, SpaceMag: Double;
  MClipped, SClipped: Double;
  V3: Double;
  Bit, RxBitValue: Boolean;
  Mp0, Mp1: Integer;
  Ferr: Double;
  AfcSpeedDiv: Integer;
begin
  ComputeMetric;

  for i := 0 to ALen - 1 do
  begin
    Sample := CplxMake(ABuf[i], ABuf[i]);

    ZMark := Mixer(FMarkPhase, Frequency + FShift / 2.0, Sample);
    ZMark := FMarkFilt.Run(ZMark);

    ZSpace := Mixer(FSpacePhase, Frequency - FShift / 2.0, Sample);
    ZSpace := FSpaceFilt.Run(ZSpace);

    MarkMag := CplxAbs(ZMark);
    FMarkEnv := DecayAvg(FMarkEnv, MarkMag, IfThen(MarkMag > FMarkEnv, FSymbolLen div 4, FSymbolLen * 16));
    FMarkNoise := DecayAvg(FMarkNoise, MarkMag, IfThen(MarkMag < FMarkNoise, FSymbolLen div 4, FSymbolLen * 48));

    SpaceMag := CplxAbs(ZSpace);
    FSpaceEnv := DecayAvg(FSpaceEnv, SpaceMag, IfThen(SpaceMag > FSpaceEnv, FSymbolLen div 4, FSymbolLen * 16));
    FSpaceNoise := DecayAvg(FSpaceNoise, SpaceMag, IfThen(SpaceMag < FSpaceNoise, FSymbolLen div 4, FSymbolLen * 48));

    FNoiseFloor := Min(FSpaceNoise, FMarkNoise);

    MClipped := IfThen(MarkMag > FMarkEnv, FMarkEnv, MarkMag);
    SClipped := IfThen(SpaceMag > FSpaceEnv, FSpaceEnv, SpaceMag);
    if MClipped < FNoiseFloor then MClipped := FNoiseFloor;
    if SClipped < FNoiseFloor then SClipped := FNoiseFloor;

    // fldigi: Optimal ATC (Automatic Threshold Correction)
    V3 := (MClipped - FNoiseFloor) * (FMarkEnv - FNoiseFloor) -
          (SClipped - FNoiseFloor) * (FSpaceEnv - FNoiseFloor) - 0.25 * (
          Sqr(FMarkEnv - FNoiseFloor) - Sqr(FSpaceEnv - FNoiseFloor));

    Bit := V3 > 0;
    FBit := Bit;

    FMarkHistory[FInpPtr] := ZMark;
    FSpaceHistory[FInpPtr] := ZSpace;
    FInpPtr := (FInpPtr + 1) mod RTTY_MAXPIPE;

    // fldigi: rx( reverse ? !bit : bit )
    RxBitValue := Bit;
    if Reverse then
      RxBitValue := not RxBitValue;

    if RxBit(RxBitValue) then
    begin
      // fldigi: AFC 周波数誤差の算出。直近2サンプルの mark(または space,
      // reverse時)履歴の位相差から周波数誤差を求める (rtty.cxx 830-850行目)。
      Mp0 := FInpPtr - 2;
      Mp1 := Mp0 + 1;
      if Mp0 < 0 then Mp0 := Mp0 + RTTY_MAXPIPE;
      if Mp1 < 0 then Mp1 := Mp1 + RTTY_MAXPIPE;

      if not Reverse then
        Ferr := (TWOPI * SampleRate / FBaud) *
                 CplxArg(CplxConj(FMarkHistory[Mp1]) * FMarkHistory[Mp0])
      else
        Ferr := (TWOPI * SampleRate / FBaud) *
                 CplxArg(CplxConj(FSpaceHistory[Mp1]) * FSpaceHistory[Mp0]);

      if Abs(Ferr) > FBaud / 2 then
        Ferr := 0;

      case FAfcSpeed of
        0: AfcSpeedDiv := 8;
        1: AfcSpeedDiv := 4;
      else
        AfcSpeedDiv := 1;
      end;
      FFreqErr := DecayAvg(FFreqErr, Ferr / 8, AfcSpeedDiv);

      if FAfcOn then
        SetFreq(Frequency - FFreqErr);
    end;
  end;
  Result := 0;
end;

{ ---- 送信 DSP ---- }

function TRttyModem.Nco(AFreq: Double): Double;
begin
  // fldigi: double rtty::nco(double freq)
  FPhaseAcc := FPhaseAcc + TWOPI * AFreq / SampleRate;
  if FPhaseAcc > TWOPI then
    FPhaseAcc := FPhaseAcc - TWOPI;
  Result := Cos(FPhaseAcc);
end;

procedure TRttyModem.SendSymbol(ASymbol: Integer; ALen: Integer; ASoundOut: Boolean);
var
  Buf: array of Double;
  i: Integer;
  Freq: Double;
  Sym: Integer;
begin
  // fldigi: void rtty::send_symbol(int symbol, int len)
  // (SymbolShaper による波形整形は省略し、矩形 FSK のみ実装)
  Sym := ASymbol;
  if Reverse then
    Sym := 1 - Sym;

  if Sym <> 0 then
    Freq := TxFrequency + FShift / 2.0
  else
    Freq := TxFrequency - FShift / 2.0;

  if ASoundOut and Assigned(Sound) then
  begin
    SetLength(Buf, ALen);
    for i := 0 to ALen - 1 do
      Buf[i] := Nco(Freq);
    Sound.WriteSamples(Buf, ALen);
  end
  else
    for i := 0 to ALen - 1 do
      Nco(Freq); // 位相だけ進める (テスト用: サウンド未使用時)
end;

procedure TRttyModem.SendStop;
begin
  // fldigi: void rtty::send_stop()
  SendSymbol(1, FStopLen);
end;

function TRttyModem.BaudotEnc(AData: Byte): Integer;
var
  i: Integer;
  EncMode: Integer;
  C: Integer;
  Ch: Char;
begin
  // fldigi: int rtty::baudot_enc(unsigned char data)
  EncMode := 0;
  C := -1;
  Ch := Chr(AData);
  if (Ch >= 'a') and (Ch <= 'z') then
    Ch := UpCase(Ch);

  for i := 0 to 31 do
  begin
    if Ch = RttyLetters[i] then
    begin
      EncMode := EncMode or RTTY_LETTERS;
      C := i;
    end;
    if Ch = RttyFigures[i] then
    begin
      EncMode := EncMode or RTTY_FIGURES;
      C := i;
    end;
    if C <> -1 then
      Exit(EncMode or C);
  end;
  Result := -1;
end;

function TRttyModem.BaudotDec(AData: Byte): Char;
var
  OutCh: Char;
begin
  // fldigi: char rtty::baudot_dec(unsigned char data)
  OutCh := #0;
  case AData of
    $1F: FRxMode := RTTY_LETTERS;
    $1B: FRxMode := RTTY_FIGURES;
    $04:
      begin
        if UOSRx then
          FRxMode := RTTY_LETTERS;
        Exit(' ');
      end;
  else
    if FRxMode = RTTY_LETTERS then
      OutCh := RttyLetters[AData]
    else
      OutCh := RttyFigures[AData];
  end;
  Result := OutCh;
end;

procedure TRttyModem.SendChar(AChar: Integer);
var
  i, C: Integer;
  OutCh: Char;
begin
  // fldigi: void rtty::send_char(int c)
  C := AChar;
  if FBits = 5 then
  begin
    if C = RTTY_LETTERS then
      C := $1F;
    if C = RTTY_FIGURES then
      C := $1B;
  end;

  // start bit (0=space)
  SendSymbol(0, FSymbolLen);
  // data bits (LSB first)
  for i := 0 to FBits - 1 do
    SendSymbol((C shr i) and 1, FSymbolLen);
  // parity bit
  if FParity <> rpNone then
    SendSymbol(RttyParityBit(C, FBits, FParity), FSymbolLen);
  // stop bit(s)
  SendStop;

  if FBits = 5 then
  begin
    if (C = $1F) or (C = $1B) then
      Exit;
    if FShiftState = RTTY_LETTERS then
      OutCh := RttyLetters[C]
    else
      OutCh := RttyFigures[C];
    // fldigi: put_echo_char(outc) -- 送信中の文字を Tx パネルへエコー表示
    if OutCh <> #0 then
      EmitEchoChar(Ord(OutCh));
  end
  else
    EmitEchoChar(C);
end;

procedure TRttyModem.SendIdle;
begin
  // fldigi: void rtty::send_idle()
  if FBits = 5 then
  begin
    SendChar(RTTY_LETTERS);
    FShiftState := RTTY_LETTERS;
  end
  else
    SendChar(0);
end;

function TRttyModem.TxProcess: Integer;
var
  C: Integer;
begin
  // fldigi: int rtty::tx_process() (FLRIG/nanoIO/WinKeyer 等の
  // 外部ハードウェア分岐は省略し、通常の Baudot 送信のみ実装)
  C := FetchTxChar;

  if FPreamble then
  begin
    SendChar(RTTY_LETTERS);
    SendChar(RTTY_LETTERS);
    FPreamble := False;
  end;

  if (C = MODEM_TX_CHAR_ETX) or StopFlag then
  begin
    StopFlag := False;
    FLineCharCount := 0;
    if FBits <> 5 then
    begin
      SendChar(13);
      SendChar(10);
    end
    else
    begin
      SendChar($08); // CR (Baudot)
      SendChar($02); // LF (Baudot)
    end;
    Exit(-1);
  end;

  if C = MODEM_TX_CHAR_NODATA then
  begin
    SendIdle;
    Exit(0);
  end;

  // 7/8bit (ASCII/ITA5相当) の場合はそのまま送信
  if FBits <> 5 then
  begin
    SendChar(C);
    Exit(0);
  end;

  // --- Baudot (5bit) 送信 ---
  if C = 13 then // '\r'
  begin
    FLineCharCount := 0;
    SendChar($08);
    Exit(0);
  end;
  if C = 10 then // '\n'
  begin
    FLineCharCount := 0;
    SendChar($02);
    Exit(0);
  end;

  // unshift-on-space
  if C = Ord(' ') then
  begin
    if UOSTx then
    begin
      SendChar(RTTY_LETTERS);
      SendChar($04);
      FShiftState := RTTY_LETTERS;
    end
    else
      SendChar($04);
    Exit(0);
  end;

  C := BaudotEnc(C);
  if C < 0 then
    Exit(0);

  if (C and $300) <> FShiftState then
  begin
    if FShiftState = RTTY_FIGURES then
    begin
      SendChar(RTTY_LETTERS);
      FShiftState := RTTY_LETTERS;
    end
    else
    begin
      SendChar(RTTY_FIGURES);
      FShiftState := RTTY_FIGURES;
    end;
  end;

  SendChar(C and $1F);
  Result := 0;
end;

procedure TRttyModem.SearchDown;
var
  SrchFreq, MinFreq: Double;
begin
  // fldigi: void rtty::searchDown() (簡略版: powerDensity 依存部分を除去)
  SrchFreq := Frequency - FShift - 100;
  MinFreq := FShift * 2 + 100;
  if SrchFreq > MinFreq then
    SetFreq(SrchFreq);
end;

procedure TRttyModem.SearchUp;
begin
  // fldigi: void rtty::searchUp() (簡略版)
  SetFreq(Frequency + FShift + 100);
end;

end.
