-- DL eMBB/URLLC Coexistence Scheduler (v5) with RL-based OLLA parameter tuning.
-- v5 additions over v4:
--   * Q-table reinforcement learning agent that runs at the OLLA timescale
--     (every OLLA_PERIOD frames, ~50ms) to dynamically select OLLA step_up
--     and step_down parameters per traffic class.
--   * State: discretized (avg_bler_bucket, avg_mcs_bucket, pending_bucket)
--   * Action: select from a finite set of (step_up, step_down) tuples
--   * Reward: throughput delta - BLER penalty - pending_bytes penalty
--   * Pure Lua Q-learning with epsilon-greedy — no Python, fits in slot budget.
--   * All v4 features retained: ceiling tracking, puncturing compensation,
--     freq-selective URLLC, budget cap, deadline logging.
-- Use: export LUA_SCHED=/path/to/pf_dl_slice_aware_v5.lua

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

-- Default per-class OLLA parameters (overridden by RL agent)
local EMBB_BLER_TARGET  = 0.10
local EMBB_OLLA_UP      = 0.50
local EMBB_OLLA_DOWN    = 1.00

local URLLC_BLER_TARGET = 0.01
local URLLC_OLLA_UP     = 0.50
local URLLC_OLLA_DOWN   = 0.50

local EMBB_INIT_MCS  = 14
local URLLC_INIT_MCS = 9

---------------------------------------------------------------------------
-- CQI-to-MCS mapping
---------------------------------------------------------------------------
local CQI_TO_APPROX_MCS = {
    [0] = 0, [1] = 0, [2] = 2, [3] = 4, [4] = 6,
    [5] = 8, [6] = 10, [7] = 12, [8] = 14, [9] = 16,
    [10] = 18, [11] = 20, [12] = 22, [13] = 24, [14] = 26, [15] = 27
}
local EMBB_CQI_FLOOR_OFFSET  = 12
local URLLC_CQI_FLOOR_OFFSET = 6

local function frames_elapsed(now, last)
    return (now - last) % MAX_FRAME
end

---------------------------------------------------------------------------
-- MCS ceiling tracking (from v4)
---------------------------------------------------------------------------
local CEILING_BLER_MULT = 2.0
local CEILING_MARGIN    = 2
local CEILING_RELAX     = 0.2

---------------------------------------------------------------------------
-- Q-Table RL Agent for OLLA parameter tuning
---------------------------------------------------------------------------
-- Runs once per OLLA_PERIOD (~50ms). Selects (step_up, step_down) for
-- each traffic class from a discrete action set. Pure Lua, O(1) lookup.
---------------------------------------------------------------------------

-- Action set: each action is a (step_up, step_down) tuple
local RL_ACTIONS_EMBB = {
    { up = 0.25, down = 0.50 },   -- 1: conservative
    { up = 0.50, down = 0.75 },   -- 2: moderate-conservative
    { up = 0.50, down = 1.00 },   -- 3: default (v4 baseline)
    { up = 0.75, down = 1.00 },   -- 4: moderate-aggressive up
    { up = 0.75, down = 1.50 },   -- 5: aggressive both
}

local RL_ACTIONS_URLLC = {
    { up = 0.25, down = 0.50 },   -- 1: very conservative
    { up = 0.50, down = 0.50 },   -- 2: default (v4 baseline)
    { up = 0.50, down = 1.00 },   -- 3: aggressive down
    { up = 0.25, down = 1.00 },   -- 4: slow up, aggressive down
}

-- State discretization buckets
local function discretize_bler(bler)
    if bler < 0.01 then return 1 end      -- very low
    if bler < 0.05 then return 2 end      -- low
    if bler < 0.10 then return 3 end      -- near target
    if bler < 0.20 then return 4 end      -- above target
    return 5                               -- high
end

local function discretize_mcs(mcs)
    if mcs < 8 then return 1 end           -- low
    if mcs < 16 then return 2 end          -- medium
    if mcs < 22 then return 3 end          -- high
    return 4                               -- very high
end

local function discretize_pending(pending_bytes)
    if pending_bytes < 10000 then return 1 end      -- empty/low
    if pending_bytes < 500000 then return 2 end     -- moderate
    if pending_bytes < 2000000 then return 3 end    -- high
    return 4                                         -- very high / backlogged
