{ ============================================================================
  Modem.pas

  fldigi の src/include/modem.h / src/trx/modem.cxx (class modem) を
  Lazarus/FPC 向けに移植したモデム基底クラス。

  設計方針 (fldigi との対応):
  ----------------------------------------------------------------------------
  1. 抽象基底クラス構造
     fldigi の "class modem" は tx_init/rx_init/restart/rx_process を
     純粋仮想関数とし、PSK/RTTY/MFSK等の各モデムがこれを継承・実装する
     (Strategy パターン)。本移植版でも TCustomModem を abstract クラスとし、
     同じ4メソッドを abstract として要求する。

  2. スレッド安全性
     fldigi は音声処理を専用スレッド (TRX_TID) で回し、GUI 更新は
     qrunner (REQ() マクロ) 経由でメインスレッドのキューに積む。
     本移植版では TCustomModem 自体はスレッドを持たず「呼ばれたら
     1ブロック処理して返る」形にし (下記 TModemEngine が駆動する)、
     GUI 通知は仮想メソッド DoNotify* 経由でイベントとして外部に伝える。
     実際のスレッド境界を越えた安全な配送は ModemUI.pas (TModemUI) が
     TThread.Queue/Synchronize を使って担当する。

  3. 状態・パラメータ
     fldigi の modem クラスが持つ frequency / bandwidth / reverse /
     metric / squelch / samplerate 等のプロパティをそのまま
     プロパティとして再現。

  4. 送受信データの受け渡し
     fldigi は get_tx_char()/put_rx_char() という「1文字ずつ」のコール
     バック関数 (fl_digi.cxx 側にグローバル定義) を介して端末側と
     やり取りする。本移植版ではこれを TModemCharSource /
     イベントプロパティ (OnGetTxChar, OnPutRxChar) として明示的に
     注入できるようにし、テスト容易性を高めている。
  ============================================================================ }
unit Modem;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SoundIntf, ModemTypes;

const
  { fldigi: modem.h の GET_TX_CHAR_* 相当 (fl_digi.h) }
  MODEM_TX_CHAR_ETX = -1;  // 送信データ終端
  MODEM_TX_CHAR_NODATA = -2;

