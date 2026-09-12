/*
 * Host-side tests for the recovery profile: one normally-open relay on TX that
 * grounds the Jetson's FORCE_RECOVERY pin. Its polarity and boot state are
 * both inverted relative to relay8, which is exactly what is worth testing.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#define BOARD_PROFILE 2          /* BOARD_RECOVERY */
#define RELAY_HOST_TEST 1
#include "arduino_shim.h"

int         shimPinState[SHIM_MAX_PIN];
int         shimPinMode[SHIM_MAX_PIN];
uint32_t    shimMillis;
std::string shimPinTrace;
ShimSerial  Serial;

uint8_t hostFlashPage[FLASH_PAGE_SIZE];
int     hostFlashWrites;
int     hostLedR = -1, hostLedG = -1, hostLedB = -1;

#include "../firmware/relay-controller/relay-controller.ino"

#include <iostream>
#include <vector>

static int failures = 0;
static int checks   = 0;

static void check(bool cond, const std::string& what)
{
  checks++;
  if (!cond) { failures++; std::cout << "  FAIL: " << what << "\n"; }
}

static void checkEq(const std::string& got, const std::string& want,
                    const std::string& what)
{
  checks++;
  if (got != want) {
    failures++;
    std::cout << "  FAIL: " << what << "\n"
              << "        want: [" << want << "]\n"
              << "        got:  [" << got  << "]\n";
  }
}

static std::string cmd(const std::string& line)
{
  Serial.clear();
  std::vector<char> buf(line.begin(), line.end());
  buf.push_back('\0');
  handleLine(buf.data());
  std::string out = Serial.out;
  if (!out.empty() && out.back() == '\n') out.pop_back();
  return out;
}

/* The relay is normally open, so asserted == pin HIGH. */
static bool asserted() { return shimPinState[RELAY_PIN[0]] == HIGH; }

static void advance(uint32_t ms)
{
  shimMillis += ms;
  servicePulses();
  serviceHeartbeat();
}

static bool ledIs(int r, int g, int b)
{
  return hostLedR == r && hostLedG == g && hostLedB == b;
}

static void section(const char* name) { std::cout << name << "\n"; }

int main(void)
{
  memset(hostFlashPage, 0xFF, sizeof(hostFlashPage));
  shimMillis = 1000;
  setup();

  section("recovery profile: shape");
  {
    check(NUM_RELAYS == 1, "exactly one channel");
    check(RELAY_PIN[0] == 6, "the channel is on TX, pin 6");
    checkEq(cmd("PINS"), "PIN 1 TX D6", "PINS reports the TX pad");
  }

  section("recovery profile: boots released");
  {
    check(!asserted(), "FORCE_RECOVERY is NOT asserted at boot");
    check(shimPinState[RELAY_PIN[0]] == LOW, "the pin is driven LOW at boot");
    checkEq(cmd("STATE"), "STATE 1=OFF", "STATE agrees it is off");

    /* A reset must never drop the Jetson into recovery, so this is the whole
       point of the inverted boot state. */
    size_t w = shimPinTrace.find("W6=0;");
    size_t m = shimPinTrace.find("M6=1;");
    check(w != std::string::npos && m != std::string::npos && w < m,
          "output register is loaded LOW before the driver is enabled");

    check(ledIs(0, 255, 0), "the pixel comes up green");
  }

  section("recovery profile: inverted polarity");
  {
    checkEq(cmd("ON 1"), "OK ON 1", "ON acknowledges");
    check(asserted(), "ON asserts FORCE_RECOVERY");
    check(shimPinState[RELAY_PIN[0]] == HIGH, "ON drives the pin HIGH");

    checkEq(cmd("OFF 1"), "OK OFF 1", "OFF acknowledges");
    check(!asserted(), "OFF releases FORCE_RECOVERY");
    check(shimPinState[RELAY_PIN[0]] == LOW, "OFF drives the pin LOW");

    checkEq(cmd("ALL ON"), "OK ON ALL", "ALL still works with one channel");
    check(asserted(), "ALL ON asserts");
    cmd("OFF ALL");
    check(!asserted(), "ALL OFF releases");
  }

  section("recovery profile: pulse holds then releases");
  {
    checkEq(cmd("PULSE 1 ON 2000"), "OK PULSE 1 ON 2000", "explicit pulse acks");
    check(asserted(), "asserted for the pulse");
    advance(1999);
    check(asserted(), "still asserted one millisecond short");
    advance(1);
    check(!asserted(), "released exactly on the deadline");

    /* Inverting from released must assert, then fall back to released. */
    checkEq(cmd("PULSE 1 500"), "OK PULSE 1 ON 500", "bare pulse inverts to ON");
    check(asserted(), "asserted");
    advance(500);
    check(!asserted(), "and falls back to released, not to asserted");
  }

  section("recovery profile: out-of-range channels refused");
  {
    checkEq(cmd("ON 2"), "ERR BAD CHANNEL 2", "channel 2 does not exist here");
    checkEq(cmd("ON 8"), "ERR BAD CHANNEL 8", "nor does channel 8");
    check(!asserted(), "and neither refusal asserted recovery");
  }

  section("recovery profile: green/white heartbeat");
  {
    /* Earlier sections advanced the clock, so re-align before measuring. */
    ledLast   = shimMillis;
    ledPhaseA = true;
    ledApply();
    advance(999);
    check(ledIs(0, 255, 0), "holds green just short of the period");
    advance(1);
    check(ledIs(255, 255, 255), "flips to white, not blue");
    advance(1000);
    check(ledIs(0, 255, 0), "and back to green");
  }

  section("recovery profile: INFO and identity");
  {
    checkEq(cmd("SETID recovery"), "OK SETID recovery", "SETID works here too");
    checkEq(cmd("INFO"),
            "OK INFO id=recovery fw=qtpy-relay-controller ver=1.3.0 "
            "profile=recovery channels=1 serial=HOSTTEST",
            "INFO reports the recovery profile and one channel");
  }

  std::cout << "\n" << (checks - failures) << "/" << checks << " checks passed\n";
  if (failures) std::cout << failures << " FAILED\n";
  return failures ? 1 : 0;
}
