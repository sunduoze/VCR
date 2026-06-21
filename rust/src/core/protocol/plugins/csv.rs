// CSV Protocol Parser - CSV格式数据解析
// 解析格式: "<prefix>:ch0,ch1,ch2,...,chN\n"
// - prefix 和冒号可以省略
// - 冒号可以用等号替代
// - 逗号可以用空格替代
// - 支持 \n, \r\n, \n\r 行结束符

use crate::core::protocol::r#trait::{ParseResult, ProtocolParser};

/// CSV 协议解析器配置
#[derive(Debug, Clone, serde::Deserialize)]
pub struct CsvConfig {
    /// 是否要求前缀
    pub require_prefix: bool,
    /// 允许的前缀列表（空表示任意前缀）
    pub allowed_prefixes: Vec<String>,
    /// 分隔符（逗号或空格）
    pub delimiter: String,
    /// 是否忽略 "image" 前缀
    pub ignore_image: bool,
}

impl Default for CsvConfig {
    fn default() -> Self {
        Self {
            require_prefix: false,
            allowed_prefixes: vec![],
            delimiter: ",".to_string(),
            ignore_image: true,
        }
    }
}

/// CSV 协议解析器
pub struct CsvParser {
    /// 配置
    config: CsvConfig,
    /// 缓冲区（用于处理不完整的行）
    buffer: String,
}

impl CsvParser {
    pub fn new() -> Self {
        Self {
            config: CsvConfig::default(),
            buffer: String::new(),
        }
    }

    /// 创建带配置的解析器
    pub fn with_config(config: CsvConfig) -> Self {
        Self {
            config,
            buffer: String::new(),
        }
    }

    /// 解析单行 CSV 数据
    fn parse_line(&self, line: &str) -> ParseResult {
        let trimmed = line.trim();

        if trimmed.is_empty() {
            return ParseResult::failure("Empty line".to_string(), Some(trimmed.to_string()));
        }

        // 检查是否忽略 image 前缀
        if self.config.ignore_image
            && (trimmed.starts_with("image:") || trimmed.starts_with("image="))
        {
            return ParseResult::failure(
                "Image prefix reserved".to_string(),
                Some(trimmed.to_string()),
            )
            .with_metadata("prefix".to_string(), "image".to_string());
        }

        // 查找分隔符(: 或 =)
        let (prefix, data_part) = if let Some(pos) = trimmed.find(':') {
            (Some(trimmed[..pos].to_string()), &trimmed[pos + 1..])
        } else if let Some(pos) = trimmed.find('=') {
            (Some(trimmed[..pos].to_string()), &trimmed[pos + 1..])
        } else {
            (None, trimmed)
        };

        // 检查前缀要求
        if self.config.require_prefix && prefix.is_none() {
            return ParseResult::failure("Prefix required".to_string(), Some(trimmed.to_string()));
        }

        // 检查允许的前缀列表
        if !self.config.allowed_prefixes.is_empty() {
            if let Some(ref p) = prefix {
                if !self.config.allowed_prefixes.contains(p) {
                    return ParseResult::failure(
                        format!("Prefix '{}' not allowed", p),
                        Some(trimmed.to_string()),
                    );
                }
            }
        }

        // 解析数值：按逗号或空格分割
        let values: Vec<f64> = data_part
            .split([',', ' '])
            .filter_map(|s| s.trim().parse::<f64>().ok())
            .collect();

        if values.is_empty() {
            return ParseResult::failure("No valid values".to_string(), Some(trimmed.to_string()));
        }

        // 构建结果
        let mut result = ParseResult::success(values, Some(trimmed.to_string()));

        if let Some(ref p) = prefix {
            result = result.with_metadata("prefix".to_string(), p.clone());
        }

        result
    }

