#!/bin/bash
# Runs the public CPU/BIOS/memory test ROMs through the headless harness and prints a table.
# (`swift test` silently runs zero tests under the Command Line Tools, so the harness is the test runner.)
# Exit status is non-zero if any ROM that is EXPECTED to pass does not.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG" --product gba-harness 2>&1 | grep -E "error:" && exit 2
swift build -c "$CONFIG" --product gbaui-harness 2>&1 | grep -E "error:" && exit 2
HARNESS=".build/$CONFIG/gba-harness"
ROMS=TestROMs/jsmolka-gba-tests

# name | path | expectation  (pass = must pass; todo:<milestone> = known not to pass yet)
TESTS=(
  "ARM instruction set|arm/arm.gba|pass"
  "Thumb instruction set|thumb/thumb.gba|pass"
  "Memory map & bus quirks|memory/memory.gba|pass"
  "BIOS behaviour & IRQ|bios/bios.gba|pass"
  "CPU pipeline / DMA / VRAM exec|nes/nes.gba|pass"
  "Unusual hardware behaviour|unsafe/unsafe.gba|pass"
  "Save: no save type|save/none.gba|pass"
  "Save: SRAM|save/sram.gba|pass"
  "Save: Flash 64K|save/flash64.gba|pass"
  "Save: Flash 128K|save/flash128.gba|pass"
)
fail=0
printf "%-34s %-9s %s\n" "TEST" "RESULT" "DETAIL"
for t in "${TESTS[@]}"; do
  IFS='|' read -r name path expect <<<"$t"
  out=$("$HARNESS" "$ROMS/$path" --max-cycles 800000000 2>&1)
  if grep -q "^PASS" <<<"$out"; then res="PASS"; detail=""
  else res="FAIL"; detail=$(grep -E "^FAIL|TIMED OUT" <<<"$out" | head -1); fi
  if [[ "$expect" == pass && "$res" != PASS ]]; then fail=1; res="FAIL*"; fi
  [[ "$expect" == todo:* ]] && detail="${detail:+$detail  }(expected: ${expect#todo:})"
  printf "%-34s %-9s %s\n" "$name" "$res" "$detail"
done
# --- Game Boy / Game Boy Color ---------------------------------------------------------------
GB=TestROMs/gb-test-roms
# name | rom | frames | expectation  (Blargg's ROMs print "Passed"/"Failed" over serial or into cartridge RAM)
GBTESTS=(
  "GB CPU: 01 special|$GB/src/cpu_instrs/individual/01-special.gb|600|pass"
  "GB CPU: 02 interrupts|$GB/src/cpu_instrs/individual/02-interrupts.gb|600|pass"
  "GB CPU: 03 op sp,hl|$GB/src/cpu_instrs/individual/03-op sp,hl.gb|600|pass"
  "GB CPU: 04 op r,imm|$GB/src/cpu_instrs/individual/04-op r,imm.gb|600|pass"
  "GB CPU: 05 op rp|$GB/src/cpu_instrs/individual/05-op rp.gb|600|pass"
  "GB CPU: 06 ld r,r|$GB/src/cpu_instrs/individual/06-ld r,r.gb|600|pass"
  "GB CPU: 07 jr,jp,call,ret,rst|$GB/src/cpu_instrs/individual/07-jr,jp,call,ret,rst.gb|600|pass"
  "GB CPU: 08 misc instrs|$GB/src/cpu_instrs/individual/08-misc instrs.gb|600|pass"
  "GB CPU: 09 op r,r|$GB/src/cpu_instrs/individual/09-op r,r.gb|1000|pass"
  "GB CPU: 10 bit ops|$GB/src/cpu_instrs/individual/10-bit ops.gb|1000|pass"
  "GB CPU: 11 op a,(hl)|$GB/src/cpu_instrs/individual/11-op a,(hl).gb|1000|pass"
  "GB CPU: all 11 + MBC1|$GB/src/cpu_instrs/cpu_instrs.gb|4000|pass"
  "GB instruction timing|$GB/src/instr_timing/instr_timing.gb|600|pass"
  "GB memory timing: read|$GB/src/mem_timing/individual/01-read_timing.gb|600|pass"
  "GB memory timing: write|$GB/src/mem_timing/individual/02-write_timing.gb|600|pass"
  "GB memory timing: modify|$GB/src/mem_timing/individual/03-modify_timing.gb|600|pass"
  "GB memory timing 2|$GB/src/mem_timing-2/mem_timing.gb|600|pass"
  "GB sound: 01 registers|$GB/src/dmg_sound/rom_singles/01-registers.gb|2000|pass"
  "GB sound: 02 length counter|$GB/src/dmg_sound/rom_singles/02-len ctr.gb|2000|pass"
  "GB sound: 03 trigger|$GB/src/dmg_sound/rom_singles/03-trigger.gb|2000|pass"
  "GB sound: 04 sweep|$GB/src/dmg_sound/rom_singles/04-sweep.gb|2000|pass"
  "GB sound: 05 sweep details|$GB/src/dmg_sound/rom_singles/05-sweep details.gb|2000|pass"
  "GB sound: 06 overflow on trigger|$GB/src/dmg_sound/rom_singles/06-overflow on trigger.gb|2000|pass"
  "GB sound: 07 len/sweep sync|$GB/src/dmg_sound/rom_singles/07-len sweep period sync.gb|2000|pass"
  "GB sound: 08 length during power|$GB/src/dmg_sound/rom_singles/08-len ctr during power.gb|2000|pass"
  "GB sound: 09 wave read while on|$GB/src/dmg_sound/rom_singles/09-wave read while on.gb|2000|todo:wave RAM access while playing"
  "GB sound: 10 wave trigger while on|$GB/src/dmg_sound/rom_singles/10-wave trigger while on.gb|2000|todo:wave RAM corruption on retrigger"
  "GB sound: 11 registers after power|$GB/src/dmg_sound/rom_singles/11-regs after power.gb|2000|pass"
  "GB sound: 12 wave write while on|$GB/src/dmg_sound/rom_singles/12-wave write while on.gb|2000|todo:wave RAM access while playing"
  "GB OAM bug|$GB/src/oam_bug/oam_bug.gb|2000|todo:OAM corruption bug not modelled"
)
for t in "${GBTESTS[@]}"; do
  IFS='|' read -r name rom frames expect <<<"$t"
  out=$("$HARNESS" --gb "$rom" --max-frames "$frames" --quiet 2>&1 | tail -1)
  if grep -q ": PASS" <<<"$out"; then res="PASS"; detail=""; else res="FAIL"; detail=$(sed 's/  pc=.*//' <<<"$out"); fi
  if [[ "$expect" == pass && "$res" != PASS ]]; then fail=1; res="FAIL*"; fi
  [[ "$expect" == todo:* ]] && detail="${detail:+$detail  }(expected: ${expect#todo:})"
  printf "%-34s %-9s %s\n" "$name" "$res" "$detail"
