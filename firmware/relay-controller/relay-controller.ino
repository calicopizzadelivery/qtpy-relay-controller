/*
 * qtpy-relay-controller — 8-channel relay control over USB serial
 *
 * Target: Adafruit QT Py M0 (SAMD21E18), FQBN adafruit:samd:adafruit_qtpy_m0
 *
 * Wiring / channel map
 * -------------------
 *   Ch  Pad    Arduino pin
 *   1   A0     0
 *   2   A1     1
 *   3   A2     2
 *   4   A3     3
 *   5   MOSI   10
 *   6   MISO   9
 *   7   SCK    8
 *   8   RX     7
 *
 * Relay polarity
 * --------------
 * The relay modules are normally closed: driving a channel HIGH energises the
 * coil, opens the contacts and cuts power to the attached device. This firmware
 * speaks in terms of the *load*, not the coil:
 *
 *   ON  -> pin LOW  -> contacts closed -> device powered
 *   OFF -> pin HIGH -> contacts open   -> device unpowered
 *
 * All channels come up ON, so a reset or reflash never silently drops power.
 * Note that the pins float for a few hundred ms during bootloader startup,
 * before setup() runs; the relay board's own input bias decides the state
 * during that window.
 *
 * Pin 7 is the Serial1 RX pin. Serial1.begin() is never called, so the pin
 * stays a plain GPIO. Do not add Serial1 to this sketch without remapping
 * channel 8.
 *
 * Identity
 * --------
 * Each board stores an eight-byte name (SETID / ID / INFO) in the last row of
 * flash, outside the application image, so it survives a reflash. Several
 * boards can then share a host without a script having to guess which is
 * which. See the identity section further down.
 *
 * Protocol: see printHelp() below, or send HELP.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#if !defined(RELAY_HOST_TEST)
#include <Adafruit_NeoPixel.h>
#endif

#define FW_NAME     "qtpy-relay-controller"
#define FW_VERSION  "1.2.0"

/* Onboard RGB heartbeat: alternates green and blue on a fixed period, so a
   glance at the board tells you the firmware is running and its loop is not
   wedged. Purely a liveness indicator -- it says nothing about relay state. */
#define LED_PERIOD_MS   1000
#define LED_BRIGHTNESS  32      /* of 255; the onboard pixel is very bright */

/*
 * Channel count. A board with fewer relays wired builds the same source with
 * a smaller count; channels are taken from the front of RELAY_PIN, so a
 * one-channel build drives A0 alone. Build a variant with:
 *
 *   arduino-cli compile --build-property compiler.cpp.extra_flags=-DRELAY_CHANNELS=1
 *
 * (compiler.cpp.extra_flags is additive; build.extra_flags would clobber the
 * board's own -D flags.)
 */
#ifndef RELAY_CHANNELS
#define RELAY_CHANNELS 8
#endif

static const uint8_t NUM_RELAYS = RELAY_CHANNELS;

/* Longest command line accepted, including the terminator. */
#define LINE_BUF 64

/* Boot state for every channel: true = powered. */
static const bool BOOT_POWERED = true;

/* Longest accepted pulse, in milliseconds. */
static const uint32_t MAX_PULSE_MS = 3600000UL;

static const uint8_t RELAY_PIN[8] = {
  PIN_A0,          /* ch1  A0   */
  PIN_A1,          /* ch2  A1   */
  PIN_A2,          /* ch3  A2   */
  PIN_A3,          /* ch4  A3   */
  PIN_SPI_MOSI,    /* ch5  MOSI */
  PIN_SPI_MISO,    /* ch6  MISO */
  PIN_SPI_SCK,     /* ch7  SCK  */
  PIN_SERIAL1_RX   /* ch8  RX   */
};

static const char* const RELAY_PAD[8] = {
  "A0", "A1", "A2", "A3", "MOSI", "MISO", "SCK", "RX"
};

static_assert(RELAY_CHANNELS >= 1 && RELAY_CHANNELS <= 8,
              "RELAY_CHANNELS must be between 1 and 8");

