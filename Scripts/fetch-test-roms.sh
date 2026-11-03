#!/bin/bash
# Downloads the public test ROMs the test suite uses into TestROMs/ (which is not committed: they belong to their authors).
#   - jsmolka/gba-tests        CPU, memory, BIOS, PPU, DMA and save tests for the GBA
#   - retrio/gb-test-roms      Blargg's Game Boy CPU, timing, sound and OAM tests
#   - mattcurrie/dmg-acid2, cgb-acid2   picture tests for the Game Boy and Game Boy Color, with their reference images
set -e
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p TestROMs && cd TestROMs
[ -d jsmolka-gba-tests ] || git clone --depth 1 https://github.com/jsmolka/gba-tests.git jsmolka-gba-tests
mkdir -p gb-test-roms/acid2
[ -d gb-test-roms/src ] || git clone --depth 1 https://github.com/retrio/gb-test-roms.git gb-test-roms/src
cd gb-test-roms/acid2
curl -sSL -o dmg-acid2.gb https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb
curl -sSL -o cgb-acid2.gbc https://github.com/mattcurrie/cgb-acid2/releases/download/v1.1/cgb-acid2.gbc
curl -sSL -o dmg-acid2-reference.png https://raw.githubusercontent.com/mattcurrie/dmg-acid2/master/img/reference-dmg.png
curl -sSL -o cgb-acid2-reference.png https://raw.githubusercontent.com/mattcurrie/cgb-acid2/master/img/reference.png
echo "Test ROMs are in TestROMs/. Run Scripts/run-tests.sh"
