{ ============================================================================
  CwModemImpl.pas

  fldigi の src/include/cw.h / src/cw_rtty/cw.cxx (class cw) を
  Lazarus/FPC 向けに移植した CW (モールス信号) モデムの具象実装。
  TCustomModem (Modem.pas) を継承する。

  fldigi との対応 (実装した範囲):
  ----------------------------------------------------------------------------
  - ミキサー (cw::mixer) + fldigi 本来の fftfilt (ModemDSP.TFftFilt。
    Overlap-Add FFT畳み込みローパス、CW_FFT_SIZE=2048) +
    ModemDSP.TMovingAverage (Cmovavg そのまま、ビットフィルタ) による
    包絡線検波。
    【2026-08 フィルタ品質改善】当初は ModemDSP.TComplexLowpass (1次IIR、
    カットオフを speed に比例させた簡易近似) で代替していたが、
    fldigi 本来の fftfilt::create_lpf() を ModemDSP.TFftFilt として
    移植し、置き換えた。カットオフも fldigi のデフォルト経路
    (progdefaults.CWmfilt=false のときの bandwidth=progdefaults.
    CWbandwidth 固定値、既定150Hz) に合わせ、本ユニットの Bandwidth
    プロパティ (既定150Hz) をそのまま使うよう修正した (speed比例の
    近似値ではなくなった)。また fldigi の rx_FFTprocess() が行う
    DEC_RATIO(=16) 間引き (フィルタ出力を16サンプルに1回だけ
    ビットフィルタ+decode_streamへ渡す) も合わせて再現した
    (当初省略していたが、bitfilter の長さ (symbollen/(2*DEC_RATIO)) は
    間引き後のレートを前提に計算されているため、間引きを省略すると
    ビットフィルタの実効時間窓が16倍短くなってしまう不整合があった)。
    CWmfilt (speedに応じて自動的に帯域を変える "整合フィルタ" モード、
    既定offのため優先度低)・rttyの矩形波整形のようなSymbolShaperは
    未実装のまま。
  - decode_stream(): AGC(自動利得制御)/ノイズフロア追跡付きの
    ヒステリシス検出 (upper/lower threshold) をそのまま移植
  - handle_event(): CW_RESET/KEYDOWN/KEYUP/QUERY の4イベントに対する
    RS_IDLE/RS_IN_TONE/RS_AFTER_TONE ステートマシンをそのまま移植
  - update_tracking(): ドット/ダッシュペア比較による適応速度追跡
  - sync_parameters(): WPM ⇔ サンプル数変換 (dot/dash 長, 2-dot 閾値等)
  - 送信: NCO (cw::nco), send_symbol/send_ch (QSK の A2 立ち上がり/
    立ち下がり整形は簡略化し、Hanning/Blackman envelope による
    on/off の raised-cosine 整形のみ実装)
  - MorseTable.pas (cMorse 移植) を使った rx_lookup/tx_lookup

  実装を省略した範囲 (fldigi固有のGUI/外部ハードウェア依存、または
  代替デコード手法のため):
  - SOM (Self-Organizing Map) デコード (find_winner/normalize/som_table)。
    fldigi では progdefaults.CWuseSOMdecoding で切替可能な代替デコード
    パスだが、既定は無効 (false) であり、主デコードパスである
    handle_event ステートマシンで十分な学習・移植価値があるため、
    本移植版では実装しない。
  - QSK (Full break-in) の右チャンネル制御信号生成、CW_KEYLINE (DTR/RTS
    キーイング)、WinKeyer/nanoIO/FLRIG/ICOM/YAESU/Elecraft/Kenwood 等の
    外部キーヤー連携
  - シンクスコープ (update_syncscope) 表示、CW ビューア (view_cw)
  - Farnsworth タイミング (CWusefarnsworth) は骨組みのみ用意し、既定
    (通常速度=Farnsworth速度) では通常タイミングと等価になる
  ============================================================================ }
unit CwModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP, MorseTable,
  DecodeEvidence;

const
  CW_SAMPLE_RATE = 8000;              // fldigi: #define CW_SAMPLERATE 8000
  CW_KWPM = (12 * CW_SAMPLE_RATE) div 10; // fldigi: #define KWPM (12*CW_SAMPLERATE/10)
  CW_KNUM = CW_KWPM div 10;           // fldigi: #define CWKNUM (KWPM/10)
  CW_INITIAL_SEND_SPEED = 18;         // fldigi: #define INITIAL_SEND_SPEED 18
  CW_TRACKING_FILTER_SIZE = 16;       // fldigi: #define TRACKING_FILTER_SIZE 16
  CW_MAX_MORSE_ELEMENTS = 6;          // fldigi: #define MAX_MORSE_ELEMENTS 6
  CW_FFT_SIZE = 2048;                 // fldigi: #define CW_FFT_SIZE 2048 (cw.cxx)
  CW_DEC_RATIO = 16;                  // fldigi: #define DEC_RATIO 16 (cw.cxx)

