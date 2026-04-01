# eMBB/URLLC Coexistence MAC Scheduler — Design Guidelines

## 1. Available Metrics

From `dl_ue_metric_t` in `pf_dl_simple.lua`, the key fields for traffic differentiation are:

| Field | Use for coexistence |
|---|---|
| `fiveQI` | **Traffic classification** — distinguishes eMBB (e.g., 5QI=9) from URLLC (e.g., 5QI=69). Primary discriminator. |
| `hol_delay_us` | **Head-of-line delay** (microseconds) — critical for URLLC deadline enforcement. |
| `pending_bytes` | Remaining data in the buffer — URLLC packets are typically small. |
| `bler` | Block error rate — URLLC requires much lower BLER targets (~1e-5) vs eMBB (~1e-1). |
| `cqi` / `previous_mcs` / `channel_mag_per_rb[272]` | Channel quality per RB — enables frequency-selective scheduling. |
| `throughput` | Past average throughput — needed for proportional fair (PF) metric for eMBB. |
| `slot` / `frame` | Timing info for deadline calculations. |

## 2. High-Level Architecture (3-Phase Scheduler)

Extend the current 2-phase design to **3 phases**, ordered by priority:

```
Phase 1: HARQ retransmissions  (as-is, highest priority)
Phase 2: URLLC new data        (strict latency deadline)
Phase 3: eMBB new data         (proportional fair)
```

## 3. Traffic Classification via 5QI

Use `fiveQI` to classify UEs at scheduling time:

```lua
local function is_urllc(fiveQI)
    -- 3GPP TS 23.501 Table 5.7.4-1: URLLC 5QI values
    local qi = tonumber(fiveQI)
    return qi == 69
end
```

Adjust the exact 5QI values to match your core network configuration (our testbed uses 5QI=69).

## 4. URLLC Scheduling Strategy

**Key principles from the literature (Alsenwi et al., Karimi et al., Feizi et al.):**

- **Preemptive puncturing**: When URLLC arrives mid-slot or during ongoing eMBB transmission, URLLC can **puncture** (overwrite) a portion of already-allocated eMBB RBs. In our framework, this maps to allocating URLLC *first* in Phase 2, then giving eMBB the *remaining* RBs.

- **Minimize eMBB disruption**: When choosing which eMBB RBs to puncture, prefer RBs where the eMBB UE has the **lowest channel quality** (`channel_mag_per_rb`), so the rate loss to eMBB is minimized.

- **Deadline-aware priority**: Sort URLLC UEs by urgency using `hol_delay_us`:

```lua
-- URLLC with highest urgency (closest to deadline) scheduled first
table.sort(urllc_ues, function(a, b)
    return metrics[a.idx].hol_delay_us > metrics[b.idx].hol_delay_us
end)
```

- **Compact allocation**: URLLC packets are small. Allocate only `required_rbs` (or estimate from `pending_bytes` + MCS), not the largest available block. This leaves more RBs for eMBB.

## 5. OLLA Differentiation

Use **different BLER targets** per traffic class:

| Parameter | eMBB | URLLC |
|---|---|---|
| `BLER_TARGET` | 0.10 | 0.001 (or lower) |
| `OLLA_DOWN` | 1.0 | 2.0 (more aggressive MCS reduction) |
| `OLLA_UP` | 0.1 | 0.05 (slower MCS increase) |
| `MIN_MCS` | 0 | 0 |

This makes the OLLA loop converge to a robust, low-error MCS for URLLC.

## 6. Modified PF Metric for eMBB (Fairness Under Puncturing)

Since URLLC puncturing degrades eMBB throughput, the standard PF coefficient needs awareness of this. The papers suggest a **compensation factor**:

```
coef_i = r_i(t) / (T_i(t) * (1 - rho_i))
```

where:
- `r_i(t)` = instantaneous achievable rate (from MCS/CQI)
- `T_i(t)` = past average throughput
- `rho_i` = fraction of RBs previously punctured for that eMBB UE

This ensures eMBB UEs that suffer more puncturing get scheduling priority in subsequent slots. Track `rho_i` per RNTI across slots.

## 7. Implementation Outline

