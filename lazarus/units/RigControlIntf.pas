{ ============================================================================
  RigControlIntf.pas

  無線機 CAT (Computer Aided Transceiver) 制御の抽象基底クラス。

  fldigi との対応:
    fldigi (C++)                         | Lazarus (Pascal)
    --------------------------------------+--------------------------------
    class Rig (rigclass.h/.cxx)          | TCustomRigControl (本ユニット)
    class RigException (rigclass.h)      | ERigControlError (本ユニット)
    Rig::open()/close()                  | Open/Close
    Rig::setFreq()/getFreq()             | SetFreq/GetFreq
    Rig::setMode()/getMode()             | SetMode/GetMode
    Rig::setPTT()/getPTT()               | SetPTT/GetPTT
    Rig::canSetFreq() 等 (caps問い合わせ) | CanSetFreq 等
    Rig::setConf()/getConf()             | SetConfStr/GetConfStr (拡張フック)
    hamlib.cxx の hamlib_loop() (50ms    | TRigPollThread (RigPollThread.pas)
      周期ポーリングスレッド)             |

  設計方針:
  ----------------------------------------------------------------------------
  1. Strategy パターンの踏襲 (TCustomSoundDevice / TCustomModem と同じ):
     本ユニットは特定のCAT制御実装 (Hamlib / rigctld / メーカー独自CAT等)
     に依存しない抽象インターフェースのみを定義する。実際の通信は
     HamlibRigControl.pas の THamlibRigControl (Hamlib直接バインディング)
     が担当するが、将来的に「rigctld へのTCP接続」「特定リグの独自CAT
     プロトコルを自前実装」等の別実装を追加する場合も、この基底クラスを
     継承するだけで ModemEngine/UI 側のコードは一切変更不要にする。

  2. 基本CAT機能 (周波数/モード/PTT) は具象メソッドとして必須実装するが、
     それ以外の任意コマンド (Sメータ取得、パワーレベル設定、アンテナ切替、
     メモリチャンネル操作、VFO切替など Hamlib rig_set_level/rig_set_parm/
     rig_set_ext_level 等でカバーされる全機能) は、以下の3段構えで
     「将来的な拡張」を可能にしている:

       a) 高頻度に使う操作は本クラスに素直なメソッドとして追加する
          (例: 将来 SetVFO/GetVFO, GetSMeter 等を追加する場合、
          TCustomRigControl に仮想メソッドを1本足すだけでよい)。

       b) Hamlib の "conf" (文字列ベースの設定項目。rig_pathname や
          serial_speed 等、fldigi の setConf/getConf 相当) は
          SetConfStr/GetConfStr で汎用的にアクセスできる。

       c) さらに低レベルな Hamlib API (rig_set_level/rig_set_parm/
          rig_set_ext_level/rig_send_morse 等、本ユニットが未対応の
          機能) を使いたい場合のための「エスケープハッチ」として
          GetNativeHandle を用意する。THamlibRigControl の場合は
          THamlibRigHandle (Hamlib の RIG*) を返すので、呼び出し側は
          HamlibBindings.pas の関数を直接呼んで独自に拡張できる。
          これにより「基本CAT機能以外にも将来的に対応できる」設計を
          Strategy パターンを壊さずに実現している。

  3. スレッド非依存: 本クラス自体はスレッドを持たない (fldigi の Rig
     クラスと同様、「呼ばれたら1回の CAT コマンドを実行して返る」設計)。
     定期ポーリング (周波数/モードの変化監視) は別ユニット
     RigPollThread.pas の TRigPollThread (TThread 派生) が担当する
     (fldigi の hamlib_loop() に相当)。これにより GUI 非依存のまま
     単体テストが可能になる (PortAudio/ModemEngine と同じ設計思想)。
  ============================================================================ }
