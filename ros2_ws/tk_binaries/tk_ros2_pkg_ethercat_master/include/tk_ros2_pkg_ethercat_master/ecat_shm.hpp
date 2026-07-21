/**
 * ecat_shm.hpp
 *
 * Generic EtherCAT shared memory layout. Device-agnostic: no device types,
 * no device-specific structs. Device sizes are dynamic (from plugins).
 */

#pragma once
#include <cstdint>
#include <cstring>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>

namespace ecat {

constexpr uint32_t SHM_MAGIC   = 0xEC47A001;
constexpr uint32_t SHM_VERSION = 10;  // Bumped: ShmSdoRequest gained str_value for VISIBLE_STRING reads

#pragma pack(push, 1)

// --------------------------------------------------------------------------
// SHM layout structs — fully generic
// --------------------------------------------------------------------------

struct ShmDeviceDesc {
    uint8_t  reserved;          // was DeviceType (no longer used)
    uint8_t  device_index;
    uint16_t cmd_offset;        // offset within command buffer
    uint16_t cmd_size;
    uint16_t state_offset;      // offset within state region
    uint16_t state_size;
    float    publish_rate_hz;   // ROS2 status publish rate for this device
    char     name[16];
};

struct ShmCmdBufferHeader {
    uint32_t seq;
    uint32_t time_ns_lo;
    uint32_t time_ns_hi;
    // followed by device command data
};

struct ShmHealth {
    uint32_t seq;               // seqlock
    int32_t  wkc;
    uint32_t flags;             // bit0=all_op, bit1=wkc_ok, bit2=cmd_hold, bit3=cmd_kill
    uint32_t err_wkc;           // WKC drops while all devices OP
    uint32_t err_wkc_preop;     // WKC drops before all devices reached OP
    uint32_t err_state;
    uint32_t total_cycles_lo;
    uint32_t recovery_count;
};

struct ShmCmdLock {
    pthread_spinlock_t lock;
};

// Bridge ↔ daemon SDO request/response slot.
//
// One outstanding request at a time (bridge-side mutex enforces it). Seq
// counters form a handshake: bridge bumps req_seq after filling the
// request fields; daemon's SDO worker thread sees req_seq != resp_seq,
// dispatches on req_type (upload vs download), fills the response
// fields, and sets resp_seq = req_seq. Bridge polls until resp_seq
// catches up or a timeout fires. Memory barriers on both sides keep
// field writes ordered relative to the seq update.
//
// The slot carries both upload (read) and download (write) requests;
// ``req_type`` tells the worker which path to take. Both directions
// share the same mutex on the bridge side because the slot itself is
// singular and IgH's kernel mailbox serialises anyway — parallel
// read+write would not help.
//
// data_type encodes the CiA 301 data-type code (5=u8, 6=u16, 7=u32, 9=VISIBLE_STRING)
// so the daemon knows how to upload/download; numeric types store the result in
// `value`, VISIBLE_STRING stores the NUL-terminated text in `str_value`.
struct ShmSdoRequest {
    // --- request (bridge writes, daemon reads) ---
    uint32_t req_seq;
    uint8_t  dev_idx;        // index into g_devices[] (matches ShmDeviceDesc order)
    uint8_t  data_type;      // 5=u8, 6=u16, 7=u32, 9=VISIBLE_STRING (upload only)
    uint16_t index;
    uint8_t  subindex;
    uint8_t  req_type;       // 0 = upload (read), 1 = download (write)
    uint8_t  _req_pad[2];
    uint32_t req_value;      // value to download (ignored for uploads)

    // --- response (daemon writes, bridge reads) ---
    uint32_t resp_seq;
    uint8_t  success;
    uint8_t  _resp_pad[3];
    uint32_t value;          // uploaded value (zeroed for successful downloads / VISIBLE_STRING reads)
    char     message[96];    // short human-readable error string on failure
    char     str_value[64];  // NUL-terminated text for VISIBLE_STRING uploads; empty otherwise
};

struct ShmHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t cycle_ns;
    uint8_t  num_devices;
    uint8_t  active_cmd_buffer; // 0 or 1
    uint16_t cmd_buffer_size;   // size of one cmd buffer (header + all device cmds)
    uint16_t state_region_size;
    uint32_t cmd_timeout_ms;
    uint32_t total_shm_size;
    uint32_t device_desc_offset;
    uint32_t cmd_buffer_a_offset;
    uint32_t cmd_buffer_b_offset;
    uint32_t state_offset;
    uint32_t health_offset;
    uint32_t cmd_lock_offset;
    uint32_t sdo_request_offset;
};

#pragma pack(pop)

// Layout structs
static_assert(sizeof(ShmDeviceDesc)      == 30, "ShmDeviceDesc must be 30B");
static_assert(sizeof(ShmCmdBufferHeader) == 12, "ShmCmdBufferHeader must be 12B");
static_assert(sizeof(ShmHealth)          == 32, "ShmHealth must be 32B");
static_assert(sizeof(ShmSdoRequest)      == 188, "ShmSdoRequest must be 188B");
static_assert(sizeof(ShmHeader)          == 54, "ShmHeader must be 54B");

// --------------------------------------------------------------------------
// Helper functions
// --------------------------------------------------------------------------

// Seqlock helpers (same pattern as a6_ecat_rt)
inline void seqlock_write_begin(uint32_t& seq) { seq++; __sync_synchronize(); }
inline void seqlock_write_end(uint32_t& seq)   { __sync_synchronize(); seq++; }

// Command buffer spinlock helpers (process-shared, for multi-writer SHM access)
inline void shm_cmd_lock_init(ShmCmdLock* lk) {
    pthread_spin_init(&lk->lock, PTHREAD_PROCESS_SHARED);
}
inline void shm_cmd_lock(ShmCmdLock* lk)   { pthread_spin_lock(&lk->lock); }
inline void shm_cmd_unlock(ShmCmdLock* lk) { pthread_spin_unlock(&lk->lock); }

// SHM create (for RT daemon)
inline void* shm_create(const char* name, size_t size) {
    shm_unlink(name);
    mode_t old_umask = umask(0);
    int fd = shm_open(name, O_CREAT | O_RDWR, 0666);
    umask(old_umask);
    if (fd < 0) return nullptr;
    if (ftruncate(fd, (off_t)size) < 0) { close(fd); return nullptr; }
    void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return nullptr;
    memset(p, 0, size);
    return p;
}

// SHM open read-only (for ROS2 node)
inline void* shm_open_ro(const char* name, size_t& out_size) {
    int fd = shm_open(name, O_RDONLY, 0);
    if (fd < 0) return nullptr;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return nullptr; }
    out_size = (size_t)st.st_size;
    void* p = mmap(nullptr, out_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return (p == MAP_FAILED) ? nullptr : p;
}

// SHM open read-write (for command writer like speed node)
inline void* shm_open_rw(const char* name, size_t& out_size) {
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0) return nullptr;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return nullptr; }
    out_size = (size_t)st.st_size;
    void* p = mmap(nullptr, out_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return (p == MAP_FAILED) ? nullptr : p;
}

} // namespace ecat