type
  TCustomModem = class; // forward

  { fldigi: get_tx_char() の関数ポインタ相当。
    送信すべき次の1文字を取得するコールバック。
    戻り値 >=0 : 文字コード, MODEM_TX_CHAR_ETX: 送信終了 }
  TGetTxCharEvent = function(Sender: TCustomModem): Integer of object;

  { fldigi: put_rx_char() 相当。受信復調された1文字を上位へ渡す }
  TPutRxCharEvent = procedure(Sender: TCustomModem; ACh: Integer) of object;

  { モデムの状態変化・メトリクス更新等を GUI 層へ通知するためのイベント群。
    fldigi では REQ(put_freq,...) / REQ(callback_set_metric,...) など
    qrunner 経由でメインスレッドに配送される処理に相当する。
    TCustomModem はスレッドを意識せず「今計算した値」をそのまま
    これらのイベントで発火する。スレッド境界をまたぐ配送の安全化は
    ModemUI.pas の責務とする。 }
  TFrequencyEvent = procedure(Sender: TCustomModem; AFrequency: Double) of object;
  TMetricEvent = procedure(Sender: TCustomModem; AMetric: Double) of object;
  TStatusTextEvent = procedure(Sender: TCustomModem; const AText: string) of object;

  { TCustomModem
    ---------------------------------------------------------------------
    fldigi: class modem (modem.h)
    全モデム実装の抽象基底クラス。DSP (信号処理) の「型」だけを定義し、
    実際の変復調アルゴリズムは派生クラス (TPskModem, TRttyModem 等) が
    実装する。 }
  TCustomModem = class abstract
  private
    FMode: TModemMode;
    FSound: TCustomSoundDevice;   // fldigi: SoundBase *scard
    FSampleRate: Integer;         // fldigi: int samplerate
    FFrequency: Double;           // fldigi: static double frequency (audio carrier, Hz)
    FTxFrequency: Double;         // fldigi: static double tx_frequency
    FFreqLock: Boolean;           // fldigi: static bool freqlock
    FBandwidth: Double;           // fldigi: double bandwidth
    FReverse: Boolean;            // fldigi: bool reverse
    FMetric: Double;              // fldigi: double metric (信号品質 0..100)
    FSquelch: Double;             // fldigi: double squelch
    FStopFlag: Boolean;           // fldigi: bool stopflag
    FCapabilities: TModemCapabilities; // fldigi: unsigned cap

    // CW 専用 (fldigi: cwTrack, cwLock, cwRcvWPM, cwXmtWPM)
    FCwTrack: Boolean;
    FCwLock: Boolean;
    FCwRcvWPM: Double;
    FCwXmtWPM: Double;

    FOnGetTxChar: TGetTxCharEvent;
    FOnPutRxChar: TPutRxCharEvent;
    FOnFrequencyChanged: TFrequencyEvent;
    FOnMetricChanged: TMetricEvent;
    FOnStatusText: TStatusTextEvent;

    procedure SetFrequency(AValue: Double);
    procedure SetBandwidth(AValue: Double);
  protected
    { fldigi: void set_metric(double) / display_metric(double)
      display_metric は set_metric に加えて GUI へ非同期通知する版。
      本移植版では常に通知イベントも発火する (呼び出し側で頻度を制御する)。 }
    procedure SetMetric(AValue: Double); virtual;

    { 派生クラスから受信文字を上位に渡すためのヘルパ。
      fldigi: put_rx_char(c) 呼び出しに相当。 }
    procedure EmitRxChar(ACh: Integer);

    { 派生クラスが送信すべき次の文字を取得するためのヘルパ。
      fldigi: get_tx_char() 呼び出しに相当。 }
    function FetchTxChar: Integer;

    { ステータス文字列を GUI へ伝える。fldigi: put_Status1/2, put_MODEstatus }
    procedure EmitStatus(const AText: string);

    property Sound: TCustomSoundDevice read FSound;
  public
    constructor Create(ASound: TCustomSoundDevice; AMode: TModemMode); virtual;
    destructor Destroy; override;

    { --------------------------------------------------------------------
      fldigi の純粋仮想関数群 (派生クラスで必ず実装する)
      -------------------------------------------------------------------- }

    { fldigi: virtual void tx_init() = 0;
      送信開始時の初期化 (シンボルカウンタ、プリアンブル準備等) }
    procedure TxInit; virtual; abstract;

    { fldigi: virtual void rx_init() = 0;
      受信開始時の初期化 (フィルタ・PLLのリセット等) }
    procedure RxInit; virtual; abstract;

    { fldigi: virtual void restart() = 0;
      帯域幅やモード変更後の再初期化 }
    procedure Restart; virtual; abstract;

    { fldigi: virtual int rx_process(const double *buf, int len) = 0;
      len サンプル分の受信オーディオを復調処理する。
      戻り値は fldigi の慣習に合わせ 0=継続, <0=エラー/終了。 }
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer; virtual; abstract;

    { fldigi: virtual int tx_process();
      1ブロック分の送信サンプルを生成し Sound に書き込む。
      基底クラスは「送信完了判定 (GET_TX_CHAR_ETX / stopflag)」の
      共通ロジックだけを提供し、実際の波形生成は派生クラスが
      override してから inherited を呼ぶ、または完全に override する。 }
    function TxProcess: Integer; virtual;

    { fldigi: virtual void init();
      コンストラクタ後、モデム切り替え時に呼ばれる共通初期化。 }
    procedure Init; virtual;

    { fldigi: virtual void shutdown() (既定は何もしない) }
    procedure Shutdown; virtual;

    { fldigi: virtual void searchDown() / searchUp()
      AFC: 周波数を検索方向にシフトする (RTTY/CW 等で使用) }
    procedure SearchDown; virtual;
    procedure SearchUp; virtual;

    { fldigi: void set_freq(double) / int get_freq() }
    procedure SetFreq(AFreq: Double); virtual;
    function GetFreq: Integer;

    { fldigi: void set_freqlock(bool) }
    procedure SetFreqLock(AOn: Boolean);

    { fldigi: get_mode() / get_mode_name() }
    function GetModeName: string;

    { --------------------------------------------------------------------
      CW 専用アクセサ (fldigi: get_cwTrack/set_cwTrack 等)
      -------------------------------------------------------------------- }
    procedure SetCwTrack(AValue: Boolean);
    procedure SetCwLock(AValue: Boolean);
    procedure SetCwXmtWPM(AValue: Double);

    property CwTrack: Boolean read FCwTrack write SetCwTrack;
    property CwLock: Boolean read FCwLock write SetCwLock;
    property CwRcvWPM: Double read FCwRcvWPM;
    property CwXmtWPM: Double read FCwXmtWPM write SetCwXmtWPM;

    { --------------------------------------------------------------------
      共通プロパティ (fldigi: modem.h の public/protected メンバ)
      -------------------------------------------------------------------- }
    property Mode: TModemMode read FMode;
    property Frequency: Double read FFrequency write SetFrequency;
    property TxFrequency: Double read FTxFrequency;
    property FreqLock: Boolean read FFreqLock;
    property Bandwidth: Double read FBandwidth write SetBandwidth;
    property Reverse: Boolean read FReverse write FReverse;
    property Metric: Double read FMetric write SetMetric;
    property Squelch: Double read FSquelch write FSquelch;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Capabilities: TModemCapabilities read FCapabilities write FCapabilities;
    property StopFlag: Boolean read FStopFlag write FStopFlag;

    { --------------------------------------------------------------------
      GUI 層と接続するためのイベント (fldigi の REQ(...) 呼び出しに相当)
      -------------------------------------------------------------------- }
    property OnGetTxChar: TGetTxCharEvent read FOnGetTxChar write FOnGetTxChar;
    property OnPutRxChar: TPutRxCharEvent read FOnPutRxChar write FOnPutRxChar;
    property OnFrequencyChanged: TFrequencyEvent read FOnFrequencyChanged write FOnFrequencyChanged;
    property OnMetricChanged: TMetricEvent read FOnMetricChanged write FOnMetricChanged;
    property OnStatusText: TStatusTextEvent read FOnStatusText write FOnStatusText;
  end;

  TModemClass = class of TCustomModem;

