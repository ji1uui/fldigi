{ ============================================================================
  HamlibRigControl.pas

  TCustomRigControl (RigControlIntf.pas) を継承した Hamlib 具象実装。

  fldigi との対応:
    fldigi (C++)                              | Lazarus (Pascal)
    -------------------------------------------+---------------------------
    class Rig (rigclass.h/.cxx)               | THamlibRigControl
    xcvr->init()/open()/close()               | Open/Close
    xcvr->setFreq()/getFreq()                 | SetFreq/GetFreq
    xcvr->setMode()/getMode()                 | SetMode/GetMode
    xcvr->setPTT()/getPTT()                   | SetPTT/GetPTT
    xcvr->setConf()/getConf()                 | SetConfStr/GetConfStr
    hamlib.cxx: hamlib_get_rigs()              | THamlibRigControl.EnumerateRigs
    hamlib.cxx: hamlib_get_rig_model_compat()  | (EnumerateRigs の戻り値から検索)
    NUMTRIES (rigclass.cxx、リトライ回数)      | RetryCount プロパティ

  設計判断のポイント:
  ----------------------------------------------------------------------------
  - RIG* は不透明ポインタ (THamlibRigHandle = Pointer) として扱う
    (HamlibBindings.pas 冒頭のコメント参照)。
  - fldigi の rigclass.cxx と同じ「NUMTRIES 回リトライしてダメなら例外」
    パターンを踏襲。
  - モード文字列は Hamlib の rmode_t (64bitフラグ) と "USB"/"LSB"/"CW"
    等の文字列を相互変換する (ModeStrToRigMode/RigModeToStr)。fldigi の
    modeString()/hamlib_getmode() に相当。
  - GetNativeHandle が THamlibRigHandle (Hamlib の RIG*) を返すため、
    本クラスに無い機能 (Sメータ取得等) が必要になった場合は、
    呼び出し側が HamlibBindings.pas の rig_get_level 等を直接呼んで
    拡張できる (RigControlIntf.pas のコメント参照)。
  - EnumerateRigs (class method) で Hamlib が対応する全リグモデルを
    列挙できる (fldigi: hamlib_get_rigs()+hamlib_get_rig_str())。
  ============================================================================ }
unit HamlibRigControl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ctypes, HamlibBindings, RigControlIntf;

