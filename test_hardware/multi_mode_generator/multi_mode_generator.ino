/**
 * 多功能串口数据生成器 + W25Q64 Flash 库 + 模式记忆
 * STM32duino (STM32F103C8T6) + ST7735S 160x80
 * 
 * 依赖库：ST7735S_SoftSPI (用户提供)
 * 自研库：w25q64.h / w25q64.cpp
 */

#include "ST7735S_SoftSPI.h"
#include "w25q64.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// ======================= 屏幕对象 =======================
ST7735S_SoftSPI tft(PB1, PB0, PA7, PB11, PB10, PA6);

// ======================= Flash 对象 =======================
W25Q64 flash;

// ======================= 配置存储 =======================
#define CONFIG_SECTOR_ADDR  0x7FF000   // 最后一个扇区
#define CONFIG_MAGIC        0xA5

void saveModeToFlash(uint8_t mode) {
    uint8_t buf[2] = {CONFIG_MAGIC, mode};
    flash.sectorErase(CONFIG_SECTOR_ADDR);
    flash.pageProgram(CONFIG_SECTOR_ADDR, buf, 2);
    Serial.println("Mode saved to Flash.");
}

bool loadModeFromFlash(uint8_t *mode) {
    uint8_t buf[2];
    flash.readData(CONFIG_SECTOR_ADDR, buf, 2);
    if (buf[0] == CONFIG_MAGIC && buf[1] >= 1 && buf[1] <= 8) {
        *mode = buf[1];
        return true;
    }
    return false;
}

// ======================= Flash 独立测试函数 =======================
void flashTest() {
    Serial.println("\n=== W25Q64 Flash Test ===");
    uint32_t id = flash.readID();
    Serial.print("Device ID: 0x");
    Serial.println(id, HEX);
    if (id != 0xEF4017) {
        Serial.println("ID mismatch! Check wiring.");
        return;
    }
    uint32_t testAddr = 0x000000;
    Serial.print("Erasing sector 0x");
    Serial.println(testAddr, HEX);
    flash.sectorErase(testAddr);
    Serial.println("Erase done.");
    uint8_t writeBuf[256];
    for (int i = 0; i < 256; i++) writeBuf[i] = i;
    Serial.println("Writing 256 bytes...");
    flash.pageProgram(testAddr, writeBuf, 256);
    Serial.println("Write done.");
    uint8_t readBuf[256];
    flash.readData(testAddr, readBuf, 256);
    bool pass = true;
    for (int i = 0; i < 256; i++) {
        if (readBuf[i] != writeBuf[i]) {
            Serial.print("Mismatch at offset ");
            Serial.print(i);
            Serial.print(": expected 0x");
            Serial.print(writeBuf[i], HEX);
            Serial.print(", got 0x");
            Serial.println(readBuf[i], HEX);
            pass = false;
            break;
        }
    }
    if (pass) Serial.println("Flash test PASSED!");
    else Serial.println("Flash test FAILED!");
    Serial.println("=== Test Finished ===\n");
}

// ======================= 系统变量 =======================
int currentMode = 4;
bool outputPaused = false;
unsigned long pauseEndTime = 0;
const unsigned long PAUSE_DURATION = 5000;

const char* modeNames[] = {
    "Mode1: Fixed CSV",
    "Mode2: Plot Cmd",
    "Mode3: Fourier Square",
    "Mode4: Lorenz",
    "Mode5: Multi-Waveform",
    "Mode6: ECG Simulator",
    "Mode7: Respiratory",
    "Mode8: Random Walk"
};
const int MODE_COUNT = 8;

// ======================= LCD 更新 (160x80) =======================
void updateLCD() {
    tft.fillScreen(TFT_GRAY);
    char line1[24];
    sprintf(line1, "CurMode:%d", currentMode);
    tft.showString(5, 2, line1, TFT_BLUE, TFT_GRAY, 16);
    char shortName[20];
    strncpy(shortName, modeNames[currentMode-1], 18);
    shortName[18] = '\0';
    tft.showString(5, 22, shortName, TFT_RED, TFT_GRAY, 16);
    tft.showString(5, 44, "mode1~8/help", TFT_GREEN, TFT_GRAY, 16);
    tft.showString(5, 64, "Pause5s/ cmd", TFT_MAGENTA, TFT_GRAY, 16);
}

