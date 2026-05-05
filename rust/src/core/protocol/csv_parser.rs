// CSV Protocol Parser
// Parses data format: "<any>:ch0,ch1,ch2,...,chN\n"
// - any and colon can be omitted, but newline is required
// - "any" cannot be "image" (reserved for image data)
// - ":" can be replaced with "="
// - "," can be replaced with " " (space)
// - \n can be \n\r or \r\n



/// Parsed CSV channel data
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CsvParseResult {
    /// Optional prefix before colon (e.g., "channels")
    pub prefix: Option<String>,
    /// Channel values in order
    pub values: Vec<f64>,
    /// Whether parsing was successful
    pub success: bool,
}

/// Parse a CSV protocol line into channel values
pub fn parse_csv_line(line: &str) -> CsvParseResult {
    let trimmed = line.trim();
    
    // Must end with newline indicator (caller should already have stripped it)
    if trimmed.is_empty() {
        return CsvParseResult {
            prefix: None,
            values: vec![],
            success: false,
        };
    }
    
    // Check for reserved "image" prefix
    if trimmed.starts_with("image:") || trimmed.starts_with("image=") {
        return CsvParseResult {
            prefix: Some("image".into()),
            values: vec![],
            success: false,
        };
    }
    
    // Find delimiter (: or =)
    let (prefix, data_part) = if let Some(pos) = trimmed.find(':') {
        (Some(trimmed[..pos].to_string()), &trimmed[pos + 1..])
    } else if let Some(pos) = trimmed.find('=') {
        (Some(trimmed[..pos].to_string()), &trimmed[pos + 1..])
    } else {
        (None, trimmed)
    };
    
    // Parse values: split by , or space
    let values: Vec<f64> = data_part
        .split(|c| c == ',' || c == ' ')
        .filter_map(|s| s.trim().parse::<f64>().ok())
        .collect();
    
    if values.is_empty() {
        return CsvParseResult {
            prefix,
            values: vec![],
            success: false,
        };
    }
    
    CsvParseResult {
        prefix,
        values,
        success: true,
    }
}

/// Protocol parser trait for extensibility
pub trait ProtocolParser: Send + Sync {
    /// Parse raw bytes into channel values
    fn parse(&self, data: &[u8]) -> Vec<f64>;
    
    /// Get parser name
    fn name(&self) -> &str;
}

/// CSV Protocol Parser implementation
pub struct CsvParser {
    /// Buffer for incomplete lines
    buffer: String,
}

impl CsvParser {
    pub fn new() -> Self {
        Self {
            buffer: String::new(),
        }
    }
    
    /// Parse incoming bytes and return complete channel data sets
    pub fn parse_bytes(&mut self, data: &[u8]) -> Vec<Vec<f64>> {
        // Convert to string (assuming UTF-8, could add GBK support later)
        let text = String::from_utf8_lossy(data);
        self.buffer.push_str(&text);
        
        let mut results = Vec::new();
        
        // Split by newlines (\n, \r\n, or \n\r)
        let mut start = 0;
        let mut end = 0;
        let chars: Vec<char> = self.buffer.chars().collect();
        
        while end < chars.len() {
            if chars[end] == '\n' || chars[end] == '\r' {
                // Found line ending
                let line: String = chars[start..end].iter().collect();
                let parsed = parse_csv_line(&line);
                if parsed.success {
                    results.push(parsed.values);
                }
                
                // Skip the newline character(s)
                end += 1;
                if end < chars.len() {
                    if (chars[end - 1] == '\r' && chars[end] == '\n') ||
                       (chars[end - 1] == '\n' && chars[end] == '\r') {
                        end += 1;
                    }
                }
                start = end;
            } else {
                end += 1;
            }
        }
        
        // Keep remaining incomplete line in buffer
        self.buffer = chars[start..].iter().collect();
        
        results
    }
    
    /// Clear the buffer
    pub fn reset(&mut self) {
        self.buffer.clear();
    }
}

/// Protocol parser factory
pub fn create_parser(protocol_name: &str) -> Box<dyn ProtocolParser> {
    match protocol_name.to_lowercase().as_str() {
        "csv" => Box::new(CsvParserWrapper::new()),
        _ => Box::new(CsvParserWrapper::new()), // Default to CSV
    }
}

/// Wrapper to implement ProtocolParser trait
struct CsvParserWrapper {
    parser: CsvParser,
}

impl CsvParserWrapper {
    fn new() -> Self {
        Self {
            parser: CsvParser::new(),
        }
    }
}

impl ProtocolParser for CsvParserWrapper {
    fn parse(&self, data: &[u8]) -> Vec<f64> {
        // For trait compatibility, return first parsed line's values
        let mut parser = CsvParser::new();
        let results = parser.parse_bytes(data);
        results.first().cloned().unwrap_or_default()
    }
    
    fn name(&self) -> &str {
        "CSV"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_parse_csv_line_with_prefix() {
        let result = parse_csv_line("channels: 1.386578,0.977929,-0.628913,-0.942729");
        assert!(result.success);
        assert_eq!(result.prefix, Some("channels".into()));
        assert_eq!(result.values.len(), 4);
        assert!((result.values[0] - 1.386578).abs() < 0.0001);
    }
    
    #[test]
    fn test_parse_csv_line_no_prefix() {
        let result = parse_csv_line("1.386578,0.977929,-0.628913");
        assert!(result.success);
        assert_eq!(result.prefix, None);
        assert_eq!(result.values.len(), 3);
    }
    
    #[test]
    fn test_parse_csv_line_equals_delimiter() {
        let result = parse_csv_line("data=1.0 2.0 3.0");
        assert!(result.success);
        assert_eq!(result.prefix, Some("data".into()));
        assert_eq!(result.values.len(), 3);
    }
    
    #[test]
    fn test_parse_csv_line_image_prefix_rejected() {
        let result = parse_csv_line("image:base64data");
        assert!(!result.success);
        assert_eq!(result.prefix, Some("image".into()));
    }
    
    #[test]
    fn test_csv_parser_bytes() {
        let mut parser = CsvParser::new();
        let results = parser.parse_bytes(b"1.0,2.0,3.0\n4.0,5.0,6.0\n");
        assert_eq!(results.len(), 2);
        assert_eq!(results[0], vec![1.0, 2.0, 3.0]);
        assert_eq!(results[1], vec![4.0, 5.0, 6.0]);
    }
}