type
  { fldigi: enum CW_RX_STATE - RS_IDLE, RS_IN_TONE, RS_AFTER_TONE }
  TCwRxState = (
    crsIdle,
    crsInTone,
    crsAfterTone
  );

  { fldigi: enum CW_EVENT - CW_RESET_EVENT, CW_KEYDOWN_EVENT,
    CW_KEYUP_EVENT, CW_QUERY_EVENT }
  TCwEvent = (
    ceReset,
    ceKeyDown,
    ceKeyUp,
    ceQuery
  );

  { QSKシェイプ整形時の要素位置 (fldigi: enum START,FIRST,MID,LAST,SPACE) }
  TCwSendState = (cssStart, cssFirst, cssMid, cssLast, cssSpace);

  { TCwModem
    ---------------------------------------------------------------------
    fldigi: class cw : public modem (cw.h / cw.cxx) }
  TCwModem = class(TCustomModem)
  private
    FMorse: TMorseTable;             // fldigi: cMorse *morse

    // --- ユーザー設定パラメータ (fldigi: progdefaults.CWxxx の写し) ---
    FCwSpeed: Integer;               // fldigi: cw_speed / progdefaults.CWspeed (送信WPM)
    FCwLowerLimit: Integer;          // fldigi: progdefaults.CWlowerlimit (既定5)
    FCwUpperLimit: Integer;          // fldigi: progdefaults.CWupperlimit (既定50)
    FCwRange: Integer;               // fldigi: progdefaults.CWrange (既定10)
    FRiseTimeMs: Double;             // fldigi: progdefaults.CWrisetime (既定4.0ms)
    FUseFarnsworth: Boolean;         // fldigi: progdefaults.CWusefarnsworth
    FFarnsworthWPM: Double;          // fldigi: progdefaults.CWfarnsworth
    FDash2Dot: Double;               // fldigi: progdefaults.CWdash2dot (既定3.0)
    FUseBlackman: Boolean;           // fldigi: progdefaults.QSKshape (0=Hanning,1=Blackman)
    FUseDefaultWPM: Boolean;         // fldigi: usedefaultWPM
    FDefaultSpeed: Integer;          // fldigi: progdefaults.defCWspeed

    // --- 送信 (tx) パラメータ ---
    FCwSendSpeed: Integer;           // fldigi: cw_send_speed
    FCwSendDotLength: Int64;         // fldigi: cw_send_dot_length (usec)
    FCwSendDashLength: Int64;        // fldigi: cw_send_dash_length (usec)
    FSymbolLen: Integer;             // fldigi: symbollen (tx, samples/dot相当)
    FFSymLen: Integer;               // fldigi: fsymlen (tx, farnsworth用)
    FPhaseAcc: Double;               // fldigi: phaseacc (NCO位相)
    FLastSym: Integer;               // fldigi: lastsym
    FKeyShape: array[0..CW_KNUM-1] of Double; // fldigi: keyshape[CWKNUM]
    FKNum: Integer;                  // fldigi: knum (エッジのサンプル数)
    FFirstChar: Boolean;             // fldigi: first_char

    // --- 受信 (rx) パラメータ ---
    FCwReceiveSpeed: Integer;        // fldigi: cw_receive_speed
    FCwReceiveDotLength: Int64;      // fldigi: cw_receive_dot_length (usec)
    FCwReceiveDashLength: Int64;     // fldigi: cw_receive_dash_length (usec)
    FTwoDots: Int64;                 // fldigi: two_dots
    FCwNoiseSpikeThreshold: Int64;   // fldigi: cw_noise_spike_threshold
    FCwUpperLimitSamples: Int64;     // fldigi: cw_upper_limit (未使用だが保持)
    FCwLowerLimitSamples: Int64;     // fldigi: cw_lower_limit (未使用だが保持)
    FLowerWpm, FUpperWpm: Double;    // fldigi: lowerwpm, upperwpm

    FTrackingFilter: TMovingAverage; // fldigi: Cmovavg *trackingfilter
    FBitFilter: TMovingAverage;      // fldigi: Cmovavg *bitfilter
    FMixerFilt: TFftFilt;            // fldigi: fftfilt *cw_FFT_filter
    FFiltBandwidth: Double;          // 直近にフィルタ生成に使った Bandwidth (変更検出用)
    FCwTrackOn: Boolean;             // fldigi: cwTrack (基底クラスの CwTrack と同期)

    // --- decode_stream 用の AGC / しきい値状態 ---
    FSigAvg: Double;                 // fldigi: sig_avg
    FNoiseFloor: Double;             // fldigi: noise_floor
    FLastSnrDb: Double;   // 直近の SNR (Evidence 用)
    FSamplePos: Int64;    // Open からの通算サンプル数 (Replay 用)
    FAgcPeak: Double;                // fldigi: agc_peak
    FCwUpper, FCwLower: Double;      // fldigi: progdefaults.CWupper/CWlower (ヒステリシス閾値)
    FSigLevel: Double;               // fldigi: siglevel

    // --- ミキサー / サンプルカウンタ ---
    FMixerPhase: Double;             // fldigi: phaseacc (rx 側ミキサー用、tx とは別変数として保持)
    FSmplCtr: Cardinal;              // fldigi: smpl_ctr (受信サンプルカウンタ, usec相当として扱う)

    // --- handle_event 状態機械 ---
    FCwReceiveState: TCwRxState;     // fldigi: cw_receive_state
    FRxRepBuf: string;               // fldigi: rx_rep_buf (ドット/ダッシュ文字列)
    FRrStartTs: Cardinal;            // fldigi: cw_rr_start_timestamp
    FRrEndTs: Cardinal;              // fldigi: cw_rr_end_timestamp
    FLastElement: Int64;             // fldigi: handle_event() 内 static last_element
    FSpaceSent: Boolean;             // fldigi: handle_event() 内 static space_sent

    function Mixer(const AIn: TComplex): TComplex;
    procedure SyncTransmitParameters;
    procedure SyncParameters;
    procedure UpdateTracking(ADur1, ADur2: Int64);
    procedure DecodeStream(AValue: Double);
    function HandleEvent(AEvent: TCwEvent; out ASc: string): Boolean; // True=CW_SUCCESS
    { ADR-002: 復号文字を Evidence として送り出す。 }
    procedure EmitCwChar(ACh: Integer);

    function Nco(AFreq: Double): Double;
    procedure CreateEdges;
    procedure SendSymbol(ABit: Integer; ALen: Integer);
    procedure SendCh(AChar: Integer);

    procedure ComputeMetric(AValue: Double);
  public
    constructor Create(ASound: TCustomSoundDevice); reintroduce;
    destructor Destroy; override;

    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer; override;
    function TxProcess: Integer; override;

    { fldigi: void incWPM() / decWPM() / toggleWPM() }
    procedure IncWPM;
    procedure DecWPM;
    procedure ToggleWPM;

    { CW パラメータ設定 (fldigi: progdefaults.CWxxx の setter 相当) }
    procedure SetCwSpeed(AWpm: Integer);
    procedure SetFarnsworth(AOn: Boolean; AWpm: Double);
    procedure SetDash2Dot(AValue: Double);
    procedure SetRiseTime(AMilliseconds: Double);

    property CwSpeed: Integer read FCwSpeed;
    property CwReceiveSpeed: Integer read FCwReceiveSpeed;
  end;