    /// 处理字节流，返回所有完整行的解析结果
    ///
    /// 热路径优化：使用 &str 字节级索引代替 Vec<char> 全集收集，
    /// 消除 O(n) char 分配和 per-line String 分配。
    /// \n/\r 为单字节 ASCII，在 UTF-8 中不会出现在多字节字符尾部，
    /// 因此字节级索引始终落在字符边界上。
    pub fn parse_bytes_stream(&mut self, data: &[u8]) -> Vec<ParseResult> {
        // ── Step 1: Append new data to buffer ──
        let text = String::from_utf8_lossy(data);
        self.buffer.push_str(&text);

        // Typical: 1-8 lines per batch in 100ms receive window
        let mut results = Vec::with_capacity(8);
        let buf = self.buffer.as_str();
        let buf_bytes = buf.as_bytes();
        let mut pos = 0;
        let max = buf_bytes.len();

        while pos < max {
            // ── Scan rest for line ending (byte-level, safe because \n/\r are ASCII) ──
            let rest = &buf_bytes[pos..];
            let line_end = rest.iter().position(|&b| b == b'\n' || b == b'\r');

            match line_end {
                Some(offset) => {
                    let end = pos + offset;
                    // Safety: pos and end are both on ASCII byte boundaries,
                    // which are always valid char boundaries in UTF-8.
                    let line = &buf[pos..end];
                    let parsed = self.parse_line(line);
                    if parsed.success || parsed.error.is_some() {
                        results.push(parsed);
                    }

                    // ── Skip line terminator(s) ──
                    pos = end + 1;
                    // Handle \r\n or \n\r
                    if pos < max {
                        let prev = buf_bytes[pos - 1];
                        let next = buf_bytes[pos];
                        if (prev == b'\r' && next == b'\n')
                            || (prev == b'\n' && next == b'\r')
                        {
                            pos += 1;
                        }
                    }
                }
                None => break,
            }
        }

        // ── Drain processed portion, keep incomplete tail ──
        self.buffer.drain(..pos);

        results
    }

    /// 兼容性方法：解析多行 CSV 数据
    /// 返回每行的通道值数组
    pub fn parse_bytes(&mut self, data: &[u8]) -> Vec<Vec<f64>> {
        let results = self.parse_bytes_stream(data);
        results
            .into_iter()
            .filter(|r| r.success)
            .map(|r| r.channels)
            .collect()
    }
}

impl ProtocolParser for CsvParser {
    fn parse(&self, data: &[u8]) -> ParseResult {
        // 对于单次解析，直接处理（不使用缓冲区）
        let text = String::from_utf8_lossy(data);

        // 查找第一个行结束符
        let line_end = text.find(['\n', '\r']);
        let line = if let Some(pos) = line_end {
            &text[..pos]
        } else {
            text.trim_end_matches('\r')
        };

        self.parse_line(line)
    }

    fn parse_text(&self, text: &str) -> ParseResult {
        let line_end = text.find(['\n', '\r']);
        let line = if let Some(pos) = line_end {
            &text[..pos]
        } else {
            text.trim_end_matches('\r')
        };

        self.parse_line(line)
    }

    fn id(&self) -> &str {
        "csv"
    }

    fn name(&self) -> &str {
        "CSV / 自定义协议"
    }

    fn description(&self) -> &str {
        "CSV格式数据解析，支持自定义前缀，格式：<prefix>:value1,value2,..."
    }

    fn config_schema(&self) -> Option<&str> {
        Some(
            r#"{"type": "object", "properties": {"require_prefix": {"type": "boolean", "default": false}, "allowed_prefixes": {"type": "array", "items": {"type": "string"}}, "delimiter": {"type": "string", "default": ","}, "ignore_image": {"type": "boolean", "default": true}}}"#,
        )
    }

    fn configure(&mut self, config: &str) -> Result<(), String> {
        // 解析 JSON 配置
        let parsed: CsvConfig =
            serde_json::from_str(config).map_err(|e| format!("Config parse error: {}", e))?;
        self.config = parsed;
        Ok(())
    }

    fn reset(&mut self) {
        self.buffer.clear();
    }

    fn supports_text(&self) -> bool {
        true
    }
}

impl Default for CsvParser {
    fn default() -> Self {
        Self::new()
    }
}

/// 兼容性函数：解析单行 CSV 数据
/// 用于 device_api.rs 等旧代码
pub fn parse_csv_line(line: &str) -> ParseResult {
    let parser = CsvParser::new();
    parser.parse_text(line)
}
