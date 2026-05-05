/**
 * 硬件流控制测试程序
 * 
 * 配合上位机 Lua 脚本 13_hardware_flow_control.lua 使用
 * 
 * 硬件连接:
 *   Arduino UNO/Nano
 *   D0 (RX)  <-- PC UART TX
 *   D1 (TX)  --> PC UART RX
 *   D7       --> PC DSR     (Arduino 输出, 模拟 DTR 给 PC)
 *   D11      <-- PC RTS     (Arduino 输入, 接收 PC 的 RTS 信号)
 *   D12      --> PC CTS     (Arduino 输出, 模拟 RTS 给 PC)
 *   D13      <-- PC DTR     (Arduino 输入, 接收 PC 的 DTR 信号, 板载 LED)
 *   GND      <-> GND
 * 
 * 串口命令:
 *   RTS 0/1    - 控制 D12 (PC CTS 输入)
 *   DTR 0/1    - 控制 D7  (PC DSR 输入)
 *   STATUS     - 回显所有信号状态
 *   BLINK <n>  - 闪烁 D7 指定次数
 * 
 * 上位机设备配置:
 *   流控选择: Hardware (硬件流控)
 *   波特率: 115200
 */

// 引脚定义
const int PIN_DSR_OUT    = 7;   // -> PC DSR
const int PIN_CTS_IN     = 11;  // <- PC RTS (输入)
const int PIN_RTS_OUT    = 12;  // -> PC CTS
const int PIN_DTR_IN     = 13;  // <- PC DTR (板载LED)

// 上一次信号状态 (用于变化检测)
bool lastDTR = false;
bool lastCTS = false;

void setup() {
    Serial.begin(115200);
    
    // 等待串口就绪
    while (!Serial) {
        ; // 某些板子需要等待 USB CDC
    }
    
    // 引脚配置
    pinMode(PIN_DSR_OUT, OUTPUT);   // D7 -> PC DSR
    pinMode(PIN_RTS_OUT, OUTPUT);   // D12 -> PC CTS
    pinMode(PIN_CTS_IN, INPUT);     // D11 <- PC RTS
    pinMode(PIN_DTR_IN, INPUT);     // D13 <- PC DTR (板载LED)
    
    // 初始状态
    digitalWrite(PIN_DSR_OUT, LOW);
    digitalWrite(PIN_RTS_OUT, LOW);
    
    Serial.println();
    Serial.println(F('================================'));
    Serial.println(F('  Hardware Flow Control Test'));
    Serial.println(F('================================'));
    Serial.println(F('Commands: RTS 0|1, DTR 0|1, STATUS, BLINK <n>'));
    Serial.println();
    printStatus();
}

void loop() {
    // 处理串口命令
    if (Serial.available()) {
        String cmd = Serial.readStringUntil('\n');
        cmd.trim();
        processCommand(cmd);
    }
    
    // 实时监测 PC DTR 和 RTS 信号变化
    bool currentDTR = digitalRead(PIN_DTR_IN) == HIGH;
    bool currentCTS = digitalRead(PIN_CTS_IN) == HIGH;
    
    if (currentDTR != lastDTR) {
        Serial.print(F('[SIGNAL] DTR changed: '));
        Serial.print(lastDTR ? F('HIGH') : F('LOW'));
        Serial.print(F(' -> '));
        Serial.println(currentDTR ? F('HIGH') : F('LOW'));
        lastDTR = currentDTR;
    }
    
    if (currentCTS != lastCTS) {
        Serial.print(F('[SIGNAL] CTS (PC RTS) changed: '));
        Serial.print(lastCTS ? F('HIGH') : F('LOW'));
        Serial.print(F(' -> '));
        Serial.println(currentCTS ? F('HIGH') : F('LOW'));
        lastCTS = currentCTS;
    }
}

void processCommand(String cmd) {
    cmd.toUpperCase();
    
    if (cmd.startsWith(F('RTS'))) {
        // RTS 0 或 RTS 1 - 控制 D12 (连接到 PC CTS)
        int value = cmd.substring(3).trim().toInt();
        if (value == 1) {
            digitalWrite(PIN_RTS_OUT, HIGH);
            Serial.println(F('[OK] RTS -> HIGH (PC CTS should be HIGH)'));
        } else {
            digitalWrite(PIN_RTS_OUT, LOW);
            Serial.println(F('[OK] RTS -> LOW (PC CTS should be LOW)'));
        }
    }
    else if (cmd.startsWith(F('DTR'))) {
        // DTR 0 或 DTR 1 - 控制 D7 (连接到 PC DSR)
        int value = cmd.substring(3).trim().toInt();
        if (value == 1) {
            digitalWrite(PIN_DSR_OUT, HIGH);
            Serial.println(F('[OK] DTR -> HIGH (PC DSR should be HIGH)'));
        } else {
            digitalWrite(PIN_DSR_OUT, LOW);
            Serial.println(F('[OK] DTR -> LOW (PC DSR should be LOW)'));
        }
    }
    else if (cmd == F('STATUS')) {
        printStatus();
    }
    else if (cmd.startsWith(F('BLINK'))) {
        // BLINK <n> - 闪烁 D7 指定次数
        int count = cmd.substring(5).trim().toInt();
        if (count <= 0) count = 3;
        if (count > 20) count = 20;
        Serial.print(F('[OK] Blinking D7 (PC DSR) '));
        Serial.print(count);
        Serial.println(F(' times'));
        for (int i = 0; i < count; i++) {
            digitalWrite(PIN_DSR_OUT, HIGH);
            delay(300);
            digitalWrite(PIN_DSR_OUT, LOW);
            delay(300);
        }
        Serial.println(F('[OK] Blink done'));
    }
    else if (cmd.length() > 0) {
        Serial.print(F('[ERR] Unknown command: '));
        Serial.println(cmd);
    }
}

void printStatus() {
    Serial.println(F('--- Signal Status ---'));
    Serial.print(F('  D7  (-> PC DSR) : '));
    Serial.println(digitalRead(PIN_DSR_OUT) ? F('HIGH') : F('LOW'));
    Serial.print(F('  D11 (<- PC RTS) : '));
    Serial.println(digitalRead(PIN_CTS_IN) ? F('HIGH') : F('LOW'));
    Serial.print(F('  D12 (-> PC CTS) : '));
    Serial.println(digitalRead(PIN_RTS_OUT) ? F('HIGH') : F('LOW'));
    Serial.print(F('  D13 (<- PC DTR) : '));
    Serial.println(digitalRead(PIN_DTR_IN) ? F('HIGH') : F('LOW'));
    Serial.println(F('--------------------'));
}