implementation

{ ---- ユーティリティ ---- }

function UsecDiff(AEarlier, ALater: Cardinal): Cardinal; inline;
begin
  // fldigi: inline int cw::usec_diff(unsigned int earlier, unsigned int later)
  if AEarlier >= ALater then
    Result := 0
  else
    Result := ALater - AEarlier;
end;

{ TCwModem }

constructor TCwModem.Create(ASound: TCustomSoundDevice);
var
  Bfv: Integer;
begin
  inherited Create(ASound, mmCW);
  SampleRate := CW_SAMPLE_RATE;
  Capabilities := Capabilities + [mcBandwidth, mcRx, mcTx];

  FMorse := TMorseTable.Create;

  // --- fldigi: cw::cw() コンストラクタ相当の初期値 ---
  FCwSpeed := CW_INITIAL_SEND_SPEED;
  FCwLowerLimit := 5;
  FCwUpperLimit := 50;
  FCwRange := 10;
  FRiseTimeMs := 4.0;
  FUseFarnsworth := False;
  FFarnsworthWPM := CW_INITIAL_SEND_SPEED;
  FDash2Dot := 3.0;
  FUseBlackman := False;
  FUseDefaultWPM := False;
  FDefaultSpeed := 24;

  FCwSendSpeed := FCwSpeed;
  FCwReceiveSpeed := FCwSpeed;
  FTwoDots := 2 * CW_KWPM div FCwSpeed;
  FCwNoiseSpikeThreshold := FTwoDots div 4;
  FCwSendDotLength := CW_KWPM div FCwSendSpeed;
  FCwSendDashLength := 3 * FCwSendDotLength;
  FSymbolLen := Round(SampleRate * 1.2 / FCwSpeed);
  FFSymLen := Round(SampleRate * 1.2 / FFarnsworthWPM);

  Bandwidth := 150; // fldigi 既定: progdefaults.CWbandwidth = 150

  Bfv := FSymbolLen div (2 * CW_DEC_RATIO); // fldigi: symbollen/(2*DEC_RATIO)
  if Bfv < 1 then Bfv := 1;
  FBitFilter := TMovingAverage.Create(Bfv);
  FTrackingFilter := TMovingAverage.Create(CW_TRACKING_FILTER_SIZE);

  // fldigi: cw_FFT_filter = new fftfilt(1.0*bandwidth/samplerate, CW_FFT_SIZE);
  //         cw_FFT_filter->create_lpf(...) は reset_rx_filter() 内でも呼ばれる
  //         (Bandwidth 変更時は RxProcess 先頭で再生成する。下記参照)
  FMixerFilt := TFftFilt.Create(CW_FFT_SIZE);
  FMixerFilt.CreateLpf(Bandwidth / SampleRate);
  FFiltBandwidth := Bandwidth;

  FCwTrackOn := True;
  CwTrack := True; // 基底クラスのプロパティにも反映 (fldigi: cwTrack = true;)

  FAgcPeak := 1.0;
  FNoiseFloor := 1.0;
  FSigAvg := 0.0;
  FCwUpper := 0.6;  // fldigi 既定: progdefaults.CWupper
  FCwLower := 0.4;  // fldigi 既定: progdefaults.CWlower

  FFirstChar := True;

  CreateEdges;
  SyncParameters;

  Restart;