type
  { Hamlib が公開する1つのリグモデルの情報 (fldigi: rig_caps の一部) }
  THamlibRigEntry = record
    RigModel: TRigModel;
    ModelName: string;
    MfgName: string;
  end;
  THamlibRigEntryArray = array of THamlibRigEntry;

  { THamlibRigControl
    ---------------------------------------------------------------------
    fldigi: class Rig (rigclass.h/.cxx) }
  THamlibRigControl = class(TCustomRigControl)
  private
    FHandle: THamlibRigHandle;
    FRigModel: TRigModel;
    FRetryCount: Integer;
    FTimeoutMs: Integer;
    FWriteDelayMs: Integer;
    FPostWriteDelayMs: Integer;
    function VfoSelToNative(Vfo: TRigVfoSel): TRigVfo;
    procedure CheckErr(ErrCode: Integer; const FuncName: string);
    function DoSetFreqOnce(Freq: TRigFreq; Vfo: TRigVfo): Integer;
    function DoGetFreqOnce(Vfo: TRigVfo; out Freq: TRigFreq): Integer;
  public
    constructor Create; override;
    constructor Create(ARigModel: TRigModel);
    destructor Destroy; override;

    { --- 未接続の RIG インスタンスの初期化 (fldigi: Rig::init())
      通常は Create(ARigModel) を使うが、モデルを後から切り替える場合に
      使用する。既に Open 済みの場合は自動的に Close される。 }
    procedure InitModel(ARigModel: TRigModel);

    function Open: Boolean; override;
    procedure Close; override;

    procedure SetFreq(Freq: Double; Vfo: TRigVfoSel = rvCurrent); override;
    function GetFreq(Vfo: TRigVfoSel = rvCurrent): Double; override;
    function CanSetFreq: Boolean; override;
    function CanGetFreq: Boolean; override;

    procedure SetMode(const Mode: string; Width: Integer = 0;
      Vfo: TRigVfoSel = rvCurrent); override;
    function GetMode(out Width: Integer; Vfo: TRigVfoSel = rvCurrent): string;
      override;
    function CanSetMode: Boolean; override;
    function CanGetMode: Boolean; override;

    procedure SetPTT(OnOff: Boolean; Vfo: TRigVfoSel = rvCurrent); override;
    function GetPTT(Vfo: TRigVfoSel = rvCurrent): Boolean; override;
    function CanSetPTT: Boolean; override;
    function CanGetPTT: Boolean; override;

    procedure SetVFO(Vfo: TRigVfoSel); override;
    function GetVFO: TRigVfoSel; override;

    procedure SetConfStr(const Name, Value: string); override;
    function GetConfStr(const Name: string): string; override;

    function GetNativeHandle: Pointer; override;

    { fldigi: xcvr->getName() / xcvr->getCaps() }
    function RigName: string;

    { fldigi: rigclass.cxx の NUMTRIES (=10)。
      Rig::setFreq 等の各操作で「成功するまで(または尽きるまで)」
      リトライする回数。 }
    property RetryCount: Integer read FRetryCount write FRetryCount;
    { fldigi: progdefaults.HamlibTimeout / HamlibWriteDelay / HamlibWait
      Open() 前に設定すると Hamlib の "timeout"/"write_delay"/
      "post_write_delay" conf に反映される。 }
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property WriteDelayMs: Integer read FWriteDelayMs write FWriteDelayMs;
    property PostWriteDelayMs: Integer read FPostWriteDelayMs write FPostWriteDelayMs;
    property RigModel: TRigModel read FRigModel;

    { --- リグモデル列挙 (fldigi: hamlib_get_rigs() + hamlib_get_rig_str())
      class method なので RIG インスタンスを作らずに呼べる。 }
    class function EnumerateRigs: THamlibRigEntryArray;
    { fldigi: hamlib_get_rig_model_compat() (設定ファイルの文字列表記から
      モデルIDを逆引きする) }
    class function FindRigModelByName(const AText: string): TRigModel;
  end;

{ モード文字列 <-> Hamlib rmode_t 変換 (fldigi: modeString() 相当) }
function ModeStrToRigMode(const Mode: string): TRigMode;
function RigModeToStr(Mode: TRigMode): string;

implementation

