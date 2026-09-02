module satay::constants {
    /// Default profit lock duration, expressed in seconds.
    const DEFAULT_LOCK_DURATION: u64 = 1_209_600;
    /// Default performance fee, expressed in BPS.
    const DEFAULT_PERFORMANCE_FEE: u64 = 1500;
    /// Default management fee, expressed in BPS.
    const DEFAULT_MANAGEMENT_FEE: u64 = 200;
    /// Default protocol fee, expressed in BPS.
    const DEFAULT_PROTOCOL_FEE: u64 = 500;

    /// Maximum profit lock duration, expressed in seconds.
    const MAX_LOCK_DURATION: u64 = 2_419_200;
    /// Minimum profit lock duration, expressed in seconds.
    const MIN_LOCK_DURATION: u64 = 604_800;
    /// Maximum protocol fee, expressed in BPS.
    const MAX_PROTOCOL_FEE: u64 = 500;
    /// Maximum performance fee, expressed in BPS.
    const MAX_MANAGEMENT_FEE: u64 = 300;
    /// Maximum performance fee, expressed in BPS.
    const MAX_PERFORMANCE_FEE: u64 = 2000;

    /// Timelock defaults for router
    const MAX_ROUTER_DELAY: u64 = 604_800;
    const DEFAULT_ROUTER_DELAY: u64 = 3600;

    /// Timelock defaults for governance
    const MAX_GOVERNANCE_DELAY: u64 = 604_800;
    const DEFAULT_GOVERNANCE_DELAY: u64 = 3600;

    /// Max basis points (100%)
    const MAX_BPS: u64 = 10_000;

    /// Seconds per year
    const SECONDS_PER_YEAR: u64 = 31_556_952; // 365.2425 days

    /// Maximum u64 value
    const U64_MAX: u64 = 18446744073709551615;

    public fun default_lock_duration(): u64 {
        DEFAULT_LOCK_DURATION
    }

    public fun default_performance_fee(): u64 {
        DEFAULT_PERFORMANCE_FEE
    }

    public fun default_management_fee(): u64 {
        DEFAULT_MANAGEMENT_FEE
    }

    public fun default_protocol_fee(): u64 {
        DEFAULT_PROTOCOL_FEE
    }

    public fun max_lock_duration(): u64 {
        MAX_LOCK_DURATION
    }

    public fun min_lock_duration(): u64 {
        MIN_LOCK_DURATION
    }

    public fun max_protocol_fee(): u64 {
        MAX_PROTOCOL_FEE
    }

    public fun max_management_fee(): u64 {
        MAX_MANAGEMENT_FEE
    }

    public fun max_performance_fee(): u64 {
        MAX_PERFORMANCE_FEE
    }

    public fun seconds_per_year(): u64 {
        SECONDS_PER_YEAR
    }

    public fun bps_max(): u64 {
        MAX_BPS
    }

    public fun u64_max(): u64 {
        U64_MAX
    }

    public fun max_router_delay(): u64 {
        MAX_ROUTER_DELAY
    }

    public fun default_router_delay(): u64 {
        DEFAULT_ROUTER_DELAY
    }

    public fun max_governance_delay(): u64 {
        MAX_GOVERNANCE_DELAY
    }

    public fun default_governance_delay(): u64 {
        DEFAULT_GOVERNANCE_DELAY
    }
}
