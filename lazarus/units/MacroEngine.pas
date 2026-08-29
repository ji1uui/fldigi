{ ============================================================================
  MacroEngine.pas

  fldigi の src/misc/macros.cxx (class MACROTEXT, MACRO_EDIT の <TAG> 展開)
  を Lazarus/FPC 向けに再設計した「マクロ展開エンジン」。

  何のための機能か:
  ----------------------------------------------------------------------------
  アマチュア無線のデジタルモード運用では、交信の大半が定型文で進む。
  CQ を出す → 呼ばれる → レポートを送る → 相手のレポートを受ける →
  名前とQTHを送る → 73 で終わる。この定型交信を「ラバースタンプQSO」と呼ぶ。
  毎回タイプするのは現実的でないので、

      CQ CQ CQ de <MYCALL> <MYCALL> pse k

  のような雛形を用意し、<MYCALL> のような差し込み記号 (タグ) を実行時に
  実際の値へ置き換えて送信する。これがマクロである。

  コンテストではさらに速度が要るうえ、送信ナンバーの管理という
  「間違えると交信が無効になる」要素が加わる。本ユニットはラバースタンプと
  コンテストの両方を同じ仕組みで扱う。

  fldigi との対応:
  ----------------------------------------------------------------------------
  | fldigi                                   | 本ユニット                     |
  |------------------------------------------|--------------------------------|
  | MACROTEXT::expand()                      | TMacroExpander.Expand          |
  | MACROTEXT::text[] / name[] (固定 48 個)  | TMacroSet (可変長・名前引き)   |
  | macro_types[] のタグ表                   | 内部のタグディスパッチ         |
  | <TX>/<RX> が直接 trx_transmit() を呼ぶ   | TMacroSegment として "返す"    |

  設計上いちばん重要な違い (なぜ文字列を返さないのか):
  ----------------------------------------------------------------------------
  fldigi の expand() は展開しながら副作用 (送信開始/停止、モード変更) を
  その場で実行してしまう。これだと

    - 送信前に「このマクロは何をするか」を確認できない
    - GUI 無し・無線機無しで単体テストできない
    - 「展開はできたが送信はしない (プレビュー)」ができない

  という三つの問題がある。そこで本ユニットは展開結果を
  「文字列断片と操作命令が順番に並んだ列」(TMacroSegment の配列) として
  返すだけにし、実行は呼び出し側に任せる。

      <TX>CQ de <MYCALL> k<RX>
        -> [操作:送信開始] [文字列:"CQ de JI1UUI k"] [操作:受信復帰]

  こうすると、同じ展開結果を「送信する」「画面に見せるだけ」「検査する」の
  どれにも使える。送信前バリデーション (Validate) が成立するのもこの形の
  おかげである。

  コンテスト運用で特に配慮した点:
  ----------------------------------------------------------------------------
  1. 送信ナンバーは "ログするまで進めない"
     <#> を展開しただけでは番号は進まない。CommitSerial を呼んだときだけ
     進む。呼ばれた局に 001 を送ったあと交信不成立でログしなかった場合、
     次の局にも 001 を送るのが正しい (番号を飛ばすとログ照合で減点される)。
     展開のたびに採番する実装だと、再送のたびに番号が飛ぶ。

  2. CW のカットナンバー
     コンテストのCWでは 0 を T、9 を N と短縮して送る慣習がある
     (599 -> 5NN、100 -> ATT)。<#CUT> で出力できるようにした。

  3. 送信したまま受信に戻らないマクロを事前に弾く
     <TX> で始まり <RX> で終わらないマクロは、実行すると電波を出しっぱなしに
     する。コンテスト中に気づかず放置すると被害が大きいので、
     Validate がエラーとして報告する。
  ============================================================================ }
unit MacroEngine;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, DateUtils, StrUtils, fpjson, jsonparser,
  SafeFileIO, StationInfo;

