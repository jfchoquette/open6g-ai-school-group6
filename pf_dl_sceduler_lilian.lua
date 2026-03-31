-- DL Fair Scheduler with OLLA MCS adaptation
-- U1 -> eMBB
-- U2 -> URLLC
-- HARQ retransmissions first
-- New data scheduling:
--   * Fair split between eMBB and URLLC
--   * URLLC priority uses HOL delay awareness
--   * eMBB uses PF-like throughput fairness
--
-- Use:
--   export LUA_SCHED=/path/to/this_scheduler.lua

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

local UE_TYPE_NEW_DATA  = 0
local UE_TYPE_HARQ_RETX = 1

---------------------------------------------------------------------------
-- OLLA state per RNTI
---------------------------------------------------------------------------
local olla = {}

local MAX_FRAME   = 1024
local OLLA_PERIOD = 10     -- adjust every 10 frames (100ms)
local BLER_TARGET = 0.10
local OLLA_UP     = 0.10
local OLLA_DOWN   = 1.00
local MIN_MCS     = 0

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
        local idx = bwp_start + rb + 1 -- Lua 1-indexed
        if mask:sub(idx, idx) ~= 'X' then
            count = count + 1
            if count == needed then
                return rb - needed + 1 -- 0-indexed start within BWP
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
    for i = 1, #mask do
        chars[i] = mask:sub(i, i)
    end
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
            if cur_len == 0 then
                cur_start = rb
            end
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

-- LF: new implementation
local function count_free_rbs(mask, bwp_start, bwp_size)
    local cnt = 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1
        if mask:sub(idx, idx) ~= 'X' then
            cnt = cnt + 1
        end
    end
    return cnt
end

---------------------------------------------------------------------------
-- Service classification
-- Requested mapping:
--   U1 -> eMBB
--   U2 -> URLLC
---------------------------------------------------------------------------
local function get_service_class(fiveQI)
    local qi = tonumber(fiveQI)
    if qi == 69 then
        return "URLLC"
    else
        return "eMBB"
    end
end

---------------------------------------------------------------------------
-- Debug logging (periodic)
---------------------------------------------------------------------------
local debug_counter = 0

---------------------------------------------------------------------------
-- Allocation helper
---------------------------------------------------------------------------
local function allocate_to_ue(m, mask, requested_rbs, min_rbs)
    if requested_rbs < min_rbs then
        return mask, 0
    end

    local start_rb = find_free_rbs(mask, requested_rbs, m.bwp_start, m.bwp_size)
    if start_rb < 0 then
        return mask, 0
    end

    local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame)

    m.allocated_rb = requested_rbs
    m.allocated_mcs = mcs
    m.allocated_rb_start = start_rb

    mask = mark_used(mask, start_rb, requested_rbs, m.bwp_start)
    return mask, requested_rbs
end

