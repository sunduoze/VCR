// Protocol Registry - 协议注册表
// 管理所有协议解析器的注册、查找和列表

use std::collections::HashMap;
use std::sync::Arc;
use crate::core::protocol::r#trait::{ProtocolParser, ProtocolPluginInfo};

/// 协议注册表
/// 管理所有已注册的协议解析器
pub struct ProtocolRegistry {
    /// 解析器映射表 (protocol_id -> parser)
    parsers: HashMap<String, Arc<dyn ProtocolParser>>,
    /// 协议信息映射表 (protocol_id -> info)
    infos: HashMap<String, ProtocolPluginInfo>,
}

impl ProtocolRegistry {
    /// 创建空的注册表
    pub fn new() -> Self {
        Self {
            parsers: HashMap::new(),
            infos: HashMap::new(),
        }
    }

    /// 创建并初始化注册表（注册内置协议）
    pub fn with_builtin_plugins() -> Self {
        let registry = Self::new();
        // 内置协议将在plugins模块中注册
        // 这里只创建空的注册表，由外部调用 register_builtin_plugins
        registry
    }

    /// 注册协议解析器
    /// 
    /// # 参数
    /// - `parser`: 协议解析器实例
    /// - `is_builtin`: 是否是内置协议
    /// - `plugin_type`: 插件类型 (rust / wasm / lua)
    /// 
    /// # 返回
    /// - `Ok(())`: 注册成功
    /// - `Err(String)`: 注册失败（ID已存在）
    pub fn register(
        &mut self,
        parser: Arc<dyn ProtocolParser>,
        is_builtin: bool,
        plugin_type: String,
    ) -> Result<(), String> {
        let id = parser.id().to_string();
        
        if self.parsers.contains_key(&id) {
            return Err(format!("Protocol '{}' already registered", id));
        }

        // 创建协议信息
        let info = ProtocolPluginInfo {
            id: id.clone(),
            name: parser.name().to_string(),
            description: parser.description().to_string(),
            supports_text: parser.supports_text(),
            config_schema: parser.config_schema().map(|s| s.to_string()),
            is_builtin,
            plugin_type,
        };

        self.parsers.insert(id.clone(), parser);
        self.infos.insert(id, info);

        Ok(())
    }

    /// 注销协议解析器
    /// 
    /// # 参数
    /// - `id`: 协议ID
    /// 
    /// # 返回
    /// - `Ok(())`: 注销成功
    /// - `Err(String)`: 注销失败（ID不存在）
    pub fn unregister(&mut self, id: &str) -> Result<(), String> {
        if !self.parsers.contains_key(id) {
            return Err(format!("Protocol '{}' not found", id));
        }

        self.parsers.remove(id);
        self.infos.remove(id);

        Ok(())
    }

    /// 获取协议解析器
    /// 
    /// # 参数
    /// - `id`: 协议ID
    /// 
    /// # 返回
    /// - `Some(&dyn ProtocolParser)`: 找到的解析器
    /// - `None`: 未找到
    pub fn get(&self, id: &str) -> Option<&dyn ProtocolParser> {
        self.parsers.get(id).map(|p| p.as_ref())
    }

    /// 获取协议解析器（Arc引用）
    /// 用于需要所有权的情况
    pub fn get_arc(&self, id: &str) -> Option<Arc<dyn ProtocolParser>> {
        self.parsers.get(id).cloned()
    }

    /// 获取协议信息
    /// 
    /// # 参数
    /// - `id`: 协议ID
    /// 
    /// # 返回
    /// - `Some(&ProtocolPluginInfo)`: 找到的协议信息
    /// - `None`: 未找到
    pub fn get_info(&self, id: &str) -> Option<&ProtocolPluginInfo> {
        self.infos.get(id)
    }

    /// 获取所有协议信息列表
    /// 用于 UI 显示协议选择列表
    pub fn list(&self) -> Vec<ProtocolPluginInfo> {
        self.infos.values().cloned().collect()
    }

    /// 获取所有协议ID列表
    pub fn list_ids(&self) -> Vec<String> {
        self.parsers.keys().cloned().collect()
    }

    /// 获取内置协议列表
    pub fn list_builtin(&self) -> Vec<ProtocolPluginInfo> {
        self.infos
            .values()
            .filter(|info| info.is_builtin)
            .cloned()
            .collect()
    }

    /// 获取插件协议列表（非内置）
    pub fn list_plugins(&self) -> Vec<ProtocolPluginInfo> {
        self.infos
            .values()
            .filter(|info| !info.is_builtin)
            .cloned()
            .collect()
    }

    /// 检查协议是否已注册
    pub fn contains(&self, id: &str) -> bool {
        self.parsers.contains_key(id)
    }

    /// 获取已注册协议数量
    pub fn count(&self) -> usize {
        self.parsers.len()
    }

    /// 清空注册表
    pub fn clear(&mut self) {
        self.parsers.clear();
        self.infos.clear();
    }
}

impl Default for ProtocolRegistry {
    fn default() -> Self {
        Self::new()
    }
}

// 全局注册表实例（懒加载）
use std::sync::OnceLock;
use std::sync::RwLock;

static GLOBAL_REGISTRY: OnceLock<RwLock<ProtocolRegistry>> = OnceLock::new();

/// 获取全局注册表实例
pub fn global_registry() -> &'static RwLock<ProtocolRegistry> {
    GLOBAL_REGISTRY.get_or_init(|| RwLock::new(ProtocolRegistry::new()))
}

/// 注册协议到全局注册表
pub fn register_global(
    parser: Arc<dyn ProtocolParser>,
    is_builtin: bool,
    plugin_type: String,
) -> Result<(), String> {
    let registry = global_registry();
    let mut registry = registry.write().map_err(|e| format!("Lock error: {}", e))?;
    registry.register(parser, is_builtin, plugin_type)
}

/// 从全局注册表获取协议解析器
pub fn get_global(id: &str) -> Option<Arc<dyn ProtocolParser>> {
    let registry = global_registry();
    let registry = registry.read().ok()?;
    registry.get_arc(id)
}

/// 获取全局注册表的所有协议信息
pub fn list_global() -> Vec<ProtocolPluginInfo> {
    let registry = global_registry();
    match registry.read() {
        Ok(r) => r.list(),
        Err(_) => vec![],
    }
}