use crate::core::app_context::{block_on, SIMULATORS};
use crate::core::virtual_device::simulator::VirtualInfraStatus;

// ============================================================================
// 虚拟基础设施控制
// ============================================================================

#[flutter_rust_bridge::frb(sync)]
pub fn start_virtual_infrastructure() -> VirtualInfraStatus {
    block_on(SIMULATORS.start_all())
}

#[flutter_rust_bridge::frb(sync)]
pub fn stop_virtual_infrastructure() -> bool {
    block_on(SIMULATORS.stop_all());
    true
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_virtual_infra_status() -> VirtualInfraStatus {
    block_on(SIMULATORS.status())
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_virtual_serial_running() -> bool {
    block_on(SIMULATORS.is_serial_pair_running())
}
