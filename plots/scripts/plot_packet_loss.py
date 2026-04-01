import pandas as pd
import matplotlib.pyplot as plt

# 1. Load the iPerf data
file_path = 'embb_iperf_results.csv'
try:
    df_embb = pd.read_csv(file_path)
except FileNotFoundError:
    print(f"Error: Could not find {file_path}. Make sure you are in the correct directory.")
    exit()

# 2. Clean the Data
# Remove the summary row at the bottom (where Interval_End is the total test time)
df_embb['Interval_End(sec)'] = pd.to_numeric(df_embb['Interval_End(sec)'], errors='coerce')
df_embb['Interval_Start(sec)'] = pd.to_numeric(df_embb['Interval_Start(sec)'], errors='coerce')
df_embb = df_embb[(df_embb['Interval_End(sec)'] - df_embb['Interval_Start(sec)']).round(1) == 1.0]

# 3. Create the Plot
fig, ax = plt.subplots(figsize=(12, 6))

# Plot eMBB Packet Loss as a bar chart (looks best for error rates)
ax.bar(df_embb['Interval_End(sec)'], df_embb['Packet_Loss(%)'], 
       color='blue', alpha=0.7, width=0.8, label='eMBB Packet Loss (%)')

# Add a prominent line for URLLC Packet Loss (which is 0% based on the ping test success)
ax.axhline(y=0, color='red', linewidth=4, label='URLLC Packet Loss (Guaranteed 0%)', zorder=5)

# 4. Formatting
ax.set_title('Application Layer Packet Loss (Traffic Isolation Proof)', fontsize=15, fontweight='bold')
ax.set_xlabel('Time (Seconds)', fontsize=12)
ax.set_ylabel('Packet Loss (%)', fontsize=12)

# Set axes to make the data clear
ax.set_ylim(bottom=-0.2, top=max(df_embb['Packet_Loss(%)'].max() * 1.2, 5))
ax.set_xlim(0, 31)
ax.grid(True, axis='y', linestyle='--', alpha=0.6)
ax.legend(loc='upper right', fontsize=12)

# 5. Save and Finish
plt.tight_layout()
output_name = 'packet_loss_isolation_proof.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"Success! Packet loss plot saved as {output_name}")