// ======================= 工具函数 =======================
void floatToStr(float value, char* buffer) {
    dtostrf(value, 0, 6, buffer);
}

// ======================= 模式1：固定 CSV =======================
void runMode1() {
    static unsigned long lastSend = 0;
    const unsigned long sendInterval = 10;
    if (millis() - lastSend >= sendInterval) {
        lastSend = millis();
        char temp[] = "1234.4567,0334.4567,0634.4567,0934.4567,1234.4567,\
1534.4567,2234.4567,3234.4567,4234.4567,5234.4567,\
6234.4567,7234.4567,8234.4567,9234.4567,1234.4567\r\n";
        Serial.print(temp);
    }
}

// ======================= 模式2：Plot 命令 =======================
void runMode2() {
    static unsigned long lastSend = 0;
    const unsigned long sendInterval = 500;
    if (millis() - lastSend >= sendInterval) {
        lastSend = millis();
        Serial.println("plot=111.4567,222.4567,333.444,555.444,444.4567,333.45");
    }
}

// ======================= 模式3：傅里叶方波 =======================
const float FREQ = 1.0;
const int SAMPLES_PER_CYCLE = 1000;
const int TOTAL_SAMPLES = SAMPLES_PER_CYCLE;
const float DT = 1.0 / (FREQ * SAMPLES_PER_CYCLE);
const float OMEGA = 2.0 * PI * FREQ;

float fourierSquareWave(float theta, int numHarmonics) {
    float sum = 0.0;
    for (int k = 1; k <= numHarmonics; k++) {
        int harmonic = 2 * k - 1;
        sum += sinf(harmonic * theta) / harmonic;
    }
    return (4.0 / PI) * sum;
}

static bool mode3HeaderSent = false;
static int mode3PointIndex = 0;

void runMode3() {
    if (!mode3HeaderSent) {
        Serial.println("Time(s),5Terms,10Terms,15Terms,20Terms");
        mode3HeaderSent = true;
    }
    float t = mode3PointIndex * DT;
    float theta = OMEGA * t;
    float ch1 = fourierSquareWave(theta, 5);
    float ch2 = fourierSquareWave(theta, 10);
    float ch3 = fourierSquareWave(theta, 15);
    float ch4 = fourierSquareWave(theta, 20);

    char lineBuffer[100];
    char temp[12];
    floatToStr(t, temp);
    strcpy(lineBuffer, temp);
    strcat(lineBuffer, ",");
    floatToStr(ch1, temp);
    strcat(lineBuffer, temp);
    strcat(lineBuffer, ",");
    floatToStr(ch2, temp);
    strcat(lineBuffer, temp);
    strcat(lineBuffer, ",");
    floatToStr(ch3, temp);
    strcat(lineBuffer, temp);
    strcat(lineBuffer, ",");
    floatToStr(ch4, temp);
    strcat(lineBuffer, temp);
    Serial.println(lineBuffer);

    mode3PointIndex++;
    if (mode3PointIndex > TOTAL_SAMPLES) mode3PointIndex = 0;
}

// ======================= 模式4：洛伦兹 =======================
float sigma = 10.0, rho = 28.0, beta = 8.0 / 3.0;
float lx = 0.1, ly = 0.0, lz = 0.0;
float ldt = 0.01;
unsigned long lastLorenzSend = 0;
const unsigned long LORENZ_INTERVAL = 10;

void runMode4() {
    float dx = sigma * (ly - lx) * ldt;
    float dy = (lx * (rho - lz) - ly) * ldt;
    float dz = (lx * ly - beta * lz) * ldt;
    lx += dx;
    ly += dy;
    lz += dz;

    if (millis() - lastLorenzSend >= LORENZ_INTERVAL) {
        lastLorenzSend = millis();
        Serial.print(lx, 6);
        Serial.print(",");
        Serial.print(ly, 6);
        Serial.print(",");
        Serial.println(lz, 6);
    }
}

// ======================= 模式5：多波形 =======================
const int WAVE_SAMPLES_PER_CYCLE = 500;
const float WAVE_FREQ = 1.0;
static int waveIndex = 0;
static bool waveHeaderSent = false;

float triangleWave(float t) {
    float period = 1.0 / WAVE_FREQ;
    float phase = fmod(t, period) / period;
    if (phase < 0.25) return 4.0 * phase;
    else if (phase < 0.75) return 2.0 - 4.0 * (phase - 0.25);
    else return 4.0 * (phase - 0.75) - 2.0;
}

