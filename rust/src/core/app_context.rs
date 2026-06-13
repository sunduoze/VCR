use std::fs::{File, OpenOptions};
use std::io::Write as IoWrite;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use crate::core::device::registry::DeviceRegistry;
use crate::core::session::debug_session::DebugSessionManager;
use crate::core::session::session_manager::SessionManager;
use crate::core::virtual_device::simulator::SimulatorManager;

/// Global flag to control whether file logging is enabled
static FILE_LOGGING_ENABLED: AtomicBool = AtomicBool::new(true);
/// Global log file path (can be changed at runtime)
static mut LOG_FILE_PATH: Option<String> = None;

/// A log::Log implementation that duplicates output to both stdout and a log file.
struct TeeLogger {
    file: Mutex<File>,
}

impl TeeLogger {
    fn new(log_path: &str) -> std::io::Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_path)?;
        Ok(Self {
            file: Mutex::new(file),
        })
    }
}

impl log::Log for TeeLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let ts = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
        let msg = format!("[{} {:5}] {}\n", ts, record.level(), record.args());

        // Write to stdout
        let _ = std::io::stdout().write_all(msg.as_bytes());
        let _ = std::io::stdout().flush();

        // Write to file (only if file logging is enabled)
        if FILE_LOGGING_ENABLED.load(Ordering::SeqCst) {
            if let Ok(mut f) = self.file.lock() {
                let _ = f.write_all(msg.as_bytes());
                let _ = f.flush();
            }
        }
    }

    fn flush(&self) {
        let _ = std::io::stdout().flush();
        if let Ok(mut f) = self.file.lock() {
            let _ = f.flush();
        }
    }
}

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

/// Initialize logger to output to both the debug console and a log file.
/// Log file is saved next to the executable: `vcr_debug_<timestamp>.log`
/// Each app launch creates a new log file.
/// Must be called once at app startup (e.g. from RustLib.init).
pub fn init_logger() {
    // Determine log file path next to the executable
    let log_path = if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let ts = chrono::Local::now().format("%Y%m%d_%H%M%S");
            dir.join(format!("vcr_debug_{}.log", ts))
                .to_string_lossy()
                .to_string()
        } else {
            "vcr_debug.log".to_string()
        }
    } else {
        "vcr_debug.log".to_string()
    };

    // Store the default path
    unsafe {
        LOG_FILE_PATH = Some(log_path.clone());
    }

    let tee = match TeeLogger::new(&log_path) {
        Ok(w) => {
            eprintln!("[Logger] Log file: {}", log_path);
            Box::new(w) as Box<dyn log::Log>
        }
        Err(e) => {
            eprintln!("[Logger] Failed to create log file '{}': {}", log_path, e);
            // Fall back: use env_logger (console only)
            env_logger::Builder::from_default_env()
                .filter_level(log::LevelFilter::Info)
                .format_timestamp_millis()
                .init();
            return;
        }
    };

    let max_level = log::LevelFilter::Info;
    log::set_boxed_logger(tee).expect("Failed to set logger");
    log::set_max_level(max_level);
}

/// Enable or disable file logging at runtime.
pub fn set_file_logging_enabled(enabled: bool) {
    FILE_LOGGING_ENABLED.store(enabled, Ordering::SeqCst);
    log::info!(
        "[Logger] File logging {}",
        if enabled { "enabled" } else { "disabled" }
    );
}

/// Set a custom log file path at runtime.
/// The path can be absolute or relative.
pub fn set_log_file_path(path: &str) {
    unsafe {
        LOG_FILE_PATH = Some(path.to_string());
    }
    log::info!("[Logger] Log file path changed to: {}", path);
}

/// Get the current log file path.
#[allow(static_mut_refs)]
pub fn get_log_file_path() -> String {
    unsafe {
        LOG_FILE_PATH
            .clone()
            .unwrap_or_else(|| "vcr_debug.log".to_string())
    }
}

/// Set the maximum log level at runtime.
/// Call this from Flutter via FFI to change log verbosity.
pub fn set_log_level(level: &str) {
    let filter = match level.to_lowercase().as_str() {
        "trace" => log::LevelFilter::Trace,
        "debug" => log::LevelFilter::Debug,
        "info" => log::LevelFilter::Info,
        "warn" | "warning" => log::LevelFilter::Warn,
        "error" => log::LevelFilter::Error,
        "off" => log::LevelFilter::Off,
        _ => log::LevelFilter::Info,
    };
    log::set_max_level(filter);
    log::info!("[Logger] Log level changed to: {:?}", filter);
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