unit RigControlIntf;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { RIG-11: TransmitGuarded に渡す送信処理。
    System.TProcedure (グローバル手続き) ではフォームやコントローラの
    メソッドを渡せないため、"of object" 版を定義する。 }
  TRigTransmitProc = procedure of object;

  { fldigi: class RigException (rigclass.h) }
  ERigControlError = class(Exception)
  private
    FErrorCode: Integer;
  public
    constructor Create(AErrorCode: Integer; const AMsg: string);
    constructor Create(const APrefix: string; AErrorCode: Integer; const AMsg: string);
    property ErrorCode: Integer read FErrorCode;
  end;

  { CAT制御対象のVFO選択。fldigi/Hamlib の vfo_t のうち代表的なもののみを
    抽象化。具象実装 (THamlibRigControl) 側で Hamlib の RIG_VFO_* に
    マッピングする。 }
  TRigVfoSel = (rvCurrent, rvA, rvB);

  { fldigi: ptt_t (RIG_PTT_OFF/ON/ON_MIC/ON_DATA) を簡略化。
    データモード送信時に MIC/DATA を区別したい場合は将来
    TRigPttMode = (rpOff, rpOn, rpOnMic, rpOnData) のように拡張する
    (progdefaults.hamlib_ptt_on_data 相当)。 }
  TRigPttMode = (rpOff, rpOn, rpOnMic, rpOnData);

  { モードは fldigi 同様「文字列」で表現する (Hamlib 側の rmode_t は
    64bitフラグ値だが、UI 表示/設定ファイル保存には文字列の方が
    プラットフォーム非依存で扱いやすいため。 fldigi の modeString()/
    rig_strrmode() に相当する変換は具象クラス側で行う)。 }

  { TCustomRigControl
    ---------------------------------------------------------------------
    fldigi: class Rig (rigclass.h/.cxx) }
  TCustomRigControl = class abstract
  private
    FDevice: string;
    FBaudRate: Integer;
    FIsOpen: Boolean;
    FPollIntervalMs: Integer;
    FPttOnDataMode: Boolean;
    FPttAsserted: Boolean;   // RIG-11: 自分が送信を ON にしたか
  protected
    property IsOpenFlag: Boolean read FIsOpen write FIsOpen;

    { RIG-11: 派生クラスは SetPTT の実装内で、実際に PTT を操作した後に
      これを呼んで状態を記録すること。EnsurePttOff はこの記録を見て
      「自分が上げた送信」だけを確実に下ろす。 }
    procedure NotePttState(AOn: Boolean);
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { --- ライフサイクル (fldigi: Rig::open()/close()) --- }
    function Open: Boolean; virtual; abstract;
    procedure Close; virtual; abstract;
    function IsOnLine: Boolean; virtual;

    { --- 周波数 (fldigi: Rig::setFreq()/getFreq()) ---
      Freq の単位は Hz (Hamlib の freq_t と同じ)。 }
    procedure SetFreq(Freq: Double; Vfo: TRigVfoSel = rvCurrent); virtual; abstract;
    function GetFreq(Vfo: TRigVfoSel = rvCurrent): Double; virtual; abstract;
    function CanSetFreq: Boolean; virtual; abstract;
    function CanGetFreq: Boolean; virtual; abstract;

    { --- モード / フィルタ幅 (fldigi: Rig::setMode()/getMode())
      Mode は "USB"/"LSB"/"CW"/"RTTY" 等の文字列 (Hamlib rig_strrmode()
      が返す表記に準拠)。Width は Hz 単位 (0 = リグ既定値/RIG_PASSBAND_NORMAL)。 }
    procedure SetMode(const Mode: string; Width: Integer = 0;
      Vfo: TRigVfoSel = rvCurrent); virtual; abstract;
    function GetMode(out Width: Integer; Vfo: TRigVfoSel = rvCurrent): string;
      virtual; abstract;
    function CanSetMode: Boolean; virtual; abstract;
    function CanGetMode: Boolean; virtual; abstract;

    { RIG-11: 送信の後始末を保証するフェイルセーフ。
      例外・アプリ終了・デバイス障害のいずれの経路でも、送信状態のまま
      無線機を放置しないために使う。失敗しても例外を投げない
      (デストラクタや except 節から安全に呼べる)。
      戻り値: PTT を下ろせたか (元から送信していなければ True)。 }
    function EnsurePttOff: Boolean;

    { RIG-11: 送信を伴う処理を安全に囲むためのヘルパー。
      ATransmitProc の実行中に例外が出ても、必ず PTT を下ろしてから
      例外を再送出する。呼び出し側の finally 書き忘れを防ぐ。
      引数は "procedure of object" である点に注意 (System.TProcedure だと
      グローバル手続きしか渡せず、フォームやコントローラのメソッドを
      渡せないため実質使えなかった)。 }
    procedure TransmitGuarded(ATransmitProc: TRigTransmitProc);

    { 自分が送信を ON にしている状態か (フェイルセーフの判定用)。 }
    property PttAsserted: Boolean read FPttAsserted;

    { --- PTT (fldigi: Rig::setPTT()/getPTT()) --- }
    procedure SetPTT(OnOff: Boolean; Vfo: TRigVfoSel = rvCurrent); virtual; abstract;
    function GetPTT(Vfo: TRigVfoSel = rvCurrent): Boolean; virtual; abstract;
    function CanSetPTT: Boolean; virtual; abstract;
    function CanGetPTT: Boolean; virtual; abstract;

    { --- VFO切替 (基本CAT機能の一部として用意。将来 A/B間のQSY等に使う) --- }
    procedure SetVFO(Vfo: TRigVfoSel); virtual; abstract;
    function GetVFO: TRigVfoSel; virtual; abstract;

    { --- 拡張フック (a) 汎用 conf 文字列アクセス
      fldigi: Rig::setConf(name,val)/getConf(name,val)
      Hamlib の rig_token_lookup + rig_set_conf/rig_get_conf に相当。
      "rig_pathname"(デバイスパス)/"serial_speed"/"timeout"/"retry"/
      "write_delay"/"post_write_delay"/"dtr_state"/"rts_state"/
      "serial_handshake"/"stop_bits" 等、Hamlib が公開するあらゆる
      文字列設定項目にモデルへ依存せず汎用アクセスできる。
      未対応の実装 (rigctld版等) は EOpNotSupported 相当を投げてよい。 }
    procedure SetConfStr(const Name, Value: string); virtual;
    function GetConfStr(const Name: string): string; virtual;

    { --- 拡張フック (c) ネイティブハンドルへのエスケープハッチ
      本クラスにまだ無い機能 (Sメータ取得・パワーレベル・アンテナ切替・
      メモリチャンネル操作等) を使いたい場合、具象実装が返す
      ネイティブハンドル (THamlibRigControl なら THamlibRigHandle
      = Hamlib の RIG*) を使い、HamlibBindings.pas の関数を直接
      呼び出すことで対応できる。これにより「対応スコープ外の機能」も
      TCustomRigControl の抽象契約を壊さずに将来拡張可能にしている。 }
    function GetNativeHandle: Pointer; virtual;

    { --- 設定 (Open 前に設定する接続パラメータ) --- }
    property Device: string read FDevice write FDevice;
    property BaudRate: Integer read FBaudRate write FBaudRate;
    property IsOpen: Boolean read FIsOpen;

    { fldigi: valHamRigPollrate (デフォルト値は具象クラス/呼び出し側で設定) }
    property PollIntervalMs: Integer read FPollIntervalMs write FPollIntervalMs;

    { fldigi: progdefaults.hamlib_ptt_on_data
      true の場合 SetPTT(true) は RIG_PTT_ON_DATA として送信する
      (具象実装が対応していれば)。 }
    property PttOnDataMode: Boolean read FPttOnDataMode write FPttOnDataMode;
  end;

  { TNullRigControl
    ---------------------------------------------------------------------
    何もしない (無線機を制御しない) デフォルト実装。
    fldigi の noCAT_* 系関数群 (rigio.h の「no xcvr」セクション) に相当。
    ModemEngine/UI 側が「リグ制御なし」で動かす際のヌルオブジェクトとして
    使う。 }
  TNullRigControl = class(TCustomRigControl)
  private
    FFreq: Double;
    FMode: string;
    FWidth: Integer;
    FPtt: Boolean;
    FVfo: TRigVfoSel;
  public
    constructor Create; override;
    function Open: Boolean; override;
    procedure Close; override;
    procedure SetFreq(Freq: Double; Vfo: TRigVfoSel = rvCurrent); override;
    function GetFreq(Vfo: TRigVfoSel = rvCurrent): Double; override;
    function CanSetFreq: Boolean; override;
    function CanGetFreq: Boolean; override;
    procedure SetMode(const Mode: string; Width: Integer = 0;
      Vfo: TRigVfoSel = rvCurrent); override;
    function GetMode(out Width: Integer; Vfo: TRigVfoSel = rvCurrent): string; override;
    function CanSetMode: Boolean; override;
    function CanGetMode: Boolean; override;
    procedure SetPTT(OnOff: Boolean; Vfo: TRigVfoSel = rvCurrent); override;
    function GetPTT(Vfo: TRigVfoSel = rvCurrent): Boolean; override;
    function CanSetPTT: Boolean; override;
    function CanGetPTT: Boolean; override;
    procedure SetVFO(Vfo: TRigVfoSel); override;
    function GetVFO: TRigVfoSel; override;
  end;

