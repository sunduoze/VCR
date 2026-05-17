#ifndef W25Q64_H
#define W25Q64_H

#include <Arduino.h>

// 引脚配置（可根据需要修改）
#define W25_CS    PB12
#define W25_MOSI  PB15
#define W25_MISO  PB14
#define W25_SCLK  PB13

// W25Q64 容量 8MB (64Mbit)
#define W25_SECTOR_SIZE 4096
#define W25_PAGE_SIZE   256

class W25Q64 {
public:
    W25Q64();
    void begin();                     // 初始化 SPI 引脚
    uint32_t readID();               // 读取设备 ID (0xEF4017)
    void sectorErase(uint32_t addr); // 擦除 4KB 扇区
    void pageProgram(uint32_t addr, const uint8_t *data, uint16_t len); // 页编程（最多256字节）
    void readData(uint32_t addr, uint8_t *buf, uint16_t len);           // 读数据
    void writeEnable();              // 写使能
    void waitBusy();                 // 等待内部操作完成

private:
    void spiInit();
    uint8_t spiTransfer(uint8_t tx);
    void spiDelay();
};

#endif