-- Minimal DL PF Scheduler — no logging, no rate limiting.
-- Every slot: retx → new data (PF sorted, largest block).
-- Use for baseline testing: export LUA_SCHED=/path/to/pf_dl_simple.lua

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

local debug_counter = 0

function compute_dl_allocations(metrics_ptr, n_ues, total_rbs, min_rbs, rb_mask_string)
    print(string.format("Computing DL Allocations (Custom Scheduler)"))
    local metrics = ffi.cast("dl_ue_metric_t*", metrics_ptr)
    local mask = rb_mask_string

    debug_counter = debug_counter + 1
    if debug_counter % 100 == 0 then
        for i = 0, n_ues - 1 do
            local m = metrics[i]
            print(string.format("[DL %d.%d] UE %04x: pending=%d thr=%.0f mcs=%d bler=%.2f cqi=%d hol=%d us type=%d",
                m.frame, m.slot, m.rnti, m.pending_bytes, m.throughput,
                m.previous_mcs, m.bler, m.cqi, tonumber(m.hol_delay_us), m.ue_type))
        end
    end

    -- Phase 1: HARQ retransmissions (exact RBs, highest priority)
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

    -- Phase 2: New data UEs sorted by PF coefficient
    local pf = {}
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA then
            local thr = m.throughput > 0 and m.throughput or 1.0
            local coef = (m.previous_mcs + 1) / thr
            pf[#pf + 1] = { idx = i, coef = coef }
        end
    end
    table.sort(pf, function(a, b) return a.coef > b.coef end)

    for _, entry in ipairs(pf) do
        local m = metrics[entry.idx]
        local best_start, best_len = find_largest_block(mask, m.bwp_start, m.bwp_size)

        if best_len >= min_rbs then
            local mcs = math.min(m.previous_mcs, 27)
            m.allocated_rb = best_len
            m.allocated_mcs = mcs
            m.allocated_rb_start = best_start
            mask = mark_used(mask, best_start, best_len, m.bwp_start)
        end
    end
end
