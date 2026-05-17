#ifndef __ST7735S_SOFTSPI_H
#define __ST7735S_SOFTSPI_H

#include <Arduino.h>

/* 屏幕物理分辨率（已设为横屏 160x80） */
#define TFT_WIDTH  160
#define TFT_HEIGHT 80

/* 常用颜色定义（RGB565） */
#define TFT_WHITE       0xFFFF
#define TFT_BLACK       0x0000
#define TFT_RED         0xF800
#define TFT_GREEN       0x07E0
#define TFT_BLUE        0x001F
#define TFT_CYAN        0x07FF
#define TFT_MAGENTA     0xF81F
#define TFT_YELLOW      0xFFE0
#define TFT_GRAY        0x8430

class ST7735S_SoftSPI {
public:
  ST7735S_SoftSPI(int8_t cs, int8_t dc, int8_t rst, int8_t mosi, int8_t sclk, int8_t led);
  void begin();
  void setBacklight(uint8_t brightness);         // 0~255（需目标引脚支持 PWM）
  void fillScreen(uint16_t color);
  void drawPixel(int16_t x, int16_t y, uint16_t color);
  void fillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t color);
  void drawLine(int16_t x1, int16_t y1, int16_t x2, int16_t y2, uint16_t color);
  void drawRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t color);
  void drawCircle(int16_t x0, int16_t y0, uint8_t r, uint16_t color);
  void showChar(int16_t x, int16_t y, char ch, uint16_t fc, uint16_t bc, uint8_t sizey, bool overlay = false);
  void showString(int16_t x, int16_t y, const char *str, uint16_t fc, uint16_t bc, uint8_t sizey, bool overlay = false);
  void showIntNum(int16_t x, int16_t y, uint16_t num, uint8_t len, uint16_t fc, uint16_t bc, uint8_t sizey);
  void showFloatNum1(int16_t x, int16_t y, float num, uint8_t len, uint16_t fc, uint16_t bc, uint8_t sizey); // 固定保留两位小数
  void showPicture(int16_t x, int16_t y, int16_t width, int16_t height, const uint8_t *bmp);

private:
  int8_t _cs, _dc, _rst, _mosi, _sclk, _led;
  void writeCommand(uint8_t cmd);
  void writeData(uint8_t data);
  void writeData16(uint16_t data);
  void setAddrWindow(int16_t x1, int16_t y1, int16_t x2, int16_t y2);
  void spiWrite(uint8_t data);
  void resetDisplay();
  uint32_t mypow(uint8_t m, uint8_t n);
};

#endif