static bool     relayPowered[NUM_RELAYS];
static bool     pulseActive[NUM_RELAYS];
static uint32_t pulseDeadline[NUM_RELAYS];   /* millis() value to revert at */
static bool     pulseRestore[NUM_RELAYS];    /* state to revert to */

/* ------------------------------------------------------------------ */
/* Device identity, persisted in flash                                 */
/* ------------------------------------------------------------------ */

/*
 * More than one of these boards hangs off the same host, so each carries an
 * eight-byte name the host can read back and match against. It lives in the
 * last 256-byte row of flash, deliberately outside the application image:
 * neither the UF2 bootloader nor bossac18 (whose upload pattern carries no
 * -e) erases beyond the pages an image covers, so the identity survives a
 * reflash. scripts/build.sh refuses to link an image that would reach it.
 */

#define ID_LEN 8

static const uint32_t ID_MAGIC = 0x52594C52UL;   /* "RLYR" */
static const char     ID_UNSET[] = "UNSET";

struct IdRecord {
  uint32_t magic;
  uint8_t  len;
  uint8_t  id[ID_LEN];
  uint8_t  pad[3];
  uint32_t hash;                             /* must stay the last member */
};

/* NUL-terminated working copy, refreshed from flash at boot. */
static char deviceId[ID_LEN + 1];

#if defined(RELAY_HOST_TEST)
extern uint8_t hostFlashPage[FLASH_PAGE_SIZE];
extern int     hostFlashWrites;
#define ID_STORAGE ((const uint8_t*)hostFlashPage)
#else
#define ID_STORAGE_ADDR (FLASH_SIZE - 256UL)   /* last row of the 256 KB flash */
#define ID_STORAGE      ((const uint8_t*)ID_STORAGE_ADDR)
#endif

/* FNV-1a over every byte ahead of the hash field, so a half-written record
   after a power cut is rejected rather than read back as a name. */
static uint32_t idHash(const IdRecord* r)
{
  uint32_t h = 2166136261UL;
  const uint8_t* p = (const uint8_t*)r;
  for (size_t i = 0; i < offsetof(IdRecord, hash); i++) {
    h ^= p[i];
    h *= 16777619UL;
  }
  return h;
}

#if defined(RELAY_HOST_TEST)
static bool idStorageWrite(const uint8_t* page)
{
  memcpy(hostFlashPage, page, FLASH_PAGE_SIZE);
  hostFlashWrites++;
  return true;
}
#else
static void nvmExec(uint32_t cmd)
{
  NVMCTRL->ADDR.reg  = ID_STORAGE_ADDR / 2;     /* ADDR counts 16-bit words */
  NVMCTRL->CTRLA.reg = cmd | NVMCTRL_CTRLA_CMDEX_KEY;
  while (NVMCTRL->INTFLAG.bit.READY == 0) { }
}

static bool idStorageWrite(const uint8_t* page)
{
  /* Interrupts stay enabled. The SAMD21 has no read-while-write, so the core
     stalls on instruction fetch until the NVM operation retires: a few
     milliseconds of jitter, which USB rides out. Masking interrupts for the
     same window would not help, and would cost the USB SOF handling. */
  NVMCTRL->STATUS.reg = NVMCTRL_STATUS_MASK;    /* write-1-to-clear */

  uint8_t manw = NVMCTRL->CTRLB.bit.MANW;
  NVMCTRL->CTRLB.bit.MANW = 1;                  /* commit only on WP */

  nvmExec(NVMCTRL_CTRLA_CMD_ER);                /* erase the row */
  nvmExec(NVMCTRL_CTRLA_CMD_PBC);               /* clear the page buffer */

  /* The page buffer takes 16- or 32-bit writes only, never bytes. */
  volatile uint32_t* dst = (volatile uint32_t*)ID_STORAGE_ADDR;
  for (uint32_t i = 0; i < FLASH_PAGE_SIZE / 4; i++) {
    uint32_t word;
    memcpy(&word, page + i * 4, sizeof(word));
    dst[i] = word;
  }

  nvmExec(NVMCTRL_CTRLA_CMD_WP);                /* commit */

  NVMCTRL->CTRLB.bit.MANW = manw;

  return (NVMCTRL->STATUS.reg &
          (NVMCTRL_STATUS_PROGE | NVMCTRL_STATUS_LOCKE | NVMCTRL_STATUS_NVME)) == 0;
}
#endif