end;

destructor TCwModem.Destroy;
begin
  FMixerFilt.Free;
  FTrackingFilter.Free;
  FBitFilter.Free;
  FMorse.Free;
  inherited Destroy;
end;

procedure TCwModem.TxInit;
begin
  // fldigi: cw::tx_init()
  FPhaseAcc := 0;
  FLastSym := 0;
end;

procedure TCwModem.RxInit;
begin
  // fldigi: cw::rx_init()
  FCwReceiveState := crsIdle;
  FSmplCtr := 0;
  FRxRepBuf := '';
  FAgcPeak := 0;
  FUseDefaultWPM := False;
  EmitStatus(Format('CW Rx %d', [FCwReceiveSpeed]));
end;

procedure TCwModem.Restart;
begin
  // fldigi: cw::restart() は空実装。ここでは同期パラメータの再計算のみ行う。
  SyncParameters;
  RxInit;
end;

{ ---- WPM/speed 管理 (fldigi: sync_transmit_parameters/sync_parameters) ---- }

procedure TCwModem.SyncTransmitParameters;
var
  NuSymbolLen, NuFSymLen: Integer;
  Changed: Boolean;
begin
  // fldigi: void cw::sync_transmit_parameters()
  FCwSendDotLength := CW_KWPM div FCwSpeed;
  FCwSendDashLength := 3 * FCwSendDotLength;

  NuSymbolLen := Round(SampleRate * 1.2 / FCwSpeed);
  if FUseFarnsworth and (FFarnsworthWPM > 0) then
    NuFSymLen := Round(SampleRate * 1.2 / FFarnsworthWPM)
  else
    NuFSymLen := NuSymbolLen;

  Changed := (FSymbolLen <> NuSymbolLen) or (NuFSymLen <> FFSymLen);
  if Changed then
  begin
    FSymbolLen := NuSymbolLen;
    FFSymLen := NuFSymLen;
    CreateEdges;
  end;
end;

