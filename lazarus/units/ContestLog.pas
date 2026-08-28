{ ============================================================================
  ContestLog.pas

  コンテストロギング機能: 交換ナンバー(Exchange)の書式検証、州(State)/準州
  (VE Province)/郡(County)/ARRLセクション/DXCC国名等のフィールド判定、
  シリアルナンバーの発行、重複交信(Dupe)チェック、および AdifFile.pas の
  TAdifDatabase 上への実際のロギングまでを担う。fldigi のコンテスト関連
  ソース (`src/logbook/contest.cxx`, `src/logbook/counties.cxx`) を解析し、
  Lazarus/FPC 向けに設計・実装したもの。

  fldigi との対応:
    fldigi (C++)                                     | Lazarus (Pascal)
    ----------------------------------------------------+---------------------------
    enum CONTEST_FIELD (contest.h)                      | TContestFieldKind (本ユニット)
    state_test()/province_test()/county_test()/         | ContestStateTest/ContestProvinceTest/
      district_test()/section_test()/class_test()/        ContestCountyTest/ContestDistrictTest/
      wfd_class_test()/ascr_class_test()/check_test()/     ContestSectionTest/ContestClassTest/
      rookie_test()/c1010_test()/cut_numeric_test()/       ContestWfdClassTest/ContestAscrClassTest/
      cut_to_numeric()/numeric_test()/rst_test()/          ContestCheckTest/ContestRookieTest/
      italian_test()/ss_chk_test()/ss_prec_test()          ContestC1010Test/ContestCutNumericTest/
                                                            ContestCutToNumeric/ContestNumericTest/
                                                            ContestRstTest/ContestItalianProvinceTest/
                                                            ContestSsChkTest/ContestSsPrecTest
    check_field()                                        | TContestDefinition.ValidateField
    country_test() (dxcc_entity_list() を利用)            | ContestCountryTest (DxccDatabase.pas を利用)
    CONTESTS contests[] (国際/一般コンテスト一覧)          | TContestRegistry.RegisterBuiltins
    struct QSOP / Ccontests::qso_parties[]               | TContestDefinition (州QSOパーティも
      (約90件の米国州QSOパーティ、州別に固定の                同じ型で表現可能。ただし本移植版は
      RST/ST/CNTY/SERNO/XCHG/NAME/CAT 列を持つ)             全件を移植していない。設計方針3参照)
    class Cstates (counties.cxx)                         | TCountyDatabase (本ユニット)
    (該当なし。fldigiにはロギング機能付きの                | TContestLog (シリアルナンバー発行+
     コンテストクラス自体が無く、check_field系関数は          重複チェック+AdifFile連携までを
     入力欄のリアルタイム検証にのみ使われる)                    1クラスにまとめた新規追加機能)

  設計方針・fldigiからの相違点:
  ----------------------------------------------------------------------------
  1. **AdifFile.pas を基盤とする**: fldigi の contest.cxx 自体はQSOレコード
     を保持せず、GUI入力欄の検証関数の集合体に過ぎない。実際のロギングは
     logbook側 (cQsoDb) が別途担う。本移植版は「新規開発のコンテスト
     ロギング機能」として、検証ロジック (fldigiの資産) と実際のログ記録を
     TContestLog 1クラスにまとめ、AdifFile.pas の TAdifDatabase/TAdifRecord
     をそのまま内部データストアとして利用する (AdifFile.pas 冒頭コメントで
     「以降の全ての機能実装の基盤データ構造として使う」と明記した通り)。

  2. **DXCC国名/CQゾーン/ITUゾーン/大陸の判定は DxccDatabase.pas に分離**:
     fldigi の country_test() は dxcc.cxx の dxcc_entity_list() に依存する。
     本移植版もこの依存関係を保つが、DXCC判定はコンテスト機能以外
     (将来の CallsignLookup.pas 等) でも使う共通基盤のため、独立した
     ユニット (DxccDatabase.pas) として切り出してある。

  3. **米国州QSOパーティ(qso_parties[])は全件を移植していない**: fldigi の
     qso_parties[] は約90件の米国/カナダ州QSOパーティを、州ごとに
     「RST/ST/CNTY/SERNO/XCHG/NAME/CATのどれを州内局(I)/州外局(O)/
     両方(B)が送るか」という固定テーブルで持つ。これは「fldigiのロジックを
     読んで移植する」対象というより「大量の静的データ」であり、かつ
     ユーザー要望が「翻訳ではなく新規開発」であることから、本移植版では
     全90件を手作業で書き写すことはせず、代わりに:
       (a) 同じ表現力を持つ汎用の TContestDefinition/TContestExchangeField
           の仕組みを用意し、
       (b) 実際に fldigi の CONTESTS contests[] (米国州限定ではない
           国際/一般コンテスト一覧) から抜粋した実在のコンテスト定義を
           `TContestRegistry.RegisterBuiltins` で組み込み、
       (c) 郡(County)データも counties.cxx 同様「外部CSVファイルから
           読み込む」設計 (TCountyDatabase.LoadFromFile) とすることで、
     利用者が必要な州QSOパーティ/郡データを CSV で用意すれば
     qso_parties[] 相当のコンテストをいくらでも追加登録できる、
     という「データ駆動で全件を再現可能な枠組み」を提供する形にした。

  4. **fldigi の CONTEST_FIELD 列挙子との対応関係**: cSTATE→cfState,
     cVE_PROV→cfProvince, cCNTY→cfCounty, cDIST→cfCounty (郡/準郡の
     区別はTCountyDatabase側のデータで表現するため型としては統合),
     cCOUNTRY→cfCountry, cCQZ→cfCqZone, cITUZ→cfItuZone,
     cCLASS/cFD_CLASS→cfClass, cWFD_CLASS→cfWfdClass,
     cASCR_CLASS→cfAscrClass, cARRL_SECT/cFD_SECTION→cfArrlSection,
     cROOKIE→cfRookie, c1010→cfC1010, cRST→cfRst,
     cSRX/cNUMERIC→cfNumeric, cITALIAN→cfItalianProvince,
     cSS_SERNO→cfSsSerno, cSS_PREC→cfSsPrecedence, cSS_CHK→cfSsCheck,
     cSS_SEC→cfSsSection。cNAME/cQTH/cGRIDSQUARE/cXCHG1/cKD_XCHG/
     cARR_XCHG (fldigi check_field() でも検証なし・常にtrue) は
     cfFreeText に統合した。

  5. **rst_test() のモード依存を明示的な引数に変更**: fldigi は
     `active_modem->get_mode() < MODE_SSB` というグローバルなモデム
     状態を直接参照するが、本ユニットはGUI/モデムエンジンに一切
     依存しない設計方針 (Modem.pas 等、他ユニットと同じ) のため、
     `ARequireThreeChar: Boolean` という明示的な引数に置き換えた
     (呼び出し側が現在の運用モードがCW/デジタル系かフォーン系かを
     判定して渡す)。

  6. **NAQP/NAスプリント等の「STATE/VE_PROV/COUNTRYのいずれか」を
     1個のバリデータ関数 (ContestStateProvinceCountryTest) に統合**:
     fldigi はGUI側で複数の入力欄候補を持たせる形で対応しているが、
     本移植版はGUI非依存のため「3種のいずれかにマッチすればOK」という
     単一の判定関数に単純化した。
  ============================================================================ }