static void idLoad(void)
{
  IdRecord r;
  memcpy(&r, ID_STORAGE, sizeof(r));

  if (r.magic == ID_MAGIC && r.len >= 1 && r.len <= ID_LEN && r.hash == idHash(&r)) {
    memcpy(deviceId, r.id, r.len);
    deviceId[r.len] = '\0';
  } else {
    strcpy(deviceId, ID_UNSET);               /* erased, or failed its hash */
  }
}

static bool idSave(const char* value, uint8_t len)
{
  uint8_t page[FLASH_PAGE_SIZE];
  memset(page, 0xFF, sizeof(page));

  IdRecord r;
  memset(&r, 0, sizeof(r));                   /* zero the padding it hashes */
  r.magic = ID_MAGIC;
  r.len   = len;
  memcpy(r.id, value, len);
  r.hash  = idHash(&r);
  memcpy(page, &r, sizeof(r));

  if (!idStorageWrite(page)) return false;

  memcpy(deviceId, value, len);
  deviceId[len] = '\0';
  return true;
}

/* 1..8 printable ASCII. Space is excluded because the parser splits on it. */
static bool idValid(const char* s, uint8_t* lenOut)
{
  size_t n = strlen(s);
  if (n < 1 || n > ID_LEN) return false;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x21 || c > 0x7E) return false;
  }
  *lenOut = (uint8_t)n;
  return true;
}

static void printChipSerial(void)
{
#if defined(RELAY_HOST_TEST)
  Serial.print("HOSTTEST");
#else
  /* SAMD21 factory serial: one word at 0x0080A00C, three more at 0x0080A040.
     This is what the core hashes into the USB serial string, so it ties a
     console session to a /dev/serial/by-id path. */
  static const uint32_t addr[4] = {
    0x0080A00CUL, 0x0080A040UL, 0x0080A044UL, 0x0080A048UL
  };
  char buf[9];
  for (int i = 0; i < 4; i++) {
    snprintf(buf, sizeof(buf), "%08lX",
             (unsigned long)(*(volatile uint32_t*)addr[i]));
    Serial.print(buf);
  }
#endif
}

static void printInfo(void)
{
  Serial.print("OK INFO id=");
  Serial.print(deviceId);
  Serial.print(" fw=" FW_NAME " ver=" FW_VERSION " channels=");
  Serial.print((unsigned int)NUM_RELAYS);
  Serial.print(" serial=");
  printChipSerial();
  Serial.println();
}

/* ------------------------------------------------------------------ */
/* Onboard RGB heartbeat                                               */
/* ------------------------------------------------------------------ */

#if defined(RELAY_HOST_TEST)
extern int hostLedGreen;                     /* 1 green, 0 blue, -1 unset */
static void ledBegin(void) { }
static void ledSet(bool green) { hostLedGreen = green ? 1 : 0; }
#else
static Adafruit_NeoPixel pixel(1, PIN_NEOPIXEL, NEO_GRB + NEO_KHZ800);

static void ledBegin(void)
{
  pixel.begin();
  pixel.setBrightness(LED_BRIGHTNESS);
  pixel.show();
}

static void ledSet(bool green)
{
  /* show() bit-bangs with interrupts off, but only for about 30 us for a
     single pixel, which USB does not notice. */
  pixel.setPixelColor(0, green ? pixel.Color(0, 255, 0) : pixel.Color(0, 0, 255));
  pixel.show();
}
#endif

static uint32_t ledLast;
static bool     ledGreen;

/* Unsigned subtraction wraps correctly, so this survives the millis() rollover
   the same way the pulse deadlines do. */
