use crate::core::device::models::{ConnectionType, DeviceStatus};
use crate::core::device::registry::DeviceRegistry;
use crate::core::transport::serial::{SerialConfig, SerialTransport};
use crate::core::transport::tcp::{TcpConfig, TcpTransport};
use crate::core::transport::virtual_channel::VirtualChannelTransport;
use crate::core::transport::{Transport, TransportError};
use crate::core::virtual_device::simulator::SimulatorManager;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};

/// 活动会话（包装 Transport trait object，内部加 Mutex 实现并发收发）
pub enum ActiveSession {
    Serial(Arc<Mutex<SerialTransport>>),
    Tcp(Arc<Mutex<TcpTransport>>),
    Virtual(Arc<Mutex<VirtualChannelTransport>>),
}

/// Windows raw HANDLE stored separately for lock-free DTR/RTS/Break control
#[cfg(target_os = "windows")]
use crate::core::transport::serial::SafeHandle;

/// 会话管理器 —— 统一管理所有设备连接
///
/// 职责：
/// - 根据 DeviceInfo 的 connection_type + is_virtual 选择正确的 Transport
/// - 管理连接池（增删查改）
/// - 提供统一的 send / receive 接口（并发安全）
pub struct SessionManager {
    sessions: RwLock<HashMap<String, ActiveSession>>,
    /// Windows raw HANDLEs for lock-free DTR/RTS/Break control
    #[cfg(target_os = "windows")]
    serial_handles: RwLock<HashMap<String, SafeHandle>>,
    registry: &'static DeviceRegistry,
    simulators: &'static SimulatorManager,
}

impl SessionManager {
    pub fn new(registry: &'static DeviceRegistry, simulators: &'static SimulatorManager) -> Self {
        Self {
            sessions: RwLock::new(HashMap::new()),
            #[cfg(target_os = "windows")]
            serial_handles: RwLock::new(HashMap::new()),
            registry,
            simulators,
        }
    }

    /// 连接设备
    pub async fn connect(&self, device_id: &str) -> Result<(), TransportError> {
        let device = self
            .registry
            .get(device_id)
            .ok_or_else(|| TransportError::InvalidConfig("Device not found".into()))?;

        self.registry
            .update_status(device_id, DeviceStatus::Connecting);

        let session = if device.is_virtual {
            self.connect_virtual(&device).await?
        } else {
            self.connect_real(&device).await?
        };

        self.sessions
            .write()
            .await
            .insert(device_id.to_string(), session);
        #[cfg(target_os = "windows")]
        {
            // Store raw HANDLE for lock-free DTR/RTS/Break control
            if let Some(handle) = self._get_serial_handle(device_id).await {
                self.serial_handles
                    .write()
                    .await
                    .insert(device_id.to_string(), handle);
            }
        }
        self.registry
            .update_status(device_id, DeviceStatus::Connected);
        Ok(())
    }

