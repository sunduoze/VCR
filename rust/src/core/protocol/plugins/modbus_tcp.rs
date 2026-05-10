// Modbus TCP Protocol Parser - Modbus TCP 协议解析
// 解析 Modbus TCP 响应帧，提取寄存器值

use crate::core::protocol::r#trait::{ProtocolParser, ParseResult};

/// Modbus TCP 协议解析器
/// 支持读取保持寄存器（功能码 03）和输入寄存器（功能码 04）
pub struct ModbusTcpParser {
    /// 单元标识符
    unit_id: u8,
}

impl ModbusTcpParser {
    pub fn new() -> Self {
        Self {
            unit_id: 1,
        }
    }

    /// 解析读取保持寄存器响应（功能码 03）
    fn parse_read_holding_response(&self, data: &[u8]) -> ParseResult {
        // Modbus TCP 响应帧格式：
        // [事务ID高][事务ID低][协议ID高][协议ID低][长度高][长度低][单元ID][功能码][字节数][数据...]
        // MBAP 头: 7 字节
        // 最小长度: 7 + 2 (功能码 + 字节数) + 2 (CRC) = 9 字节

        if data.len() < 9 {
            return ParseResult::failure("Frame too short".to_string(), None);
        }

        // 验证协议 ID（应为 0）
        let protocol_id = ((data[2] as u16) << 8) | (data[3] as u16);
        if protocol_id != 0 {
            return ParseResult::failure(format!("Wrong protocol ID: {}", protocol_id), None);
        }

        // 验证单元 ID
        if data[6] != self.unit_id {
            return ParseResult::failure(format!("Wrong unit ID: {}", data[6]), None);
        }

        // 功能码
        let function_code = data[7];
        if function_code != 0x03 {
            return ParseResult::failure(format!("Wrong function code: {}", function_code), None);
        }

        // 字节数
        let byte_count = data[8] as usize;

        // 检查数据长度
        if data.len() < 9 + byte_count {
            return ParseResult::failure("Incomplete data".to_string(), None);
        }

        // 提取寄存器值
        let register_data = &data[9..9 + byte_count];
        let values: Vec<f64> = register_data
            .chunks(2)
            .map(|chunk| {
                if chunk.len() == 2 {
                    // 大端序：高字节在前
                    ((chunk[0] as u16) << 8 | chunk[1] as u16) as f64
                } else {
                    chunk[0] as f64
                }
            })
            .collect();

        ParseResult::success(values, None)
            .with_metadata("unit_id".to_string(), self.unit_id.to_string())
            .with_metadata("function_code".to_string(), "03".to_string())
    }

    /// 解析错误响应
    fn parse_error_response(&self, data: &[u8]) -> ParseResult {
        if data.len() < 9 {
            return ParseResult::failure("Frame too short".to_string(), None);
        }

        let error_code = data[8];
        let error_messages = [
            (0x01, "Illegal Function"),
            (0x02, "Illegal Data Address"),
            (0x03, "Illegal Data Value"),
            (0x04, "Slave Device Failure"),
        ];

        let error_msg = error_messages
            .iter()
            .find(|(code, _)| *code == error_code)
            .map(|(_, msg)| msg)
            .map_or("Unknown Error", |v| *v);

        ParseResult::failure(format!("Modbus Error {}: {}", error_code, error_msg), None)
    }
}

impl ProtocolParser for ModbusTcpParser {
    fn parse(&self, data: &[u8]) -> ParseResult {
        if data.len() < 9 {
            return ParseResult::failure("Frame too short".to_string(), None);
        }

        // 检查功能码
        let function_code = data[7];

        match function_code {
            0x03 => self.parse_read_holding_response(data),
            0x83 => self.parse_error_response(data), // 错误响应
            _ => ParseResult::failure(format!("Unsupported function code: {}", function_code), None),
        }
    }

    fn id(&self) -> &str {
        "modbus_tcp"
    }

    fn name(&self) -> &str {
        "Modbus TCP"
    }

    fn description(&self) -> &str {
        "网络 Modbus TCP 协议，支持读取保持寄存器（功能码 03）"
    }

    fn config_schema(&self) -> Option<&str> {
        Some(r#"{"type": "object", "properties": {"unit_id": {"type": "integer", "default": 1, "minimum": 1, "maximum": 247}}}"#)
    }

    fn configure(&mut self, config: &str) -> Result<(), String> {
        let parsed: serde_json::Value = serde_json::from_str(config)
            .map_err(|e| format!("Config parse error: {}", e))?;

        if let Some(unit) = parsed.get("unit_id").and_then(|v| v.as_u64()) {
            self.unit_id = unit as u8;
        }

        Ok(())
    }

    fn supports_text(&self) -> bool {
        false
    }
}

impl Default for ModbusTcpParser {
    fn default() -> Self {
        Self::new()
    }
}