procedure TCwModem.SyncParameters;
begin
  // fldigi: void cw::sync_parameters()
  SyncTransmitParameters;

  // fldigi: 送信速度・トラッキングON/OFFが変わったらトラッキングをリセット
  if (FCwTrackOn <> CwTrack) or (FCwSendSpeed <> FCwSpeed) then
  begin
    FTrackingFilter.Reset;
    FTwoDots := 2 * FCwSendDotLength;
    UpdateCwRcvWPM(FCwSendSpeed);
  end;
  FCwTrackOn := CwTrack;
  FCwSendSpeed := FCwSpeed;

  // 受信範囲
  FLowerWpm := FCwSendSpeed - FCwRange;
  FUpperWpm := FCwSendSpeed + FCwRange;
  if FLowerWpm < FCwLowerLimit then FLowerWpm := FCwLowerLimit;
  if FUpperWpm > FCwUpperLimit then FUpperWpm := FCwUpperLimit;
  FCwLowerLimitSamples := Round(2 * CW_KWPM / FUpperWpm);
  FCwUpperLimitSamples := Round(2 * CW_KWPM / FLowerWpm);

  if FCwTrackOn then
  begin
    if FTwoDots > 1 then
      FCwReceiveSpeed := CW_KWPM div (FTwoDots div 2)
    else
      FCwReceiveSpeed := FCwSendSpeed;
  end
  else
  begin
    FCwReceiveSpeed := FCwSendSpeed;
    FTwoDots := 2 * FCwSendDotLength;
  end;

  if FCwReceiveSpeed > 0 then
    FCwReceiveDotLength := CW_KWPM div FCwReceiveSpeed
  else
    FCwReceiveDotLength := CW_KWPM div 5;

  FCwReceiveDashLength := 3 * FCwReceiveDotLength;
  FCwNoiseSpikeThreshold := FCwReceiveDotLength div 2;

  UpdateCwRcvWPM(FCwReceiveSpeed);
end;

procedure TCwModem.UpdateTracking(ADur1, ADur2: Int64);
const
  MinDot = CW_KWPM div 200;
  MaxDash = 3 * CW_KWPM div 5;
begin
  // fldigi: inline void cw::update_tracking(int dur_1, int dur_2)
  if (ADur1 > ADur2) and (ADur1 > 4 * ADur2) then Exit;
  if (ADur2 > ADur1) and (ADur2 > 4 * ADur1) then Exit;
  if (ADur1 < MinDot) or (ADur2 < MinDot) then Exit;
  if (ADur2 > MaxDash) then Exit; // fldigi: dur_2 > max_dash (2回目の判定は同一条件の重複)

  FTwoDots := Round(FTrackingFilter.Run((ADur1 + ADur2) / 2));
  SyncParameters;
end;

procedure TCwModem.SetCwSpeed(AWpm: Integer);
begin
  if FUseDefaultWPM then Exit;
  if AWpm < FCwLowerLimit then AWpm := FCwLowerLimit;
  if AWpm > FCwUpperLimit then AWpm := FCwUpperLimit;
  FCwSpeed := AWpm;
  SyncParameters;
  EmitStatus(Format('CW Rx %d', [FCwReceiveSpeed]));
end;

procedure TCwModem.IncWPM;
begin
  // fldigi: void cw::incWPM()
  if FUseDefaultWPM then Exit;
  if FCwSpeed < FCwUpperLimit then
    SetCwSpeed(FCwSpeed + 1);
end;

procedure TCwModem.DecWPM;
begin
  // fldigi: void cw::decWPM()
  if FUseDefaultWPM then Exit;
  if FCwSpeed > FCwLowerLimit then
    SetCwSpeed(FCwSpeed - 1);
end;

procedure TCwModem.ToggleWPM;
var
  Saved: Integer;
begin
  // fldigi: void cw::toggleWPM()
  FUseDefaultWPM := not FUseDefaultWPM;
  if FUseDefaultWPM then
  begin
    Saved := FCwSpeed;
    FCwSpeed := FDefaultSpeed;
    FDefaultSpeed := Saved; // wpm<->CWspeed の一時退避 (fldigi: wpm 変数相当)
  end;
  SyncParameters;
  if FUseDefaultWPM then
    EmitStatus(Format('CW %s Rx %d', ['*', FCwReceiveSpeed]))
  else
    EmitStatus(Format('CW %s Rx %d', [' ', FCwReceiveSpeed]));
end;

procedure TCwModem.SetFarnsworth(AOn: Boolean; AWpm: Double);
begin
  FUseFarnsworth := AOn;
  if AWpm > 0 then
    FFarnsworthWPM := AWpm;
  SyncParameters;
end;

procedure TCwModem.SetDash2Dot(AValue: Double);
begin
  if AValue > 1.0 then
    FDash2Dot := AValue;
end;

procedure TCwModem.SetRiseTime(AMilliseconds: Double);
begin
  FRiseTimeMs := AMilliseconds;
  CreateEdges;
end;

{ ---- 受信 DSP ---- }

function TCwModem.Mixer(const AIn: TComplex): TComplex;
begin
  // fldigi: cmplx cw::mixer(cmplx in)
  Result := CplxMake(Cos(FMixerPhase), Sin(FMixerPhase)) * AIn;
  FMixerPhase := FMixerPhase + TWOPI * Frequency / SampleRate;
  if FMixerPhase > TWOPI then
    FMixerPhase := FMixerPhase - TWOPI;
end;

procedure TCwModem.ComputeMetric(AValue: Double);
var
  M: Double;
