// LockFreeRingBuffer — Phase 2: High-throughput lock-free data buffer
// Replaces Mutex-based ChannelBuffer with atomic operations
// Design: 12M points pre-allocated (~192MB), cache-line aligned, no false sharing

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

/// Cache line size for modern x86 CPUs
const CACHE_LINE_SIZE: usize = 128;

/// Single data point — 16 bytes (2x f64)
/// Must be Copy for lock-free operations
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RingDataPoint {
    pub timestamp_ms: f64,
    pub value: f64,
}

/// Lock-Free Ring Buffer with cache-line padding and generation counter.
///
/// Layout:
/// [write_pos: AtomicU64] [padding] [read_pos: AtomicU64] [padding]
/// [generation: AtomicU64] [padding] [capacity: usize]
/// [data: UnsafeCell<Vec<RingDataPoint>>] [readable: AtomicU64] [padding]
///
/// Safety: Only ONE producer thread writes; only ONE consumer thread reads.
/// This is a Single-Producer-Single-Consumer (SPSC) ring buffer.
pub struct LockFreeRingBuffer {
    /// Producer write position (monotonically increasing, never wraps)
    write_pos: AtomicU64,
    _pad0: [u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],

    /// Consumer read position (monotonically increasing, never wraps)
    read_pos: AtomicU64,
    _pad1: [u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],

    /// Overwrite generation counter — incremented each time write overwrites unread data.
    /// Dart side compares this to detect if data between frames has been lost.
    generation: AtomicU64,
    _pad2: [u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],

    /// Total capacity (always power-of-two for fast modulo via bitwise AND)
    capacity: usize,

    /// Ring buffer data storage (wrapped with UnsafeCell for interior mutability)
    data: UnsafeCell<Vec<RingDataPoint>>,

    /// Readable count for consumer (how many points are available to read)
    readable: AtomicU64,
    _pad3: [u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],
}

// LockFreeRingBuffer is Send + Sync because:
// - Atomic operations provide synchronization
// - UnsafeCell is accessed via atomic indices
unsafe impl Send for LockFreeRingBuffer {}
unsafe impl Sync for LockFreeRingBuffer {}

impl LockFreeRingBuffer {
    /// Create a new lock-free ring buffer with given capacity.
    /// Capacity is rounded up to next power of two.
    pub fn new(requested_capacity: usize) -> Self {
        let capacity = requested_capacity.next_power_of_two();
        let data = vec![RingDataPoint { timestamp_ms: 0.0, value: 0.0 }; capacity];

        Self {
            write_pos: AtomicU64::new(0),
            _pad0: [0u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],
            read_pos: AtomicU64::new(0),
            _pad1: [0u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],
            generation: AtomicU64::new(0),
            _pad2: [0u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],
            capacity,
            data: UnsafeCell::new(data),
            readable: AtomicU64::new(0),
            _pad3: [0u8; CACHE_LINE_SIZE - std::mem::size_of::<AtomicU64>()],
        }
    }