```
compute_dl_allocations(...)
│
├─ Phase 1: HARQ retx (unchanged)
│
├─ Phase 2: URLLC new data
│   ├─ Filter UEs where is_urllc(fiveQI) and ue_type == NEW_DATA
│   ├─ Sort by hol_delay_us (descending = most urgent first)
│   ├─ For each URLLC UE:
│   │   ├─ Compute MCS via olla_mcs() with URLLC BLER target
│   │   ├─ Compute needed RBs from pending_bytes + MCS
│   │   ├─ Allocate from best available RBs (frequency-selective)
│   │   └─ Update mask
│   └─ If no free RBs: puncture lowest-quality eMBB RBs (advanced)
│
├─ Phase 3: eMBB new data
│   ├─ Filter UEs where NOT is_urllc(fiveQI) and ue_type == NEW_DATA
│   ├─ Compute PF coefficient (optionally with puncturing compensation)
│   ├─ Sort by PF coefficient descending
│   ├─ Allocate largest available block per UE
│   └─ Apply olla_mcs() with eMBB BLER target
```

## 8. Key Design Decisions

| Decision | Options | Trade-off |
|---|---|---|
| **Puncturing vs. reservation** | Puncture eMBB RBs on-the-fly vs. pre-reserve RBs for URLLC | Puncturing = better eMBB throughput when no URLLC; reservation = simpler, guaranteed URLLC resources |
| **Frequency-selective for URLLC** | Use `channel_mag_per_rb[]` to pick best RBs for URLLC | Better reliability but more computation per slot |
| **URLLC RB sizing** | Fixed mini-slot size vs. dynamic from `pending_bytes` | Dynamic is more efficient but needs TBS table lookup |
| **eMBB fairness compensation** | Track puncturing history per UE or not | More fair long-term, but adds state |

## 9. Related Work Summary

- **Alsenwi et al.** ("Joint Resource Allocation and Packet Scheduling"): Formulates a risk-sensitive optimization. URLLC reliability is handled via a **Lyapunov-based** online approach that converts the latency/reliability constraint into a virtual queue. Practical takeaway: prioritize URLLC by deadline urgency, compensate eMBB via modified PF.

- **Karimi et al.** ("Multiplexing URLLC within eMBB — Fair Scheduling"): Proposes **puncturing-aware proportional fairness** — track the rate loss each eMBB UE experiences due to URLLC puncturing and boost their PF priority accordingly. Directly implementable with the available metrics.

- **Feizi** (thesis): Comprehensive framework handling both DL and UL multiplexing. Recommends **superposition coding** where feasible, and **immediate preemption** for URLLC with minimal disruption to eMBB.

## 10. Suggested Incremental Plan

1. **v1**: 3-phase priority (HARQ > URLLC > eMBB), separate BLER targets
2. **v2**: Add deadline-aware URLLC sorting via `hol_delay_us`
3. **v3**: Add frequency-selective URLLC allocation via `channel_mag_per_rb`
4. **v4**: Add eMBB puncturing compensation in PF metric + OLLA oscillation fix (MCS ceiling tracking)
5. **v5**: RL-based dynamic OLLA parameter tuning via Q-table (see Section 13)

## 11. Known Issue — OLLA MCS Oscillation (v1–v3)

### 11.1 Problem Description

Versions v1–v3 exhibit a **sawtooth MCS oscillation** for eMBB UEs with high CQI. The pattern observed on UE dddc (CQI=15, 5QI=9):

```
MCS 15 ──(slow ramp ~1s)──▶ MCS 27 ──(BLER spike)──▶ MCS 15 ──(stall ~3.6s)──▶ repeat
```

Detailed cycle:
1. **Ramp phase (~1s)**: BLER drops below target (0.10), OLLA increases MCS. The accelerated recovery factor (3x when deficit > 10 MCS from CQI suggestion) rockets MCS up at +1.5/period.
2. **Crash phase (~0.4s)**: At MCS 27, BLER spikes to ~25%. The proportional down-step drops MCS aggressively: 27→25→24→21→19→17→16→15.
3. **Stall phase (~3.6s)**: At MCS 15, pending bytes have accumulated to 3–14 MB. Residual HARQ retransmissions keep the reported BLER above target, preventing recovery. HOL delay grows to 800+ ms.
4. Eventually BLER decays enough for the ramp to restart → cycle repeats.

### 11.2 Root Causes

