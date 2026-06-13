use rand::Rng;

/// 数据生成器 - 用于生成模拟波形数据
pub struct DataGenerator {
    sample_rate: f64,
    signal_type: SignalType,
    amplitude: f64,
    frequency: f64,
    #[allow(dead_code)]
    phase: f64,
    noise_level: f64,
    current_phase: f64,
}

#[derive(Clone, Copy, Debug)]
pub enum SignalType {
    Sine,
    Square,
    Triangle,
    Sawtooth,
    Noise,
    Mixed,
}

impl DataGenerator {
    pub fn new() -> Self {
        Self {
            sample_rate: 1000.0, // Hz
            signal_type: SignalType::Sine,
            amplitude: 1.0,
            frequency: 10.0,
            phase: 0.0,
            noise_level: 0.05,
            current_phase: 0.0,
        }
    }

    /// 设置采样率
    pub fn set_sample_rate(&mut self, rate: f64) {
        self.sample_rate = rate;
    }

    /// 设置信号类型
    pub fn set_signal_type(&mut self, signal_type: SignalType) {
        self.signal_type = signal_type;
    }

    /// 设置幅度
    pub fn set_amplitude(&mut self, amp: f64) {
        self.amplitude = amp;
    }

    /// 设置频率
    pub fn set_frequency(&mut self, freq: f64) {
        self.frequency = freq;
    }

    /// 设置噪声电平
    pub fn set_noise_level(&mut self, level: f64) {
        self.noise_level = level;
    }

    /// 生成单个采样点
    pub fn generate_sample(&mut self) -> f64 {
        let t = self.current_phase;
        let mut rng = rand::thread_rng();

        let signal = match self.signal_type {
            SignalType::Sine => {
                self.amplitude * (2.0 * std::f64::consts::PI * self.frequency * t).sin()
            }
            SignalType::Square => {
                let phase = (2.0 * std::f64::consts::PI * self.frequency * t)
                    % (2.0 * std::f64::consts::PI);
                if phase < std::f64::consts::PI {
                    self.amplitude
                } else {
                    -self.amplitude
                }
            }
            SignalType::Triangle => {
                let phase = (self.frequency * t) % 1.0;
                self.amplitude * (4.0 * (phase - 0.5).abs() - 1.0)
            }
            SignalType::Sawtooth => {
                let phase = (self.frequency * t) % 1.0;
                self.amplitude * (2.0 * phase - 1.0)
            }
            SignalType::Noise => (rng.gen::<f64>() - 0.5) * 2.0 * self.amplitude,
            SignalType::Mixed => {
                // 多频率叠加
                let base = self.amplitude * (2.0 * std::f64::consts::PI * self.frequency * t).sin();
                let harmonic1 = 0.3
                    * self.amplitude
                    * (2.0 * std::f64::consts::PI * self.frequency * 2.0 * t).sin();
                let harmonic2 = 0.1
                    * self.amplitude
                    * (2.0 * std::f64::consts::PI * self.frequency * 3.0 * t).sin();
                base + harmonic1 + harmonic2
            }
        };

        // 添加噪声
        let noise = if self.noise_level > 0.0 {
            (rng.gen::<f64>() - 0.5) * 2.0 * self.amplitude * self.noise_level
        } else {
            0.0
        };

        // 更新相位
        self.current_phase += 1.0 / self.sample_rate;

        signal + noise
    }

    /// 批量生成采样点
    pub fn generate_samples(&mut self, count: usize) -> Vec<f64> {
        (0..count).map(|_| self.generate_sample()).collect()
    }

    /// 生成字节流（16位有符号整数）
    pub fn generate_bytes(&mut self, count: usize) -> Vec<u8> {
        let samples = self.generate_samples(count);
        let mut bytes = Vec::with_capacity(count * 2);
        for sample in samples {
            let value = (sample * 32767.0) as i16;
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        bytes
    }

    /// 重置相位
    pub fn reset(&mut self) {
        self.current_phase = 0.0;
    }
}

impl Default for DataGenerator {
    fn default() -> Self {
        Self::new()
    }
}

/// Modbus 数据生成器
pub struct ModbusDataGenerator {
    registers: [u16; 100],
}

impl ModbusDataGenerator {
    pub fn new() -> Self {
        let mut gen = Self {
            registers: [0u16; 100],
        };
        gen.initialize_default_values();
        gen
    }

    fn initialize_default_values(&mut self) {
        // 保持寄存器初始化一些合理的默认值
        self.registers[0] = 3300; // 电压 (3300 = 33.00V)
        self.registers[1] = 500; // 电流 (500 = 5.00A)
        self.registers[2] = 16500; // 功率 (16500 = 165.0W)
        self.registers[3] = 250; // 温度 (250 = 25.0°C)
        self.registers[4] = 1000; // 频率 (1000 = 100.0Hz)
        self.registers[10] = 1; // 状态: 运行中
    }

    /// 读取保持寄存器
    pub fn read_holding_registers(&self, start: u16, count: u16) -> Vec<u16> {
        let start = start as usize;
        let count = count as usize;
        if start + count > self.registers.len() {
            return vec![];
        }
        self.registers[start..start + count].to_vec()
    }

    /// 写入单个寄存器
    pub fn write_single_register(&mut self, address: u16, value: u16) -> bool {
        let addr = address as usize;
        if addr < self.registers.len() {
            self.registers[addr] = value;
            true
        } else {
            false
        }
    }

    /// 更新模拟数据
    pub fn update(&mut self) {
        let mut rng = rand::thread_rng();
        // 添加一些随机波动
        self.registers[0] = self.registers[0].saturating_add_signed(rng.gen_range(-10..10));
        self.registers[1] = self.registers[1].saturating_add_signed(rng.gen_range(-5..5));
        self.registers[3] = self.registers[3].saturating_add_signed(rng.gen_range(-1..1));
    }
}

impl Default for ModbusDataGenerator {
    fn default() -> Self {
        Self::new()
    }
}
