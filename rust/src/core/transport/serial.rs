use super::{Transport, TransportError};
use async_trait::async_trait;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_serial::SerialPortBuilderExt;
use crate::core::device::models::{DataBits, StopBits, Parity, FlowControl};

/// Wrapper for Windows HANDLE that implements Send + Sync
/// SAFETY: Windows HANDLEs can be used from any thread (they're kernel objects)
#[cfg(target_os = "windows")]
#[derive(Clone, Copy)]
pub struct SafeHandle(pub *mut std::ffi::c_void);

#[cfg(target_os = "windows")]
unsafe impl Send for SafeHandle {}
#[cfg(target_os = "windows")]
unsafe impl Sync for SafeHandle {}

/// EscapeCommFunction constants for direct Windows API calls
#[cfg(target_os = "windows")]
pub mod win_comm {
    pub const SETDTR: u32 = 5;
    pub const CLRDTR: u32 = 6;
    pub const SETRTS: u32 = 3;
    pub const CLRRTS: u32 = 4;
    pub const SETBREAK: u32 = 8;
    pub const CLRBREAK: u32 = 9;

    #[link(name = "kernel32")]
    extern "system" {
        pub fn EscapeCommFunction(hFile: *mut std::ffi::c_void, dwFunc: u32) -> i32;
        pub fn GetCommModemStatus(hFile: *mut std::ffi::c_void, lpModemStat: *mut u32) -> i32;
        pub fn GetLastError() -> u32;
    }

    // GetCommModemStatus 返回值位掩码
    pub const MS_CTS_ON: u32 = 0x0010;
    pub const MS_DSR_ON: u32 = 0x0020;
    pub const MS_RING_ON: u32 = 0x0040;
    pub const MS_RLSD_ON: u32 = 0x0080;
}

#[derive(Clone, Debug)]
pub struct SerialConfig {
    pub port: String,
    pub baud_rate: u32,
    pub data_bits: DataBits,
    pub stop_bits: StopBits,
    pub parity: Parity,
    pub flow_control: FlowControl,
    /// Serial receive timeout in milliseconds (default: 100)
    pub receive_timeout_ms: u64,
}

impl Default for SerialConfig {
    fn default() -> Self {
        Self {
            port: String::new(),
            baud_rate: 115200,
            data_bits: DataBits::Eight,
            stop_bits: StopBits::One,
            parity: Parity::None,
            flow_control: FlowControl::None,
            receive_timeout_ms: 100,
        }
    }
}

impl SerialConfig {
    pub fn to_tokio_data_bits(&self) -> tokio_serial::DataBits {
        match self.data_bits {
            DataBits::Five => tokio_serial::DataBits::Five,
            DataBits::Six => tokio_serial::DataBits::Six,
            DataBits::Seven => tokio_serial::DataBits::Seven,
            DataBits::Eight => tokio_serial::DataBits::Eight,
        }
    }
    pub fn to_tokio_stop_bits(&self) -> tokio_serial::StopBits {
        match self.stop_bits {
            StopBits::One => tokio_serial::StopBits::One,
            StopBits::Two => tokio_serial::StopBits::Two,
        }
    }
    pub fn to_tokio_parity(&self) -> tokio_serial::Parity {
        match self.parity {
            Parity::None => tokio_serial::Parity::None,
            Parity::Odd => tokio_serial::Parity::Odd,
            Parity::Even => tokio_serial::Parity::Even,
        }
    }
    pub fn to_tokio_flow_control(&self) -> tokio_serial::FlowControl {
        match self.flow_control {
            FlowControl::None => tokio_serial::FlowControl::None,
            FlowControl::Hardware => tokio_serial::FlowControl::Hardware,
            FlowControl::Software => tokio_serial::FlowControl::Software,
        }
    }
}

pub struct SerialTransport {
    config: SerialConfig,
    port: Option<tokio_serial::SerialStream>,
    /// Raw Windows HANDLE for direct DTR/RTS/Break control (bypasses Mutex)
    #[cfg(target_os = "windows")]
    pub raw_handle: Option<SafeHandle>,
}

// Safety: raw_handle is a copy of the HANDLE inside `port`;
// it's valid as long as `port` is Some, and we clear it on disconnect.
#[cfg(target_os = "windows")]
unsafe impl Send for SerialTransport {}
#[cfg(target_os = "windows")]
unsafe impl Sync for SerialTransport {}

impl SerialTransport {
    pub fn new(config: SerialConfig) -> Self {
        Self {
            config,
            port: None,
            #[cfg(target_os = "windows")]
            raw_handle: None,
        }
    }

    /// Set DTR signal directly via Windows API (no Mutex needed)
    #[cfg(target_os = "windows")]
    fn escape_comm(&self, func: u32, _func_name: &str) -> bool {
        if let Some(ref handle) = self.raw_handle {
            let result = unsafe { win_comm::EscapeCommFunction(handle.0, func) };
            result != 0
        } else {
            false
        }
    }

    pub fn set_dtr(&self, level: bool) -> bool {
        let func = if level { win_comm::SETDTR } else { win_comm::CLRDTR };
        let name = if level { "SETDTR" } else { "CLRDTR" };
        self.escape_comm(func, name)
    }

