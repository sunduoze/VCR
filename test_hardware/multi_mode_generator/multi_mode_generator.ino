/**
 * 多功能串口数据生成器 - 上位机性能测试专用
 * 修复：移除 Serial.printf，补全 flashTest 函数
 */

#include "ST7735S_SoftSPI.h"
#include "w25q64.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// ======================= 硬件对象 =======================
ST7735S_SoftSPI tft(PB1, PB0, PA7, PB11, PB10, PA6);
W25Q64 flash;

// ======================= 配置存储 =======================
#define CONFIG_SECTOR_ADDR  0x7FF000
#define CONFIG_MAGIC        0xA5

void saveModeToFlash(uint8_t mode) {
    uint8_t buf[2] = {CONFIG_MAGIC, mode};
    flash.sectorErase(CONFIG_SECTOR_ADDR);
    flash.pageProgram(CONFIG_SECTOR_ADDR, buf, 2);
    Serial.println("Mode saved.");
}

bool loadModeFromFlash(uint8_t *mode) {
    uint8_t buf[2];
    flash.readData(CONFIG_SECTOR_ADDR, buf, 2);
    if (buf[0] == CONFIG_MAGIC && buf[1] >= 1 && buf[1] <= 16) {
        *mode = buf[1];
        return true;
    }
    return false;
}

// ======================= Flash 测试函数 =======================
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
    "1:Fixed CSV", "2:Plot Cmd", "3:Fourier Sq", "4:Lorenz",
    "5:Multi-Wave", "6:ECG", "7:Resp", "8:RandomWalk",
    "9:HighRate", "10:BigPacket", "11:Binary", "12:16Ch",
    "13:Jitter", "14:CPU Load", "15:SweepFreq", "16:Spike"
};
const int MODE_COUNT = 16;

// ======================= LCD 显示 =======================
void updateLCD() {
    tft.fillScreen(TFT_GRAY);
    char line1[24];
    sprintf(line1, "Mode:%d", currentMode);
    tft.showString(5, 2, line1, TFT_BLUE, TFT_GRAY, 16);
    tft.showString(5, 22, modeNames[currentMode-1], TFT_RED, TFT_GRAY, 16);
    tft.showString(5, 44, "mode1~16/help", TFT_GREEN, TFT_GRAY, 16);
    tft.showString(5, 64, "pause5s", TFT_MAGENTA, TFT_GRAY, 16);
}

// ======================= 全局参数（供多模式共用）=======================
// 傅里叶方波参数
const float FREQ = 1.0;
const int SAMPLES_PER_CYCLE = 1000;
const float DT = 1.0 / FREQ / SAMPLES_PER_CYCLE;
const float OMEGA = 2.0 * PI * FREQ;

// 洛伦兹参数
float sigma = 10.0, rho = 28.0, beta = 8.0/3.0;
float lx=0.1, ly=0.0, lz=0.0;
float ldt = 0.01;
unsigned long lastLorenzSend = 0;
const unsigned long LORENZ_INTERVAL = 10;

// 多波形参数
const int WAVE_SAMPLES = 500;
const float WAVE_FREQ = 1.0;

// ======================= 辅助函数 =======================
float fourierSquare(float theta, int n) {
    float s=0; for(int k=1;k<=n;k++) { int h=2*k-1; s+=sinf(h*theta)/h; }
    return 4.0/PI*s;
}
float triangleWave(float t) {
    float phase = fmod(t*WAVE_FREQ, 1.0);
    if(phase<0.25) return 4*phase;
    else if(phase<0.75) return 2-4*(phase-0.25);
    else return 4*(phase-0.75)-2;
}
float sawtoothWave(float t) { return 2.0*fmod(t*WAVE_FREQ,1.0)-1.0; }

// ======================= 模式实现 =======================

// 模式1：固定CSV（高频，10ms间隔）
void runMode1() {
    static unsigned long last=0;
    if(millis()-last>=10) { last=millis(); Serial.print("1234.5,5678.9,9012.3,3456.7,7890.1\r\n"); }
}

// 模式2：Plot指令（500ms）
void runMode2() {
    static unsigned long last=0;
    if(millis()-last>=500) { last=millis(); Serial.println("plot=11.1,22.2,33.3,44.4,55.5"); }
}

// 模式3：傅里叶方波（连续）
static bool m3_head=false;
static int m3_idx=0;
void runMode3() {
    if(!m3_head) { Serial.println("Time,5T,10T,15T,20T"); m3_head=true; }
    float t=m3_idx*DT, th=OMEGA*t;
    char buf[100];
    sprintf(buf,"%.6f,%.6f,%.6f,%.6f,%.6f", t,
            fourierSquare(th,5), fourierSquare(th,10), fourierSquare(th,15), fourierSquare(th,20));
    Serial.println(buf);
    if(++m3_idx > SAMPLES_PER_CYCLE) m3_idx=0;
}