end

-- Q-tables: Q[state_key] = { [action_idx] = q_value }
local q_embb  = {}
local q_urllc = {}

-- RL hyperparameters
local RL_ALPHA   = 0.10    -- learning rate
local RL_GAMMA   = 0.90    -- discount factor
local RL_EPSILON = 0.15    -- exploration rate (epsilon-greedy)
local RL_EPSILON_DECAY = 0.9999  -- per-decision decay
local RL_EPSILON_MIN   = 0.02

-- RL state: track previous state/action/reward-components per class
local rl_state = {
    embb = {
        prev_state_key = nil,
        prev_action = nil,
        prev_thr = 0,
        prev_bler = 0,
        prev_pending = 0,
        decision_frame = -100,
    },
    urllc = {
        prev_state_key = nil,
        prev_action = nil,
        prev_thr = 0,
        prev_bler = 0,
        prev_hol = 0,
        decision_frame = -100,
    },
}

-- Active OLLA parameters (set by RL agent, consumed by olla_mcs)
local active_embb_up   = EMBB_OLLA_UP
local active_embb_down = EMBB_OLLA_DOWN
local active_urllc_up   = URLLC_OLLA_UP
local active_urllc_down = URLLC_OLLA_DOWN

local function make_state_key(bler_bucket, mcs_bucket, pending_bucket)
    return bler_bucket * 100 + mcs_bucket * 10 + pending_bucket
end

local function get_q(qtable, state_key, n_actions)
    if not qtable[state_key] then
        qtable[state_key] = {}
        for a = 1, n_actions do
            qtable[state_key][a] = 0.0
        end
    end
    return qtable[state_key]
end

local function select_action(qtable, state_key, n_actions)
    -- Epsilon-greedy
    if math.random() < RL_EPSILON then
        return math.random(1, n_actions)
    end
    -- Greedy: pick action with highest Q
    local qvals = get_q(qtable, state_key, n_actions)
    local best_a, best_q = 1, qvals[1]
    for a = 2, n_actions do
        if qvals[a] > best_q then
            best_a = a
            best_q = qvals[a]
        end
    end
    return best_a
end

local function update_q(qtable, state_key, action, reward, next_state_key, n_actions)
    local qvals = get_q(qtable, state_key, n_actions)
    local next_qvals = get_q(qtable, next_state_key, n_actions)
    -- Find max Q for next state
    local max_next_q = next_qvals[1]
    for a = 2, n_actions do
        if next_qvals[a] > max_next_q then
            max_next_q = next_qvals[a]
        end
    end
    -- Q-learning update
    qvals[action] = qvals[action] + RL_ALPHA * (reward + RL_GAMMA * max_next_q - qvals[action])
end

-- Reward functions
local function embb_reward(thr, prev_thr, bler, pending)
    -- Throughput improvement (normalized)
    local thr_delta = 0
    if prev_thr > 0 then
        thr_delta = (thr - prev_thr) / prev_thr  -- fractional change
    end
    -- BLER penalty: exponential above target
    local bler_penalty = 0
    if bler > EMBB_BLER_TARGET then
        bler_penalty = (bler - EMBB_BLER_TARGET) * 10.0
    end
    -- Pending bytes penalty (backlog)
    local pending_penalty = 0
    if pending > 1000000 then
        pending_penalty = math.log(pending / 1000000) * 0.5
    end
    return thr_delta - bler_penalty - pending_penalty
end

local function urllc_reward(thr, prev_thr, bler, hol_us)
    -- BLER is critical for URLLC
    local bler_penalty = 0
    if bler > URLLC_BLER_TARGET then
        bler_penalty = (bler - URLLC_BLER_TARGET) * 100.0  -- heavy penalty
    end
    -- HOL delay penalty
    local hol_penalty = 0
    if hol_us > 2000 then  -- > 2ms
        hol_penalty = (hol_us - 2000) / 1000.0
    end
    -- Small throughput bonus
    local thr_bonus = 0
    if prev_thr > 0 then
        thr_bonus = (thr - prev_thr) / prev_thr * 0.1
    end
    return thr_bonus - bler_penalty - hol_penalty
end

