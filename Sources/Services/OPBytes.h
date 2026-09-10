#ifndef OPBytes_h
#define OPBytes_h

#import <Foundation/Foundation.h>

// Little-endian read/write helpers shared by the SMB2 and NTLM code.

static inline uint16_t OPReadLE16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static inline uint32_t OPReadLE32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

static inline uint64_t OPReadLE64(const uint8_t *p) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) {
        value |= ((uint64_t)p[i]) << (8 * i);
    }
    return value;
}

static inline uint16_t OPReadBE16(const uint8_t *p) {
    return (uint16_t)((p[0] << 8) | p[1]);
}

static inline uint32_t OPReadBE24(const uint8_t *p) {
    return (uint32_t)((p[0] << 16) | (p[1] << 8) | p[2]);
}

static inline void OPWriteLE16(uint8_t *p, uint16_t value) {
    p[0] = (uint8_t)(value & 0xFF);
    p[1] = (uint8_t)((value >> 8) & 0xFF);
}

static inline void OPWriteLE32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value & 0xFF);
    p[1] = (uint8_t)((value >> 8) & 0xFF);
    p[2] = (uint8_t)((value >> 16) & 0xFF);
    p[3] = (uint8_t)((value >> 24) & 0xFF);
}

static inline void OPWriteLE64(uint8_t *p, uint64_t value) {
    for (int i = 0; i < 8; i++) {
        p[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
    }
}

static inline void OPAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2];
    OPWriteLE16(bytes, value);
    [data appendBytes:bytes length:2];
}

static inline void OPAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4];
    OPWriteLE32(bytes, value);
    [data appendBytes:bytes length:4];
}

static inline void OPAppendLE64(NSMutableData *data, uint64_t value) {
    uint8_t bytes[8];
    OPWriteLE64(bytes, value);
    [data appendBytes:bytes length:8];
}

#endif