    fn connect_virtual(
        &self,
        device: &crate::core::device::models::DeviceInfo,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<ActiveSession, TransportError>> + Send + '_>,
    > {
        let device = device.clone();
        Box::pin(async move {
            match device.connection_type {
                ConnectionType::Tcp => {
                    let parts: Vec<&str> = device.address.split(':').collect();
                    if parts.len() < 2 {
                        return Err(TransportError::InvalidConfig("Invalid TCP address".into()));
                    }
                    let host = parts[0].to_string();
                    let port = parts[1]
                        .parse::<u16>()
                        .map_err(|_| TransportError::InvalidConfig("Invalid port".into()))?;

                    let mut transport = TcpTransport::new(TcpConfig {
                        host,
                        port,
                        ..Default::default()
                    });
                    transport.connect().await?;
                    Ok(ActiveSession::Tcp(Arc::new(Mutex::new(transport))))
                }
                ConnectionType::Serial => {
                    // 虚拟串口：从 SimulatorManager 获取 channel pair
                    let handle = self
                        .simulators
                        .create_serial_connection()
                        .await
                        .ok_or_else(|| {
                            TransportError::ConnectionFailed(
                                "Virtual serial not running. Start infrastructure first.".into(),
                            )
                        })?;

                    let mut transport =
                        VirtualChannelTransport::new(handle.cmd_tx, handle.response_rx);
                    transport.connect().await?;
                    Ok(ActiveSession::Virtual(Arc::new(Mutex::new(transport))))
                }
                _ => Err(TransportError::InvalidConfig(format!(
                    "Unsupported virtual connection type: {:?}",
                    device.connection_type
                ))),
            }
        })
    }

    fn connect_real(
        &self,
        device: &crate::core::device::models::DeviceInfo,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<ActiveSession, TransportError>> + Send + '_>,
    > {
        let device = device.clone();
        Box::pin(async move {
            match device.connection_type {
                ConnectionType::Serial => {
                    let parts: Vec<&str> = device.address.split(':').collect();
                    if parts.len() < 2 {
                        return Err(TransportError::InvalidConfig(
                            "Invalid serial address".into(),
                        ));
                    }
                    let port = parts[0].to_string();
                    let baud_rate = parts[1]
                        .parse::<u32>()
                        .map_err(|_| TransportError::InvalidConfig("Invalid baud rate".into()))?;
                    // Parse optional serial config: port:baudRate:dataBits:stopBits:parity:flowControl
                    let data_bits = parts
                        .get(2)
                        .map(|s| match *s {
                            "5" => crate::core::device::models::DataBits::Five,
                            "6" => crate::core::device::models::DataBits::Six,
                            "7" => crate::core::device::models::DataBits::Seven,
                            _ => crate::core::device::models::DataBits::Eight,
                        })
                        .unwrap_or(crate::core::device::models::DataBits::Eight);
                    let stop_bits = parts
                        .get(3)
                        .map(|s| match *s {
                            "2" => crate::core::device::models::StopBits::Two,
                            _ => crate::core::device::models::StopBits::One,
                        })
                        .unwrap_or(crate::core::device::models::StopBits::One);
                    let parity = parts
                        .get(4)
                        .map(|s| match *s {
                            "O" => crate::core::device::models::Parity::Odd,
                            "E" => crate::core::device::models::Parity::Even,
                            _ => crate::core::device::models::Parity::None,
                        })
                        .unwrap_or(crate::core::device::models::Parity::None);
                    let flow_control = parts
                        .get(5)
                        .map(|s| match *s {
                            "H" => crate::core::device::models::FlowControl::Hardware,
                            "S" => crate::core::device::models::FlowControl::Software,
                            _ => crate::core::device::models::FlowControl::None,
                        })
                        .unwrap_or(crate::core::device::models::FlowControl::None);
                    let receive_timeout_ms = parts
                        .get(6)
                        .and_then(|s| s.parse::<u64>().ok())
                        .unwrap_or(100);
                    let mut transport = SerialTransport::new(SerialConfig {
                        port,
                        baud_rate,
                        data_bits,
                        stop_bits,
                        parity,
                        flow_control,
                        receive_timeout_ms,
                    });
                    transport.connect().await?;
                    Ok(ActiveSession::Serial(Arc::new(Mutex::new(transport))))
                }
                ConnectionType::Tcp => {
                    let parts: Vec<&str> = device.address.split(':').collect();
                    if parts.len() < 2 {
                        return Err(TransportError::InvalidConfig("Invalid TCP address".into()));
                    }
                    let host = parts[0].to_string();
                    let port = parts[1]
                        .parse::<u16>()
                        .map_err(|_| TransportError::InvalidConfig("Invalid port".into()))?;
                    let mut transport = TcpTransport::new(TcpConfig {
                        host,
                        port,
                        ..Default::default()
                    });
                    transport.connect().await?;
                    Ok(ActiveSession::Tcp(Arc::new(Mutex::new(transport))))
                }
                _ => Err(TransportError::InvalidConfig(format!(
                    "Unsupported connection type: {:?}",
                    device.connection_type
                ))),
            }
        })
    }

    /// 断开设备
    pub async fn disconnect(&self, device_id: &str) -> Result<(), TransportError> {
        #[cfg(target_os = "windows")]
        {
            self.serial_handles.write().await.remove(device_id);
        }
        if let Some(session) = self.sessions.write().await.remove(device_id) {
            match session {
                ActiveSession::Serial(t) => t.lock().await.disconnect().await?,
                ActiveSession::Tcp(t) => t.lock().await.disconnect().await?,
                ActiveSession::Virtual(t) => t.lock().await.disconnect().await?,
            }
        }
        self.registry
            .update_status(device_id, DeviceStatus::Disconnected);
        Ok(())
    }

    /// 发送数据
    pub async fn send(&self, device_id: &str, data: &[u8]) -> Result<(), TransportError> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(device_id)
            .ok_or(TransportError::Disconnected)?;
        match session {
            ActiveSession::Serial(t) => t.lock().await.send(data).await,
            ActiveSession::Tcp(t) => t.lock().await.send(data).await,
            ActiveSession::Virtual(t) => t.lock().await.send(data).await,
        }
    }

    /// 接收数据
    pub async fn receive(&self, device_id: &str) -> Result<Vec<u8>, TransportError> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(device_id)
            .ok_or(TransportError::Disconnected)?;
        match session {
            ActiveSession::Serial(t) => t.lock().await.receive().await,
            ActiveSession::Tcp(t) => t.lock().await.receive().await,
            ActiveSession::Virtual(t) => t.lock().await.receive().await,
        }
    }