float sawtoothWave(float t) {
    float period = 1.0 / WAVE_FREQ;
    float phase = fmod(t, period) / period;
    return 2.0 * phase - 1.0;
}

void runMode5() {
    if (!waveHeaderSent) {
        Serial.println("Time(s),Sine,Triangle,Sawtooth,Noise");
        waveHeaderSent = true;
    }
    float t = waveIndex * (1.0 / (WAVE_FREQ * WAVE_SAMPLES_PER_CYCLE));
    float sineVal = sin(2 * PI * WAVE_FREQ * t);
    float triVal = triangleWave(t);
    float sawVal = sawtoothWave(t);
    float noiseVal = ((float)rand() / RAND_MAX) * 2.0 - 1.0;

    Serial.print(t, 6);
    Serial.print(",");
    Serial.print(sineVal, 6);
    Serial.print(",");
    Serial.print(triVal, 6);
    Serial.print(",");
    Serial.print(sawVal, 6);
    Serial.print(",");
    Serial.println(noiseVal, 6);

    waveIndex++;
    if (waveIndex > WAVE_SAMPLES_PER_CYCLE) waveIndex = 0;
}

// ======================= 模式6：ECG =======================
static unsigned long lastECGSend = 0;
const unsigned long ECG_INTERVAL = 10;
static float ecgTime = 0.0;
static bool ecgHeaderSent = false;

float simulateECG(float t) {
    float period = 1.0;
    float phase = fmod(t, period) / period;
    float x = phase * 2 * PI;
    float ecg = 0.0;
    ecg += 0.1 * exp(-pow((x - 0.2 * 2*PI) / 0.3, 2));
    ecg += 0.5 * exp(-pow((x - 0.5 * 2*PI) / 0.1, 2));
    ecg -= 0.2 * exp(-pow((x - 0.45 * 2*PI) / 0.05, 2));
    ecg += 0.25 * exp(-pow((x - 0.8 * 2*PI) / 0.2, 2));
    ecg += 0.05 * sin(0.5 * 2*PI * t);
    return ecg;
}

void runMode6() {
    if (!ecgHeaderSent) {
        Serial.println("Time(s),ECG");
        ecgHeaderSent = true;
    }
    if (millis() - lastECGSend >= ECG_INTERVAL) {
        lastECGSend = millis();
        float value = simulateECG(ecgTime);
        Serial.print(ecgTime, 3);
        Serial.print(",");
        Serial.println(value, 6);
        ecgTime += ECG_INTERVAL / 1000.0;
    }
}

// ======================= 模式7：呼吸 =======================
static unsigned long lastRespSend = 0;
const unsigned long RESP_INTERVAL = 100;
static float respTime = 0.0;
static bool respHeaderSent = false;

float simulateRespiration(float t) {
    float freq = 0.25;
    float envelope = 0.5 + 0.5 * sin(2 * PI * freq * t);
    float noise = ((float)rand() / RAND_MAX) * 0.05 - 0.025;
    return envelope + noise;
}

void runMode7() {
    if (!respHeaderSent) {
        Serial.println("Time(s),Respiratory");
        respHeaderSent = true;
    }
    if (millis() - lastRespSend >= RESP_INTERVAL) {
        lastRespSend = millis();
        float value = simulateRespiration(respTime);
        Serial.print(respTime, 3);
        Serial.print(",");
        Serial.println(value, 6);
        respTime += RESP_INTERVAL / 1000.0;
    }
}

// ======================= 模式8：随机游走 =======================
static unsigned long lastWalkSend = 0;
const unsigned long WALK_INTERVAL = 20;
static float walkPos = 0.0;
static bool walkHeaderSent = false;

void runMode8() {
    if (!walkHeaderSent) {
        Serial.println("Time(ms),RandomWalk");
        walkHeaderSent = true;
    }
    if (millis() - lastWalkSend >= WALK_INTERVAL) {
        lastWalkSend = millis();
        float step = ((float)rand() / RAND_MAX) * 0.1 - 0.05;
        walkPos += step;
        if (walkPos > 5) walkPos = 5;
        if (walkPos < -5) walkPos = -5;
        Serial.print(millis());
        Serial.print(",");
        Serial.println(walkPos, 6);
    }
}