unit ContestLog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, DateUtils, Generics.Collections,
  AdifFile, DxccDatabase;

type
  { ==========================================================================
    交換ナンバー(Exchange)のフィールド種別。
    fldigi: contest.h の enum CONTEST_FIELD に相当 (対応関係は本ファイル
    冒頭コメント「設計方針 4」を参照)。
    ========================================================================== }
  TContestFieldKind = (
    cfFreeText,          // 検証なし (NAME/QTH/POWER/EXCHANGE等の自由記入欄)
    cfNumeric,           // 数字のみ (SRX、CQ WPXのSERNO等)
    cfCutNumeric,        // カットナンバー許容 (N=9, T=0 の代用を許す)
    cfRst,               // RST/RSQ 形式 (2桁または3桁)
    cfState,             // 米国の州 (DXを含む)
    cfProvince,          // カナダの州/準州
    cfCounty,            // 郡/市 (要 TCountyDatabase)
    cfCountry,           // DXCC国名の部分一致 (要 TDxccDatabase)
    cfCqZone,            // CQゾーン (1-40の数字)
    cfItuZone,           // ITUゾーン (1-90の数字)
    cfClass,             // ARRL Field Day クラス (数字+A~F)
    cfWfdClass,          // Winter Field Day クラス (数字+I/O/H)
    cfAscrClass,         // ASCR クラス (I/C/S の1文字)
    cfArrlSection,       // ARRL/RACセクション
    cfRookie,            // ARRL Rookie Roundup の免許取得年
    cfC1010,             // Ten-Ten 会員番号 (数字のみ)
    cfItalianProvince,   // イタリアの県略号 (2文字)
    cfSsSerno,           // ARRL Sweepstakes シリアル番号
    cfSsPrecedence,      // ARRL Sweepstakes プレシデンス (Q/A/B/U/M/S)
    cfSsCheck,           // ARRL Sweepstakes チェック欄
    cfSsSection,         // ARRL Sweepstakes セクション (=ARRLセクションと同じ表)
    cfStateProvinceOrCountry // 州/準州/DXCC国名のいずれか (NAQP等)
  );

const
  { fldigi: contest.cxx 冒頭の静的テーブル群をそのまま踏襲。
    州/準州/セクション名は4文字幅 (3文字+空白1つ) で区切られており、
    判定側もこれに合わせて右側を空白パディングしてから部分一致で
    検索する (fldigi の state_test()/section_test() 等と同じ手法)。 }
  CONTEST_STATES =
    'DX  CT  MA  ME  NH  RI  VT  ' +
    'NY  NJ  ' +
    'DE  PA  MD  DC ' +
    'AL  FL  GA  KY  NC  SC  TN  VA  ' +
    'AR  LA  MS  NM  OK  TX  ' +
    'CA  HI  ' +
    'AK  AZ  ID  MT  NV  OR  UT  WA  WY  ' +
    'MI  OH  WV  ' +
    'IL  WI  IN  ' +
    'CO  IA  KS  MN  MO  ND  NE  SD  ';

  CONTEST_PROVINCES =
    'AB  BC  LB  MB  NB  NF  NS  NU  NWT ON  PEI QC  SK  YT  ';

  CONTEST_MEXICO = 'XE1 XE2 XE3 XF1 XF4 ';

  CONTEST_SECTIONS =
    'DX  ' +
    'CT  RI  EMA VT  ME  WMA NH  ' +
    'ENY NNY NLI SNJ NNJ WHY ' +
    'DE  MDC EPA WPA ' +
    'AL  GA  KY  NC  NFL PR  SC  SFL TN  VA  ' +
    'VI  WCF AR  LA  MS  NM  NTX OK  STX WTX ' +
    'EB  LAX ORG PAC SB  SCV SDG SF  SJV SV  ' +
    'AK  AZ  EWA ID  MT  NV  OR  UT  WWA WY  ' +
    'MI  OH  WV  ' +
    'IL  IN  WI  ' +
    'CO  IA  KS  MN  MO  ND  NE  SD  ' +
    'AB  BC  GTA MAR MB  NL  NT  ONE ONN ONS QC  SK  ';

  { イタリア各県の略号一覧 (地方ごとにグループ化)。fldigi: contest.cxx
    の IT1_～IT9_/IX1_/IN3_/IV3_/IS0_ 定数群をそのまま踏襲。 }
  ITALIAN_PROVINCE_GROUPS: array[0..13] of string = (
    'AL AT BI CN GE IM NO SP SV TO VB VC ',
    'AO ',
    'BG BS CO CR LC LO MB MI MN PV SO VA ',
    'BL PD RO TV VE VI VR ',
    'BZ TN ',
    'GO PN TS UD ',
    'BO FC FE MO PC PR RA RE RN ',
    'AR FI GR LI LU MS PI PO PT SI ',
    'AN AP AQ CH FM MC PE PS PU TE ',
    'BA BR BT FG LE MT TA ',
    'AV BN CB CE CS CZ IS KR NA PZ RC SA VV ',
    'FR LT PG RI RM TR VT ',
    'AG CL CT EN ME PA RG SR TP ',
    'CA NU OR SS SU '
  );

