// Protocol Parser Trait - 协议解析器统一接口
// 所有协议解析器必须实现此 trait

use std::collections::HashMap;

/// 解析结果
#[derive(Debug, Clone, serde::Serialize)]
pub struct ParseResult {
    /// 通道数据（解析后的数值）
    pub channels: Vec<f64>,
    /// 原始文本（用于显示）
    pub raw_text: Option<String>,
    /// 元数据（协议特定信息，如Modbus寄存器地址等）
    pub metadata: HashMap<String, String>,
    /// 是否成功解析
    pub success: bool,
    /// 错误信息（解析失败时）
    pub error: Option<String>,
}

impl ParseResult {
    /// 创建成功的解析结果
    pub fn success(channels: Vec<f64>, raw_text: Option<String>) -> Self {
        Self {
            channels,
            raw_text,
            metadata: HashMap::new(),
            success: true,
            error: None,
        }
    }

    /// 创建失败的解析结果
    pub fn failure(error: String, raw_text: Option<String>) -> Self {
        Self {
            channels: vec![],
            raw_text,
            metadata: HashMap::new(),
            success: false,
            error: Some(error),
        }
    }

    /// 添加元数据
    pub fn with_metadata(mut self, key: String, value: String) -> Self {
        self.metadata.insert(key, value);
        self
    }
}

/// 协议解析器 trait - 所有协议解析器的统一接口
pub trait ProtocolParser: Send + Sync {
    /// 解析原始数据
    ///
    /// # 参数
    /// - `data`: 原始字节数据
    ///
    /// # 返回
    /// - `ParseResult`: 解析结果，包含通道数据、原始文本、元数据等
    fn parse(&self, data: &[u8]) -> ParseResult;

    /// 解析文本数据（可选实现）
    /// 用于文本协议（如 CSV、SCPI），可以直接处理字符串
    fn parse_text(&self, text: &str) -> ParseResult {
        // 默认实现：转换为字节后调用 parse
        self.parse(text.as_bytes())
    }

    /// 协议ID（唯一标识符）
    /// 用于在注册表中查找和配置设备
    fn id(&self) -> &str;

    /// 协议名称（显示用）
    fn name(&self) -> &str;

    /// 协议描述
    fn description(&self) -> &str;

    /// 配置参数 JSON Schema（可选）
    /// 用于 UI 生成配置表单
    fn config_schema(&self) -> Option<&str> {
        None
    }

    /// 应用配置（可选）
    /// 配置格式为 JSON 字符串
    fn configure(&mut self, _config: &str) -> Result<(), String> {
        Ok(())
    }

    /// 重置解析器状态（可选）
    /// 用于清除缓冲区、重置状态等
    fn reset(&mut self) {}

    /// 是否支持文本模式
    /// 文本协议（CSV、SCPI）返回 true，二进制协议（Modbus）返回 false
    fn supports_text(&self) -> bool {
        false
    }

    /// 获取支持的通道数量（可选）
    /// 用于 UI 显示和配置验证
    fn channel_count(&self) -> Option<usize> {
        None
    }

    /// 获取通道名称列表（可选）
    /// 用于 UI 显示通道标签
    fn channel_names(&self) -> Option<Vec<String>> {
        None
    }
}

/// 协议信息（用于 UI 显示和注册表查询）
#[derive(Debug, Clone)]
pub struct ProtocolPluginInfo {
    /// 协议 ID
    pub id: String,
    /// 协议名称
    pub name: String,
    /// 协议描述
    pub description: String,
    /// 是否支持文本模式
    pub supports_text: bool,
    /// 配置 JSON Schema
    pub config_schema: Option<String>,
    /// 是否是内置协议
    pub is_builtin: bool,
    /// 插件类型（rust / wasm / lua）
    pub plugin_type: String,
}
