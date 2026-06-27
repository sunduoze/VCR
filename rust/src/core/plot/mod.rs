pub mod analog_segment;
pub mod constants;
pub mod data_buffer;
pub mod envelope;
pub mod ffi_bridge;
#[cfg(feature = "lockfree")]
pub mod lockfree_buffer;
pub mod lttb;
pub mod pipeline;
pub mod segment;
pub mod time_bucket;

pub use analog_segment::AnalogSegment;
pub use constants::{ENVELOPE_SCALE_FACTOR, ENVELOPE_SCALE_POWER, LN_ENVELOPE_SCALE_FACTOR, SCALE_STEP_COUNT};
pub use data_buffer::{ChannelBuffer, DataPoint, PlotDataManager, PLOT_DATA};
pub use envelope::{EnvelopeLayer, EnvelopeSample, EnvelopeSection};
#[cfg(feature = "lockfree")]
pub use lockfree_buffer::{LockFreeRingBuffer, RingDataPoint};
pub use lttb::{lttb_downsample, minmax_downsample};
pub use segment::SegmentStorage;
pub use time_bucket::{BucketStats, TimeBucket, TimeBucketPyramid};