begin
  // fldigi: decode_stream() 内の metric 計算部分を分離
  M := 0.8 * Metric;
  if (FNoiseFloor > 1e-4) and (FNoiseFloor < FSigAvg) then
  begin
    FLastSnrDb := 20 * Log10(FSigAvg / FNoiseFloor);   { Evidence 用に保持 }
    M := M + 0.2 * ClampF(2.5 * FLastSnrDb, 0, 100);
  end;
  SetMetric(M);
end;

procedure TCwModem.DecodeStream(AValue: Double);
var
  Attack, Decay: Integer;
  NormNoise, NormSig, Diff: Double;
  Sc: string;
  Value: Double;
begin
  // fldigi: void cw::decode_stream(double value)
  // (progdefaults.cwrx_attack/decay は既定 "MEDIUM" 相当に固定)
  Attack := 200;
  Decay := 1000;

  Value := AValue;

  FSigAvg := DecayAvg(FSigAvg, Value, Decay);

  if Value < FSigAvg then
  begin
    if Value < FNoiseFloor then
      FNoiseFloor := DecayAvg(FNoiseFloor, Value, Attack)
    else
      FNoiseFloor := DecayAvg(FNoiseFloor, Value, Decay);
  end;
  if Value > FSigAvg then
  begin
    if Value > FAgcPeak then
      FAgcPeak := DecayAvg(FAgcPeak, Value, Attack)
    else
      FAgcPeak := DecayAvg(FAgcPeak, Value, Decay);
  end;

  if FAgcPeak > 1e-12 then
  begin
    NormNoise := FNoiseFloor / FAgcPeak;
    NormSig := FSigAvg / FAgcPeak;
  end
  else
  begin
    NormNoise := 0;
    NormSig := 0;
  end;
  FSigLevel := NormSig;

  if FAgcPeak <> 0 then
    Value := Value / FAgcPeak
  else
    Value := 0;

  ComputeMetric(Value);

  Diff := NormSig - NormNoise;
  FCwUpper := NormSig - 0.2 * Diff;
  FCwLower := NormNoise + 0.7 * Diff;

  // Power detection using hysteresis detector
  if (Value > FCwUpper) and (FCwReceiveState <> crsInTone) then
    HandleEvent(ceKeyDown, Sc);
  if (Value < FCwLower) and (FCwReceiveState = crsInTone) then
    HandleEvent(ceKeyUp, Sc);

  if HandleEvent(ceQuery, Sc) then
  begin
    if Sc <> '' then
      EmitCwChar(Ord(Sc[1]));
  end;
end;

procedure TCwModem.EmitCwChar(ACh: Integer);
{ ADR-002: CW は文字ごとの軟判定尺度を持たない。
  復号が「短点・長点の時間パターンをモールス表と照合する」方式で、
  一致しなければ何も出さない (= 候補が1つか0つ) ためである。
  候補に順位をつけるには、表の照合を「距離つきの近傍探索」に作り替える
  必要があり、それは Phase 3 の Algorithm Portfolio の仕事になる。
  ここで無理に数値をでっち上げると、根拠のない尺度が Evidence として
  流れてしまうので、MetricKind は emkNone のままにする。
  一方 SNR は持っているので、それは載せる。 }
var
  ev: TDecodeEvidence;
begin
  ev := SingleCandidateEvidence(ACh, DecoderName);
  ev.HasSnr := True;
  ev.SnrDb := FLastSnrDb;
  ev.SamplePos := FSamplePos;
  EmitDecode(ev);
end;

function TCwModem.HandleEvent(AEvent: TCwEvent; out ASc: string): Boolean;
var
  ElementUsec: Cardinal;