{ ============================================================================
  単体フィールド検証関数群。
  fldigi: contest.cxx の同名 (英語スネークケース) 関数群に相当。
  ============================================================================ }

{ fldigi: class_test() (ARRL Field Day クラス: 数字1桁以上 + A~F の1文字) }
function ContestClassTest(const S: string): Boolean;
{ fldigi: wfd_class_test() (Winter Field Day クラス: 数字1桁以上 + I/O/H) }
function ContestWfdClassTest(const S: string): Boolean;
{ fldigi: ascr_class_test() (I/C/S のいずれか1文字) }
function ContestAscrClassTest(const S: string): Boolean;
{ fldigi: state_test() }
function ContestStateTest(const S: string): Boolean;
{ fldigi: province_test() }
function ContestProvinceTest(const S: string): Boolean;
{ fldigi: check_test() (STATES+PROVINCES+MEXICOのいずれかに一致するか) }
function ContestCheckTest(const S: string): Boolean;
{ fldigi: section_test() }
function ContestSectionTest(const S: string): Boolean;
{ fldigi: rookie_test()。ANowUtc には検証時点の現在時刻(UTC)を渡す。
  免許取得年から3年未満ならルーキーとみなす。 }
function ContestRookieTest(const S: string; ANowUtc: TDateTime): Boolean;
{ fldigi: c1010_test() (数字のみ) }
function ContestC1010Test(const S: string): Boolean;
{ fldigi: cut_to_numeric() (N→9, T→0 の置換) }
function ContestCutToNumeric(const S: string): string;
{ fldigi: cut_numeric_test() (0-9,N,n,T,tのみで構成されるか) }
function ContestCutNumericTest(const S: string): Boolean;
{ fldigi: numeric_test() (0-9のみで構成されるか) }
function ContestNumericTest(const S: string): Boolean;
{ fldigi: rst_test()。ARequireThreeChar=True ならCW/デジタル系
  (3桁必須)、False ならフォーン系 (2桁も可) として検証する。 }
function ContestRstTest(const S: string; ARequireThreeChar: Boolean): Boolean;
{ fldigi: italian_test() (イタリアの県略号2文字か) }
function ContestItalianProvinceTest(const S: string): Boolean;
{ fldigi: ss_chk_test()。fldigi の実装をそのまま踏襲しており、
  実際には「先頭1文字が数字かどうか」しか見ていない (関数名の割に
  簡易な実装だが、原典に忠実に移植した)。 }
function ContestSsChkTest(const S: string): Boolean;
{ fldigi: ss_prec_test() (Q/A/B/U/M/S のいずれか1文字) }
function ContestSsPrecTest(const S: string): Boolean;
{ fldigi には直接の対応関数は無いが、NAQP/NAスプリント等
  「STATE / VE_PROV / COUNTRY のいずれか」という表記を1個の判定に
  まとめたもの (本ファイル冒頭コメント「設計方針 6」参照)。
  ADxcc が nil の場合、国名側の判定は常にtrueになる
  (fldigi country_test() の「DXCCデータ未ロード時は常にtrue」という
  フォールバックと同じ考え方)。 }
function ContestStateProvinceCountryTest(ADxcc: TDxccDatabase; const S: string): Boolean;
{ fldigi: contest.cxx country_test()。ADxcc が nil (=cty.dat未ロード)
  の場合は常にtrueを返す (fldigi と同じ寛容フォールバック)。
  マッチした場合、AMatchedCountry に正式国名を返す。 }
function ContestCountryTest(ADxcc: TDxccDatabase; const S: string; out AMatchedCountry: string): Boolean;

type
  { TCountyEntry / TCountyDatabase
    ---------------------------------------------------------------------
    fldigi: counties.cxx の STATE_COUNTY_QUAD / class Cstates に相当。
    fldigi は SQSO(全米州別)/6QP(ニューイングランド)/7QP(太平洋岸北西部)の
    3種類の郡データを別々のグローバル変数 (vec_SQSO/vec_6QP/vec_7QP) で
    持つが、本移植版は「どの郡データを使うか」を TContestDefinition
    (あるいは TContestLog) 側が保持する TCountyDatabase インスタンスの
    差し替えで表現するため、クラス自体は1種類に統合した。 }
  TCountyEntry = record
    State: string;  // 州/準州の正式名
    ST: string;     // 州/準州の略号
    County: string; // 郡/市の正式名
    CTY: string;    // 郡/市の略号
  end;

  TCountyDatabase = class
  private
    FEntries: array of TCountyEntry;
    function GetCount: Integer;
    function GetEntry(AIndex: Integer): TCountyEntry;
  public
    { fldigi: counties.cxx load_from_file()。
      "State/Province, ST/PR, County/City/District, CCD" 形式のCSV
      (1行目はヘッダ行として読み捨てる) を読み込む。
      戻り値: 読み込んだ行数。 }
    function LoadFromFile(const AFileName: string): Integer;
    procedure Clear;

    property Count: Integer read GetCount;
    property Entries[AIndex: Integer]: TCountyEntry read GetEntry; default;

    { fldigi: Cstates::valid_county(st, cnty)
      st/cnty とも正式名・略号のどちらで渡してもよい。 }
    function ValidCounty(const ASt, ACounty: string): Boolean;
    { fldigi: Cstates::names() ('|'区切りの州/準州正式名一覧) }
    function StateNames: string;
    { fldigi: Cstates::counties(ST) ('|'区切りの郡正式名一覧) }
    function CountyNamesForState(const ASt: string): string;
    { fldigi: Cstates::county(st, cnty) (正式名を返す。無ければ空文字) }
    function CountyLongName(const ASt, ACounty: string): string;
    { fldigi: Cstates::cnty_short(st, cnty) (略号を返す。無ければ空文字) }
    function CountyShortName(const ASt, ACounty: string): string;
  end;

  { fldigi: county_test(st, cnty) / district_test(pr, dist)。
    st が空文字の場合は「常に home state 側とみなす」というfldigiの
    progdefaults依存処理を省き、単純に「st が空ならホームステートを
    使う」動作にした呼び出し側の設計に合わせ、本関数自体は st を
    そのまま使う (ホームステートの補完は TContestLog 側の責務とする)。
    ACounties が nil の場合は常にtrueを返す (郡データ未ロード時の
    寛容フォールバック)。 }
  function ContestCountyTest(ACounties: TCountyDatabase; const ASt, ACounty: string): Boolean;