type
  EMacroError = class(Exception);

  { --- 交信における「立場」 ---
    同じ局面でも、CQ を出している側と呼んでいる側では送る内容が違う。
    ラバースタンプでもコンテストでも、この区別なしに「次に送るべきもの」は
    決まらない。 }
  TQsoRole = (
    qrRun,           // CQ を出して呼ばれる側
    qrSearchPounce   // 相手の CQ を探して呼ぶ側
  );

  { --- 交信の局面 ---
    定型交信は状態機械である。どの局面にいるかで「次に送るもの」も
    「今ログしてよいか」も決まる。
    以前の設計はこれを持たず、値の入れ物しか無かったため、
      - 交換を受け取る前にログできてしまう
      - ログ後も相手のコールが残り、次の交信で誤ったコールを送る
      - 「次に押すべきキー」を提示できない
    という穴があった。 }
  TQsoPhase = (
    qpIdle,          // 相手がいない (CQ を出す / 相手を探す)
    qpCalling,       // 呼びかけた (CQ 送出済み / 相手を呼んだ)
    qpAnswered,      // 相手のコールサインを取得した
    qpExchangeSent,  // レポート/ナンバーを送った
    qpExchangeRcvd,  // 相手のレポート/ナンバーを受け取った (ログ可)
    qpConfirmed      // TU/73 を送った
  );
  TQsoPhaseSet = set of TQsoPhase;

  { マクロがどちらの立場のものか。 }
  TMacroRoleFilter = (
    mrfAny,          // どちらでも使う
    mrfRun,
    mrfSearchPounce
  );

  { マクロが呼び出し側に依頼する操作。
    fldigi では expand() の中で直接実行されるが、本ユニットは
    「依頼を返す」だけにして実行を呼び出し側に委ねる。 }
  TMacroActionKind = (
    makTransmit,    // <TX>      送信開始
    makReceive,     // <RX>      受信復帰 (送信バッファを送り切ってから)
    makAbortTx,     // <ABORT>   送信即時中止
    makLog,         // <LOG>     現在の交信をログに記録
    makClearRx,     // <CLRRX>   受信ウィンドウを消去
    makClearTx,     // <CLRTX>   送信ウィンドウを消去
    makSetMode,     // <MODE:x>  モード変更 (Arg にモード名)
    makSetFreq,     // <FREQ:x>  周波数変更 (ArgNum に MHz)
    makIncSerial,   // <INCR>    送信ナンバーを1増やす
    makDecSerial,   // <DECR>    送信ナンバーを1減らす
    makWait         // <WAIT:n>  n 秒待つ (ArgNum に秒)
  );

  TMacroSegmentKind = (
    mskText,        // 送信すべき文字列
    mskAction       // 呼び出し側への操作依頼
  );

  { 展開結果の1断片。文字列と操作が元の順序どおりに並ぶ。 }
  TMacroSegment = record
    Kind: TMacroSegmentKind;
    Text: string;              // mskText のときの本文
    Action: TMacroActionKind;  // mskAction のときの操作
    Arg: string;               // 操作の文字列引数 (<MODE:RTTY> の "RTTY")
    ArgNum: Double;            // 操作の数値引数 (<WAIT:3> の 3)
  end;
  TMacroSegmentArray = array of TMacroSegment;

  TMacroIssueLevel = (
    milInfo,      // 参考情報
    milWarning,   // 送信はできるが意図と違う可能性がある
    milError      // 送信すべきでない
  );

  { 送信前バリデーションの指摘 1件。 }
  TMacroIssue = record
    Level: TMacroIssueLevel;
    Tag: string;        // 原因となったタグ (無い場合は空)
    Message: string;
  end;
  TMacroIssueArray = array of TMacroIssue;

  { 展開の結果一式。 }
  TMacroExpansion = record
    Segments: TMacroSegmentArray;
    Issues: TMacroIssueArray;
    { 展開中に実際に使われた差し込みタグの名前 (大文字, 重複なし)。
      展開後の文字列を見ても「<CALL> が空だった」のか
      「もともと <CALL> を書いていない」のかは区別できない。
      CQ のように相手がいない場面で「相手のコールが空です」と
      言われては困るので、使ったかどうかを展開時に記録しておく。 }
    UsedTags: array of string;

    { すべての mskText を連結したもの。プレビュー表示や
      「実際に電波に乗る文字列」の確認に使う。 }
    function PlainText: string;
    function SegmentCount: Integer;
    function ActionCount: Integer;
    function IssueCount(ALevel: TMacroIssueLevel): Integer;
    { milError が 1 件でもあれば True。送信を止める判断に使う。 }
    function HasErrors: Boolean;
    function HasWarnings: Boolean;
    { 指摘を人が読める1つの文字列にまとめる (改行区切り)。 }
    function IssueText: string;
    { 指定した操作が含まれるか。 }
    function ContainsAction(AKind: TMacroActionKind): Boolean;
    { 指定した差し込みタグが使われたか (名前は大小どちらでもよい)。 }
    function UsesTag(const ATag: string): Boolean;
  end;

  { マクロの用途区分。UI でタブを分けたり、コンテスト中に
    ラグチュー用マクロを隠したりするために持つ。 }
  TMacroCategory = (
    mcGeneral,      // 汎用
    mcRubberStamp,  // ラバースタンプ (定型交信)
    mcContest       // コンテスト
  );

  { --- 展開に使う値の入れ物 ---
    「自局」「相手局」「運用状態」「コンテスト」の4群からなる。
    自局の値は OpProfile.TResolvedStation から流し込む想定。 }
  TMacroContext = class
  private
    FMyCall: string;
    FMyName: string;
    FMyQth: string;
    FMyLocator: string;
    FMyRig: string;
    FMyAntenna: string;
    FMyPowerW: Integer;

    FCall: string;
    FName: string;
    FQth: string;
    FLocator: string;
    FRstSent: string;
    FRstRcvd: string;

    FBand: string;
    FMode: string;
    FFreqMHz: Double;

    FContestName: string;
    FSerialOut: Integer;
    FSerialDigits: Integer;
    FSerialIn: string;
    FExchangeOut: string;
    FExchangeIn: string;

    FFixedUtcNow: TDateTime;

    FRole: TQsoRole;
    FPhase: TQsoPhase;
    FIsDuplicate: Boolean;

    { 相手局の値が入ったら局面を前へ進める (後戻りはしない)。
      オペレータが「コールを打ち込む」「レポートを受け取る」という
      自然な操作だけで局面が正しく進むようにするための仕掛けで、
      これがないと局面管理が「別途やる作業」になり必ず忘れられる。 }
    procedure AdvancePhaseTo(APhase: TQsoPhase);
    procedure SetCall(const AValue: string);
    procedure SetRstRcvd(const AValue: string);
    procedure SetSerialIn(const AValue: string);
    procedure SetExchangeIn(const AValue: string);
  public
    constructor Create;

    { 現在の UTC。FixedUtcNow が 0 でなければそれを返す
      (テストで時刻を固定するため。時計をモックするより読みやすい)。 }
    function UtcNow: TDateTime;

    { 送信ナンバーを確定して次へ進める。ログ記録が成功した後にだけ呼ぶこと。
      展開 (<#>) では進めない ― 交信不成立で番号を飛ばすと、
      コンテストのログ照合で「相手の受信番号と合わない」減点になる。 }
    procedure CommitSerial;
    procedure ResetSerial(AStart: Integer = 1);

    { 相手局に関する項目だけを消し、局面を qpIdle へ戻す
      (次の交信へ移るとき)。自局・運用状態・送信ナンバーは残る。
      ログ成功時に TMacroRunner が自動的に呼ぶ ― 以前はこれを
      実装だけして誰も呼んでおらず、ログ後も前の局のコールが残って
      次の交信で誤ったコールサインを送る状態だった。 }
    procedure ClearWorkedStation;

    { 自局の値を TStationInfo から流し込む。
      OpProfile の解決結果は TResolvedStation.ToStationInfo で
      TStationInfo に落ちるので、
        Registry.Resolve(...).ToStationInfo(info);
        ctx.LoadFromStationInfo(info);
      という2段で運用プロファイルの実効値がマクロまで届く。
      これをしないと、移動運用でコールが JI1UUI/1 に変わっても
      マクロは古いコールを送り続ける。 }
    procedure LoadFromStationInfo(AStationInfo: TStationInfo);

    { --- 自局 --- }
    property MyCall: string read FMyCall write FMyCall;
    property MyName: string read FMyName write FMyName;
    property MyQth: string read FMyQth write FMyQth;
    property MyLocator: string read FMyLocator write FMyLocator;
    property MyRig: string read FMyRig write FMyRig;
    property MyAntenna: string read FMyAntenna write FMyAntenna;
    property MyPowerW: Integer read FMyPowerW write FMyPowerW;

    { --- 相手局 --- }
    { 相手のコールが入った時点で局面は qpAnswered へ進む。 }
    property Call: string read FCall write SetCall;
    property Name: string read FName write FName;
    property Qth: string read FQth write FQth;
    property Locator: string read FLocator write FLocator;
    property RstSent: string read FRstSent write FRstSent;
    { 相手のレポートが入った時点で局面は qpExchangeRcvd へ進む
      (= ログしてよい状態)。 }
    property RstRcvd: string read FRstRcvd write SetRstRcvd;

    { --- 運用状態 --- }
    property Band: string read FBand write FBand;
    property Mode: string read FMode write FMode;
    property FreqMHz: Double read FFreqMHz write FFreqMHz;

    { --- コンテスト --- }
    property ContestName: string read FContestName write FContestName;
    { これから送る番号。CommitSerial を呼ぶまで変わらない。 }
    property SerialOut: Integer read FSerialOut write FSerialOut;
    { 送信ナンバーのゼロ詰め桁数 (既定 3 = 001)。 }
    property SerialDigits: Integer read FSerialDigits write FSerialDigits;
    property SerialIn: string read FSerialIn write SetSerialIn;
    property ExchangeOut: string read FExchangeOut write FExchangeOut;
    property ExchangeIn: string read FExchangeIn write SetExchangeIn;

    { 0 以外なら UtcNow がこの値を返す (テスト用)。 }
    property FixedUtcNow: TDateTime read FFixedUtcNow write FFixedUtcNow;

    { --- 局面 --- }
    { CQ を出す側か、呼ぶ側か。 }
    property Role: TQsoRole read FRole write FRole;
    { 現在の局面。通常は値の投入で自動的に進むので、
      直接書くのは「取り消し」「やり直し」のような明示操作のときだけ。 }
    property Phase: TQsoPhase read FPhase write FPhase;
    { この相手と既に交信済みか (コンテストのデュープ)。
      呼び出し側が TContestLog.IsDuplicate 等を見て設定する。 }
    property IsDuplicate: Boolean read FIsDuplicate write FIsDuplicate;
  end;

  { 1つのマクロ定義。 }
  TMacroDefinition = class
  private
    FName: string;
    FText: string;
    FNote: string;
    FCategory: TMacroCategory;
    FRoleFilter: TMacroRoleFilter;
    FValidPhases: TQsoPhaseSet;
    FResultPhase: TQsoPhase;
    FHasResultPhase: Boolean;
  public
    constructor Create(const AName, AText: string;
      ACategory: TMacroCategory = mcGeneral; const ANote: string = '');

    { このマクロが「いつ使うものか」を宣言する。
      これがあると
        - 局面に合わないマクロを押したときに警告できる
        - 「次に押すべきマクロ」を提示できる (ESM: Enter Sends Message)
      の両方が成り立つ。宣言しなければ従来どおり「いつでも使える」。 }
    procedure DeclareSequence(ARole: TMacroRoleFilter;
      AValidPhases: TQsoPhaseSet; AResultPhase: TQsoPhase);
    procedure ClearSequence;

    { 指定の立場・局面で使うマクロか。 }
    function MatchesSequence(ARole: TQsoRole; APhase: TQsoPhase): Boolean;

    property Name: string read FName write FName;
    property Text: string read FText write FText;
    property Note: string read FNote write FNote;
    property Category: TMacroCategory read FCategory write FCategory;
    property RoleFilter: TMacroRoleFilter read FRoleFilter write FRoleFilter;
    { 空集合 = どの局面でも使える。 }
    property ValidPhases: TQsoPhaseSet read FValidPhases write FValidPhases;
    { 実行後に遷移する局面 (HasResultPhase が True のときのみ有効)。 }
    property ResultPhase: TQsoPhase read FResultPhase;
    property HasResultPhase: Boolean read FHasResultPhase;
  end;

  { マクロの一覧。ファンクションキーへの割り当ては呼び出し側 (UI) の責務とし、
    ここでは「名前で引ける定義の集合」に徹する。 }
  TMacroSet = class
  private
    FItems: array of TMacroDefinition;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TMacroDefinition;
    procedure CheckIndex(AIndex: Integer);
  public
    destructor Destroy; override;
    procedure Clear;

    function Add(const AName, AText: string;
      ACategory: TMacroCategory = mcGeneral;
      const ANote: string = ''): TMacroDefinition;
    { 同名があれば内容を差し替え、無ければ追加する。 }
    function AddOrReplace(const AName, AText: string;
      ACategory: TMacroCategory = mcGeneral;
      const ANote: string = ''): TMacroDefinition;
    function Find(const AName: string): TMacroDefinition;
    function IndexOf(const AName: string): Integer;
    function Remove(const AName: string): Boolean;

    { 指定の立場・局面で「次に使うべき」マクロを返す (見つからなければ nil)。
      ESM (Enter Sends Message) の土台になる。オペレータが局面ごとに
      正しいキーを覚える必要が無くなり、コンテストの速度に効く。
      複数該当する場合は登録順で最初のものを返す。 }
    function FindForSequence(ARole: TQsoRole;
      APhase: TQsoPhase): TMacroDefinition;

    { ラバースタンプ交信とコンテスト運用の標準セットを登録する。
      「何から書き始めればいいか分からない」状態を避けるための出発点であり、
      利用者が自由に編集して使うことを前提としている。 }
    procedure RegisterBuiltins;

    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    function ToJsonString: string;
    procedure FromJsonString(const AJson: string);

    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TMacroDefinition read GetItem; default;
  end;

  { マクロ展開器。状態を持たないので 1 個を使い回してよい。 }
  TMacroExpander = class
  private
    FMacros: TMacroSet;      // <MACRO:名前> の解決先。nil 可 (参照のみ)。
    FMaxDepth: Integer;
    FStrictUnknownTags: Boolean;
    procedure ExpandInto(const AText: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; ADepth: Integer;
      var APending: string);
    procedure Flush(var AResult: TMacroExpansion; var APending: string);
    { 操作を積む。文字列と操作の順序を保つため、溜まっている文字列を
      先に確定させてから積むこと。そのため APending も受け取る。 }
    procedure AddAction(var AResult: TMacroExpansion; var APending: string;
      AKind: TMacroActionKind; const AArg: string; AArgNum: Double);
    procedure AddIssue(var AResult: TMacroExpansion; ALevel: TMacroIssueLevel;
      const ATag, AMessage: string);
    { 差し込みタグを使ったことを記録する (Validate が使う)。 }
    procedure NoteTagUsed(var AResult: TMacroExpansion; const ATag: string);
    { タグ 1 個を処理する。文字列に展開されるなら APending に足し、
      操作なら AResult へ積む。戻り値: 既知のタグだったか。
      ATagName には正規化した (大文字・引数を除いた) タグ名を返す。 }
    function HandleTagCore(const ATagBody: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; ADepth: Integer;
      var APending: string; out ATagName: string): Boolean;
    { HandleTagCore を呼び、既知タグだった場合だけ使用記録を残す。 }
    function HandleTag(const ATagBody: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; ADepth: Integer;
      var APending: string): Boolean;

    { --- 宣言的な条件分岐・反復 ---
      いずれも "展開時に" 解決する。実行時に分岐するのではなく、
      展開し終わった段階では条件の無い平坦な列になっている。
      これが決定的に重要で、おかげで送信前バリデーションが
      そのまま成立する (「今回実際に送られるもの」を検査できる)。
      スクリプト言語を埋め込むとこの性質が失われる。 }
    function EvalCondition(const ACond: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; out AValue: Boolean): Boolean;
    { AStartPos (開きタグの直後) から対応する閉じタグを探す。
      AElsePos は IF のときだけ意味を持つ (無ければ 0)。 }
    function FindBlockEnd(const AText: string; AStartPos: Integer;
      AIsIf: Boolean; var AResult: TMacroExpansion;
      out AElsePos, AEndPos, AAfterPos: Integer): Boolean;
  public
    constructor Create(AMacros: TMacroSet = nil);

    { 本文を展開する。 }
    function Expand(const AText: string; ACtx: TMacroContext): TMacroExpansion;
    { 登録済みマクロを名前で展開する。 }
    function ExpandNamed(const AName: string; ACtx: TMacroContext): TMacroExpansion;

    { 展開結果を送信前に検査し、Issues を追加して返す。
      Expand が「書き方の問題」(未知タグ等) を見るのに対し、こちらは
      「今この状況で送っていいか」を見る。 }
    { ADefinition を渡すと、そのマクロが宣言した「使うべき局面」と
      現在の局面が食い違っていないかも見る (押し間違いの検出)。 }
    function Validate(const AExpansion: TMacroExpansion;
      ACtx: TMacroContext;
      ADefinition: TMacroDefinition = nil): TMacroExpansion;

    { 展開と検査をまとめて行う (送信ボタンから呼ぶ入口)。 }
    function Prepare(const AText: string; ACtx: TMacroContext): TMacroExpansion;
    function PrepareNamed(const AName: string; ACtx: TMacroContext): TMacroExpansion;

    { <MACRO:名前> の解決先。 }
    property Macros: TMacroSet read FMacros write FMacros;
    { <MACRO:...> の入れ子の深さ上限 (既定 8)。無限再帰を止める。 }
    property MaxDepth: Integer read FMaxDepth write FMaxDepth;
    { True にすると未知タグを milError にする (既定 False = 警告)。 }
    property StrictUnknownTags: Boolean
      read FStrictUnknownTags write FStrictUnknownTags;
  end;

  TMacroRunner = class;

  { --- マクロを実際に実行するための宿主 ---
    展開結果 (TMacroSegment の列) を「誰が」実行するかを抽象化する。
    実機ではフォームがこれを実装し、TModemEngine / TCustomRigControl /
    TQsoLogbook へ配線する。テストでは記録するだけの実装を差し込む。

    【重要: 非同期の契約】
    送信は実時間で数秒から十数秒かかる。同期的に「送って戻る」ことはできない。
    そこで時間のかかる操作は「依頼」で、完了は宿主から Runner へ折り返す。

      RequestReceive  : 送信バッファを送り切ってから受信へ戻し、
                        完了したら Runner.NotifyTxFinished を呼ぶ
      StartTimer      : 指定秒後に Runner.NotifyTimerElapsed を呼ぶ

    この折り返しがあって初めて、<RX> の後ろに置いた <LOG> が
    「本当に送信し終わってから」実行される。以前の同期実装では
    送信をキューに積んだ直後にログしており、送信を中断してもログが
    残り、ADIF の TIME_OFF も実際の交信終了より前になっていた。

    【スレッド】Runner のメソッドはすべて同じスレッド (通常は UI スレッド)
    から呼ぶこと。宿主が別スレッドで送信完了を検出した場合は、
    TThread.Queue 等で UI スレッドへ渡してから Notify を呼ぶ。
    違反は EMacroError として検出される。 }
  TMacroHost = class abstract
  private
    FRunner: TMacroRunner;
  public
    { 送信バッファへ本文を積む。 }
    procedure SendText(const AText: string); virtual; abstract;
    { 送信を開始する (即時)。 }
    procedure StartTransmit; virtual; abstract;
    { 送信バッファを送り切ってから受信へ戻す。
      完了したら Runner.NotifyTxFinished を呼ぶこと。 }
    procedure RequestReceive; virtual; abstract;
    { 送信を即時中止する (バッファは捨てる)。完了通知は不要。 }
    procedure AbortTransmit; virtual; abstract;
    { 現在の交信をログに記録する。戻り値が True のときだけ
      送信ナンバーが進み、相手局情報が消える。 }
    function LogCurrentQso: Boolean; virtual; abstract;
    procedure ClearRxWindow; virtual; abstract;
    procedure ClearTxWindow; virtual; abstract;
    procedure SetMode(const AMode: string); virtual; abstract;
    procedure SetFreqMHz(AFreqMHz: Double); virtual; abstract;
    { ASeconds 秒後に Runner.NotifyTimerElapsed を呼ぶこと。 }
    procedure StartTimer(ASeconds: Double); virtual; abstract;

    { 実行中の Runner。TMacroRunner が Host を設定するときに自動で入る。 }
    property Runner: TMacroRunner read FRunner write FRunner;
  end;

  { マクロ実行の進行状態。 }
  TMacroRunState = (
    mrsIdle,          // 実行していない
    mrsWaitingTxEnd,  // <RX> の送信終了待ち
    mrsWaitingTimer,  // <WAIT:n> の経過待ち
    mrsDone,          // 最後まで実行した
    mrsAborted        // 中断した
  );

  { 実行中に別のマクロを起動しようとしたときの扱い。 }
  TMacroBusyPolicy = (
    mbpReject,        // 拒否する (既定。誤操作で送信内容が混ざらない)
    mbpReplace        // 実行中のものを中断して差し替える
  );

  { マクロ実行の結果 (起動時点で分かること)。 }
  TMacroRunResult = record
    Started: Boolean;       // 実行を開始したか
    Logged: Boolean;        // ログ記録が行われ成功したか (完了時に確定)
    SerialAdvanced: Boolean;
    Completed: Boolean;     // 待ちに入らず最後まで走り切ったか
    RefusalReason: string;  // Started=False のときの理由
  end;

  { 実行完了の通知。 }
  TMacroDoneEvent = procedure(Sender: TMacroRunner;
    ACompleted: Boolean) of object;

  { --- 展開結果を宿主へ流し込む実行器 (状態機械) ---
    断片を順に処理し、時間のかかる操作 (<RX>/<WAIT>) に当たったら
    そこで止まって宿主からの折り返しを待つ。 }
  TMacroRunner = class
  private
    FHost: TMacroHost;
    FExpander: TMacroExpander;
    FAllowWithWarnings: Boolean;
    FBusyPolicy: TMacroBusyPolicy;
    FClearAfterLog: Boolean;
    FStepTimeoutSec: Integer;

    FState: TMacroRunState;
    FSegments: TMacroSegmentArray;
    FIndex: Integer;               // 次に処理する断片
    FCtx: TMacroContext;
    FDefinition: TMacroDefinition; // 実行中マクロ (順序遷移の適用に使う)
    FOwnerThreadId: TThreadID;
    FStepStartedAt: TDateTime;
    FLogged: Boolean;
    FSerialAdvanced: Boolean;
    FOnDone: TMacroDoneEvent;

    procedure SetHost(AValue: TMacroHost);
    procedure CheckThread;
    { 展開・検査・実行の本体。ADefinition は順序の検査と遷移に使う
      (名前で起動したときだけ渡る)。 }
    function ExecuteInternal(const AText: string; ACtx: TMacroContext;
      ADefinition: TMacroDefinition; AForce: Boolean): TMacroRunResult;
    { 断片を進められるところまで進める。 }
    procedure Step;
    procedure FinishRun(AState: TMacroRunState);
    procedure ApplyResultPhase;
    { 待ちが長すぎる場合に自動で中断する (宿主が折り返しを忘れても
      永久に Busy のままにならないようにするための保険)。 }
    procedure CheckStepTimeout;
    function GetBusy: Boolean;
  public
    constructor Create(AHost: TMacroHost; AExpander: TMacroExpander = nil);

    { --- 実行の入口 ---
      展開・検査・実行を 1 回の呼び出しにまとめてある。
      以前は Prepare して Run に渡す形だったが、その間にコンテキストが
      書き換わると「検査した状態と違う状態で送る」ことになり、
      しかも型の上では別のコンテキストで検査した結果すら渡せた。
      不可分にすることでその隙間を無くしている。
      プレビューが必要なときは TMacroExpander.Prepare を別途使う
      (表示専用。実行はこちらが再展開する)。 }
    function Execute(const AText: string; ACtx: TMacroContext;
      AForce: Boolean = False): TMacroRunResult;
    function ExecuteNamed(const AName: string; ACtx: TMacroContext;
      AForce: Boolean = False): TMacroRunResult;
    { 現在の立場・局面に合ったマクロを選んで実行する
      (ESM: Enter Sends Message)。該当が無ければ実行しない。 }
    function ExecuteForSequence(ACtx: TMacroContext;
      AForce: Boolean = False): TMacroRunResult;

    { --- 宿主からの折り返し --- }
    procedure NotifyTxFinished;
    procedure NotifyTimerElapsed;

    { 実行中のマクロを中断する。 }
    procedure Abort;

    property Host: TMacroHost read FHost write SetHost;
    property Expander: TMacroExpander read FExpander write FExpander;
    property State: TMacroRunState read FState;
    { 実行中か (待ち状態を含む)。 }
    property Busy: Boolean read GetBusy;
    property Logged: Boolean read FLogged;

    property AllowWithWarnings: Boolean
      read FAllowWithWarnings write FAllowWithWarnings;
    { 実行中に別のマクロを起動したときの扱い (既定 mbpReject)。 }
    property BusyPolicy: TMacroBusyPolicy read FBusyPolicy write FBusyPolicy;
    { ログ成功時に相手局情報を消して局面を戻すか (既定 True)。 }
    property ClearAfterLog: Boolean read FClearAfterLog write FClearAfterLog;
    { 1 つの待ちに許す秒数 (既定 120)。超えたら自動的に中断する。 }
    property StepTimeoutSec: Integer read FStepTimeoutSec write FStepTimeoutSec;
    property OnDone: TMacroDoneEvent read FOnDone write FOnDone;
  end;

{ 送信ナンバーをゼロ詰めした文字列にする (3桁なら 7 -> "007")。 }
function FormatSerial(AValue, ADigits: Integer): string;

{ CW コンテストのカットナンバー表記に変換する (0 -> T, 9 -> N)。
  599 -> 5NN、100 -> ATT ではなく 1TT (1 は短縮しないのが安全側)。
  数字以外はそのまま通す。 }
function ToCutNumbers(const AText: string): string;

{ 「値を差し込むだけ」のタグ名から値を引く。展開と条件式が共用する。
  戻り値: 既知のタグだったか。 }
function MacroValueByName(const ATagName: string; ACtx: TMacroContext;
  out AValue: string): Boolean;

function MacroCategoryToStr(ACategory: TMacroCategory): string;
function StrToMacroCategory(const AStr: string): TMacroCategory;
function MacroIssueLevelToStr(ALevel: TMacroIssueLevel): string;

function QsoPhaseToStr(APhase: TQsoPhase): string;
function StrToQsoPhase(const AStr: string): TQsoPhase;
function QsoPhaseSetToStr(APhases: TQsoPhaseSet): string;
function StrToQsoPhaseSet(const AStr: string): TQsoPhaseSet;
function MacroRoleFilterToStr(ARole: TMacroRoleFilter): string;
function StrToMacroRoleFilter(const AStr: string): TMacroRoleFilter;
function QsoPhaseDescription(APhase: TQsoPhase): string;

implementation

const
  MACRO_JSON_VERSION = 1;
  DEFAULT_SERIAL_DIGITS = 3;
  DEFAULT_MAX_DEPTH = 8;
  { <REPEAT:n> の上限。展開時に n 回ぶん実体化するので、
    大きな値を許すとメモリと送信時間の両方が破裂する。
    CQ を数回繰り返す用途しか想定していない。 }
  MAX_REPEAT_COUNT = 20;

{ ============================ 補助関数 ============================ }

function FormatSerial(AValue, ADigits: Integer): string;
var
  s: string;
begin
  if ADigits < 1 then ADigits := 1;
  if ADigits > 9 then ADigits := 9;
  s := IntToStr(Abs(AValue));
  while Length(s) < ADigits do
    s := '0' + s;
  if AValue < 0 then
    s := '-' + s;
  Result := s;
end;

function ToCutNumbers(const AText: string): string;
var
  i: Integer;
begin
  Result := AText;
  for i := 1 to Length(Result) do
    case Result[i] of
      '0': Result[i] := 'T';
      '9': Result[i] := 'N';
    end;
end;

function MacroCategoryToStr(ACategory: TMacroCategory): string;
begin
  case ACategory of
    mcRubberStamp: Result := 'rubberstamp';
    mcContest:     Result := 'contest';
  else
    Result := 'general';
  end;
end;

function StrToMacroCategory(const AStr: string): TMacroCategory;
var
  s: string;
begin
  s := LowerCase(Trim(AStr));
  if s = 'rubberstamp' then Result := mcRubberStamp
  else if s = 'contest' then Result := mcContest
  else Result := mcGeneral;
end;

function MacroIssueLevelToStr(ALevel: TMacroIssueLevel): string;
begin
  case ALevel of
    milError:   Result := 'エラー';
    milWarning: Result := '警告';
  else
    Result := '情報';
  end;
end;

function QsoPhaseToStr(APhase: TQsoPhase): string;
begin
  case APhase of
    qpCalling:      Result := 'calling';
    qpAnswered:     Result := 'answered';
    qpExchangeSent: Result := 'exchangeSent';
    qpExchangeRcvd: Result := 'exchangeRcvd';
    qpConfirmed:    Result := 'confirmed';
  else
    Result := 'idle';
  end;
end;

function StrToQsoPhase(const AStr: string): TQsoPhase;
var
  t: string;
begin
  t := LowerCase(Trim(AStr));
  if t = 'calling' then Result := qpCalling
  else if t = 'answered' then Result := qpAnswered
  else if t = 'exchangesent' then Result := qpExchangeSent
  else if t = 'exchangercvd' then Result := qpExchangeRcvd
  else if t = 'confirmed' then Result := qpConfirmed
  else Result := qpIdle;
end;

function QsoPhaseSetToStr(APhases: TQsoPhaseSet): string;
var
  p: TQsoPhase;
begin
  Result := '';
  for p := Low(TQsoPhase) to High(TQsoPhase) do
    if p in APhases then
    begin
      if Result <> '' then Result := Result + ',';
      Result := Result + QsoPhaseToStr(p);
    end;
end;

function StrToQsoPhaseSet(const AStr: string): TQsoPhaseSet;
var
  parts: TStringList;
  i: Integer;
begin
  Result := [];
  if Trim(AStr) = '' then Exit;
  parts := TStringList.Create;
  try
    parts.Delimiter := ',';
    parts.StrictDelimiter := True;
    parts.DelimitedText := AStr;
    for i := 0 to parts.Count - 1 do
      if Trim(parts[i]) <> '' then
        Include(Result, StrToQsoPhase(parts[i]));
  finally
    parts.Free;
  end;
end;

function MacroRoleFilterToStr(ARole: TMacroRoleFilter): string;
begin
  case ARole of
    mrfRun:          Result := 'run';
    mrfSearchPounce: Result := 'searchPounce';
  else
    Result := 'any';
  end;
end;

function StrToMacroRoleFilter(const AStr: string): TMacroRoleFilter;
var
  t: string;
begin
  t := LowerCase(Trim(AStr));
  if t = 'run' then Result := mrfRun
  else if t = 'searchpounce' then Result := mrfSearchPounce
  else Result := mrfAny;
end;

function QsoPhaseDescription(APhase: TQsoPhase): string;
begin
  case APhase of
    qpCalling:      Result := '呼びかけ中';
    qpAnswered:     Result := '相手のコールを取得';
    qpExchangeSent: Result := 'レポート/ナンバー送出済み';
    qpExchangeRcvd: Result := 'レポート/ナンバー受領済み';
    qpConfirmed:    Result := '確認送出済み';
  else
    Result := '相手なし';
  end;
end;

function MacroValueByName(const ATagName: string; ACtx: TMacroContext;
  out AValue: string): Boolean;
{ 「値を差し込むだけ」のタグの表。展開 (<CALL> 等) と
  条件式 (HAS:CALL / EMPTY:CALL) の両方がここを見るので、
  片方にだけ項目を足して食い違う、ということが起きない。 }
var
  n: string;
begin
  Result := True;
  AValue := '';
  n := UpperCase(Trim(ATagName));

  { --- 自局 --- }
  if n = 'MYCALL' then AValue := ACtx.MyCall
  else if n = 'MYNAME' then AValue := ACtx.MyName
  else if n = 'MYQTH' then AValue := ACtx.MyQth
  else if n = 'MYLOC' then AValue := ACtx.MyLocator
  else if n = 'MYRIG' then AValue := ACtx.MyRig
  else if (n = 'MYANT') or (n = 'ANTENNA') then AValue := ACtx.MyAntenna
  else if n = 'MYPWR' then
  begin
    if ACtx.MyPowerW > 0 then
      AValue := IntToStr(ACtx.MyPowerW);
  end

  { --- 相手局 --- }
  else if n = 'CALL' then AValue := ACtx.Call
  else if n = 'NAME' then AValue := ACtx.Name
  else if n = 'QTH' then AValue := ACtx.Qth
  else if n = 'LOC' then AValue := ACtx.Locator
  else if (n = 'RST') or (n = 'RSTS') then AValue := ACtx.RstSent
  else if n = 'RSTR' then AValue := ACtx.RstRcvd

  { --- 運用状態 --- }
  else if n = 'BAND' then AValue := ACtx.Band

  { --- 日時 (すべて UTC。ログも交信も UTC で扱うため) --- }
  else if n = 'TIME' then
    AValue := FormatDateTime('hhnn', ACtx.UtcNow) + 'Z'
  else if n = 'DATE' then
    AValue := FormatDateTime('yyyymmdd', ACtx.UtcNow)
  else if n = 'ZDT' then
    AValue := FormatDateTime('yyyy-mm-dd hh:nn', ACtx.UtcNow) + 'Z'

  { --- コンテスト --- }
  else if n = 'CNTST' then AValue := ACtx.ContestName
  else if (n = '#') or (n = 'SERIAL') then
    AValue := FormatSerial(ACtx.SerialOut, ACtx.SerialDigits)
  else if (n = '#CUT') or (n = 'SERIALCUT') then
    AValue := ToCutNumbers(FormatSerial(ACtx.SerialOut, ACtx.SerialDigits))
  else if n = 'SERIALIN' then AValue := ACtx.SerialIn
  else if n = 'XOUT' then AValue := ACtx.ExchangeOut
  else if n = 'XIN' then AValue := ACtx.ExchangeIn

  else
    Result := False;
end;

{ ============================ TMacroExpansion ============================ }

function TMacroExpansion.PlainText: string;
var
  i: Integer;
  sb: string;
begin
  sb := '';
  for i := 0 to High(Segments) do
    if Segments[i].Kind = mskText then
      sb := sb + Segments[i].Text;
  Result := sb;
end;

function TMacroExpansion.SegmentCount: Integer;
begin
  Result := Length(Segments);
end;

function TMacroExpansion.ActionCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Segments) do
    if Segments[i].Kind = mskAction then
      Inc(Result);