static void serviceHeartbeat(void)
{
  uint32_t now = millis();
  if ((uint32_t)(now - ledLast) >= (uint32_t)LED_PERIOD_MS) {
    ledLast = now;
    ledGreen = !ledGreen;
    ledSet(ledGreen);
  }
}

/* ------------------------------------------------------------------ */
/* Relay primitives                                                    */
/* ------------------------------------------------------------------ */

static inline void driveChannel(uint8_t idx, bool powered)
{
  digitalWrite(RELAY_PIN[idx], powered ? LOW : HIGH);
  relayPowered[idx] = powered;
}

/* Set a channel and cancel any pulse in flight on it. */
static void setChannel(uint8_t idx, bool powered)
{
  pulseActive[idx] = false;
  driveChannel(idx, powered);
}

static void pulseChannel(uint8_t idx, bool powered, uint32_t ms)
{
  /* Revert to whatever the channel was doing before this pulse. If a pulse
     was already running, that is its pending restore state, not the live
     pin state. */
  bool restore = pulseActive[idx] ? pulseRestore[idx] : relayPowered[idx];

  driveChannel(idx, powered);
  pulseRestore[idx]  = restore;
  pulseDeadline[idx] = millis() + ms;
  pulseActive[idx]   = true;
}

/* Revert any pulse whose deadline has passed. Rollover-safe: the subtraction
   is done in signed 32-bit, so it stays correct across the millis() wrap. */
static void servicePulses(void)
{
  uint32_t now = millis();
  for (uint8_t i = 0; i < NUM_RELAYS; i++) {
    if (pulseActive[i] && (int32_t)(now - pulseDeadline[i]) >= 0) {
      pulseActive[i] = false;
      driveChannel(i, pulseRestore[i]);
    }
  }
}

/* ------------------------------------------------------------------ */
/* Reporting                                                           */
/* ------------------------------------------------------------------ */

static void printState(void)
{
  Serial.print("STATE");
  for (uint8_t i = 0; i < NUM_RELAYS; i++) {
    Serial.print(' ');
    Serial.print(i + 1);
    Serial.print('=');
    Serial.print(relayPowered[i] ? "ON" : "OFF");
    if (pulseActive[i]) {
      /* Remaining time, clamped at 0 in case we race the deadline. */
      int32_t remain = (int32_t)(pulseDeadline[i] - millis());
      if (remain < 0) remain = 0;
      Serial.print("(pulse ");
      Serial.print(remain);
      Serial.print("ms)");
    }
  }
  Serial.println();
}

static void printHelp(void)
{
  Serial.println("commands (case-insensitive, one per line):");
  Serial.println("  ON <n>            power channel n on   (pin LOW, relay closed)");
  Serial.println("  OFF <n>           power channel n off  (pin HIGH, relay open)");
  Serial.println("  ON ALL | OFF ALL  all channels at once");
  Serial.println("  ALL ON | ALL OFF  same thing, other word order");
  Serial.println("  RELAY <n> ON|OFF|TOGGLE");
  Serial.println("  TOGGLE <n>|ALL");
  Serial.println("  PULSE <n>|ALL <ms>            invert for <ms>, then revert");
  Serial.println("  PULSE <n>|ALL ON|OFF <ms>     hold that state for <ms>, then revert");
  Serial.println("  GET <n>           report one channel");
  Serial.println("  STATE             report all channels");
  Serial.println("  PINS              report the channel-to-pad map");
  Serial.println("  ID                report this board's identity");
  Serial.println("  SETID <text>      persist a new identity (1-8 chars, no spaces)");
  Serial.println("  INFO              identity, firmware, channel count, chip serial");
  Serial.println("  VERSION           firmware name and version");
  Serial.println("  HELP              this text");
  Serial.print("  channels 1-");
  Serial.print(NUM_RELAYS);
  Serial.print(", pulse 1-");
  Serial.print(MAX_PULSE_MS);
  Serial.println(" ms");
}

