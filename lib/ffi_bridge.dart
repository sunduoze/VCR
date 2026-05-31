// FFI 桥接 - 临时占位版本（避免编译错误）
// TODO: 后续修复为正确的 dart:ffi 手动绑定

import 'dart:typed_data';

/// PointsBuffer 结构体（占位）
class PointsBuffer {
  Pointer<Float>? ptr;
  int len = 0;
  
  PointsBuffer({this.ptr, this.len = 0});
}

/// FFI 桥接类（单例，占位实现）
class FfiBridge {
  static final FfiBridge _instance = FfiBridge._internal();
  factory FfiBridge() => _instance;
  
  FfiBridge._internal();
  
  /// 设置视口（占位）
  void setViewport(double tStart, double tEnd, int maxPoints) {
    // TODO: 实现 FFI 调用
    print('setViewport: $tStart, $tEnd, $maxPoints');
  }
  
  /// 获取当前视口内的数据点（占位）
  Float32List getPoints() {
    // TODO: 实现零拷贝 FFI 调用
    return Float32List(0);
  }
  
  /// 获取最新 N 个点（占位）
  Float32List getLatestPoints(int n) {
    // TODO: 实现零拷贝 FFI 调用
    return Float32List(0);
  }
  
  /// 推送单个数据点（占位）
  int pushDataPoint(double timestamp, double value) {
    // TODO: 实现 FFI 调用
    return 0;
  }
  
  /// 批量推送数据点（占位）
  void pushDataBatch(List<double> timestamps, List<double> values) {
    // TODO: 实现 FFI 调用
    print('pushDataBatch: ${timestamps.length} points');
  }
  
  /// 获取缓冲区读索引（占位）
  int getBufferReadIdx() => 0;
  
  /// 获取缓冲区写索引（占位）
  int getBufferWriteIdx() => 0;
}

/// 临时占位（避免编译错误）
class Pointer<T> {
  final int address;
  const Pointer(this.address);
  
  bool get isNull => address == 0;
  
  static Pointer<Float> fromAddress(int address) => Pointer<Float>(address);
}

class Float {}

/// 扩展方法（占位）
extension Float32ListExtension on Float32List {
  Pointer<Float> asTypedList(int len) => Pointer<Float>(0);
}