---------------------------------------------------------------------------
-- Main entry point called from C every DL slot
---------------------------------------------------------------------------
function compute_dl_allocations(metrics_ptr, n_ues, total_rbs, min_rbs, rb_mask_string)
    local metrics = ffi.cast("dl_ue_metric_t*", metrics_ptr)
    local mask = rb_mask_string

    -- Reset per-slot allocation outputs
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        m.allocated_rb = 0
        m.allocated_mcs = 10
        m.allocated_rb_start = 0
    end

    debug_counter = debug_counter + 1
    if debug_counter % 100 == 0 then
        for i = 0, n_ues - 1 do
            local m = metrics[i]
            local s = olla[m.rnti]
            local frac_str = s and string.format("%.2f", s.frac) or "N/A"
            print(string.format(
                "[DL %d.%d] UE uid=%d rnti=%04x class=%s pending=%d thr=%.0f mcs=%d olla_frac=%s bler=%.3f cqi=%d hol=%d us type=%d",
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
    -- Phase 2: Separate NEW DATA UEs by service class
    -----------------------------------------------------------------------
    local urllc_ues = {}
    local embb_ues  = {}

    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and m.pending_bytes > 0 then
            local class = get_service_class(m)

            if class == "URLLC" then
                local thr = (m.throughput > 0) and m.throughput or 1.0
                local hol = tonumber(m.hol_delay_us) or 0
                local priority = (hol + 1.0) / thr
                urllc_ues[#urllc_ues + 1] = { idx = i, priority = priority }
            else
                local thr = (m.throughput > 0) and m.throughput or 1.0
                local priority = (m.previous_mcs + 1.0) / thr
                embb_ues[#embb_ues + 1] = { idx = i, priority = priority }
            end
        end
    end

    table.sort(urllc_ues, function(a, b) return a.priority > b.priority end)
    table.sort(embb_ues,  function(a, b) return a.priority > b.priority end)

    -----------------------------------------------------------------------
    -- Phase 3: Fair class-level budget split
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
        urllc_budget = math.floor(free_now * 0.5)
        embb_budget  = free_now - urllc_budget

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
    -----------------------------------------------------------------------
    local used_urllc = 0
    for _, entry in ipairs(urllc_ues) do
        local m = metrics[entry.idx]
        local remain = urllc_budget - used_urllc
        if remain < min_rbs then
            break
        end

        local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
        local grant = math.min(req, remain)

        if grant < min_rbs and remain >= min_rbs then
            grant = min_rbs
        end

        local new_mask, got = allocate_to_ue(m, mask, grant, min_rbs)
        mask = new_mask
        used_urllc = used_urllc + got
    end

    -----------------------------------------------------------------------
    -- Phase 5: Allocate eMBB budget
    -----------------------------------------------------------------------
    local used_embb = 0
    for _, entry in ipairs(embb_ues) do
        local m = metrics[entry.idx]
        local remain = embb_budget - used_embb
        if remain < min_rbs then
            break
        end

        local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
        local grant = math.min(req, remain)

        if grant < min_rbs and remain >= min_rbs then
            grant = min_rbs
        end

        local new_mask, got = allocate_to_ue(m, mask, grant, min_rbs)
        mask = new_mask
        used_embb = used_embb + got
    end

    -----------------------------------------------------------------------
    -- Phase 6: Leftover RBs
    -- First unscheduled URLLC, then unscheduled eMBB
    -----------------------------------------------------------------------
    local leftover = count_free_rbs(mask, 0, total_rbs)

    if leftover >= min_rbs then
        for _, entry in ipairs(urllc_ues) do
            local m = metrics[entry.idx]
            if m.allocated_rb == 0 then
                local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
                local grant = math.min(req, leftover)
                if grant >= min_rbs then
                    local new_mask, got = allocate_to_ue(m, mask, grant, min_rbs)
                    mask = new_mask
                    leftover = leftover - got
                    if leftover < min_rbs then
                        break
                    end
                end
            end
        end
    end

    if leftover >= min_rbs then
        for _, entry in ipairs(embb_ues) do
            local m = metrics[entry.idx]
            if m.allocated_rb == 0 then
                local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
                local grant = math.min(req, leftover)
                if grant >= min_rbs then
                    local new_mask, got = allocate_to_ue(m, mask, grant, min_rbs)
                    mask = new_mask
                    leftover = leftover - got
                    if leftover < min_rbs then
                        break
                    end
                end
            end
        end
    end

    -----------------------------------------------------------------------
    -- Periodic debug print
    -----------------------------------------------------------------------
    if debug_counter % 100 == 0 then
        for i = 0, n_ues - 1 do
            local m = metrics[i]
            print(string.format(
                "[FAIR DL %d.%d] UE uid=%d rnti=%04x class=%s pending=%d thr=%.1f hol=%d alloc_rb=%d alloc_mcs=%d type=%d",
                m.frame, m.slot, m.uid, m.rnti, get_service_class(m),
                m.pending_bytes, m.throughput, tonumber(m.hol_delay_us),
                m.allocated_rb, m.allocated_mcs, m.ue_type))
        end
    end
end