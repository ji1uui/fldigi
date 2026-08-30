{ ============================================================================
  RttyModemImpl.pas

  fldigi の src/include/rtty.h / src/cw_rtty/rtty.cxx (class rtty) を
  Lazarus/FPC 向けに移植した RTTY (Radio Teletype / Baudot) モデムの
  具象実装。TCustomModem (Modem.pas) を継承する。

  fldigi との対応 (実装した範囲):
  ----------------------------------------------------------------------------
  - Baudot 5bit 符号表 (letters[]/figures[]) と baudot_enc/baudot_dec
  - Mark/Space ミキサー (rtty::mixer) + fldigi 本来の fftfilt
    (ModemDSP.TFftFilt。Overlap-Add FFT畳み込み、rtty_filter()による
    raised-cosine整合フィルタ) + 包絡線検波
    【2026-08 フィルタ品質改善】当初は ModemDSP.TComplexLowpass (1次IIR)
    で代替していたが、fldigi 本来の fftfilt::rtty_filter() を
    ModemDSP.TFftFilt として移植し、置き換えた (rtty.cxx の
    reset_filters()/FILTLEN[] をそのまま踏襲)。TFftFilt.Run() は
    flen2 サンプル溜まるまで0を返し、溜まったら flen2 個まとめて返す
    ブロック処理のため、RxProcess() 内の包絡線検波以降のロジックは
    ProcessFilteredSample() に切り出し、フィルタが実際に出力した
    サンプルの数だけ呼び出す構造に変更した (fldigi rtty.cxx の
    `for (int i = 0; i < n_out; i++)` ループにそのまま対応)。
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
  Classes, SysUtils, Math, SoundIntf, ModemTypes, Modem, ModemDSP,
  DecodeEvidence;

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
  { fldigi: rtty::FILTLEN[] (rtty.cxx)。BAUD[]と同じ添字で引く
    fftfilt の flen (2の冪乗、baudが速いほど短い)。 }
  RttyFiltLenTable: array[0..9] of Integer = (512, 512, 512, 512, 512, 512, 512, 256, 128, 64);

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
    FBaudIndex: Integer;     // fldigi: progdefaults.rtty_baud (RttyFiltLenTable添字用)
    FBits: Integer;          // fldigi: rtty_bits (5/7/8)
    FParity: TRttyParity;    // fldigi: rtty_parity
    FStopBits: Double;       // fldigi: rtty_stop -> stl (1.0/1.5/2.0)
    FSymbolLen: Integer;     // fldigi: symbollen
    FStopLen: Integer;       // fldigi: stoplen

    // --- 受信 DSP 状態 ---
    FMarkPhase: Double;      // fldigi: mark_phase
    FSpacePhase: Double;     // fldigi: space_phase
    FMarkFilt: TFftFilt;     // fldigi: fftfilt *mark_filt
    FSpaceFilt: TFftFilt;    // fldigi: fftfilt *space_filt
    FBitBuf: array[0..RTTY_MAXBITS-1] of Boolean; // fldigi: bit_buf[MAXBITS]
    { ADR-002: 軟判定の余裕を運ぶための追加状態。
      ATC 判定変数 V3 の符号がビット値、大きさが「判定境界からの距離」に
      あたる。包絡線エネルギーで正規化すると -1..+1 の無次元量になり、
      0 に近いほど「どちらとも言えない」ビットである。
      これを文字組み立ての間ずっと保持しておき、最も弱かったビットを
      反転した文字を第2候補として出す。 }
    FMarginBuf: array[0..RTTY_MAXBITS-1] of Double;  // FBitBuf と同期して流す
    FLastMargin: Double;                 // 直近サンプルの正規化余裕
    FDataMargin: array[0..RTTY_MAXBITS-1] of Double; // データビットごとの余裕
    FLastSnrDb: Double;                  // 直近に算出した SNR (Evidence 用)
    FSamplePos: Int64;                   // Open からの通算サンプル数 (Replay 用)
    FMarkEnv, FMarkNoise: Double;  // fldigi: mark_env, mark_noise
    FSpaceEnv, FSpaceNoise: Double;// fldigi: space_env, space_noise
    FNoiseFloor: Double;          // fldigi: noise_floor
    FBit: Boolean;                // fldigi: bit

    FRxState: TRttyRxState;  // fldigi: rxstate
    FRxMode: Integer;        // fldigi: rxmode (LETTERS/FIGURES)
    { Unshift On Space。fldigi は progdefaults の全体設定だったが、
      本移植版ではインスタンスごとに持つ。理由は2つある。
        (1) 送信用と受信用に別インスタンスを持つ設計なので、全体設定だと
            片方の変更がもう片方にも及んでしまう (実際に不具合だった)。
        (2) 設定違いの復調器を同じ音声に対して並列評価する
            (v1.1 C-06) には、設定がインスタンスに閉じている必要がある。
      「状態をインスタンスに閉じ込める」規律は、並列化を後回しにしても
      後から入れられる形を保つための対価である (ADR-009)。 }
    FUosTx: Boolean;
    FUosRx: Boolean;
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
    { ADR-002: 復調した文字を Evidence として送り出す。
      軟判定の余裕から「文字全体の確からしさ」と「第2候補」を作る。
      文字の確からしさは、その文字を構成したデータビットのうち
      最も余裕が小さかったものが決める (弱いビットが1つでもあれば
      文字全体が危うい)。第2候補は、その最も弱いビットを反転した文字。
      これは Phase 4 の Context Assistance が「補正候補」として使う。 }
    procedure EmitDecodedChar(ACh: Integer);
    { 副作用を残さない仮復号 (第2候補の算出用)。 }
    function SpeculativeDecode(AData: Integer): Integer;
    function IsMark: Boolean;
    function IsMarkSpace(out ACorrection: Integer): Boolean;
    function RxBit(ABit: Boolean): Boolean; // fldigi: rtty::rx(bool bit)
    procedure ResetFilters;  // fldigi: rtty::reset_filters()
    procedure ProcessFilteredSample(const AZMark, AZSpace: TComplex);
      // fldigi: rtty::rx_process() の n_out ループ本体

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
    { 設定がインスタンスに閉じていることを外から確かめられるようにする。 }
    property UnshiftOnSpaceTx: Boolean read FUosTx write SetUnshiftOnSpaceTx;
    property UnshiftOnSpaceRx: Boolean read FUosRx write SetUnshiftOnSpaceRx;
  end;

implementation


const
  { 第2候補を出す軟判定余裕のしきい値。
    これより余裕がある (判定が明確な) 文字には候補を足さない。
    足しても選ばれないうえ、Phase 4 の補正候補提示が雑音だらけになる。 }
  ALT_CANDIDATE_MARGIN = 0.5;

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
  FBaudIndex := 1;
  FBaud := RttyBaudTable[FBaudIndex];     // 既定 45.45 baud
  FBits := 5;
  FParity := rpNone;
  FStopBits := 1.5;
  { fldigi の progdefaults 既定値 (UOStx/UOSrx = true) と同じ }
  FUosTx := True;
  FUosRx := True;

  FMarkFilt := TFftFilt.Create(RttyFiltLenTable[FBaudIndex]);
  FSpaceFilt := TFftFilt.Create(RttyFiltLenTable[FBaudIndex]);

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

  ResetFilters;

  for i := 0 to RTTY_MAXBITS - 1 do
    FBitBuf[i] := False;

  FMarkNoise := 0;
  FSpaceNoise := 0;
  FBit := True;
end;

procedure TRttyModem.ResetFilters;
begin
  // fldigi: void rtty::reset_filters()
  FMarkFilt.Free;
  FMarkFilt := TFftFilt.Create(RttyFiltLenTable[FBaudIndex]);
  FMarkFilt.RttyFilter(FBaud / SampleRate);

  FSpaceFilt.Free;
  FSpaceFilt := TFftFilt.Create(RttyFiltLenTable[FBaudIndex]);
  FSpaceFilt.RttyFilter(FBaud / SampleRate);
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
    FBaudIndex := AIndex;
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
  FUosTx := AOn;
end;

procedure TRttyModem.SetUnshiftOnSpaceRx(AOn: Boolean);
begin
  FUosRx := AOn;
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

function TRttyModem.SpeculativeDecode(AData: Integer): Integer;
{ 「もしビットが違っていたら何の文字だったか」を試す仮復号。

  BaudotDec は文字シフト/数字シフトの状態 (FRxMode) を書き換える。
  仮復号でそれを動かしてしまうと、あり得たかもしれない候補の副作用で
  本物のシフト状態が壊れ、以降の数字が文字として出てくる。
  実際にこれで "12345" が "WERT" になった (Baudot では 2=W,3=E,4=R,5=T)。
  仮の計算なので、状態は必ず元に戻す。 }
var
  savedMode, savedData: Integer;
begin
  savedMode := FRxMode;
  savedData := FRxData;
  try
    FRxData := AData;
    Result := DecodeChar;
  finally
    FRxData := savedData;
    FRxMode := savedMode;
  end;
end;

procedure TRttyModem.EmitDecodedChar(ACh: Integer);
var
  ev: TDecodeEvidence;
  i, dataBits, altCh: Integer;
  weakest: Integer;
  weakestMargin: Double;
begin
  dataBits := FBits;
  weakest := -1;
  weakestMargin := 1.0;
  for i := 0 to dataBits - 1 do
    if FDataMargin[i] < weakestMargin then
    begin
      weakestMargin := FDataMargin[i];
      weakest := i;
    end;

  ev := ScoredCandidateEvidence(ACh, weakestMargin, emkSoftMargin, DecoderName);
  ev.HasSnr := True;
  ev.SnrDb := FLastSnrDb;
  ev.HasFreqOffset := True;
  ev.FreqOffsetHz := FFreqErr;
  ev.SamplePos := FSamplePos;

  { 最も弱いビットを反転した文字を第2候補にする。
    余裕が十分ある (= 判定が明確) ときは候補を増やさない。
    増やしても選ばれないうえ、Phase 4 の補正候補提示が
    雑音だらけになるため。 }
  if (weakest >= 0) and (weakestMargin < ALT_CANDIDATE_MARGIN) then
  begin
    altCh := SpeculativeDecode(FRxData xor (1 shl weakest));
    if (altCh <> 0) and (altCh <> ACh) then
      { 第2候補の尺度は「反転してしまった側」なので符号を反転して渡す }
      AddCandidate(ev, altCh, -weakestMargin);
  end;

  EmitDecode(ev);
end;

function TRttyModem.RxBit(ABit: Boolean): Boolean;
var
  i, Correction, C: Integer;
  ParityBits: Integer;
begin
  // fldigi: bool rtty::rx(bool bit)
  Result := False;

  for i := 1 to FSymbolLen - 1 do
  begin
    FBitBuf[i-1] := FBitBuf[i];
    FMarginBuf[i-1] := FMarginBuf[i];
  end;
  FBitBuf[FSymbolLen - 1] := ABit;
  FMarginBuf[FSymbolLen - 1] := FLastMargin;

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
            for i := 0 to High(FDataMargin) do
              FDataMargin[i] := 0;
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
          { このビットの判定余裕を記録する。IsMark と同じ位置
            (シンボル中央) の値を使う。 }
          if FBitCntr <= High(FDataMargin) then
            FDataMargin[FBitCntr] := Abs(FMarginBuf[FSymbolLen div 2]);
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
                EmitDecodedChar(C);
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
  FLastSnrDb := Snr;   { Evidence へ載せるため保持する }
  SetMetric(ClampF(Snr * 5.0, 0.0, 100.0));
end;

procedure TRttyModem.ProcessFilteredSample(const AZMark, AZSpace: TComplex);
{ fldigi: rtty::rx_process() の `for (int i = 0; i < n_out; i++)` ループの
  本体 (フィルタ出力1サンプル分の包絡線検波~AFCまで)。 }
var
  MarkMag, SpaceMag: Double;
  MClipped, SClipped: Double;
  V3: Double;
  Bit, RxBitValue: Boolean;
  Mp0, Mp1: Integer;
  Ferr: Double;
  AfcSpeedDiv: Integer;
  MarginDenom: Double;
begin
  MarkMag := CplxAbs(AZMark);
  FMarkEnv := DecayAvg(FMarkEnv, MarkMag, IfThen(MarkMag > FMarkEnv, FSymbolLen div 4, FSymbolLen * 16));
  FMarkNoise := DecayAvg(FMarkNoise, MarkMag, IfThen(MarkMag < FMarkNoise, FSymbolLen div 4, FSymbolLen * 48));

  SpaceMag := CplxAbs(AZSpace);
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

  { 軟判定の余裕。V3 は「振幅の2乗」の次元なので、包絡線エネルギーで
    割ると無次元になる。0 が判定境界、±1 が「完全に振り切った」状態。 }
  MarginDenom := Sqr(FMarkEnv - FNoiseFloor) + Sqr(FSpaceEnv - FNoiseFloor);
  if MarginDenom > 1e-12 then
    FLastMargin := ClampF(V3 / MarginDenom, -1.0, 1.0)
  else
    FLastMargin := 0;

  FMarkHistory[FInpPtr] := AZMark;
  FSpaceHistory[FInpPtr] := AZSpace;
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

function TRttyModem.RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
{ fldigi: rtty::rx_process(). mark_filt/space_filt は同じ flen で同期して
  処理されるため、mark_filt の戻り値は捨て、space_filt の戻り値 (n_out)
  だけでブロック出力の有無・サンプル数を判定する (fldigi と同じ)。 }
var
  i, j, nOut: Integer;
  Sample, ZMark, ZSpace: TComplex;
  MarkOut, SpaceOut: TComplexArray;
begin
  ComputeMetric;
  { Replay / 再現のために通算サンプル位置を進める (X-06 の下地)。 }
  Inc(FSamplePos, ALen);

  for i := 0 to ALen - 1 do
  begin
    Sample := CplxMake(ABuf[i], ABuf[i]);

    ZMark := Mixer(FMarkPhase, Frequency + FShift / 2.0, Sample);
    FMarkFilt.Run(ZMark, MarkOut);

    ZSpace := Mixer(FSpacePhase, Frequency - FShift / 2.0, Sample);
    nOut := FSpaceFilt.Run(ZSpace, SpaceOut);

    for j := 0 to nOut - 1 do
      ProcessFilteredSample(MarkOut[j], SpaceOut[j]);
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
    EnsureTxBuf(ALen);   // X-04: 通常は既に足りていて何もしない
    for i := 0 to ALen - 1 do
      FTxSymbolBuf[i] := Nco(Freq);
    Sound.WriteSamples(FTxSymbolBuf, ALen);
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
        if FUosRx then
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
    if FUosTx then
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
