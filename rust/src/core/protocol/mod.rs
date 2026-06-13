// Protocol Module - 协议解析模块
// 提供可扩展的协议解析器插件架构

use std::sync::Arc;

// 核心模块
pub mod registry;
pub mod r#trait; // ProtocolParser trait 定义 // 协议注册表

// 内置插件
pub mod plugins;

// 保留旧模块的兼容性（已迁移到 plugins/csv.rs）
// pub mod csv_parser;

// 重新导出核心类型
pub use r#trait::{ParseResult, ProtocolParser};
pub use registry::ProtocolRegistry;

// 重新导出内置插件
pub use plugins::csv::parse_csv_line;
pub use plugins::csv::CsvParser;
pub use plugins::modbus_rtu::ModbusRtuParser;
pub use plugins::modbus_tcp::ModbusTcpParser;
pub use plugins::raw::RawParser;
pub use plugins::scpi::ScpiParser;

/// 创建默认协议注册表并注册所有内置插件
pub fn create_default_registry() -> ProtocolRegistry {
    let mut registry = ProtocolRegistry::new();

    // 注册内置插件
    registry
        .register(Arc::new(RawParser::new()), true, "rust".to_string())
        .ok();
    registry
        .register(Arc::new(CsvParser::new()), true, "rust".to_string())
        .ok();
    registry
        .register(Arc::new(ModbusRtuParser::new()), true, "rust".to_string())
        .ok();
    registry
        .register(Arc::new(ModbusTcpParser::new()), true, "rust".to_string())
        .ok();
    registry
        .register(Arc::new(ScpiParser::new()), true, "rust".to_string())
        .ok();

    registry
}

/// 初始化协议模块
/// 在应用启动时调用，注册所有内置协议解析器
pub fn init() {
    log::debug!(
        "Protocol module initialized with built-in parsers: raw, csv, modbus_rtu, modbus_tcp, scpi"
    );
}