    /// 检查连接状态
    pub async fn is_connected(&self, device_id: &str) -> bool {
        let sessions = self.sessions.read().await;
        sessions.get(device_id).is_some_and(|s| match s {
            ActiveSession::Serial(t) => {
                // 尝试快速检测：如果不能锁说明正在用，视为已连接
                t.try_lock().map_or(true, |g| g.is_connected())
            }
            ActiveSession::Tcp(t) => t.try_lock().map_or(true, |g| g.is_connected()),
            ActiveSession::Virtual(t) => t.try_lock().map_or(true, |g| g.is_connected()),
        })
    }

    /// 同步版连接状态检查 —— 用于 #[frb(sync)] 函数，避免 block_on
    /// 仅检查 sessions map 是否包含该设备，不尝试锁定 transport
    pub fn is_connected_sync(&self, device_id: &str) -> bool {
        self.sessions
            .try_read()
            .map(|sessions| sessions.contains_key(device_id))
            .unwrap_or(false) // 锁被占用时保守认为已连接
    }

    /// Helper: extract raw HANDLE from serial session (for storing in serial_handles map)
    #[cfg(target_os = "windows")]
    async fn _get_serial_handle(&self, device_id: &str) -> Option<SafeHandle> {
        let sessions = self.sessions.read().await;
        if let Some(ActiveSession::Serial(t)) = sessions.get(device_id) {
            if let Ok(transport) = t.try_lock() {
                return transport.raw_handle;
            }
        }
        None
    }

    /// Set DTR signal — uses raw HANDLE directly, no Mutex lock needed
    #[cfg(target_os = "windows")]
    pub fn set_dtr(&self, device_id: &str, level: bool) -> bool {
        if let Ok(handles) = self.serial_handles.try_read() {
            if let Some(handle) = handles.get(device_id) {
                let func = if level {
                    crate::core::transport::serial::win_comm::SETDTR
                } else {
                    crate::core::transport::serial::win_comm::CLRDTR
                };
                return unsafe {
                    crate::core::transport::serial::win_comm::EscapeCommFunction(handle.0, func)
                        != 0
                };
            }
        }
        let handles = crate::core::app_context::block_on(self.serial_handles.read());
        if let Some(handle) = handles.get(device_id) {
            let func = if level {
                crate::core::transport::serial::win_comm::SETDTR
            } else {
                crate::core::transport::serial::win_comm::CLRDTR
            };
            unsafe {
                crate::core::transport::serial::win_comm::EscapeCommFunction(handle.0, func) != 0
            }
        } else {
            false
        }
    }