| Cause | Detail |
|---|---|
| **No MCS ceiling memory** | After crashing from MCS 27, the scheduler has no memory that 27 was unsustainable. It climbs right back to the same failing MCS. |
| **Over-aggressive acceleration** | The 3x `accel` factor when `deficit > 10` causes MCS to increase by +1.5 per OLLA period, overshooting the sustainable MCS (~20–22 for this channel). |
| **CQI floor too permissive** | CQI=15 maps to MCS 27, floor offset=12 → floor=15. This is too low — the scheduler stalls at MCS 15 for seconds while retx queue drains. |
| **BLER feedback lag** | The `bler` field is an EMA that doesn't instantly reflect the current MCS. After a crash, stale high BLER keeps MCS pinned at the floor long after the channel could support higher MCS. |

### 11.3 Fix in v4 — MCS Ceiling Tracking

v4 adds a **per-RNTI adaptive MCS ceiling** that prevents repeated overshoot:

- When BLER exceeds `2× target`, the current `olla_frac` is recorded as `mcs_ceiling`.
- Future ramp-ups are capped at `ceiling - CEILING_MARGIN` (default 2 MCS below the last failure point).
- The ceiling relaxes upward by `CEILING_RELAX` (default +0.2) per OLLA period when BLER is good, allowing slow re-exploration.
- The acceleration factor is capped at 1.5x (was 3x) to prevent rocketing past the sustainable MCS.

This converts the sawtooth into a **converging damped oscillation** that settles at the sustainable MCS.

### 11.4 Observed Log Trace (pre-fix)

```
Frame  62: mcs=16  olla_frac=16.50  bler=0.077  pending=460K   ← ramp starts
Frame  80: mcs=20  olla_frac=20.00  bler=0.077  pending=0      ← clearing queue
Frame 112: mcs=24  olla_frac=24.00  bler=0.077  pending=0      ← climbing
Frame 149: mcs=27  olla_frac=27.00  bler=0.077  pending=0      ← peak
Frame 168: mcs=25  olla_frac=25.48  bler=0.252  pending=2.6M   ← BLER spike!
Frame 180: mcs=20  olla_frac=20.93  bler=0.252  pending=0      ← crashing
Frame 205: mcs=15  olla_frac=15.00  bler=0.252  pending=3.0M   ← floor, stuck
Frame 505: mcs=15  olla_frac=15.00  bler=0.101  pending=4.1M   ← still stuck 3s later
Frame 568: mcs=16  olla_frac=16.50  bler=0.071  pending=4.3M   ← recovery starts
Frame 662: mcs=27  olla_frac=27.00  bler=0.071  pending=6.3M   ← same peak again!
Frame 668: mcs=25  olla_frac=25.54  bler=0.246  pending=6.5M   ← same crash again
```

## 12. Experimental Results

### 12.1 Run 1 — v4 pre-OLLA-fix

**Test Setup:**
- **gNB**: OAI NR softmodem with Lua DL scheduler (`pf_dl_slice_aware_v4.lua`)
- **UEs**: 2 UEs connected
  - UE dddc (RNTI 0xdddc): eMBB, 5QI=9, CQI=15, RI=2, RSRP=-74 dBm
  - UE 2f98 (RNTI 0x2f98): URLLC, 5QI=69, CQI=8–13 (variable), RI=2, RSRP=-77 to -91 dBm
- **O-RU**: Foxconn, 2x2 MIMO

**URLLC Latency (Ping — UE 2f98):**

| Metric | Value |
|---|---|
| Min RTT | 11.9 ms |
| Max RTT | 36.8 ms |
| Avg RTT | ~23.1 ms |
| Loss | 0% |

**eMBB Throughput (iperf UDP DL — UE dddc):**

| Metric | Value |
|---|---|
| Average throughput | 96.4 Mbps |
| Peak throughput | 102 Mbps |
| Jitter (avg) | 0.226 ms |
| Packet loss | 2.2% (3898/178332) |

**gNB MAC Statistics:**

| UE | DL rounds (1st/2nd/3rd/4th) | BLER | MCS | TX bytes |
|---|---|---|---|---|
| dddc (eMBB) | 15429/1880/240/207 | 0.256 | 15 (oscillating) | 219 MB |
| 2f98 (URLLC) | 102/11/1/0 | 0.006 | 10 | 53 KB |

**Notes:** OLLA MCS sawtooth oscillation visible (15→23→crash→15 repeating). UE 2f98 has high `CCE fail` count (32) indicating PDCCH congestion.

---

### 12.2 Run 2 — v4 with OLLA ceiling fix

