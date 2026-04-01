import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import glob
import os

# 1. Find ALL data files dynamically
v4_files = glob.glob('../test-runs/v4_run*.csv')
simple_files = glob.glob('../test-runs/simple_run*.csv')

if not v4_files or not simple_files:
    print("Error: Could not find both 'v4_run*.csv' and 'simple_run*.csv' files.")
    exit()

print(f"Aggregating Box Plot: {len(v4_files)} Proposed runs vs {len(simple_files)} Baseline runs...")

# 2. Robust Extraction & Aggregation Function
def get_aggregated_throughput_data(file_list, scheduler_name):
    all_data = []
    total_embb = 0
    total_urllc = 0

    for file_name in file_list:
        df = pd.read_csv(file_name)
        df.columns = df.columns.str.strip()
        
        if 'throughput' not in df.columns:
            continue

        # Force numeric and drop actual NaNs, but KEEP 0s to show complete failures
        df['throughput'] = pd.to_numeric(df['throughput'], errors='coerce')
        df = df.dropna(subset=['throughput']).copy()
        
        embb = pd.Series(dtype=float)
        urllc = pd.Series(dtype=float)

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

        # Convert to Mbps
        embb = embb / 1000000.0
        urllc = urllc / 1000000.0
        
        total_embb += len(embb)
        total_urllc += len(urllc)

        # Structure for Seaborn (melted format)
        for val in embb:
            all_data.append({'Throughput (Mbps)': val, 'Traffic Type': 'eMBB (NRT)', 'Scheduler': scheduler_name})
        for val in urllc:
            all_data.append({'Throughput (Mbps)': val, 'Traffic Type': 'URLLC (RT)', 'Scheduler': scheduler_name})

    print(f" -> [{scheduler_name}]: Aggregated {total_embb:,} eMBB slots, {total_urllc:,} URLLC slots.")
    if total_urllc > 0 and max([d['Throughput (Mbps)'] for d in all_data if d['Traffic Type'] == 'URLLC (RT)']) < 0.1:
        print(f"    [!] WARNING: URLLC throughput is incredibly low across all runs. Did the 10M iPerf command fail?")
        
    return pd.DataFrame(all_data)

# 3. Process and Combine Data
df_v4_plot = get_aggregated_throughput_data(v4_files, 'Proposed')
df_simple_plot = get_aggregated_throughput_data(simple_files, 'Original')

df_plot = pd.concat([df_simple_plot, df_v4_plot], ignore_index=True)

if df_plot.empty:
    print("Error: No valid throughput data found to plot.")
    exit()

# 4. Create the Box Plot
sns.set_theme(style="whitegrid")
fig, ax = plt.subplots(figsize=(6, 4))

my_palette = {"eMBB (NRT)": "#4C72B0", "URLLC (RT)": "#C44E52"}

sns.boxplot(
    data=df_plot, 
    x='Scheduler', 
    y='Throughput (Mbps)', 
    hue='Traffic Type',
    palette=my_palette,
    width=0.6,
    boxprops={'edgecolor': 'black', 'linewidth': 1.5},
    whiskerprops={'linewidth': 1.5},
    capprops={'linewidth': 1.5},
    flierprops={'marker': 'o', 'markersize': 3, 'alpha': 0.1} # Lowered alpha because of massive data points
)

# 5. Formatting & Annotations
# ax.set_title('Throughput: Original vs Proposed', fontsize=16, fontweight='bold', pad=15)
ax.set_xlabel('Scheduler Implementation', fontsize=14, labelpad=10)
ax.set_ylabel('Throughput (Mbps)', fontsize=14)

ax.tick_params(axis='both', which='major', labelsize=12)

ax.legend(title='Traffic Class', title_fontsize=9, fontsize=9, loc='upper right' , ncol=1, framealpha=1)
ax.set_ylim(bottom=-5) 

ax.axhline(y=80, color='green', linestyle='--', linewidth=2, alpha=0.7, zorder=0)
ax.text(0.05, 82, 'eMBB Target SLA (80 Mbps)', color='green', fontsize=10, fontweight='bold')

ax.axhline(y=10, color='red', linestyle=':', linewidth=2, alpha=0.7, zorder=0)
ax.text(0.05, 12, 'URLLC Load (10 Mbps)', color='red', fontsize=10, fontweight='bold')

# 6. Save and Finish
plt.tight_layout()
os.makedirs('../figures', exist_ok=True)
output_name = '../figures/aggregated_throughput_boxplot.png'
plt.savefig(output_name, dpi=300, bbox_inches='tight')
print(f"Success! Aggregated Box plot saved as {output_name}")