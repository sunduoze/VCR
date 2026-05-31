// TypedDataPool — Phase 3: Object pool for Float32List reuse
// Avoids GC pressure by recycling Float32List buffers instead of allocating new ones.
// Typical usage: waveform rendering passes 1-4 Float32Lists per frame at 60fps.

import 'dart:typed_data';
import 'dart:collection';

/// Pool configuration
class PoolConfig {
  /// Default capacity per buffer (number of Float32 elements)
  final int defaultLength;

  /// Maximum number of buffers to pool per bucket
  final int maxPooledPerBucket;

  const PoolConfig({
    this.defaultLength = 2048,
    this.maxPooledPerBucket = 8,
  });
}

/// A size-bucketed pool of Float32List objects.
///
/// Buffers are grouped into buckets by their length (rounded up to next power of two).
/// When a buffer is "released", it goes back to its bucket for reuse.
/// When a buffer is "acquired", it's taken from the matching bucket (or created new).
///
/// This avoids the GC overhead of allocating and throwing away Float32Lists
/// on every frame in the hot rendering path.
class TypedDataPool {
  final PoolConfig _config;

  /// Buckets: power-of-two size → list of available buffers
  final Map<int, ListQueue<Float32List>> _buckets = {};

  TypedDataPool({PoolConfig? config}) : _config = config ?? const PoolConfig();

  /// Acquire a Float32List of at least [minLength] elements.
  ///
  /// Returns a pooled buffer if available, otherwise creates a new one.
  /// The returned buffer MAY be larger than [minLength].
  Float32List acquire(int minLength) {
    if (minLength <= 0) {
      return Float32List(0);
    }

    final bucketSize = _bucketSize(minLength);
    final bucket = _buckets.putIfAbsent(bucketSize, () => ListQueue());

    if (bucket.isNotEmpty) {
      final buf = bucket.removeLast();
      return buf;
    }

    // Create new buffer (sized to bucket capacity)
    return Float32List(bucketSize);
  }

  /// Release a Float32List back to the pool for future reuse.
  void release(Float32List buffer) {
    if (buffer.length == 0) return;

    final bucketSize = buffer.length;
    final bucket = _buckets.putIfAbsent(bucketSize, () => ListQueue());

    if (bucket.length < _config.maxPooledPerBucket) {
      bucket.addLast(buffer);
    }
    // If bucket is full, let the buffer be GC'd
  }

  /// Clear all pooled buffers (useful for cleanup)
  void clear() {
    _buckets.clear();
  }

  /// Get total number of buffers currently in the pool
  int get totalBuffers {
    int count = 0;
    for (final bucket in _buckets.values) {
      count += bucket.length;
    }
    return count;
  }

  /// Statistics for debugging
  Map<String, dynamic> get stats {
    final bucketStats = <String, int>{};
    int totalBuffers = 0;
    for (final entry in _buckets.entries) {
      bucketStats['${entry.key}'] = entry.value.length;
      totalBuffers += entry.value.length;
    }
    return {
      'totalBuffers': totalBuffers,
      'numBuckets': _buckets.length,
      'buckets': bucketStats,
    };
  }

  /// Calculate bucket size (next power of two)
  int _bucketSize(int minLength) {
    if (minLength <= _config.defaultLength) {
      return _config.defaultLength;
    }
    // Round up to next power of two
    int size = 1;
    while (size < minLength) {
      size <<= 1;
    }
    return size;
  }
}

/// Global singleton pool for waveform rendering
TypedDataPool? _globalPool;

/// Get or create the global TypedDataPool for waveform rendering
TypedDataPool get waveformDataPool {
  _globalPool ??= TypedDataPool(config: const PoolConfig(
    defaultLength: 4096,  // 2x default for waveform buffers
    maxPooledPerBucket: 12, // generous pool for 60fps rendering
  ));
  return _globalPool!;
}

/// Convenience extension to auto-release buffers
extension TypedDataPoolExtension on TypedDataPool {
  /// Acquire a buffer, execute [action], then release it back.
  /// Returns the result of [action].
  T withBuffer<T>(int minLength, T Function(Float32List) action) {
    final buf = acquire(minLength);
    try {
      return action(buf);
    } finally {
      release(buf);
    }
  }
}