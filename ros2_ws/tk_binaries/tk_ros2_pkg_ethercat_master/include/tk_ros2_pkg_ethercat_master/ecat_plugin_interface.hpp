/**
 * ecat_plugin_interface.hpp
 *
 * Abstract interface for EtherCAT device plugins. Each device type (servo,
 * isokernel, etc.) implements this interface either as an external .so plugin
 * or as a built-in (like the passthrough plugin for dumb I/O devices).
 *
 * This header + ecat_pdo_types.hpp + ecrt.h is the entire "plugin SDK".
 * External plugins only need these headers to build against.
 */

#pragma once
#include "tk_ros2_pkg_ethercat_master/ecat_pdo_types.hpp"
#include <cstdint>
#include <string>
#include <vector>

// Forward declarations from ecrt.h — only applyCriticalSDOs needs the
// master pointer; pulling in ecrt.h here would force every plugin TU
// to compile against IgH headers even when it doesn't use the master.
typedef struct ec_master ec_master_t;

namespace ecat {

constexpr uint32_t ECAT_PLUGIN_API_VERSION = 3;

/**
 * Every device plugin implements this interface.
 *
 * Lifecycle:
 *   1. create_plugin() — factory constructs the plugin
 *   2. defineSyncManagers() — daemon reads PDO layout for IgH registration
 *   3. configureSDOs() — register queued config-SDOs (auto-replay on slave recovery)
 *   4. applyCriticalSDOs() — optional: synchronously verify critical SDOs landed
 *   5. [RT loop begins]
 *      a. readInputs()  — domain PDO data → plugin internal state
 *      b. cyclicTask()   — protocol logic (DS402, safety, etc.)
 *      c. readShmCmd()   — SHM command bytes → plugin internal state
 *      d. writeOutputs() — plugin internal state → domain PDO data
 *      e. writeShmState() — plugin internal state → SHM state bytes
 *   5. destroy_plugin() — cleanup
 */
class EcatDevicePlugin {
public:
    virtual ~EcatDevicePlugin() = default;

    // --- STARTUP (called once) ---

    // Set the bus cycle period (called before configureSDOs).
    // Plugins that configure DC sync should use this instead of hardcoding.
    virtual void setBusCycleNs(uint32_t /*cycle_ns*/) {}

    // Called before defineSyncManagers() with the IgH master pointer.
    // Passthrough plugin uses this to auto-discover PDOs from the slave's
    // SII when no pdo_map YAML was provided.
    virtual void discoverPdos(ec_master_t* /*master*/, uint8_t /*position*/) {}

    // Returns true if this plugin already has its PDO map resolved (e.g.
    // an explicit YAML, or an on-disk discovery cache). The daemon uses
    // this to skip its deep PREOP-readiness probe — there is no walk to
    // protect, so there is nothing to wait for.
    virtual bool hasCachedPdoMap(ec_master_t* /*master*/) { return false; }

    // Return the sync manager / PDO layout for IgH registration.
    // The plugin must allocate stable storage for offset_ptr values in
    // PdoEntryDesc — IgH fills them in after domain registration.
    virtual std::vector<SyncManagerDesc> defineSyncManagers() = 0;

    // Configure SDOs if needed (called before cyclic operation).
    // ecrt_slave_config_sdo*() calls register *queued* config-SDOs that IgH
    // applies during PREOP→SAFEOP. They never block and never report
    // success/failure — if they race the slave's CoE mailbox they fail
    // silently and the slave hangs in PREOP. Use this hook to register
    // them; use applyCriticalSDOs() to back them up with synchronous writes.
    virtual void configureSDOs(ec_slave_config_t* sc) = 0;

    // Optional: synchronously verify critical SDOs landed on the slave.
    // Default no-op. Plugins that absolutely depend on certain SDOs being
    // applied before SAFEOP (e.g. operation_mode, profile_velocity) should
    // override and use ecrt_master_sdo_download / ecrt_master_sdo_upload
    // with retry-on-EIO. Throws on hard failure to abort device bringup.
    // Called after configureSDOs() and before master activation.
    virtual void applyCriticalSDOs(ec_master_t* /*master*/, uint8_t /*position*/) {}

    // Returns true if this slave participates in Distributed Clocks (i.e.
    // the plugin calls ecrt_slave_config_dc() with a non-zero
    // AssignActivate value). The daemon polls this across all devices to
    // decide whether to call ecrt_master_sync_reference_clock_to() +
    // ecrt_master_sync_slave_clocks() in the cyclic loop.
    //
    // Why this matters: IgH auto-promotes slave 0 as the DC reference
    // clock during bus scan. If slave 0 is a device that does NOT
    // implement DC (e.g. Pilz PNOZmulti EF safety controller), the
    // per-cycle DC sync datagrams target a register the slave doesn't
    // respond to, the kernel marks them as TIMED OUT, and the FSM
    // thread eventually decides the slave is unresponsive. This kills
    // safety bringup even though the bus is fine.
    //
    // Plugins that configure DC (servos with SYNC0/SYNC1) override and
    // return true. Plugins that don't (passthrough, safety) leave the
    // default false. The daemon skips the sync calls when zero devices
    // return true.
    virtual bool hasDcEnabled() const { return false; }

    // How many bytes this device needs in the SHM command/state regions.
    virtual uint16_t shmCmdSize() const = 0;
    virtual uint16_t shmStateSize() const = 0;

    // --- RT CYCLE (called every cycle, ~250-500us) ---

    // Read inputs from IgH domain process data into plugin internal state.
    virtual void readInputs(uint8_t* domain_pd) = 0;

    // Write outputs from plugin internal state to IgH domain process data.
    virtual void writeOutputs(uint8_t* domain_pd) = 0;

    // Per-cycle protocol logic (DS402, safety checks, etc.).
    // Called after readInputs(), before writeOutputs().
    virtual void cyclicTask() = 0;

    // Read command bytes from SHM into plugin internal state.
    virtual void readShmCmd(const uint8_t* shm_cmd) = 0;

    // Write plugin internal state into SHM state bytes.
    virtual void writeShmState(uint8_t* shm_state) = 0;
};

} // namespace ecat

// ---------------------------------------------------------------------------
// External .so plugins must export these C functions.
// Built-in plugins (passthrough) do not need these.
// ---------------------------------------------------------------------------
extern "C" {

/**
 * Create a plugin instance for a specific slave.
 * @param name             Device name from bus config YAML
 * @param position         Bus position (0-based)
 * @param config_yaml_path Path to plugin-specific config file (may be empty)
 * @return                 Heap-allocated plugin instance
 */
ecat::EcatDevicePlugin* create_plugin(const char* name, uint8_t position,
                                       const char* config_yaml_path);

/** Destroy a plugin instance created by create_plugin(). */
void destroy_plugin(ecat::EcatDevicePlugin* p);

/** Return the plugin API version for compatibility checking. */
uint32_t plugin_api_version();

}
