use crate::core::device::registry::DeviceRegistry;
use crate::core::session::debug_session::DebugSessionManager;
use crate::core::session::session_manager::SessionManager;
use crate::core::virtual_device::simulator::SimulatorManager;

/// Global panic hook — catches any panic and logs with stack trace.
/// Without this, panics on Windows desktop can silently crash with no output.
/// Uses lazy_static so it runs when first accessed, not at compile time.
fn set_panic_hook() {
    std::panic::set_hook(Box::new(|panic_info| {
        let msg = if let Some(s) = panic_info.payload().downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = panic_info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "Unknown panic".to_string()
        };

        let location = panic_info
            .location()
            .map(|loc| format!("{}:{}:{}", loc.file(), loc.line(), loc.column()))
            .unwrap_or_else(|| "<unknown>".to_string());

        // Print to stderr AND log via env_logger (which Flutter captures)
        eprintln!("[PANIC] {} at {}", msg, location);
        log::error!("[PANIC] {} at {}", msg, location);
    }));
}

// Initialize panic hook on first access of any static — safe, runs once
lazy_static::lazy_static! {
    static ref _PANIC_HOOK_INIT: () = {
        set_panic_hook();
    };
}

/// Initialize env_logger to output to console.
/// Must be called once at app startup (e.g. from RustLib.init).
/// After calling this, log::info!/warn!/error! macros will print to the debug console.
pub fn init_logger() {
    env_logger::Builder::from_default_env()
        .filter_level(log::LevelFilter::Info)
        .format_timestamp_millis()
        .init();
}

/// Call this to ensure the panic hook is installed.
/// Safe to call multiple times — the static init runs only once.
pub fn ensure_panic_hook() {
    lazy_static::initialize(&_PANIC_HOOK_INIT);
}

lazy_static::lazy_static! {
    pub static ref RT: tokio::runtime::Runtime =
        tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
}

// Ensure panic hook runs when RT is first used (first access of any static in this module)
lazy_static::lazy_static! {
    static ref _ENSURE_HOOK: () = {
        set_panic_hook();
    };
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