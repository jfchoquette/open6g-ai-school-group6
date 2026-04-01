function compute_dl_allocations(metrics_ptr, n_ues, total_rbs, min_rbs, rb_mask_string)
    local metrics = ffi.cast("dl_ue_metric_t*", metrics_ptr)
    local mask = rb_mask_string

    -----------------------------------------------------------------------
    -- QoS configuration
    -----------------------------------------------------------------------
    local EMBB_LATENCY_WARNING_US = 30000    -- start boosting eMBB priority
    local EMBB_LATENCY_TARGET_US  = 50000    -- 50 ms target
    local URLLC_TARGET_THR_BPS    = 80e6     -- 80 Mbps, throughput is in bits/s

    -----------------------------------------------------------------------
    -- Local helpers
    -----------------------------------------------------------------------
    local function get_service_class(m)
        -- 5QI-based classification:
        -- 69 -> URLLC
        -- otherwise -> eMBB
        if tonumber(m.fiveQI) == 69 then
            return "URLLC"
        else
            return "eMBB"
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
        -- Try exact requested size first.
        -- If not possible, try smaller contiguous blocks down to min_rbs.
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
        -- Allocate one contiguous block, up to max_budget.
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
            print(string.format(
                "[DL %d.%d] UE uid=%d rnti=%04x fiveQI=%d class=%s pending=%d thr=%.0f bps mcs=%d olla_frac=%s bler=%.3f hol=%d us type=%d",
                m.frame, m.slot, m.uid, m.rnti, tonumber(m.fiveQI), get_service_class(m),
                m.pending_bytes, m.throughput, m.previous_mcs, frac_str,
                m.bler, tonumber(m.hol_delay_us), m.ue_type))
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
    -- Phase 2: Build candidate lists
    --
    -- eMBB:
    --   low-rate latency-sensitive traffic
    --   priority rises only when HOL delay grows
    --
    -- URLLC:
    --   throughput-sensitive traffic
    --   priority rises when throughput is below target
    -----------------------------------------------------------------------
    local urllc_ues = {}
    local embb_ues  = {}

    for i = 0, n_ues - 1 do
        local m = metrics[i]

        if m.ue_type == UE_TYPE_NEW_DATA and m.pending_bytes > 0 then
            local class = get_service_class(m)
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
                -- eMBB gets urgent priority only when HOL increases.
                local priority = 0.0

                if hol >= EMBB_LATENCY_TARGET_US then
                    -- Very urgent: must be served now.
                    priority = 1000.0 + (hol / EMBB_LATENCY_TARGET_US)
                elseif hol >= EMBB_LATENCY_WARNING_US then
                    -- Warning zone: boost priority before target is violated.
                    priority = 100.0 + (hol / EMBB_LATENCY_TARGET_US)
                else
                    -- Not urgent yet.
                    priority = hol / EMBB_LATENCY_TARGET_US
                end

                embb_ues[#embb_ues + 1] = {
                    idx = i,
                    hol = hol,
                    priority = priority
                }
            end
        end
    end

    table.sort(embb_ues, function(a, b)
        if a.priority == b.priority then
            return a.hol > b.hol
        end
        return a.priority > b.priority
    end)

    table.sort(urllc_ues, function(a, b)
        if a.deficit == b.deficit then
            return a.hol > b.hol
        end
        return a.deficit > b.deficit
    end)

    -----------------------------------------------------------------------
    -- Phase 3: eMBB latency protection first
    --
    -- eMBB is ping / low-rate traffic.
    -- We do NOT reserve RBs permanently.
    -- We only allocate to eMBB early when HOL delay says it is needed.
    -----------------------------------------------------------------------
    local free_now = count_free_rbs(mask, 0, total_rbs)
    if free_now < min_rbs then
        return
    end

    local used_embb = 0

    for _, entry in ipairs(embb_ues) do
        local m = metrics[entry.idx]
        local hol = entry.hol
        local remain = free_now - used_embb
        if remain < min_rbs then
            break
        end

        -- Serve eMBB only if delay is becoming important.
        if hol >= EMBB_LATENCY_WARNING_US then
            local req = (m.required_rbs > 0) and m.required_rbs or min_rbs

            -- For ping-like traffic, usually a small grant is enough.
            -- Keep it simple: give only what is needed, bounded by remaining RBs.
            local grant_budget = math.min(req, remain)

            local new_mask, got = allocate_with_fallback(m, mask, grant_budget)
            mask = new_mask
            used_embb = used_embb + got
        end
    end

    -----------------------------------------------------------------------
    -- Phase 4: URLLC allocation with fairness inside URLLC
    --
    -- All remaining RBs go to URLLC.
    -- If there is more than one URLLC UE, divide the URLLC budget more
    -- fairly based on throughput deficit.
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
                -- Only one URLLC UE: it can use the whole URLLC budget.
                grant_budget = remain
            else
                -- Fair split among URLLC UEs according to throughput deficit.
                -- A UE farther below target gets a larger portion.
                grant_budget = math.floor(urllc_budget * (entry.deficit / deficit_sum))

                -- Ensure the last UE can use all remaining RBs.
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
    --   1) unscheduled eMBB already violating latency target
    --   2) remaining unscheduled URLLC
    --   3) remaining unscheduled eMBB
    -----------------------------------------------------------------------
    local leftover = count_free_rbs(mask, 0, total_rbs)

    if leftover >= min_rbs then
        -- 1) eMBB already violating latency target
        for _, entry in ipairs(embb_ues) do
            local m = metrics[entry.idx]
            if m.allocated_rb == 0 and entry.hol >= EMBB_LATENCY_TARGET_US then
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
        -- 2) remaining URLLC
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
        -- 3) remaining eMBB
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
                "[QoS DL %d.%d] UE uid=%d rnti=%04x fiveQI=%d class=%s pending=%d thr=%.0f bps hol=%d us alloc_rb=%d alloc_mcs=%d alloc_start=%d type=%d",
                m.frame, m.slot, m.uid, m.rnti, tonumber(m.fiveQI), get_service_class(m),
                m.pending_bytes, m.throughput, tonumber(m.hol_delay_us),
                m.allocated_rb, m.allocated_mcs, m.allocated_rb_start, m.ue_type))
        end
    end
end