-- Main RL decision function: called once per OLLA_PERIOD
-- Aggregates metrics across UEs of each class, updates Q-tables,
-- selects new OLLA parameters.
local function rl_decide(metrics, n_ues, frame)
    -- Aggregate per-class metrics
    local embb_thr, embb_bler, embb_mcs, embb_pending, embb_count = 0, 0, 0, 0, 0
    local urllc_thr, urllc_bler, urllc_mcs, urllc_hol, urllc_count = 0, 0, 0, 0, 0

    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if is_urllc(m.fiveQI) then
            urllc_thr = urllc_thr + m.throughput
            urllc_bler = urllc_bler + m.bler
            urllc_mcs = urllc_mcs + m.previous_mcs
            urllc_hol = urllc_hol + tonumber(m.hol_delay_us)
            urllc_count = urllc_count + 1
        else
            embb_thr = embb_thr + m.throughput
            embb_bler = embb_bler + m.bler
            embb_mcs = embb_mcs + m.previous_mcs
            embb_pending = embb_pending + m.pending_bytes
            embb_count = embb_count + 1
        end
    end

    -- eMBB RL decision
    if embb_count > 0 then
        local avg_bler = embb_bler / embb_count
        local avg_mcs = embb_mcs / embb_count
        local avg_thr = embb_thr / embb_count
        local total_pending = embb_pending

        local state_key = make_state_key(
            discretize_bler(avg_bler),
            discretize_mcs(avg_mcs),
            discretize_pending(total_pending)
        )

        -- Update Q-table with reward from previous action
        local rs = rl_state.embb
        if rs.prev_state_key then
            local reward = embb_reward(avg_thr, rs.prev_thr, avg_bler, total_pending)
            update_q(q_embb, rs.prev_state_key, rs.prev_action, reward, state_key, #RL_ACTIONS_EMBB)
        end

        -- Select new action
        local action = select_action(q_embb, state_key, #RL_ACTIONS_EMBB)
        active_embb_up   = RL_ACTIONS_EMBB[action].up
        active_embb_down = RL_ACTIONS_EMBB[action].down

        -- Save state for next update
        rs.prev_state_key = state_key
        rs.prev_action = action
        rs.prev_thr = avg_thr
        rs.prev_bler = avg_bler
        rs.prev_pending = total_pending
        rs.decision_frame = frame
    end

    -- URLLC RL decision
    if urllc_count > 0 then
        local avg_bler = urllc_bler / urllc_count
        local avg_mcs = urllc_mcs / urllc_count
        local avg_thr = urllc_thr / urllc_count
        local avg_hol = urllc_hol / urllc_count

        local state_key = make_state_key(
            discretize_bler(avg_bler),
            discretize_mcs(avg_mcs),
            1  -- URLLC doesn't use pending bucket; always 1
        )

        local rs = rl_state.urllc
        if rs.prev_state_key then
            local reward = urllc_reward(avg_thr, rs.prev_thr, avg_bler, avg_hol)
            update_q(q_urllc, rs.prev_state_key, rs.prev_action, reward, state_key, #RL_ACTIONS_URLLC)
        end

        local action = select_action(q_urllc, state_key, #RL_ACTIONS_URLLC)
        active_urllc_up   = RL_ACTIONS_URLLC[action].up
        active_urllc_down = RL_ACTIONS_URLLC[action].down

        rs.prev_state_key = state_key
        rs.prev_action = action
        rs.prev_thr = avg_thr
        rs.prev_bler = avg_bler
        rs.prev_hol = avg_hol
        rs.decision_frame = frame
    end

    -- Decay epsilon
    RL_EPSILON = math.max(RL_EPSILON_MIN, RL_EPSILON * RL_EPSILON_DECAY)
end

---------------------------------------------------------------------------
-- OLLA MCS selection (with ceiling tracking from v4, RL-tuned step sizes)
---------------------------------------------------------------------------
local function olla_mcs(rnti, seed_mcs, bler, mcs_table, frame, urllc, cqi)
    local max_mcs = 27
    local s = olla[rnti]

    if not s then
        local default_mcs = urllc and URLLC_INIT_MCS or EMBB_INIT_MCS
        local init = seed_mcs > 0 and seed_mcs or default_mcs
        s = { frac = init + 0.0, last_frame = frame, ceiling = max_mcs + 0.0 }
        olla[rnti] = s
    end

    -- Use RL-tuned parameters instead of static constants
    local bler_target = urllc and URLLC_BLER_TARGET or EMBB_BLER_TARGET
    local step_up     = urllc and active_urllc_up   or active_embb_up
    local step_down   = urllc and active_urllc_down or active_embb_down

    -- CQI-derived MCS floor
    local cqi_val = (cqi and cqi >= 0 and cqi <= 15) and cqi or 0
    local cqi_mcs = CQI_TO_APPROX_MCS[cqi_val] or 0
    local floor_offset = urllc and URLLC_CQI_FLOOR_OFFSET or EMBB_CQI_FLOOR_OFFSET
    local cqi_floor = math.max(MIN_MCS, cqi_mcs - floor_offset)

    -- Effective ceiling
    local effective_cap = math.min(max_mcs, s.ceiling - CEILING_MARGIN)
    effective_cap = math.max(cqi_floor, effective_cap)

    -- One adjustment per OLLA_PERIOD frames
    if frames_elapsed(frame, s.last_frame) >= OLLA_PERIOD then
        if bler < bler_target then
            local deficit = cqi_mcs - s.frac
            local accel = 1.0
            if deficit > 10 then
                accel = 1.5
            elseif deficit > 5 then
                accel = 1.25
            end

            -- Taper near ceiling
            local headroom = effective_cap - s.frac
            if headroom < 3.0 and headroom > 0 then
                accel = accel * (headroom / 3.0)
            end

            s.frac = s.frac + step_up * accel

            -- Relax ceiling
            if s.ceiling < max_mcs then
                s.ceiling = math.min(max_mcs, s.ceiling + CEILING_RELAX)
            end
        else
            local excess_ratio = bler / math.max(bler_target, 0.001)
            local down_scale = math.min(excess_ratio - 1.0, 2.0)
            down_scale = math.max(0.5, down_scale)
            s.frac = s.frac - step_down * down_scale

            -- Record ceiling on severe BLER overshoot
            if excess_ratio >= CEILING_BLER_MULT then
                local new_ceil = s.frac + step_down * down_scale
                s.ceiling = math.min(s.ceiling, new_ceil)
            end
        end
        s.last_frame = frame
    end

    -- Clamp
    s.frac = math.max(cqi_floor, math.min(s.frac, effective_cap))

    return math.floor(s.frac)
end

---------------------------------------------------------------------------
-- RB mask helpers (identical to v4)
---------------------------------------------------------------------------

local function find_free_rbs(mask, needed, bwp_start, bwp_size)
    local count = 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1
        if mask:sub(idx, idx) ~= 'X' then
            count = count + 1
            if count == needed then
                return rb - needed + 1
            end
        else
            count = 0
        end
    end
    return -1
end

local function mark_used(mask, start_rb, num_rbs, bwp_start)
    local chars = {}
    for i = 1, #mask do chars[i] = mask:sub(i, i) end
    for rb = start_rb, start_rb + num_rbs - 1 do
        chars[bwp_start + rb + 1] = 'X'
    end
    return table.concat(chars)
end

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

local function find_best_channel_rbs(mask, needed, bwp_start, bwp_size, channel_mag)
    local best_start = -1
    local best_avg   = -1
    local has_nonzero = false

    local cur_start, cur_len = -1, 0
    for rb = 0, bwp_size - 1 do
        local idx = bwp_start + rb + 1
        if mask:sub(idx, idx) ~= 'X' then
            if cur_len == 0 then cur_start = rb end
            cur_len = cur_len + 1
        else
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
            cur_len = 0
        end
    end
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

    if not has_nonzero and best_start >= 0 then
        return find_smallest_free(mask, needed, bwp_start, bwp_size)
    end

    return best_start
end

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
-- URLLC budget cap
---------------------------------------------------------------------------
local URLLC_RB_BUDGET_FRAC = 0.30

---------------------------------------------------------------------------
-- URLLC deadline
---------------------------------------------------------------------------
local URLLC_DEADLINE_US = 2000
local URLLC_DEADLINE_LOG_INTERVAL = 100

---------------------------------------------------------------------------
-- Puncturing compensation state (per RNTI)
---------------------------------------------------------------------------
local puncture_rho = {}
local deadline_warn_count = {}
local RHO_EMA_ALPHA = 0.05
local RHO_FLOOR     = 0.001

---------------------------------------------------------------------------
-- Debug logging + RL diagnostics
---------------------------------------------------------------------------
local debug_counter = 0
local rl_log_counter = 0

---------------------------------------------------------------------------
-- RL decision tracking: frame of last RL decision
---------------------------------------------------------------------------
local last_rl_frame = -100

---------------------------------------------------------------------------
-- Main entry point called from C every DL slot
---------------------------------------------------------------------------
function compute_dl_allocations(metrics_ptr, n_ues, total_rbs, min_rbs, rb_mask_string)
    local metrics = ffi.cast("dl_ue_metric_t*", metrics_ptr)
    local mask = rb_mask_string
    local frame = n_ues > 0 and metrics[0].frame or 0

    -- Run RL agent at OLLA timescale (every OLLA_PERIOD frames)
    if frames_elapsed(frame, last_rl_frame) >= OLLA_PERIOD then
        rl_decide(metrics, n_ues, frame)
        last_rl_frame = frame
    end

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
        -- RL diagnostics
        rl_log_counter = rl_log_counter + 1
        if rl_log_counter % 5 == 0 then
            local rs_e = rl_state.embb
            local rs_u = rl_state.urllc
            print(string.format(
                "[RL %d] eMBB action=%s up=%.2f down=%.2f | URLLC action=%s up=%.2f down=%.2f | eps=%.3f | Q_embb_states=%d Q_urllc_states=%d",
                frame,
                rs_e.prev_action and tostring(rs_e.prev_action) or "-",
                active_embb_up, active_embb_down,
                rs_u.prev_action and tostring(rs_u.prev_action) or "-",
                active_urllc_up, active_urllc_down,
                RL_EPSILON,
                (function() local c = 0; for _ in pairs(q_embb) do c = c + 1 end; return c end)(),
                (function() local c = 0; for _ in pairs(q_urllc) do c = c + 1 end; return c end)()
            ))
        end
    end

    -- Phase 1: HARQ retransmissions
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

    -- Phase 2: URLLC new data (strict priority, freq-selective, budget-capped)
    local urllc_ues = {}
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and is_urllc(m.fiveQI) then
            urllc_ues[#urllc_ues + 1] = { idx = i, hol = tonumber(m.hol_delay_us) }
        end
    end
    table.sort(urllc_ues, function(a, b) return a.hol > b.hol end)

    local free_before_urllc = count_free_rbs(mask, 0, #mask)
    local urllc_rb_budget = math.floor(free_before_urllc * URLLC_RB_BUDGET_FRAC)
    local urllc_rbs_used = 0

    for _, entry in ipairs(urllc_ues) do
        local m = metrics[entry.idx]
        local needed = m.required_rbs > 0 and m.required_rbs or min_rbs

        if urllc_rbs_used + needed > urllc_rb_budget then
            break
        end

        local s = find_best_channel_rbs(mask, needed, m.bwp_start, m.bwp_size, m.channel_mag_per_rb)
        if s >= 0 then
            local mcs = olla_mcs(m.rnti, m.previous_mcs, m.bler, m.mcs_table, m.frame, true, m.cqi)
            m.allocated_rb = needed
            m.allocated_mcs = mcs
            m.allocated_rb_start = s
            mask = mark_used(mask, s, needed, m.bwp_start)
            urllc_rbs_used = urllc_rbs_used + needed
        end

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

    -- Update puncturing rho for eMBB UEs
    local slot_puncture_frac = total_rbs > 0 and (urllc_rbs_used / total_rbs) or 0.0
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if not is_urllc(m.fiveQI) then
            local old_rho = puncture_rho[m.rnti] or 0.0
            puncture_rho[m.rnti] = old_rho + RHO_EMA_ALPHA * (slot_puncture_frac - old_rho)
        end
    end

    -- Phase 3: eMBB new data (compensated PF)
    local pf = {}
    for i = 0, n_ues - 1 do
        local m = metrics[i]
        if m.ue_type == UE_TYPE_NEW_DATA and not is_urllc(m.fiveQI) then
            local thr = m.throughput > 0 and m.throughput or 1.0
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
