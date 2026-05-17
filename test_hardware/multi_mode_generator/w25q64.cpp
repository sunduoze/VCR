#include "w25q64.h"

W25Q64::W25Q64() {}

void W25Q64::spiDelay() {
    for (volatile int i = 0; i < 5; i++);
}

void W25Q64::spiInit() {
    pinMode(W25_CS, OUTPUT);
    pinMode(W25_MOSI, OUTPUT);
    pinMode(W25_MISO, INPUT);
    pinMode(W25_SCLK, OUTPUT);
    digitalWrite(W25_CS, HIGH);
    digitalWrite(W25_SCLK, LOW);
    digitalWrite(W25_MOSI, LOW);
}

uint8_t W25Q64::spiTransfer(uint8_t tx) {
    uint8_t rx = 0;
    for (int i = 7; i >= 0; i--) {
        digitalWrite(W25_SCLK, LOW);
        spiDelay();
        digitalWrite(W25_MOSI, (tx >> i) & 0x01);
        spiDelay();
        digitalWrite(W25_SCLK, HIGH);
        spiDelay();
        if (digitalRead(W25_MISO))
            rx |= (1 << i);
    }
    digitalWrite(W25_SCLK, LOW);
    return rx;
}

void W25Q64::begin() {
    spiInit();
}

uint32_t W25Q64::readID() {
    uint32_t id = 0;
    digitalWrite(W25_CS, LOW);
    spiTransfer(0x9F);  // RDID
    id |= ((uint32_t)spiTransfer(0x00) << 16);
    id |= ((uint32_t)spiTransfer(0x00) << 8);
    id |= spiTransfer(0x00);
    digitalWrite(W25_CS, HIGH);
    return id;
}

void W25Q64::writeEnable() {
    digitalWrite(W25_CS, LOW);
    spiTransfer(0x06);
    digitalWrite(W25_CS, HIGH);
}

void W25Q64::waitBusy() {
    digitalWrite(W25_CS, LOW);
    spiTransfer(0x05);  // RDSR1
    uint8_t status;
    do {
        status = spiTransfer(0x00);
    } while (status & 0x01);
    digitalWrite(W25_CS, HIGH);
}

void W25Q64::sectorErase(uint32_t addr) {
    writeEnable();
    digitalWrite(W25_CS, LOW);
    spiTransfer(0x20);  // Sector Erase (4KB)
    spiTransfer((addr >> 16) & 0xFF);
    spiTransfer((addr >> 8) & 0xFF);
    spiTransfer(addr & 0xFF);
    digitalWrite(W25_CS, HIGH);
    waitBusy();
}

void W25Q64::pageProgram(uint32_t addr, const uint8_t *data, uint16_t len) {
    if (len > W25_PAGE_SIZE) len = W25_PAGE_SIZE;
    writeEnable();
    digitalWrite(W25_CS, LOW);
    spiTransfer(0x02);  // Page Program
    spiTransfer((addr >> 16) & 0xFF);
    spiTransfer((addr >> 8) & 0xFF);
    spiTransfer(addr & 0xFF);
    for (uint16_t i = 0; i < len; i++) {
        spiTransfer(data[i]);
    }
    digitalWrite(W25_CS, HIGH);
    waitBusy();
}

void W25Q64::readData(uint32_t addr, uint8_t *buf, uint16_t len) {
    digitalWrite(W25_CS, LOW);
    spiTransfer(0x03);  // Read Data
    spiTransfer((addr >> 16) & 0xFF);
    spiTransfer((addr >> 8) & 0xFF);
    spiTransfer(addr & 0xFF);
    for (uint16_t i = 0; i < len; i++) {
        buf[i] = spiTransfer(0x00);
    }
    digitalWrite(W25_CS, HIGH);
}