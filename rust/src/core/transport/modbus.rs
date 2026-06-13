const MODBUS_RTU_CRC_POLY: u16 = 0xA001;

pub struct ModbusCodec;

impl ModbusCodec {
    pub fn calculate_crc(data: &[u8]) -> u16 {
        let mut crc: u16 = 0xFFFF;
        for &byte in data {
            crc ^= byte as u16;
            for _ in 0..8 {
                if crc & 0x0001 != 0 {
                    crc = (crc >> 1) ^ MODBUS_RTU_CRC_POLY;
                } else {
                    crc >>= 1;
                }
            }
        }
        crc
    }

    pub fn verify_crc(data: &[u8]) -> bool {
        if data.len() < 3 {
            return false;
        }
        let payload = &data[..data.len() - 2];
        let crc_bytes = &data[data.len() - 2..];
        let expected_crc = u16::from_le_bytes([crc_bytes[0], crc_bytes[1]]);
        Self::calculate_crc(payload) == expected_crc
    }

    pub fn append_crc(data: &mut Vec<u8>) {
        let crc = Self::calculate_crc(data);
        data.push((crc & 0xFF) as u8);
        data.push(((crc >> 8) & 0xFF) as u8);
    }
}

#[derive(Clone, Debug, Copy, PartialEq)]
pub enum ModbusFunction {
    ReadCoils = 0x01,
    ReadDiscreteInputs = 0x02,
    ReadHoldingRegisters = 0x03,
    ReadInputRegisters = 0x04,
    WriteSingleCoil = 0x05,
    WriteSingleRegister = 0x06,
    WriteMultipleCoils = 0x0F,
    WriteMultipleRegisters = 0x10,
}

#[derive(Clone, Debug)]
pub struct ModbusRequest {
    pub slave_id: u8,
    pub function: ModbusFunction,
    pub address: u16,
    pub quantity: u16,
    pub data: Vec<u8>,
}

impl ModbusRequest {
    pub fn read_holding_registers(slave_id: u8, address: u16, quantity: u16) -> Self {
        Self {
            slave_id,
            function: ModbusFunction::ReadHoldingRegisters,
            address,
            quantity,
            data: Vec::new(),
        }
    }

    pub fn write_single_register(slave_id: u8, address: u16, value: u16) -> Self {
        Self {
            slave_id,
            function: ModbusFunction::WriteSingleRegister,
            address,
            quantity: 1,
            data: value.to_be_bytes().to_vec(),
        }
    }

    pub fn write_multiple_registers(slave_id: u8, address: u16, values: &[u16]) -> Self {
        let mut data = vec![(values.len() * 2) as u8];
        for &v in values {
            data.extend_from_slice(&v.to_be_bytes());
        }
        Self {
            slave_id,
            function: ModbusFunction::WriteMultipleRegisters,
            address,
            quantity: values.len() as u16,
            data,
        }
    }

    pub fn encode_rtu(&self) -> Vec<u8> {
        let mut frame = Vec::new();
        frame.push(self.slave_id);
        frame.push(self.function as u8);
        frame.extend_from_slice(&self.address.to_be_bytes());
        frame.extend_from_slice(&self.quantity.to_be_bytes());
        frame.extend_from_slice(&self.data);
        ModbusCodec::append_crc(&mut frame);
        frame
    }

    pub fn encode_tcp(&self, transaction_id: u16) -> Vec<u8> {
        let mut frame = Vec::new();
        frame.extend_from_slice(&transaction_id.to_be_bytes());
        frame.extend_from_slice(&0u16.to_be_bytes());
        let length = 2 + 4 + self.data.len() as u16;
        frame.extend_from_slice(&length.to_be_bytes());
        frame.push(self.slave_id);
        frame.push(self.function as u8);
        frame.extend_from_slice(&self.address.to_be_bytes());
        frame.extend_from_slice(&self.quantity.to_be_bytes());
        frame.extend_from_slice(&self.data);
        frame
    }
}

#[derive(Clone, Debug)]
pub struct ModbusResponse {
    pub slave_id: u8,
    pub function: u8,
    pub data: Vec<u8>,
}

impl ModbusResponse {
    pub fn parse_rtu(data: &[u8]) -> Option<Self> {
        if data.len() < 5 || !ModbusCodec::verify_crc(data) {
            return None;
        }
        Some(Self {
            slave_id: data[0],
            function: data[1],
            data: data[2..data.len() - 2].to_vec(),
        })
    }

    pub fn get_registers(&self) -> Vec<u16> {
        if self.function == 0x03 && self.data.len() > 1 {
            let byte_count = self.data[0] as usize;
            let mut registers = Vec::new();
            for i in 0..(byte_count / 2) {
                let offset = 1 + i * 2;
                if offset + 1 < self.data.len() {
                    registers.push(u16::from_be_bytes([
                        self.data[offset],
                        self.data[offset + 1],
                    ]));
                }
            }
            registers
        } else {
            Vec::new()
        }
    }
}