// ======================= 串口命令 =======================
void printHelp() {
    Serial.println("=== Available Commands ===");
    Serial.println("mode1  - Fixed CSV");
    Serial.println("mode2  - Plot command");
    Serial.println("mode3  - Fourier square wave");
    Serial.println("mode4  - Lorenz attractor (default)");
    Serial.println("mode5  - Multi-waveform (Sine,Tri,Saw,Noise)");
    Serial.println("mode6  - ECG simulator");
    Serial.println("mode7  - Respiratory signal");
    Serial.println("mode8  - Random walk");
    Serial.println("flash_test - Test W25Q64 flash");
    Serial.println("help / ?  - Show this help");
    Serial.println("===========================");
}

void setMode(int newMode) {
    if (newMode < 1 || newMode > MODE_COUNT) {
        Serial.println("Invalid mode. Use mode1~8.");
        return;
    }
    if (newMode == currentMode) return;
    currentMode = newMode;
    updateLCD();
    saveModeToFlash((uint8_t)currentMode);

    // 重置各模式内部状态
    mode3HeaderSent = false;
    mode3PointIndex = 0;
    waveHeaderSent = false;
    waveIndex = 0;
    ecgHeaderSent = false;
    ecgTime = 0.0;
    respHeaderSent = false;
    respTime = 0.0;
    walkHeaderSent = false;
    walkPos = 0.0;
    lx = 0.1; ly = 0.0; lz = 0.0;
    lastLorenzSend = 0;

    outputPaused = true;
    pauseEndTime = millis() + PAUSE_DURATION;
    Serial.print("Switched to ");
    Serial.print(modeNames[currentMode-1]);
    Serial.println(". Output paused for 5 seconds.");
}

void processSerialCommand() {
    if (!Serial.available()) return;
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.length() == 0) return;

    if (cmd == "mode1") setMode(1);
    else if (cmd == "mode2") setMode(2);
    else if (cmd == "mode3") setMode(3);
    else if (cmd == "mode4") setMode(4);
    else if (cmd == "mode5") setMode(5);
    else if (cmd == "mode6") setMode(6);
    else if (cmd == "mode7") setMode(7);
    else if (cmd == "mode8") setMode(8);
    else if (cmd == "flash_test") {
        outputPaused = true;
        pauseEndTime = millis() + 100;
        flashTest();
        outputPaused = true;
        pauseEndTime = millis() + PAUSE_DURATION;
        Serial.println("Test done. Output paused for 5 seconds.");
    }
    else if (cmd == "help" || cmd == "help?" || cmd == "?") {
        printHelp();
        outputPaused = true;
        pauseEndTime = millis() + PAUSE_DURATION;
        Serial.println("Output paused for 5 seconds.");
    } else {
        Serial.print("Unknown: ");
        Serial.println(cmd);
        Serial.println("Type 'help'");
        outputPaused = true;
        pauseEndTime = millis() + PAUSE_DURATION;
    }
}

// ======================= 初始化 =======================
void setup() {
    Serial.begin(115200);
    tft.begin();
    tft.setBacklight(120);
    tft.fillScreen(TFT_GRAY);
    flash.begin();

    Serial.println("=== Multi-Mode Data Generator Started ===");
    Serial.println("W25Q64 driver initialized.");

    uint8_t savedMode;
    if (loadModeFromFlash(&savedMode)) {
        currentMode = savedMode;
        Serial.print("Loaded saved mode: ");
        Serial.println(currentMode);
    } else {
        currentMode = 4;
        Serial.println("No saved mode, using default mode 4.");
        saveModeToFlash((uint8_t)currentMode);
    }
    updateLCD();
    Serial.println("Send 'help' for commands.");
    outputPaused = true;
    pauseEndTime = millis() + PAUSE_DURATION;
    randomSeed(analogRead(PA0));
}

// ======================= 主循环 =======================
void loop() {
    processSerialCommand();
    if (outputPaused && millis() >= pauseEndTime) {
        outputPaused = false;
        Serial.println("Output resumed.");
    }
    if (!outputPaused) {
        switch (currentMode) {
            case 1: runMode1(); break;
            case 2: runMode2(); break;
            case 3: runMode3(); break;
            case 4: runMode4(); break;
            case 5: runMode5(); break;
            case 6: runMode6(); break;
            case 7: runMode7(); break;
            case 8: runMode8(); break;
            default: currentMode = 4; break;
        }
    }
    delay(1);
}
