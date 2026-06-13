use crate::core::virtual_device::scpi_responder::ScpiResponder;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, RwLock};

// ============================================================================
// SimulatorManager — 虚拟设备基础设施的统一入口
// ============================================================================

/// 虚拟基础设施状态
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct VirtualInfraStatus {
    pub tcp_scpi_running: bool,
    pub tcp_scpi_address: String,
    pub virtual_serial_running: bool,
    pub virtual_serial_ports: String,
}

/// 虚拟通道连接句柄（给 VirtualChannelTransport 使用）
pub struct VirtualChannelHandle {
    pub cmd_tx: mpsc::UnboundedSender<Vec<u8>>,
    pub response_rx: broadcast::Receiver<Vec<u8>>,
}

/// 虚拟设备模拟器管理器
///
/// 管理两个子系统：
/// 1. TCP SCPI 服务器（127.0.0.1:5025）
/// 2. 虚拟串口对（COM1 ↔ COM2，用 channel 模拟）
pub struct SimulatorManager {
    tcp_server: RwLock<Option<TcpSimulator>>,
    serial_pair: RwLock<Option<SerialPairSimulator>>,
}

impl SimulatorManager {
    pub fn new() -> Self {
        Self {
            tcp_server: RwLock::new(None),
            serial_pair: RwLock::new(None),
        }
    }

    /// 启动所有虚拟基础设施
    pub async fn start_all(&self) -> VirtualInfraStatus {
        // 启动 TCP SCPI 服务器
        let _tcp_running = match self.start_tcp_server(5025).await {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[Simulator] TCP server start failed: {}", e);
                false
            }
        };

        // 启动虚拟串口对
        let _serial_running = match self.start_serial_pair().await {
            Ok(_) => true,
            Err(e) => {
                eprintln!("[Simulator] Serial pair start failed: {}", e);
                false
            }
        };

        self.status().await
    }

    /// 停止所有虚拟基础设施
    pub async fn stop_all(&self) {
        if let Some(server) = self.tcp_server.write().await.take() {
            server.stop().await;
        }
        if let Some(pair) = self.serial_pair.write().await.take() {
            pair.stop().await;
        }
    }

    /// 获取当前状态
    pub async fn status(&self) -> VirtualInfraStatus {
        VirtualInfraStatus {
            tcp_scpi_running: self.tcp_server.read().await.is_some(),
            tcp_scpi_address: "127.0.0.1:5025".into(),
            virtual_serial_running: self.serial_pair.read().await.is_some(),
            virtual_serial_ports: "COM1 ↔ COM2".into(),
        }
    }

    /// 创建虚拟串口连接（供 SessionManager 使用）
    pub async fn create_serial_connection(&self) -> Option<VirtualChannelHandle> {
        let pair = self.serial_pair.read().await;
        pair.as_ref()?.create_connection().await
    }

    /// 检查虚拟串口是否运行（同步版本，用于 scan_serial_ports 等 frb sync 上下文）
    pub fn is_serial_pair_running_sync(&self) -> bool {
        // 检查 RwLock 的锁状态，但不实际加锁——因为 tokio 单线程 runtime
        // 在这里阻塞会导致 tokio spawn 的后台任务无法执行而产生死锁。
        // serial_pair 为 Option<SerialPairSimulator>，非 None 表示已启动。
        // 我们使用 try_read 来避免实际加锁的开销和死锁风险。
        self.serial_pair
            .try_read()
            .map(|guard| guard.is_some())
            .unwrap_or(false) // 如果锁被占用，认为正在运行
    }

    /// 检查虚拟串口是否运行（异步版本）
    pub async fn is_serial_pair_running(&self) -> bool {
        self.serial_pair.read().await.is_some()
    }

    // ---- 内部实现 ----

    async fn start_tcp_server(&self, port: u16) -> Result<(), String> {
        if self.tcp_server.read().await.is_some() {
            return Ok(()); // 已在运行
        }
        let server = TcpSimulator::start(port).await?;
        *self.tcp_server.write().await = Some(server);
        Ok(())
    }

    async fn start_serial_pair(&self) -> Result<(), String> {
        if self.serial_pair.read().await.is_some() {
            return Ok(()); // 已在运行
        }
        let pair = SerialPairSimulator::start().await?;
        *self.serial_pair.write().await = Some(pair);
        Ok(())
    }
}