static void printPins(void)
{
  for (uint8_t i = 0; i < NUM_RELAYS; i++) {
    Serial.print("PIN ");
    Serial.print(i + 1);
    Serial.print(' ');
    Serial.print(RELAY_PAD[i]);
    Serial.print(" D");
    Serial.println(RELAY_PIN[i]);
  }
}

/* ------------------------------------------------------------------ */
/* Command parsing                                                     */
/* ------------------------------------------------------------------ */

/* 0 = ALL, 1..NUM_RELAYS = one channel, -1 = not a valid target. */
static int parseTarget(const char* s)
{
  if (strcmp(s, "ALL") == 0) return 0;

  char* end;
  unsigned long v = strtoul(s, &end, 10);
  if (end == s || *end != '\0') return -1;
  if (v < 1 || v > NUM_RELAYS) return -1;
  return (int)v;
}

/* 1 = ON, 0 = OFF, -1 = neither. */
static int parseOnOff(const char* s)
{
  if (strcmp(s, "ON") == 0  || strcmp(s, "1") == 0) return 1;
  if (strcmp(s, "OFF") == 0 || strcmp(s, "0") == 0) return 0;
  return -1;
}

/* Returns false if s is not a bare unsigned integer. */
static bool parseMillis(const char* s, uint32_t* out)
{
  char* end;
  unsigned long v = strtoul(s, &end, 10);
  if (end == s || *end != '\0') return false;
  if (v < 1 || v > MAX_PULSE_MS) return false;
  *out = (uint32_t)v;
  return true;
}

static void applyToTarget(int target, bool powered)
{
  if (target == 0) {
    for (uint8_t i = 0; i < NUM_RELAYS; i++) setChannel(i, powered);
  } else {
    setChannel((uint8_t)(target - 1), powered);
  }
}

static void ackTarget(const char* verb, int target, const char* arg)
{
  Serial.print("OK ");
  Serial.print(verb);
  Serial.print(' ');
  if (target == 0) Serial.print("ALL"); else Serial.print(target);
  if (arg) { Serial.print(' '); Serial.print(arg); }
  Serial.println();
}

static int tokenize(char* s, char** out, int maxTok)
{
  int n = 0;
  char* p = s;
  while (*p && n < maxTok) {
    while (*p == ' ' || *p == '\t') p++;
    if (!*p) break;
    out[n++] = p;
    while (*p && *p != ' ' && *p != '\t') p++;
    if (*p) *p++ = '\0';
  }
  return n;
}