const
  { fldigi: rigclass.cxx #define NUMTRIES 10 }
  DefaultRetryCount = 10;

{ ---------------------------------------------------------------------------
  モード文字列 <-> rmode_t
  --------------------------------------------------------------------------- }

function ModeStrToRigMode(const Mode: string): TRigMode;
var
  m: string;
begin
  m := UpperCase(Trim(Mode));
  if m = 'AM' then Result := RIG_MODE_AM
  else if m = 'CW' then Result := RIG_MODE_CW
  else if m = 'CWR' then Result := RIG_MODE_CWR
  else if m = 'USB' then Result := RIG_MODE_USB
  else if m = 'LSB' then Result := RIG_MODE_LSB
  else if m = 'RTTY' then Result := RIG_MODE_RTTY
  else if m = 'RTTYR' then Result := RIG_MODE_RTTYR
  else if m = 'FM' then Result := RIG_MODE_FM
  else if m = 'WFM' then Result := RIG_MODE_WFM
  else if (m = 'PKTUSB') or (m = 'DATA-U') or (m = 'USB-D') then Result := RIG_MODE_PKTUSB
  else if (m = 'PKTLSB') or (m = 'DATA-L') or (m = 'LSB-D') then Result := RIG_MODE_PKTLSB
  else if m = 'PKTFM' then Result := RIG_MODE_PKTFM
  else if m = 'PKTAM' then Result := RIG_MODE_PKTAM
  else if m = 'FAX' then Result := RIG_MODE_FAX
  else
    Result := RIG_MODE_NONE;
end;

function RigModeToStr(Mode: TRigMode): string;
begin
  if Mode = RIG_MODE_AM then Result := 'AM'
  else if Mode = RIG_MODE_CW then Result := 'CW'
  else if Mode = RIG_MODE_CWR then Result := 'CWR'
  else if Mode = RIG_MODE_USB then Result := 'USB'
  else if Mode = RIG_MODE_LSB then Result := 'LSB'
  else if Mode = RIG_MODE_RTTY then Result := 'RTTY'
  else if Mode = RIG_MODE_RTTYR then Result := 'RTTYR'
  else if Mode = RIG_MODE_FM then Result := 'FM'
  else if Mode = RIG_MODE_WFM then Result := 'WFM'
  else if Mode = RIG_MODE_PKTUSB then Result := 'PKTUSB'
  else if Mode = RIG_MODE_PKTLSB then Result := 'PKTLSB'
  else if Mode = RIG_MODE_PKTFM then Result := 'PKTFM'
  else if Mode = RIG_MODE_PKTAM then Result := 'PKTAM'
  else if Mode = RIG_MODE_FAX then Result := 'FAX'
  else
    Result := '';
end;

{ ---------------------------------------------------------------------------
  THamlibRigControl
  --------------------------------------------------------------------------- }

constructor THamlibRigControl.Create;
begin
  inherited Create;
  FHandle := nil;
  FRigModel := RIG_MODEL_NONE;
  FRetryCount := DefaultRetryCount;
  FTimeoutMs := 200;
  FWriteDelayMs := 0;
  FPostWriteDelayMs := 0;
end;

constructor THamlibRigControl.Create(ARigModel: TRigModel);
begin
  Create;
  InitModel(ARigModel);
end;

destructor THamlibRigControl.Destroy;
begin
  if IsOpen then
    Close;
  if FHandle <> nil then
  begin
    rig_cleanup(FHandle);
    FHandle := nil;
  end;
  inherited Destroy;
end;

procedure THamlibRigControl.InitModel(ARigModel: TRigModel);
begin
  if IsOpen then
    Close;
  if FHandle <> nil then
  begin
    rig_cleanup(FHandle);
    FHandle := nil;
  end;
  FHandle := rig_init(ARigModel);
  if FHandle = nil then
    raise ERigControlError.Create(RIG_EINVAL,
      Format('rig_init に失敗しました (model=%d)', [ARigModel]));
  FRigModel := ARigModel;
end;

procedure THamlibRigControl.CheckErr(ErrCode: Integer; const FuncName: string);
begin
  if ErrCode <> RIG_OK then
    raise ERigControlError.Create(FuncName, ErrCode, rigerror(ErrCode));
end;

function THamlibRigControl.VfoSelToNative(Vfo: TRigVfoSel): TRigVfo;
begin
  case Vfo of
    rvA: Result := RIG_VFO_A;
    rvB: Result := RIG_VFO_B;
  else
    Result := RIG_VFO_CURR;
  end;
end;

function THamlibRigControl.Open: Boolean;
var
  szParam: string;
begin
  Result := False;
  if FHandle = nil then
    raise ERigControlError.Create(RIG_EINVAL,
      'RIG が初期化されていません (InitModel/Create(model) を先に呼んでください)');
  if IsOpen then
    Close;

  { fldigi: xcvr->setConf("rig_pathname", ...) }
  if Device <> '' then
    rig_set_conf(FHandle, rig_token_lookup(FHandle, 'rig_pathname'), PAnsiChar(Device));

  if TimeoutMs > 0 then
  begin
    szParam := IntToStr(TimeoutMs);
    rig_set_conf(FHandle, rig_token_lookup(FHandle, 'timeout'), PAnsiChar(szParam));
  end;
  if WriteDelayMs > 0 then
  begin
    szParam := IntToStr(WriteDelayMs);
    rig_set_conf(FHandle, rig_token_lookup(FHandle, 'write_delay'), PAnsiChar(szParam));
  end;
  if PostWriteDelayMs > 0 then
  begin
    szParam := IntToStr(PostWriteDelayMs);
    rig_set_conf(FHandle, rig_token_lookup(FHandle, 'post_write_delay'), PAnsiChar(szParam));
  end;
  if BaudRate > 0 then
  begin
    szParam := IntToStr(BaudRate);
    rig_set_conf(FHandle, rig_token_lookup(FHandle, 'serial_speed'), PAnsiChar(szParam));
  end;

  CheckErr(rig_open(FHandle), 'rig_open');
  IsOpenFlag := True;
  Result := True;
end;

procedure THamlibRigControl.Close;
begin
  if not IsOpen then Exit;
  rig_close(FHandle);
  IsOpenFlag := False;
end;

function THamlibRigControl.DoSetFreqOnce(Freq: TRigFreq; Vfo: TRigVfo): Integer;
begin
  Result := rig_set_freq(FHandle, Vfo, Freq);
end;

function THamlibRigControl.DoGetFreqOnce(Vfo: TRigVfo; out Freq: TRigFreq): Integer;
begin
  Result := rig_get_freq(FHandle, Vfo, Freq);
end;

procedure THamlibRigControl.SetFreq(Freq: Double; Vfo: TRigVfoSel);
var
  i, err: Integer;
  nvfo: TRigVfo;
begin
  if not CanSetFreq then Exit; // fldigi: Rig::setFreq() と同じ挙動 (無視)
  nvfo := VfoSelToNative(Vfo);
  err := RIG_OK;
  for i := 1 to RetryCount do
  begin
    err := DoSetFreqOnce(Freq, nvfo);
    if err = RIG_OK then Exit;
  end;
  CheckErr(err, 'rig_set_freq');
end;

function THamlibRigControl.GetFreq(Vfo: TRigVfoSel): Double;
var
  i, err: Integer;
  f: TRigFreq;
  nvfo: TRigVfo;
begin
  Result := 0;
  if not CanGetFreq then Exit;
  nvfo := VfoSelToNative(Vfo);
  f := 0;
  for i := 1 to RetryCount do
  begin
    err := DoGetFreqOnce(nvfo, f);
    if (err = RIG_OK) and (f <> 0) then
    begin
      Result := f;
      Exit;
    end;
  end;
  Result := f;
end;

function THamlibRigControl.CanSetFreq: Boolean;
begin
  { Hamlib は「set_freq を実装しないバックエンド」がまれにあるが、
    rig_caps の関数ポインタを直接読むのは避け (不透明ポインタ方針)、
    実際に呼んでみて RIG_ENAVAIL が返るかどうかで判定する方法もあるが、
    Open 前には呼べないため、ここでは「Open されていれば常に試す」と
    し、実際の失敗は SetFreq 内のリトライ+例外に委ねる設計とする。
    (fldigi の canSetFreq() は rig->caps->set_freq を直接見ているが、
    本移植版は不透明ポインタ方針のため、より安全側に倒している。) }
  Result := IsOpen;
end;

function THamlibRigControl.CanGetFreq: Boolean;
begin
  Result := IsOpen;
end;

procedure THamlibRigControl.SetMode(const Mode: string; Width: Integer;
  Vfo: TRigVfoSel);
var
  i, err: Integer;
  nvfo: TRigVfo;
  rmode: TRigMode;
begin
  if not CanSetMode then
    raise ERigControlError.Create(RIG_ENAVAIL, 'SetMode は利用できません');
  nvfo := VfoSelToNative(Vfo);
  rmode := ModeStrToRigMode(Mode);
  err := RIG_OK;
  for i := 1 to RetryCount do
  begin
    err := rig_set_mode(FHandle, nvfo, rmode, TRigWidth(Width));
    if err = RIG_OK then Exit;
  end;
  CheckErr(err, 'rig_set_mode');
end;

function THamlibRigControl.GetMode(out Width: Integer; Vfo: TRigVfoSel): string;
var
  i, err: Integer;
  nvfo: TRigVfo;
  rmode: TRigMode;
  w: TRigWidth;
begin
  Width := 0;
  Result := '';
  if not CanGetMode then
    raise ERigControlError.Create(RIG_ENAVAIL, 'GetMode は利用できません');
  nvfo := VfoSelToNative(Vfo);
  rmode := RIG_MODE_NONE;
  w := 0;
  err := RIG_OK;
  for i := 1 to RetryCount do
  begin
    err := rig_get_mode(FHandle, nvfo, rmode, w);
    if err = RIG_OK then
    begin
      Result := RigModeToStr(rmode);
      Width := w;
      Exit;
    end;
  end;
  CheckErr(err, 'rig_get_mode');
end;

function THamlibRigControl.CanSetMode: Boolean;
begin
  Result := IsOpen;
end;

function THamlibRigControl.CanGetMode: Boolean;
begin
  Result := IsOpen;
end;

procedure THamlibRigControl.SetPTT(OnOff: Boolean; Vfo: TRigVfoSel);
var
  i, err: Integer;
  nvfo: TRigVfo;
  pttVal: TRigPtt;
begin
  if not CanSetPTT then Exit; // fldigi: hamlib_set_ptt() と同じく無視
  nvfo := VfoSelToNative(Vfo);
  if OnOff then
  begin
    if PttOnDataMode then
      pttVal := RIG_PTT_ON_DATA
    else
      pttVal := RIG_PTT_ON_MIC;
  end
  else
    pttVal := RIG_PTT_OFF;
  err := RIG_OK;
  for i := 1 to RetryCount do
  begin
    err := rig_set_ptt(FHandle, nvfo, pttVal);
    if err = RIG_OK then Exit;
  end;
  CheckErr(err, 'rig_set_ptt');
end;

function THamlibRigControl.GetPTT(Vfo: TRigVfoSel): Boolean;
var
  i, err: Integer;
  nvfo: TRigVfo;
  pttVal: TRigPtt;
begin
  Result := False;
  if not CanGetPTT then Exit;
  nvfo := VfoSelToNative(Vfo);
  pttVal := RIG_PTT_OFF;
  err := RIG_OK;
  for i := 1 to RetryCount do
  begin
    err := rig_get_ptt(FHandle, nvfo, pttVal);
    if err = RIG_OK then
    begin
      Result := (pttVal <> RIG_PTT_OFF);
      Exit;
    end;
  end;
  CheckErr(err, 'rig_get_ptt');
end;

function THamlibRigControl.CanSetPTT: Boolean;
begin
  Result := IsOpen;
end;

function THamlibRigControl.CanGetPTT: Boolean;
begin
  Result := IsOpen;
end;

procedure THamlibRigControl.SetVFO(Vfo: TRigVfoSel);
begin
  if not IsOpen then Exit;
  CheckErr(rig_set_vfo(FHandle, VfoSelToNative(Vfo)), 'rig_set_vfo');
end;

function THamlibRigControl.GetVFO: TRigVfoSel;
var
  v: TRigVfo;
begin
  Result := rvCurrent;
  if not IsOpen then Exit;
  if rig_get_vfo(FHandle, v) = RIG_OK then
  begin
    if v = RIG_VFO_A then Result := rvA
    else if v = RIG_VFO_B then Result := rvB
    else Result := rvCurrent;
  end;
end;

procedure THamlibRigControl.SetConfStr(const Name, Value: string);
var
  tok: TRigToken;
  err: Integer;
begin
  if FHandle = nil then
    raise ERigControlError.Create(RIG_EINVAL, 'RIG が初期化されていません');
  tok := rig_token_lookup(FHandle, PAnsiChar(Name));
  if tok = 0 then
    raise ERigControlError.Create(Name, RIG_EINVAL, '未知の conf 名です');
  err := rig_set_conf(FHandle, tok, PAnsiChar(Value));
  if err <> RIG_OK then
    raise ERigControlError.Create(Name, err, rigerror(err));
end;

function THamlibRigControl.GetConfStr(const Name: string): string;
var
  tok: TRigToken;
  buf: array[0..255] of AnsiChar;
  err: Integer;
begin
  Result := '';
  if FHandle = nil then
    raise ERigControlError.Create(RIG_EINVAL, 'RIG が初期化されていません');
  tok := rig_token_lookup(FHandle, PAnsiChar(Name));
  if tok = 0 then
    raise ERigControlError.Create(Name, RIG_EINVAL, '未知の conf 名です');
  FillChar(buf, SizeOf(buf), 0);
  err := rig_get_conf2(FHandle, tok, @buf[0], SizeOf(buf));
  if err <> RIG_OK then
    raise ERigControlError.Create(Name, err, rigerror(err));
  Result := StrPas(PAnsiChar(@buf[0]));
end;

function THamlibRigControl.GetNativeHandle: Pointer;
begin
  Result := FHandle;
end;

function THamlibRigControl.RigName: string;
begin
  if FRigModel = RIG_MODEL_NONE then
    Result := ''
  else
    Result := StrPas(rig_get_caps_cptr(FRigModel, RIG_CAPS_MODEL_NAME_CPTR));
end;

type
  TEnumerateContext = record
    Entries: THamlibRigEntryArray;
    Count: Integer;
  end;
  PEnumerateContext = ^TEnumerateContext;

function EnumerateCallback(RigCapsPtr: Pointer; UserData: Pointer): cint; cdecl;
var
  head: PRigCapsHead;
  ctx: PEnumerateContext;
begin
  head := PRigCapsHead(RigCapsPtr);
  ctx := PEnumerateContext(UserData);
  if ctx^.Count >= Length(ctx^.Entries) then
    SetLength(ctx^.Entries, Length(ctx^.Entries) + 64);
  ctx^.Entries[ctx^.Count].RigModel := head^.rig_model;
  if head^.model_name <> nil then
    ctx^.Entries[ctx^.Count].ModelName := StrPas(head^.model_name)
  else
    ctx^.Entries[ctx^.Count].ModelName := '';
  if head^.mfg_name <> nil then
    ctx^.Entries[ctx^.Count].MfgName := StrPas(head^.mfg_name)
  else
    ctx^.Entries[ctx^.Count].MfgName := '';
  Inc(ctx^.Count);
  Result := 1; // 1 = 列挙を継続 (rig_list_foreach の仕様)
end;

class function THamlibRigControl.EnumerateRigs: THamlibRigEntryArray;
var
  ctx: TEnumerateContext;
begin
  rig_load_all_backends; // 冪等 (fldigi: hamlib_get_rigs() も同様の呼び方)
  ctx.Entries := nil;
  ctx.Count := 0;
  rig_list_foreach(@EnumerateCallback, @ctx);
  SetLength(ctx.Entries, ctx.Count);
  Result := ctx.Entries;
end;

class function THamlibRigControl.FindRigModelByName(const AText: string): TRigModel;
var
  Entries: THamlibRigEntryArray;
  i: Integer;
begin
  Result := RIG_MODEL_NONE;
  Entries := EnumerateRigs;
  for i := 0 to High(Entries) do
    if (Pos(Entries[i].MfgName, AText) > 0) and (Pos(Entries[i].ModelName, AText) > 0) then
    begin
      Result := Entries[i].RigModel;
      Exit;
    end;
end;

end.
