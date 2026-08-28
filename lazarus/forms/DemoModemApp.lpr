program DemoModemApp;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // LCLバックエンド (widgetset) を選択するために必要
  Forms,
  UnitMainForm;

var
  MainFormInstance: TMainForm;

begin
  Application.Title := 'Lazarus fldigi-style Modem Demo';
  Application.Scaled := True;
  Application.Initialize;
  MainFormInstance := TMainForm.Create(Application);
  Application.ShowMainForm := True;
  Application.Run;
  MainFormInstance := nil; // 使用済みマーク (Application が所有者として解放する)
end.
