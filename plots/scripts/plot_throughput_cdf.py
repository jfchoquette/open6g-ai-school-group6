import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import glob
import os

# 1. Find ALL data files dynamically
v4_files = glob.glob('../test-runs/v4_run*.csv')
simple_files = glob.glob('../test-runs/simple_run*.csv')

if not v4_files or not simple_files:
    print("Error: Could not find both 'v4_run*.csv' and 'simple_run*.csv'.")
    exit()

print(f"Aggregating Throughput: {len(v4_files)} Proposed Scheduler runs and {len(simple_files)} Baseline runs...")

# 2. Ultra-Robust Extraction & Aggregation Function
def get_aggregated_throughput(file_list, label_prefix):
    all_embb_tp = []
    all_urllc_tp = []

    for file_name in file_list:
        df = pd.read_csv(file_name)
        df.columns = df.columns.str.strip()
        
        if 'throughput' not in df.columns:
            continue

        # Force numeric and filter for active transmission slots only (> 0)
        df['throughput'] = pd.to_numeric(df['throughput'], errors='coerce')
        df = df[df['throughput'] > 0]
        
        embb = pd.Series(dtype=float)
        urllc = pd.Series(dtype=float)

        # Auto-detect format for this specific file
        if 'class' in df.columns:
            df['class'] = df['class'].astype(str).str.strip()
            embb = df[df['class'] == 'eMBB']['throughput']
            urllc = df[df['class'] == 'URLLC']['throughput']
        elif 'fiveQI' in df.columns:
            df['fiveQI'] = pd.to_numeric(df['fiveQI'], errors='coerce')
            embb = df[df['fiveQI'] == 9]['throughput']
            urllc = df[(df['fiveQI'] != 9) & (df['fiveQI'].notna())]['throughput']
        elif 'rnti' in df.columns:
            if not df.empty and not df['throughput'].isna().all():
                embb_rnti = df.groupby('rnti')['throughput'].max().idxmax()
                embb = df[df['rnti'] == embb_rnti]['throughput']
                urllc = df[df['rnti'] != embb_rnti]['throughput']

        all_embb_tp.append(embb)
        all_urllc_tp.append(urllc)

    # Combine all runs
    combined_embb = pd.concat(all_embb_tp, ignore_index=True) if all_embb_tp else pd.Series(dtype=float)
    combined_urllc = pd.concat(all_urllc_tp, ignore_index=True) if all_urllc_tp else pd.Series(dtype=float)

    # Convert to Mbps
    combined_embb = combined_embb / 1000000.0
    combined_urllc = combined_urllc / 1000000.0

    print(f" -> [{label_prefix} Aggregate]: eMBB active slots: {len(combined_embb):,}, URLLC active slots: {len(combined_urllc):,}")
    return combined_embb, combined_urllc

# Extract and Aggregate
v4_embb, v4_urllc = get_aggregated_throughput(v4_files, "Proposed v4")
simple_embb, simple_urllc = get_aggregated_throughput(simple_files, "Baseline")

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
fig, ax = plt.subplots(figsize=(12, 7))

# --- Plot Baseline Scheduler (Dashed Lines) ---
if len(simple_embb_x) > 0:
    ax.plot(simple_embb_x, simple_embb_y, color='gray', linestyle='--', linewidth=2, 
            label=f'Baseline eMBB (N={len(simple_embb):,})')
if len(simple_urllc_x) > 0:
    ax.plot(simple_urllc_x, simple_urllc_y, color='orange', linestyle='--', linewidth=2.5, 
            label=f'Baseline URLLC (N={len(simple_urllc):,})')

# --- Plot Proposed v4 Scheduler (Solid, Bold Lines) ---
if len(v4_embb_x) > 0:
    ax.plot(v4_embb_x, v4_embb_y, color='blue', linewidth=3.5, zorder=4,
            label=f'Proposed eMBB (N={len(v4_embb):,})')
if len(v4_urllc_x) > 0:
    ax.plot(v4_urllc_x, v4_urllc_y, color='red', linewidth=3.5, zorder=5, 
            label=f'Proposed URLLC (N={len(v4_urllc):,})')

# 5. Add the Hackathon constraint line
ax.axvline(x=80, color='green', linestyle='--', linewidth=2.5, label='eMBB SLA Target (> 80 Mbps)', zorder=1)

# Determine graph bounds dynamically
max_x_embb = max(max(v4_embb_x) if len(v4_embb_x) else 150, max(simple_embb_x) if len(simple_embb_x) else 150)
ax.axvspan(80, max_x_embb * 1.05, color='green', alpha=0.05, label='eMBB SLA Met Zone')

# 6. Formatting
ax.set_title('Aggregated Internal MAC Throughput CDF: Baseline vs Proposed', fontsize=16, fontweight='bold')
ax.set_xlabel('Calculated Throughput (Mbps)', fontsize=13)
ax.set_ylabel('Cumulative Probability', fontsize=13)

ax.set_xlim(left=0, right=max_x_embb * 1.05)
ax.set_ylim(0, 1.05)
ax.grid(True, which='both', linestyle=':', alpha=0.7)

# Move Legend to the bottom right for throughput plots
ax.legend(loc='lower right', fontsize=11, framealpha=0.9)

# 7. Save and Finish
plt.tight_layout()
os.makedirs('../figures', exist_ok=True)
output_name = '../figures/aggregated_throughput_cdf_comparison.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"\nSuccess! Aggregated Throughput CDF Plot saved as {output_name}")