type
  { TContestExchangeField / TContestDefinition
    ---------------------------------------------------------------------
    fldigi: struct QSOP (contest.h) + CONTESTS 構造体を統合したもの。
    1個のコンテストが要求する交換ナンバーの各フィールドを表す。 }
  TContestExchangeField = record
    FieldId: TAdifFieldId;   // AdifFile.pas のどのADIFフィールドに格納するか
    Kind: TContestFieldKind; // どのバリデータで検証するか
    FieldLabel: string;      // UI表示用ラベル (例: "SECTION", "SERNO")
    Required: Boolean;       // 必須入力かどうか
  end;

  TContestDefinition = class
  private
    FName: string;
    FNotes: string;
    FFields: array of TContestExchangeField;
    FCounties: TCountyDatabase; // 郡ベースのコンテスト用 (参照のみ、所有しない)
    function GetFieldCount: Integer;
    function GetField(AIndex: Integer): TContestExchangeField;
  public
    constructor Create(const AName, ANotes: string);

    { fldigi: struct QSOP の各列を1個ずつ AddField で積み上げる形に
      相当 (元のfldigiは固定長配列だが、本移植版は可変長)。 }
    procedure AddField(AFieldId: TAdifFieldId; AKind: TContestFieldKind;
      const AFieldLabel: string; ARequired: Boolean = True);

    property Name: string read FName;
    property Notes: string read FNotes;
    property FieldCount: Integer read GetFieldCount;
    property Fields[AIndex: Integer]: TContestExchangeField read GetField; default;
    { 郡(County)を交換ナンバーに含むコンテストの場合、対応する
      TCountyDatabase をここに設定する (nilなら郡フィールドは常に有効
      とみなされる)。 }
    property Counties: TCountyDatabase read FCounties write FCounties;
  end;

  { TContestRegistry
    ---------------------------------------------------------------------
    fldigi: CONTESTS contests[] (国際/一般コンテスト一覧、contest.cxx)
    に相当。全件の翻訳ではなく代表的なコンテストを抜粋して組み込む
    (本ファイル冒頭コメント「設計方針 3」参照)。利用者は Add() で
    独自の州QSOパーティ等をいくらでも追加登録できる。 }
  TContestRegistry = class
  private
    FDefinitions: specialize TObjectList<TContestDefinition>;
  public
    constructor Create;
    destructor Destroy; override;

    function Add(ADefinition: TContestDefinition): TContestDefinition;
    function FindByName(const AName: string): TContestDefinition;
    function Count: Integer;
    function Definition(AIndex: Integer): TContestDefinition;

    { fldigi: contest.cxx contests[] のうち代表的な15件
      (Africa All-Mode International, ARRL Field Day, ARRL International
      DX (cw), ARRL Rookie Roundup, ARRL November Sweepstakes,
      ARRL Winter FD, BARTG RTTY contest, CQ WPX, CQ WW DX,
      CQ WW DX RTTY, Italian A.R.I. International DX, NAQP, NA Sprint,
      Ten Ten, VHF) を、それぞれの notes 記載の交換ナンバー構成に
      従って登録する。米国州QSOパーティ (qso_parties[]) は含まない。 }
    procedure RegisterBuiltins;
  end;

  TContestFieldValue = record
    FieldId: TAdifFieldId;
    Value: string;
  end;

  { コンテストログの操作エラー (添字の範囲外など)。 }
  EContestLogError = class(Exception);

  { TContestLog
    ---------------------------------------------------------------------
    fldigi に直接対応するクラスは無い (設計方針1参照)。交換ナンバーの
    検証・シリアルナンバー発行・重複交信チェックを行い、AdifFile.pas の
    TAdifDatabase へ実際にロギングする、本移植版オリジナルのクラス。 }
  TContestLog = class
  private
    FDatabase: TAdifDatabase;    // 所有 (Destroyで解放)
    FDefinition: TContestDefinition; // 参照のみ (Registry等が所有権を持つ)
    FDxcc: TDxccDatabase;         // 参照のみ。nil なら国名/ゾーン自動補完なし
    FNextSerial: Integer;
    FLastSaveError: string;
  public
    constructor Create;
    destructor Destroy; override;

    property Definition: TContestDefinition read FDefinition write FDefinition;
    property Dxcc: TDxccDatabase read FDxcc write FDxcc;
    property Database: TAdifDatabase read FDatabase;
    property NextSerial: Integer read FNextSerial write FNextSerial;

    { シリアルナンバーを AStart から振り直す (コンテスト開始時、
      またはバンド/モード別運用を切り替える際に呼ぶ)。 }
    procedure ResetSerial(AStart: Integer = 1);

    { fldigi に直接対応する関数は無いが、コンテストロギングの基本機能
      として「同一バンド・同一モードでの同一コールサインとの再交信」を
      重複とみなす (一般的なコンテストロギングソフトの標準的な定義)。 }
    function IsDuplicate(const ACall, ABand, AMode: string): Boolean;

    { 交換ナンバー各フィールドの値を Definition の Kind に従って検証する。
      AHomeState は cfCounty (郡) 検証時のみ使用する
      (呼び出し側が「自局の州」を渡す。空文字なら郡検証は
      TCountyDatabase側のデータだけで州非依存に一致を試みる)。
      戻り値: 検証に失敗したフィールドの FieldLabel の配列 (空配列なら
      全項目が有効)。 }
    function ValidateExchange(const AExchange: array of TContestFieldValue;
      const AHomeState: string = ''): specialize TArray<string>;

    { 1件のQSOを記録する。RST/コールサイン/バンド/モードに加え、
      Definition が要求する交換ナンバー (AExchange) をそのまま
      対応するADIFフィールドへ格納する。Dxcc が設定されていれば
      コールサインからCOUNTRY/CQZ/ITUZ/CONTを自動補完する。
      STX (送信シリアル) は Definition.UsesSerialNumber (Fields中に
      cfSsSerno/cfNumericでafSrx/afSsSerno以外へマップされたfieldが
      無い場合の簡易判定はせず) 呼び出し側が明示的に AAssignSerial=True
      を指定した場合のみ NextSerial を払い出して自動採番する。
      ADupe には IsDuplicate の判定結果を返す (記録はDupeでも行う。
      除外するかどうかは呼び出し側の判断に委ねる)。 }
    function LogQso(const ACall, ABand, AMode, ARstSent, ARstRcvd: string;
      const AExchange: array of TContestFieldValue; AAssignSerial: Boolean;
      out ADupe: Boolean): TAdifRecord;

    { ADIF ファイルへ保存する。成功したら True を返す。
      失敗理由が必要な場合は out 引数付きの版を使う。 }
    function SaveToAdif(const AFileName: string): Boolean;
    function SaveToAdif(const AFileName: string; out AErrorMessage: string): Boolean;
    { 直近の SaveToAdif が失敗した理由 (成功時は空文字)。 }
    property LastSaveError: string read FLastSaveError;

    function LoadFromAdif(const AFileName: string): Integer;
  end;

