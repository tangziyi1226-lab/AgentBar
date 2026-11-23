import Foundation

/// Self-contained RFC 8878 Zstandard multi-frame decompressor used to decode
/// concatenated Zstd event frames in DeepSeek Harness `session.v4.jsonl.zstd` logs
/// in-process with zero external tools or dylib dependencies.
public enum ZstdDecoder {
    private static let frameMagic: UInt32 = 0xFD2FB528
    private static let skippableMagicMask: UInt32 = 0xFFFFFFF0
    private static let skippableMagicBase: UInt32 = 0x184D2A50

    private static let llExtra: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16
    ]
    private static let llBase: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536
    ]

    private static let mlExtra: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16
    ]
    private static let mlBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539
    ]

    private static let predefinedLLNorm: [Int16] = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1
    ]
    private static let predefinedMLNorm: [Int16] = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1
    ]
    private static let predefinedOFNorm: [Int16] = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
    ]

    private struct FSEEntry {
        var symbol: UInt8
        var numBits: UInt8
        var baseline: Int
    }

    private struct FSETable {
        var tableLog: Int
        var entries: [FSEEntry]
    }

    private struct HuffEntry {
        var symbol: UInt8
        var numBits: UInt8
    }

    private struct HuffTable {
        var maxBits: Int
        var entries: [HuffEntry]
    }

    private static let predefinedLLTable = buildFSETable(norm: predefinedLLNorm, tableLog: 6)!
    private static let predefinedMLTable = buildFSETable(norm: predefinedMLNorm, tableLog: 6)!
    private static let predefinedOFTable = buildFSETable(norm: predefinedOFNorm, tableLog: 5)!

    private struct BackwardBitReader {
        let base: UnsafePointer<UInt8>
        var bitsLeft: Int

        init?(base: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return nil }
            let lastByte = base[count - 1]
            guard lastByte != 0 else { return nil }
            let highestBit = 7 - lastByte.leadingZeroBitCount
            self.base = base
            self.bitsLeft = (count - 1) * 8 + highestBit
        }

        mutating func readBits(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            let newBitsLeft = bitsLeft - n
            bitsLeft = newBitsLeft
            if newBitsLeft >= 0 {
                return extractBits(at: newBitsLeft, count: n)
            } else {
                let avail = n + newBitsLeft
                guard avail > 0 else { return 0 }
                return extractBits(at: 0, count: avail) << (-newBitsLeft)
            }
        }

        func peekBits(_ n: Int) -> Int {
            guard n > 0, bitsLeft > 0 else { return 0 }
            if bitsLeft >= n {
                return extractBits(at: bitsLeft - n, count: n)
            } else {
                return extractBits(at: 0, count: bitsLeft) << (n - bitsLeft)
            }
        }

        mutating func skipBits(_ n: Int) {
            bitsLeft -= n
        }

        private func extractBits(at bitOffset: Int, count: Int) -> Int {
            let byteIdx = bitOffset >> 3
            let bitShift = bitOffset & 7
            var raw: UInt64 = 0
            let neededBytes = (bitShift + count + 7) >> 3
            for i in 0..<neededBytes {
                raw |= UInt64(base[byteIdx + i]) << (i * 8)
            }
            let mask: UInt64 = count >= 64 ? UInt64.max : ((UInt64(1) << count) - 1)
            return Int((raw >> bitShift) & mask)
        }
    }

    /// Encodes `payload` into a valid RFC 8878 single-segment Zstandard `Raw_Block` frame (for unit tests).
    public static func encodeUncompressedFrame(_ payload: Data) -> Data {
        precondition(payload.count <= 0x1FFFF, "Raw_Block max size is 128 KiB")
        var out = Data()
        out.reserveCapacity(payload.count + 16)
        // Magic: 0xFD2FB528 LE
        out.append(contentsOf: [0x28, 0xB5, 0x2F, 0xFD])
        // FHD: FCS_Field_Size=2 (4 bytes, 0x80) | Single_Segment=1 (0x20) => 0xA0
        out.append(0xA0)
        let fcs = UInt32(payload.count)
        out.append(UInt8(fcs & 0xFF))
        out.append(UInt8((fcs >> 8) & 0xFF))
        out.append(UInt8((fcs >> 16) & 0xFF))
        out.append(UInt8((fcs >> 24) & 0xFF))
        // Block_Header: Last_Block=1, Block_Type=0 (Raw_Block), Block_Size=payload.count
        let bh = UInt32((payload.count << 3) | 1)
        out.append(UInt8(bh & 0xFF))
        out.append(UInt8((bh >> 8) & 0xFF))
        out.append(UInt8((bh >> 16) & 0xFF))
        out.append(payload)
        return out
    }

    /// Scans `data` for Zstandard frames (`0x28 0xB5 0x2F 0xFD`, e.g. even when `data` is a tail slice
    /// starting mid-file) and decodes all complete frames in order up to `maxDecompressedBytes`.
    public static func decodeConcatenatedFrames(_ data: Data, maxDecompressedBytes: Int = 2 * 1024 * 1024) -> Data {
        guard data.count >= 8 else { return Data() }
        var combined = Data()
        combined.reserveCapacity(min(maxDecompressedBytes, max(4096, data.count * 3)))

        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            let totalLen = rawBuf.count
            var offset = 0

            while offset + 4 <= totalLen && combined.count < maxDecompressedBytes {
                let magic = readU32LE(ptr, offset)
                if (magic & skippableMagicMask) == skippableMagicBase {
                    guard offset + 8 <= totalLen else { break }
                    let skipSize = Int(readU32LE(ptr, offset + 4))
                    guard skipSize >= 0, offset + 8 + skipSize <= totalLen else { break }
                    offset += 8 + skipSize
                    continue
                }
                if magic != frameMagic {
                    // Advance to next potential magic byte (allows tail-sliced files starting mid-frame)
                    if let nextIdx = findNextFrameMagic(ptr: ptr, start: offset + 1, end: totalLen) {
                        offset = nextIdx
                        continue
                    }
                    break
                }

                if let (frameOut, consumed) = decodeSingleFrame(
                    ptr: ptr + offset,
                    avail: totalLen - offset,
                    maxFrameBytes: maxDecompressedBytes - combined.count
                ), consumed > 0 {
                    combined.append(frameOut)
                    offset += consumed
                } else {
                    if let nextIdx = findNextFrameMagic(ptr: ptr, start: offset + 4, end: totalLen) {
                        offset = nextIdx
                    } else {
                        break
                    }
                }
            }
        }
        return combined
    }

    private static func findNextFrameMagic(ptr: UnsafePointer<UInt8>, start: Int, end: Int) -> Int? {
        guard start + 4 <= end else { return nil }
        var i = start
        let limit = end - 4
        while i <= limit {
            if ptr[i] == 0x28 && ptr[i + 1] == 0xB5 && ptr[i + 2] == 0x2F && ptr[i + 3] == 0xFD {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func readU32LE(_ p: UnsafePointer<UInt8>, _ off: Int) -> UInt32 {
        UInt32(p[off])
            | (UInt32(p[off + 1]) << 8)
            | (UInt32(p[off + 2]) << 16)
            | (UInt32(p[off + 3]) << 24)
    }

    private static func decodeSingleFrame(
        ptr: UnsafePointer<UInt8>,
        avail: Int,
        maxFrameBytes: Int
    ) -> (Data, Int)? {
        guard avail >= 6, readU32LE(ptr, 0) == frameMagic else { return nil }
        var pos = 4
        let fhd = ptr[pos]
        pos += 1

        if (fhd & 0x08) != 0 { return nil } // Reserved bit must be zero
        let fcsFlag = Int((fhd >> 6) & 3)
        let singleSegment = ((fhd >> 5) & 1) != 0
        let contentChecksum = ((fhd >> 2) & 1) != 0
        let dictIDFlag = Int(fhd & 3)

        if !singleSegment {
            guard pos < avail else { return nil }
            pos += 1 // Window_Descriptor
        }

        let dictFieldSizes = [0, 1, 2, 4]
        let dictBytes = dictFieldSizes[dictIDFlag]
        guard pos + dictBytes <= avail else { return nil }
        for i in 0..<dictBytes where ptr[pos + i] != 0 {
            // External dictionary frames are unsupported
            return nil
        }
        pos += dictBytes

        let fcsBytes: Int
        switch fcsFlag {
        case 0: fcsBytes = singleSegment ? 1 : 0
        case 1: fcsBytes = 2
        case 2: fcsBytes = 4
        default: fcsBytes = 8
        }
        guard pos + fcsBytes <= avail else { return nil }
        pos += fcsBytes

        var frameOut = Data()
        frameOut.reserveCapacity(4096)
        var rep: (Int, Int, Int) = (1, 4, 8)
        var prevHuff: HuffTable?
        var prevLL: FSETable?
        var prevOF: FSETable?
        var prevML: FSETable?

        while true {
            guard pos + 3 <= avail else { return nil }
            let bh = Int(ptr[pos]) | (Int(ptr[pos + 1]) << 8) | (Int(ptr[pos + 2]) << 16)
            pos += 3
            let lastBlock = (bh & 1) != 0
            let blockType = (bh >> 1) & 3
            let blockSize = bh >> 3

            switch blockType {
            case 0: // Raw_Block
                guard pos + blockSize <= avail, frameOut.count + blockSize <= maxFrameBytes else { return nil }
                frameOut.append(ptr + pos, count: blockSize)
                pos += blockSize
            case 1: // RLE_Block
                guard pos + 1 <= avail, frameOut.count + blockSize <= maxFrameBytes else { return nil }
                let byte = ptr[pos]
                pos += 1
                frameOut.append(contentsOf: repeatElement(byte, count: blockSize))
            case 2: // Compressed_Block
                guard pos + blockSize <= avail else { return nil }
                guard decodeCompressedBlock(
                    ptr: ptr + pos,
                    blockSize: blockSize,
                    frameOut: &frameOut,
                    maxFrameBytes: maxFrameBytes,
                    rep: &rep,
                    prevHuff: &prevHuff,
                    prevLL: &prevLL,
                    prevOF: &prevOF,
                    prevML: &prevML
                ) else {
                    return nil
                }
                pos += blockSize
            default:
                return nil
            }

            if lastBlock {
                if contentChecksum {
                    guard pos + 4 <= avail else { return nil }
                    pos += 4
                }
                return (frameOut, pos)
            }
        }
    }

    private static func decodeCompressedBlock(
        ptr: UnsafePointer<UInt8>,
        blockSize: Int,
        frameOut: inout Data,
        maxFrameBytes: Int,
        rep: inout (Int, Int, Int),
        prevHuff: inout HuffTable?,
        prevLL: inout FSETable?,
        prevOF: inout FSETable?,
        prevML: inout FSETable?
    ) -> Bool {
        guard blockSize >= 2 else { return false }
        var pos = 0

        // 1. Decode Literals_Section
        let lb0 = Int(ptr[0])
        let litType = lb0 & 3
        let sizeFmt = (lb0 >> 2) & 3
        var literals = [UInt8]()

        if litType == 0 || litType == 1 {
            let regenSize: Int
            if (sizeFmt & 1) == 0 {
                regenSize = lb0 >> 3
                pos += 1
            } else if sizeFmt == 1 {
                guard blockSize >= 2 else { return false }
                regenSize = (lb0 >> 4) | (Int(ptr[1]) << 4)
                pos += 2
            } else {
                guard blockSize >= 3 else { return false }
                regenSize = (lb0 >> 4) | (Int(ptr[1]) << 4) | (Int(ptr[2]) << 12)
                pos += 3
            }
            guard regenSize <= maxFrameBytes else { return false }
            if litType == 0 {
                guard pos + regenSize <= blockSize else { return false }
                literals = Array(UnsafeBufferPointer(start: ptr + pos, count: regenSize))
                pos += regenSize
            } else {
                guard pos + 1 <= blockSize else { return false }
                literals = [UInt8](repeating: ptr[pos], count: regenSize)
                pos += 1
            }
        } else {
            let numStreams = (sizeFmt == 0) ? 1 : 4
            let regenSize: Int
            let compSize: Int
            switch sizeFmt {
            case 0, 1:
                guard blockSize >= 3 else { return false }
                let h = lb0 | (Int(ptr[1]) << 8) | (Int(ptr[2]) << 16)
                regenSize = (h >> 4) & 0x3FF
                compSize = (h >> 14) & 0x3FF
                pos += 3
            case 2:
                guard blockSize >= 4 else { return false }
                let h = lb0 | (Int(ptr[1]) << 8) | (Int(ptr[2]) << 16) | (Int(ptr[3]) << 24)
                regenSize = (h >> 4) & 0x3FFF
                compSize = (h >> 18) & 0x3FFF
                pos += 4
            default:
                guard blockSize >= 5 else { return false }
                regenSize = (lb0 >> 4) | (Int(ptr[1]) << 4) | ((Int(ptr[2]) & 0x3F) << 12)
                compSize = (Int(ptr[2]) >> 6) | (Int(ptr[3]) << 2) | (Int(ptr[4]) << 10)
                pos += 5
            }
            guard pos + compSize <= blockSize, regenSize <= maxFrameBytes else { return false }
            var streamPtr = ptr + pos
            var streamLen = compSize
            pos += compSize

            if litType == 2 {
                guard let (builtHuff, usedBytes) = parseHuffmanTable(ptr: streamPtr, avail: streamLen) else {
                    return false
                }
                prevHuff = builtHuff
                streamPtr += usedBytes
                streamLen -= usedBytes
            }
            guard let huff = prevHuff else { return false }
            literals.reserveCapacity(regenSize)

            if numStreams == 1 {
                guard decodeHuffStream(ptr: streamPtr, len: streamLen, expectedOut: regenSize, huff: huff, out: &literals) else {
                    return false
                }
            } else {
                guard streamLen >= 6 else { return false }
                let s1 = Int(streamPtr[0]) | (Int(streamPtr[1]) << 8)
                let s2 = Int(streamPtr[2]) | (Int(streamPtr[3]) << 8)
                let s3 = Int(streamPtr[4]) | (Int(streamPtr[5]) << 8)
                let s4 = streamLen - 6 - s1 - s2 - s3
                guard s1 > 0, s2 > 0, s3 > 0, s4 > 0 else { return false }
                let chunk = (regenSize + 3) / 4
                let lens = [s1, s2, s3, s4]
                let targets = [chunk, chunk, chunk, regenSize - 3 * chunk]
                var sp = streamPtr + 6
                for idx in 0..<4 {
                    guard targets[idx] >= 0,
                          decodeHuffStream(ptr: sp, len: lens[idx], expectedOut: targets[idx], huff: huff, out: &literals) else {
                        return false
                    }
                    sp += lens[idx]
                }
            }
        }

        // 2. Decode Sequences_Section_Header
        guard pos < blockSize else { return false }
        let sb0 = Int(ptr[pos])
        pos += 1
        let numSeq: Int
        if sb0 == 0 {
            guard pos == blockSize, frameOut.count + literals.count <= maxFrameBytes else { return false }
            frameOut.append(contentsOf: literals)
            return true
        } else if sb0 < 128 {
            numSeq = sb0
        } else if sb0 < 255 {
            guard pos < blockSize else { return false }
            numSeq = ((sb0 - 128) << 8) + Int(ptr[pos])
            pos += 1
        } else {
            guard pos + 2 <= blockSize else { return false }
            numSeq = Int(ptr[pos]) + (Int(ptr[pos + 1]) << 8) + 0x7F00
            pos += 2
        }

        guard pos < blockSize else { return false }
        let modes = Int(ptr[pos])
        pos += 1
        guard (modes & 3) == 0 else { return false }
        let llMode = (modes >> 6) & 3
        let ofMode = (modes >> 4) & 3
        let mlMode = (modes >> 2) & 3

        guard let llTable = resolveSeqTable(
            mode: llMode,
            ptr: ptr,
            pos: &pos,
            end: blockSize,
            maxSymbol: 35,
            maxLog: 9,
            predefined: predefinedLLTable,
            previous: &prevLL
        ) else { return false }

        guard let ofTable = resolveSeqTable(
            mode: ofMode,
            ptr: ptr,
            pos: &pos,
            end: blockSize,
            maxSymbol: 31,
            maxLog: 8,
            predefined: predefinedOFTable,
            previous: &prevOF
        ) else { return false }

        guard let mlTable = resolveSeqTable(
            mode: mlMode,
            ptr: ptr,
            pos: &pos,
            end: blockSize,
            maxSymbol: 52,
            maxLog: 9,
            predefined: predefinedMLTable,
            previous: &prevML
        ) else { return false }

        let seqStreamLen = blockSize - pos
        guard var reader = BackwardBitReader(base: ptr + pos, count: seqStreamLen) else { return false }

        var llState = reader.readBits(llTable.tableLog)
        var ofState = reader.readBits(ofTable.tableLog)
        var mlState = reader.readBits(mlTable.tableLog)
        guard reader.bitsLeft >= 0 else { return false }

        var litCursor = 0
        for seqIdx in 0..<numSeq {
            let llEntry = llTable.entries[llState]
            let ofEntry = ofTable.entries[ofState]
            let mlEntry = mlTable.entries[mlState]

            let ofCode = Int(ofEntry.symbol)
            let mlCode = Int(mlEntry.symbol)
            let llCode = Int(llEntry.symbol)
            guard llCode < llBase.count, mlCode < mlBase.count, ofCode <= 31 else { return false }

            let ofVal = (1 << ofCode) + reader.readBits(ofCode)
            let mlVal = mlBase[mlCode] + reader.readBits(Int(mlExtra[mlCode]))
            let llVal = llBase[llCode] + reader.readBits(Int(llExtra[llCode]))

            if seqIdx + 1 < numSeq {
                llState = llEntry.baseline + reader.readBits(Int(llEntry.numBits))
                mlState = mlEntry.baseline + reader.readBits(Int(mlEntry.numBits))
                ofState = ofEntry.baseline + reader.readBits(Int(ofEntry.numBits))
            }
            guard reader.bitsLeft >= 0 else { return false }

            let realOffset: Int
            if ofVal > 3 {
                realOffset = ofVal - 3
                rep = (realOffset, rep.0, rep.1)
            } else {
                let adj = (llVal == 0) ? (ofVal + 1) : ofVal
                switch adj {
                case 1:
                    realOffset = rep.0
                case 2:
                    realOffset = rep.1
                    rep = (realOffset, rep.0, rep.2)
                case 3:
                    realOffset = rep.2
                    rep = (realOffset, rep.0, rep.1)
                default: // adj == 4 (ofVal == 3 && llVal == 0)
                    realOffset = rep.0 - 1
                    rep = (realOffset, rep.0, rep.1)
                }
            }

            guard litCursor + llVal <= literals.count,
                  frameOut.count + llVal + mlVal <= maxFrameBytes else {
                return false
            }
            if llVal > 0 {
                frameOut.append(contentsOf: literals[litCursor ..< (litCursor + llVal)])
                litCursor += llVal
            }

            guard realOffset > 0, realOffset <= frameOut.count else { return false }
            let matchStart = frameOut.count - realOffset
            if realOffset >= mlVal {
                let slice = Array(frameOut[matchStart ..< (matchStart + mlVal)])
                frameOut.append(contentsOf: slice)
            } else {
                for i in 0..<mlVal {
                    let b = frameOut[matchStart + i]
                    frameOut.append(b)
                }
            }
        }

        let remLits = literals.count - litCursor
        if remLits > 0 {
            guard frameOut.count + remLits <= maxFrameBytes else { return false }
            frameOut.append(contentsOf: literals[litCursor ..< literals.count])
        }
        return reader.bitsLeft == 0
    }

    private static func resolveSeqTable(
        mode: Int,
        ptr: UnsafePointer<UInt8>,
        pos: inout Int,
        end: Int,
        maxSymbol: Int,
        maxLog: Int,
        predefined: FSETable,
        previous: inout FSETable?
    ) -> FSETable? {
        switch mode {
        case 0:
            previous = predefined
            return predefined
        case 1:
            guard pos < end else { return nil }
            let sym = ptr[pos]
            pos += 1
            guard Int(sym) <= maxSymbol else { return nil }
            let rle = FSETable(tableLog: 0, entries: [FSEEntry(symbol: sym, numBits: 0, baseline: 0)])
            previous = rle
            return rle
        case 2:
            guard let (parsed, consumed) = readFSETable(ptr: ptr + pos, avail: end - pos, maxSymbol: maxSymbol, maxTableLog: maxLog) else {
                return nil
            }
            pos += consumed
            previous = parsed
            return parsed
        case 3:
            return previous
        default:
            return nil
        }
    }

    private static func parseHuffmanTable(ptr: UnsafePointer<UInt8>, avail: Int) -> (HuffTable, Int)? {
        guard avail >= 1 else { return nil }
        let hdr = Int(ptr[0])
        var weights = [Int]()
        let consumed: Int

        if hdr >= 128 {
            let numWeights = hdr - 127
            let bytesNeeded = 1 + (numWeights + 1) / 2
            guard bytesNeeded <= avail else { return nil }
            weights.reserveCapacity(numWeights + 1)
            for i in 0..<numWeights {
                let b = Int(ptr[1 + (i >> 1)])
                let w = ((i & 1) == 0) ? ((b >> 4) & 0x0F) : (b & 0x0F)
                weights.append(w)
            }
            consumed = bytesNeeded
        } else {
            guard hdr > 0, 1 + hdr <= avail else { return nil }
            guard let (fse, fseBytes) = readFSETable(ptr: ptr + 1, avail: hdr, maxSymbol: 12, maxTableLog: 6) else {
                return nil
            }
            let streamLen = hdr - fseBytes
            guard var reader = BackwardBitReader(base: ptr + 1 + fseBytes, count: streamLen) else {
                return nil
            }
            var state1 = reader.readBits(fse.tableLog)
            var state2 = reader.readBits(fse.tableLog)
            guard reader.bitsLeft >= 0 else { return nil }

            weights.reserveCapacity(256)
            while weights.count < 255 {
                let e1 = fse.entries[state1]
                weights.append(Int(e1.symbol))
                if reader.bitsLeft < Int(e1.numBits) {
                    weights.append(Int(fse.entries[state2].symbol))
                    break
                }
                state1 = e1.baseline + reader.readBits(Int(e1.numBits))
                if weights.count >= 255 { break }

                let e2 = fse.entries[state2]
                weights.append(Int(e2.symbol))
                if reader.bitsLeft < Int(e2.numBits) {
                    weights.append(Int(fse.entries[state1].symbol))
                    break
                }
                state2 = e2.baseline + reader.readBits(Int(e2.numBits))
            }
            consumed = 1 + hdr
        }

        var weightSum = 0
        for w in weights where w > 0 {
            if w > 11 { return nil }
            weightSum += (1 << (w - 1))
        }
        guard weightSum > 0 else { return nil }
        let maxBits = Int.bitWidth - weightSum.leadingZeroBitCount
        guard maxBits >= 1, maxBits <= 11 else { return nil }
        let totalWeightCap = 1 << maxBits
        let rem = totalWeightCap - weightSum
        guard rem > 0, (rem & (rem - 1)) == 0 else { return nil }
        let lastWeight = rem.trailingZeroBitCount + 1
        weights.append(lastWeight)
        guard weights.count <= 256 else { return nil }

        var rankCount = [Int](repeating: 0, count: maxBits + 1)
        for w in weights where w > 0 {
            rankCount[w] += 1
        }
        var rankStart = [Int](repeating: 0, count: maxBits + 2)
        var nextCode = 0
        for w in 1...maxBits {
            rankStart[w] = nextCode
            nextCode += rankCount[w] * (1 << (w - 1))
        }
        guard nextCode == totalWeightCap else { return nil }

        var entries = [HuffEntry](repeating: HuffEntry(symbol: 0, numBits: 0), count: totalWeightCap)
        for (sym, w) in weights.enumerated() where w > 0 {
            let nBits = UInt8(maxBits + 1 - w)
            let span = 1 << (w - 1)
            let start = rankStart[w]
            for idx in start ..< (start + span) {
                entries[idx] = HuffEntry(symbol: UInt8(sym), numBits: nBits)
            }
            rankStart[w] += span
        }
        return (HuffTable(maxBits: maxBits, entries: entries), consumed)
    }

    private static func decodeHuffStream(
        ptr: UnsafePointer<UInt8>,
        len: Int,
        expectedOut: Int,
        huff: HuffTable,
        out: inout [UInt8]
    ) -> Bool {
        if expectedOut == 0 { return len == 0 }
        guard var reader = BackwardBitReader(base: ptr, count: len) else { return false }
        let startCount = out.count
        while reader.bitsLeft > 0 && (out.count - startCount) < expectedOut {
            let idx = reader.peekBits(huff.maxBits)
            let entry = huff.entries[idx]
            guard entry.numBits > 0 else { return false }
            out.append(entry.symbol)
            reader.skipBits(Int(entry.numBits))
        }
        return (out.count - startCount) == expectedOut && reader.bitsLeft == 0
    }

    private static func readFSETable(
        ptr: UnsafePointer<UInt8>,
        avail: Int,
        maxSymbol: Int,
        maxTableLog: Int
    ) -> (FSETable, Int)? {
        guard avail >= 1 else { return nil }
        var bitPos = 0
        let totalBits = avail * 8

        func peekForwardBits(_ count: Int) -> Int {
            guard count > 0, bitPos < totalBits else { return 0 }
            let byteIdx = bitPos >> 3
            let shift = bitPos & 7
            var raw: UInt64 = 0
            let maxBytes = min(8, avail - byteIdx)
            for i in 0..<maxBytes {
                raw |= UInt64(ptr[byteIdx + i]) << (i * 8)
            }
            let mask: UInt64 = (UInt64(1) << count) - 1
            return Int((raw >> shift) & mask)
        }

        let accuracyLog = (peekForwardBits(4) & 0x0F) + 5
        bitPos += 4
        guard accuracyLog <= maxTableLog else { return nil }

        var remaining = (1 << accuracyLog) + 1
        var threshold = 1 << accuracyLog
        var nbBits = accuracyLog + 1
        var norm = [Int16]()
        norm.reserveCapacity(maxSymbol + 1)
        var prevZero = false

        while remaining > 1 && norm.count <= maxSymbol {
            if prevZero {
                while bitPos <= totalBits {
                    let twoBits = peekForwardBits(2)
                    bitPos += 2
                    if twoBits == 3 {
                        for _ in 0..<3 where norm.count <= maxSymbol {
                            norm.append(0)
                        }
                    } else {
                        for _ in 0..<twoBits where norm.count <= maxSymbol {
                            norm.append(0)
                        }
                        break
                    }
                }
                if norm.count > maxSymbol { break }
            }

            let maxVal = (2 * threshold - 1) - remaining
            let lowBits = peekForwardBits(nbBits - 1)
            let countVal: Int
            if lowBits < maxVal {
                countVal = lowBits
                bitPos += nbBits - 1
            } else {
                var full = peekForwardBits(nbBits)
                bitPos += nbBits
                if full >= threshold {
                    full -= maxVal
                }
                countVal = full
            }

            let prob = countVal - 1
            if prob == -1 {
                remaining -= 1
            } else {
                remaining -= prob
            }
            guard remaining >= 1 else { return nil }
            norm.append(Int16(prob))
            prevZero = (prob == 0)

            while remaining < threshold && nbBits > 1 {
                nbBits -= 1
                threshold >>= 1
            }
        }

        let bytesConsumed = (bitPos + 7) >> 3
        guard remaining == 1, bytesConsumed <= avail, norm.count <= maxSymbol + 1 else { return nil }
        guard let built = buildFSETable(norm: norm, tableLog: accuracyLog) else { return nil }
        return (built, bytesConsumed)
    }

    private static func buildFSETable(norm: [Int16], tableLog: Int) -> FSETable? {
        let tableSize = 1 << tableLog
        let tableMask = tableSize - 1
        let step = (tableSize >> 1) + (tableSize >> 3) + 3

        var symbols = [UInt8](repeating: 0, count: tableSize)
        var nextState = [Int](repeating: 0, count: norm.count)
        var highThreshold = tableSize - 1
        var pos = 0
        var sum = 0

        for (sym, rawProb) in norm.enumerated() where rawProb == -1 {
            guard highThreshold >= 0 else { return nil }
            symbols[highThreshold] = UInt8(sym)
            highThreshold -= 1
            nextState[sym] = 1
            sum += 1
        }

        for (sym, rawProb) in norm.enumerated() where rawProb > 0 {
            let p = Int(rawProb)
            nextState[sym] = p
            sum += p
            for _ in 0..<p {
                symbols[pos] = UInt8(sym)
                repeat {
                    pos = (pos + step) & tableMask
                } while pos > highThreshold
            }
        }
        guard sum == tableSize, pos == 0 else { return nil }

        var entries = [FSEEntry](repeating: FSEEntry(symbol: 0, numBits: 0, baseline: 0), count: tableSize)
        for idx in 0..<tableSize {
            let sym = Int(symbols[idx])
            let st = nextState[sym]
            nextState[sym] = st + 1
            let highBit = Int.bitWidth - 1 - st.leadingZeroBitCount
            let nBits = tableLog - highBit
            let base = (st << nBits) - tableSize
            entries[idx] = FSEEntry(symbol: UInt8(sym), numBits: UInt8(nBits), baseline: base)
        }
        return FSETable(tableLog: tableLog, entries: entries)
    }
}
