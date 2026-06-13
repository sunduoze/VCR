// Modbus RTU Protocol Parser - Modbus RTU 协议解析
// 解析 Modbus RTU 响应帧，提取寄存器值

use crate::core::protocol::r#trait::{ParseResult, ProtocolParser};
use std::collections::HashMap;

/// Modbus RTU 协议解析器
/// 支持读取保持寄存器（功能码 03）和输入寄存器（功能码 04）
pub struct ModbusRtuParser {
    /// 从站地址
    slave_address: u8,
    /// 是否验证 CRC
    verify_crc: bool,
}

impl ModbusRtuParser {
    pub fn new() -> Self {
        Self {
            slave_address: 1,
            verify_crc: true,
        }
    }

    /// 计算 CRC16
    fn calculate_crc(data: &[u8]) -> u16 {
        let mut crc = 0xFFFF;
        for byte in data {
            crc ^= *byte as u16;
            for _ in 0..8 {
                if crc & 0x0001 != 0 {
                    crc >>= 1;
                    crc ^= 0xA001;
                } else {
                    crc >>= 1;
                }
            }
        }
        crc
    }

    /// 解析读取保持寄存器响应（功能码 03）
    fn parse_read_holding_response(&self, data: &[u8]) -> ParseResult {
        // Modbus RTU 响应帧格式：
        // [地址][功能码][字节数][数据...][CRC低][CRC高]
        // 最小长度: 地址(1) + 功能码(1) + 字节数(1) + CRC(2) = 5 字节

        if data.len() < 5 {
            return ParseResult::failure("Frame too short".to_string(), None);
        }

        // 验证地址
        if data[0] != self.slave_address {
            return ParseResult::failure(format!("Wrong slave address: {}", data[0]), None);
        }

        // 验证功能码
        if data[1] != 0x03 {
            return ParseResult::failure(format!("Wrong function code: {}", data[1]), None);
        }

        // 字节数
        let byte_count = data[2] as usize;

        // 检查数据长度
        if data.len() < 3 + byte_count + 2 {
            return ParseResult::failure("Incomplete data".to_string(), None);
        }

        // 提取寄存器值
        let register_data = &data[3..3 + byte_count];
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

        // 验证 CRC
        if self.verify_crc {
            let crc_data = &data[..data.len() - 2];
            let received_crc = (data[data.len() - 1] as u16) << 8 | data[data.len() - 2] as u16;
            let calculated_crc = Self::calculate_crc(crc_data);

            if received_crc != calculated_crc {
                return ParseResult::failure(
                    format!(
                        "CRC mismatch: received {}, calculated {}",
                        received_crc, calculated_crc
                    ),
                    None,
                );
            }
        }

        // 构建元数据
        let mut metadata = HashMap::new();
        metadata.insert("slave_address".to_string(), self.slave_address.to_string());
        metadata.insert("function_code".to_string(), "03".to_string());
        metadata.insert("register_count".to_string(), (byte_count / 2).to_string());

        ParseResult::success(values, None)
            .with_metadata("slave_address".to_string(), self.slave_address.to_string())
            .with_metadata("function_code".to_string(), "03".to_string())
    }

    /// 解析错误响应
    fn parse_error_response(&self, data: &[u8]) -> ParseResult {
        if data.len() < 5 {
            return ParseResult::failure("Frame too short".to_string(), None);
        }

        let error_code = data[2];
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

impl ProtocolParser for ModbusRtuParser {
    fn parse(&self, data: &[u8]) -> ParseResult {
        if data.len() < 5 {
            return ParseResult::failure("Frame too short".to_string(), None);
        }

        // 检查功能码
        let function_code = data[1];

        match function_code {
            0x03 => self.parse_read_holding_response(data),
            0x83 => self.parse_error_response(data), // 错误响应
            _ => ParseResult::failure(
                format!("Unsupported function code: {}", function_code),
                None,
            ),
        }
    }

    fn id(&self) -> &str {
        "modbus_rtu"
    }

    fn name(&self) -> &str {
        "Modbus RTU"
    }

    fn description(&self) -> &str {
        "串口 Modbus RTU 协议，支持读取保持寄存器（功能码 03）"
    }

    fn config_schema(&self) -> Option<&str> {
        Some(
            r#"{"type": "object", "properties": {"slave_address": {"type": "integer", "default": 1, "minimum": 1, "maximum": 247}, "verify_crc": {"type": "boolean", "default": true}}}"#,
        )
    }

    fn configure(&mut self, config: &str) -> Result<(), String> {
        let parsed: serde_json::Value =
            serde_json::from_str(config).map_err(|e| format!("Config parse error: {}", e))?;

        if let Some(addr) = parsed.get("slave_address").and_then(|v| v.as_u64()) {
            self.slave_address = addr as u8;
        }

        if let Some(verify) = parsed.get("verify_crc").and_then(|v| v.as_bool()) {
            self.verify_crc = verify;
        }

        Ok(())
    }

    fn supports_text(&self) -> bool {
        false
    }
}

impl Default for ModbusRtuParser {
    fn default() -> Self {
        Self::new()
    }
}
