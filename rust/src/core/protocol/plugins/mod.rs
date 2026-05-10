// Protocol Plugins - 内置协议插件模块
// 包含所有内置协议解析器的实现

pub mod raw;
pub mod csv;
pub mod modbus_rtu;
pub mod modbus_tcp;
pub mod scpi;

use std::sync::Arc;
use crate::core::protocol::registry::register_global;

/// 注册所有内置协议到全局注册表
/// 在程序启动时调用一次
pub fn register_builtin_plugins() {
    // Raw 协议
    let raw_parser = Arc::new(raw::RawParser::new());
    let _ = register_global(raw_parser, true, "rust".to_string());

    // CSV 协议
    let csv_parser = Arc::new(csv::CsvParser::new());
    let _ = register_global(csv_parser, true, "rust".to_string());

    // Modbus RTU 协议
    let modbus_rtu_parser = Arc::new(modbus_rtu::ModbusRtuParser::new());
    let _ = register_global(modbus_rtu_parser, true, "rust".to_string());

    // Modbus TCP 协议
    let modbus_tcp_parser = Arc::new(modbus_tcp::ModbusTcpParser::new());
    let _ = register_global(modbus_tcp_parser, true, "rust".to_string());

    // SCPI 协议
    let scpi_parser = Arc::new(scpi::ScpiParser::new());
    let _ = register_global(scpi_parser, true, "rust".to_string());

    log::debug!("Registered 5 builtin protocol plugins");
}