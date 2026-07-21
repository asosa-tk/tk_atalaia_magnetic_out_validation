#pragma once
#include <ecrt.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "tk_ros2_pkg_ethercat_master/ecat_pdo_types.hpp"
#include "tk_ros2_pkg_ethercat_master/ecat_shm.hpp"

namespace ecat {

class EcatDeviceBase {
public:
    EcatDeviceBase(const std::string& name, uint8_t position,
                   uint32_t vendor_id, uint32_t product_code);
    virtual ~EcatDeviceBase() = default;

    // --- Pure virtual interface ---
    virtual void discoverPdos(ec_master_t* /*master*/) {}
    virtual void definePdoMapping() = 0;
    virtual void configureSDOs(ec_slave_config_t* sc) = 0;
    // Default no-op. See ecat_plugin_interface.hpp for the contract.
    virtual void applyCriticalSDOs(ec_master_t* /*master*/) {}
    virtual void setBusCycleNs(uint32_t /*cycle_ns*/) {}
    virtual void readInputs(uint8_t* domain_pd) = 0;
    virtual void writeOutputs(uint8_t* domain_pd) = 0;
    virtual void cyclicTask() = 0;
    virtual uint16_t shmCmdSize() const = 0;
    virtual uint16_t shmStateSize() const = 0;
    virtual void readShmCmd(const uint8_t* shm_cmd_base) = 0;
    virtual void writeShmState(uint8_t* shm_state_base) = 0;

    // --- Common implementation ---
    //
    // Two domains:
    //   in_domain  — collects entries from EC_DIR_INPUT  sync managers
    //                (slave → master, TxPDO data: process inputs).
    //   out_domain — collects entries from EC_DIR_OUTPUT sync managers
    //                (master → slave, RxPDO data: process outputs).
    //
    // Splitting the domains is required for slaves with R/O fixed FMMUs
    // that map separate logical-address ranges to their TxPDO and RxPDO
    // SM regions (Pilz PNOZmulti EF, Euchner MBM, and most safety
    // controllers). With a single combined domain, the slave's FMMUs
    // refuse to match the master's logical address and LRW WKC stays
    // at 0 even though the slaves respond to point-to-point reads.
    //
    // For devices that don't need direction separation (DS402 servos,
    // simple I/O passthroughs), this just splits the same PDOs into
    // two adjacent logical ranges; the kernel handles both transparently
    // and there is no measurable overhead.
    bool registerWithMaster(ec_master_t* master,
                            ec_domain_t* in_domain,
                            ec_domain_t* out_domain);

    // Poll slave config state from IgH — call periodically from daemon loop.
    // Returns true if al_state changed (for transition logging).
    bool updateSlaveState() {
        if (!sc_) return false;
        ec_slave_config_state_t st;
        ecrt_slave_config_state(sc_, &st);
        bool changed = (st.al_state != slave_al_state_);
        slave_al_state_ = st.al_state;
        slave_online_ = st.online;
        slave_operational_ = st.operational;
        return changed;
    }
    uint8_t slaveAlState() const { return slave_al_state_; }
    uint8_t slaveOnline() const { return slave_online_; }
    uint8_t slaveOperational() const { return slave_operational_; }

    // Getters
    const std::string& name() const { return name_; }
    uint8_t position() const { return position_; }
    uint32_t vendorId() const { return vendor_id_; }
    uint32_t productCode() const { return product_code_; }
    float publishRateHz() const { return publish_rate_hz_; }
    void setPublishRateHz(float hz) { publish_rate_hz_ = hz; }
    void setIdentity(uint32_t vid, uint32_t pid) { vendor_id_ = vid; product_code_ = pid; }
    ec_slave_config_t* slaveConfig() const { return sc_; }

    // PREOP-settle: extra delay between the slave reaching PREOP and the
    // master walking SDOs on it. Some modular I/O slaves (notably the SMC
    // EX600) finish their EtherCAT-side PREOP transition fast but need
    // hundreds of ms more to complete an internal sub-bus enumeration.
    // SDO reads issued before that finishes can return truncated /
    // inconsistent values, latching the slave into stuck-PREOP. Default
    // 0 (no delay); set per-slave in the bus YAML.
    uint32_t preopSettleMs() const { return preop_settle_ms_; }
    void setPreopSettleMs(uint32_t ms) { preop_settle_ms_ = ms; }

    // Returns true if this device already has its PDO map resolved (e.g.
    // via an on-disk discovery cache) and therefore doesn't need the
    // daemon's deep readiness probe to wait for the CoE mailbox to settle.
    // Plugins that rely on live SDO discovery override this to short-circuit
    // when they have a cache hit. Default = false (probe runs as configured).
    virtual bool hasCachedPdoMap(ec_master_t* /*master*/) { return false; }

    // Returns true if this slave participates in Distributed Clocks. The
    // daemon polls this across all devices to decide whether to issue
    // per-cycle DC sync datagrams. See ecat_plugin_interface.hpp for the
    // full contract. Default = false.
    virtual bool hasDcEnabled() const { return false; }

protected:
    std::string name_;
    uint8_t position_;
    uint32_t vendor_id_;
    uint32_t product_code_;
    float publish_rate_hz_ = 100.0f;
    uint32_t preop_settle_ms_ = 0;

    // Per-slave state (updated by updateSlaveState)
    uint8_t slave_al_state_ = 0;
    uint8_t slave_online_ = 0;
    uint8_t slave_operational_ = 0;

    ec_slave_config_t* sc_ = nullptr;
    std::vector<SyncManagerDesc> sync_managers_;

    // Storage for IgH C arrays (kept alive for the master's lifetime).
    // c_regs_in_/c_regs_out_ are split by SM direction so each batch
    // registers to its own domain. The old single c_regs_ is gone.
    std::vector<ec_pdo_entry_info_t> c_entries_;
    std::vector<ec_pdo_info_t> c_pdos_;
    std::vector<ec_sync_info_t> c_syncs_;
    std::vector<ec_pdo_entry_reg_t> c_regs_in_;
    std::vector<ec_pdo_entry_reg_t> c_regs_out_;
};

} // namespace ecat
