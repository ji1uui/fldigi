{ ============================================================================
  NullModemImpl.pas

  fldigi の src/include/nullmodem.h / src/trx/nullmodem.cxx (class NULLMODEM)
  を Lazarus/FPC 向けに移植した最小構成の具象モデム実装。

  TCustomModem を継承する際の「お手本」として、他のモード
  (PSK/RTTY/MFSK/Hellschreiber 等) を実装する際のテンプレートにする。
  ============================================================================ }
unit NullModemImpl;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SoundIntf, ModemTypes, Modem;

const
  NULLMODEM_SAMPLE_RATE = 8000; // fldigi: #define NULLMODEMSampleRate 8000

type
  { TNullModem
    ---------------------------------------------------------------------
    fldigi: class NULLMODEM : public modem (nullmodem.h)
    信号処理を一切行わない「何もしない」モデム。アプリ起動直後の
    既定モデムや、モデム未選択状態のプレースホルダとして使う。 }
  TNullModem = class(TCustomModem)
  public
    constructor Create(ASound: TCustomSoundDevice); reintroduce;

    procedure TxInit; override;
    procedure RxInit; override;
    procedure Restart; override;
    function RxProcess(const ABuf: array of Double; ALen: Integer): Integer; override;
    function TxProcess: Integer; override;
  end;

implementation

constructor TNullModem.Create(ASound: TCustomSoundDevice);
begin
  inherited Create(ASound, mmNull);
  SampleRate := NULLMODEM_SAMPLE_RATE;
  Restart;
end;

procedure TNullModem.TxInit;
begin
  // fldigi: NULLMODEM::tx_init() は空実装
end;

procedure TNullModem.RxInit;
begin
  // fldigi: NULLMODEM::rx_init() は put_MODEstatus(mode) のみ
  EmitStatus(GetModeName);
end;

procedure TNullModem.Restart;
begin
  // fldigi: NULLMODEM::restart() は set_bandwidth(null_bw) のみ (帯域=1Hz)
  Bandwidth := 1.0;
end;

function TNullModem.RxProcess(const ABuf: array of Double; ALen: Integer): Integer;
begin
  // fldigi: NULLMODEM::rx_process() は常に 0 を返すだけ
  Result := 0;
end;

function TNullModem.TxProcess: Integer;
begin
  // fldigi: NULLMODEM::tx_process() は modem::tx_process() (基底の共通処理)
  // を呼んだ後、10ms スリープしてから抜けるだけ。
  Result := inherited TxProcess;
  Sleep(10);
end;

end.