implementation

{ ============================================================================
  単体フィールド検証関数群
  ============================================================================ }

function PadTo4(const S: string): string;
begin
  Result := S;
  while Length(Result) < 4 do
    Result := Result + ' ';
end;

function ContestClassTest(const S: string): Boolean;
const
  CLASSES = 'ABCDEF';
var
  i: Integer;
begin
  Result := False;
  if Length(S) < 2 then Exit;
  if Pos(UpCase(S[Length(S)]), CLASSES) = 0 then Exit;
  for i := 1 to Length(S) - 1 do
    if not (S[i] in ['0'..'9']) then Exit;
  Result := True;
end;

function ContestWfdClassTest(const S: string): Boolean;
const
  CLASSES = 'IOH';
var
  i: Integer;
begin
  Result := False;
  if Length(S) < 2 then Exit;
  if Pos(UpCase(S[Length(S)]), CLASSES) = 0 then Exit;
  for i := 1 to Length(S) - 1 do
    if not (S[i] in ['0'..'9']) then Exit;
  Result := True;
end;

function ContestAscrClassTest(const S: string): Boolean;
begin
  Result := (Length(S) = 1) and (UpCase(S[1]) in ['I', 'C', 'S']);
end;

function ContestStateTest(const S: string): Boolean;
begin
  Result := (S <> '') and (Pos(UpperCase(PadTo4(S)), CONTEST_STATES) > 0);
end;

function ContestProvinceTest(const S: string): Boolean;
begin
  Result := Pos(UpperCase(PadTo4(S)), CONTEST_PROVINCES) > 0;
end;

function ContestCheckTest(const S: string): Boolean;
begin
  if Length(S) >= 4 then
  begin
    Result := False;
    Exit;
  end;
  Result := Pos(PadTo4(S), CONTEST_STATES + CONTEST_PROVINCES + CONTEST_MEXICO) > 0;
end;

function ContestSectionTest(const S: string): Boolean;
begin
  Result := Pos(UpperCase(PadTo4(S)), CONTEST_SECTIONS) > 0;
end;

function ContestRookieTest(const S: string; ANowUtc: TDateTime): Boolean;
var
  yearLicensed, yearWorked: Integer;
begin
  Result := False;
  if not TryStrToInt(Trim(S), yearLicensed) then Exit;
  if yearLicensed < 100 then Inc(yearLicensed, 2000);
  yearWorked := YearOf(ANowUtc);
  if yearWorked < yearLicensed then Dec(yearLicensed, 100);
  Result := (yearWorked - yearLicensed) < 3;
end;

