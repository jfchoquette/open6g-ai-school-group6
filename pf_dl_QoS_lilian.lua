--------------------------------------------------------------------------- DL PF Scheduler with OLLA MCS adaptation (every 10 frames / 100ms).
-- Every slot: retx → new data (PF sorted, largest block).
-- Use: export LUA_SCHED=/path/to/pf_dl_simple.lua

local ffi = require("ffi")

ffi.cdef[[
typedef struct {
    uint16_t rnti;
    uint8_t nr_of_layers;
    uint32_t pending_bytes;
    float throughput;
    uint8_t previous_mcs;
    int ue_type;
    uint16_t required_rbs;
    uint8_t required_mcs;
    uint16_t cqi;
    int uid;
    int mcs_table;
    float bler;
    int slot;
    int frame;
    uint64_t fiveQI;
    int16_t channel_mag_per_rb[272];
    uint32_t bwp_start;
    uint32_t bwp_size;
    int16_t dl_rsrp;
    uint64_t hol_delay_us;
    uint16_t allocated_rb;
    uint8_t allocated_mcs;
    uint16_t allocated_rb_start;
} dl_ue_metric_t;
]]

local UE_TYPE_NEW_DATA = 0
local UE_TYPE_HARQ_RETX = 1

---------------------------------------------------------------------------
-- OLLA state per RNTI
---------------------------------------------------------------------------
local olla = {}

local MAX_FRAME    = 1024   -- NR frame counter wraps at 1024
local OLLA_PERIOD  = 5     -- adjust every 5 frames (50ms)
local BLER_TARGET  = 0.10
local OLLA_UP      = 0.50   -- step up per period when BLER < target
local OLLA_DOWN    = 1.00   -- step down per period when BLER >= target
local MIN_MCS      = 0

local function frames_elapsed(now, last)
    return (now - last) % MAX_FRAME
end

local function olla_mcs(rnti, seed_mcs, bler, mcs_table, frame)
    local max_mcs = 27
    local s = olla[rnti]

    if not s then
        local init = seed_mcs > 0 and seed_mcs or 4
        s = { frac = init + 0.0, last_frame = frame }
        olla[rnti] = s
    end

    -- One adjustment per OLLA_PERIOD frames
    if frames_elapsed(frame, s.last_frame) >= OLLA_PERIOD then
        if bler < BLER_TARGET then
            s.frac = s.frac + OLLA_UP
        else
            s.frac = s.frac - OLLA_DOWN
        end
        s.last_frame = frame
    end

    -- Clamp to valid range
    s.frac = math.max(MIN_MCS, math.min(s.frac, max_mcs))

    return math.floor(s.frac)
end

---------------------------------------------------------------------------
-- RB mask helpers
---------------------------------------------------------------------------

-- Find first contiguous free RBs in mask
local function find_free_rbs(mask, needed, bwp_start, bwp_size)
    local count = 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1  -- Lua 1-indexed
        if mask:sub(idx, idx) ~= 'X' then
            count = count + 1
            if count == needed then
                return rb - needed + 1  -- 0-indexed start within BWP
            end
        else
            count = 0
        end
    end
    return -1
end

-- Mark RBs as used in mask string
local function mark_used(mask, start_rb, num_rbs, bwp_start)
    local chars = {}
    for i = 1, #mask do chars[i] = mask:sub(i, i) end
    for rb = start_rb, start_rb + num_rbs - 1 do
        chars[bwp_start + rb + 1] = 'X'
    end
    return table.concat(chars)
end

-- Find largest contiguous free block
local function find_largest_block(mask, bwp_start, bwp_size)
    local best_start, best_len = -1, 0
    local cur_start, cur_len = -1, 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1
        if mask:sub(idx, idx) ~= 'X' then
            if cur_len == 0 then cur_start = rb end
            cur_len = cur_len + 1
        else
            if cur_len > best_len then
                best_start = cur_start
                best_len = cur_len
            end
            cur_len = 0
        end
    end
    if cur_len > best_len then
        best_start = cur_start
        best_len = cur_len
    end
    return best_start, best_len
end

---------------------------------------------------------------------------
-- Debug logging (periodic)
---------------------------------------------------------------------------
local debug_counter = 0