end;

function TMacroExpansion.IssueCount(ALevel: TMacroIssueLevel): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Issues) do
    if Issues[i].Level = ALevel then
      Inc(Result);
end;

function TMacroExpansion.HasErrors: Boolean;
begin
  Result := IssueCount(milError) > 0;
end;

function TMacroExpansion.HasWarnings: Boolean;
begin
  Result := IssueCount(milWarning) > 0;
end;

function TMacroExpansion.IssueText: string;
var
  i: Integer;
  line: string;
begin
  Result := '';
  for i := 0 to High(Issues) do
  begin
    line := '[' + MacroIssueLevelToStr(Issues[i].Level) + '] ';
    if Issues[i].Tag <> '' then
      line := line + '<' + Issues[i].Tag + '>: ';
    line := line + Issues[i].Message;
    if Result <> '' then
      Result := Result + sLineBreak;
    Result := Result + line;
  end;
end;

function TMacroExpansion.ContainsAction(AKind: TMacroActionKind): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Segments) do
    if (Segments[i].Kind = mskAction) and (Segments[i].Action = AKind) then
      Exit(True);
  Result := False;
end;

function TMacroExpansion.UsesTag(const ATag: string): Boolean;
var
  i: Integer;
  key: string;
begin
  key := UpperCase(Trim(ATag));
  for i := 0 to High(UsedTags) do
    if UsedTags[i] = key then
      Exit(True);
  Result := False;
