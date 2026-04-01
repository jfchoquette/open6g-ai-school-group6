import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import ScalarFormatter
import glob

# 1. Find ALL data files dynamically
v4_files = glob.glob('../test-runs/v4_run*.csv')
simple_files = glob.glob('../test-runs/simple_run*.csv')

if not v4_files or not simple_files:
    print("Error: Could not find both 'v4_run*.csv' and 'simple_run*.csv' files.")
    exit()

print(f"Aggregating {len(v4_files)} Proposed Scheduler runs and {len(simple_files)} Baseline runs...")

# 2. Ultra-Robust Extraction & Aggregation Function
def get_aggregated_delays(file_list, label_prefix):
    all_embb_delays = []
    all_urllc_delays = []

    for file_name in file_list:
        df = pd.read_csv(file_name)
        df.columns = df.columns.str.strip()
        
        if 'hol_delay_us' not in df.columns:
            continue

        df['hol_delay_us'] = pd.to_numeric(df['hol_delay_us'], errors='coerce')
        df['hol_delay_ms'] = df['hol_delay_us'] / 1000.0
        df['hol_delay_ms'] = df['hol_delay_ms'].clip(lower=0.01) # Keep log scale safe
        
        embb = pd.Series(dtype=float)
        urllc = pd.Series(dtype=float)

        # Auto-detect format for this specific file
        if 'class' in df.columns:
            df['class'] = df['class'].astype(str).str.strip()
            embb = df[df['class'] == 'eMBB']['hol_delay_ms'].dropna()
            urllc = df[df['class'] == 'URLLC']['hol_delay_ms'].dropna()
        elif 'fiveQI' in df.columns:
            df['fiveQI'] = pd.to_numeric(df['fiveQI'], errors='coerce')
            embb = df[df['fiveQI'] == 9]['hol_delay_ms'].dropna()
            urllc = df[(df['fiveQI'] != 9) & (df['fiveQI'].notna())]['hol_delay_ms'].dropna()
        elif 'rnti' in df.columns and 'throughput' in df.columns:
            df['throughput'] = pd.to_numeric(df['throughput'], errors='coerce')
            if not df.empty and not df['throughput'].isna().all():
                embb_rnti = df.groupby('rnti')['throughput'].max().idxmax()
                embb = df[df['rnti'] == embb_rnti]['hol_delay_ms'].dropna()
                urllc = df[df['rnti'] != embb_rnti]['hol_delay_ms'].dropna()

        all_embb_delays.append(embb)
        all_urllc_delays.append(urllc)

    # Combine all individual runs into one massive dataset
    combined_embb = pd.concat(all_embb_delays, ignore_index=True) if all_embb_delays else pd.Series(dtype=float)
    combined_urllc = pd.concat(all_urllc_delays, ignore_index=True) if all_urllc_delays else pd.Series(dtype=float)

    print(f" -> [{label_prefix} Aggregate]: Total eMBB packets: {len(combined_embb)}, Total URLLC packets: {len(combined_urllc)}")
    return combined_embb, combined_urllc

# Extract and Aggregate
v4_embb, v4_urllc = get_aggregated_delays(v4_files, "Proposed v4")
simple_embb, simple_urllc = get_aggregated_delays(simple_files, "Baseline")

# 3. Helper function to compute CDF
def compute_cdf(data):
    if len(data) == 0:
        return np.array([]), np.array([])
    sorted_data = np.sort(data)
    p = np.arange(1, len(data) + 1) / len(data)
    return sorted_data, p

v4_embb_x, v4_embb_y = compute_cdf(v4_embb)
v4_urllc_x, v4_urllc_y = compute_cdf(v4_urllc)
simple_embb_x, simple_embb_y = compute_cdf(simple_embb)
simple_urllc_x, simple_urllc_y = compute_cdf(simple_urllc)

# 4. Create the Plot
fig, ax = plt.subplots(figsize=(11, 7))

# --- Plot Baseline Scheduler (Dashed Lines) ---
if len(simple_embb_x) > 0:
    ax.plot(simple_embb_x, simple_embb_y, color='gray', linestyle='--', linewidth=2, 
            label=f'Baseline eMBB (N={len(simple_embb):,})')
if len(simple_urllc_x) > 0:
    ax.plot(simple_urllc_x, simple_urllc_y, color='orange', linestyle='--', linewidth=2.5, 
            label=f'Baseline URLLC (N={len(simple_urllc):,})')

# --- Plot Proposed v4 Scheduler (Solid, Bold Lines) ---
if len(v4_embb_x) > 0:
    ax.plot(v4_embb_x, v4_embb_y, color='blue', linewidth=2.5, 
            label=f'Proposed eMBB (N={len(v4_embb):,})')
if len(v4_urllc_x) > 0:
    ax.plot(v4_urllc_x, v4_urllc_y, color='red', linewidth=3.5, zorder=5, 
            label=f'Proposed URLLC (N={len(v4_urllc):,})')

# 5. Add the Hackathon constraint lines
ax.axvline(x=50, color='green', linestyle='--', linewidth=2.5, label='SLA Deadline (50ms)', zorder=1)
ax.axhline(y=0.99, color='black', linestyle=':', linewidth=1.5, label='99th Percentile Target', zorder=1)

ax.axvspan(0.01, 50, color='green', alpha=0.05, label='URLLC Safe Zone')

# 6. Formatting
ax.set_title('Aggregated Internal MAC Latency CDF (All Test Runs)', fontsize=16, fontweight='bold')
ax.set_xlabel('Head-of-Line Queue Delay (ms)', fontsize=13)
ax.set_ylabel('Cumulative Probability', fontsize=13)

# Set X-axis to Log Scale
ax.set_xscale('log')
ax.xaxis.set_major_formatter(ScalarFormatter())
ax.set_xticks([0.1, 1, 10, 50, 100, 300]) 

ax.set_ylim(0, 1.05)
ax.grid(True, which='both', linestyle=':', alpha=0.7)

ax.legend(loc='lower right', fontsize=11, framealpha=0.9)

# 7. Save and Finish
plt.tight_layout()
output_name = '../figures/aggregated_latency_cdf_comparison.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"\nSuccess! Aggregated CDF Plot saved as {output_name}")