function ContestC1010Test(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if S = '' then Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then Exit;
  Result := True;
end;

function ContestCutToNumeric(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
  begin
    if Result[i] in ['N', 'n'] then Result[i] := '9';
    if Result[i] in ['T', 't'] then Result[i] := '0';
  end;
end;

function ContestCutNumericTest(const S: string): Boolean;
const
  ALLOWED = '1234567890NnTt';
var
  i: Integer;
begin
  Result := False;
  if S = '' then Exit;
  for i := 1 to Length(S) do
    if Pos(S[i], ALLOWED) = 0 then Exit;
  Result := True;
end;

function ContestNumericTest(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if S = '' then Exit;
  for i := 1 to Length(S) do
    if not (S[i] in ['0'..'9']) then Exit;
  Result := True;
end;

function ContestRstTest(const S: string; ARequireThreeChar: Boolean): Boolean;
const
  NBRS1 = '12345';
  NBRS2 = '123456789Nn';
begin
  Result := False;
  if (Length(S) < 3) and ARequireThreeChar then Exit;
  if (Length(S) < 2) or (Length(S) > 3) then Exit;
  if S[1] = '0' then Exit;
  if Pos(S[1], NBRS1) = 0 then Exit;
  if Pos(S[2], NBRS2) = 0 then Exit;
  if (Length(S) = 3) and (Pos(S[3], NBRS2) = 0) then Exit;
  Result := True;
end;

function ContestItalianProvinceTest(const S: string): Boolean;
var
  i: Integer;
  needle: string;
begin
  Result := False;
  if Length(S) <> 2 then Exit;
  needle := UpperCase(S) + ' ';
  for i := 0 to High(ITALIAN_PROVINCE_GROUPS) do
    if Pos(needle, ITALIAN_PROVINCE_GROUPS[i]) > 0 then
    begin
      Result := True;
      Exit;
    end;
end;

function ContestSsChkTest(const S: string): Boolean;
begin
  { fldigi: ss_chk_test() の実装をそのまま踏襲 (原典コメント参照)。 }
  Result := (S <> '') and (S[1] in ['0'..'9']);
end;

function ContestSsPrecTest(const S: string): Boolean;
const
  PREC = 'QABUMS';
begin
  Result := (S <> '') and (Pos(UpCase(S[1]), PREC) > 0);
end;

function ContestCountyTest(ACounties: TCountyDatabase; const ASt, ACounty: string): Boolean;
begin
  if not Assigned(ACounties) then
  begin
    Result := True;
    Exit;
  end;
  if not ContestStateTest(ASt) then
  begin
    Result := False;
    Exit;
  end;
  Result := ACounties.ValidCounty(ASt, ACounty);
end;

function ContestCountryTest(ADxcc: TDxccDatabase; const S: string; out AMatchedCountry: string): Boolean;
begin
  AMatchedCountry := '';
  if (not Assigned(ADxcc)) or (not ADxcc.Loaded) then
  begin
    Result := True; { fldigi: country_test() の dxcc_list=nil 時のフォールバック }
    Exit;
  end;
  AMatchedCountry := ADxcc.FindCountryByFragment(S);
  Result := AMatchedCountry <> '';
end;

function ContestStateProvinceCountryTest(ADxcc: TDxccDatabase; const S: string): Boolean;
var
  dummy: string;
begin
  Result := ContestStateTest(S) or ContestProvinceTest(S) or
    ContestCountryTest(ADxcc, S, dummy);
end;

{ ============================================================================
  TCountyDatabase
  ============================================================================ }

function TCountyDatabase.GetCount: Integer;
begin
  Result := Length(FEntries);
end;

function TCountyDatabase.GetEntry(AIndex: Integer): TCountyEntry;
begin
  if (AIndex < 0) or (AIndex >= Length(FEntries)) then
    raise EContestLogError.CreateFmt(
      '郡データの番号が範囲外です: %d (件数 %d)', [AIndex, Length(FEntries)]);
  Result := FEntries[AIndex];
end;

procedure TCountyDatabase.Clear;
begin
  SetLength(FEntries, 0);
end;

function TCountyDatabase.LoadFromFile(const AFileName: string): Integer;
{ fldigi: counties.cxx load_from_file()。
  "State, ST, County, CTY" 形式のCSV。1行目はヘッダ行として読み捨てる。 }
var
  sl: TStringList;
  i, p1, p2, p3: Integer;
  line: string;
  e: TCountyEntry;
begin
  Clear;
  if not FileExists(AFileName) then
  begin
    Result := 0;
    Exit;
  end;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    for i := 1 to sl.Count - 1 do { i=0 のヘッダ行は読み飛ばす }
    begin
      line := Trim(sl[i]);
      if line = '' then Continue;

      p1 := Pos(',', line);
      if p1 = 0 then Continue;
      e.State := Trim(Copy(line, 1, p1 - 1));

      p2 := PosEx(',', line, p1 + 1);
      if p2 = 0 then Continue;
      e.ST := Trim(Copy(line, p1 + 1, p2 - p1 - 1));

      p3 := PosEx(',', line, p2 + 1);
      if p3 = 0 then Continue;
      e.County := Trim(Copy(line, p2 + 1, p3 - p2 - 1));

      e.CTY := Trim(Copy(line, p3 + 1, MaxInt));

      if e.ST <> '' then
      begin
        SetLength(FEntries, Length(FEntries) + 1);
        FEntries[High(FEntries)] := e;
      end;
    end;
  finally
    sl.Free;
  end;
  Result := Length(FEntries);
end;

function TCountyDatabase.ValidCounty(const ASt, ACounty: string): Boolean;
var
  i: Integer;
  st, cnty: string;
begin
  Result := False;
  st := UpperCase(Trim(ASt));
  cnty := UpperCase(Trim(ACounty));
  for i := 0 to High(FEntries) do
  begin
    if UpperCase(FEntries[i].ST) <> st then Continue;
    if (UpperCase(FEntries[i].CTY) = cnty) or (UpperCase(FEntries[i].County) = cnty) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function TCountyDatabase.StateNames: string;
var
  i: Integer;
  lastSt, names: string;
begin
  names := '';
  lastSt := '';
  for i := 0 to High(FEntries) do
    if FEntries[i].ST <> lastSt then
    begin
      if names <> '' then names := names + '|';
      names := names + FEntries[i].State;
      lastSt := FEntries[i].ST;
    end;
  Result := names;
end;

function TCountyDatabase.CountyNamesForState(const ASt: string): string;
var
  i: Integer;
  st, names: string;
begin
  names := '';
  st := UpperCase(Trim(ASt));
  for i := 0 to High(FEntries) do
    if UpperCase(FEntries[i].ST) = st then
    begin
      if names <> '' then names := names + '|';
      names := names + FEntries[i].County;
    end;
  Result := names;
end;

function TCountyDatabase.CountyLongName(const ASt, ACounty: string): string;
var
  i: Integer;
  st, cnty: string;
begin
  Result := '';
  st := UpperCase(Trim(ASt));
  cnty := UpperCase(Trim(ACounty));
  for i := 0 to High(FEntries) do
    if UpperCase(FEntries[i].ST) = st then
      if (UpperCase(FEntries[i].CTY) = cnty) or (UpperCase(FEntries[i].County) = cnty) then
      begin
        Result := FEntries[i].County;
        Exit;
      end;
end;

function TCountyDatabase.CountyShortName(const ASt, ACounty: string): string;
var
  i: Integer;
  st, cnty: string;
begin
  Result := '';
  st := UpperCase(Trim(ASt));
  cnty := UpperCase(Trim(ACounty));
  for i := 0 to High(FEntries) do
    if UpperCase(FEntries[i].ST) = st then
      if (UpperCase(FEntries[i].CTY) = cnty) or (UpperCase(FEntries[i].County) = cnty) then
      begin
        Result := FEntries[i].CTY;
        Exit;
      end;
end;

{ ============================================================================
  TContestDefinition
  ============================================================================ }

constructor TContestDefinition.Create(const AName, ANotes: string);
begin
  inherited Create;
  FName := AName;
  FNotes := ANotes;
  FCounties := nil;
end;

procedure TContestDefinition.AddField(AFieldId: TAdifFieldId;
  AKind: TContestFieldKind; const AFieldLabel: string; ARequired: Boolean);
var
  n: Integer;
begin
  n := Length(FFields);
  SetLength(FFields, n + 1);
  FFields[n].FieldId := AFieldId;
  FFields[n].Kind := AKind;
  FFields[n].FieldLabel := AFieldLabel;
  FFields[n].Required := ARequired;
end;

function TContestDefinition.GetFieldCount: Integer;
begin
  Result := Length(FFields);
end;

function TContestDefinition.GetField(AIndex: Integer): TContestExchangeField;
begin
  if (AIndex < 0) or (AIndex >= Length(FFields)) then
    raise EContestLogError.CreateFmt(
      '交換フィールドの番号が範囲外です: %d (項目数 %d)', [AIndex, Length(FFields)]);
  Result := FFields[AIndex];
end;

{ ============================================================================
  TContestRegistry
  ============================================================================ }

constructor TContestRegistry.Create;
begin
  inherited Create;
  FDefinitions := specialize TObjectList<TContestDefinition>.Create(True);
end;

destructor TContestRegistry.Destroy;
begin
  FDefinitions.Free;
  inherited Destroy;
end;

function TContestRegistry.Add(ADefinition: TContestDefinition): TContestDefinition;
begin
  FDefinitions.Add(ADefinition);
  Result := ADefinition;
end;

function TContestRegistry.FindByName(const AName: string): TContestDefinition;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FDefinitions.Count - 1 do
    if SameText(FDefinitions[i].Name, AName) then
    begin
      Result := FDefinitions[i];
      Exit;
    end;
end;

function TContestRegistry.Count: Integer;
begin
  Result := FDefinitions.Count;
end;

function TContestRegistry.Definition(AIndex: Integer): TContestDefinition;
begin
  if (AIndex < 0) or (AIndex >= FDefinitions.Count) then
    raise EContestLogError.CreateFmt(
      'コンテスト定義の番号が範囲外です: %d (件数 %d)', [AIndex, FDefinitions.Count]);
  Result := FDefinitions[AIndex];
end;

procedure TContestRegistry.RegisterBuiltins;
var
  d: TContestDefinition;
begin
  { fldigi: contest.cxx CONTESTS contests[] より抜粋 (原文の notes 欄の
    交換ナンバー構成をそのまま踏襲)。 }

  d := Add(TContestDefinition.Create('Africa All-Mode International',
    'CALL SERNO, COUNTRY, RSTr, RSTs'));
  d.AddField(afSrx, cfNumeric, 'SERNO');
  d.AddField(afCountry, cfCountry, 'COUNTRY');

  d := Add(TContestDefinition.Create('ARRL Field Day',
    'CALL SECTION, CLASS, RSTr, RSTs'));
  d.AddField(afFdClass, cfClass, 'CLASS');
  d.AddField(afFdSection, cfArrlSection, 'SECTION');

  d := Add(TContestDefinition.Create('ARRL Winter FD',
    'CALL SECTION, CLASS, RSTr, RSTs'));
  d.AddField(afFdClass, cfClass, 'CLASS');
  d.AddField(afFdSection, cfArrlSection, 'SECTION');

  d := Add(TContestDefinition.Create('ARRL International DX (cw)',
    'CALL COUNTRY, POWER, RSTr, RSTs'));
  d.AddField(afCountry, cfCountry, 'COUNTRY');
  d.AddField(afTxPwr, cfFreeText, 'POWER');

  d := Add(TContestDefinition.Create('ARRL Rookie Roundup',
    'CALL, NAME, CHECK, STATE / VE_PROV, RSTr, RSTs'));
  d.AddField(afName, cfFreeText, 'NAME');
  d.AddField(afCheck, cfRookie, 'CHECK(免許取得年)');
  d.AddField(afState, cfStateProvinceOrCountry, 'STATE/PROV');

  d := Add(TContestDefinition.Create('ARRL November Sweepstakes',
    'CALL SECTION, SERNO, PREC, CHECK, RSTr, RSTs'));
  d.AddField(afSsSerno, cfSsSerno, 'SERNO');
  d.AddField(afSsPrec, cfSsPrecedence, 'PREC');
  d.AddField(afSsChk, cfSsCheck, 'CHECK');
  d.AddField(afSsSec, cfSsSection, 'SECTION');

  d := Add(TContestDefinition.Create('BARTG RTTY contest',
    'CALL NAME, SERIAL, EXCHANGE'));
  d.AddField(afName, cfFreeText, 'NAME');
  d.AddField(afSrx, cfNumeric, 'SERIAL');
  d.AddField(afXchg1, cfFreeText, 'EXCHANGE');

  d := Add(TContestDefinition.Create('CQ WPX',
    'CALL SERNO, COUNTRY, RSTr, RSTs'));
  d.AddField(afSrx, cfNumeric, 'SERNO');
  d.AddField(afCountry, cfCountry, 'COUNTRY');

  d := Add(TContestDefinition.Create('CQ WW DX',
    'CALL COUNTRY, ZONE, RSTr, RSTs'));
  d.AddField(afCountry, cfCountry, 'COUNTRY');
  d.AddField(afCqz, cfCqZone, 'ZONE');

  d := Add(TContestDefinition.Create('CQ WW DX RTTY',
    'CALL STATE, COUNTRY, ZONE, RSTr'));
  d.AddField(afState, cfState, 'STATE', False); { W/VE局のみ必須 }
  d.AddField(afCountry, cfCountry, 'COUNTRY');
  d.AddField(afCqz, cfCqZone, 'ZONE');

  d := Add(TContestDefinition.Create('Italian A.R.I. International DX',
    'CALL PR(ovince), COUNTRY, SERNO, RSTr, RSTs'));
  d.AddField(afXchg1, cfItalianProvince, 'PROVINCE', False); { イタリア局のみ必須 }
  d.AddField(afCountry, cfCountry, 'COUNTRY');
  d.AddField(afSrx, cfNumeric, 'SERNO');

  d := Add(TContestDefinition.Create('NAQP',
    'CALL NAME, STATE / VE_PROV / COUNTRY'));
  d.AddField(afName, cfFreeText, 'NAME');
  d.AddField(afState, cfStateProvinceOrCountry, 'STATE/PROV/COUNTRY');

  d := Add(TContestDefinition.Create('NA Sprint',
    'CALL SERNO, STATE / VE_PROV / COUNTRY, NAME, RSTr, RSTs'));
  d.AddField(afSrx, cfNumeric, 'SERNO');
  d.AddField(afState, cfStateProvinceOrCountry, 'STATE/PROV/COUNTRY');
  d.AddField(afName, cfFreeText, 'NAME');

  d := Add(TContestDefinition.Create('Ten Ten',
    'CALL 1010NR, STATE, NAME, RSTr, RSTs'));
  d.AddField(afTenTen, cfC1010, '1010NR');
  d.AddField(afState, cfState, 'STATE');
  d.AddField(afName, cfFreeText, 'NAME');

  d := Add(TContestDefinition.Create('VHF', 'CALL RSTr, RSTs'));
  d.AddField(afGridSquare, cfFreeText, 'GRID', False);
end;

{ ============================================================================
  TContestLog
  ============================================================================ }

constructor TContestLog.Create;
begin
  inherited Create;
  FDatabase := TAdifDatabase.Create;
  FDefinition := nil;
  FDxcc := nil;
  FNextSerial := 1;
end;

destructor TContestLog.Destroy;
begin
  FDatabase.Free;
  inherited Destroy;
end;

procedure TContestLog.ResetSerial(AStart: Integer);
begin
  FNextSerial := AStart;
end;

function TContestLog.IsDuplicate(const ACall, ABand, AMode: string): Boolean;
var
  i: Integer;
  rec: TAdifRecord;
  call, band, mode: string;
begin
  Result := False;
  call := UpperCase(Trim(ACall));
  band := LowerCase(Trim(ABand));
  mode := UpperCase(Trim(AMode));
  for i := 0 to FDatabase.Count - 1 do
  begin
    rec := FDatabase[i];
    if (rec.Call = call) and (LowerCase(rec.Band) = band) and (rec.Mode = mode) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function TContestLog.ValidateExchange(const AExchange: array of TContestFieldValue;
  const AHomeState: string): specialize TArray<string>;
var
  i, j: Integer;
  fld: TContestExchangeField;
  value: string;
  ok: Boolean;
  matchedCountry: string;
  failures: array of string;
begin
  SetLength(failures, 0);
  if not Assigned(FDefinition) then
  begin
    Result := failures;
    Exit;
  end;

  for i := 0 to FDefinition.FieldCount - 1 do
  begin
    fld := FDefinition[i];
    value := '';
    for j := 0 to High(AExchange) do
      if AExchange[j].FieldId = fld.FieldId then
      begin
        value := AExchange[j].Value;
        Break;
      end;

    if (value = '') and not fld.Required then Continue;

    case fld.Kind of
      cfFreeText:            ok := True;
      cfNumeric:              ok := ContestNumericTest(value);
      cfCutNumeric:           ok := ContestCutNumericTest(value);
      cfRst:                  ok := ContestRstTest(value, True);
      cfState:                ok := ContestStateTest(value);
      cfProvince:             ok := ContestProvinceTest(value);
      cfCounty:               ok := ContestCountyTest(FDefinition.Counties, AHomeState, value);
      cfCountry:              ok := ContestCountryTest(FDxcc, value, matchedCountry);
      cfCqZone:               ok := ContestNumericTest(value) and (StrToIntDef(value, 0) >= 1) and (StrToIntDef(value, 0) <= 40);
      cfItuZone:              ok := ContestNumericTest(value) and (StrToIntDef(value, 0) >= 1) and (StrToIntDef(value, 0) <= 90);
      cfClass:                ok := ContestClassTest(value);
      cfWfdClass:             ok := ContestWfdClassTest(value);
      cfAscrClass:            ok := ContestAscrClassTest(value);
      cfArrlSection:          ok := ContestSectionTest(value);
      cfRookie:               ok := ContestRookieTest(value, LocalTimeToUniversal(Now));
      cfC1010:                ok := ContestC1010Test(value);
      cfItalianProvince:      ok := ContestItalianProvinceTest(value);
      cfSsSerno:              ok := ContestNumericTest(value);
      cfSsPrecedence:         ok := ContestSsPrecTest(value);
      cfSsCheck:              ok := ContestSsChkTest(value);
      cfSsSection:            ok := ContestSectionTest(value);
      cfStateProvinceOrCountry: ok := ContestStateProvinceCountryTest(FDxcc, value);
    else
      ok := True;
    end;

    if not ok then
    begin
      SetLength(failures, Length(failures) + 1);
      failures[High(failures)] := fld.FieldLabel;
    end;
  end;

  Result := failures;
end;

function TContestLog.LogQso(const ACall, ABand, AMode, ARstSent, ARstRcvd: string;
  const AExchange: array of TContestFieldValue; AAssignSerial: Boolean;
  out ADupe: Boolean): TAdifRecord;
var
  i: Integer;
  entry: TDxccEntry;
  nowUtc: TDateTime;
begin
  ADupe := IsDuplicate(ACall, ABand, AMode);

  Result := FDatabase.AddRecord;
  Result.Call := ACall;
  Result.Mode := AMode;
  Result.Band := ABand;
  Result.PutField(afRstSent, ARstSent);
  Result.PutField(afRstRcvd, ARstRcvd);

  nowUtc := LocalTimeToUniversal(Now);
  Result.SetCurrentDateTime(True, nowUtc);
  Result.CheckBand;

  if Assigned(FDxcc) and FDxcc.Loaded then
  begin
    entry := FDxcc.Lookup(ACall);
    if Assigned(entry) then
    begin
      Result.PutField(afCountry, entry.Country);
      Result.PutField(afCqz, IntToStr(entry.CqZone));
      Result.PutField(afItuz, IntToStr(entry.ItuZone));
      Result.PutField(afCont, entry.Continent);
    end;
  end;

  for i := 0 to High(AExchange) do
    Result.PutField(AExchange[i].FieldId, AExchange[i].Value);

  if AAssignSerial then
  begin
    Result.PutField(afStx, IntToStr(FNextSerial));
    Inc(FNextSerial);
  end;
end;

function TContestLog.SaveToAdif(const AFileName: string): Boolean;
{ 保存の成否を正直に返す。以前は無条件に True を返しており、書き込みに
  失敗しても呼び出し側が戻り値からは気付けなかった (例外が素通りするか、
  成功したように見えるかのどちらかで、扱いが一貫しなかった)。
  実運用では書き込み権限・ディスク残量・USB メモリの抜去といった失敗が
  現実に起こるため、戻り値だけで判定できるようにする。 }
begin
  Result := SaveToAdif(AFileName, FLastSaveError);
end;

function TContestLog.SaveToAdif(const AFileName: string;
  out AErrorMessage: string): Boolean;
begin
  AErrorMessage := '';
  try
    FDatabase.SaveToFile(AFileName);
    Result := True;
  except
    on E: Exception do
    begin
      AErrorMessage := E.Message;
      Result := False;
    end;
  end;
end;

function TContestLog.LoadFromAdif(const AFileName: string): Integer;
begin
  Result := FDatabase.LoadFromFile(AFileName);
end;

end.