end;

{ ============================ TMacroContext ============================ }

constructor TMacroContext.Create;
begin
  inherited Create;
  FMyPowerW := 0;
  FFreqMHz := 0;
  FSerialOut := 1;
  FSerialDigits := DEFAULT_SERIAL_DIGITS;
  FFixedUtcNow := 0;
  FRole := qrRun;
  FPhase := qpIdle;
  FIsDuplicate := False;
end;

procedure TMacroContext.AdvancePhaseTo(APhase: TQsoPhase);
begin
  { 前へだけ進める。値を入れ直しても局面が戻らないようにするため
    (「レポートを打ち直したら未受領に戻った」では困る)。 }
  if APhase > FPhase then
    FPhase := APhase;
end;

procedure TMacroContext.SetCall(const AValue: string);
begin
  FCall := AValue;
  if Trim(AValue) <> '' then
    AdvancePhaseTo(qpAnswered);
end;

procedure TMacroContext.SetRstRcvd(const AValue: string);
begin
  FRstRcvd := AValue;
  if Trim(AValue) <> '' then
    AdvancePhaseTo(qpExchangeRcvd);
end;

procedure TMacroContext.SetSerialIn(const AValue: string);
begin
  FSerialIn := AValue;
  if Trim(AValue) <> '' then
    AdvancePhaseTo(qpExchangeRcvd);
end;

procedure TMacroContext.SetExchangeIn(const AValue: string);
begin
  FExchangeIn := AValue;
  if Trim(AValue) <> '' then
    AdvancePhaseTo(qpExchangeRcvd);
end;

procedure TMacroContext.LoadFromStationInfo(AStationInfo: TStationInfo);
begin
  if not Assigned(AStationInfo) then Exit;
  FMyCall := AStationInfo.MyCall;
  FMyName := AStationInfo.MyName;
  FMyQth := AStationInfo.MyQth;
  FMyLocator := AStationInfo.MyLocator;
  FMyAntenna := AStationInfo.MyAntenna;
  FMyRig := AStationInfo.MyRig;
  FMyPowerW := AStationInfo.MyPowerW;
end;

function TMacroContext.UtcNow: TDateTime;
begin
  if FFixedUtcNow <> 0 then
    Result := FFixedUtcNow
  else
    Result := LocalTimeToUniversal(Now);
end;

procedure TMacroContext.CommitSerial;
begin
  Inc(FSerialOut);
end;

procedure TMacroContext.ResetSerial(AStart: Integer);
begin
  FSerialOut := AStart;
end;

procedure TMacroContext.ClearWorkedStation;
begin
  FCall := '';
  FName := '';
  FQth := '';
  FLocator := '';
  FRstRcvd := '';
  FSerialIn := '';
  FExchangeIn := '';
  FIsDuplicate := False;
  FPhase := qpIdle;   { 局面も戻す (ここだけは後戻りが正しい) }
end;

{ ============================ TMacroDefinition ============================ }

constructor TMacroDefinition.Create(const AName, AText: string;
  ACategory: TMacroCategory; const ANote: string);
begin
  inherited Create;
  FName := AName;
  FText := AText;
  FCategory := ACategory;
  FNote := ANote;
  ClearSequence;
end;

procedure TMacroDefinition.DeclareSequence(ARole: TMacroRoleFilter;
  AValidPhases: TQsoPhaseSet; AResultPhase: TQsoPhase);
begin
  FRoleFilter := ARole;
  FValidPhases := AValidPhases;
  FResultPhase := AResultPhase;
  FHasResultPhase := True;
end;

procedure TMacroDefinition.ClearSequence;
begin
  FRoleFilter := mrfAny;
  FValidPhases := [];
  FResultPhase := qpIdle;
  FHasResultPhase := False;
end;

function TMacroDefinition.MatchesSequence(ARole: TQsoRole;
  APhase: TQsoPhase): Boolean;
begin
  Result := False;
  case FRoleFilter of
    mrfRun:          if ARole <> qrRun then Exit;
    mrfSearchPounce: if ARole <> qrSearchPounce then Exit;
  end;
  { 空集合は「どの局面でも使える」= 順序の宣言をしていない }
  if FValidPhases = [] then Exit;
  Result := APhase in FValidPhases;
end;

{ ============================ TMacroSet ============================ }

destructor TMacroSet.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TMacroSet.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Free;
  SetLength(FItems, 0);
end;

