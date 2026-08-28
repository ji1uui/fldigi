{ ============================================================================
  HamlibBindings.pas

  Hamlib (https://hamlib.github.io/, rig control library) の C API
  (hamlib/rig.h, V4系) を Free Pascal 向けに直接バインディングした
  低レベルユニット。

  fldigi は無線機の CAT (Computer Aided Transceiver) 制御に Hamlib を
  使用しており (src/include/rigclass.h の class Rig、src/rigcontrol/
  hamlib.cxx)、本ユニットはそれと同じネイティブライブラリを Lazarus/FPC
  から直接呼び出すためのヘッダ移植である。

  重要な設計判断: RIG 構造体は不透明(opaque) として扱う
  ----------------------------------------------------------------------------
  Hamlib の `struct s_rig` (typedef されて RIG) は非常に大きく (実測
  47880 バイト、4.6.2)、かつバージョン間でレイアウトが頻繁に変わる
  内部実装詳細を多数含む。fldigi 自身の rigclass.cxx も `RIG *rig` を
  常に「Hamlib が返してきたポインタ」として扱い、フィールドへ直接アクセス
  するのは `rig->caps->model_name` 等ごく一部の公開ヘッダ内で安定した
  部分のみである。

  本バインディングもこれを踏襲し、RIG 型そのものは定義せず Pointer
  (THamlibRigHandle) として扱う。すべての操作は rig_init/rig_open/
  rig_set_freq 等の API 関数呼び出しのみで行うため、Hamlib のマイナー
  バージョンが変わって内部構造体レイアウトが変化しても、公開 API の
  シグネチャが変わらない限り本バインディングは影響を受けない
  (= 移植性・保守性が高い)。

  対応プラットフォームとリンク方法:
  ----------------------------------------------------------------------------
  - Windows : libhamlib-4.dll (Hamlib公式ビルド or MSYS2 mingw-w64-hamlib
              に含まれる。実行ファイルと同じディレクトリに配置)
  - Linux   : libhamlib.so.4 (Debian/Ubuntu系は `apt install
              libhamlib-dev` で /usr/lib に導入される。本リポジトリの
              検証は Hamlib 4.6.2 で実施)
  - macOS   : libhamlib.4.dylib (Homebrew `brew install hamlib` 等)

  PortAudioBindings.pas と同様、動的ライブラリロードではなく `external`
  による通常のインポートリンクを使用する。
  ============================================================================ }
unit HamlibBindings;

{$mode objfpc}{$H+}

interface

uses
  ctypes;

const
  {$IFDEF WINDOWS}
  HamlibLib = 'libhamlib-4.dll';
  {$ENDIF}
  {$IFDEF DARWIN}
  HamlibLib = 'libhamlib.4.dylib';
  {$ENDIF}
  {$IFDEF LINUX}
  HamlibLib = 'libhamlib.so.4';
  {$ENDIF}
  {$IF NOT (DEFINED(WINDOWS) OR DEFINED(DARWIN) OR DEFINED(LINUX))}
  HamlibLib = 'libhamlib.so.4'; // その他Unix系のフォールバック
  {$ENDIF}

type
  { hamlib/rig.h: typedef struct s_rig RIG;  (不透明。上記コメント参照) }
  THamlibRigHandle = Pointer;

  { hamlib/riglist.h: typedef uint32_t rig_model_t; }
  TRigModel = cuint32;
  { hamlib/rig.h: typedef double freq_t; }
  TRigFreq = cdouble;
  { hamlib/rig.h: typedef unsigned int vfo_t; }
  TRigVfo = cuint;
  { hamlib/rig.h: typedef signed long shortfreq_t; typedef shortfreq_t pbwidth_t; }
  TRigWidth = clong;
  { hamlib/rig.h: typedef uint64_t rmode_t; }
  TRigMode = cuint64;
  { hamlib/rig.h: typedef enum (RIG_PTT_OFF=0, RIG_PTT_ON, ...) ptt_t; }
  TRigPtt = cint;
  { hamlib/rig.h: typedef long hamlib_token_t; }
  TRigToken = clong;
  { hamlib/rig.h: typedef enum (RIG_DCD_OFF=0, RIG_DCD_ON) dcd_t; }
  TRigDcd = cint;
  { hamlib/rig.h: typedef union value_t (levels/params 用。抜粋) }
  TRigValue = record
    case Byte of
      0: (i: cint);
      1: (f: Single);
  end;
  { hamlib/rig.h: typedef uint64_t setting_t; (rig_set_level 等のレベル種別) }
  TRigSetting = cuint64;

const
  { --- rig_model_t の特殊値 (riglist.h) --- }
  RIG_MODEL_NONE       = TRigModel(0);
  RIG_MODEL_DUMMY      = TRigModel(1);   // RIG_MAKE_MODEL(RIG_DUMMY=0, 1)
  RIG_MODEL_NETRIGCTL  = TRigModel(2);   // rigctld へのTCP接続モデル

  { --- vfo_t (抜粋。rig.h の RIG_VFO_N(n) 系マクロの展開値) --- }
  RIG_VFO_NONE = TRigVfo(0);
  RIG_VFO_CURR = TRigVfo(1 shl 29); // RIG_VFO_N(29)
  RIG_VFO_A    = TRigVfo(1 shl 0);  // RIG_VFO_N(0)
  RIG_VFO_B    = TRigVfo(1 shl 1);  // RIG_VFO_N(1)

  { --- rmode_t (抜粋、CONSTANT_64BIT_FLAG(n) = 1 shl n) --- }
  RIG_MODE_NONE   = TRigMode(0);
  RIG_MODE_AM     = TRigMode(1) shl 0;
  RIG_MODE_CW     = TRigMode(1) shl 1;
  RIG_MODE_USB    = TRigMode(1) shl 2;
  RIG_MODE_LSB    = TRigMode(1) shl 3;
  RIG_MODE_RTTY   = TRigMode(1) shl 4;
  RIG_MODE_FM     = TRigMode(1) shl 5;
  RIG_MODE_WFM    = TRigMode(1) shl 6;
  RIG_MODE_CWR    = TRigMode(1) shl 7;
  RIG_MODE_RTTYR  = TRigMode(1) shl 8;
  RIG_MODE_AMS    = TRigMode(1) shl 9;
  RIG_MODE_PKTLSB = TRigMode(1) shl 10;
  RIG_MODE_PKTUSB = TRigMode(1) shl 11;
  RIG_MODE_PKTFM  = TRigMode(1) shl 12;
  RIG_MODE_ECSSUSB = TRigMode(1) shl 13;
  RIG_MODE_ECSSLSB = TRigMode(1) shl 14;
  RIG_MODE_FAX    = TRigMode(1) shl 15;
  RIG_MODE_PKTAM  = TRigMode(1) shl 16;

  { --- ptt_t --- }
  RIG_PTT_OFF     = TRigPtt(0);
  RIG_PTT_ON      = TRigPtt(1);
  RIG_PTT_ON_MIC  = TRigPtt(2);
  RIG_PTT_ON_DATA = TRigPtt(3);

  { --- pbwidth_t 特殊値 --- }
  RIG_WIDTH_NORMAL = TRigWidth(0); // hamlib/rig.h: #define RIG_PASSBAND_NORMAL s_Hz(0)

  { --- rig_errcode_e (エラーコード、0=成功) --- }
  RIG_OK          = 0;
  RIG_EINVAL      = 1;
  RIG_ECONF       = 2;
  RIG_ENOMEM      = 3;
  RIG_ENIMPL      = 4;
  RIG_ETIMEOUT    = 5;
  RIG_EIO         = 6;
  RIG_EINTERNAL   = 7;
  RIG_EPROTO      = 8;
  RIG_ERJCTED     = 9;
  RIG_ETRUNC      = 10;
  RIG_ENAVAIL     = 11;
  RIG_ENTARGET    = 12;
  RIG_BUSERROR    = 13;
  RIG_BUSBUSY     = 14;
  RIG_EARG        = 15;
  RIG_EVFO        = 16;
  RIG_EDOM        = 17;
  RIG_EDEPRECATED = 18;
  RIG_ESECURITY   = 19;
  RIG_EPOWER      = 20;
  RIG_ELIMIT      = 21;
  RIG_EACCESS     = 22;

  { --- rig_debug_level_e --- }
  RIG_DEBUG_NONE    = 0;
  RIG_DEBUG_BUG     = 1;
  RIG_DEBUG_ERR     = 2;
  RIG_DEBUG_WARN    = 3;
  RIG_DEBUG_VERBOSE = 4;
  RIG_DEBUG_TRACE   = 5;
  RIG_DEBUG_CACHE   = 6;

  { --- rig_port_e (hamlib_port_t.type、Rig.getCaps 経由で判定) --- }
  RIG_PORT_NONE    = 0;
  RIG_PORT_SERIAL  = 1;
  RIG_PORT_NETWORK = 2;

  { --- rig_get_caps_int() / rig_get_caps_cptr() の問い合わせ種別
        (enum rig_caps_int_e / rig_caps_cptr_e) --- }
  RIG_CAPS_TARGETABLE_VFO  = 0;
  RIG_CAPS_RIG_MODEL       = 1;
  RIG_CAPS_PORT_TYPE       = 2;
  RIG_CAPS_PTT_TYPE        = 3;
  RIG_CAPS_HAS_GET_LEVEL   = 4;
  RIG_CAPS_HAS_SET_LEVEL   = 5;

  RIG_CAPS_VERSION_CPTR    = 0;
  RIG_CAPS_MFG_NAME_CPTR   = 1;
  RIG_CAPS_MODEL_NAME_CPTR = 2;
  RIG_CAPS_STATUS_CPTR     = 3;

type
  { hamlib/rig.h: typedef int (*rig_debug_msg_callback)(...) — 未使用だがシグネチャ
    整合性のために定義 (rig_set_debug_callback を将来使う場合に備える) }
  TRigVprintfCallback = function(DebugLevel: cint; UserData: Pointer;
    const Fmt: PAnsiChar; Args: Pointer): cint; cdecl;

{ ---- 初期化・生成・解放 (hamlib/rig.h) ---- }
function rig_init(rig_model: TRigModel): THamlibRigHandle; cdecl; external HamlibLib;
function rig_open(arig: THamlibRigHandle): cint; cdecl; external HamlibLib;
function rig_close(arig: THamlibRigHandle): cint; cdecl; external HamlibLib;
function rig_cleanup(arig: THamlibRigHandle): cint; cdecl; external HamlibLib;

{ ---- 周波数 ---- }
function rig_set_freq(arig: THamlibRigHandle; vfo: TRigVfo; freq: TRigFreq): cint; cdecl;
  external HamlibLib;
function rig_get_freq(arig: THamlibRigHandle; vfo: TRigVfo; var freq: TRigFreq): cint; cdecl;
  external HamlibLib;

{ ---- モード / フィルタ幅 ---- }
function rig_set_mode(arig: THamlibRigHandle; vfo: TRigVfo; mode: TRigMode;
  width: TRigWidth): cint; cdecl; external HamlibLib;
function rig_get_mode(arig: THamlibRigHandle; vfo: TRigVfo; var mode: TRigMode;
  var width: TRigWidth): cint; cdecl; external HamlibLib;

{ ---- VFO ---- }
function rig_set_vfo(arig: THamlibRigHandle; vfo: TRigVfo): cint; cdecl; external HamlibLib;
function rig_get_vfo(arig: THamlibRigHandle; var vfo: TRigVfo): cint; cdecl; external HamlibLib;

{ ---- PTT / DCD ---- }
function rig_set_ptt(arig: THamlibRigHandle; vfo: TRigVfo; ptt: TRigPtt): cint; cdecl;
  external HamlibLib;
function rig_get_ptt(arig: THamlibRigHandle; vfo: TRigVfo; var ptt: TRigPtt): cint; cdecl;
  external HamlibLib;
function rig_get_dcd(arig: THamlibRigHandle; vfo: TRigVfo; var dcd: TRigDcd): cint; cdecl;
  external HamlibLib;

{ ---- レベル / パラメータ (拡張用フック。S メータ/パワー等)
       hamlib/rig.h: rig_set_level/rig_get_level (value_t は int/float の union
       だが本バインディングでは TRigValue で表現) ---- }
function rig_set_level(arig: THamlibRigHandle; vfo: TRigVfo; level: TRigSetting;
  val: TRigValue): cint; cdecl; external HamlibLib;
function rig_get_level(arig: THamlibRigHandle; vfo: TRigVfo; level: TRigSetting;
  var val: TRigValue): cint; cdecl; external HamlibLib;
function rig_has_get_level(arig: THamlibRigHandle; level: TRigSetting): cint; cdecl;
  external HamlibLib;
function rig_has_set_level(arig: THamlibRigHandle; level: TRigSetting): cint; cdecl;
  external HamlibLib;

{ ---- 設定 (conf) 文字列。シリアルポートパス・ボーレート等はすべてこれ経由。
       hamlib/rig.h: rig_token_lookup + rig_set_conf/rig_get_conf ---- }
function rig_token_lookup(arig: THamlibRigHandle; const name: PAnsiChar): TRigToken; cdecl;
  external HamlibLib;
function rig_set_conf(arig: THamlibRigHandle; token: TRigToken;
  const val: PAnsiChar): cint; cdecl; external HamlibLib;
function rig_get_conf2(arig: THamlibRigHandle; token: TRigToken; val: PAnsiChar;
  val_len: cint): cint; cdecl; external HamlibLib;

{ ---- 帯域幅ヘルパー ---- }
function rig_passband_normal(arig: THamlibRigHandle; mode: TRigMode): TRigWidth; cdecl;
  external HamlibLib;
function rig_passband_narrow(arig: THamlibRigHandle; mode: TRigMode): TRigWidth; cdecl;
  external HamlibLib;
function rig_passband_wide(arig: THamlibRigHandle; mode: TRigMode): TRigWidth; cdecl;
  external HamlibLib;

{ ---- rig_caps 問い合わせ (rig_model_t 単位。RIG* を開く前でも呼べる) ---- }
function rig_get_caps_int(rig_model: TRigModel; caps_kind: cint): cuint64; cdecl;
  external HamlibLib;
function rig_get_caps_cptr(rig_model: TRigModel; caps_kind: cint): PAnsiChar; cdecl;
  external HamlibLib;

{ ---- エラー文字列 / デバッグレベル ---- }
function rigerror(errnum: cint): PAnsiChar; cdecl; external HamlibLib;
function rig_set_debug(debug_level: cint): cint; cdecl; external HamlibLib;

{ ---- 全バックエンド一覧取得 (fldigi: hamlib_get_rigs 相当)
       hamlib/rig.h:
         int rig_load_all_backends(void);
         int rig_list_foreach(int (*cfunc)(const struct rig_caps*, void*), void* data);
       rig_caps 構造体全体は複雑なため、コールバックには「不透明ポインタ」を
       そのまま渡し、Pascal 側では rig_get_caps_int/cptr でモデルIDと文字列
       だけを都度問い合わせる設計にする (構造体レイアウトを固定しなくて済む)。 }
type
  TRigListForeachCallback = function(RigCapsPtr: Pointer; UserData: Pointer): cint; cdecl;

function rig_load_all_backends: cint; cdecl; external HamlibLib;
function rig_list_foreach(cfunc: TRigListForeachCallback; data: Pointer): cint; cdecl;
  external HamlibLib;

{ ---- rig_caps 構造体の先頭2フィールド (rig_model_t, model_name の直後に
       mfg_name) だけを読む最小限のヘルパー。
       struct rig_caps の先頭は以下の順で安定している (rig.h 参照):
         rig_model_t rig_model;   (4バイト、ただし後続に4バイトのパディング)
         const char *model_name;
         const char *mfg_name;
       これは rig_list_foreach のコールバックから rig_model を取得する際、
       rig_get_caps_int(RIG_CAPS_RIG_MODEL) 相当の情報を「モデル一覧構築の
       コールバック内で」直接取るために使う。安定した先頭部のみに限定し、
       それ以降のフィールドには一切アクセスしない。 }
type
  PRigCapsHead = ^TRigCapsHead;
  TRigCapsHead = record
    rig_model: TRigModel;
    _pad: cuint32; // 64bit環境でのポインタアラインメント用パディング
    model_name: PAnsiChar;
    mfg_name: PAnsiChar;
  end;

implementation

end.
