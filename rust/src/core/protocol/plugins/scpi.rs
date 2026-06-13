// SCPI Protocol Parser - SCPI 协议解析
// 解析 SCPI 命令响应（如 :MEAS:VOLT? -> +1.234E+00）

use crate::core::protocol::r#trait::{ParseResult, ProtocolParser};

/// SCPI 协议解析器
/// 支持解析 SCPI 标准格式的数值响应
pub struct ScpiParser {
    /// 是否支持多值响应（逗号分隔）
    multi_value: bool,
}

impl ScpiParser {
    pub fn new() -> Self {
        Self { multi_value: true }
    }

    /// 解析单个 SCPI 数值
    /// 支持格式：
    /// - 整数：123, -456
    /// - 小数：1.234, -5.678
    /// - 科学计数法：+1.234E+00, -5.678E-03
    /// - 带单位：1.234V, 5.678mA（单位会被忽略）
    fn parse_single_value(&self, s: &str) -> Option<f64> {
        let trimmed = s.trim();

        // 移除尾部单位（如 V, mV, A, mA, Hz 等）
        let numeric_part = trimmed.trim_end_matches(|c: char| c.is_ascii_alphabetic());

        // 尝试解析数值
        numeric_part.parse::<f64>().ok()
    }

    /// 解析 SCPI 响应
    fn parse_response(&self, text: &str) -> ParseResult {
        let trimmed = text.trim();

        if trimmed.is_empty() {
            return ParseResult::failure("Empty response".to_string(), Some(trimmed.to_string()));
        }

        // SCPI 响应可能是单值或多值（逗号分隔）
        let values: Vec<f64> = if self.multi_value {
            trimmed
                .split(',')
                .filter_map(|s| self.parse_single_value(s))
                .collect()
        } else {
            self.parse_single_value(trimmed)
                .map(|v| vec![v])
                .unwrap_or_default()
        };

        if values.is_empty() {
            return ParseResult::failure("No valid values".to_string(), Some(trimmed.to_string()));
        }

        // 检测响应类型
        let response_type = if trimmed.contains(',') {
            "multi"
        } else {
            "single"
        };

        ParseResult::success(values, Some(trimmed.to_string()))
            .with_metadata("response_type".to_string(), response_type.to_string())
    }
}

impl ProtocolParser for ScpiParser {
    fn parse(&self, data: &[u8]) -> ParseResult {
        // 转换为 UTF-8 字符串
        let text = String::from_utf8_lossy(data);
        self.parse_response(&text)
    }

    fn parse_text(&self, text: &str) -> ParseResult {
        self.parse_response(text)
    }

    fn id(&self) -> &str {
        "scpi"
    }

    fn name(&self) -> &str {
        "SCPI 协议"
    }

    fn description(&self) -> &str {
        "SCPI (Standard Commands for Programmable Instruments) 仪器控制协议"
    }

    fn config_schema(&self) -> Option<&str> {
        Some(
            r#"{"type": "object", "properties": {"multi_value": {"type": "boolean", "default": true}}}"#,
        )
    }

    fn configure(&mut self, config: &str) -> Result<(), String> {
        let parsed: serde_json::Value =
            serde_json::from_str(config).map_err(|e| format!("Config parse error: {}", e))?;

        if let Some(multi) = parsed.get("multi_value").and_then(|v| v.as_bool()) {
            self.multi_value = multi;
        }

        Ok(())
    }

    fn supports_text(&self) -> bool {
        true
    }
}

impl Default for ScpiParser {
    fn default() -> Self {
        Self::new()
    }
}