**Test Setup:**
- Same hardware. Scheduler: `pf_dl_slice_aware_v4.lua` with ceiling tracking fix applied.
- UE a344 (RNTI 0xa344): URLLC, 5QI=69, CQI=9–10, RI=1–2, RSRP=-79 to -80 dBm
- UE 3216 (RNTI 0x3216): eMBB, 5QI=9, CQI=15, RI=2, RSRP=-74 dBm

**URLLC Latency (Ping — UE a344):**

| Metric | Value |
|---|---|
| Min RTT | 21.4 ms |
| Max RTT | 27.0 ms |
| Avg RTT | ~25.4 ms |
| Loss | 0% |
| Samples | 10 |

Latency is **well below the 50 ms target** with tighter variance than Run 1 (±3 ms vs ±12 ms).

**eMBB Throughput (iperf UDP DL — UE 3216):**

| Metric | Value |
|---|---|
| Average throughput | 101 Mbps |
| Peak throughput | 124 Mbps |
| Jitter (avg) | 0.218 ms |
| Packet loss | 0.88% (1561/178331) |
| Duration | 20.5 s |

Throughput is improved vs Run 1 (+5 Mbps avg) and packet loss is significantly reduced (0.88% vs 2.2%). Periodic dips still occur during OLLA ramp-up/crash cycles but are less severe.

**eMBB Throughput breakdown (1s intervals):**

| Interval | Throughput | Loss |
|---|---|---|
| 0–1s | 105 Mbps | 0% |
| 1–2s | 92.5 Mbps | 3% |
| 2–3s | 84.6 Mbps | 2.5% |
| 3–7s | 102 Mbps | 0% |
| 7–8s | 107 Mbps | 0% |
| 8–9s | 107 Mbps | 6.3% |
| 9–10s | 82.8 Mbps | 2.5% |
| 10–14s | 102–107 Mbps | 0% |
| 14–15s | 116 Mbps | 2.3% |
| 15–16s | 84.4 Mbps | 1.6% |
| 16–20s | 102–107 Mbps | 0% |

**gNB MAC Statistics (Frame 768):**

| UE | DL rounds (1st/2nd/3rd/4th) | BLER | MCS | TX bytes |
|---|---|---|---|---|
| 3216 (eMBB) | 14395/1424/213/27 | 0.053 | 23 (ramping) | 203 MB |
| a344 (URLLC) | 177/13/0/0 | 0.075 | 10 | 106 KB |

**OLLA Behavior:** The ceiling tracking successfully prevents the old sawtooth MCS run-away pattern, but a new oscillation cycle is visible:
1. MCS ramps 15→17→19→21→23 over ~80 frames (with ceiling tracking up from 15→27)
2. At MCS 23, BLER spikes to 0.25+, ceiling drops back to ~15, MCS crashes to 15
3. Stuck at MCS 15 for ~300 frames while ceiling slowly relaxes (0.2/period)
4. Once ceiling > 17, starts climbing again

**Root causes identified:** The ceiling relaxation rate (`CEILING_RELAX=0.2/period`) is too slow — once ceiling drops to 15, it takes ~60 OLLA periods (~300 frames) to climb back. Also the down-step is too aggressive: a single BLER spike (0.25) triggers `excess_ratio=2.5×`, dropping MCS by 4 units per period.

---

### 12.3 Run 3 — v4.1 tuning (regression — CQI=11 eMBB)

**Test Setup:**
- Same hardware. Scheduler: `pf_dl_slice_aware_v4.lua` v4.1 tuning (CEILING_RELAX=0.5, CEILING_MIN_OFFSET=6, MAX_DOWN_STEP=4, URLLC_RB_BUDGET=15%).
- UE be5e (RNTI 0xbe5e): eMBB, 5QI=9, CQI=11–13, RI=2, RSRP=-74 to -77 dBm
- UE a1a0 (RNTI 0xa1a0): URLLC, 5QI=69, CQI=3–10 (very variable), RI=1–2, RSRP=-78 to -109 dBm (moving UE)

**URLLC Latency (Ping — UE a1a0):**

| Metric | Value |
|---|---|
| Min RTT | 11.9 ms |
| Max RTT | 34.9 ms |
| Avg RTT | ~24.4 ms |
| Loss | 0% |
| Samples | 10 |

URLLC latency remains well below 50 ms target. Higher variance (±12 ms) likely due to UE mobility (CQI swings 3–10).

**eMBB Throughput (iperf UDP DL — UE be5e):**