    /// Set RTS signal — uses raw HANDLE directly
    #[cfg(target_os = "windows")]
    pub fn set_rts(&self, device_id: &str, level: bool) -> bool {
        if let Ok(handles) = self.serial_handles.try_read() {
            if let Some(handle) = handles.get(device_id) {
                let func = if level {
                    crate::core::transport::serial::win_comm::SETRTS
                } else {
                    crate::core::transport::serial::win_comm::CLRRTS
                };
                return unsafe {
                    crate::core::transport::serial::win_comm::EscapeCommFunction(handle.0, func)
                        != 0
                };
            }
        }
        let handles = crate::core::app_context::block_on(self.serial_handles.read());
        if let Some(handle) = handles.get(device_id) {
            let func = if level {
                crate::core::transport::serial::win_comm::SETRTS
            } else {
                crate::core::transport::serial::win_comm::CLRRTS
            };
            unsafe {
                crate::core::transport::serial::win_comm::EscapeCommFunction(handle.0, func) != 0
            }
        } else {
            false
        }
    }

    /// Set Break signal — uses raw HANDLE directly
    #[cfg(target_os = "windows")]
    pub fn set_break(&self, device_id: &str) -> bool {
        if let Ok(handles) = self.serial_handles.try_read() {
            if let Some(handle) = handles.get(device_id) {
                return unsafe {
                    crate::core::transport::serial::win_comm::EscapeCommFunction(
                        handle.0,
                        crate::core::transport::serial::win_comm::SETBREAK,
                    ) != 0
                };
            }
        }
        let handles = crate::core::app_context::block_on(self.serial_handles.read());
        if let Some(handle) = handles.get(device_id) {
            unsafe {
                crate::core::transport::serial::win_comm::EscapeCommFunction(
                    handle.0,
                    crate::core::transport::serial::win_comm::SETBREAK,
                ) != 0
            }
        } else {
            false
        }
    }

    /// Clear Break signal — uses raw HANDLE directly
    #[cfg(target_os = "windows")]
    pub fn clear_break(&self, device_id: &str) -> bool {
        if let Ok(handles) = self.serial_handles.try_read() {
            if let Some(handle) = handles.get(device_id) {
                return unsafe {
                    crate::core::transport::serial::win_comm::EscapeCommFunction(
                        handle.0,
                        crate::core::transport::serial::win_comm::CLRBREAK,
                    ) != 0
                };
            }
        }
        let handles = crate::core::app_context::block_on(self.serial_handles.read());
        if let Some(handle) = handles.get(device_id) {
            unsafe {
                crate::core::transport::serial::win_comm::EscapeCommFunction(
                    handle.0,
                    crate::core::transport::serial::win_comm::CLRBREAK,
                ) != 0
            }
        } else {
            false
        }
    }

    /// Read CTS signal status — uses raw HANDLE directly
    #[cfg(target_os = "windows")]
    pub fn get_cts(&self, device_id: &str) -> bool {
        let read_cts = |handle: &crate::core::transport::serial::SafeHandle| -> bool {
            let mut stat: u32 = 0;
            let result = unsafe {
                crate::core::transport::serial::win_comm::GetCommModemStatus(handle.0, &mut stat)
            };
            result != 0 && (stat & crate::core::transport::serial::win_comm::MS_CTS_ON) != 0
        };
        if let Ok(handles) = self.serial_handles.try_read() {
            if let Some(handle) = handles.get(device_id) {
                return read_cts(handle);
            }
        }
        let handles = crate::core::app_context::block_on(self.serial_handles.read());
        handles.get(device_id).is_some_and(read_cts)
    }

    /// Read DSR signal status — uses raw HANDLE directly
    #[cfg(target_os = "windows")]
    pub fn get_dsr(&self, device_id: &str) -> bool {
        let read_dsr = |handle: &crate::core::transport::serial::SafeHandle| -> bool {
            let mut stat: u32 = 0;
            let result = unsafe {
                crate::core::transport::serial::win_comm::GetCommModemStatus(handle.0, &mut stat)
            };
            result != 0 && (stat & crate::core::transport::serial::win_comm::MS_DSR_ON) != 0
        };
        if let Ok(handles) = self.serial_handles.try_read() {
            if let Some(handle) = handles.get(device_id) {
                return read_dsr(handle);
            }
        }
        let handles = crate::core::app_context::block_on(self.serial_handles.read());
        handles.get(device_id).is_some_and(read_dsr)
    }
}