// 模式4：洛伦兹（原始）
void runMode4() {
    float dx=sigma*(ly-lx)*ldt, dy=(lx*(rho-lz)-ly)*ldt, dz=(lx*ly-beta*lz)*ldt;
    lx+=dx; ly+=dy; lz+=dz;
    if(millis()-lastLorenzSend>=LORENZ_INTERVAL) {
        lastLorenzSend=millis();
        Serial.print(lx,6); Serial.print(","); Serial.print(ly,6); Serial.print(","); Serial.println(lz,6);
    }
}

// 模式5：多波形
static bool m5_head=false;
static int m5_idx=0;
void runMode5() {
    if(!m5_head) { Serial.println("Time,Sine,Tri,Saw,Noise"); m5_head=true; }
    float t=m5_idx/(WAVE_FREQ*WAVE_SAMPLES);
    char buf[100];
    sprintf(buf,"%.6f,%.6f,%.6f,%.6f,%.6f", t,
            sin(2*PI*WAVE_FREQ*t), triangleWave(t), sawtoothWave(t),
            ((float)rand()/RAND_MAX)*2-1);
    Serial.println(buf);
    if(++m5_idx > WAVE_SAMPLES) m5_idx=0;
}

// 模式6：ECG
static unsigned long lastECG=0;
static float ecgTime=0;
static bool m6_head=false;
void runMode6() {
    if(!m6_head) { Serial.println("Time,ECG"); m6_head=true; }
    if(millis()-lastECG>=10) {
        lastECG=millis();
        float t=ecgTime, x=fmod(t,1.0)*2*PI;
        float val=0.1*exp(-pow((x-0.4)/0.3,2)) + 0.5*exp(-pow((x-1.0)/0.1,2))
                 -0.2*exp(-pow((x-0.9)/0.05,2)) + 0.25*exp(-pow((x-1.6)/0.2,2)) + 0.05*sin(0.5*2*PI*t);
        Serial.print(t,3); Serial.print(","); Serial.println(val,6);
        ecgTime+=0.01;
    }
}

// 模式7：呼吸
static unsigned long lastResp=0;
static float respTime=0;
static bool m7_head=false;
void runMode7() {
    if(!m7_head) { Serial.println("Time,Resp"); m7_head=true; }
    if(millis()-lastResp>=100) {
        lastResp=millis();
        float val=0.5+0.5*sin(2*PI*0.25*respTime) + ((float)rand()/RAND_MAX)*0.05-0.025;
        Serial.print(respTime,3); Serial.print(","); Serial.println(val,6);
        respTime+=0.1;
    }
}

// 模式8：随机游走
static unsigned long lastWalk=0;
static float walkPos=0;
static bool m8_head=false;
void runMode8() {
    if(!m8_head) { Serial.println("Time,Walk"); m8_head=true; }
    if(millis()-lastWalk>=20) {
        lastWalk=millis();
        walkPos += ((float)rand()/RAND_MAX)*0.1-0.05;
        if(walkPos>5) walkPos=5; if(walkPos<-5) walkPos=-5;
        Serial.print(millis()); Serial.print(","); Serial.println(walkPos,6);
    }
}

// ======================= 新增测试模式 =======================

// 模式9：高数据率模式（每1ms发送一个简单整数，测试上位机极限）
void runMode9() {
    static unsigned long last=0;
    static int cnt=0;
    if(millis()-last>=1) {
        last=millis();
        Serial.print("D"); Serial.print(cnt++); Serial.print(",");
        Serial.println(sin(cnt*0.01)*100, 2);
        if(cnt>9999) cnt=0;
    }
}

// 模式10：大数据包模式（一次发送约512字节，测试缓冲区）
void runMode10() {
    static unsigned long last=0;
    if(millis()-last>=200) {
        last=millis();
        char big[520];
        for(int i=0;i<512;i++) big[i]='A'+(i%26);
        big[512]=',';
        for(int i=0;i<10;i++) big[513+i]='0'+i;
        big[523]=0;
        Serial.println(big);
    }
}

// 模式11：二进制数据模式（发送4个float，原始二进制，需上位机支持）
void runMode11() {
    static unsigned long last=0;
    static float val=0;
    if(millis()-last>=10) {
        last=millis();
        float data[4] = {val, sin(val), cos(val), val*0.1f};
        Serial.write((uint8_t*)data, sizeof(data));
        val += 0.1f;
    }
}

// 模式12：16通道数据（测试多曲线性能）
void runMode12() {
    static unsigned long last=0;
    static int idx=0;
    if(millis()-last>=10) {
        last=millis();
        float t=idx*0.01;
        Serial.print(t,3);
        for(int ch=1;ch<=16;ch++) {
            Serial.print(",");
            Serial.print(sin(2*PI*ch*0.5*t)*10 + ch*5, 2);
        }
        Serial.println();
        idx++;
        if(idx>1000) idx=0;
    }
}

// 模式13：抖动/丢包模拟（随机跳过一些数据包）
void runMode13() {
    static unsigned long last=0;
    if(millis()-last>=10) {
        last=millis();
        if(rand()%10 < 2) return;  // 20%丢包率
        Serial.print(millis()); Serial.print(",");
        Serial.println(sin(millis()*0.001)*100, 2);
    }
}