    /// Get capacity
    #[inline]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Get number of readable points
    #[inline]
    pub fn len(&self) -> usize {
        self.readable.load(Ordering::Acquire) as usize
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Get generation counter (increments on data overwrite).
    /// Used by Dart to detect dropped frames / data loss.
    #[inline]
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    /// Get current write position
    #[inline]
    pub fn head(&self) -> u64 {
        self.write_pos.load(Ordering::Acquire)
    }

    /// Producer: Push a single data point (single-producer, lock-free)
    #[inline]
    pub fn push(&self, timestamp_ms: f64, value: f64) {
        let idx = self.write_pos.fetch_add(1, Ordering::Relaxed) as usize;
        let slot = idx & (self.capacity - 1); // fast modulo (power-of-two)

        // Detect overwrite: if write passes read, oldest data is being overwritten
        let read = self.read_pos.load(Ordering::Acquire) as usize;
        if idx.wrapping_sub(read) >= self.capacity {
            self.generation.fetch_add(1, Ordering::Release);
        }

        let data_ptr = unsafe { &mut *self.data.get() };
        data_ptr[slot] = RingDataPoint { timestamp_ms, value };

        // Update readable count
        let new_readable = (idx + 1).min(read + self.capacity);
        self.readable.store(
            new_readable as u64 - self.read_pos.load(Ordering::Acquire),
            Ordering::Release,
        );
    }

    /// Producer: Push a batch of data points (single-producer, lock-free)
    pub fn push_batch(&self, points: &[(f64, f64)]) {
        let data_ptr = unsafe { &mut *self.data.get() };
        let read = self.read_pos.load(Ordering::Acquire) as usize;
        let mut overwrites = 0u64;

        for (ts, val) in points {
            let idx = self.write_pos.fetch_add(1, Ordering::Relaxed) as usize;
            let slot = idx & (self.capacity - 1);

            if idx.wrapping_sub(read) >= self.capacity {
                overwrites += 1;
            }

            data_ptr[slot] = RingDataPoint { timestamp_ms: *ts, value: *val };
        }

        if overwrites > 0 {
            self.generation.fetch_add(overwrites, Ordering::Release);
        }

        let new_idx = self.write_pos.load(Ordering::Relaxed) as usize;
        let readable = new_idx.min(read + self.capacity);
        self.readable.store(
            readable as u64 - self.read_pos.load(Ordering::Acquire),
            Ordering::Release,
        );
    }

    /// Consumer: Read all available data (single-consumer, lock-free)
    /// Returns a Vec<RingDataPoint> ordered by timestamp.
    /// Note: This allocates. For zero-copy, use read_into().
    pub fn read_all(&self) -> Vec<RingDataPoint> {
        let data_ptr = unsafe { &*self.data.get() };
        let readable = self.readable.load(Ordering::Acquire) as usize;

        if readable == 0 {
            return vec![];
        }

        let read_start = self.read_pos.load(Ordering::Acquire) as usize;
        let mut result = Vec::with_capacity(readable);

        for i in 0..readable {
            let slot = (read_start + i) & (self.capacity - 1);
            result.push(data_ptr[slot]);
        }

        self.read_pos.fetch_add(readable as u64, Ordering::Release);
        self.readable.store(0, Ordering::Release);

        result
    }

    /// Consumer: Read data into a pre-allocated slice (partial zero-copy)
    /// Returns the number of points actually read.
    pub fn read_into(&self, dest: &mut [RingDataPoint]) -> usize {
        let readable = self.readable.load(Ordering::Acquire) as usize;
        let count = readable.min(dest.len());

        if count == 0 {
            return 0;
        }

        let data_ptr = unsafe { &*self.data.get() };
        let read_start = self.read_pos.load(Ordering::Acquire) as usize;

        for i in 0..count {
            let slot = (read_start + i) & (self.capacity - 1);
            dest[i] = data_ptr[slot];
        }

        self.read_pos.fetch_add(count as u64, Ordering::Release);
        self.readable.fetch_sub(count as u64, Ordering::Release);

        count
    }

    /// Consumer: Peek at readable count without consuming
    #[inline]
    pub fn peek_len(&self) -> usize {
        self.readable.load(Ordering::Acquire) as usize
    }

    /// Get raw pointer to internal data (unsafe, for zero-copy peek operations).
    /// Caller must ensure no concurrent writes during access.
    #[inline]
    pub fn data_ptr(&self) -> *const Vec<RingDataPoint> {
        self.data.get()
    }

    /// Clear the buffer (reset positions)
    pub fn clear(&self) {
        self.write_pos.store(0, Ordering::Release);
        self.read_pos.store(0, Ordering::Release);
        self.readable.store(0, Ordering::Release);
    }

    /// Get memory usage in bytes
    pub fn memory_usage(&self) -> usize {
        let data_ptr = unsafe { &*self.data.get() };
        data_ptr.len() * std::mem::size_of::<RingDataPoint>()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn test_push_and_read() {
        let buf = LockFreeRingBuffer::new(1024);
        assert_eq!(buf.capacity(), 1024);

        buf.push(1.0, 10.0);
        buf.push(2.0, 20.0);
        buf.push(3.0, 30.0);

        assert_eq!(buf.len(), 3);

        let data = buf.read_all();
        assert_eq!(data.len(), 3);
        assert_eq!(data[0].timestamp_ms, 1.0);
        assert_eq!(data[2].value, 30.0);

        assert!(buf.is_empty());
    }

    #[test]
    fn test_wraparound() {
        let buf = LockFreeRingBuffer::new(4); // capacity = 4
        assert_eq!(buf.capacity(), 4);

        // Fill the buffer
        buf.push(1.0, 1.0);
        buf.push(2.0, 2.0);
        buf.push(3.0, 3.0);
        buf.push(4.0, 4.0);

        // Read 2
        let data = buf.read_all();
        assert_eq!(data.len(), 4);
        assert_eq!(data[3].timestamp_ms, 4.0);

        // Push more (wraparound)
        buf.push(5.0, 5.0);
        buf.push(6.0, 6.0);

        let data = buf.read_all();
        assert_eq!(data.len(), 2);
        assert_eq!(data[0].timestamp_ms, 5.0);
        assert_eq!(data[1].timestamp_ms, 6.0);
    }

    #[test]
    fn test_multi_thread() {
        use std::sync::Arc;
        let buf = Arc::new(LockFreeRingBuffer::new(1024));
        let buf_clone = buf.clone();

        let producer = thread::spawn(move || {
            for i in 0..1000 {
                buf_clone.push(i as f64, i as f64 * 10.0);
            }
        });

        let consumer = thread::spawn(move || {
            let mut total = 0;
            while total < 1000 {
                let data = buf.read_all();
                total += data.len();
                if data.len() < 100 {
                    thread::sleep(std::time::Duration::from_micros(100));
                }
            }
            assert_eq!(total, 1000);
        });

        producer.join().unwrap();
        consumer.join().unwrap();
    }

    #[test]
    fn test_capacity_power_of_two() {
        let buf = LockFreeRingBuffer::new(1000);
        assert_eq!(buf.capacity(), 1024);

        let buf = LockFreeRingBuffer::new(100000);
        assert_eq!(buf.capacity(), 131072);
    }

    #[test]
    fn test_memory_usage() {
        let buf = LockFreeRingBuffer::new(1024);
        let expected = 1024 * 16; // 16 bytes per RingDataPoint
        assert_eq!(buf.memory_usage(), expected);
    }

    #[test]
    fn test_clear() {
        let buf = LockFreeRingBuffer::new(1024);
        buf.push(1.0, 10.0);
        buf.push(2.0, 20.0);
        assert_eq!(buf.len(), 2);
        buf.clear();
        assert!(buf.is_empty());
        assert_eq!(buf.len(), 0);
    }
}