| Metric | Value |
|---|---|
| Average throughput | ~81.5 Mbps |
| Peak throughput | 106 Mbps |
| Jitter (avg) | 0.219 ms |
| Packet loss | 0.52% (928/178332) |
| Duration | 20.5 s |

**Regression**: Average throughput dropped from 101 Mbps (Run 2) to ~81.5 Mbps. The eMBB UE spends ~50% of time stuck at MCS 8 (~57 Mbps) due to the CQI floor/ceiling trap described below.

**eMBB Throughput breakdown (1s intervals):**

| Interval | Throughput | Notes |
|---|---|---|
| 0–1s | 93.9 Mbps | Initial ramp |
| 1–4s | 56–62 Mbps | Stuck at MCS 8 |
| 4–7s | 94–106 Mbps | Recovered to MCS 20+ |
| 7–10s | 56–71 Mbps | Stuck again |
| 10–13s | 94–106 Mbps | Recovered |
| 13–16s | 56–68 Mbps | Stuck again |
| 16–20s | 94–106 Mbps | Recovered |

The throughput alternates between ~100 Mbps (MCS 20+) and ~57 Mbps (MCS 8) in ~6-second cycles.

**gNB OLLA Behavior:** The scheduler enters a death spiral:
1. MCS ramps 8→12→16→20→24 over ~100 frames (ceiling relaxing well)
2. At MCS 24, BLER spikes to 0.26–0.28, ceiling crashes to ~14 (min = CQI_MCS - 6 = 20 - 6 = 14)
3. Down-step cascade continues every OLLA period: 24→22→18→14→12→9→8 (floor = CQI_MCS - 12 = 8)
4. **Stuck at MCS 8 for 400+ frames** — BLER stays 0.15–0.18 at low MCS, preventing ceiling relaxation
5. Eventually BLER drops below target, ceiling relaxes, and cycle restarts

**Root cause of regression (v4.1 floor/ceiling trap):**
- `EMBB_CQI_FLOOR_OFFSET = 12`: For CQI=11 (MCS≈20), floor = 20 - 12 = **MCS 8** (too low)
- `CEILING_MIN_OFFSET = 6`: Minimum ceiling = 20 - 6 = **14**, so effective_cap = 14 - 2 = 12
- Once ceiling is at 14, the usable MCS range is only [8, 12] — a **throughput trap**
- The down-step cascade fires every 5-frame period, driving MCS all the way to the floor
- At MCS 8, BLER doesn't improve (wrong cause — BLER was from high MCS, not channel), so the scheduler stays stuck

**v4.2 fix applied:**
- `EMBB_CQI_FLOOR_OFFSET 12→6`: floor = CQI_MCS - 6 (CQI=11 → floor=14 instead of 8)
- `BLER_DEADZONE = 1.3×`: No down-step when BLER is within 30% of target (stops cascade)
- `EMBB_OLLA_DOWN 1.0→0.5`: Gentler per-step reduction
- `CEILING_MIN_OFFSET 6→4`: Min ceiling = CQI_MCS - 4 (CQI=11 → ceil≥16, effective_cap≥14)

**Key lesson:** Tuning parameters derived from CQI=15 UEs (Run 2) break badly for CQI=11 UEs because the floor/ceiling offsets are absolute, not proportional. The v4.2 fix tightens offsets and adds a BLER dead-zone to prevent the cascading down-step that causes the MCS trap.

---

### 12.4 Run 4 — v4.2 tuning (improved but floor=cap trap remains)

**Test Setup:**
- Same hardware. Scheduler: `pf_dl_slice_aware_v4.lua` v4.2 tuning (FLOOR_OFFSET=6, CEILING_MIN_OFFSET=4, CEILING_MARGIN=2, BLER_DEADZONE=1.3, OLLA_DOWN=0.5).
- UE 9dd9 (RNTI 0x9dd9): eMBB, 5QI=9, CQI=10–11, RI=2, RSRP=-75 to -81 dBm
- UE 97d7 (RNTI 0x97d7): URLLC, 5QI=69, CQI=10–12, RI=2, RSRP=-81 to -95 dBm

**URLLC Latency (Ping — UE 97d7):**

| Metric | Value |
|---|---|
| Min RTT | 8.5 ms |
| Max RTT | 31.8 ms |
| Avg RTT | ~23 ms |
| Loss | 0% |
| Samples | 20 (2 rounds) |

