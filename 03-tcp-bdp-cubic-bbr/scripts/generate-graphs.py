import json
import matplotlib.pyplot as plt
import os

os.makedirs('graphs', exist_ok=True)

def load_throughput(path):
    data = json.load(open(path))
    times = [iv['sum']['start'] for iv in data['intervals']]
    mbps = [iv['sum']['bits_per_second'] / 1e6 for iv in data['intervals']]
    return times, mbps

# --- Chart 1: Buffer/burst tuning story ---
plt.figure(figsize=(10, 6))

t, m = load_throughput('results/csv/tuned-buffers.json')
plt.plot(t, m, label='Tuned buffers, original 4Kb burst', marker='o', markersize=3)

# Reuse the same file if a JSON version of the corrected-burst run exists;
# otherwise this line will need the matching .json capture
try:
    t2, m2 = load_throughput('results/csv/tuned-buffers-larger-burst.json')
    plt.plot(t2, m2, label='Tuned buffers, corrected 128Kb burst', marker='s', markersize=3)
except FileNotFoundError:
    print("Note: no JSON capture for corrected-burst run — chart will only show one line")

plt.xlabel('Time (seconds)')
plt.ylabel('Throughput (Mbit/s)')
plt.title('TCP Throughput: Buffer Tuning vs Burst Size Correction')
plt.legend()
plt.grid(True, alpha=0.3)
plt.savefig('graphs/phase2-buffer-burst-tuning.png', dpi=150, bbox_inches='tight')
plt.close()
print("Saved graphs/phase2-buffer-burst-tuning.png")
