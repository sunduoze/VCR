// Raw Protocol Parser - 原始数据协议
// 无协议封装，直接返回原始数据

use crate::core::protocol::r#trait::{ProtocolParser, ParseResult};

/// Raw 协议解析器
/// 不进行任何解析，直接返回原始字节作为文本
pub struct RawParser {}

impl RawParser {
    pub fn new() -> Self {
        Self {}
    }
}

impl ProtocolParser for RawParser {
    fn parse(&self, data: &[u8]) -> ParseResult {
        // 尝试转换为 UTF-8 字符串
        let raw_text = String::from_utf8_lossy(data).to_string();
        
        ParseResult::success(vec![], Some(raw_text))
            .with_metadata("bytes".to_string(), data.len().to_string())
    }

    fn id(&self) -> &str {
        "raw"
    }

    fn name(&self) -> &str {
        "Raw / 无协议"
    }

    fn description(&self) -> &str {
        "原始数据流，无协议封装，直接显示原始字节"
    }

    fn supports_text(&self) -> bool {
        true
    }
}

impl Default for RawParser {
    fn default() -> Self {
        Self::new()
    }
}