-- DL eMBB/URLLC Coexistence Scheduler (v4) with per-class OLLA MCS adaptation.
-- v4 additions over v3:
--   * Puncturing-aware PF compensation for eMBB (Karimi et al.):
--     Tracks per-RNTI rho_i = fraction of BWP stolen by URLLC.
--     Modified PF coefficient: coef = r_i / (T_i * (1 - rho_i))
--     so eMBB UEs that lose the most RBs to URLLC get priority boost.
--   * rho_i uses EMA decay (alpha=0.05) across slots for smooth tracking.
--   * OLLA MCS ceiling tracking to prevent sawtooth oscillation:
--     When BLER exceeds 2× target, records olla_frac as mcs_ceiling.
--     Future ramp-ups capped at (ceiling - margin). Ceiling relaxes slowly
--     when BLER is good, allowing cautious re-exploration.
--     Acceleration factor capped at 1.5x (was 3x).
-- Retained from v3: freq-selective URLLC, budget cap, deadline logging, per-class OLLA.
-- Every slot: retx → URLLC new data (best-channel fit) → eMBB new data (compensated PF, largest block).
-- Traffic class determined by fiveQI (3GPP TS 23.501 Table 5.7.4-1).
-- Use: export LUA_SCHED=/path/to/pf_dl_slice_aware_v4.lua

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
-- Traffic classification via 5QI
---------------------------------------------------------------------------
local function is_urllc(fiveQI)
    local qi = tonumber(fiveQI)
    return qi == 69
end

---------------------------------------------------------------------------
-- OLLA state per RNTI
---------------------------------------------------------------------------
local olla = {}

local MAX_FRAME    = 1024   -- NR frame counter wraps at 1024
local OLLA_PERIOD  = 5      -- adjust every 5 frames (50ms)
local MIN_MCS      = 0

-- Per-class OLLA parameters
local EMBB_BLER_TARGET  = 0.10
local EMBB_OLLA_UP      = 0.50
local EMBB_OLLA_DOWN    = 1.00

local URLLC_BLER_TARGET = 0.01
local URLLC_OLLA_UP     = 0.50
local URLLC_OLLA_DOWN   = 0.50

local EMBB_INIT_MCS  = 14
local URLLC_INIT_MCS = 9

---------------------------------------------------------------------------
-- CQI-to-MCS floor: prevents OLLA death spiral when channel is good.
-- Approximate CQI-to-MCS mapping (Table 1, 64QAM) used as reference.
-- Floor = CQI_MCS - offset, so OLLA never drops absurdly below what
-- the channel can clearly support.
---------------------------------------------------------------------------
local CQI_TO_APPROX_MCS = {
    [0] = 0, [1] = 0, [2] = 2, [3] = 4, [4] = 6,
    [5] = 8, [6] = 10, [7] = 12, [8] = 14, [9] = 16,
    [10] = 18, [11] = 20, [12] = 22, [13] = 24, [14] = 26, [15] = 27
}
local EMBB_CQI_FLOOR_OFFSET  = 12    -- eMBB: floor = CQI_MCS - 12
local URLLC_CQI_FLOOR_OFFSET = 6     -- URLLC: tighter floor

local function frames_elapsed(now, last)
    return (now - last) % MAX_FRAME
end

---------------------------------------------------------------------------
-- MCS ceiling tracking: prevents repeated overshoot to unsustainable MCS.
-- When BLER exceeds CEILING_BLER_MULT × target, record current olla_frac
-- as a ceiling.  Ramp-ups are then capped at (ceiling - CEILING_MARGIN).
-- The ceiling relaxes upward slowly when BLER is good, allowing cautious
-- re-exploration of higher MCS values.
---------------------------------------------------------------------------
local CEILING_BLER_MULT = 2.0   -- trigger ceiling when BLER > 2× target
local CEILING_MARGIN    = 2     -- stay this many MCS below the last failure
local CEILING_RELAX     = 0.2   -- relax ceiling by this much per OLLA period when BLER is good

