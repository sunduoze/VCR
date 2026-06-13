use super::{Transport, TransportError};
use async_trait::async_trait;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};

/// 虚拟通道传输（用于虚拟串口对 / 内部 channel 通信）
///
/// 与 SerialTransport / TcpTransport 拥有相同的 Transport 接口，
/// 但底层使用 mpsc + broadcast channel，不需要真实硬件。
pub struct VirtualChannelTransport {
    cmd_tx: mpsc::UnboundedSender<Vec<u8>>,
    response_rx: broadcast::Receiver<Vec<u8>>,
    connected: bool,
}

impl VirtualChannelTransport {
    pub fn new(
        cmd_tx: mpsc::UnboundedSender<Vec<u8>>,
        response_rx: broadcast::Receiver<Vec<u8>>,
    ) -> Self {
        Self {
            cmd_tx,
            response_rx,
            connected: false,
        }
    }
}

#[async_trait]
impl Transport for VirtualChannelTransport {
    async fn connect(&mut self) -> Result<(), TransportError> {
        if self.cmd_tx.is_closed() {
            return Err(TransportError::ConnectionFailed(
                "Virtual channel closed".into(),
            ));
        }
        self.connected = true;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), TransportError> {
        self.connected = false;
        Ok(())
    }

    async fn send(&mut self, data: &[u8]) -> Result<(), TransportError> {
        if !self.connected {
            return Err(TransportError::Disconnected);
        }
        self.cmd_tx
            .send(data.to_vec())
            .map_err(|e| TransportError::SendError(format!("Virtual channel send: {}", e)))
    }

    async fn receive(&mut self) -> Result<Vec<u8>, TransportError> {
        if !self.connected {
            return Err(TransportError::Disconnected);
        }
        // 用 recv() + timeout 替代 try_recv()
        // 这样数据一旦 broadcast 就立即返回，而不是轮询空转
        match tokio::time::timeout(Duration::from_millis(200), self.response_rx.recv()).await {
            Ok(Ok(data)) => Ok(data),
            Ok(Err(broadcast::error::RecvError::Closed)) => Err(TransportError::Disconnected),
            Ok(Err(broadcast::error::RecvError::Lagged(_n))) => Err(TransportError::Timeout),
            Err(_) => {
                // timeout，无数据，正常返回空让调用方继续轮询
                Ok(vec![])
            }
        }
    }

    fn is_connected(&self) -> bool {
        self.connected && !self.cmd_tx.is_closed()
    }
}
