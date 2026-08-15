import 'dart:io';
import 'dart:typed_data';

/// Minimal MJPEG-in-AVI writer (pure Dart, no native codec needed).
///
/// Screens of the remote viewer are captured as JPEG frames and stored as
/// Motion-JPEG AVI — playable in Windows Media Player and most players.
///
/// Usage:
/// ```dart
/// final writer = MjpegWriter(path, width, height, fps);
/// writer.addJpeg(frameBytes);
/// await writer.close();
/// ```
class MjpegWriter {
  MjpegWriter(
    this.path,
    this.width,
    this.height,
    this.fps,
  ) {
    _out = File(path).openSync(mode: FileMode.writeOnlyAppend);
    _writeHeader();
  }

  final String path;
  final int width;
  final int height;
  final int fps;

  late final RandomAccessFile _out;

  late int _riffSizePos;
  late int _moviListSizePos;
  late int _totalFramesPos;
  late int _streamLengthPos;

  int _frameCount = 0;
  int _moviSize = 0;
  bool _closed = false;

  // ---- public ----------------------------------------------------------------

  void addJpeg(Uint8List jpeg) {
    if (_closed) return;
    _write('00dc');
    _writeInt32(jpeg.length);
    _out.writeFromSync(jpeg, 0, jpeg.length);
    _moviSize += 8 + jpeg.length;
    if (jpeg.length.isOdd) {
      _out.writeFromSync(Uint8List(1), 0, 1);
      _moviSize += 1;
    }
    _frameCount++;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _patchHeader();
    await _out.flush();
    _out.closeSync();
  }

  // ---- internals ---------------------------------------------------------------

  void _writeHeader() {
    _out.writeStringSync('RIFF');
    _riffSizePos = _out.positionSync();
    _writeInt32(0); // patched later
    _out.writeStringSync('AVI ');

    _out.writeStringSync('LIST');
    _writeInt32(4 + (4 + 56) + (4 + 56 + 40) + 4 + 4);
    _out.writeStringSync('hdrl');

    // avih
    _out.writeStringSync('avih');
    _writeInt32(56);
    _writeInt32((1000000 / fps).round()); // microsec per frame
    _writeInt32(width * height * 3 * fps); // max bytes/sec (estimate)
    _writeInt32(0); // padding granularity
    _writeInt32(0x10); // AVIF_HASINDEX
    _totalFramesPos = _out.positionSync(); // dwTotalFrames
    _writeInt32(0);
    _writeInt32(0);
    _writeInt32(1); // streams
    _writeInt32(width * height * 3);
    _writeInt32(width);
    _writeInt32(height);
    for (var i = 0; i < 4; i++) {
      _writeInt32(0);
    }

    // strl
    _out.writeStringSync('LIST');
    _writeInt32(4 + (4 + 56) + (4 + 40));
    _out.writeStringSync('strl');

    // strh
    _out.writeStringSync('strh');
    _writeInt32(56);
    _writeFourcc('vids');
    _writeFourcc('MJPG');
    _writeInt32(0); // flags
    _writeInt32(0); // priority
    _writeInt32(0); // language
    _writeInt32(0); // initial frames
    _writeInt32(1); // scale
    _writeInt32(fps); // rate
    _writeInt32(0); // start
    _streamLengthPos = _out.positionSync(); // dwLength
    _writeInt32(0);
    _writeInt32(width * height * 3); // suggested buffer
    _writeInt32(0xFFFFFFFF); // quality (default)
    _writeInt32(0); // sample size
    _writeInt32(0); // rcFrame left
    _writeInt32(0); // top
    _writeInt32(width);
    _writeInt32(height);

    // strf (BITMAPINFOHEADER)
    _out.writeStringSync('strf');
    _writeInt32(40);
    _writeInt32(40); // biSize
    _writeInt32(width);
    _writeInt32(height);
    _writeInt32(1); // planes
    _writeInt32(24); // bit count
    _writeFourcc('MJPG');
    _writeInt32(width * height * 3);
    _writeInt32(0);
    _writeInt32(0);
    _writeInt32(0);
    _writeInt32(0);

    _out.writeStringSync('LIST');
    _moviListSizePos = _out.positionSync(); // movi list size
    _writeInt32(0);
    _out.writeStringSync('movi');
  }

  void _patchHeader() {
    final end = _out.positionSync();

    _out.setPositionSync(_moviListSizePos);
    _writeInt32(4 + _moviSize);

    _out.setPositionSync(_riffSizePos);
    _writeInt32(end - _riffSizePos - 4);

    _out.setPositionSync(_totalFramesPos);
    _writeInt32(_frameCount);

    _out.setPositionSync(_streamLengthPos);
    _writeInt32(_frameCount);

    _out.setPositionSync(end);
  }

  void _write(String s) {
    _out.writeStringSync(s);
  }

  void _writeFourcc(String s) => _write(s);

  void _writeInt32(int value) {
    final bytes = ByteData(4)..setInt32(0, value, Endian.little);
    _out.writeFromSync(bytes.buffer.asUint8List(), 0, 4);
  }
}