local function olla_mcs(rnti, seed_mcs, bler, mcs_table, frame, urllc, cqi)
    local max_mcs = 27
    local s = olla[rnti]

    if not s then
        local default_mcs = urllc and URLLC_INIT_MCS or EMBB_INIT_MCS
        local init = seed_mcs > 0 and seed_mcs or default_mcs
        s = { frac = init + 0.0, last_frame = frame, ceiling = max_mcs + 0.0 }
        olla[rnti] = s
    end

    -- Select OLLA parameters based on traffic class
    local bler_target = urllc and URLLC_BLER_TARGET or EMBB_BLER_TARGET
    local step_up     = urllc and URLLC_OLLA_UP     or EMBB_OLLA_UP
    local step_down   = urllc and URLLC_OLLA_DOWN   or EMBB_OLLA_DOWN

    -- CQI-derived MCS floor: prevents death spiral when channel is good
    local cqi_val = (cqi and cqi >= 0 and cqi <= 15) and cqi or 0
    local cqi_mcs = CQI_TO_APPROX_MCS[cqi_val] or 0
    local floor_offset = urllc and URLLC_CQI_FLOOR_OFFSET or EMBB_CQI_FLOOR_OFFSET
    local cqi_floor = math.max(MIN_MCS, cqi_mcs - floor_offset)

    -- Effective ceiling: never ramp above (ceiling - margin)
    local effective_cap = math.min(max_mcs, s.ceiling - CEILING_MARGIN)
    effective_cap = math.max(cqi_floor, effective_cap)  -- ceiling can't be below floor

    -- One adjustment per OLLA_PERIOD frames
    if frames_elapsed(frame, s.last_frame) >= OLLA_PERIOD then
        if bler < bler_target then
            -- MCS is below ceiling: ramp up with moderate acceleration
            local deficit = cqi_mcs - s.frac
            local accel = 1.0
            if deficit > 10 then
                accel = 1.5   -- was 3.0 — reduced to prevent overshoot
            elseif deficit > 5 then
                accel = 1.25   -- was 2.0
            end

            -- Slow down as we approach the ceiling
            local headroom = effective_cap - s.frac
            if headroom < 3.0 and headroom > 0 then
                accel = accel * (headroom / 3.0)  -- linear taper
            end

            s.frac = s.frac + step_up * accel

            -- Also relax the ceiling upward when BLER is good
            if s.ceiling < max_mcs then
                s.ceiling = math.min(max_mcs, s.ceiling + CEILING_RELAX)
            end
        else
            -- Proportional down-step: mild BLER excess = mild penalty
            local excess_ratio = bler / math.max(bler_target, 0.001)
            local down_scale = math.min(excess_ratio - 1.0, 2.0)
            down_scale = math.max(0.5, down_scale)
            s.frac = s.frac - step_down * down_scale

            -- If BLER is way above target, record a ceiling
            if excess_ratio >= CEILING_BLER_MULT then
                -- Set ceiling to current frac (which is already being reduced)
                -- Use the higher of current frac and new ceiling to avoid
                -- ratcheting down too aggressively from a single bad period
                local new_ceil = s.frac + step_down * down_scale  -- pre-reduction value
                s.ceiling = math.min(s.ceiling, new_ceil)
            end
        end
        s.last_frame = frame
    end

    -- Clamp: never below CQI floor, never above effective ceiling
    s.frac = math.max(cqi_floor, math.min(s.frac, effective_cap))

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

-- Find smallest contiguous free block that fits >= needed RBs (best-fit)
-- Preserves large contiguous regions for eMBB
local function find_smallest_free(mask, needed, bwp_start, bwp_size)
    local best_start, best_len = -1, bwp_size + 1
    local cur_start, cur_len = -1, 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1
        if mask:sub(idx, idx) ~= 'X' then
            if cur_len == 0 then cur_start = rb end
            cur_len = cur_len + 1
        else
            if cur_len >= needed and cur_len < best_len then
                best_start = cur_start
                best_len = cur_len
            end
            cur_len = 0
        end
    end
    if cur_len >= needed and cur_len < best_len then
        best_start = cur_start
        best_len = cur_len
    end
    return best_start