static void handleLine(char* line)
{
  /* Commands are matched case-insensitively, but SETID has to preserve the
     case it was given. Tokenising a verbatim copy alongside the uppercased
     one gives both: uppercasing never moves a separator, so the two token
     arrays line up index for index. */
  char raw[LINE_BUF];
  strncpy(raw, line, sizeof(raw) - 1);
  raw[sizeof(raw) - 1] = '\0';

  for (char* p = line; *p; p++) *p = toupper((unsigned char)*p);

  char* tok[5];
  char* rawTok[5];
  int n = tokenize(line, tok, 5);
  tokenize(raw, rawTok, 5);
  if (n == 0) return;                      /* blank line: stay quiet */

  const char* cmd = tok[0];

  if (strcmp(cmd, "HELP") == 0 || strcmp(cmd, "?") == 0) {
    printHelp();
    return;
  }
  if (strcmp(cmd, "VERSION") == 0) {
    Serial.print(FW_NAME);
    Serial.print(' ');
    Serial.println(FW_VERSION);
    return;
  }
  if (strcmp(cmd, "INFO") == 0) {
    printInfo();
    return;
  }
  if (strcmp(cmd, "ID") == 0) {
    Serial.print("OK ID ");
    Serial.println(deviceId);
    return;
  }
  if (strcmp(cmd, "SETID") == 0) {
    if (n < 2) { Serial.println("ERR SETID NEEDS A VALUE"); return; }
    if (n > 2) { Serial.println("ERR ID MUST NOT CONTAIN SPACES"); return; }

    /* rawTok mirrors tok on the untouched line, so the identity keeps the
       case it was sent in even though commands are matched uppercased. */
    const char* value = rawTok[1];
    uint8_t len;
    if (!idValid(value, &len)) {
      Serial.print("ERR BAD ID ");
      Serial.println(tok[1]);
      return;
    }
    if (strcmp(value, deviceId) == 0) {       /* spare the flash a rewrite */
      Serial.print("OK SETID ");
      Serial.println(deviceId);
      return;
    }
    if (!idSave(value, len)) {
      Serial.println("ERR ID WRITE FAILED");
      return;
    }
    Serial.print("OK SETID ");
    Serial.println(deviceId);
    return;
  }
  if (strcmp(cmd, "STATE") == 0 || strcmp(cmd, "STATUS") == 0) {
    printState();
    return;
  }
  if (strcmp(cmd, "PINS") == 0) {
    printPins();
    return;
  }

  /* GET <n> */
  if (strcmp(cmd, "GET") == 0) {
    if (n < 2) { Serial.println("ERR GET NEEDS A CHANNEL"); return; }
    int target = parseTarget(tok[1]);
    if (target < 0) { Serial.print("ERR BAD CHANNEL "); Serial.println(tok[1]); return; }
    if (target == 0) { printState(); return; }
    uint8_t i = (uint8_t)(target - 1);
    Serial.print("OK GET ");
    Serial.print(target);
    Serial.print(' ');
    Serial.println(relayPowered[i] ? "ON" : "OFF");
    return;
  }

  /* ON <n|ALL> / OFF <n|ALL> */
  int direct = parseOnOff(cmd);
  if (direct >= 0) {
    if (n < 2) { Serial.print("ERR "); Serial.print(cmd); Serial.println(" NEEDS A CHANNEL OR ALL"); return; }
    int target = parseTarget(tok[1]);
    if (target < 0) { Serial.print("ERR BAD CHANNEL "); Serial.println(tok[1]); return; }
    applyToTarget(target, direct == 1);
    ackTarget(direct == 1 ? "ON" : "OFF", target, NULL);
    return;
  }

  /* ALL ON / ALL OFF / ALL TOGGLE */
  if (strcmp(cmd, "ALL") == 0) {
    if (n < 2) { Serial.println("ERR ALL NEEDS ON OR OFF"); return; }
    if (strcmp(tok[1], "TOGGLE") == 0) {
      for (uint8_t i = 0; i < NUM_RELAYS; i++) setChannel(i, !relayPowered[i]);
      Serial.println("OK TOGGLE ALL");
      return;
    }
    int want = parseOnOff(tok[1]);
    if (want < 0) { Serial.print("ERR BAD STATE "); Serial.println(tok[1]); return; }
    applyToTarget(0, want == 1);
    ackTarget(want == 1 ? "ON" : "OFF", 0, NULL);
    return;
  }

  /* RELAY <n|ALL> ON|OFF|TOGGLE */
  if (strcmp(cmd, "RELAY") == 0) {
    if (n < 3) { Serial.println("ERR RELAY NEEDS A CHANNEL AND A STATE"); return; }
    int target = parseTarget(tok[1]);
    if (target < 0) { Serial.print("ERR BAD CHANNEL "); Serial.println(tok[1]); return; }
    if (strcmp(tok[2], "TOGGLE") == 0) {
      if (target == 0) for (uint8_t i = 0; i < NUM_RELAYS; i++) setChannel(i, !relayPowered[i]);
      else setChannel((uint8_t)(target - 1), !relayPowered[target - 1]);
      ackTarget("TOGGLE", target, NULL);
      return;
    }
    int want = parseOnOff(tok[2]);
    if (want < 0) { Serial.print("ERR BAD STATE "); Serial.println(tok[2]); return; }
    applyToTarget(target, want == 1);
    ackTarget(want == 1 ? "ON" : "OFF", target, NULL);
    return;
  }

  /* TOGGLE <n|ALL> */
  if (strcmp(cmd, "TOGGLE") == 0) {
    if (n < 2) { Serial.println("ERR TOGGLE NEEDS A CHANNEL OR ALL"); return; }
    int target = parseTarget(tok[1]);
    if (target < 0) { Serial.print("ERR BAD CHANNEL "); Serial.println(tok[1]); return; }
    if (target == 0) for (uint8_t i = 0; i < NUM_RELAYS; i++) setChannel(i, !relayPowered[i]);
    else setChannel((uint8_t)(target - 1), !relayPowered[target - 1]);
    ackTarget("TOGGLE", target, NULL);
    return;
  }

  /* PULSE <n|ALL> [ON|OFF] <ms> */
  if (strcmp(cmd, "PULSE") == 0) {
    if (n < 3) { Serial.println("ERR PULSE NEEDS A CHANNEL AND A DURATION"); return; }
    int target = parseTarget(tok[1]);
    if (target < 0) { Serial.print("ERR BAD CHANNEL "); Serial.println(tok[1]); return; }

    int want;
    uint32_t ms;
    if (n >= 4) {
      want = parseOnOff(tok[2]);
      if (want < 0) { Serial.print("ERR BAD STATE "); Serial.println(tok[2]); return; }
      if (!parseMillis(tok[3], &ms)) { Serial.print("ERR BAD DURATION "); Serial.println(tok[3]); return; }
    } else {
      want = -1;                            /* invert whatever is live */
      if (!parseMillis(tok[2], &ms)) { Serial.print("ERR BAD DURATION "); Serial.println(tok[2]); return; }
    }

    char msbuf[16];
    if (target == 0) {
      for (uint8_t i = 0; i < NUM_RELAYS; i++)
        pulseChannel(i, want < 0 ? !relayPowered[i] : (want == 1), ms);
    } else {
      uint8_t i = (uint8_t)(target - 1);
      pulseChannel(i, want < 0 ? !relayPowered[i] : (want == 1), ms);
    }

    /* Echo the state we pulsed to, so a bare PULSE is unambiguous. Per-channel
       inversion of ALL can differ, so report INVERT in that case. */
    Serial.print("OK PULSE ");
    if (target == 0) Serial.print("ALL"); else Serial.print(target);
    Serial.print(' ');
    if (want < 0) Serial.print(target == 0 ? "INVERT" : (relayPowered[target - 1] ? "ON" : "OFF"));
    else Serial.print(want == 1 ? "ON" : "OFF");
    Serial.print(' ');
    snprintf(msbuf, sizeof(msbuf), "%lu", (unsigned long)ms);
    Serial.println(msbuf);
    return;
  }

  Serial.print("ERR UNKNOWN COMMAND ");
  Serial.println(cmd);
}