impl Default for SimulatorManager {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================================
// TCP SCPI 模拟服务器
// ============================================================================

struct TcpSimulator {
    running: Arc<RwLock<bool>>,
}

impl TcpSimulator {
    async fn start(port: u16) -> Result<Self, String> {
        let addr = format!("127.0.0.1:{}", port);
        let listener = TcpListener::bind(&addr)
            .await
            .map_err(|e| format!("Bind {} failed: {}", addr, e))?;

        let running = Arc::new(RwLock::new(true));
        let running_clone = running.clone();

        tokio::spawn(async move {
            println!("[TcpSimulator:{}] Listening on {}", port, addr);
            loop {
                if !*running_clone.read().await {
                    break;
                }
                match listener.accept().await {
                    Ok((stream, peer)) => {
                        println!("[TcpSimulator:{}] Client connected: {}", port, peer);
                        let r = running_clone.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_scpi_client(stream, r).await {
                                eprintln!("[TcpSimulator] Client error: {}", e);
                            }
                        });
                    }
                    Err(e) => {
                        eprintln!("[TcpSimulator:{}] Accept error: {}", port, e);
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    }
                }
            }
            println!("[TcpSimulator:{}] Stopped", port);
        });

        // 等待服务器就绪
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        Ok(Self { running })
    }

    async fn stop(&self) {
        *self.running.write().await = false;
    }
}

async fn handle_scpi_client(
    stream: TcpStream,
    running: Arc<RwLock<bool>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let mut scpi = ScpiResponder::new();

    loop {
        if !*running.read().await {
            break;
        }
        let line =
            tokio::time::timeout(std::time::Duration::from_secs(60), lines.next_line()).await;
        match line {
            Ok(Ok(Some(cmd))) if !cmd.is_empty() => {
                let response = scpi.handle_command(&cmd);
                writer.write_all(response.as_bytes()).await?;
                writer.flush().await?;
            }
            Ok(Ok(Some(_))) => {} // empty line, ignore
            Ok(Ok(None)) | Ok(Err(_)) => break,
            Err(_) => continue, // timeout
        }
    }
    Ok(())
}

// ============================================================================
// 虚拟串口对模拟器
// ============================================================================

struct SerialPairSimulator {
    cmd_sender: mpsc::UnboundedSender<Vec<u8>>,
    response_sender: broadcast::Sender<Vec<u8>>,
    running: Arc<RwLock<bool>>,
}

impl SerialPairSimulator {
    async fn start() -> Result<Self, String> {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (resp_tx, _) = broadcast::channel::<Vec<u8>>(256);
        let running = Arc::new(RwLock::new(true));
        let running_clone = running.clone();
        let resp_tx_clone = resp_tx.clone();

        tokio::spawn(async move {
            let mut scpi = ScpiResponder::new();
            println!("[SerialPair] SCPI processor started on COM2");
            while *running_clone.read().await {
                match cmd_rx.try_recv() {
                    Ok(data) => {
                        let cmd = String::from_utf8_lossy(&data);
                        let cmd = cmd.trim();
                        if cmd.is_empty() {
                            continue;
                        }
                        println!("[SerialPair:RX] {}", cmd);
                        let response = scpi.handle_command(cmd);
                        println!("[SerialPair:TX] {}", response.trim());
                        let _ = resp_tx_clone.send(response.into_bytes());
                    }
                    Err(mpsc::error::TryRecvError::Empty) => {
                        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    }
                    Err(mpsc::error::TryRecvError::Disconnected) => break,
                }
            }
            println!("[SerialPair] SCPI processor stopped");
        });

        println!("[SerialPair] Started: COM1 ↔ COM2");
        Ok(Self {
            cmd_sender: cmd_tx,
            response_sender: resp_tx,
            running,
        })
    }

    async fn stop(&self) {
        *self.running.write().await = false;
    }

    async fn create_connection(&self) -> Option<VirtualChannelHandle> {
        if !*self.running.read().await {
            return None;
        }
        Some(VirtualChannelHandle {
            cmd_tx: self.cmd_sender.clone(),
            response_rx: self.response_sender.subscribe(),
        })
    }
}