end

-- Find the contiguous free block of exactly `needed` RBs with highest
-- average channel magnitude for a given UE. Uses channel_mag_per_rb[].
-- Falls back to smallest-fit if channel_mag data is all zeros.
local function find_best_channel_rbs(mask, needed, bwp_start, bwp_size, channel_mag)
    local best_start = -1
    local best_avg   = -1
    local has_nonzero = false

    -- Collect all free contiguous blocks >= needed
    local cur_start, cur_len = -1, 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1
        if mask:sub(idx, idx) ~= 'X' then
            if cur_len == 0 then cur_start = rb end
            cur_len = cur_len + 1
        else
            if cur_len >= needed then
                -- Evaluate every `needed`-wide window within this block
                for w = cur_start, cur_start + cur_len - needed do
                    local sum = 0
                    for r = w, w + needed - 1 do
                        local mag = channel_mag[r]
                        sum = sum + mag
                        if mag ~= 0 then has_nonzero = true end
                    end
                    local avg = sum / needed
                    if avg > best_avg then
                        best_avg = avg
                        best_start = w
                    end
                end
            end
            cur_len = 0
        end
    end
    -- Handle trailing free block at end of BWP
    if cur_len >= needed then
        for w = cur_start, cur_start + cur_len - needed do
            local sum = 0
            for r = w, w + needed - 1 do
                local mag = channel_mag[r]
                sum = sum + mag
                if mag ~= 0 then has_nonzero = true end
            end
            local avg = sum / needed
            if avg > best_avg then
                best_avg = avg
                best_start = w
            end
        end
    end

    -- Fallback: if channel data is all zeros, use smallest-fit instead
    if not has_nonzero and best_start >= 0 then
        return find_smallest_free(mask, needed, bwp_start, bwp_size)
    end

    return best_start
end

-- Count total free RBs in mask
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
-- URLLC budget cap: max fraction of free RBs URLLC can consume per slot
---------------------------------------------------------------------------
local URLLC_RB_BUDGET_FRAC = 0.30

---------------------------------------------------------------------------
-- URLLC deadline threshold for violation logging (microseconds)
---------------------------------------------------------------------------
local URLLC_DEADLINE_US = 2000  -- 2 ms
local URLLC_DEADLINE_LOG_INTERVAL = 100  -- print every Nth violation