begin
  // fldigi: int cw::handle_event(int cw_event, std::string &sc)
  Result := False;
  ASc := '';

  case AEvent of
    ceReset:
      begin
        SyncParameters;
        FCwReceiveState := crsIdle;
        FSmplCtr := 0;
        FRxRepBuf := '';
      end;

    ceKeyDown:
      begin
        // A receive tone start can only happen while idle or mid-char.
        if FCwReceiveState = crsInTone then
          Exit(False);
        if FCwReceiveState = crsIdle then
        begin
          FSmplCtr := 0;
          FRxRepBuf := '';
        end;
        FRrStartTs := FSmplCtr;
        FCwReceiveState := crsInTone;
        Result := False;
      end;

    ceKeyUp:
      begin
        if FCwReceiveState <> crsInTone then
          Exit(False);
        FRrEndTs := FSmplCtr;
        ElementUsec := UsecDiff(FRrStartTs, FRrEndTs);

        SyncParameters;

        if (FCwNoiseSpikeThreshold > 0) and (ElementUsec < FCwNoiseSpikeThreshold) then
        begin
          FCwReceiveState := crsIdle;
          Exit(False);
        end;

        // 適応速度追跡: dot-dash / dash-dot ペアの比較
        if FLastElement > 0 then
        begin
          if (Int64(ElementUsec) > 2 * FLastElement) and (Int64(ElementUsec) < 4 * FLastElement) then
            UpdateTracking(FLastElement, ElementUsec);
          if (FLastElement > 2 * Int64(ElementUsec)) and (FLastElement < 4 * Int64(ElementUsec)) then
            UpdateTracking(ElementUsec, FLastElement);
        end;
        FLastElement := ElementUsec;

        if Int64(ElementUsec) <= FTwoDots then
          FRxRepBuf := FRxRepBuf + CW_DOT_REPRESENTATION
        else
          FRxRepBuf := FRxRepBuf + CW_DASH_REPRESENTATION;

        if Length(FRxRepBuf) > CW_MAX_MORSE_ELEMENTS then
        begin
          FCwReceiveState := crsIdle;
          FSmplCtr := 0;
          FRxRepBuf := '';
          Exit(False);
        end;

        FCwReceiveState := crsAfterTone;
        Result := False;
      end;

    ceQuery:
      begin
        if FCwReceiveState = crsInTone then
          Exit(False);
        SyncParameters;
        ElementUsec := UsecDiff(FRrEndTs, FSmplCtr);

        // SHORT: まだ何もしない
        if Int64(ElementUsec) < 2 * FCwReceiveDotLength then
          Exit(False);

        // MEDIUM: 文字区切り
        if (Int64(ElementUsec) >= 2 * FCwReceiveDotLength) and
           (Int64(ElementUsec) <= 4 * FCwReceiveDotLength) and
           (FCwReceiveState = crsAfterTone) then
        begin
          ASc := FMorse.RxLookup(FRxRepBuf);
          if ASc = '' then
            ASc := '*'; // fldigi: progdefaults.CW_noise 既定値 '*'
          FRxRepBuf := '';
          FCwReceiveState := crsIdle;
          FSpaceSent := False;
          Exit(True);
        end;

        // LONG: 単語区切り
        if (Int64(ElementUsec) > 4 * FCwReceiveDotLength) and (not FSpaceSent) then
        begin
          ASc := ' ';
          FSpaceSent := True;
          Exit(True);
        end;

        Result := False;
      end;
  end;
end;

function TCwModem.RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
{ fldigi: int cw::rx_process(const double *buf, int len)
    -> reset_rx_filter() (帯域変更時のフィルタ再生成)
    -> rx_FFTprocess() (fftfilt + DEC_RATIO間引き) }
var
  i, j, nOut: Integer;
  Z: TComplex;
  FiltOut: TComplexArray;
  Value: Double;
begin
  { Replay / 再現のために通算サンプル位置を進める (X-06 の下地)。 }
  Inc(FSamplePos, ALen);
  // fldigi: reset_rx_filter() (CWmfilt="整合フィルタ"モードは未実装のため、
  // Bandwidth プロパティの変更のみを検出条件とする)
  if Bandwidth <> FFiltBandwidth then
  begin
    FMixerFilt.Free;
    FMixerFilt := TFftFilt.Create(CW_FFT_SIZE);
    FMixerFilt.CreateLpf(Bandwidth / SampleRate);
    FFiltBandwidth := Bandwidth;
  end;

  for i := 0 to ALen - 1 do
  begin
    Z := CplxMake(ABuf[i], ABuf[i]);
    Z := Mixer(Z);
    nOut := FMixerFilt.Run(Z, FiltOut);

    for j := 0 to nOut - 1 do
    begin
      Inc(FSmplCtr);
      // fldigi: if (smpl_ctr % DEC_RATIO) continue;
      if FSmplCtr mod CW_DEC_RATIO <> 0 then Continue;

      Value := CplxAbs(FiltOut[j]);
      Value := FBitFilter.Run(Value);

      DecodeStream(Value);
    end;
  end;
  Result := 0;
end;

{ ---- 送信 DSP ---- }

function TCwModem.Nco(AFreq: Double): Double;
begin
  // fldigi: inline double cw::nco(double freq)
  FPhaseAcc := FPhaseAcc + 2.0 * Pi * AFreq / SampleRate;
  if FPhaseAcc > TWOPI then
    FPhaseAcc := FPhaseAcc - TWOPI;
  Result := Sin(FPhaseAcc);
end;

procedure TCwModem.CreateEdges;
var
  i: Integer;
