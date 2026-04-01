import pandas as pd
import matplotlib.pyplot as plt

# 1. Load the data
file_path = 'v4_run1.csv'
try:
    df = pd.read_csv(file_path)
except FileNotFoundError:
    print(f"Error: Could not find {file_path}. Make sure it is in the same directory.")
    exit()

# 2. Data Conversions
# Convert Head-of-Line delay from microseconds to milliseconds
df['hol_delay_ms'] = df['hol_delay_us'] / 1000.0
# Convert pending bytes to Megabytes for easier reading
df['buffer_mb'] = df['pending_bytes'] / (1024 * 1024)

# 3. Separate the traffic classes
embb_df = df[df['class'] == 'eMBB']
urllc_df = df[df['class'] == 'URLLC']

# 4. Create a dual-pane figure
# We use 'sharex=True' so the X-axis (time/sequence) perfectly aligns both graphs
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 9), sharex=True)

# --- Plot 1: eMBB Buffer Backlog (The Firehose) ---
ax1.plot(embb_df.index, embb_df['buffer_mb'], color='blue', linewidth=2.5, label='eMBB Pending Data')
ax1.fill_between(embb_df.index, embb_df['buffer_mb'], color='blue', alpha=0.1)
ax1.set_title('eMBB Network Saturation (Buffer State)', fontsize=14, fontweight='bold')
ax1.set_ylabel('Pending Data (Megabytes)', fontsize=12)
ax1.grid(True, linestyle='--', alpha=0.6)
ax1.legend(loc='upper left', fontsize=11)

# --- Plot 2: Internal MAC Latency (The Priority Fast-Lane) ---
ax2.plot(embb_df.index, embb_df['hol_delay_ms'], color='orange', linewidth=2, label='eMBB Wait Time', alpha=0.7)

# URLLC packets are sparse events, so we plot them as highly visible red dots with stem lines
ax2.scatter(urllc_df.index, urllc_df['hol_delay_ms'], color='red', s=120, zorder=5, label='URLLC Packets Processed')
for i, row in urllc_df.iterrows():
    ax2.vlines(x=i, ymin=0, ymax=row['hol_delay_ms'], color='red', linestyle='-', linewidth=2, alpha=0.8)

# Add the hackathon deadline
ax2.axhline(y=50, color='green', linestyle='--', linewidth=2.5, label='Hackathon Deadline (50ms)')

ax2.set_title('Internal MAC Scheduler Delay (Head-of-Line)', fontsize=14, fontweight='bold')
ax2.set_xlabel('Scheduling Slot Sequence (Time ->)', fontsize=12)
ax2.set_ylabel('Queue Delay (ms)', fontsize=12)

# Using a log scale for the Y-axis because the difference is so extreme (270ms vs 0.2ms)
ax2.set_yscale('log')
ax2.grid(True, which='both', linestyle='--', alpha=0.6)
ax2.legend(loc='upper left', fontsize=11)

# 5. Save and Show
plt.tight_layout()
output_name = 'mac_scheduler_proof.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"Success! Plot saved as {output_name}")
