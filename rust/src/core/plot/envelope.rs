/// Single envelope sample: min/max pair (8 bytes total, f32)
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct EnvelopeSample {
    pub min: f32,
    pub max: f32,
}

/// A single level of the envelope pyramid
#[derive(Debug, Clone)]
pub struct EnvelopeLayer {
    /// Logical number of EnvelopeSamples in this layer
    pub length: u64,
    /// Allocated capacity (aligned to ENVELOPE_DATA_UNIT)
    pub capacity: u64,
    /// The actual envelope samples
    pub samples: Vec<EnvelopeSample>,
}

impl EnvelopeLayer {
    pub fn new() -> Self {
        Self {
            length: 0,
            capacity: 0,
            samples: Vec::new(),
        }
    }

    /// Reserve capacity aligned to ENVELOPE_DATA_UNIT
    pub fn reserve(&mut self, target_capacity: u64) {
        use super::constants::ENVELOPE_DATA_UNIT;
        let units = (target_capacity as usize).div_ceil(ENVELOPE_DATA_UNIT);
        let aligned = units * ENVELOPE_DATA_UNIT / std::mem::size_of::<EnvelopeSample>();
        if aligned > self.samples.capacity() {
            self.samples.reserve_exact(aligned - self.samples.len());
        }
        self.capacity = aligned as u64;
    }

    /// Push a single envelope sample
    pub fn push(&mut self, sample: EnvelopeSample) {
        self.samples.push(sample);
        self.length += 1;
    }

    /// Get total number of samples
    pub fn len(&self) -> u64 {
        self.length
    }

    pub fn is_empty(&self) -> bool {
        self.length == 0
    }
}

/// A section of envelope data for rendering
#[derive(Debug, Clone)]
pub struct EnvelopeSection {
    /// Start sample number (in original sample space)
    pub start: u64,
    /// Scale factor (1 envelope sample = scale original samples)
    pub scale: u32,
    /// Number of envelope samples in this section
    pub length: u64,
    /// The envelope samples
    pub samples: Vec<EnvelopeSample>,
}