begin
  // fldigi: void cw::create_edges() (QSK 用 keyshape のみ移植。
  // QSKkeyshape (右チャンネル制御) は QSK 機能自体を省略するため対象外)
  for i := 0 to CW_KNUM - 1 do
    FKeyShape[i] := 1.0;

  FKNum := Round(FRiseTimeMs * CW_SAMPLE_RATE / 1000);
  if FKNum >= FSymbolLen then
    FKNum := FSymbolLen;
  if FKNum >= CW_KNUM then
    FKNum := CW_KNUM - 1;
  if FKNum < 0 then
    FKNum := 0;

  if FUseBlackman then
  begin
    for i := 0 to FKNum - 1 do
      FKeyShape[i] := 0.42 - 0.50 * Cos(Pi * i / FKNum) + 0.08 * Cos(2 * Pi * i / FKNum);
  end
  else
  begin
    for i := 0 to FKNum - 1 do
      FKeyShape[i] := 0.5 * (1.0 - Cos(Pi * i / FKNum));
  end;
end;

procedure TCwModem.SendSymbol(ABit: Integer; ALen: Integer);
var
  Buf: array of Double;
  n: Integer;
  TxFreq: Double;
  Amp: Double;
begin
  // fldigi: void cw::send_symbol(int bit, int len, int state)
  // (QSK 右チャンネル信号 qskbuf の生成は省略、A2 (CWキーイング波形)
  //  のみ生成する)
  SyncTransmitParameters;

  if ALen <= 0 then
    Exit;

  SetLength(Buf, ALen);
  TxFreq := TxFrequency;

  if ABit = 1 then
  begin
    for n := 0 to ALen - 1 do
    begin
      Amp := Nco(TxFreq);
      if n < FKNum then
        Amp := Amp * FKeyShape[n];
      if (ALen - n) < FKNum then
        Amp := Amp * FKeyShape[ALen - n];
      Buf[n] := Amp;
    end;
  end
  else
  begin
    for n := 0 to ALen - 1 do
      Buf[n] := 0;
  end;

  if Assigned(Sound) then
    Sound.WriteSamples(Buf, ALen);
end;

procedure TCwModem.SendCh(AChar: Integer);
var
  Code: string;
  KFactor, Tc, Ta, Tch, Twd, W: Double;
  Elements, n: Integer;
begin
  // fldigi: void cw::send_ch(int ch)
  KFactor := CW_SAMPLE_RATE / 1000.0;
  Tc := 1200.0 / FCwSpeed;
  Ta := 0.0;
  Tch := 3 * Tc;
  Twd := 4 * Tc;

  if FUseFarnsworth and (FCwSpeed > FFarnsworthWPM) then
  begin
    Ta := 60000.0 / FFarnsworthWPM - 37200.0 / FCwSpeed;
    Tch := 3 * Ta / 19;
    Twd := 4 * Ta / 19;
  end;
  Tc := Tc * KFactor;
  Tch := Tch * KFactor;
  Twd := Twd * KFactor;

  SyncParameters;

  if (AChar = Ord(' ')) or (AChar = 10) then
  begin
    SendSymbol(0, Round(Twd));
    EmitEchoChar(AChar);
    Exit;
  end;

  Code := FMorse.TxLookup(Chr(AChar and $FF));
  if Code = '' then
    Exit;

  W := (FDash2Dot + 1) / (FDash2Dot - 1);
  Elements := Length(Code);

  for n := 1 to Elements do
  begin
    if Code[n] = '-' then
      SendSymbol(1, Round((W + 1) * FSymbolLen))
    else
      SendSymbol(1, Round((W - 1) * FSymbolLen));

    if n < Elements then
      SendSymbol(0, Round(Tc))
    else
      SendSymbol(0, Round(Tch));
  end;

  EmitEchoChar(Ord(AChar));
end;

function TCwModem.TxProcess: Integer;
var
  C: Integer;
begin
  // fldigi: int cw::tx_process()
  // (FLRIG/WinKeyer/nanoIO/ICOM/YAESU/Elecraft/Kenwood/CW_KEYLINE 等の
  //  外部ハードウェア分岐は省略し、通常のサウンド送信のみ実装)
  C := FetchTxChar;

  if C = MODEM_TX_CHAR_NODATA then
  begin
    if StopFlag then
    begin
      StopFlag := False;
      EmitEchoChar(10);
      FFirstChar := True;
      Exit(-1);
    end;
    Sleep(10);
    Exit(0);
  end;

  if (C = MODEM_TX_CHAR_ETX) or StopFlag then
  begin
    StopFlag := False;
    EmitEchoChar(10);
    FFirstChar := True;
    Exit(-1);
  end;

  SendCh(C);
  FFirstChar := False;
  Result := 0;
end;

end.
