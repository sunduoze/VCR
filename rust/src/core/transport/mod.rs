pub mod serial;
pub mod tcp;
pub mod virtual_channel;
pub mod modbus;

use async_trait::async_trait;

/// 传输层统一接口
#[async_trait]
pub trait Transport: Send + Sync {
    async fn connect(&mut self) -> Result<(), TransportError>;
    async fn disconnect(&mut self) -> Result<(), TransportError>;
    async fn send(&mut self, data: &[u8]) -> Result<(), TransportError>;
    async fn receive(&mut self) -> Result<Vec<u8>, TransportError>;
    fn is_connected(&self) -> bool;
}

#[derive(Clone, Debug)]
pub enum TransportError {
    ConnectionFailed(String),
    Disconnected,
    SendError(String),
    ReceiveError(String),
    Timeout,
    InvalidConfig(String),
}
