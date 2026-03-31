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
local OLLA_PERIOD  = 10     -- adjust every 10 frames (100ms)
local BLER_TARGET  = 0.10
local OLLA_UP      = 0.10   -- step up per period when BLER < target
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
    -- QoS targets / scheduler weights
    -----------------------------------------------------------------------
    local EMBB_LATENCY_TARGET_US = 50000      -- 50 ms
    local URLLC_TARGET_THR_BPS   = 80e6       -- 80 Mbps, m.throughput is in bits/s

    local URLLC_WEIGHT = 12.0
    local EMBB_WEIGHT  = 4.0

    -- Protected minimum eMBB share when both classes are active
    local EMBB_MIN_SHARE = 0.40

    -----------------------------------------------------------------------
    -- Local helpers
    -----------------------------------------------------------------------


    local function get_service_class(m)
        local q = tonumber(m.fiveQI)
        if q == 69 then
            return "URLLC"
        end
        return "eMBB"
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

    local function allocate_to_ue(m, mask_str, requested_rbs)
        if requested_rbs < min_rbs then
            return mask_str, 0
        end

        local start_rb = find_free_rbs(mask_str, requested_rbs, m.bwp_start, m.bwp_size)
        if start_rb < 0 then
            return mask_str, 0
        end

        local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame)

        m.allocated_rb = requested_rbs
        m.allocated_mcs = mcs
        m.allocated_rb_start = start_rb

        mask_str = mark_used(mask_str, start_rb, requested_rbs, m.bwp_start)
        return mask_str, requested_rbs
    end

    local function allocate_best_contiguous_block(m, mask_str, max_budget)
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

    local function try_allocate_with_fallback(m, mask_str, max_budget)
        if max_budget < min_rbs then
            return mask_str, 0
        end

        local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
        local target = math.min(req, max_budget)

        if target >= min_rbs then
            local new_mask, got = allocate_to_ue(m, mask_str, target)
            if got > 0 then
                return new_mask, got
            end
        end

        return allocate_best_contiguous_block(m, mask_str, max_budget)
    end

    -----------------------------------------------------------------------
    -- Reset per-slot outputs
    -----------------------------------------------------------------------
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        m.allocated_rb = 0
        m.allocated_mcs = 9
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
            print(string.format(
                "[DL %d.%d] UE uid=%d rnti=%04x class=%s pending=%d thr=%.0f bps mcs=%d olla_frac=%s bler=%.3f cqi=%d hol=%d us type=%d",
                m.frame, m.slot, m.uid, m.rnti, get_service_class(m),
                m.pending_bytes, m.throughput, m.previous_mcs, frac_str,
                m.bler, m.cqi, tonumber(m.hol_delay_us), m.ue_type))
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
    -- Phase 2: Build QoS-aware candidate lists
    -----------------------------------------------------------------------
    local urllc_ues = {}
    local embb_ues  = {}

    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and m.pending_bytes > 0 then
            local class = get_service_class(m)
            local thr = (m.throughput > 0) and m.throughput or 1.0   -- bits/s
            local hol = tonumber(m.hol_delay_us) or 0

            if class == "URLLC" then
                local thr_deficit = URLLC_TARGET_THR_BPS / math.max(thr, 1.0)
                if thr_deficit < 1.0 then
                    thr_deficit = 1.0
                end

                local hol_urgency = 1.0 + (hol / 1000.0)
                local priority = URLLC_WEIGHT * thr_deficit * hol_urgency

                urllc_ues[#urllc_ues + 1] = {
                    idx = i,
                    priority = priority,
                    hol = hol,
                    thr = thr
                }
            else
                local lateness_ratio = hol / EMBB_LATENCY_TARGET_US
                local urgency

                if hol < EMBB_LATENCY_TARGET_US then
                    urgency = 1.0 + lateness_ratio
                else
                    urgency = 2.0 + 8.0 * (lateness_ratio - 1.0)
                end

                local thr_mbps = thr / 1e6
                local pf_term = (m.previous_mcs + 1.0) / math.max(thr_mbps, 1.0)
                local priority = EMBB_WEIGHT * urgency * pf_term

                embb_ues[#embb_ues + 1] = {
                    idx = i,
                    priority = priority,
                    hol = hol,
                    thr = thr
                }
            end
        end
    end

    table.sort(urllc_ues, function(a, b)
        if a.priority == b.priority then
            return a.hol > b.hol
        end
        return a.priority > b.priority
    end)

    table.sort(embb_ues, function(a, b)
        if a.priority == b.priority then
            return a.hol > b.hol
        end
        return a.priority > b.priority
    end)

    -----------------------------------------------------------------------
    -- Phase 3: Dynamic QoS-aware class budget split
    --
    -- React to BOTH:
    --   * URLLC throughput deficit relative to 80 Mbps
    --   * eMBB latency violation relative to 50 ms
    -----------------------------------------------------------------------
    local free_now = count_free_rbs(mask, 0, total_rbs)
    if free_now < min_rbs then
        return
    end

    local has_urllc = (#urllc_ues > 0)
    local has_embb  = (#embb_ues > 0)

    local urllc_budget = 0
    local embb_budget  = 0

    if has_urllc and has_embb then
        -------------------------------------------------------------------
        -- Aggregate URLLC pressure
        -------------------------------------------------------------------
        local urllc_below_target = 0
        local urllc_avg_deficit = 1.0
        local urllc_max_deficit = 1.0

        if #urllc_ues > 0 then
            local deficit_sum = 0.0

            for _, entry in ipairs(urllc_ues) do
                local thr = entry.thr or 1.0
                local deficit = URLLC_TARGET_THR_BPS / math.max(thr, 1.0)
                if deficit < 1.0 then
                    deficit = 1.0
                end

                deficit_sum = deficit_sum + deficit

                if thr < URLLC_TARGET_THR_BPS then
                    urllc_below_target = urllc_below_target + 1
                end

                if deficit > urllc_max_deficit then
                    urllc_max_deficit = deficit
                end
            end

            urllc_avg_deficit = deficit_sum / #urllc_ues
        end

        -------------------------------------------------------------------
        -- Aggregate eMBB pressure
        -------------------------------------------------------------------
        local embb_violating = 0
        local embb_avg_violation = 0.0
        local embb_max_violation = 0.0

        if #embb_ues > 0 then
            local violation_sum = 0.0

            for _, entry in ipairs(embb_ues) do
                local hol = entry.hol or 0
                local violation = hol / EMBB_LATENCY_TARGET_US

                if violation > 1.0 then
                    embb_violating = embb_violating + 1
                    violation_sum = violation_sum + violation

                    if violation > embb_max_violation then
                        embb_max_violation = violation
                    end
                end
            end

            if embb_violating > 0 then
                embb_avg_violation = violation_sum / embb_violating
            end
        end

        -------------------------------------------------------------------
        -- Compute share shift from a balanced baseline
        -------------------------------------------------------------------
        local dynamic_urllc_share = 0.25

        if urllc_below_target > 0 then
            local urllc_pressure =
                0.10 * math.min(urllc_avg_deficit - 1.0, 2.0) +
                0.08 * math.min(urllc_max_deficit - 1.0, 2.0)

            if urllc_below_target >= 2 then
                urllc_pressure = urllc_pressure + 0.05
            end

            dynamic_urllc_share = dynamic_urllc_share + urllc_pressure
        end

        if embb_violating > 0 then
            local embb_pressure =
                0.08 * math.min(embb_avg_violation - 1.0, 2.0) +
                0.10 * math.min(embb_max_violation - 1.0, 2.0)

            if embb_violating >= 2 then
                embb_pressure = embb_pressure + 0.05
            end

            dynamic_urllc_share = dynamic_urllc_share - embb_pressure
        end

        dynamic_urllc_share = math.max(0.30, math.min(dynamic_urllc_share, 0.75))

        -------------------------------------------------------------------
        -- Convert share to budgets
        -------------------------------------------------------------------
        embb_budget = math.max(min_rbs, math.floor(free_now * EMBB_MIN_SHARE))
        urllc_budget = math.floor(free_now * dynamic_urllc_share)

        if urllc_budget + embb_budget > free_now then
            urllc_budget = free_now - embb_budget
        end

        local assigned = urllc_budget + embb_budget
        if assigned < free_now then
            local extra = free_now - assigned

            local urllc_pressure_score = 0.0
            local embb_pressure_score = 0.0

            if urllc_below_target > 0 then
                urllc_pressure_score = (urllc_avg_deficit - 1.0) + (urllc_max_deficit - 1.0)
            end

            if embb_violating > 0 then
                embb_pressure_score = (embb_avg_violation - 1.0) + (embb_max_violation - 1.0)
            end

            if urllc_pressure_score >= embb_pressure_score then
                urllc_budget = urllc_budget + extra
            else
                embb_budget = embb_budget + extra
            end
        end

        -------------------------------------------------------------------
        -- Final safety guards
        -------------------------------------------------------------------
        if urllc_budget < min_rbs and free_now >= 2 * min_rbs then
            urllc_budget = min_rbs
            embb_budget = free_now - urllc_budget
        end

        if embb_budget < min_rbs and free_now >= 2 * min_rbs then
            embb_budget = min_rbs
            urllc_budget = free_now - embb_budget
        end

    elseif has_urllc then
        urllc_budget = free_now
    elseif has_embb then
        embb_budget = free_now
    else
        return
    end

    -----------------------------------------------------------------------
    -- Phase 4: Allocate URLLC budget
    -- One contiguous block per UE only
    -----------------------------------------------------------------------
    local used_urllc = 0
    for _, entry in ipairs(urllc_ues) do
        local m = metrics[entry.idx]
        local remain = urllc_budget - used_urllc
        if remain < min_rbs then
            break
        end

        local new_mask, got = try_allocate_with_fallback(m, mask, remain)
        mask = new_mask
        used_urllc = used_urllc + got
    end

    -----------------------------------------------------------------------
    -- Phase 5: Allocate eMBB budget
    -- One contiguous block per UE only
    -----------------------------------------------------------------------
    local used_embb = 0
    for _, entry in ipairs(embb_ues) do
        local m = metrics[entry.idx]
        local remain = embb_budget - used_embb
        if remain < min_rbs then
            break
        end

        local new_mask, got = try_allocate_with_fallback(m, mask, remain)
        mask = new_mask
        used_embb = used_embb + got
    end

    -----------------------------------------------------------------------
    -- Phase 6: Leftover RBs, contiguous-only
    --
    -- Priority:
    --   1) unscheduled URLLC below 80 Mbps target
    --   2) unscheduled eMBB violating 50 ms HOL target
    --   3) remaining unscheduled URLLC
    --   4) remaining unscheduled eMBB
    -----------------------------------------------------------------------
    local leftover = count_free_rbs(mask, 0, total_rbs)

    if leftover >= min_rbs then
        for _, entry in ipairs(urllc_ues) do
            local m = metrics[entry.idx]
            local thr = (m.throughput > 0) and m.throughput or 1.0

            if m.allocated_rb == 0 and thr < URLLC_TARGET_THR_BPS then
                local new_mask, got = try_allocate_with_fallback(m, mask, leftover)
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
            local hol = tonumber(m.hol_delay_us) or 0

            if m.allocated_rb == 0 and hol >= EMBB_LATENCY_TARGET_US then
                local new_mask, got = try_allocate_with_fallback(m, mask, leftover)
                mask = new_mask
                leftover = leftover - got
                if leftover < min_rbs then
                    break
                end
            end
        end
    end

    if leftover >= min_rbs then
        for _, entry in ipairs(urllc_ues) do
            local m = metrics[entry.idx]
            if m.allocated_rb == 0 then
                local new_mask, got = try_allocate_with_fallback(m, mask, leftover)
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
                local new_mask, got = try_allocate_with_fallback(m, mask, leftover)
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
            "[QoS DL CONTIG %d.%d] budgets: urllc=%d embb=%d leftover=%d",
            metrics[0].frame, metrics[0].slot, urllc_budget, embb_budget, leftover))

        for i = 0, n_ues - 1 do
            local m = metrics[i]
            print(string.format(
                "[QoS DL CONTIG %d.%d] UE uid=%d rnti=%04x class=%s pending=%d thr=%.0f bps hol=%d us alloc_rb=%d alloc_mcs=%d alloc_start=%d type=%d",
                m.frame, m.slot, m.uid, m.rnti, get_service_class(m),
                m.pending_bytes, m.throughput, tonumber(m.hol_delay_us),
                m.allocated_rb, m.allocated_mcs, m.allocated_rb_start, m.ue_type))
        end
    end
end