/* ------------------------------------------------------------------ */
/* Arduino entry points                                                */
/* ------------------------------------------------------------------ */

void setup(void)
{
  for (uint8_t i = 0; i < NUM_RELAYS; i++) {
    /* Load the output register before enabling the driver, so the pin never
       glitches to the opposite state as it becomes an output. */
    digitalWrite(RELAY_PIN[i], BOOT_POWERED ? LOW : HIGH);
    pinMode(RELAY_PIN[i], OUTPUT);
    driveChannel(i, BOOT_POWERED);
    pulseActive[i] = false;
  }

  idLoad();

  ledBegin();
  ledGreen = true;
  ledLast  = millis();
  ledSet(ledGreen);

  /* Baud is ignored on USB CDC. Never block on !Serial: this board has to run
     headless. */
  Serial.begin(115200);
}

void loop(void)
{
  static char    buf[LINE_BUF];
  static uint8_t len = 0;
  static bool    overflow = false;

  servicePulses();
  serviceHeartbeat();

  while (Serial.available() > 0) {
    char c = (char)Serial.read();

    if (c == '\n' || c == '\r') {
      if (overflow) {
        Serial.println("ERR LINE TOO LONG");
        overflow = false;
      } else {
        buf[len] = '\0';
        handleLine(buf);
      }
      len = 0;
      continue;
    }

    if (len < sizeof(buf) - 1) {
      buf[len++] = c;
    } else {
      overflow = true;                      /* drop the rest of the line */
    }
  }
}