Latency well below 50 ms target with both ping rounds consistent.

**eMBB Throughput (iperf UDP DL — UE 9dd9):**

| Metric | Value |
|---|---|
| Average throughput | 89.5 Mbps |
| Peak throughput | 101 Mbps |
| Jitter (avg) | 0.233 ms |
| Packet loss | 0.65% (1092/168596) |
| Duration | 22.0 s |

Improvement over Run 3 (+8 Mbps avg) but still below Run 2 (101 Mbps). The eMBB UE still gets stuck at fixed MCS values for extended periods.

**eMBB Throughput breakdown (1s intervals):**

| Interval | Throughput | Notes |
|---|---|---|
| 0–1s | 90.8 Mbps | Initial ramp (1.8% loss) |
| 1–4s | 93.9–95.8 Mbps | MCS 14–16 phase |
| 4–5s | 101 Mbps | Reached MCS 19+ |
| 5–7s | 88–93 Mbps | BLER spike, dipping |
| 7–10s | 94.7–95.9 Mbps | MCS 14 trap |
| 10–11s | 101 Mbps | Brief recovery |
| 11–13s | 86.9–87.2 Mbps | Second crash |
| 13–16s | 79.1–79.4 Mbps | **MCS 12 trap** (CQI=10) |
| 16–18s | 85.2–96.4 Mbps | Ramping back up |
| 18–22s | 78.9–87.4 Mbps | Mixed, second MCS 12 phase |

**gNB MAC Statistics:**

| Frame | UE | DL rounds (1st/2nd/3rd/4th) | BLER | MCS | TX bytes |
|---|---|---|---|---|---|
| 896 | 9dd9 (eMBB) | 11083/1182/191/8 | 0.071 | 24 (peak) | 148 MB |
| 896 | 97d7 (URLLC) | 69/5/1/0 | 0.031 | 12 | 37 KB |

**OLLA Behavior — two distinct trap phases:**

**Phase 1 — CQI=11, MCS 14 trap (frames 893–112, ~220 frames):**
- `olla_frac=14.00, ceil=16.0` — effective_cap = 16-2 = **14 = floor** (CQI=11, floor=20-6=14)
- BLER decays slowly: 0.216 → 0.151 → 0.106 → 0.076 (takes ~180 frames to drop below 0.10)
- Once BLER < 0.10, ceiling relaxes and MCS ramps: 14→16→18→20→22→24 over ~100 frames
- At MCS 24, BLER spikes to 0.343 → crash back to MCS 14 in ~5 OLLA periods

**Phase 2 — CQI drops to 10, MCS 12 trap (frames 944–288, ~350 frames):**
- CQI_MCS=18, floor=18-6=**12**, min_ceil=18-4=14, effective_cap=14-2=**12**
- Again: **floor = effective_cap → locked at MCS 12** (~80 Mbps)
- BLER decays: 0.346 → 0.257 → 0.180 → 0.126 → 0.088 (takes ~340 frames)
- Pending bytes grow from 16 MB to 36 MB during MCS 12 phase
- Eventually recovers, ramps to MCS 18→24, then next BLER spike crashes it again

**Root cause — floor=cap equality:**
- v4.2 parameters: `FLOOR_OFFSET=6, CEIL_MIN_OFFSET=4, CEIL_MARGIN=2` → `6 = 4 + 2`
- At minimum ceiling: effective_cap = CQI_MCS - (CEIL_MIN_OFFSET + CEIL_MARGIN) = CQI_MCS - 6 = floor
- Both CQI=11 and CQI=10 create zero-headroom traps (MCS 14 and MCS 12 respectively)
- The cascade still drops through ~10 OLLA periods before reaching the floor (no cumulative cap)

**v4.3 fix applied:**
- `CEILING_MARGIN 2→1`: effective_cap = ceil - 1 (more headroom above floor)
- `CEILING_MIN_OFFSET 4→2`: min_ceil = CQI_MCS - 2 (CQI=10→ceil≥16, CQI=11→ceil≥18)
- `MAX_CUMULATIVE_DROP = 6`: max 6 MCS total drop per BLER event (from MCS 24 → stops at 18, not floor)
- Track per-UE `dropping`/`drop_start` state to enforce cumulative cap

**Expected improvement for CQI=10 (MCS=18):**
- New: floor=12, min_ceil=16, effective_cap=15 → usable range [12, 15] (was [12, 12])
- Cumulative cap: from MCS 24, stops at 18 instead of cascading to 12
- Recovery from MCS 18 is much faster than from MCS 12

