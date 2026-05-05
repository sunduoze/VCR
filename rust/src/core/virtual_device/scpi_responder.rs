use rand::Rng;

/// SCPI 设备内部状态
#[derive(Clone, Debug)]
struct ScpiState {
    identity: String,
    voltage: f64,
    current: f64,
    power: f64,
    frequency: f64,
    temperature: f64,
    output_enabled: bool,
    error_queue: Vec<String>,
}

impl Default for ScpiState {
    fn default() -> Self {
        Self {
            identity: "VCR Virtual Instrument v1.0".into(),
            voltage: 3.3,
            current: 0.5,
            power: 1.65,
            frequency: 1000.0,
            temperature: 25.0,
            output_enabled: false,
            error_queue: Vec::new(),
        }
    }
}

/// SCPI 命令响应器 —— 纯逻辑，无 I/O
pub struct ScpiResponder {
    state: ScpiState,
}

impl ScpiResponder {
    pub fn new() -> Self {
        Self {
            state: ScpiState::default(),
        }
    }

    /// 处理 SCPI 命令，返回响应字符串（含换行符）
    pub fn handle_command(&mut self, command: &str) -> String {
        let cmd = command.trim();

        if cmd.is_empty() {
            return String::new();
        }

        let cmd_upper = cmd.to_uppercase();

        // * 公共命令：直接按完整命令匹配（不要 trim 掉 * 和 :）
        if cmd_upper.starts_with('*') {
            return match cmd_upper.as_str() {
                "*IDN?" => format!("{}\n", self.state.identity),
                "*RST" => {
                    self.state = ScpiState::default();
                    "OK\n".into()
                }
                "*CLS" => {
                    self.state.error_queue.clear();
                    "OK\n".into()
                }
                "*HELP?" => self.help_text(),
                _ => {
                    self.state
                        .error_queue
                        .push("-100,\"Command error\"".into());
                    "ERR:Unknown * command\n".into()
                }
            };
        }

        // 程序命令：匹配完整路径（含 : 分隔符）
        match cmd_upper.as_str() {
            "MEAS:VOLT?" | "MEAS:VOLT:DC?" => self.measure(self.state.voltage, 0.1),
            "MEAS:CURR?" | "MEAS:CURR:DC?" => self.measure(self.state.current, 0.01),
            "MEAS:POW?" => self.measure(self.state.power, 0.1),
            "MEAS:FREQ?" => self.measure(self.state.frequency, 10.0),
            "MEAS:TEMP?" | "SYST:TEMP?" => self.measure(self.state.temperature, 0.5),
            "OUTP ON" | "OUTPUT ON" => {
                self.state.output_enabled = true;
                "OK\n".into()
            }
            "OUTP OFF" | "OUTPUT OFF" => {
                self.state.output_enabled = false;
                "OK\n".into()
            }
            "OUTP?" | "OUTPUT?" => {
                format!("{}\n", if self.state.output_enabled { 1 } else { 0 })
            }
            "SYST:ERR?" => self.state.error_queue.pop().map_or_else(
                || "0,\"No error\"\n".into(),
                |e| format!("{}\n", e),
            ),
            "SYST:STAT?" | "STAT?" => self.status_text(),
            "HELP?" => self.help_text(),
            // 带参数的命令（VOLT x / CURR x / FREQ x）
            _ if cmd_upper.starts_with("VOLT ") || cmd_upper.starts_with("SOUR:VOLT ") => {
                self.set_voltage(cmd)
            }
            _ if cmd_upper.starts_with("CURR ") || cmd_upper.starts_with("SOUR:CURR ") => {
                self.set_current(cmd)
            }
            _ if cmd_upper.starts_with("FREQ ") || cmd_upper.starts_with("SOUR:FREQ ") => {
                self.set_frequency(cmd)
            }
            _ => {
                self.state
                    .error_queue
                    .push("-100,\"Command error\"".into());
                "ERR:Unknown command\n".into()
            }
        }
    }

    fn measure(&self, base: f64, noise_range: f64) -> String {
        let noise = (rand::thread_rng().gen::<f64>() - 0.5) * noise_range;
        format!("{:.6}\n", base + noise)
    }

    fn set_voltage(&mut self, cmd: &str) -> String {
        if let Some(v) = cmd.split_whitespace().last().and_then(|s| s.parse::<f64>().ok()) {
            self.state.voltage = v;
            self.state.power = v * self.state.current;
            "OK\n".into()
        } else {
            "ERR:Invalid parameter\n".into()
        }
    }

    fn set_current(&mut self, cmd: &str) -> String {
        if let Some(v) = cmd.split_whitespace().last().and_then(|s| s.parse::<f64>().ok()) {
            self.state.current = v;
            self.state.power = self.state.voltage * v;
            "OK\n".into()
        } else {
            "ERR:Invalid parameter\n".into()
        }
    }

    fn set_frequency(&mut self, cmd: &str) -> String {
        if let Some(v) = cmd.split_whitespace().last().and_then(|s| s.parse::<f64>().ok()) {
            self.state.frequency = v;
            "OK\n".into()
        } else {
            "ERR:Invalid parameter\n".into()
        }
    }

    fn help_text(&self) -> String {
        "Available commands:\n\
         *IDN? - Device identification\n\
         *RST - Reset device\n\
         *CLS - Clear errors\n\
         MEAS:VOLT? - Measure voltage\n\
         MEAS:CURR? - Measure current\n\
         MEAS:POW? - Measure power\n\
         MEAS:FREQ? - Measure frequency\n\
         MEAS:TEMP? - Measure temperature\n\
         VOLT <value> - Set voltage\n\
         CURR <value> - Set current\n\
         OUTP ON|OFF - Enable/disable output\n\
         STAT? - Query all status\n"
            .into()
    }

    fn status_text(&self) -> String {
        format!(
            "VOLT:{:.3}V;CURR:{:.3}A;POW:{:.3}W;FREQ:{:.1}Hz;TEMP:{:.1}C;OUT:{}\n",
            self.state.voltage,
            self.state.current,
            self.state.power,
            self.state.frequency,
            self.state.temperature,
            if self.state.output_enabled { 1 } else { 0 }
        )
    }
}

impl Default for ScpiResponder {
    fn default() -> Self {
        Self::new()
    }
}