function TMacroSet.GetCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TMacroSet.CheckIndex(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EMacroError.CreateFmt(
      'マクロの添字が範囲外です (要求 %d / 登録数 %d)', [AIndex, Length(FItems)]);
end;

function TMacroSet.GetItem(AIndex: Integer): TMacroDefinition;
begin
  CheckIndex(AIndex);
  Result := FItems[AIndex];
end;

function TMacroSet.IndexOf(const AName: string): Integer;
var
  i: Integer;
  key: string;
begin
  key := UpperCase(Trim(AName));
  for i := 0 to High(FItems) do
    if UpperCase(FItems[i].Name) = key then
      Exit(i);
  Result := -1;
end;

function TMacroSet.Find(const AName: string): TMacroDefinition;
var
  idx: Integer;
begin
  idx := IndexOf(AName);
  if idx < 0 then
    Result := nil
  else
    Result := FItems[idx];
end;

function TMacroSet.FindForSequence(ARole: TQsoRole;
  APhase: TQsoPhase): TMacroDefinition;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if FItems[i].MatchesSequence(ARole, APhase) then
      Exit(FItems[i]);
  Result := nil;
end;

function TMacroSet.Add(const AName, AText: string;
  ACategory: TMacroCategory; const ANote: string): TMacroDefinition;
var
  n: Integer;
begin
  if Trim(AName) = '' then
    raise EMacroError.Create('マクロ名が空です');
  if IndexOf(AName) >= 0 then
    raise EMacroError.CreateFmt('マクロ名が重複しています: %s', [AName]);
  Result := TMacroDefinition.Create(Trim(AName), AText, ACategory, ANote);
  n := Length(FItems);
  SetLength(FItems, n + 1);
  FItems[n] := Result;
end;

function TMacroSet.AddOrReplace(const AName, AText: string;
  ACategory: TMacroCategory; const ANote: string): TMacroDefinition;
var
  idx: Integer;
begin
  idx := IndexOf(AName);
  if idx < 0 then
    Exit(Add(AName, AText, ACategory, ANote));
  Result := FItems[idx];
  Result.Text := AText;
  Result.Category := ACategory;
  Result.Note := ANote;
end;

function TMacroSet.Remove(const AName: string): Boolean;
var
  idx, i: Integer;
begin
  idx := IndexOf(AName);
  if idx < 0 then Exit(False);
  FItems[idx].Free;
  for i := idx to High(FItems) - 1 do
    FItems[i] := FItems[i + 1];
  SetLength(FItems, Length(FItems) - 1);
  Result := True;
end;

procedure TMacroSet.RegisterBuiltins;
{ 標準セットは単なる文例集ではなく「立場 × 局面」の表である。
  どの局面でも次に使うマクロが 1 つ決まるようにしてあり、
  FindForSequence がそれを返す (ESM: Enter Sends Message の土台)。

  ラバースタンプもコンテストも、交信は同じ形の状態機械で進む:

    Run  (CQ を出す側)          S&P (呼ぶ側)
    ------------------------    ------------------------
    qpIdle        CQ            qpIdle        自局コール送出
    qpCalling     (相手のコールを取得すると自動で qpAnswered)
    qpAnswered    レポート送出   qpAnswered    レポート送出
    qpExchangeSent(相手のレポート受領で自動で qpExchangeRcvd)
    qpExchangeRcvd 確認 + ログ   qpExchangeRcvd 確認 + ログ

  すべて <TX> で始めて <RX> で終える形に統一してあるのは、
  雛形の段階で「送信したまま戻らない」形を排除するため。 }
var
  d: TMacroDefinition;
begin
  { ============ ラバースタンプ (Run) ============ }
  d := AddOrReplace('CQ',
    '<TX>' + sLineBreak +
    'CQ CQ CQ de <MYCALL> <MYCALL> <MYCALL> pse k' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'CQ を出す');
  d.DeclareSequence(mrfRun, [qpIdle], qpCalling);

  d := AddOrReplace('レポート',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'GA OM ur rst <RST> <RST>' + sLineBreak +
    'QTH is <MYQTH> <MYQTH>' + sLineBreak +
    'name is <MYNAME> <MYNAME>' + sLineBreak +
    'hw? <CALL> de <MYCALL> kn' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'RST・QTH・名前を送る (ラバースタンプの本体)');
  d.DeclareSequence(mrfRun, [qpAnswered], qpExchangeSent);

  d := AddOrReplace('73',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'tnx fb qso <NAME>. hpe cuagn. 73 es gl' + sLineBreak +
    '<CALL> de <MYCALL> sk' + sLineBreak +
    '<RX><LOG>',
    mcRubberStamp, '交信を終えてログに記録する');
  d.DeclareSequence(mrfRun, [qpExchangeRcvd, qpConfirmed], qpConfirmed);

  { ============ ラバースタンプ (S&P) ============ }
  d := AddOrReplace('呼ぶ',
    '<TX><MYCALL> <MYCALL><RX>',
    mcRubberStamp, '相手の CQ に対して自局のコールだけ送る');
  d.DeclareSequence(mrfSearchPounce, [qpIdle], qpCalling);

  d := AddOrReplace('応答レポート',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'tnx fb call. ur rst <RST> <RST>' + sLineBreak +
    'QTH <MYQTH> name <MYNAME>' + sLineBreak +
    '<CALL> de <MYCALL> kn' + sLineBreak +
    '<RX>',
    mcRubberStamp, '呼んで取ってもらえた後にレポートを送る');
  d.DeclareSequence(mrfSearchPounce, [qpAnswered], qpExchangeSent);

  d := AddOrReplace('73(S&P)',
    '<TX>' + sLineBreak +
    'tnx fb qso <NAME>. 73 es gl' + sLineBreak +
    '<CALL> de <MYCALL> sk' + sLineBreak +
    '<RX><LOG>',
    mcRubberStamp, '呼んだ側として交信を終える');
  d.DeclareSequence(mrfSearchPounce, [qpExchangeRcvd, qpConfirmed], qpConfirmed);

  { ============ 順序に紐づかない補助 (どの局面でも使う) ============ }
  AddOrReplace('QRZ?',
    '<TX>QRZ? de <MYCALL> k<RX>',
    mcRubberStamp, 'コールサインが取れなかったときの聞き返し');

  AddOrReplace('リグ紹介',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'rig is <MYRIG> pwr <MYPWR>W' + sLineBreak +
    'ant is <MYANT>' + sLineBreak +
    '<CALL> de <MYCALL> kn' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'リグ・アンテナ・出力を送る (任意のタイミング)');

  { ============ コンテスト (Run) ============
    ラバースタンプと違い、余計な語を入れないのが正義である。 }
  d := AddOrReplace('CQコンテスト',
    '<TX>CQ TEST de <MYCALL> <MYCALL> TEST<RX>',
    mcContest, 'コンテストの CQ (短く速く)');
  d.DeclareSequence(mrfRun, [qpIdle], qpCalling);

  d := AddOrReplace('交換',
    '<TX><CALL> <RST><#> <RST><#><RX>',
    mcContest, 'レポートと送信ナンバーを送る');
  d.DeclareSequence(mrfRun, [qpAnswered], qpExchangeSent);

  d := AddOrReplace('TU',
    '<TX>TU <MYCALL> TEST<RX><LOG>',
    mcContest, '交信成立。送信を終えてからログに記録する');
  d.DeclareSequence(mrfRun, [qpExchangeRcvd, qpConfirmed], qpConfirmed);

  { ============ コンテスト (S&P) ============ }
  d := AddOrReplace('呼ぶ(コンテスト)',
    '<TX><MYCALL><RX>',
    mcContest, '相手の CQ に自局コールだけ送る');
  d.DeclareSequence(mrfSearchPounce, [qpIdle], qpCalling);

  d := AddOrReplace('交換(S&P)',
    '<TX><RST><#> <RST><#><RX>',
    mcContest, '取ってもらえた後にレポートとナンバーを送る');
  d.DeclareSequence(mrfSearchPounce, [qpAnswered], qpExchangeSent);

  d := AddOrReplace('TU(S&P)',
    '<TX>TU <MYCALL><RX><LOG>',
    mcContest, '呼んだ側として交信を終える');
  d.DeclareSequence(mrfSearchPounce, [qpExchangeRcvd, qpConfirmed], qpConfirmed);

  { ============ コンテストの補助 ============ }
  AddOrReplace('交換(カット)',
    '<TX><CALL> <RST><#CUT> <RST><#CUT><RX>',
    mcContest, 'CW用にカットナンバー (0=T, 9=N) で送る');

  AddOrReplace('AGN?', '<TX>AGN AGN<RX>', mcContest, '再送依頼');
  AddOrReplace('NR?', '<TX>NR? NR?<RX>', mcContest, '送信ナンバーの再送依頼');
end;

function TMacroSet.ToJsonString: string;
var
  root: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add('version', MACRO_JSON_VERSION);
    arr := TJSONArray.Create;
    root.Add('macros', arr);
    for i := 0 to High(FItems) do
    begin
      o := TJSONObject.Create;
      o.Add('name', FItems[i].Name);
      o.Add('text', FItems[i].Text);
      o.Add('note', FItems[i].Note);
      o.Add('category', MacroCategoryToStr(FItems[i].Category));
      { 順序の宣言。宣言していないマクロには書かない (旧形式と互換)。 }
      if FItems[i].ValidPhases <> [] then
      begin
        o.Add('role', MacroRoleFilterToStr(FItems[i].RoleFilter));
        o.Add('validPhases', QsoPhaseSetToStr(FItems[i].ValidPhases));
        if FItems[i].HasResultPhase then
          o.Add('resultPhase', QsoPhaseToStr(FItems[i].ResultPhase));
      end;
      arr.Add(o);
    end;
    Result := root.FormatJSON;
  finally
    root.Free;
  end;
end;

procedure TMacroSet.FromJsonString(const AJson: string);
var
  data: TJSONData;
  root: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: Integer;
  nm, tx, nt, cat: string;
  def: TMacroDefinition;
  phases: TQsoPhaseSet;
begin
  Clear;
  if Trim(AJson) = '' then Exit;
  data := GetJSON(AJson);
  try
    if not (data is TJSONObject) then
      raise EMacroError.Create('マクロ定義の最上位が JSON オブジェクトではありません');
    root := TJSONObject(data);
    if root.IndexOfName('macros') < 0 then Exit;
    if not (root.Items[root.IndexOfName('macros')] is TJSONArray) then
      raise EMacroError.Create('"macros" が配列ではありません');
    arr := TJSONArray(root.Items[root.IndexOfName('macros')]);
    for i := 0 to arr.Count - 1 do
    begin
      { 手編集で壊れた項目は、その 1 件だけ読み飛ばす。
        1 件の型違いでマクロ全体が読めなくなる方が実害が大きい。 }
      if not (arr.Items[i] is TJSONObject) then Continue;
      o := TJSONObject(arr.Items[i]);
      nm := o.Get('name', '');
      if Trim(nm) = '' then Continue;
      if IndexOf(nm) >= 0 then Continue;   // 重複は先勝ち
      tx := o.Get('text', '');
      nt := o.Get('note', '');
      cat := o.Get('category', 'general');
      def := Add(nm, tx, StrToMacroCategory(cat), nt);
      phases := StrToQsoPhaseSet(o.Get('validPhases', ''));
      if phases <> [] then
        def.DeclareSequence(StrToMacroRoleFilter(o.Get('role', 'any')),
          phases, StrToQsoPhase(o.Get('resultPhase', 'idle')));
    end;
  finally
    data.Free;
  end;
end;

procedure TMacroSet.LoadFromFile(const AFileName: string);
begin
  if not FileExists(AFileName) then
  begin
    Clear;
    Exit;
  end;
  FromJsonString(LoadTextRaw(AFileName));
end;

procedure TMacroSet.SaveToFile(const AFileName: string);
begin
  SaveTextAtomic(AFileName, ToJsonString);
end;

{ ============================ TMacroExpander ============================ }

function FindWordOp(const AText, AOp: string; out APos: Integer): Boolean;
{ 空白で囲まれた語形の演算子を探す (' GT ' 等)。 }
begin
  APos := Pos(AOp, AText);
  Result := APos > 0;
end;

function SetTrue(out ATarget: Boolean; AValue: Boolean): Boolean;
{ 「条件は読めた (True) / 値は AValue」を 1 行で返すためだけの補助。 }
begin
  ATarget := AValue;
  Result := True;
end;


constructor TMacroExpander.Create(AMacros: TMacroSet);
begin
  inherited Create;
  FMacros := AMacros;
  FMaxDepth := DEFAULT_MAX_DEPTH;
  FStrictUnknownTags := False;
end;

procedure TMacroExpander.Flush(var AResult: TMacroExpansion;
  var APending: string);
var
  n: Integer;
begin
  if APending = '' then Exit;
  n := Length(AResult.Segments);
  SetLength(AResult.Segments, n + 1);
  AResult.Segments[n].Kind := mskText;
  AResult.Segments[n].Text := APending;
  AResult.Segments[n].Action := makTransmit;   // 未使用
  AResult.Segments[n].Arg := '';
  AResult.Segments[n].ArgNum := 0;
  APending := '';
end;

procedure TMacroExpander.AddAction(var AResult: TMacroExpansion;
  var APending: string; AKind: TMacroActionKind;
  const AArg: string; AArgNum: Double);
var
  n: Integer;
begin
  { ここで確定させないと「操作の前にあった文字列」が操作の後ろに回る。 }
  Flush(AResult, APending);
  n := Length(AResult.Segments);
  SetLength(AResult.Segments, n + 1);
  AResult.Segments[n].Kind := mskAction;
  AResult.Segments[n].Text := '';
  AResult.Segments[n].Action := AKind;
  AResult.Segments[n].Arg := AArg;
  AResult.Segments[n].ArgNum := AArgNum;
end;

procedure TMacroExpander.AddIssue(var AResult: TMacroExpansion;
  ALevel: TMacroIssueLevel; const ATag, AMessage: string);
var
  n: Integer;
begin
  n := Length(AResult.Issues);
  SetLength(AResult.Issues, n + 1);
  AResult.Issues[n].Level := ALevel;
  AResult.Issues[n].Tag := ATag;
  AResult.Issues[n].Message := AMessage;
end;

procedure TMacroExpander.NoteTagUsed(var AResult: TMacroExpansion;
  const ATag: string);
var
  n: Integer;
begin
  if AResult.UsesTag(ATag) then Exit;
  n := Length(AResult.UsedTags);
  SetLength(AResult.UsedTags, n + 1);
  AResult.UsedTags[n] := UpperCase(Trim(ATag));
end;

function TMacroExpander.HandleTag(const ATagBody: string; ACtx: TMacroContext;
  var AResult: TMacroExpansion; ADepth: Integer;
  var APending: string): Boolean;
var
  tagName: string;
begin
  Result := HandleTagCore(ATagBody, ACtx, AResult, ADepth, APending, tagName);
  if Result then
    NoteTagUsed(AResult, tagName);
end;

function TMacroExpander.HandleTagCore(const ATagBody: string;
  ACtx: TMacroContext; var AResult: TMacroExpansion; ADepth: Integer;
  var APending: string; out ATagName: string): Boolean;
var
  upperTag, tagName, arg: string;
  colonPos: Integer;
  num: Double;
  sub: TMacroDefinition;
  fs: TFormatSettings;
  value: string;
begin
  Result := True;
  upperTag := UpperCase(Trim(ATagBody));

  { 引数付きタグ (<MODE:RTTY>) を名前と引数に割る。
    引数側は大小をそのまま残す (モード名やマクロ名は原文が要る)。 }
  colonPos := Pos(':', upperTag);
  if colonPos > 0 then
  begin
    tagName := Copy(upperTag, 1, colonPos - 1);
    arg := Trim(Copy(Trim(ATagBody), colonPos + 1, MaxInt));
  end
  else
  begin
    tagName := upperTag;
    arg := '';
  end;

  ATagName := tagName;

  { --- 値を差し込むだけのタグは 1 か所にまとめてある。
        条件式の HAS:/EMPTY: が同じ表を参照するので、
        ここで分岐を書き足すと条件式にも自動的に効く。 --- }
  if MacroValueByName(tagName, ACtx, value) then
    APending := APending + value

  { --- 運用状態 --- }
  else if tagName = 'MODE' then
  begin
    if arg = '' then
      APending := APending + ACtx.Mode
    else
      AddAction(AResult, APending, makSetMode, arg, 0);
  end
  else if tagName = 'FREQ' then
  begin
    if arg = '' then
    begin
      fs := DefaultFormatSettings;
      fs.DecimalSeparator := '.';   // ADIF/無線の慣習に合わせ小数点は必ず '.'
      APending := APending + FormatFloat('0.000', ACtx.FreqMHz, fs);
    end
    else
    begin
      fs := DefaultFormatSettings;
      fs.DecimalSeparator := '.';
      if not TryStrToFloat(arg, num, fs) then
      begin
        AddIssue(AResult, milError, 'FREQ',
          '周波数として読めません: ' + arg);
        Exit(True);
      end;
      AddAction(AResult, APending, makSetFreq, arg, num);
    end;
  end

  { --- コンテスト (操作系のみ。値は上の表で処理される) --- }
  else if tagName = 'INCR' then AddAction(AResult, APending, makIncSerial, '', 0)
  else if tagName = 'DECR' then AddAction(AResult, APending, makDecSerial, '', 0)

  { --- 操作 --- }
  else if tagName = 'TX' then AddAction(AResult, APending, makTransmit, '', 0)
  else if tagName = 'RX' then AddAction(AResult, APending, makReceive, '', 0)
  else if tagName = 'ABORT' then AddAction(AResult, APending, makAbortTx, '', 0)
  else if tagName = 'LOG' then AddAction(AResult, APending, makLog, '', 0)
  else if tagName = 'CLRRX' then AddAction(AResult, APending, makClearRx, '', 0)
  else if tagName = 'CLRTX' then AddAction(AResult, APending, makClearTx, '', 0)
  else if tagName = 'WAIT' then
  begin
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    if not TryStrToFloat(arg, num, fs) then
    begin
      AddIssue(AResult, milError, 'WAIT', '秒数として読めません: ' + arg);
      Exit(True);
    end;
    if (num < 0) or (num > 600) then
    begin
      AddIssue(AResult, milError, 'WAIT',
        '待ち時間が範囲外です (0～600秒): ' + arg);
      Exit(True);
    end;
    AddAction(AResult, APending, makWait, arg, num);
  end

  { --- 入れ子マクロ --- }
  else if tagName = 'MACRO' then
  begin
    if FMacros = nil then
    begin
      AddIssue(AResult, milError, 'MACRO',
        'マクロ集が設定されていないため <MACRO:' + arg + '> を展開できません');
      Exit(True);
    end;
    if ADepth >= FMaxDepth then
    begin
      AddIssue(AResult, milError, 'MACRO',
        'マクロの入れ子が深すぎます (上限 ' + IntToStr(FMaxDepth) +
        ')。循環参照になっていないか確認してください: ' + arg);
      Exit(True);
    end;
    sub := FMacros.Find(arg);
    if sub = nil then
    begin
      AddIssue(AResult, milError, 'MACRO',
        '参照先のマクロが見つかりません: ' + arg);
      Exit(True);
    end;
    ExpandInto(sub.Text, ACtx, AResult, ADepth + 1, APending);
  end

  else
    Result := False;   // 未知のタグ
end;

function TMacroExpander.EvalCondition(const ACond: string;
  ACtx: TMacroContext; var AResult: TMacroExpansion;
  out AValue: Boolean): Boolean;
{ 条件は「列挙できる形」に限定してある。任意の式を書けるようにすると
  静的に検査できなくなり、送信前バリデーションが意味を失うため。

    DUPE / NOTDUPE          既に交信済みか
    CONTEST / NOTCONTEST    コンテスト運用か (ContestName が入っているか)
    ROLE=RUN | ROLE=SP      立場
    PHASE=<局面> / PHASE>=<局面>
    MODE=CW / MODE NE CW    モード (大小を区別しない)
    BAND=20m / BAND NE 20m
    HAS:<タグ名>            値タグが空でない
    EMPTY:<タグ名>          値タグが空
    SERIAL=n / SERIAL GT n / SERIAL LT n / SERIAL NE n

  比較演算子に > < <> を使わないのは、タグの終端 '>' と衝突するためである。
  <IF:SERIAL>100> と書くと最初の '>' でタグが閉じてしまう。
  そこで GT / LT / GE / NE という語形にしてある
  (= だけは衝突しないのでそのまま使える)。 }
var
  c, lhs, rhs, op: string;
  p, n: Integer;
  v: string;

  function Cmp(const AL, AR: string): Boolean;
  begin
    Result := UpperCase(Trim(AL)) = UpperCase(Trim(AR));
  end;

begin
  Result := True;
  AValue := False;
  c := UpperCase(Trim(ACond));
  if c = '' then
  begin
    AddIssue(AResult, milError, 'IF', '条件が空です');
    Exit(False);
  end;

  { --- 引数を取らない条件 --- }
  if c = 'DUPE' then Exit(SetTrue(AValue, ACtx.IsDuplicate));
  if c = 'NOTDUPE' then Exit(SetTrue(AValue, not ACtx.IsDuplicate));
  if c = 'CONTEST' then Exit(SetTrue(AValue, Trim(ACtx.ContestName) <> ''));
  if c = 'NOTCONTEST' then Exit(SetTrue(AValue, Trim(ACtx.ContestName) = ''));

  { --- HAS: / EMPTY: --- }
  if Copy(c, 1, 4) = 'HAS:' then
  begin
    if not MacroValueByName(Copy(c, 5, MaxInt), ACtx, v) then
    begin
      AddIssue(AResult, milError, 'IF',
        'HAS: に指定されたタグが不明です: ' + Copy(c, 5, MaxInt));
      Exit(False);
    end;
    Exit(SetTrue(AValue, Trim(v) <> ''));
  end;
  if Copy(c, 1, 6) = 'EMPTY:' then
  begin
    if not MacroValueByName(Copy(c, 7, MaxInt), ACtx, v) then
    begin
      AddIssue(AResult, milError, 'IF',
        'EMPTY: に指定されたタグが不明です: ' + Copy(c, 7, MaxInt));
      Exit(False);
    end;
    Exit(SetTrue(AValue, Trim(v) = ''));
  end;

  { --- 比較演算 ---
    語形の演算子を先に探す (空白で区切られていることを要求するので、
    値の中にたまたま GT 等が含まれていても誤検出しない)。 }
  op := '';
  p := 0;
  if FindWordOp(c, ' GE ', p) then op := 'GE'
  else if FindWordOp(c, ' GT ', p) then op := 'GT'
  else if FindWordOp(c, ' LT ', p) then op := 'LT'
  else if FindWordOp(c, ' NE ', p) then op := 'NE'
  else if FindWordOp(c, ' EQ ', p) then op := 'EQ'
  else
  begin
    p := Pos('=', c);
    if p > 0 then op := '=';
  end;

  if op = '' then
  begin
    AddIssue(AResult, milError, 'IF', '条件の書き方が分かりません: ' + ACond);
    Exit(False);
  end;

  if op = '=' then
  begin
    lhs := Trim(Copy(c, 1, p - 1));
    rhs := Trim(Copy(c, p + 1, MaxInt));
  end
  else
  begin
    lhs := Trim(Copy(c, 1, p - 1));
    rhs := Trim(Copy(c, p + 4, MaxInt));   { ' XX ' の 4 文字分 }
    if op = 'EQ' then op := '=';
  end;

  if lhs = 'ROLE' then
  begin
    if (rhs = 'RUN') then Exit(SetTrue(AValue, ACtx.Role = qrRun));
    if (rhs = 'SP') or (rhs = 'SEARCHPOUNCE') then
      Exit(SetTrue(AValue, ACtx.Role = qrSearchPounce));
    AddIssue(AResult, milError, 'IF', '立場の指定が不明です: ' + rhs);
    Exit(False);
  end;

  if lhs = 'PHASE' then
  begin
    if op = '=' then Exit(SetTrue(AValue, ACtx.Phase = StrToQsoPhase(rhs)));
    if op = 'GE' then Exit(SetTrue(AValue, ACtx.Phase >= StrToQsoPhase(rhs)));
    AddIssue(AResult, milError, 'IF',
      '局面の比較は = と GE のみ使えます');
    Exit(False);
  end;

  if lhs = 'SERIAL' then
  begin
    if not TryStrToInt(rhs, n) then
    begin
      AddIssue(AResult, milError, 'IF', '数値として読めません: ' + rhs);
      Exit(False);
    end;
    if op = '=' then Exit(SetTrue(AValue, ACtx.SerialOut = n));
    if op = 'GT' then Exit(SetTrue(AValue, ACtx.SerialOut > n));
    if op = 'GE' then Exit(SetTrue(AValue, ACtx.SerialOut >= n));
    if op = 'LT' then Exit(SetTrue(AValue, ACtx.SerialOut < n));
    if op = 'NE' then Exit(SetTrue(AValue, ACtx.SerialOut <> n));
    AddIssue(AResult, milError, 'IF', '送信ナンバーの比較演算が不正です');
    Exit(False);
  end;

  { それ以外は値タグとの文字列比較 (MODE / BAND / CALL など) }
  if MacroValueByName(lhs, ACtx, v) then
  begin
    if op = '=' then Exit(SetTrue(AValue, Cmp(v, rhs)));
    if op = 'NE' then Exit(SetTrue(AValue, not Cmp(v, rhs)));
    AddIssue(AResult, milError, 'IF',
      '文字列の比較に使えるのは = と NE だけです: ' + ACond);
    Exit(False);
  end;

  { MODE は値表にあるが、引数つき操作タグでもあるので個別に見る }
  if lhs = 'MODE' then
  begin
    if op = '=' then Exit(SetTrue(AValue, Cmp(ACtx.Mode, rhs)));
    if op = 'NE' then Exit(SetTrue(AValue, not Cmp(ACtx.Mode, rhs)));
  end;

  AddIssue(AResult, milError, 'IF', '条件の左辺が不明です: ' + lhs);
  Result := False;
end;

function TMacroExpander.FindBlockEnd(const AText: string; AStartPos: Integer;
  AIsIf: Boolean; var AResult: TMacroExpansion;
  out AElsePos, AEndPos, AAfterPos: Integer): Boolean;
{ 開きタグの直後 (AStartPos) から、同じ入れ子段の閉じタグを探す。
  入れ子の種類を積んで確認するので、<IF><REPEAT><ENDIF><ENDREPEAT> の
  ような交差した書き方も検出できる (黙って通すと展開結果が
  書いた人の意図と食い違う)。 }
var
  i, gt: Integer;
  body, nm: string;
  stack: array of Boolean;   // True = IF, False = REPEAT
  top: Integer;
begin
  Result := False;
  AElsePos := 0;
  AEndPos := 0;
  AAfterPos := 0;
  SetLength(stack, 0);
  top := 0;
  i := AStartPos;

  while i <= Length(AText) do
  begin
    if AText[i] <> '<' then
    begin
      Inc(i);
      Continue;
    end;
    gt := PosEx('>', AText, i + 1);
    if gt = 0 then Break;
    body := Copy(AText, i + 1, gt - i - 1);
    nm := UpperCase(Trim(body));
    if Pos(':', nm) > 0 then
      nm := Copy(nm, 1, Pos(':', nm) - 1);

    if (nm = 'IF') or (nm = 'REPEAT') then
    begin
      SetLength(stack, top + 1);
      stack[top] := nm = 'IF';
      Inc(top);
    end
    else if nm = 'ELSE' then
    begin
      if (top = 0) and AIsIf and (AElsePos = 0) then
        AElsePos := i;
    end
    else if (nm = 'ENDIF') or (nm = 'ENDREPEAT') then
    begin
      if top = 0 then
      begin
        if AIsIf <> (nm = 'ENDIF') then
        begin
          AddIssue(AResult, milError, nm,
            'ブロックの開きと閉じが対応していません');
          Exit(False);
        end;
        AEndPos := i;
        AAfterPos := gt + 1;
        Exit(True);
      end;
      Dec(top);
      if stack[top] <> (nm = 'ENDIF') then
      begin
        AddIssue(AResult, milError, nm,
          'ブロックが交差しています (<IF> と <REPEAT> の入れ子を確認してください)');
        Exit(False);
      end;
      SetLength(stack, top);
    end;
    i := gt + 1;
  end;

  if AIsIf then
    AddIssue(AResult, milError, 'IF', '対応する <ENDIF> がありません')
  else
    AddIssue(AResult, milError, 'REPEAT', '対応する <ENDREPEAT> がありません');
end;

procedure TMacroExpander.ExpandInto(const AText: string; ACtx: TMacroContext;
  var AResult: TMacroExpansion; ADepth: Integer; var APending: string);
var
  i, gtPos: Integer;
  body, tagName, tagArg, branch: string;
  elsePos, endPos, afterPos, elseGt, repeatCount, rep: Integer;
  condValue: Boolean;
begin
  i := 1;
  while i <= Length(AText) do
  begin
    if AText[i] <> '<' then
    begin
      APending := APending + AText[i];
      Inc(i);
      Continue;
    end;

    gtPos := PosEx('>', AText, i + 1);
    if gtPos = 0 then
    begin
      { 閉じ '>' が無い。タグではなく本文の '<' として扱う
        (「<」を含む普通の文章を消してしまわないため)。 }
      APending := APending + Copy(AText, i, MaxInt);
      Break;
    end;

    body := Copy(AText, i + 1, gtPos - i - 1);
    tagName := UpperCase(Trim(body));
    if Pos(':', tagName) > 0 then
    begin
      tagArg := Trim(Copy(Trim(body), Pos(':', tagName) + 1, MaxInt));
      tagName := Copy(tagName, 1, Pos(':', tagName) - 1);
    end
    else
      tagArg := '';

    { --- 条件分岐 (展開時に解決する) --- }
    if tagName = 'IF' then
    begin
      if not FindBlockEnd(AText, gtPos + 1, True, AResult,
                          elsePos, endPos, afterPos) then Exit;
      if not EvalCondition(tagArg, ACtx, AResult, condValue) then
      begin
        { 条件が読めない場合は「何も出さない」。誤った文面を送るより
          送らない方が安全であり、Issue で理由が残る。 }
        i := afterPos;
        Continue;
      end;
      if elsePos > 0 then
      begin
        if condValue then
          branch := Copy(AText, gtPos + 1, elsePos - gtPos - 1)
        else
        begin
          elseGt := PosEx('>', AText, elsePos + 1);
          if elseGt = 0 then elseGt := elsePos;
          branch := Copy(AText, elseGt + 1, endPos - elseGt - 1);
        end;
      end
      else if condValue then
        branch := Copy(AText, gtPos + 1, endPos - gtPos - 1)
      else
        branch := '';
      if branch <> '' then
        ExpandInto(branch, ACtx, AResult, ADepth, APending);
      i := afterPos;
      Continue;
    end;

    { --- 反復 (展開時に展開しきる) --- }
    if tagName = 'REPEAT' then
    begin
      if not FindBlockEnd(AText, gtPos + 1, False, AResult,
                          elsePos, endPos, afterPos) then Exit;
      if not TryStrToInt(tagArg, repeatCount) then
      begin
        AddIssue(AResult, milError, 'REPEAT',
          '繰り返し回数として読めません: ' + tagArg);
        i := afterPos;
        Continue;
      end;
      if (repeatCount < 0) or (repeatCount > MAX_REPEAT_COUNT) then
      begin
        AddIssue(AResult, milError, 'REPEAT',
          '繰り返し回数が範囲外です (0～' + IntToStr(MAX_REPEAT_COUNT) +
          '): ' + tagArg);
        i := afterPos;
        Continue;
      end;
      branch := Copy(AText, gtPos + 1, endPos - gtPos - 1);
      for rep := 1 to repeatCount do
        ExpandInto(branch, ACtx, AResult, ADepth, APending);
      i := afterPos;
      Continue;
    end;

    { ブロックの外に現れた閉じタグ }
    if (tagName = 'ELSE') or (tagName = 'ENDIF') or (tagName = 'ENDREPEAT') then
    begin
      AddIssue(AResult, milError, tagName,
        '対応する開きタグがありません');
      i := gtPos + 1;
      Continue;
    end;

    { 文字列側は溜めておき、操作が入る直前で切り出す。
      こうすると「文字列 → 操作 → 文字列」の順序が保たれる。 }
    if not HandleTag(body, ACtx, AResult, ADepth, APending) then
    begin
      { 未知のタグ。原文のまま残し、指摘だけ出す。
        勝手に消すと「送ったつもりの文が抜けている」ことに気づけない。 }
      APending := APending + '<' + body + '>';
      if FStrictUnknownTags then
        AddIssue(AResult, milError, body, '未知のタグです')
      else
        AddIssue(AResult, milWarning, body,
          '未知のタグです。そのままの文字列として送信されます');
    end;
    i := gtPos + 1;
  end;
end;

function TMacroExpander.Expand(const AText: string;
  ACtx: TMacroContext): TMacroExpansion;
var
  pending: string;
  i, n: Integer;
  merged: TMacroSegmentArray;
begin
  if ACtx = nil then
    raise EMacroError.Create('展開コンテキストが nil です');
  Result.Segments := nil;
  Result.Issues := nil;
  Result.UsedTags := nil;
  pending := '';

  ExpandInto(AText, ACtx, Result, 0, pending);

  { 末尾に残った文字列を確定 }
  Flush(Result, pending);

  { 連続する文字列断片をまとめる (実行側が扱いやすいように) }
  SetLength(merged, 0);
  for i := 0 to High(Result.Segments) do
  begin
    n := Length(merged);
    if (Result.Segments[i].Kind = mskText) and (n > 0) and
       (merged[n - 1].Kind = mskText) then
      merged[n - 1].Text := merged[n - 1].Text + Result.Segments[i].Text
    else
    begin
      SetLength(merged, n + 1);
      merged[n] := Result.Segments[i];
    end;
  end;
  Result.Segments := merged;
end;

function TMacroExpander.ExpandNamed(const AName: string;
  ACtx: TMacroContext): TMacroExpansion;
var
  def: TMacroDefinition;
begin
  if FMacros = nil then
    raise EMacroError.Create('マクロ集が設定されていません');
  def := FMacros.Find(AName);
  if def = nil then
    raise EMacroError.CreateFmt('マクロが見つかりません: %s', [AName]);
  Result := Expand(def.Text, ACtx);
end;

function TMacroExpander.Validate(const AExpansion: TMacroExpansion;
  ACtx: TMacroContext; ADefinition: TMacroDefinition): TMacroExpansion;
{ 「今この状況で送っていいか」を見る。Expand が見るのは書き方の問題
  (未知タグ・引数の不正) で、こちらが見るのは運用上の問題である。

  実際に困るのは次の 4 つ:
    1. 送信したまま受信に戻らない → 電波を出しっぱなしにする
    2. 送信開始より前に本文がある → その文は電波に乗らない
    3. 差し込む値が空 → "de  de " のような文を送ってしまう
    4. ログ操作があるのに交信内容が埋まっていない → 空レコードが残る

  3 の判定には「そのタグを実際に使ったか」が要る。展開後の文字列を見ても
  「<CALL> が空だった」のか「もともと書いていない」のかは区別できず、
  CQ マクロに対して「相手のコールが空です」と言ってしまう。
  そこで展開時に記録した UsedTags を使う。 }
var
  i: Integer;
  txSeen, rxAfterTx, textBeforeTx, textAfterRx, hasLog, hasText: Boolean;

  procedure Note(ALevel: TMacroIssueLevel; const ATag, AMsg: string);
  begin
    AddIssue(Result, ALevel, ATag, AMsg);
  end;

  { 差し込みタグを使っているのに値が空、という指摘。 }
  procedure RequireValue(const ATag, AValue, ALabel: string;
    ALevel: TMacroIssueLevel);
  begin
    if AExpansion.UsesTag(ATag) and (Trim(AValue) = '') then
      Note(ALevel, ATag, ALabel + 'が空のまま送信しようとしています');
  end;

begin
  Result := AExpansion;   // 指摘を足して返す (展開時の指摘は残す)
  if ACtx = nil then
    raise EMacroError.Create('検査コンテキストが nil です');

  txSeen := False;
  rxAfterTx := False;
  textBeforeTx := False;
  textAfterRx := False;
  hasLog := False;
  hasText := False;

  for i := 0 to High(Result.Segments) do
    if Result.Segments[i].Kind = mskText then
    begin
      if Trim(Result.Segments[i].Text) <> '' then
      begin
        hasText := True;
        if not txSeen then
          textBeforeTx := True;
        if rxAfterTx then
          textAfterRx := True;
      end;
    end
    else
      case Result.Segments[i].Action of
        makTransmit:
          begin
            txSeen := True;
            rxAfterTx := False;   { 二度目の <TX> 以降を改めて見る }
          end;
        makReceive:
          if txSeen then rxAfterTx := True;
        makLog:
          hasLog := True;
      else
        ;
      end;

  { --- 1. 送信したまま戻らない (コンテスト中に最も痛い事故) --- }
  if txSeen and (not rxAfterTx) then
    Note(milError, 'TX',
      '送信を開始したあと受信に戻る <RX> がありません。' +
      'このまま実行すると電波を出し続けます');

  { --- 2. 送信開始前/受信復帰後の本文は今回の送信に乗らない --- }
  if textBeforeTx and txSeen then
    Note(milWarning, 'TX',
      '<TX> より前に本文があります。この部分は送信されません');
  if textAfterRx then
    Note(milWarning, 'RX',
      '<RX> より後ろに本文があります。この部分は今回は送信されず、' +
      '次に送信したときに出ます');

  if hasText and (not txSeen) then
    Note(milInfo, '',
      '<TX> がありません。本文は送信ウィンドウに入るだけで送信はされません');

  { --- 3. 差し込む値が空のまま --- }
  { 自局コールは、使っていれば必ず必要。 }
  RequireValue('MYCALL', ACtx.MyCall, '自局のコールサイン', milError);
  { 相手コールは、使っているのに空なら交信が成立しない。 }
  RequireValue('CALL', ACtx.Call, '相手局のコールサイン', milError);
  { 以下は空でも交信は成立するので警告どまり。 }
  RequireValue('RST', ACtx.RstSent, '送信 RST', milWarning);
  RequireValue('RSTS', ACtx.RstSent, '送信 RST', milWarning);
  RequireValue('RSTR', ACtx.RstRcvd, '受信 RST', milWarning);
  RequireValue('NAME', ACtx.Name, '相手局の名前', milWarning);
  RequireValue('QTH', ACtx.Qth, '相手局の QTH', milWarning);
  RequireValue('LOC', ACtx.Locator, '相手局のグリッドロケータ', milWarning);
  RequireValue('MYNAME', ACtx.MyName, '自局の名前', milWarning);
  RequireValue('MYQTH', ACtx.MyQth, '自局の QTH', milWarning);
  RequireValue('MYRIG', ACtx.MyRig, '自局のリグ', milWarning);
  RequireValue('MYANT', ACtx.MyAntenna, '自局のアンテナ', milWarning);
  RequireValue('ANTENNA', ACtx.MyAntenna, '自局のアンテナ', milWarning);
  RequireValue('SERIALIN', ACtx.SerialIn, '受信ナンバー', milWarning);
  RequireValue('XOUT', ACtx.ExchangeOut, '送信コンテストナンバー', milWarning);
  RequireValue('XIN', ACtx.ExchangeIn, '受信コンテストナンバー', milWarning);
  RequireValue('CNTST', ACtx.ContestName, 'コンテスト名', milInfo);
  RequireValue('BAND', ACtx.Band, 'バンド', milWarning);
  RequireValue('MODE', ACtx.Mode, 'モード', milWarning);

  if AExpansion.UsesTag('MYPWR') and (ACtx.MyPowerW <= 0) then
    Note(milWarning, 'MYPWR', '送信出力が未設定のまま送信しようとしています');
  if AExpansion.UsesTag('FREQ') and (ACtx.FreqMHz <= 0) then
    Note(milWarning, 'FREQ', '周波数が未設定のまま送信しようとしています');

  { 送信ナンバーは 1 以上でなければコンテストログとして通らない。 }
  if (AExpansion.UsesTag('#') or AExpansion.UsesTag('SERIAL') or
      AExpansion.UsesTag('#CUT') or AExpansion.UsesTag('SERIALCUT')) and
     (ACtx.SerialOut < 1) then
    Note(milError, '#',
      '送信ナンバーが ' + IntToStr(ACtx.SerialOut) +
      ' です。1 以上である必要があります');

  { --- 4. ログ操作があるのに記録内容が埋まっていない --- }
  if hasLog then
  begin
    { 局面での判定。交換を受け取る前にログするのは、
      「相手のレポート/ナンバーが空のレコード」を作る操作であり、
      コンテストでは提出ログが不備になる。 }
    if ACtx.Phase < qpExchangeRcvd then
      Note(milError, 'LOG',
        '交換を受け取る前にログしようとしています (現在: ' +
        QsoPhaseDescription(ACtx.Phase) + ')');

    if Trim(ACtx.Call) = '' then
      Note(milError, 'LOG',
        '相手局のコールサインが空のままログしようとしています');
    if Trim(ACtx.Mode) = '' then
      Note(milWarning, 'LOG', 'モードが未設定のままログしようとしています');
    if ACtx.FreqMHz <= 0 then
      Note(milWarning, 'LOG', '周波数が未設定のままログしようとしています');
    if Trim(ACtx.RstSent) = '' then
      Note(milWarning, 'LOG', '送信 RST が空のままログしようとしています');
    if Trim(ACtx.RstRcvd) = '' then
      Note(milWarning, 'LOG', '受信 RST が空のままログしようとしています');

    { デュープはコンテストによっては「得点0で記録する」のが正しいので、
      止めずに知らせるだけにする。 }
    if ACtx.IsDuplicate then
      Note(milWarning, 'LOG',
        'この局とは既に交信済みです (デュープ)');
  end;

  { --- 5. 立場・局面に合わないマクロ --- }
  if ADefinition <> nil then
  begin
    if (ADefinition.ValidPhases <> []) and
       (not ADefinition.MatchesSequence(ACtx.Role, ACtx.Phase)) then
      Note(milWarning, '',
        'マクロ "' + ADefinition.Name + '" は現在の局面 (' +
        QsoPhaseDescription(ACtx.Phase) +
        ') 向けではありません。押し間違いでないか確認してください');
  end;
end;

function TMacroExpander.Prepare(const AText: string;
  ACtx: TMacroContext): TMacroExpansion;
begin
  Result := Validate(Expand(AText, ACtx), ACtx);
end;

function TMacroExpander.PrepareNamed(const AName: string;
  ACtx: TMacroContext): TMacroExpansion;
var
  def: TMacroDefinition;
begin
  def := nil;
  if FMacros <> nil then
    def := FMacros.Find(AName);
  Result := Validate(ExpandNamed(AName, ACtx), ACtx, def);
end;

{ ============================ TMacroRunner ============================ }

constructor TMacroRunner.Create(AHost: TMacroHost; AExpander: TMacroExpander);
begin
  inherited Create;
  FExpander := AExpander;
  FAllowWithWarnings := True;
  FBusyPolicy := mbpReject;
  FClearAfterLog := True;
  FStepTimeoutSec := 120;
  FState := mrsIdle;
  FIndex := 0;
  FOwnerThreadId := 0;
  SetHost(AHost);
end;

procedure TMacroRunner.SetHost(AValue: TMacroHost);
begin
  if FHost = AValue then Exit;
  if Assigned(FHost) and (FHost.Runner = Self) then
    FHost.Runner := nil;
  FHost := AValue;
  if Assigned(FHost) then
    FHost.Runner := Self;
end;

procedure TMacroRunner.CheckThread;
{ 宿主が別スレッドから折り返すと、断片の進行が競合して
  「送信中に次のマクロが割り込む」ような壊れ方をする。
  黙って壊れるより、開発時に見える失敗にする。 }
begin
  if FOwnerThreadId = TThreadID(0) then Exit;
  if GetCurrentThreadId <> FOwnerThreadId then
    raise EMacroError.Create(
      'TMacroRunner はマクロを開始したスレッドからのみ操作できます。' +
      '宿主が別スレッドで送信完了を検出した場合は、' +
      'TThread.Queue 等で UI スレッドへ渡してから通知してください');
end;

function TMacroRunner.GetBusy: Boolean;
begin
  CheckStepTimeout;
  Result := FState in [mrsWaitingTxEnd, mrsWaitingTimer];
end;

procedure TMacroRunner.CheckStepTimeout;
var
  elapsedSec: Double;
begin
  if not (FState in [mrsWaitingTxEnd, mrsWaitingTimer]) then Exit;
  if FStepTimeoutSec <= 0 then Exit;
  elapsedSec := (Now - FStepStartedAt) * SecsPerDay;
  if elapsedSec > FStepTimeoutSec then
  begin
    { 宿主が折り返しを忘れた/失敗した。永久に Busy のままにすると
      以後どのマクロも打てなくなるので、中断して解放する。 }
    if Assigned(FHost) then
      try
        FHost.AbortTransmit;
      except
        on E: Exception do ;
      end;
    FinishRun(mrsAborted);
  end;
end;

procedure TMacroRunner.ApplyResultPhase;
begin
  if (FDefinition = nil) or (not FDefinition.HasResultPhase) or (FCtx = nil) then
    Exit;
  { ログして相手局を消した直後は局面が qpIdle に戻っている。ここで
    マクロの宣言 (TU なら qpConfirmed) をそのまま適用すると、
    せっかく戻した局面が前へ跳ね返り、次の CQ が「確認送出済み」から
    始まってしまう。ログできた交信は完了しているので、宣言は適用しない。 }
  if FLogged and FClearAfterLog then Exit;
  FCtx.AdvancePhaseTo(FDefinition.ResultPhase);
end;

procedure TMacroRunner.FinishRun(AState: TMacroRunState);
var
  completed: Boolean;
begin
  FState := AState;
  FOwnerThreadId := 0;
  SetLength(FSegments, 0);
  FIndex := 0;
  completed := AState = mrsDone;
  if completed then
    ApplyResultPhase;
  FDefinition := nil;
  if Assigned(FOnDone) then
    FOnDone(Self, completed);
end;

procedure TMacroRunner.Step;
{ 断片を順に処理し、待ちに入ったら抜ける。
  待ちから復帰したときも同じ関数が続きから再開する。 }
var
  seg: TMacroSegment;
begin
  while FIndex <= High(FSegments) do
  begin
    seg := FSegments[FIndex];
    Inc(FIndex);

    if seg.Kind = mskText then
    begin
      FHost.SendText(seg.Text);
      Continue;
    end;

    case seg.Action of
      makTransmit:  FHost.StartTransmit;
      makClearRx:   FHost.ClearRxWindow;
      makClearTx:   FHost.ClearTxWindow;
      makSetMode:   FHost.SetMode(seg.Arg);
      makSetFreq:   FHost.SetFreqMHz(seg.ArgNum);

      makAbortTx:
        begin
          FHost.AbortTransmit;
          FinishRun(mrsAborted);
          Exit;
        end;

      makReceive:
        begin
          { ここが同期実装との決定的な違い。送信バッファを送り切るまで
            戻らないので、この後ろの断片 (<LOG> 等) は本当に
            送信し終わってから実行される。 }
          FState := mrsWaitingTxEnd;
          FStepStartedAt := Now;
          FHost.RequestReceive;
          Exit;
        end;

      makWait:
        begin
          FState := mrsWaitingTimer;
          FStepStartedAt := Now;
          FHost.StartTimer(seg.ArgNum);
          Exit;
        end;

      makLog:
        begin
          { 送信ナンバーが進むのはここだけ。ログが成功しなければ
            進めない ― 番号を飛ばすとコンテストのログ照合で減点される。 }
          if FHost.LogCurrentQso then
          begin
            FLogged := True;
            FCtx.CommitSerial;
            FSerialAdvanced := True;
            { ログできたら相手局は「済んだ相手」になる。ここで消さないと
              次の交信で前の局のコールを送ってしまう。 }
            if FClearAfterLog then
              FCtx.ClearWorkedStation;
          end;
        end;

      makIncSerial:
        begin
          FCtx.SerialOut := FCtx.SerialOut + 1;
          FSerialAdvanced := True;
        end;

      makDecSerial:
        if FCtx.SerialOut > 1 then
          FCtx.SerialOut := FCtx.SerialOut - 1;
    end;
  end;

  FinishRun(mrsDone);
end;

function TMacroRunner.Execute(const AText: string; ACtx: TMacroContext;
  AForce: Boolean): TMacroRunResult;
begin
  Result := ExecuteInternal(AText, ACtx, nil, AForce);
end;

function TMacroRunner.ExecuteInternal(const AText: string;
  ACtx: TMacroContext; ADefinition: TMacroDefinition;
  AForce: Boolean): TMacroRunResult;
var
  ex: TMacroExpansion;
begin
  Result.Started := False;
  Result.Logged := False;
  Result.SerialAdvanced := False;
  Result.Completed := False;
  Result.RefusalReason := '';

  if FHost = nil then
    raise EMacroError.Create('マクロ実行の宿主 (TMacroHost) が設定されていません');
  if ACtx = nil then
    raise EMacroError.Create('実行コンテキストが nil です');
  if FExpander = nil then
    raise EMacroError.Create('マクロ展開器 (TMacroExpander) が設定されていません');

  if Busy then
  begin
    case FBusyPolicy of
      mbpReject:
        begin
          Result.RefusalReason :=
            '別のマクロを実行中です (' +
            IfThen(FState = mrsWaitingTxEnd, '送信終了待ち', '待機中') + ')';
          Exit;
        end;
      mbpReplace:
        Abort;
    end;
  end;

  { 展開と検査をここで行う。呼び出し側が古い展開結果を持ち込めないので、
    「検査した状態」と「送る状態」が必ず一致する。 }
  ex := FExpander.Validate(FExpander.Expand(AText, ACtx), ACtx, ADefinition);

  if not AForce then
  begin
    if ex.HasErrors then
    begin
      Result.RefusalReason := ex.IssueText;
      Exit;
    end;
    if (not FAllowWithWarnings) and ex.HasWarnings then
    begin
      Result.RefusalReason := ex.IssueText;
      Exit;
    end;
  end;

  FDefinition := ADefinition;
  FSegments := ex.Segments;
  FIndex := 0;
  FCtx := ACtx;
  FLogged := False;
  FSerialAdvanced := False;
  FState := mrsIdle;
  FOwnerThreadId := GetCurrentThreadId;

  Result.Started := True;
  Step;

  Result.Logged := FLogged;
  Result.SerialAdvanced := FSerialAdvanced;
  Result.Completed := FState = mrsDone;
end;

function TMacroRunner.ExecuteNamed(const AName: string; ACtx: TMacroContext;
  AForce: Boolean): TMacroRunResult;
var
  def: TMacroDefinition;
begin
  if FExpander = nil then
    raise EMacroError.Create('マクロ展開器 (TMacroExpander) が設定されていません');
  if FExpander.Macros = nil then
    raise EMacroError.Create('マクロ集が設定されていません');
  def := FExpander.Macros.Find(AName);
  if def = nil then
    raise EMacroError.CreateFmt('マクロが見つかりません: %s', [AName]);
  { 順序の宣言 (使うべき局面・実行後の局面) を検査と遷移に使う。 }
  Result := ExecuteInternal(def.Text, ACtx, def, AForce);
end;

function TMacroRunner.ExecuteForSequence(ACtx: TMacroContext;
  AForce: Boolean): TMacroRunResult;
var
  def: TMacroDefinition;
begin
  Result.Started := False;
  Result.Logged := False;
  Result.SerialAdvanced := False;
  Result.Completed := False;
  Result.RefusalReason := '';

  if ACtx = nil then
    raise EMacroError.Create('実行コンテキストが nil です');
  if (FExpander = nil) or (FExpander.Macros = nil) then
    raise EMacroError.Create('マクロ集が設定されていません');

  def := FExpander.Macros.FindForSequence(ACtx.Role, ACtx.Phase);
  if def = nil then
  begin
    Result.RefusalReason :=
      '現在の局面 (' + QsoPhaseDescription(ACtx.Phase) +
      ') に対応するマクロが登録されていません';
    Exit;
  end;
  Result := ExecuteInternal(def.Text, ACtx, def, AForce);
end;

procedure TMacroRunner.NotifyTxFinished;
begin
  CheckThread;
  if FState <> mrsWaitingTxEnd then Exit;   // 想定外の通知は無視する
  FState := mrsIdle;
  Step;
end;

procedure TMacroRunner.NotifyTimerElapsed;
begin
  CheckThread;
  if FState <> mrsWaitingTimer then Exit;
  FState := mrsIdle;
  Step;
end;

procedure TMacroRunner.Abort;
begin
  if not (FState in [mrsWaitingTxEnd, mrsWaitingTimer]) then Exit;
  if Assigned(FHost) then
    try
      FHost.AbortTransmit;
    except
      on E: Exception do ;
    end;
  FinishRun(mrsAborted);
end;

initialization
  { 日本語のマクロ名・注記を JSON へ往復させるため。
    Unix では DefaultSystemCodePage が 0 のことがあり、これを
    設定しないと UTF-8 文字列が '?' に落ちる (9-2 と同じ不具合)。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