**Run comparison:**

| Run | Version | CQI | eMBB avg | eMBB loss | URLLC avg RTT | Trap MCS | Trap duration |
|---|---|---|---|---|---|---|---|
| 1 | v4 pre-fix | 15 | 96.4 Mbps | 2.2% | 23.1 ms | Sawtooth 15–23 | Continuous |
| 2 | v4 ceiling | 15 | 101 Mbps | 0.88% | 25.4 ms | 15 | ~300 frames |
| 3 | v4.1 | 11–13 | 81.5 Mbps | 0.52% | 24.4 ms | 8 | 400+ frames |
| 4 | v4.2 | 10–11 | 89.5 Mbps | 0.65% | 23 ms | 14/12 | 220/350 frames |
| 5 | v4.3 | 10–11 | **103 Mbps** | 2.0% | 24.0 ms | — | Shorter cycles |

---

### 12.5 Run 5 — v4.3 tuning (cumulative drop cap — best throughput)

**Test Setup:**
- Same hardware. Scheduler: `pf_dl_slice_aware_v4.lua` v4.3 tuning (CEILING_MARGIN=1, CEILING_MIN_OFFSET=2, MAX_CUMULATIVE_DROP=6).
- UE 9dd9 (RNTI 0x9dd9): eMBB, 5QI=9, CQI=10–11, RI=2
- UE 97d7 (RNTI 0x97d7): URLLC, 5QI=69

**URLLC Latency (Ping — UE 97d7):**

| Metric | Value |
|---|---|
| Min RTT | 12.0 ms |
| Max RTT | 41.1 ms |
| Avg RTT | ~24.0 ms |
| Loss | 0% |
| Samples | 30 (3 rounds) |

Latency well below 50 ms target. Higher max (41.1 ms) in first round but still within budget.

**eMBB Throughput (iperf UDP DL — UE 9dd9):**

| Metric | Value |
|---|---|
| Average throughput | **103 Mbps** |
| Peak throughput | 120 Mbps |
| Jitter (avg) | 0.217 ms |
| Packet loss | 2.0% (3565/178331) |
| Duration | 20.0 s |

**Best eMBB throughput across all runs** (+13.5 Mbps over Run 4, +2 Mbps over Run 2). Peak 120 Mbps exceeds all prior peaks. Packet loss is higher (2.0% vs 0.65%) due to more aggressive MCS exploration.

**eMBB Throughput breakdown (1s intervals):**

| Interval | Throughput | Loss | Notes |
|---|---|---|---|
| 0–1s | 65.8 Mbps | 16% | Initial ramp + OLLA cold start |
| 1–2s | 111 Mbps | 5.8% | Fast ramp to MCS 20+ |
| 2–3s | 114 Mbps | 5.5% | Exploring high MCS |
| 3–4s | 103 Mbps | 1.5% | Stabilizing |
| 4–5s | 103 Mbps | 1.4% | Stable |
| 5–6s | 104 Mbps | 0.27% | Stable |
| 6–7s | 105 Mbps | 0.1% | Stable — near-zero loss |
| 7–8s | 85.9 Mbps | 0.16% | BLER dip (but **not stuck**) |
| 8–9s | 119 Mbps | 1.3% | Fast recovery + peak |
| 9–10s | 108 Mbps | 0% | Stable |
| 10–11s | 105 Mbps | 0% | Stable |
| 11–12s | 105 Mbps | 0% | Stable |
| 12–13s | 86.8 Mbps | 1.3% | Brief dip |
| 13–14s | 104 Mbps | 4.7% | Recovery (BLER spike) |
| 14–15s | 117 Mbps | 0% | Peak recovery |
| 15–16s | 105 Mbps | 0% | Stable |
| 16–17s | 105 Mbps | 0% | Stable |
| 17–18s | 88.1 Mbps | 1.9% | Brief dip |
| 18–19s | 102 Mbps | 2.6% | Recovery |
| 19–20s | 120 Mbps | 0% | Peak — highest interval |

**Key improvement over Run 4:** The throughput dips are **brief** (1–2 seconds) and recovery is **fast** — no more 220–350 frame MCS traps. The cumulative drop cap prevents the cascade from reaching the floor, so the scheduler bounces back from ~86 Mbps to 105+ Mbps within 1–2 seconds instead of being stuck at 79–80 Mbps for 5+ seconds.

