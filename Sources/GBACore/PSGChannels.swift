// The four Game Boy sound channels, shared by the GBA's APU and the Game Boy's. Each `advance` takes a time step in
// 16.78 MHz (GBA) cycles; the Game Boy's 4.19 MHz clock simply feeds four times its own cycle count.

/// What the Game Boy's NRx4 write logic needs from a channel.
protocol PSGLengthChannel: AnyObject {
    var enabled: Bool { get set }
    var lengthEnabled: Bool { get set }
    var length: Int { get set }
    func trigger()
}

final class PSGEnvelope {
    var volume = 0, initial = 0, increase = false, period = 0, timer = 0
    func load(_ reg: Int) { initial = (reg >> 12) & 15; increase = reg & 0x800 != 0; period = (reg >> 8) & 7 }
    func trigger() { volume = initial; timer = period == 0 ? 8 : period }
    func clock() {
        guard period != 0 else { return }
        timer -= 1
        if timer <= 0 {
            timer = period
            if increase { if volume < 15 { volume += 1 } } else if volume > 0 { volume -= 1 }
        }
    }
    var dacOn: Bool { initial != 0 || increase }
}

final class PSGSquare: PSGLengthChannel {
    var enabled = false, lengthEnabled = false
    var length = 0, duty = 0, step = 0, timer = 0, frequency = 0
    let env = PSGEnvelope()
    // sweep (channel 1 only)
    var hasSweep = false, sweepEnabled = false, sweepNegate = false
    /// Set when a sweep calculation has been done in negate mode (leaving negate mode afterwards silences the channel).
    var sweepNegateUsed = false
    var sweepShift = 0, sweepPeriod = 0, sweepTimer = 0, shadow = 0
    static let patterns: [[Int]] = [[0, 0, 0, 0, 0, 0, 0, 1], [1, 0, 0, 0, 0, 0, 0, 1], [1, 0, 0, 0, 0, 1, 1, 1], [0, 1, 1, 1, 1, 1, 1, 0]]

    func advance(_ dt: Int) {
        timer -= dt
        if timer <= 0 {
            let period = (2048 - frequency) * 16
            let n = (-timer) / max(period, 1) + 1
            timer += n * period
            step = (step + n) & 7
        }
    }
    var output: Int { enabled ? PSGSquare.patterns[duty][step] * env.volume : 0 }

    func trigger() {
        enabled = env.dacOn
        if length == 0 { length = 64 }
        timer = (2048 - frequency) * 16
        env.trigger()
        if hasSweep {
            shadow = frequency
            sweepNegateUsed = false
            sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod
            sweepEnabled = sweepPeriod != 0 || sweepShift != 0
            if sweepShift != 0 { _ = sweepTarget() }
        }
    }
    func clockLength() { if lengthEnabled && length > 0 { length -= 1; if length == 0 { enabled = false } } }
    func sweepTarget() -> Int {
        let delta = shadow >> sweepShift
        let target = sweepNegate ? shadow - delta : shadow + delta
        if sweepNegate { sweepNegateUsed = true }
        if target > 2047 { enabled = false }
        return target
    }
    func clockSweep() {
        guard hasSweep, sweepTimer > 0 else { return }
        sweepTimer -= 1
        if sweepTimer == 0 {
            sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod
            if sweepEnabled && sweepPeriod != 0 {
                let target = sweepTarget()
                if target <= 2047 && sweepShift != 0 { shadow = target; frequency = target; _ = sweepTarget() }
            }
        }
    }
}

final class PSGWave: PSGLengthChannel {
    var enabled = false, dacOn = false, lengthEnabled = false
    var length = 0, timer = 0, frequency = 0, position = 0, volumeCode = 0
    var force75 = false, twoBanks = false, playBank = 0
    var ram = [UInt8](repeating: 0, count: 32)            // two banks of 16 bytes

    func advance(_ dt: Int) {
        timer -= dt
        if timer <= 0 {
            let period = (2048 - frequency) * 8
            let n = (-timer) / max(period, 1) + 1
            timer += n * period
            position = (position + n) % (twoBanks ? 64 : 32)
        }
    }
    var output: Int {
        guard enabled && dacOn else { return 0 }
        let bank = twoBanks ? position >> 5 : playBank
        let index = position & 31
        let byte = ram[bank * 16 + index >> 1]
        let nibble = Int(index & 1 == 0 ? byte >> 4 : byte & 15)
        if force75 { return nibble * 3 >> 2 }
        switch volumeCode { case 1: return nibble; case 2: return nibble >> 1; case 3: return nibble >> 2; default: return 0 }
    }
    func trigger() {
        enabled = dacOn
        if length == 0 { length = 256 }
        timer = (2048 - frequency) * 8
        position = 0
    }
    func clockLength() { if lengthEnabled && length > 0 { length -= 1; if length == 0 { enabled = false } } }
}

final class PSGNoise: PSGLengthChannel {
    var enabled = false, lengthEnabled = false, narrow = false
    var length = 0, timer = 0, divisor = 0, shift = 0
    var lfsr = 0x7FFF
    let env = PSGEnvelope()
    var period: Int { ((divisor == 0 ? 8 : divisor * 16) << min(shift, 14)) << 2 }
    func advance(_ dt: Int) {
        timer -= dt
        while timer <= 0 {
            timer += period
            let x = (lfsr & 1) ^ ((lfsr >> 1) & 1)
            lfsr = (lfsr >> 1) | (x << 14)
            if narrow { lfsr = (lfsr & ~0x40) | (x << 6) }
        }
    }
    var output: Int { enabled && lfsr & 1 == 0 ? env.volume : 0 }
    func trigger() {
        enabled = env.dacOn
        if length == 0 { length = 64 }
        timer = period
        lfsr = 0x7FFF
        env.trigger()
    }
    func clockLength() { if lengthEnabled && length > 0 { length -= 1; if length == 0 { enabled = false } } }
}

