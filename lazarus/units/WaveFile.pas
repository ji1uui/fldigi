{ ============================================================================
  WaveFile.pas

  RIFF/WAVE の読み書き (16 bit PCM モノラル)。

  何のためにあるか
  ----------------------------------------------------------------------------
  Baseline §14.1 は Test Vector を **Golden WAV** と呼んでいる。
  TestVectors.pas は種から決定的に波形を作るので、日々の回帰試験には
  ファイルが要らない。それでも WAV の読み書きが要るのは 2 つの場面が
  あるためである。

  1. **実際の受信録音を持ち込む。** 合成した劣化は「こちらが考えた
     劣悪さ」でしかない。本当に難しい信号は現場にしかない。運用者が
     録った WAV をそのまま回帰試験に入れられるようにしておく。
  2. **生成した波形を外へ出して耳と目で確かめる。** 数字が悪いとき、
     波形を聴いたりスペクトラムを見たりできないと原因に辿り着けない。

  対応する形式を絞った理由
  ----------------------------------------------------------------------------
  16 bit PCM モノラルだけを読み書きする。復調に渡すのは実数のモノラル
  波形なので、多チャンネルや 24/32 bit を受けても結局は畳んで捨てる。
  **読めない形式は黙って変換せず、読めないと言う。** 変換すると、
  「なぜか復調できない」の原因がファイル形式にあることを見落とす。

  ただしステレオだけは例外で、左チャンネルを取り出す。fldigi が右を
  QSK 制御に使う流儀があり、受信録音がステレオで来ることが実際にある
  ためである (何をしたかは戻り値の情報で分かるようにしてある)。
  ============================================================================ }
unit WaveFile;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Math, ModemTypes;

const
  { 受け付ける標本化周波数の範囲。範囲外は壊れたヘッダとみなす。
    0 を通すと呼び出し側の割り算が落ちる。 }
  WAVE_MIN_RATE = 1000;
  WAVE_MAX_RATE = 768000;

  { 受け付ける最大の標本数 (48 kHz で 1 時間)。

    上限を置くのは、data の長さがヘッダから来る値だからである。
    2 GB を超える長さを Integer で受けると溢れて負になり、負の長さで
    読み出そうとする。**外部から来るファイルを読む関数**なので、
    ヘッダの値をそのまま信用しない。 }
  WAVE_MAX_FRAMES = 48000 * 60 * 60;

type
  EWaveFileError = class(Exception);

  { 読み込んだ WAV の素性。 }
  TWaveInfo = record
    SampleRate: Integer;
    Channels: Integer;      // 元のチャンネル数 (1 か 2)
    BitsPerSample: Integer;
    Frames: Integer;        // 取り出した標本数
    UsedLeftOfStereo: Boolean;  // ステレオから左を取り出したか
    function Describe: string;
  end;

{ 16 bit PCM モノラルとして書き出す。値は -1..+1 を想定し、範囲外は
  頭打ちにする (黙って回り込むと、聴いたとき別物になる)。 }
procedure SaveWave(const AFileName: string; const AData: array of Double;
  ACount, ASampleRate: Integer);

{ 読み込む。16 bit PCM のみ。ステレオは左を取り出す。 }
function LoadWave(const AFileName: string; out AData: TDoubleArray): TWaveInfo;

implementation

type
  { RIFF のかたまりの見出し。 }
  TChunkHeader = packed record
    Id: array[0..3] of AnsiChar;
    Size: LongWord;
  end;

function TWaveInfo.Describe: string;
begin
  Result := Format('%d Hz / %d bit / %d ch / %d 標本 (%.2f 秒)',
    [SampleRate, BitsPerSample, Channels, Frames,
     Frames / Max(1, SampleRate)]);
  if UsedLeftOfStereo then
    Result := Result + ' [ステレオの左を使用]';
end;

procedure WriteId(AStream: TStream; const AId: string);
var
  b: array[0..3] of AnsiChar;
  i: Integer;
begin
  for i := 0 to 3 do b[i] := AId[i + 1];
  AStream.WriteBuffer(b, 4);
end;

procedure SaveWave(const AFileName: string; const AData: array of Double;
  ACount, ASampleRate: Integer);
var
  fs: TFileStream;
  i: Integer;
  v: Double;
  s: SmallInt;
  dataBytes: LongWord;
  u32: LongWord;
  u16: Word;
begin
  if ACount < 0 then ACount := 0;
  if ACount > Length(AData) then ACount := Length(AData);
  if ASampleRate <= 0 then
    raise EWaveFileError.CreateFmt('標本化周波数が不正です (%d)', [ASampleRate]);

  dataBytes := LongWord(ACount) * 2;

  fs := TFileStream.Create(AFileName, fmCreate);
  try
    WriteId(fs, 'RIFF');
    u32 := 36 + dataBytes; fs.WriteBuffer(u32, 4);
    WriteId(fs, 'WAVE');

    WriteId(fs, 'fmt ');
    u32 := 16; fs.WriteBuffer(u32, 4);
    u16 := 1; fs.WriteBuffer(u16, 2);              { PCM }
    u16 := 1; fs.WriteBuffer(u16, 2);              { モノラル }
    u32 := LongWord(ASampleRate); fs.WriteBuffer(u32, 4);
    u32 := LongWord(ASampleRate) * 2; fs.WriteBuffer(u32, 4);  { byte/秒 }
    u16 := 2; fs.WriteBuffer(u16, 2);              { block align }
    u16 := 16; fs.WriteBuffer(u16, 2);             { bit/標本 }

    WriteId(fs, 'data');
    fs.WriteBuffer(dataBytes, 4);
    for i := 0 to ACount - 1 do
    begin
      { -1..+1 を想定。範囲外は頭打ちにする。回り込ませると、
        大きすぎる波形が小さい波形として書かれてしまう。 }
      v := AData[i];
      if v > 1.0 then v := 1.0
      else if v < -1.0 then v := -1.0;
      s := Round(v * 32767);
      fs.WriteBuffer(s, 2);
    end;
  finally
    fs.Free;
  end;
