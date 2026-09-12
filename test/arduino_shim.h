/*
 * Minimal Arduino stand-in so the sketch can be compiled and exercised on the
 * host. Records pin writes, fakes a controllable clock, and captures
 * everything the sketch prints.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cctype>
#include <string>

#define LOW    0
#define HIGH   1
#define INPUT  0
#define OUTPUT 1

/* QT Py M0 (variants/qtpy_m0/variant.h) */
#define PIN_A0          (0ul)
#define PIN_A1          (1ul)
#define PIN_A2          (2ul)
#define PIN_A3          (3ul)
#define PIN_SERIAL1_RX  (7ul)
#define PIN_SPI_SCK     (8u)
#define PIN_SPI_MISO    (9u)
#define PIN_SPI_MOSI    (10u)

/* Widest pin number we care about, plus slack. */
static const int SHIM_MAX_PIN = 16;

extern int      shimPinState[SHIM_MAX_PIN];
extern int      shimPinMode[SHIM_MAX_PIN];
extern uint32_t shimMillis;
/* Order matters: catches a pinMode that enables the driver before the output
   register is loaded, which would glitch the relay on boot. */
extern std::string shimPinTrace;

inline void pinMode(uint32_t pin, int mode)
{
  shimPinMode[pin] = mode;
  char buf[32];
  snprintf(buf, sizeof(buf), "M%u=%d;", (unsigned)pin, mode);
  shimPinTrace += buf;
}

inline void digitalWrite(uint32_t pin, int val)
{
  shimPinState[pin] = val;
  char buf[32];
  snprintf(buf, sizeof(buf), "W%u=%d;", (unsigned)pin, val);
  shimPinTrace += buf;
}

inline uint32_t millis(void) { return shimMillis; }

class ShimSerial {
public:
  std::string out;

  void begin(unsigned long) {}
  int available(void) { return 0; }
  int read(void) { return -1; }

  void print(const char* s)   { out += s; }
  void print(char c)          { out += c; }
  void print(int v)           { append("%d", v); }
  void print(unsigned int v)  { append("%u", v); }
  void print(long v)          { append("%ld", v); }
  void print(unsigned long v) { append("%lu", v); }
  void print(unsigned char v) { append("%u", (unsigned)v); }

  void println(void)              { out += "\n"; }
  template <typename T> void println(T v) { print(v); out += "\n"; }

  void clear(void) { out.clear(); }

private:
  template <typename T> void append(const char* fmt, T v)
  {
    char buf[32];
    snprintf(buf, sizeof(buf), fmt, v);
    out += buf;
  }
};

extern ShimSerial Serial;
