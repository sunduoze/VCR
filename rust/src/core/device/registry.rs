use crate::core::device::models::{DeviceConfig, DeviceInfo, DeviceStatus, Protocol};
use parking_lot::RwLock;
use std::collections::HashMap;
use uuid::Uuid;

/// 设备注册表 —— 纯数据 CRUD，不含连接逻辑
pub struct DeviceRegistry {
    devices: RwLock<HashMap<String, DeviceInfo>>,
}

impl DeviceRegistry {
    pub fn new() -> Self {
        Self {
            devices: RwLock::new(HashMap::new()),
        }
    }

    /// 添加设备，返回生成的 ID
    pub fn add(&self, config: DeviceConfig) -> String {
        let id = Uuid::new_v4().to_string();
        let info = DeviceInfo::from_config(id.clone(), config);
        self.devices.write().insert(id.clone(), info);
        id
    }

    /// 添加设备（使用固定 ID，如虚拟设备）
    pub fn add_with_id(&self, id: String, config: DeviceConfig) {
        let info = DeviceInfo::from_config(id.clone(), config);
        self.devices.write().insert(id, info);
    }

    pub fn remove(&self, device_id: &str) -> bool {
        self.devices.write().remove(device_id).is_some()
    }

    pub fn get(&self, device_id: &str) -> Option<DeviceInfo> {
        self.devices.read().get(device_id).cloned()
    }

    pub fn exists(&self, device_id: &str) -> bool {
        self.devices.read().contains_key(device_id)
    }

    pub fn all(&self) -> Vec<DeviceInfo> {
        self.devices.read().values().cloned().collect()
    }

    /// 更新设备配置（名称、地址、协议）
    pub fn update(
        &self,
        device_id: &str,
        name: String,
        address: String,
        protocol: Protocol,
    ) -> bool {
        if let Some(d) = self.devices.write().get_mut(device_id) {
            d.name = name;
            d.address = address;
            d.protocol = protocol;
            true
        } else {
            false
        }
    }

    pub fn update_status(&self, device_id: &str, status: DeviceStatus) {
        if let Some(d) = self.devices.write().get_mut(device_id) {
            d.status = status;
            if status == DeviceStatus::Connected {
                d.last_seen = Some(chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string());
            }
        }
    }

    pub fn set_error(&self, device_id: &str, msg: String) {
        if let Some(d) = self.devices.write().get_mut(device_id) {
            d.status = DeviceStatus::Error;
            d.error_message = Some(msg);
        }
    }

    pub fn clear_error(&self, device_id: &str) {
        if let Some(d) = self.devices.write().get_mut(device_id) {
            d.error_message = None;
        }
    }
}

impl Default for DeviceRegistry {
    fn default() -> Self {
        Self::new()
    }
}
