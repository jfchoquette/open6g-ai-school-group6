import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import PercentFormatter
import os

# 1. Define the specific directories
proposed_dirs = [f'../test-runs/unknown_scheduler-{i}' for i in range(1, 9)]
baseline_dir = '../test-runs/unknown_scheduler-9'

# 2. Robust parsing function for iPerf CSVs
def get_loss_array(folder_list, label):
    all_losses = []
    
    for folder in folder_list:
        file_path = os.path.join(folder, 'embb_iperf_results.csv')
        if not os.path.exists(file_path):
            continue

        df = pd.read_csv(file_path)
        df.columns = df.columns.str.strip()
        
        # Ensure numeric types
        df['Interval_Start(sec)'] = pd.to_numeric(df['Interval_Start(sec)'], errors='coerce')
        df['Interval_End(sec)'] = pd.to_numeric(df['Interval_End(sec)'], errors='coerce')
        df['Packet_Loss(%)'] = pd.to_numeric(df['Packet_Loss(%)'], errors='coerce')
        
        # Drop NaNs and filter out the final summary row
        df = df.dropna(subset=['Interval_Start(sec)', 'Packet_Loss(%)'])
        df = df[(df['Interval_End(sec)'] - df['Interval_Start(sec)']).round(1) <= 1.0]
        
        all_losses.append(df['Packet_Loss(%)'])
            
    if all_losses:
        combined = pd.concat(all_losses, ignore_index=True)
        print(f" -> [{label}]: Analyzed {len(combined):,} one-second intervals.")
        return combined
    return pd.Series(dtype=float)

# 3. Extract Data
proposed_loss = get_loss_array(proposed_dirs, 'Proposed 3-Phase eMBB')
baseline_loss = get_loss_array([baseline_dir], 'Baseline eMBB')

# 4. Helper function to compute CDF
def compute_cdf(data):
    if len(data) == 0:
        return np.array([]), np.array([])
    sorted_data = np.sort(data)
    p = np.arange(1, len(data) + 1) / len(data)
    return sorted_data, p

prop_x, prop_y = compute_cdf(proposed_loss)
base_x, base_y = compute_cdf(baseline_loss)

# 5. Create the Plot
fig, ax = plt.subplots(figsize=(10, 6))

max_x = max(prop_x.max() if len(prop_x) else 5, base_x.max() if len(base_x) else 5)

# Plot URLLC First (Pushed to the back, dotted line)
ax.plot([0, 0, max_x], [0, 1.0, 1.0], color='red', linestyle=':', linewidth=3, zorder=1,
        label='Proposed URLLC (Guaranteed 0% Loss)')

# Plot Baseline (Using steps-post for accurate CDF visualization)
if len(base_x) > 0:
    ax.plot(base_x, base_y, color='purple', linestyle='-', linewidth=2.5, alpha=0.85, 
            drawstyle='steps-post', zorder=3,
            label=f'Baseline eMBB (N={len(baseline_loss):,})')

# Plot Proposed (Using steps-post)
if len(prop_x) > 0:
    ax.plot(prop_x, prop_y, color='blue', linestyle='-', linewidth=3.5, alpha=0.85,
            drawstyle='steps-post', zorder=4,
            label=f'Proposed 3-Phase eMBB (N={len(proposed_loss):,})')


# 6. Formatting & Annotations
ax.set_title('Aggregated Packet Loss CDF (1-Second Intervals)', fontsize=16, fontweight='bold', pad=15)
ax.set_xlabel('Packet Loss (%)', fontsize=14, labelpad=10)
ax.set_ylabel('Cumulative Probability', fontsize=14)

# Format X-axis to show percentage signs
ax.xaxis.set_major_formatter(PercentFormatter(decimals=1))

ax.set_xlim(-0.1, max_x * 1.05)
ax.set_ylim(0, 1.05)

ax.grid(True, which='both', linestyle=':', alpha=0.7)
ax.tick_params(axis='both', which='major', labelsize=12)

# Legend placement
ax.legend(loc='lower right', fontsize=11, framealpha=0.9)

# 7. Save and Finish
plt.tight_layout()
os.makedirs('../figures', exist_ok=True)
output_name = '../figures/packet_loss_cdf.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"\nSuccess! Packet Loss CDF Plot saved as {output_name}")