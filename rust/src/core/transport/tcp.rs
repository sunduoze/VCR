use super::{Transport, TransportError};
use async_trait::async_trait;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[derive(Clone, Debug)]
pub struct TcpConfig {
    pub host: String,
    pub port: u16,
    pub timeout_ms: u64,
}

impl Default for TcpConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 8080,
            timeout_ms: 5000,
        }
    }
}

pub struct TcpTransport {
    stream: Option<TcpStream>,
    config: TcpConfig,
}

impl TcpTransport {
    pub fn new(config: TcpConfig) -> Self {
        Self {
            stream: None,
            config,
        }
    }
}

#[async_trait]
impl Transport for TcpTransport {
    async fn connect(&mut self) -> Result<(), TransportError> {
        // 使用 config 中的 host:port，不再硬编码
        let addr = format!("{}:{}", self.config.host, self.config.port);
        let stream = tokio::time::timeout(
            Duration::from_millis(self.config.timeout_ms),
            TcpStream::connect(&addr),
        )
        .await
        .map_err(|_| TransportError::Timeout)?
        .map_err(|e| TransportError::ConnectionFailed(e.to_string()))?;

        stream.set_nodelay(true).map_err(|e| TransportError::ConnectionFailed(e.to_string()))?;
        self.stream = Some(stream);
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), TransportError> {
        self.stream = None;
        Ok(())
    }

    async fn send(&mut self, data: &[u8]) -> Result<(), TransportError> {
        if let Some(ref mut stream) = self.stream {
            stream.write_all(data).await.map_err(|e| TransportError::SendError(e.to_string()))
        } else {
            Err(TransportError::Disconnected)
        }
    }

    async fn receive(&mut self) -> Result<Vec<u8>, TransportError> {
        if let Some(ref mut stream) = self.stream {
            let mut buf = vec![0u8; 4096];
            let n = tokio::time::timeout(
                Duration::from_millis(200),
                stream.read(&mut buf),
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
        self.stream.is_some()
    }
}