end;

function LoadWave(const AFileName: string; out AData: TDoubleArray): TWaveInfo;
var
  fs: TFileStream;
  hdr: TChunkHeader;
  riffType: array[0..3] of AnsiChar;
  fmtFound, dataFound: Boolean;
  fmtTag, channels, bits, blockAlign: Word;
  rate: LongWord;
  dataPos: Int64;
  dataSize: LongWord;
  i, frames: Integer;
  frameCount: Int64;
  raw: array of SmallInt;
  skip: Int64;
begin
  AData := nil;
  FillChar(Result, SizeOf(Result), 0);
  fmtFound := False;
  dataFound := False;
  fmtTag := 0; channels := 0; bits := 0; blockAlign := 0; rate := 0;
  dataPos := 0; dataSize := 0;

  if not FileExists(AFileName) then
    raise EWaveFileError.CreateFmt('ファイルがありません: %s', [AFileName]);

  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size < 12 then
      raise EWaveFileError.Create('WAV として短すぎます。');
    fs.ReadBuffer(hdr, SizeOf(hdr));
    if hdr.Id <> 'RIFF' then
      raise EWaveFileError.Create('RIFF ではありません。');
    fs.ReadBuffer(riffType, 4);
    if riffType <> 'WAVE' then
      raise EWaveFileError.Create('WAVE ではありません。');

    { かたまりを順に読む。知らないものは飛ばす。 }
    while fs.Position + SizeOf(hdr) <= fs.Size do
    begin
      fs.ReadBuffer(hdr, SizeOf(hdr));
      if hdr.Id = 'fmt ' then
      begin
        if hdr.Size < 16 then
          raise EWaveFileError.Create('fmt が短すぎます。');
        fs.ReadBuffer(fmtTag, 2);
        fs.ReadBuffer(channels, 2);
        fs.ReadBuffer(rate, 4);
        fs.Seek(4, soCurrent);            { byte/秒 は使わない }
        fs.ReadBuffer(blockAlign, 2);
        fs.ReadBuffer(bits, 2);
        if hdr.Size > 16 then
          fs.Seek(Int64(hdr.Size) - 16, soCurrent);
        fmtFound := True;
      end
      else if (hdr.Id = 'data') and (not dataFound) then
      begin
        { data が複数あるファイルは最初のものを採る。後勝ちにすると
          どれを読んだのか分からなくなる。 }
        dataPos := fs.Position;
        dataSize := hdr.Size;
        dataFound := True;
        { data の中身は後で読む。 }
        skip := hdr.Size;
        if dataPos + skip > fs.Size then
          skip := fs.Size - dataPos;     { 途中で切れたファイルを許す }
        fs.Seek(skip, soCurrent);
      end
      else
        fs.Seek(Int64(hdr.Size), soCurrent);

      { かたまりは偶数境界に揃う。 }
      if (hdr.Size and 1) <> 0 then
        fs.Seek(1, soCurrent);
    end;

    if not fmtFound then
      raise EWaveFileError.Create('fmt が見つかりません。');
    if not dataFound then
      raise EWaveFileError.Create('data が見つかりません。');
    if fmtTag <> 1 then
      raise EWaveFileError.CreateFmt(
        '非圧縮 PCM ではありません (format tag %d)。', [fmtTag]);
    if bits <> 16 then
      raise EWaveFileError.CreateFmt(
        '16 bit のみ扱えます (このファイルは %d bit)。', [bits]);
    if (channels < 1) or (channels > 2) then
      raise EWaveFileError.CreateFmt(
        'モノラルかステレオのみ扱えます (%d ch)。', [channels]);
    if (rate < WAVE_MIN_RATE) or (rate > WAVE_MAX_RATE) then
      raise EWaveFileError.CreateFmt(
        '標本化周波数が範囲外です (%d Hz。%d〜%d のみ扱えます)。',
        [rate, WAVE_MIN_RATE, WAVE_MAX_RATE]);

    if dataPos + Int64(dataSize) > fs.Size then
      dataSize := LongWord(fs.Size - dataPos);

    { ヘッダ由来の長さをそのまま Integer に入れない。先に 64 bit で
      割ってから上限と突き合わせる。 }
    frameCount := Int64(dataSize) div (2 * Int64(channels));
    if frameCount > WAVE_MAX_FRAMES then
      raise EWaveFileError.CreateFmt(
        '長すぎます (%d 標本。上限 %d)。', [frameCount, WAVE_MAX_FRAMES]);
    frames := Integer(frameCount);
    SetLength(raw, frames * channels);
    if frames > 0 then
    begin
      fs.Position := dataPos;
      fs.ReadBuffer(raw[0], frames * channels * 2);
    end;

    SetLength(AData, frames);
    for i := 0 to frames - 1 do
      AData[i] := raw[i * channels] / 32768.0;

    Result.SampleRate := Integer(rate);
    Result.Channels := channels;
    Result.BitsPerSample := bits;
    Result.Frames := frames;
    Result.UsedLeftOfStereo := channels = 2;
  finally
    fs.Free;
  end;
end;

end.