implementation

{ TCustomModem }

constructor TCustomModem.Create(ASound: TCustomSoundDevice; AMode: TModemMode);
begin
  inherited Create;
  FSound := ASound;
  FMode := AMode;
  FSampleRate := 8000;
  FFrequency := 1000.0;   // fldigi 既定値 (modem::modem() 初期値)
  FTxFrequency := 1000.0;
  FFreqLock := False;
  FBandwidth := 0.0;
  FReverse := False;
  FMetric := 0.0;
  FSquelch := 0.0;
  FStopFlag := False;
  FCapabilities := [mcRx, mcTx]; // fldigi: cap = CAP_RX | CAP_TX;
  FCwTrack := False;
  FCwLock := False;
  FCwRcvWPM := 0.0;
  FCwXmtWPM := 18.0;
end;

destructor TCustomModem.Destroy;
begin
  inherited Destroy;
end;

procedure TCustomModem.Init;
begin
  // fldigi: modem::init() は stopflag = false; と wf 反転状態の再計算のみ。
  FStopFlag := False;
end;

procedure TCustomModem.Shutdown;
begin
  // 既定では何もしない。派生クラスでリソース解放等を行う。
end;

procedure TCustomModem.SearchDown;
begin
  // 既定では何もしない (AFC対応モデムのみ override)
end;

procedure TCustomModem.SearchUp;
begin
  // 既定では何もしない
end;

procedure TCustomModem.SetFrequency(AValue: Double);
begin
  SetFreq(AValue);
end;

procedure TCustomModem.SetFreq(AFreq: Double);
begin
  // fldigi: modem::set_freq() は progdefaults の上下限にクランプするが、
  // ここでは可搬性のため単純な下限0のみ担保し、上限判定は
  // 呼び出し側 (TModemUI/アプリ設定) に委ねる。
  if AFreq < 0 then
    AFreq := 0;
  FFrequency := AFreq;
  if not FFreqLock then
    FTxFrequency := FFrequency;

  // fldigi: REQ(put_freq, frequency);  -- ここでは直接イベント発火
  if Assigned(FOnFrequencyChanged) then
    FOnFrequencyChanged(Self, FFrequency);
end;

function TCustomModem.GetFreq: Integer;
begin
  Result := Round(FFrequency);
end;

procedure TCustomModem.SetFreqLock(AOn: Boolean);
begin
  FFreqLock := AOn;
  SetFreq(FFrequency);
end;

procedure TCustomModem.SetBandwidth(AValue: Double);
begin
  FBandwidth := AValue;
end;

procedure TCustomModem.SetMetric(AValue: Double);
begin
  FMetric := AValue;
  // fldigi: display_metric() は set_metric() の後 REQ(callback_set_metric,...)
  if Assigned(FOnMetricChanged) then
    FOnMetricChanged(Self, FMetric);
end;

function TCustomModem.GetModeName: string;
begin
  Result := ModemModeToStr(FMode);
end;

procedure TCustomModem.SetCwTrack(AValue: Boolean);
begin
  FCwTrack := AValue;
end;

procedure TCustomModem.SetCwLock(AValue: Boolean);
begin
  FCwLock := AValue;
end;

procedure TCustomModem.SetCwXmtWPM(AValue: Double);
begin
  FCwXmtWPM := AValue;
end;

procedure TCustomModem.EmitRxChar(ACh: Integer);
begin
  if Assigned(FOnPutRxChar) then
    FOnPutRxChar(Self, ACh);
end;

function TCustomModem.FetchTxChar: Integer;
begin
  if Assigned(FOnGetTxChar) then
    Result := FOnGetTxChar(Self)
  else
    Result := MODEM_TX_CHAR_ETX;
end;

procedure TCustomModem.EmitStatus(const AText: string);
begin
  if Assigned(FOnStatusText) then
    FOnStatusText(Self, AText);
end;

function TCustomModem.TxProcess: Integer;
var
  Ch: Integer;
begin
  // fldigi: nullmodem.cxx の tx_process() 共通パターンを基底クラスに集約:
  //   int c = get_tx_char();
  //   if (c == GET_TX_CHAR_ETX) { stopflag = false; return -1; }
  //   if (stopflag) { stopflag = false; return -1; }
  //   return 0;
  Ch := FetchTxChar;
  if Ch = MODEM_TX_CHAR_ETX then
  begin
    FStopFlag := False;
    Exit(-1);
  end;
  if FStopFlag then
  begin
    FStopFlag := False;
    Exit(-1);
  end;
  Result := 0;
end;

end.
