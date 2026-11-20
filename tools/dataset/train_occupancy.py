"""Trains a tiny occupancy classifier (empty vs anything) on squares.npz and
reports accuracy per source, splitting by board so no board is in both
train and test.

usage: .venv/bin/python tools/dataset/train_occupancy.py [--epochs N]
writes samples/datasets/occupancy.pt
"""
import sys
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[2] / "samples" / "datasets"
SOURCES = ["chessred2k", "samryan18"]
epochs = int(sys.argv[sys.argv.index("--epochs") + 1]) if "--epochs" in sys.argv else 6
device = "mps" if torch.backends.mps.is_available() else "cpu"

data = np.load(ROOT / "squares.npz")
crops, labels, sources, groups = data["crops"], data["label"], data["source"], data["group"]
occupied = (labels > 0).astype(np.float32)

rng = np.random.default_rng(0)
boards = np.unique(groups)
test_boards = set(rng.choice(boards, size=len(boards) // 5, replace=False))
test = np.array([g in test_boards for g in groups])
train = ~test


class Net(nn.Module):
    def __init__(self):
        super().__init__()
        def block(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU(), nn.MaxPool2d(2))
        self.features = nn.Sequential(block(1, 16), block(16, 32), block(32, 64), block(64, 64))
        self.head = nn.Linear(64 * 2 * 2, 1)

    def forward(self, x):
        return self.head(self.features(x).flatten(1)).squeeze(1)


def tensor(idx, augment=False):
    x = torch.from_numpy(crops[idx]).float().div(255).unsqueeze(1)
    if augment:
        # Lighting, contrast, and the eight board symmetries.
        x = x * torch.empty(len(idx), 1, 1, 1).uniform_(0.6, 1.4) + torch.empty(len(idx), 1, 1, 1).uniform_(-0.2, 0.2)
        if rng.random() < 0.5:
            x = x.flip(3)
        x = torch.rot90(x, int(rng.integers(4)), (2, 3))
    return x.clamp(0, 1).to(device)


model = Net().to(device)
opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
loss_fn = nn.BCEWithLogitsLoss()
train_idx = np.flatnonzero(train)
print(f"train {len(train_idx)} squares, test {test.sum()} squares, device {device}")

for epoch in range(epochs):
    model.train()
    rng.shuffle(train_idx)
    total = 0.0
    for start in range(0, len(train_idx), 512):
        idx = train_idx[start:start + 512]
        loss = loss_fn(model(tensor(idx, augment=True)), torch.from_numpy(occupied[idx]).to(device))
        opt.zero_grad()
        loss.backward()
        opt.step()
        total += loss.item() * len(idx)
    print(f"epoch {epoch + 1}: loss {total / len(train_idx):.4f}", flush=True)

model.eval()
with torch.no_grad():
    test_idx = np.flatnonzero(test)
    probs = np.concatenate([torch.sigmoid(model(tensor(test_idx[i:i + 2048]))).cpu().numpy()
                            for i in range(0, len(test_idx), 2048)])
predicted = probs > 0.5
truth = occupied[test_idx] > 0.5
for s, name in enumerate(SOURCES):
    mask = sources[test_idx] == s
    if not mask.any():
        continue
    accuracy = (predicted[mask] == truth[mask]).mean()
    per_board = [(predicted[mask & (groups[test_idx] == g)] == truth[mask & (groups[test_idx] == g)]).all()
                 for g in np.unique(groups[test_idx][mask])]
    print(f"{name}: {accuracy:.2%} of squares right, {np.mean(per_board):.0%} of boards fully right")
torch.save(model.state_dict(), ROOT / "occupancy.pt")