implementation

{ ERigControlError }

constructor ERigControlError.Create(AErrorCode: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  FErrorCode := AErrorCode;
end;

constructor ERigControlError.Create(const APrefix: string; AErrorCode: Integer;
  const AMsg: string);
begin
  inherited Create(APrefix + ': ' + AMsg);
  FErrorCode := AErrorCode;
end;

{ TCustomRigControl }

constructor TCustomRigControl.Create;
begin
  inherited Create;
  FDevice := '';
  FBaudRate := 0; // 0 = Hamlib のリグ既定値を使う
  FIsOpen := False;
  FPollIntervalMs := 250; // fldigi 既定の PollRate に近い値
  FPttOnDataMode := False;
end;

destructor TCustomRigControl.Destroy;
{ RIG-11: 破棄経路でも必ず送信を止める。Close より先に PTT を下ろすのは、
  Close で通信路が閉じてしまうと PTT を操作できなくなるため。

  ※ここでの EnsurePttOff は "最後の保険" にすぎない。基底デストラクタが
    走る時点で派生クラスのデストラクタ本体は既に終わっており、派生が
    自分で Close 済みなら (FIsOpen=False) 何もできない。したがって
    実際に PTT を下ろす責任は派生デストラクタの先頭にある
    (THamlibRigControl.Destroy を参照)。 }
begin
  EnsurePttOff;
  if FIsOpen then
  begin
    try
      Close;
    except
      on E: Exception do ; // 破棄中の例外は伝播させない
    end;
  end;
  inherited Destroy;
end;

procedure TCustomRigControl.NotePttState(AOn: Boolean);
begin
  FPttAsserted := AOn;
end;

function TCustomRigControl.EnsurePttOff: Boolean;
begin
  Result := True;
  if not FPttAsserted then Exit;   // 自分は送信していない

  if not (FIsOpen and CanSetPTT) then
  begin
    { 通信路が閉じている等で PTT を操作できない。ここで True を返すと
      「下ろせた」と誤って報告することになる (電波が出続けているのに
      呼び出し側は正常終了と判断してしまう)。記録も消さずに残し、
      再オープン後の再試行で下ろせるようにする。 }
    Result := False;
    Exit;
  end;

  try
    SetPTT(False);
    FPttAsserted := False;
  except
    on E: Exception do
    begin
      { ここで例外を投げると、呼び出し元 (デストラクタや except 節) の
        後始末が止まってしまう。送信が残っている可能性は戻り値で伝える。 }
      Result := False;
    end;
  end;
end;

procedure TCustomRigControl.TransmitGuarded(ATransmitProc: TRigTransmitProc);
begin
  if not Assigned(ATransmitProc) then
    raise ERigControlError.Create(-1,
      'TransmitGuarded: 送信処理が指定されていません');
  try
    ATransmitProc();
  finally
    EnsurePttOff;
  end;
end;

function TCustomRigControl.IsOnLine: Boolean;
begin
  Result := FIsOpen;
end;

const
  { hamlib.h の RIG_ENAVAIL (Function not available) と同じ値 (=11)。
    本ユニットは HamlibBindings に依存しないため、値をここに複製する。 }
  ERR_NOT_AVAILABLE = 11;

procedure TCustomRigControl.SetConfStr(const Name, Value: string);
begin
  raise ERigControlError.Create(ERR_NOT_AVAILABLE,
    'SetConfStr は具象クラスで未実装です (' + Name + ')');
end;

function TCustomRigControl.GetConfStr(const Name: string): string;
begin
  raise ERigControlError.Create(ERR_NOT_AVAILABLE,
    'GetConfStr は具象クラスで未実装です (' + Name + ')');
end;

function TCustomRigControl.GetNativeHandle: Pointer;
begin
  Result := nil;
end;

{ TNullRigControl }

constructor TNullRigControl.Create;
begin
  inherited Create;
  FFreq := 14070000.0;
  FMode := 'USB';
  FWidth := 0;
  FPtt := False;
  FVfo := rvCurrent;
end;

function TNullRigControl.Open: Boolean;
begin
  IsOpenFlag := True;
  Result := True;
end;

procedure TNullRigControl.Close;
begin
  IsOpenFlag := False;
end;

procedure TNullRigControl.SetFreq(Freq: Double; Vfo: TRigVfoSel);
begin
  FFreq := Freq;
end;

function TNullRigControl.GetFreq(Vfo: TRigVfoSel): Double;
begin
  Result := FFreq;
end;

function TNullRigControl.CanSetFreq: Boolean;
begin
  Result := True;
end;

function TNullRigControl.CanGetFreq: Boolean;
begin
  Result := True;
end;

procedure TNullRigControl.SetMode(const Mode: string; Width: Integer;
  Vfo: TRigVfoSel);
begin
  FMode := Mode;
  FWidth := Width;
end;

function TNullRigControl.GetMode(out Width: Integer; Vfo: TRigVfoSel): string;
begin
  Width := FWidth;
  Result := FMode;
end;

function TNullRigControl.CanSetMode: Boolean;
begin
  Result := True;
end;

function TNullRigControl.CanGetMode: Boolean;
begin
  Result := True;
end;

procedure TNullRigControl.SetPTT(OnOff: Boolean; Vfo: TRigVfoSel);
begin
  FPtt := OnOff;
  NotePttState(OnOff);   // RIG-11: フェイルセーフが状態を追えるようにする
end;

function TNullRigControl.GetPTT(Vfo: TRigVfoSel): Boolean;
begin
  Result := FPtt;
end;

function TNullRigControl.CanSetPTT: Boolean;
begin
  Result := True;
end;

function TNullRigControl.CanGetPTT: Boolean;
begin
  Result := True;
end;

procedure TNullRigControl.SetVFO(Vfo: TRigVfoSel);
begin
  FVfo := Vfo;
end;

function TNullRigControl.GetVFO: TRigVfoSel;
begin
  Result := FVfo;
end;

end.
