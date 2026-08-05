import 'dart:ffi';
import 'dart:typed_data';

// Stub — core pipeline/envelope/analog removed after Min-Max simplification.
// All calls are no-ops. plot_screen.dart still references these during cleanup.

final class CDataPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class CEnvelopeSample extends Struct {
  @Double()
  external double minVal;
  @Double()
  external double maxVal;

  // Aliases for code that uses .min / .max
  double get min => minVal;
  double get max => maxVal;
}

class FfiBridge {
  static final FfiBridge instance = FfiBridge._();
  FfiBridge._();

  void analogReset(int deviceKey, int channel) {}
  void analogSetEnvelopeEnabled(bool v) {}
  void analogEnsure(int deviceKey, int channel) {}
  void analogSetSamplerate(int deviceKey, int channel, double hz) {}
  void analogResetAll() {}
  int analogSampleCount(int deviceKey, int channel) => 0;

  // analogGetTrace: 6 args in code
  int analogGetTrace(int deviceKey, int channel, int startSample, int endSample,
      Pointer<Float> out, int maxLen) => 0;

  // analogGetEnvelope: 9 args in code
  int analogGetEnvelope(int deviceKey, int channel, int startSample, int endSample,
      double samplesPerPixel, Pointer<CEnvelopeSample> out, int maxSamples,
      Pointer<Uint64> sectionStart, Pointer<Uint32> sectionScale) => 0;

  String analogDumpDebug(int dk, int ch) => 'stub';

  int envelopeGetGeneration() => 0;
  void envelopeGetViewport(Pointer<Double> min, Pointer<Double> max) {}
  Pointer<Double> envelopeGetDataPtr() => nullptr;
  int envelopeGetNumChannels() => 0;
  int envelopeGetTotalSize() => 0;
  int envelopeGetChannelOffset(int dk, int ch) => -1;
  int envelopeGetChannelCount(int dk, int ch) => 0;
  void envelopeSetViewport(double tMin, double tMax, int maxPts, double anchor) {}

  void startPipeline() {}
  void stopPipeline() {}

  void pushChannelBatch(int deviceKey, int chId, Pointer<CDataPoint> data, int count) {}
  void pushChannelBatchDart(int deviceKey, int chId, List<(double, double)> batch) {}
  int get analogLevelCount => 10;
  set analogLevelCount(int v) {}
  void pyramidsSetAcceptConsole(bool v) {}
  void clearAllChannelPyramids() {}

  int queryChannelPointsInto(int dk, int ch, double tMin, double tMax,
      int maxPts, Pointer<CDataPoint> buf, int bufsz, Float64List fb) => 0;

  bool checkDataReady() => false;
}