    /// Set RTS signal directly via Windows API (no Mutex needed)
    #[cfg(target_os = "windows")]
    pub fn set_rts(&self, level: bool) -> bool {
        let func = if level { win_comm::SETRTS } else { win_comm::CLRRTS };
        let name = if level { "SETRTS" } else { "CLRRTS" };
        self.escape_comm(func, name)
    }

    /// Set Break signal directly via Windows API (no Mutex needed)
    #[cfg(target_os = "windows")]
    pub fn set_break(&self) -> bool {
        self.escape_comm(win_comm::SETBREAK, "SETBREAK")
    }

    /// Clear Break signal directly via Windows API (no Mutex needed)
    #[cfg(target_os = "windows")]
    pub fn clear_break(&self) -> bool {
        self.escape_comm(win_comm::CLRBREAK, "CLRBREAK")
    }

    /// Read CTS (Clear To Send) signal status via Windows API
    #[cfg(target_os = "windows")]
    pub fn get_cts(&self) -> bool {
        if let Some(ref handle) = self.raw_handle {
            let mut stat: u32 = 0;
            let result = unsafe { win_comm::GetCommModemStatus(handle.0, &mut stat) };
            if result != 0 {
                return (stat & win_comm::MS_CTS_ON) != 0;
            }
        }
        false
    }

    /// Read DSR (Data Set Ready) signal status via Windows API
    #[cfg(target_os = "windows")]
    pub fn get_dsr(&self) -> bool {
        if let Some(ref handle) = self.raw_handle {
            let mut stat: u32 = 0;
            let result = unsafe { win_comm::GetCommModemStatus(handle.0, &mut stat) };
            if result != 0 {
                return (stat & win_comm::MS_DSR_ON) != 0;
            }
        }
        false
    }
}

#[async_trait]
impl Transport for SerialTransport {
    async fn connect(&mut self) -> Result<(), TransportError> {
        let builder = tokio_serial::new(&self.config.port, self.config.baud_rate)
            .data_bits(self.config.to_tokio_data_bits())
            .stop_bits(self.config.to_tokio_stop_bits())
            .parity(self.config.to_tokio_parity())
            .flow_control(self.config.to_tokio_flow_control());

        let port = builder
            .open_native_async()
            .map_err(|e| TransportError::ConnectionFailed(e.to_string()))?;
        #[cfg(target_os = "windows")]
        let handle = {
            use std::os::windows::io::AsRawHandle;
            port.as_raw_handle()
        };
        self.port = Some(port);
        #[cfg(target_os = "windows")]
        {
            self.raw_handle = Some(SafeHandle(handle));
        }
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), TransportError> {
        self.port = None;
        #[cfg(target_os = "windows")]
        {
            self.raw_handle = None;
        }
        Ok(())
    }

    async fn send(&mut self, data: &[u8]) -> Result<(), TransportError> {
        if let Some(ref mut port) = self.port {
            port.write_all(data).await.map_err(|e| TransportError::SendError(e.to_string()))
        } else {
            Err(TransportError::Disconnected)
        }
    }

    async fn receive(&mut self) -> Result<Vec<u8>, TransportError> {
        if let Some(ref mut port) = self.port {
            let mut buf = vec![0u8; 4096];
            let n = tokio::time::timeout(
                Duration::from_millis(self.config.receive_timeout_ms),
                port.read(&mut buf),
            )
            .await
            .map_err(|_| TransportError::Timeout)?
            .map_err(|e| TransportError::ReceiveError(e.to_string()))?;
            buf.truncate(n);
            Ok(buf)
        } else {
            Err(TransportError::Disconnected)
        }
    }

    fn is_connected(&self) -> bool {
        self.port.is_some()
    }
}

/// 扫描系统可用串口，返回 (端口名, 设备管理器友好名称, 是否虚拟串口)
/// 使用 serialport crate 内置 USB 信息，无需 PowerShell，~50ms 替代原来 2-5s
pub fn scan_serial_ports() -> Vec<(String, String, bool)> {
    serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        .map(|p| {
            let (desc, is_virtual) = match &p.port_type {
                serialport::SerialPortType::UsbPort(usb) => {
                    let mfr = usb.manufacturer.as_deref().unwrap_or("");
                    let prod = usb.product.as_deref().unwrap_or("");
                    let is_v = mfr.contains("Eltima") || mfr.contains("Virtual")
                        || prod.contains("Virtual") || prod.contains("VSPD");
                    let desc = match (mfr, prod) {
                        (m, p) if !m.is_empty() && !p.is_empty() => format!("{} - {}", m, p),
                        (m, _) if !m.is_empty() => m.to_string(),
                        (_, p) if !p.is_empty() => p.to_string(),
                        _ => "USB Serial Device".to_string(),
                    };
                    (desc, is_v)
                }
                serialport::SerialPortType::PciPort => ("PCI Serial Port".to_string(), false),
                serialport::SerialPortType::BluetoothPort => ("Bluetooth Serial".to_string(), false),
                serialport::SerialPortType::Unknown => {
                    ("Virtual Serial Port".to_string(), true)
                }
            };
            (p.port_name, desc, is_virtual)
        })
        .collect()
}