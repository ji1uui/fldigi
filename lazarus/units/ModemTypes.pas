{ ============================================================================
  ModemTypes.pas

  fldigi の src/include/globals.h の一部 (trx_mode 列挙, state_t 列挙) を
  Lazarus/FPC 向けに移植した共通型定義ユニット。

  設計方針:
    - fldigi は enum で全モードをひとまとめに管理している (globals.h)。
      本移植版では規模を抑えつつ、同じ考え方 (モード種別を1つの列挙型で管理) を
      TModemMode として再現する。必要に応じて追加すればよい。
    - fldigi の state_t (trx.h) を TTrxState として再現。
      送受信スレッドの状態機械を Lazarus 側でも同じ枠組みで実装する。
  ============================================================================ }
unit ModemTypes;

{$mode objfpc}{$H+}

interface

type
  { 音声標本の並び。ユニットを跨いで波形を受け渡すのに使う。
    (もとは test/TestSupport.pas にあったが、units/ 側からも要るように
    なったのでここへ上げた。) }
  TDoubleArray = array of Double;

  // fldigi: enum state_t "STATE_PAUSE, STATE_RX, STATE_TX, ..." (trx.h)
  TTrxState = (
    tsPause,
    tsReceive,
    tsTransmit,
    tsRestart,
    tsTune,
    tsAbort,
    tsFlush,
    tsNoop,
    tsExit,
    tsEnded,
    tsIdle,
    tsNewModem
  );

  // fldigi: enum "MODE_NULL, MODE_CW, MODE_PSK31, MODE_RTTY, ..." (globals.h)
  // ここでは代表的なモードのみ抜粋。プロジェクトの必要に応じて追加する。
  TModemMode = (
    mmNull,
    mmCW,
    mmRTTY,
    mmPSK31,
    mmPSK63,
    mmPSK125,
    mmQPSK31,
    mmMFSK16,
    mmMFSK32,
    mmOlivia,
    mmDominoEX,
    mmThor,
    mmHellFeld,      // Feld Hell
    mmHellSlow,      // Slow Hell
    mmContestia,
    mmThrob,
    mmWWV,
    mmAnalysis
  );

  // モデムの能力ビット。fldigi: modem.h の enum "CAP_AFC, CAP_AFC_SR, ..."
  TModemCapability = (
    mcAFC,        // 自動周波数制御対応
    mcAFC_SR,     // AFC + サンプルレート追随
    mcReverse,    // 側波帯反転(REV)対応
    mcImage,      // 画像送受信対応 (MFSK/Feld等)
    mcBandwidth,  // 帯域幅可変
    mcRx,         // 受信対応
    mcTx          // 送信対応
  );
  TModemCapabilities = set of TModemCapability;

const
  ModemModeNames: array[TModemMode] of string = (
    'NULL', 'CW', 'RTTY', 'PSK31', 'PSK63', 'PSK125', 'QPSK31',
    'MFSK16', 'MFSK32', 'OLIVIA', 'DOMINOEX', 'THOR',
    'HELL', 'HELL-SLOW', 'CONTESTIA', 'THROB', 'WWV', 'ANALYSIS'
  );

function ModemModeToStr(AMode: TModemMode): string;

implementation

function ModemModeToStr(AMode: TModemMode): string;
begin
  Result := ModemModeNames[AMode];
end;

end.
