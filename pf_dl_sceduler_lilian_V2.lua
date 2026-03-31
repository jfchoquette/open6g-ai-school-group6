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

    -- Nominal class shares when both are active
    local URLLC_MIN_SHARE = 0.60
    local EMBB_MIN_SHARE  = 0.25

    -----------------------------------------------------------------------
    -- Local helpers
    -----------------------------------------------------------------------
    local function get_service_class(FiveQI)
        -- Requested mapping:
        local qi = tonumber(FiveQI)
        if qi == 69
            return "URLLC"
        else
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

        -- First try exact requested size limited by budget
        local req = (m.required_rbs > 0) and m.required_rbs or min_rbs
        local target = math.min(req, max_budget)

        if target >= min_rbs then
            local new_mask, got = allocate_to_ue(m, mask_str, target)
            if got > 0 then
                return new_mask, got
            end
        end

        -- Fallback: allocate the largest feasible contiguous block
        return allocate_best_contiguous_block(m, mask_str, max_budget)
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
    --
    -- URLLC:
    --   prioritize users below 80 Mbps target
    --   plus HOL urgency
    --
    -- eMBB:
    --   prioritize users approaching / exceeding 50 ms HOL target
    --   with a PF-like term normalized using Mbps
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
    -- Phase 3: QoS-aware class budget split
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
        urllc_budget = math.floor(free_now * URLLC_MIN_SHARE)
        embb_budget  = math.floor(free_now * EMBB_MIN_SHARE)

        local assigned = urllc_budget + embb_budget
        if assigned > free_now then
            embb_budget = math.max(min_rbs, free_now - urllc_budget)
        elseif assigned < free_now then
            urllc_budget = urllc_budget + (free_now - assigned)
        end

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
    --
    -- No top-up for already-scheduled UEs in this version.
    -----------------------------------------------------------------------
    local leftover = count_free_rbs(mask, 0, total_rbs)

    if leftover >= min_rbs then
        -- 1) Unscheduled URLLC below throughput target
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
        -- 2) Unscheduled eMBB violating latency target
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
        -- 3) Remaining unscheduled URLLC
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
        -- 4) Remaining unscheduled eMBB
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