---

## 13. Reinforcement Learning Extension (v5)

After the heuristic scheduler (v1–v4) is stable, RL can be layered on top to dynamically tune scheduling parameters.

### 13.1 RL Formulation

**State** (observable every slot from `dl_ue_metric_t`):
- Per-UE: `cqi`, `bler`, `throughput`, `hol_delay_us`, `pending_bytes`, `fiveQI`, `previous_mcs`, `channel_mag_per_rb[]`
- System-level: RB mask occupancy, number of active URLLC/eMBB UEs

**Action space** — what the RL agent decides:
- How many RBs to reserve for URLLC vs. leave for eMBB (replacing the fixed Phase 2/3 split)
- OLLA step sizes (`step_up`, `step_down`) per UE or per class
- The PF compensation factor weighting

**Reward** — multi-objective trade-off:

```
R(t) = α · Σ_eMBB log(T_i)  −  β · Σ_URLLC 1[hol_delay > D_max]  −  γ · Σ_URLLC bler_i
```

- First term: eMBB proportional fairness (log-throughput)
- Second term: URLLC deadline violation penalty
- Third term: URLLC reliability violation penalty

### 13.2 Where RL Adds Value Over Heuristics

| Aspect | v1–v4 heuristic | RL advantage |
|---|---|---|
| URLLC RB budget | Fixed priority (all URLLC first) | Learn optimal RB split dynamically based on load |
| OLLA parameters | Static per-class constants | Adapt step sizes per-UE based on channel dynamics |
| Puncturing decision | Puncture lowest-quality eMBB RBs | Learn when puncturing is worthwhile vs. deferring URLLC by 1 slot |
| PF compensation | Track ρ_i with fixed formula | Learn the right compensation weight from observed fairness |

### 13.3 Practical Approaches (simple → complex)

1. **Contextual Bandit** (recommended start): Replace fixed OLLA parameters with a bandit that picks from a discrete set of `(BLER_target, step_up, step_down)` tuples per slot. Context = `(avg_cqi, urllc_load, embb_load)`. No temporal credit assignment needed.

2. **Deep Q-Network (DQN) for RB partitioning**: State = `(n_urllc_ues, n_embb_ues, avg_hol_delay, avg_bler, rb_utilization)`. Action = fraction of BWP reserved for URLLC (discretized: 0%, 10%, 20%, …, 50%). Train offline on logged scheduling data, deploy as a lookup.

3. **Multi-Agent PPO** (most powerful, most complex): Each UE class has an agent. The URLLC agent decides RB demand; the eMBB agent decides PF weights. Shared reward with competing objectives. Mirrors the Alsenwi et al. Lyapunov approach but learned rather than derived.

### 13.4 Real-Time Constraints

The scheduler runs in LuaJIT from C every slot (~0.5ms at 30kHz SCS). The slot processing budget is ~100–200 microseconds. RL inference must respect this:

| Approach | Latency per slot | Feasible in slot loop? |
|---|---|---|
| Lua table lookup (Q-table) | ~0.1 µs | Yes |
| Small decision tree | ~0.5 µs | Yes |
| Neural network (even tiny MLP) | ~50–500 µs | **No** |
| Python callback via IPC | ~1–10 ms | **No** |

### 13.5 Recommended Integration Architecture

Run RL decisions at a **slow timescale** (every ~100ms, matching `OLLA_PERIOD`), not every slot. The RL agent sets policy parameters that the fast Lua scheduler consumes:

```
Every 100ms (RL timescale):
  Python/C agent observes aggregated metrics
  → outputs: urllc_rb_budget, olla_params_urllc, olla_params_embb
  → writes to shared memory / global Lua variables

Every slot (scheduler timescale):
  Lua scheduler reads those parameters
  → runs Phase 1/2/3 as before, using RL-tuned params
```

This keeps the hot path (slot-level Lua) unchanged and real-time safe, while the RL agent operates at a coarser granularity where inference latency is acceptable.

### 13.6 Data Collection

The existing debug prints already log per-UE state every 100 slots. These logs contain the state-action-reward tuples needed for offline RL training. The biggest practical gain is **learning the URLLC RB budget dynamically** — a single scalar decision per period that the heuristic currently sets implicitly (all available RBs to URLLC first), which can be overly aggressive under low URLLC load.
