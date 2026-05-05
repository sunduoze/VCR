// Minimal placeholder — main logic lives in device_api/debug_api/plot_api
use flutter_rust_bridge::frb;

#[frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}
