/*
 * Host-side tests for the relay firmware's command parser and pulse engine.
 * The sketch is #included so the file-static helpers are reachable.
 *
 *   ./test/run-tests.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#define RELAY_HOST_TEST 1
#include "arduino_shim.h"

int         shimPinState[SHIM_MAX_PIN];
int         shimPinMode[SHIM_MAX_PIN];
uint32_t    shimMillis;
std::string shimPinTrace;
ShimSerial  Serial;

/* Stands in for the flash row the firmware persists its identity to. Starts
   erased, exactly as a never-written row reads. */
uint8_t hostFlashPage[FLASH_PAGE_SIZE];
int     hostFlashWrites;
int     hostLedGreen = -1;

#include "../firmware/relay-controller/relay-controller.ino"

#include <iostream>
#include <vector>

static int failures = 0;
static int checks   = 0;

static void check(bool cond, const std::string& what)
{
  checks++;
  if (!cond) {
    failures++;
    std::cout << "  FAIL: " << what << "\n";
  }
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

/* Feed one command line, return everything the firmware printed. */
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

/* true when the channel is powered, i.e. its pin is driven LOW. */
static bool powered(int ch) { return shimPinState[RELAY_PIN[ch - 1]] == LOW; }

static void advance(uint32_t ms)
{
  shimMillis += ms;
  servicePulses();
  serviceHeartbeat();
}

static void section(const char* name) { std::cout << name << "\n"; }

int main(void)
{
  memset(hostFlashPage, 0xFF, sizeof(hostFlashPage));   /* virgin flash */
  hostFlashWrites = 0;
  shimMillis = 1000;
  setup();

  section("boot state");
  {
    bool allOn = true;
    for (int ch = 1; ch <= 8; ch++) if (!powered(ch)) allOn = false;
    check(allOn, "every channel comes up powered");

    for (int ch = 1; ch <= 8; ch++)
      check(shimPinMode[RELAY_PIN[ch - 1]] == OUTPUT, "channel is an output");

    /* The write that loads the output register must precede the pinMode that
       enables the driver, or the pin briefly drives the wrong way. */
    size_t firstWrite = shimPinTrace.find("W0=0;");
    size_t firstMode  = shimPinTrace.find("M0=1;");
    check(firstWrite != std::string::npos && firstMode != std::string::npos &&
          firstWrite < firstMode,
          "output register is loaded before the driver is enabled");

    check(hostLedGreen == 1, "the pixel comes up green");
  }

  section("channel map");
  {
    const uint8_t want[8] = {0, 1, 2, 3, 10, 9, 8, 7};
    for (int i = 0; i < 8; i++)
      check(RELAY_PIN[i] == want[i], "channel maps to the documented pin");
  }

  section("single channel on/off");
  {
    checkEq(cmd("OFF 3"), "OK OFF 3", "OFF 3 acknowledges");
    check(!powered(3), "channel 3 is unpowered");
    check(shimPinState[RELAY_PIN[2]] == HIGH, "channel 3 pin is driven HIGH");
    check(powered(1) && powered(8), "other channels are untouched");

    checkEq(cmd("ON 3"), "OK ON 3", "ON 3 acknowledges");
    check(powered(3), "channel 3 is powered again");

    checkEq(cmd("off 5"), "OK OFF 5", "lowercase is accepted");
    check(!powered(5), "channel 5 is unpowered");
    cmd("ON 5");
  }

  section("all channels");
  {
    checkEq(cmd("OFF ALL"), "OK OFF ALL", "OFF ALL acknowledges");
    for (int ch = 1; ch <= 8; ch++) check(!powered(ch), "channel is unpowered");

    checkEq(cmd("ALL ON"), "OK ON ALL", "ALL ON acknowledges");
    for (int ch = 1; ch <= 8; ch++) check(powered(ch), "channel is powered");
  }

  section("relay and toggle forms");
  {
    checkEq(cmd("RELAY 4 OFF"), "OK OFF 4", "RELAY n OFF acknowledges");
    check(!powered(4), "channel 4 is unpowered");
    checkEq(cmd("TOGGLE 4"), "OK TOGGLE 4", "TOGGLE acknowledges");
    check(powered(4), "TOGGLE restored power");
    checkEq(cmd("RELAY 4 TOGGLE"), "OK TOGGLE 4", "RELAY n TOGGLE acknowledges");
    check(!powered(4), "RELAY TOGGLE cut power");
    cmd("ON 4");
  }

  section("pulse: invert then revert");
  {
    checkEq(cmd("PULSE 1 250"), "OK PULSE 1 OFF 250",
            "bare pulse reports the state it pulsed to");
    check(!powered(1), "channel 1 dropped for the pulse");

    advance(249);
    check(!powered(1), "still pulsing one millisecond short of the deadline");

    advance(1);
    check(powered(1), "reverted exactly on the deadline");
  }

  section("pulse: explicit state");
  {
    cmd("OFF 5");
    checkEq(cmd("PULSE 5 ON 100"), "OK PULSE 5 ON 100", "explicit pulse acknowledges");
    check(powered(5), "channel 5 powered for the pulse");
    advance(100);
    check(!powered(5), "reverted to the pre-pulse OFF, not to ON");
    cmd("ON 5");
  }

  section("pulse: restacking keeps the original restore state");
  {
    cmd("OFF 6");
    cmd("PULSE 6 ON 100");
    advance(50);
    cmd("PULSE 6 ON 100");          /* re-pulse while one is already running */
    advance(100);
    check(!powered(6), "still reverts to the pre-pulse OFF after restacking");
    cmd("ON 6");
  }

  section("pulse: a plain set cancels a pulse in flight");
  {
    cmd("PULSE 7 1000");
    check(!powered(7), "pulse took channel 7 down");
    cmd("ON 7");
    check(powered(7), "explicit ON took effect");
    advance(1000);
    check(powered(7), "the cancelled pulse did not fire later");
  }

  section("pulse: all channels");
  {
    checkEq(cmd("PULSE ALL 200"), "OK PULSE ALL INVERT 200",
            "pulsing all reports INVERT");
    for (int ch = 1; ch <= 8; ch++) check(!powered(ch), "channel inverted");
    advance(200);
    for (int ch = 1; ch <= 8; ch++) check(powered(ch), "channel reverted");
  }

  section("pulse: millis rollover");
  {
    shimMillis = 0xFFFFFF00UL;       /* 256 ms before the wrap */
    cmd("PULSE 2 500");
    check(!powered(2), "pulse started before the wrap");
    advance(499);
    check(!powered(2), "still pulsing across the wrap");
    advance(1);
    check(powered(2), "reverted correctly after millis wrapped");
    check(shimMillis < 1000, "clock really did wrap during this test");
  }

  section("queries");
  {
    cmd("OFF 2");
    checkEq(cmd("GET 2"), "OK GET 2 OFF", "GET reports a single channel");
    cmd("ON 2");
    checkEq(cmd("GET 2"), "OK GET 2 ON", "GET reflects the change");
    checkEq(cmd("STATE"),
            "STATE 1=ON 2=ON 3=ON 4=ON 5=ON 6=ON 7=ON 8=ON",
            "STATE lists every channel");
    cmd("OFF 4");
    checkEq(cmd("STATE"),
            "STATE 1=ON 2=ON 3=ON 4=OFF 5=ON 6=ON 7=ON 8=ON",
            "STATE tracks an off channel");
    cmd("ON 4");
  }

  section("bad input is refused");
  {
    checkEq(cmd("ON 9"),        "ERR BAD CHANNEL 9",     "channel above range");
    checkEq(cmd("ON 0"),        "ERR BAD CHANNEL 0",     "channel below range");
    checkEq(cmd("ON 3X"),       "ERR BAD CHANNEL 3X",    "trailing garbage");
    checkEq(cmd("FROBNICATE"),  "ERR UNKNOWN COMMAND FROBNICATE", "unknown verb");
    checkEq(cmd("PULSE 1 0"),   "ERR BAD DURATION 0",    "zero duration");
    checkEq(cmd("PULSE 1 99999999"), "ERR BAD DURATION 99999999", "over the cap");
    checkEq(cmd("RELAY 1 SIDEWAYS"), "ERR BAD STATE SIDEWAYS", "nonsense state");
    check(cmd("ON").rfind("ERR", 0) == 0, "ON with no channel is refused");
    check(cmd("PULSE 1").rfind("ERR", 0) == 0, "PULSE with no duration is refused");
    checkEq(cmd(""), "", "a blank line says nothing");
    checkEq(cmd("   "), "", "a whitespace-only line says nothing");

    bool untouched = true;
    for (int ch = 1; ch <= 8; ch++) if (!powered(ch)) untouched = false;
    check(untouched, "no bad command disturbed a relay");
  }

  section("whitespace tolerance");
  {
    checkEq(cmd("  OFF   3  "), "OK OFF 3", "extra spaces are ignored");
    cmd("ON 3");
    checkEq(cmd("\tOFF\t3"), "OK OFF 3", "tabs are accepted");
    cmd("ON 3");
  }

  section("heartbeat");
  {
    /* Earlier sections advanced the clock, so the heartbeat phase is arbitrary
       by now. Re-align it before measuring the period. */
    ledLast      = shimMillis;
    ledGreen     = true;
    hostLedGreen = 1;

    advance(999);
    check(hostLedGreen == 1, "holds just short of the period");
    advance(1);
    check(hostLedGreen == 0, "flips to blue on the period");
    advance(1000);
    check(hostLedGreen == 1, "and back to green");

    /* Same rollover exposure as the pulse deadlines. */
    shimMillis = 0xFFFFFF00UL;
    ledLast    = shimMillis;
    int before = hostLedGreen;
    advance(1000);
    check(hostLedGreen != before, "keeps flipping across the millis wrap");
  }

  section("identity: defaults and round-trip");
  {
    checkEq(cmd("ID"), "OK ID UNSET", "an erased row reads back as UNSET");

    checkEq(cmd("SETID relay8"), "OK SETID relay8", "SETID acknowledges");
    checkEq(cmd("ID"), "OK ID relay8", "the identity reads back");
    check(hostFlashWrites == 1, "exactly one flash write");

    /* Reboot: drop the RAM copy and reload from the persisted row. */
    memset(deviceId, 0, sizeof(deviceId));
    idLoad();
    checkEq(cmd("ID"), "OK ID relay8", "the identity survives a reboot");
  }

  section("identity: case is preserved");
  {
    checkEq(cmd("SETID Relay1"), "OK SETID Relay1",
            "mixed case survives the case-insensitive parser");
    checkEq(cmd("ID"), "OK ID Relay1", "and reads back unchanged");
    checkEq(cmd("setid LOWER"), "OK SETID LOWER", "the verb is still case-insensitive");
  }

  section("identity: full eight bytes");
  {
    checkEq(cmd("SETID 12345678"), "OK SETID 12345678", "eight characters fit");
    memset(deviceId, 0, sizeof(deviceId));
    idLoad();
    checkEq(cmd("ID"), "OK ID 12345678", "eight characters survive a reboot");
  }

  section("identity: rewrites are skipped");
  {
    cmd("SETID samename");
    int before = hostFlashWrites;
    checkEq(cmd("SETID samename"), "OK SETID samename", "a no-op SETID still acks");
    check(hostFlashWrites == before, "but does not touch the flash again");
    cmd("SETID relay8");
    check(hostFlashWrites == before + 1, "a genuine change does write");
  }

  section("identity: bad input is refused");
  {
    checkEq(cmd("SETID 123456789"), "ERR BAD ID 123456789", "nine characters is too long");
    checkEq(cmd("SETID a b"), "ERR ID MUST NOT CONTAIN SPACES", "spaces are refused");
    check(cmd("SETID").rfind("ERR", 0) == 0, "SETID with no value is refused");
    checkEq(cmd("SETID a\x7f"), "ERR BAD ID A\x7f", "non-printable bytes are refused");
    checkEq(cmd("ID"), "OK ID relay8", "no refusal disturbed the stored identity");
  }

  section("identity: a corrupt row falls back to UNSET");
  {
    hostFlashPage[6] ^= 0xFF;              /* flip a bit inside the name */
    memset(deviceId, 0, sizeof(deviceId));
    idLoad();
    checkEq(cmd("ID"), "OK ID UNSET", "a failed hash is not read back as a name");

    cmd("SETID relay8");                   /* and it recovers on the next write */
    memset(deviceId, 0, sizeof(deviceId));
    idLoad();
    checkEq(cmd("ID"), "OK ID relay8", "rewriting repairs the row");
  }

  section("identity: INFO");
  {
    checkEq(cmd("INFO"),
            "OK INFO id=relay8 fw=qtpy-relay-controller ver=1.2.0 "
            "channels=8 serial=HOSTTEST",
            "INFO reports identity, firmware, channels and chip serial");
    checkEq(cmd("VERSION"), "qtpy-relay-controller 1.2.0",
            "VERSION no longer doubles as the identity command");
  }

  std::cout << "\n" << (checks - failures) << "/" << checks << " checks passed\n";
  if (failures) std::cout << failures << " FAILED\n";
  return failures ? 1 : 0;
}
