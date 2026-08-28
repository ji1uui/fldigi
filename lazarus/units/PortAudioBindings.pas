{ ============================================================================
  PortAudioBindings.pas

  PortAudio (http://www.portaudio.com/, http://files.portaudio.com/) の
  C API (portaudio.h, V19系) を Free Pascal 向けに直接バインディングした
  低レベルユニット。

  fldigi は音声デバイスの実I/Oに PortAudio を使用しており
  (src/include/sound.h の class SoundPort、USE_PORTAUDIO)、
  本ユニットはそれと同じネイティブライブラリを Lazarus/FPC から
  呼び出すためのヘッダ移植である。

  対応プラットフォームとリンク方法:
  ----------------------------------------------------------------------------
  - Windows : portaudio_x64.dll / portaudio_x86.dll (別途配布 or ビルドして
              実行ファイルと同じディレクトリに置く)
  - Linux   : libportaudio.so.2 (Debian/Ubuntu系は `apt install
              portaudio19-dev` で /usr/lib に導入される)
  - macOS   : libportaudio.dylib (Homebrew `brew install portaudio` 等)

  すべて mode objfpc + H+ でコンパイルし、動的ライブラリロードではなく
  `external` による通常のインポートリンクを使用する (実行時に見つから
  ない場合は
  プロセス起動時にリンクエラーとなるので、Open() を呼ぶ前に
  PaInitializeChecked のような try/except でラップするのではなく、
  アプリ全体の起動チェックとして扱うこと)。
  ============================================================================ }
unit PortAudioBindings;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  ctypes;

const
  {$IFDEF WINDOWS}
  PortAudioLib = 'libportaudio-2.dll';
  {$ENDIF}
  {$IFDEF DARWIN}
  PortAudioLib = 'libportaudio.dylib';
  {$ENDIF}
  {$IFDEF LINUX}
  PortAudioLib = 'libportaudio.so.2';
  {$ENDIF}
  {$IF NOT (DEFINED(WINDOWS) OR DEFINED(DARWIN) OR DEFINED(LINUX))}
  PortAudioLib = 'libportaudio.so.2'; // その他Unix系のフォールバック
  {$ENDIF}

type
  { fldigi/portaudio.h: typedef int PaError; }
  PaError = cint;
  { fldigi/portaudio.h: typedef int PaDeviceIndex; }
  PaDeviceIndex = cint;
  { fldigi/portaudio.h: typedef int PaHostApiIndex; }
  PaHostApiIndex = cint;
  { fldigi/portaudio.h: typedef double PaTime; }
  PaTime = cdouble;
  { fldigi/portaudio.h: typedef unsigned long PaSampleFormat; }
  PaSampleFormat = culong;
  { fldigi/portaudio.h: typedef unsigned long PaStreamFlags; }
  PaStreamFlags = culong;
  { fldigi/portaudio.h: typedef void PaStream; (opaque) }
  PPaStream = Pointer;

const
  { PaErrorCode (抜粋。多用するもののみ) }
  paNoError                    = PaError(0);
  paInputOverflowed            = PaError(-9981); // paErrorCode 一覧の値は
  paOutputUnderflowed          = PaError(-9980); // portaudio.h の enum 順で変わるため
                                                  // 実際には Pa_GetErrorText() を使う

  { paNoDevice (device index が「無し」を示す特別値) }
  paNoDevice = PaDeviceIndex(-1);
  paUseHostApiSpecificDeviceSpecification = PaDeviceIndex(-2);

  { PaSampleFormat フラグ (portaudio.h #define) }
  paFloat32        = PaSampleFormat($00000001);
  paInt32          = PaSampleFormat($00000002);
  paInt24          = PaSampleFormat($00000004);
  paInt16          = PaSampleFormat($00000008);
  paInt8           = PaSampleFormat($00000010);
  paUInt8          = PaSampleFormat($00000020);
  paCustomFormat   = PaSampleFormat($00010000);
  paNonInterleaved = PaSampleFormat($80000000);

  { Pa_OpenStream() framesPerBuffer に指定可能な特別値 }
  paFramesPerBufferUnspecified = culong(0);

  { PaStreamCallback の戻り値 (PaStreamCallbackResult) }
  paContinue = cint(0);
  paComplete = cint(1);
  paAbort    = cint(2);

type
  { fldigi/portaudio.h: struct PaDeviceInfo
    (V19 struct version 2。$PACKRECORDS C によりCと同じレイアウトになる) }
  PPaDeviceInfo = ^TPaDeviceInfo;
  TPaDeviceInfo = record
    structVersion: cint;
    name: PAnsiChar;
    hostApi: PaHostApiIndex;
    maxInputChannels: cint;
    maxOutputChannels: cint;
    defaultLowInputLatency: PaTime;
    defaultLowOutputLatency: PaTime;
    defaultHighInputLatency: PaTime;
    defaultHighOutputLatency: PaTime;
    defaultSampleRate: cdouble;
  end;

  { fldigi/portaudio.h: struct PaStreamParameters }
  PPaStreamParameters = ^TPaStreamParameters;
  TPaStreamParameters = record
    device: PaDeviceIndex;
    channelCount: cint;
    sampleFormat: PaSampleFormat;
    suggestedLatency: PaTime;
    hostApiSpecificStreamInfo: Pointer;
  end;

  { fldigi/portaudio.h: struct PaStreamCallbackTimeInfo }
  PPaStreamCallbackTimeInfo = ^TPaStreamCallbackTimeInfo;
  TPaStreamCallbackTimeInfo = record
    inputBufferAdcTime: PaTime;
    currentTime: PaTime;
    outputBufferDacTime: PaTime;
  end;

  TPaStreamCallbackFlags = culong;

  { fldigi/portaudio.h: typedef int PaStreamCallback(...)
    ブロッキングI/O (Pa_ReadStream/Pa_WriteStream) のみを使う場合は
    Pa_OpenStream() の streamCallback に nil を渡すため本コールバック型は
    実際には未使用だが、シグネチャの整合性のために定義しておく。 }
  TPaStreamCallback = function(Input: Pointer; Output: Pointer;
    FrameCount: culong; const TimeInfo: PPaStreamCallbackTimeInfo;
    StatusFlags: TPaStreamCallbackFlags; UserData: Pointer): cint; cdecl;

{ ---- ライブラリ初期化/終了 ---- }
function Pa_GetVersion: cint; cdecl; external PortAudioLib;
function Pa_GetVersionText: PAnsiChar; cdecl; external PortAudioLib;
function Pa_GetErrorText(errorCode: PaError): PAnsiChar; cdecl; external PortAudioLib;
function Pa_Initialize: PaError; cdecl; external PortAudioLib;
function Pa_Terminate: PaError; cdecl; external PortAudioLib;

{ ---- デバイス列挙 ---- }
function Pa_GetDeviceCount: PaDeviceIndex; cdecl; external PortAudioLib;
function Pa_GetDefaultInputDevice: PaDeviceIndex; cdecl; external PortAudioLib;
function Pa_GetDefaultOutputDevice: PaDeviceIndex; cdecl; external PortAudioLib;
function Pa_GetDeviceInfo(device: PaDeviceIndex): PPaDeviceInfo; cdecl; external PortAudioLib;
function Pa_GetHostApiCount: PaHostApiIndex; cdecl; external PortAudioLib;
function Pa_GetDefaultHostApi: PaHostApiIndex; cdecl; external PortAudioLib;

{ ---- フォーマット確認 ---- }
function Pa_IsFormatSupported(inputParameters: PPaStreamParameters;
  outputParameters: PPaStreamParameters; sampleRate: cdouble): PaError; cdecl;
  external PortAudioLib;

{ ---- ストリーム制御 (ブロッキング read/write モード) ---- }
function Pa_OpenStream(var stream: PPaStream; inputParameters: PPaStreamParameters;
  outputParameters: PPaStreamParameters; sampleRate: cdouble;
  framesPerBuffer: culong; streamFlags: PaStreamFlags;
  streamCallback: TPaStreamCallback; userData: Pointer): PaError; cdecl;
  external PortAudioLib;

function Pa_OpenDefaultStream(var stream: PPaStream; numInputChannels: cint;
  numOutputChannels: cint; sampleFormat: PaSampleFormat; sampleRate: cdouble;
  framesPerBuffer: culong; streamCallback: TPaStreamCallback;
  userData: Pointer): PaError; cdecl; external PortAudioLib;

function Pa_CloseStream(stream: PPaStream): PaError; cdecl; external PortAudioLib;
function Pa_StartStream(stream: PPaStream): PaError; cdecl; external PortAudioLib;
function Pa_StopStream(stream: PPaStream): PaError; cdecl; external PortAudioLib;
function Pa_AbortStream(stream: PPaStream): PaError; cdecl; external PortAudioLib;
function Pa_IsStreamStopped(stream: PPaStream): PaError; cdecl; external PortAudioLib;
function Pa_IsStreamActive(stream: PPaStream): PaError; cdecl; external PortAudioLib;

function Pa_ReadStream(stream: PPaStream; buffer: Pointer; frames: culong): PaError; cdecl;
  external PortAudioLib;
function Pa_WriteStream(stream: PPaStream; const buffer: Pointer; frames: culong): PaError; cdecl;
  external PortAudioLib;
function Pa_GetStreamReadAvailable(stream: PPaStream): clong; cdecl; external PortAudioLib;
function Pa_GetStreamWriteAvailable(stream: PPaStream): clong; cdecl; external PortAudioLib;

implementation

end.
