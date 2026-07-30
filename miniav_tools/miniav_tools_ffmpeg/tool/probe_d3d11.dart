import 'package:miniav_tools_ffmpeg/miniav_tools_ffmpeg.dart';

Future<void> main() async {
  await ensureFFmpegLoaded();
  print('HW vendors (Stage A): ${ffmpegHwVendorsAvailable()}');
  print('D3D11VA vendors (Stage B): ${ffmpegD3d11VendorsAvailable()}');
  print(
    'Stage B available for h264: ${ffmpegD3d11EncoderAvailable(VideoCodec.h264)}',
  );
  print(
    'Stage B available for hevc: ${ffmpegD3d11EncoderAvailable(VideoCodec.hevc)}',
  );
  print(
    'Stage B available for av1:  ${ffmpegD3d11EncoderAvailable(VideoCodec.av1)}',
  );
}
