use parking_lot::RwLock;
use std::sync::atomic::AtomicU64;

/// Storage for raw sample data, split into chunks
pub struct SegmentStorage {
    /// Raw data chunks (each <= MAX_CHUNK_SIZE bytes)
    pub data_chunks: RwLock<Vec<Vec<u8>>>,
    /// Total number of samples (lock-free read)
    pub sample_count: AtomicU64,
    /// Bytes per sample (= 4 for f32)
    pub unit_size: u32,
    /// Start time (Unix timestamp or sample index)
    pub start_time: i64,
    /// Sampling rate in Hz
    pub samplerate: f64,
    /// Whether data collection is complete
    pub is_complete: RwLock<bool>,
}

impl SegmentStorage {
    /// Create new storage with given samplerate
    pub fn new(samplerate: f64) -> Self {
        Self {
            data_chunks: RwLock::new(Vec::new()),
            sample_count: AtomicU64::new(0),
            unit_size: std::mem::size_of::<f32>() as u32,
            start_time: 0,
            samplerate,
            is_complete: RwLock::new(false),
        }
    }

    /// Get the total number of samples (lock-free)
    pub fn sample_count(&self) -> u64 {
        self.sample_count.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Append interleaved f32 samples (value per channel)
    /// Each channel gets its own sample; for multi-channel, values are stored sequentially.
    /// Returns the sample index of the first sample written.
    pub fn append_interleaved_samples(&self, data: &[f32], _channel_count: usize) -> u64 {
        use super::constants::MAX_CHUNK_SIZE;

        let sample_start = self.sample_count.fetch_add(1, std::sync::atomic::Ordering::Release);
        let byte_data: &[u8] = unsafe {
            std::slice::from_raw_parts(
                data.as_ptr() as *const u8,
                data.len() * std::mem::size_of::<f32>(),
            )
        };

        let mut chunks = self.data_chunks.write();
        if chunks.is_empty() || chunks.last().unwrap().len() + byte_data.len() > MAX_CHUNK_SIZE {
            chunks.push(Vec::with_capacity(MAX_CHUNK_SIZE));
        }
        chunks.last_mut().unwrap().extend_from_slice(byte_data);

        sample_start
    }

    /// Get min/max for a range of samples [start, end) for a specific channel
    /// Returns (min, max) or (0.0, 0.0) if range is invalid
    pub fn range_min_max(&self, _start: u64, _end: u64, _channel: usize, _total_channels: usize) -> (f32, f32) {
        // TODO: implement indexed range lookup from chunks
        // For now, placeholder
        (0.0, 0.0)
    }
}