// 模式14：CPU负载测试（大量浮点运算同时发送数据）
void runMode14() {
    static unsigned long last=0;
    if(millis()-last>=50) {
        last=millis();
        volatile float dummy=0;
        for(int i=0;i<5000;i++) dummy += sinf(i*0.001);
        Serial.print("Load,"); Serial.print(dummy,3); Serial.print(",");
        Serial.println(sin(millis()*0.01)*100, 2);
    }
}

// 模式15：扫频模式（频率从1Hz到100Hz线性扫描，测试上位机动态刷新）
void runMode15() {
    static unsigned long last=0;
    static float freq=1.0;
    static float phase=0;
    if(millis()-last>=5) {
        last=millis();
        phase += freq * 0.005 * 2*PI;
        float val = sin(phase)*100;
        Serial.print(millis()); Serial.print(",");
        Serial.print(val,2); Serial.print(",");
        Serial.println(freq,2);
        freq += 0.1;
        if(freq>100) freq=1;
    }
}

// 模式16：尖峰脉冲模式（测试上位机对突变的响应）
void runMode16() {
    static unsigned long last=0;
    static int cnt=0;
    if(millis()-last>=20) {
        last=millis();
        float val = (cnt%50==0) ? 1000.0 : 0.0;
        Serial.print(millis()); Serial.print(",");
        Serial.println(val,2);
        cnt++;
    }
}

// ======================= 串口命令 =======================
void printHelp() {
    Serial.println("=== Test Modes (1-16) ===");
    char buf[64];
    for(int i=1;i<=16;i++) {
        sprintf(buf, "mode%d - %s", i, modeNames[i-1]);
        Serial.println(buf);
    }
    Serial.println("flash_test - Test W25Q64");
    Serial.println("help/? - this help");
    Serial.println("===========================");
}

void setMode(int newMode) {
    if(newMode<1 || newMode>MODE_COUNT) { Serial.println("Invalid mode"); return; }
    if(newMode==currentMode) return;
    currentMode=newMode;
    updateLCD();
    saveModeToFlash(currentMode);
    // 重置模式状态
    m3_head=false; m3_idx=0;
    m5_head=false; m5_idx=0;
    m6_head=false; ecgTime=0;
    m7_head=false; respTime=0;
    m8_head=false; walkPos=0;
    lx=0.1; ly=0; lz=0;
    outputPaused=true;
    pauseEndTime=millis()+PAUSE_DURATION;
    char msg[64];
    sprintf(msg, "Switched to %s. Paused 5s.", modeNames[currentMode-1]);
    Serial.println(msg);
}

void processSerial() {
    if(!Serial.available()) return;
    String cmd=Serial.readStringUntil('\n');
    cmd.trim();
    if(cmd.length()==0) return;
    if(cmd.startsWith("mode")) {
        int m=atoi(cmd.substring(4).c_str());
        setMode(m);
    } else if(cmd=="flash_test") {
        outputPaused=true; pauseEndTime=millis()+100;
        flashTest();
        outputPaused=true; pauseEndTime=millis()+PAUSE_DURATION;
    } else if(cmd=="help"||cmd=="?"||cmd=="help?") {
        printHelp();
        outputPaused=true; pauseEndTime=millis()+PAUSE_DURATION;
    } else {
        Serial.println("Unknown. Type help");
        outputPaused=true; pauseEndTime=millis()+PAUSE_DURATION;
    }
}

// ======================= 初始化 =======================
void setup() {
    Serial.begin(115200);
    tft.begin(); tft.setBacklight(120); tft.fillScreen(TFT_GRAY);
    flash.begin();
    uint8_t saved;
    if(loadModeFromFlash(&saved)) currentMode=saved;
    else { currentMode=4; saveModeToFlash(currentMode); }
    updateLCD();
    Serial.println("=== Serial Scope Tester ===");
    printHelp();
    outputPaused=true; pauseEndTime=millis()+PAUSE_DURATION;
    randomSeed(analogRead(PA0));
}

// ======================= 主循环 =======================
void loop() {
    processSerial();
    if(outputPaused && millis()>=pauseEndTime) {
        outputPaused=false;
        Serial.println("Resumed.");
    }
    if(!outputPaused) {
        switch(currentMode) {
            case 1: runMode1(); break; case 2: runMode2(); break;
            case 3: runMode3(); break; case 4: runMode4(); break;
            case 5: runMode5(); break; case 6: runMode6(); break;
            case 7: runMode7(); break; case 8: runMode8(); break;
            case 9: runMode9(); break; case 10: runMode10(); break;
            case 11: runMode11(); break; case 12: runMode12(); break;
            case 13: runMode13(); break; case 14: runMode14(); break;
            case 15: runMode15(); break; case 16: runMode16(); break;
            default: currentMode=4; break;
        }
    }
    delay(1);
}