---------------------------------------------------------------------------
-- Puncturing compensation state (per RNTI)
-- rho_i = exponential moving average of (URLLC_rbs_this_slot / bwp_size)
-- Used to boost PF priority of eMBB UEs that lose RBs to URLLC.
---------------------------------------------------------------------------
local puncture_rho = {}           -- [rnti] = rho  (0.0 .. 1.0)
local deadline_warn_count = {}    -- [rnti] = count of deadline violations
local RHO_EMA_ALPHA = 0.05        -- EMA smoothing: higher = faster tracking
local RHO_FLOOR     = 0.001       -- clamp (1 - rho) away from zero

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

    debug_counter = debug_counter + 1
    if debug_counter % 100 == 0 then
        for i = 0, n_ues - 1 do
            local m = metrics[i]
            local s = olla[m.rnti]
            local frac_str = s and string.format("%.2f", s.frac) or "N/A"
            local ceil_str = s and string.format("%.1f", s.ceiling) or "N/A"
            local class = is_urllc(m.fiveQI) and "URLLC" or "eMBB"
            local rho = puncture_rho[m.rnti] or 0.0
            print(string.format(
                "[DL %d.%d] UE %04x [%s 5QI=%d]: pending=%d thr=%.0f mcs=%d olla_frac=%s ceil=%s bler=%.3f cqi=%d hol=%d us rho=%.3f type=%d",
                m.frame, m.slot, m.rnti, class, tonumber(m.fiveQI),
                m.pending_bytes, m.throughput,
                m.previous_mcs, frac_str, ceil_str, m.bler, m.cqi,
                tonumber(m.hol_delay_us), rho, m.ue_type))
        end
    end

    -- Phase 1: HARQ retransmissions (exact RBs, highest priority, original MCS)
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

    -- Phase 2: URLLC new data (strict priority, smallest-fit, budget-capped)
    local urllc_ues = {}
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and is_urllc(m.fiveQI) then
            urllc_ues[#urllc_ues + 1] = { idx = i, hol = tonumber(m.hol_delay_us) }
        end
    end
    -- Sort by HOL delay descending (most urgent first)
    table.sort(urllc_ues, function(a, b) return a.hol > b.hol end)

    -- Budget cap: URLLC may use at most URLLC_RB_BUDGET_FRAC of currently free RBs
    local free_before_urllc = count_free_rbs(mask, 0, #mask)
    local urllc_rb_budget = math.floor(free_before_urllc * URLLC_RB_BUDGET_FRAC)
    local urllc_rbs_used = 0

    for _, entry in ipairs(urllc_ues) do
        local m = metrics[entry.idx]
        local needed = m.required_rbs > 0 and m.required_rbs or min_rbs

        -- Respect budget cap
        if urllc_rbs_used + needed > urllc_rb_budget then
            break
        end

        -- Frequency-selective: pick the `needed` contiguous RBs with best channel
        local s = find_best_channel_rbs(mask, needed, m.bwp_start, m.bwp_size, m.channel_mag_per_rb)
        if s >= 0 then
            local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame, true, m.cqi)
            m.allocated_rb = needed
            m.allocated_mcs = mcs
            m.allocated_rb_start = s
            mask = mark_used(mask, s, needed, m.bwp_start)
            urllc_rbs_used = urllc_rbs_used + needed
        end

        -- Log deadline violations (rate-limited)
        if entry.hol > URLLC_DEADLINE_US then
            local rnti = m.rnti
            deadline_warn_count[rnti] = (deadline_warn_count[rnti] or 0) + 1
            if deadline_warn_count[rnti] % URLLC_DEADLINE_LOG_INTERVAL == 0 then
                print(string.format(
                    "[DL %d.%d] URLLC DEADLINE WARNING: UE %04x hol=%d us > %d us [#%d]",
                    m.frame, m.slot, rnti, entry.hol, URLLC_DEADLINE_US,
                    deadline_warn_count[rnti]))
            end
        end
    end

    -- Update puncturing rho for all eMBB UEs this slot
    -- rho_new = EMA of (urllc_rbs_used / total_rbs)
    local slot_puncture_frac = total_rbs > 0 and (urllc_rbs_used / total_rbs) or 0.0
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if not is_urllc(m.fiveQI) then
            local old_rho = puncture_rho[m.rnti] or 0.0
            puncture_rho[m.rnti] = old_rho + RHO_EMA_ALPHA * (slot_puncture_frac - old_rho)
        end
    end

    -- Phase 3: eMBB new data sorted by compensated PF coefficient
    local pf = {}
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and not is_urllc(m.fiveQI) then
            local thr = m.throughput > 0 and m.throughput or 1.0
            -- Compensated PF: boost priority for UEs that lost RBs to URLLC
            local rho = puncture_rho[m.rnti] or 0.0
            local compensation = math.max(RHO_FLOOR, 1.0 - rho)
            local coef = (m.previous_mcs + 1) / (thr * compensation)
            pf[#pf + 1] = { idx = i, coef = coef }
        end
    end
    table.sort(pf, function(a, b) return a.coef > b.coef end)

    for _, entry in ipairs(pf) do
        local m = metrics[entry.idx]
        local best_start, best_len = find_largest_block(mask, m.bwp_start, m.bwp_size)

        if best_len >= min_rbs then
            local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame, false, m.cqi)
            m.allocated_rb = best_len
            m.allocated_mcs = mcs
            m.allocated_rb_start = best_start
            mask = mark_used(mask, best_start, best_len, m.bwp_start)
        end
    end
end