---------------------------------------------------------------------------
-- Main entry point called from C every DL slot
---------------------------------------------------------------------------
function compute_dl_allocations(metrics_ptr, n_ues, total_rbs, min_rbs, rb_mask_string)
    local metrics = ffi.cast("dl_ue_metric_t*", metrics_ptr)
    local mask = rb_mask_string

    -----------------------------------------------------------------------
    -- QoS configuration
    -----------------------------------------------------------------------
    local EMBB_LATENCY_TARGET_US = 50000    -- 50 ms
    local URLLC_TARGET_THR_BPS   = 80e6     -- 80 Mbps, throughput is in bits/s

    -----------------------------------------------------------------------
    -- Local helpers
    -----------------------------------------------------------------------
    
    local function get_service_class(fiveQI)
        local qi = tonumber(fiveQI)
        if q1 == 69 then
            return "eMBB" -- LF: need to change the code later
        else
            return "URLLC"
        end
    end
    

    local function count_free_rbs(mask_str, bwp_start, bwp_size)
        local cnt = 0
        for rb = 0, bwp_size - 1 do
            local idx = bwp_start + rb + 1
            if mask_str:sub(idx, idx) ~= 'X' then
                cnt = cnt + 1
            end
        end
        return cnt
    end

    local function allocate_exact_or_less(m, mask_str, max_budget)
        if max_budget < min_rbs then
            return mask_str, 0
        end

        local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
        local grant = math.min(req, max_budget)

        while grant >= min_rbs do
            local start_rb = find_free_rbs(mask_str, grant, m.bwp_start, m.bwp_size)
            if start_rb >= 0 then
                local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame)
                m.allocated_rb = grant
                m.allocated_mcs = mcs
                m.allocated_rb_start = start_rb
                mask_str = mark_used(mask_str, start_rb, grant, m.bwp_start)
                return mask_str, grant
            end
            grant = grant - 1
        end

        return mask_str, 0
    end

    local function allocate_largest_possible(m, mask_str, max_budget)
        if max_budget < min_rbs then
            return mask_str, 0
        end

        local best_start, best_len = find_largest_block(mask_str, m.bwp_start, m.bwp_size)
        if best_start < 0 or best_len < min_rbs then
            return mask_str, 0
        end

        local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
        local grant = math.min(req, max_budget, best_len)
        if grant < min_rbs then
            return mask_str, 0
        end

        local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame)
        m.allocated_rb = grant
        m.allocated_mcs = mcs
        m.allocated_rb_start = best_start
        mask_str = mark_used(mask_str, best_start, grant, m.bwp_start)
        return mask_str, grant
    end

    local function allocate_with_fallback(m, mask_str, max_budget)
        local new_mask, got = allocate_exact_or_less(m, mask_str, max_budget)
        if got > 0 then
            return new_mask, got
        end
        return allocate_largest_possible(m, mask_str, max_budget)
    end

    -----------------------------------------------------------------------
    -- Reset per-slot outputs
    -----------------------------------------------------------------------
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        m.allocated_rb = 0
        m.allocated_mcs = 0
        m.allocated_rb_start = 0
    end

    -----------------------------------------------------------------------
    -- Debug
    -----------------------------------------------------------------------
    debug_counter = debug_counter + 1
    if debug_counter % 100 == 0 then
        for i = 0, n_ues - 1 do
            local m = metrics[i]
            local s = olla[m.rnti]
            local frac_str = s and string.format("%.2f", s.frac) or "N/A"

            -- Print only active DL users
            if m.pending_bytes > 0 or m.required_rbs > 0 then
                print(string.format(
                    "[ACTIVE DL %d.%d] UE uid=%d rnti=%04x fiveQI=%d class=%s pending=%d thr=%.0f bps req_rbs=%d alloc_rb=%d prev_mcs=%d olla_frac=%s bler=%.3f hol=%d us type=%d",
                    m.frame, m.slot, m.uid, m.rnti, tonumber(m.fiveQI), get_service_class(m.fiveQI),
                    m.pending_bytes, m.throughput, m.required_rbs, m.allocated_rb,
                    m.previous_mcs, frac_str, m.bler, tonumber(m.hol_delay_us), m.ue_type))
            end
        
        end
    end


    -----------------------------------------------------------------------
    -- Phase 1: HARQ retransmissions first
    -----------------------------------------------------------------------
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_HARQ_RETX and m.required_rbs > 0 then
            local s = find_free_rbs(mask, m.required_rbs, m.bwp_start, m.bwp_size)
            if s >= 0 then
                m.allocated_rb = m.required_rbs
                m.allocated_mcs = m.required_mcs
                m.allocated_rb_start = s
                mask = mark_used(mask, s, m.required_rbs, m.bwp_start)
            end
        end
    end

    -----------------------------------------------------------------------
    -- Phase 2: Build lists
    --
    -- eMBB:
    --   only protected if it is already violating the latency target
    --
    -- URLLC:
    --   prioritized by throughput deficit
    -----------------------------------------------------------------------
    local urllc_ues = {}
    local embb_ues  = {}

    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and m.pending_bytes > 0 then
            local class = get_service_class(m.fiveQI)
            local thr = (m.throughput > 0) and m.throughput or 1.0
            local hol = tonumber(m.hol_delay_us) or 0

            if class == "URLLC" then
                local deficit = URLLC_TARGET_THR_BPS / math.max(thr, 1.0)
                if deficit < 1.0 then
                    deficit = 1.0
                end

                urllc_ues[#urllc_ues + 1] = {
                    idx = i,
                    thr = thr,
                    hol = hol,
                    deficit = deficit
                }
            else
                embb_ues[#embb_ues + 1] = {
                    idx = i,
                    hol = hol
                }
            end
        end
    end

    table.sort(embb_ues, function(a, b)
        return a.hol > b.hol
    end)

    table.sort(urllc_ues, function(a, b)
        if a.deficit == b.deficit then
            return a.hol > b.hol
        end
        return a.deficit > b.deficit
    end)

    -----------------------------------------------------------------------
    -- Phase 3: rescue eMBB only if latency target is already violated
    --
    -- This is intentionally aggressive for URLLC.
    -- For ping traffic, we do not reserve RBs and we do not serve eMBB early
    -- unless it is actually in trouble.
    -----------------------------------------------------------------------
    local free_now = count_free_rbs(mask, 0, total_rbs)
    if free_now < min_rbs then
        return
    end

    local used_embb = 0

    for _, entry in ipairs(embb_ues) do
        local m = metrics[entry.idx]
        local remain = free_now - used_embb
        if remain < min_rbs then
            break
        end

        if entry.hol >= EMBB_LATENCY_TARGET_US then
            -- Low-rate traffic: just give enough to avoid latency explosion.
            local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
            local grant_budget = math.min(req, remain)

            local new_mask, got = allocate_with_fallback(m, mask, grant_budget)
            mask = new_mask
            used_embb = used_embb + got
        end
    end

    -----------------------------------------------------------------------
    -- Phase 4: give the rest to URLLC
    --
    -- If there is one URLLC UE, it can use the whole remaining budget.
    -- If there are multiple URLLC UEs, split the budget fairly according
    -- to throughput deficit.
    -----------------------------------------------------------------------
    local urllc_budget = count_free_rbs(mask, 0, total_rbs)

    if urllc_budget >= min_rbs and #urllc_ues > 0 then
        local deficit_sum = 0.0
        for _, entry in ipairs(urllc_ues) do
            deficit_sum = deficit_sum + entry.deficit
        end

        local used_urllc = 0

        for pos, entry in ipairs(urllc_ues) do
            local m = metrics[entry.idx]
            local remain = urllc_budget - used_urllc
            if remain < min_rbs then
                break
            end

            local grant_budget

            if #urllc_ues == 1 or deficit_sum <= 0.0 then
                grant_budget = remain
            else
                grant_budget = math.floor(urllc_budget * (entry.deficit / deficit_sum))

                if pos == #urllc_ues then
                    grant_budget = remain
                end

                if grant_budget < min_rbs then
                    grant_budget = min_rbs
                end

                if grant_budget > remain then
                    grant_budget = remain
                end
            end

            local new_mask, got = allocate_with_fallback(m, mask, grant_budget)
            mask = new_mask
            used_urllc = used_urllc + got
        end
    end

    -----------------------------------------------------------------------
    -- Phase 5: leftover RBs
    --
    -- Priority:
    --   1) remaining unscheduled URLLC
    --   2) remaining unscheduled eMBB
    -----------------------------------------------------------------------
    local leftover = count_free_rbs(mask, 0, total_rbs)

    if leftover >= min_rbs then
        for _, entry in ipairs(urllc_ues) do
            local m = metrics[entry.idx]
            if m.allocated_rb == 0 then
                local new_mask, got = allocate_with_fallback(m, mask, leftover)
                mask = new_mask
                leftover = leftover - got
                if leftover < min_rbs then
                    break
                end
            end
        end
    end

    if leftover >= min_rbs then
        for _, entry in ipairs(embb_ues) do
            local m = metrics[entry.idx]
            if m.allocated_rb == 0 then
                local new_mask, got = allocate_with_fallback(m, mask, leftover)
                mask = new_mask
                leftover = leftover - got
                if leftover < min_rbs then
                    break
                end
            end
        end
    end

    -----------------------------------------------------------------------
    -- Final debug print
    -----------------------------------------------------------------------
    if debug_counter % 100 == 0 then
        print(string.format(
            "[QoS DL %d.%d] leftover=%d urllc_count=%d embb_count=%d",
            metrics[0].frame, metrics[0].slot, leftover, #urllc_ues, #embb_ues))

        for i = 0, n_ues - 1 do
            local m = metrics[i]
            print(string.format(
                "[QoS DL %d.%d] UE uid=%d rnti=%04x fiveQI=%d class=%s pending=%d thr=%.0f bps req_rbs=%d hol=%d us alloc_rb=%d alloc_mcs=%d alloc_start=%d type=%d",
                m.frame, m.slot, m.uid, m.rnti, tonumber(m.fiveQI), get_service_class(m.fiveQI),
                m.pending_bytes, m.throughput, m.required_rbs, tonumber(m.hol_delay_us),
                m.allocated_rb, m.allocated_mcs, m.allocated_rb_start, m.ue_type))
        end
    end
end
