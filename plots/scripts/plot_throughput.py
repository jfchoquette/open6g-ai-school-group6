import pandas as pd
import matplotlib.pyplot as plt

# 1. Load the data
file_path = 'v4_run1.csv'
try:
    df = pd.read_csv(file_path)
except FileNotFoundError:
    print(f"Error: Could not find {file_path}. Make sure it is in the same directory.")
    exit()

# 2. Separate the traffic classes
embb_df = df[df['class'] == 'eMBB'].copy()
urllc_df = df[df['class'] == 'URLLC'].copy()

# 3. Data Conversion
# The MAC throughput tracker is in bits per second. Convert to Mbps.
embb_df['throughput_mbps'] = embb_df['throughput'] / 1000000.0

# 4. Create the Plot
fig, ax = plt.subplots(figsize=(12, 6))

# Plot the eMBB MAC-layer throughput
ax.plot(embb_df.index, embb_df['throughput_mbps'], color='blue', linewidth=2.5, label='eMBB Internal MAC Throughput')
ax.fill_between(embb_df.index, embb_df['throughput_mbps'], 80, where=(embb_df['throughput_mbps'] >= 80), color='blue', alpha=0.1)

# Add the Hackathon Target Line
ax.axhline(y=80, color='red', linestyle='--', linewidth=3, label='Hackathon SLA Target (80 Mbps)')

# Overlay URLLC Puncturing Events
# We draw a thin vertical line exactly where URLLC jumped the queue
first_urllc = True
for i in urllc_df.index:
    if first_urllc:
        ax.axvline(x=i, color='orange', linestyle='-', linewidth=1.5, alpha=0.8, label='URLLC Preemption Event')
        first_urllc = False
    else:
        ax.axvline(x=i, color='orange', linestyle='-', linewidth=1.5, alpha=0.8)

# 5. Formatting
ax.set_title('eMBB Throughput Resilience Under URLLC Preemption', fontsize=15, fontweight='bold')
ax.set_xlabel('Scheduling Slot Sequence (Time ->)', fontsize=12)
ax.set_ylabel('Calculated Throughput (Mbps)', fontsize=12)

# Set Y-axis to show the buffer ramping up and sustaining
ax.set_ylim(0, 150)
ax.set_xlim(embb_df.index.min(), embb_df.index.max())
ax.grid(True, linestyle='--', alpha=0.6)
ax.legend(loc='lower right', fontsize=11)

# 6. Save and Finish
plt.tight_layout()
output_name = 'throughput_resilience_proof.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"Success! Throughput Plot saved as {output_name}")