done
# ROMs that only report on screen: compare the screen with a hash recorded after confirming "Passed" by eye
for t in "GB halt bug|$GB/src/halt_bug.gb|300|07D16CFA" "GB interrupt timing (CGB)|$GB/src/interrupt_time/interrupt_time.gb|300|ACC065A9"; do
  IFS='|' read -r name rom frames want <<<"$t"
  got=$("$HARNESS" --gb-screen-hash "$rom" --max-frames "$frames" 2>&1 | tail -1)
  if [[ "$got" == "$want" ]]; then res="PASS"; detail=""; else res="FAIL*"; fail=1; detail="screen hash $got, expected $want"; fi
  printf "%-34s %-9s %s\n" "$name" "$res" "$detail"
done
# Picture tests: the screen must match the reference image pixel for pixel
for t in "GB picture: dmg-acid2|$GB/acid2/dmg-acid2.gb|$GB/acid2/dmg-acid2-reference.png" "GB picture: cgb-acid2|$GB/acid2/cgb-acid2.gbc|$GB/acid2/cgb-acid2-reference.png"; do
  IFS='|' read -r name rom ref <<<"$t"
  out=$("$HARNESS" --gb-picture "$rom" "$ref" 2>&1 | tail -1)
  if grep -q ": PASS" <<<"$out"; then res="PASS"; detail=""; else res="FAIL*"; fail=1; detail="$out"; fi
  printf "%-34s %-9s %s\n" "$name" "$res" "$detail"
done

# The app's engine layer, headless (session pacing at every speed, autosave, recording, rendering up to 16K). Takes about a minute.
out=$(".build/$CONFIG/gbaui-harness" 2>&1)
if grep -q "^PASS" <<<"$out"; then res="PASS"; detail="$(grep -c '  ok ' <<<"$out") checks"; else res="FAIL*"; fail=1; detail=$(grep -m1 "FAIL" <<<"$out"); fi
printf "%-34s %-9s %s\n" "UI engine (speed, autosave, record)" "$res" "$detail"
# Native-BIOS maths against mathematically defined answers (no ROM involved)
out=$("$HARNESS" --bios-selftest 2>&1)
if grep -q "^PASS" <<<"$out"; then res="PASS"; detail="$(grep -c '  ok ' <<<"$out") checks"; else res="FAIL*"; fail=1; detail=$(grep FAIL <<<"$out" | head -1); fi
printf "%-34s %-9s %s\n" "Native BIOS maths self-check" "$res" "$detail"
for st in "ppu|PPU scene self-check" "hw|Timers, DMA, LCD, keypad check" "apu|Sound hardware check" "services|BIOS services, EEPROM, RTC check" "state|Save states and rewind check" "rewind-leak|Rewind memory stays flat" "control|Controls and cheats check" "cheat|All cheat-device formats check" "gb|Game Boy hardware check" "link|Link cable check"; do
  flag=${st%%|*}; label=${st#*|}
  if [[ $flag == *-leak ]]; then opt="--$flag"; else opt="--$flag-selftest"; fi
  out=$("$HARNESS" $opt 2>&1)
  if grep -q "^PASS" <<<"$out"; then res="PASS"; detail="$(grep -c '  ok ' <<<"$out") checks"; else res="FAIL*"; fail=1; detail=$(grep -m1 "FAIL" <<<"$out"); fi
  printf "%-34s %-9s %s\n" "$label" "$res" "$detail"
done
[[ $fail -eq 0 ]] && echo "OK: every test that should pass does" || echo "REGRESSION: a test that should pass failed (marked FAIL*)"
exit $fail
