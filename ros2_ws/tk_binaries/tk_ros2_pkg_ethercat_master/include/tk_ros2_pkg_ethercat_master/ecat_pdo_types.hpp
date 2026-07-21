#pragma once
#include <ecrt.h>
#include <cstdint>
#include <vector>

namespace ecat {

// Descriptive structs for PDO mapping (declarative, converted to IgH C arrays)
struct PdoEntryDesc {
    uint16_t index;
    uint8_t subindex;
    uint8_t bit_length;
    unsigned int* offset_ptr;  // filled by IgH after registration
};

struct PdoDesc {
    uint16_t index;
    std::vector<PdoEntryDesc> entries;
};

struct SyncManagerDesc {
    uint8_t sm_index;
    ec_direction_t direction;
    ec_watchdog_mode_t watchdog;
    std::vector<PdoDesc> pdos;
};

} // namespace ecat
