use crate::core::device::registry::DeviceRegistry;
use crate::core::session::debug_session::DebugSessionManager;
use crate::core::session::session_manager::SessionManager;
use crate::core::virtual_device::simulator::SimulatorManager;

lazy_static::lazy_static! {
    pub static ref RT: tokio::runtime::Runtime =
        tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
}

lazy_static::lazy_static! {
    pub static ref REGISTRY: DeviceRegistry = DeviceRegistry::new();
}

lazy_static::lazy_static! {
    pub static ref SIMULATORS: SimulatorManager = SimulatorManager::new();
}

lazy_static::lazy_static! {
    pub static ref DEBUG: DebugSessionManager = DebugSessionManager::new();
}

lazy_static::lazy_static! {
    pub static ref SESSIONS: SessionManager = SessionManager::new(&REGISTRY, &SIMULATORS);
}

pub fn block_on<F, T>(future: F) -> T
where
    F: std::future::Future<Output = T>,
{
    RT.block_on(future)
}
