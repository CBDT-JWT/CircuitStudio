"""Train a small, offline symbol classifier on writer-disjoint CGHD crops.

Synthetic jittered strokes augment training only. Validation and test metrics
are measured on real photographs from writers never used for training.
"""
import argparse
import collections
import hashlib
import json
import math
import pathlib
import random
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageOps
import torch
from torch import nn
from torch.utils.data import Dataset, DataLoader, WeightedRandomSampler

LABELS = ["other", "resistor", "capacitor", "polarizedCapacitor", "inductor", "diode", "ground", "voltageSource", "acVoltage", "mos", "opAmp"]
MAPPING = {"resistor": "resistor", "capacitor.unpolarized": "capacitor", "capacitor.polarized": "polarizedCapacitor", "inductor": "inductor", "diode": "diode", "gnd": "ground", "voltage.dc": "voltageSource", "voltage.ac": "acVoltage", "transistor.fet": "mos", "operational_amplifier": "opAmp"}
WRITERS = {"train": [1, 2, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14], "validation": [3, 11], "test": [15, 16, 17]}
SIDE = 96


def normalize_photo(im):
    im = im.copy()
    im.thumbnail((256, 256), Image.Resampling.LANCZOS)
    gray = ImageOps.grayscale(im)
    # Remove slow paper illumination gradients, then threshold dark/colored ink.
    a = np.asarray(gray, dtype=np.float32)
    background = np.asarray(gray.filter(ImageFilter.MaxFilter(15)), dtype=np.float32)
    contrast = np.clip(background - a, 0, 255).astype(np.uint8)
    hist = np.bincount(contrast.ravel(), minlength=256).astype(float)
    w = np.cumsum(hist); means = np.cumsum(hist * np.arange(256))
    score = (means[-1] * w - means * w[-1]) ** 2 / np.maximum(w * (w[-1] - w), 1)
    threshold = max(8, min(90, int(score.argmax())))
    binary = Image.fromarray(np.where(contrast > threshold, 255, 0).astype(np.uint8))
    return tile(binary)


def tile(ink):
    ink = ink.convert("L")
    bbox = ink.point(lambda p: 255 if p > 64 else 0).getbbox()
    if bbox:
        ink = ink.crop(bbox)
    ink.thumbnail((80, 80), Image.Resampling.LANCZOS)
    result = Image.new("L", (SIDE, SIDE))
    result.paste(ink, ((SIDE - ink.width) // 2, (SIDE - ink.height) // 2))
    return np.asarray(result).copy()


def prepare(root, output):
    output.mkdir(parents=True, exist_ok=True)
    arrays = {s: [] for s in WRITERS}; labels = {s: [] for s in WRITERS}; ids = {s: [] for s in WRITERS}
    for writer in range(1, 18):
        split = next(s for s, values in WRITERS.items() if writer in values)
        for p in sorted((root / f"drafter_{writer}" / "images").iterdir()):
            if not p.stem.endswith("_P1") or p.suffix.lower() not in [".jpg", ".jpeg", ".png"]:
                continue
            xml = p.parent.parent / "annotations" / p.with_suffix(".xml").name
            tree = ET.parse(xml)
            image = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
            size = tree.find("size")
            expected = (int(size.findtext("width")), int(size.findtext("height")))
            if image.size != expected:
                raise ValueError(f"Annotation/image mismatch after EXIF orientation: {p}: {image.size} vs {expected}")
            for i, obj in enumerate(tree.findall("object")):
                name = obj.findtext("name")
                # Junction dots dominate CGHD; subsample them deterministically.
                if name in ["junction", "crossover", "terminal"] and i % 8 != 0:
                    continue
                b = obj.find("bndbox")
                x1, y1, x2, y2 = (int(b.findtext(k)) for k in ["xmin", "ymin", "xmax", "ymax"])
                if x2 - x1 < 3 or y2 - y1 < 3:
                    continue
                margin = max(2, round(min(x2 - x1, y2 - y1) * 0.05))
                crop = image.crop((max(0, x1 - margin), max(0, y1 - margin), min(image.width, x2 + margin), min(image.height, y2 + margin)))
                arrays[split].append(normalize_photo(crop))
                labels[split].append(LABELS.index(MAPPING.get(name, "other")))
                ids[split].append(f"drafter_{writer}/{p.stem}/{i}/{name}")
        print(f"Prepared writer {writer}", flush=True)
    for split in arrays:
        np.savez_compressed(output / f"{split}.npz", images=np.array(arrays[split]), labels=np.array(labels[split]))
        (output / f"{split}-ids.json").write_text(json.dumps(ids[split]))
        print(split, dict(collections.Counter(LABELS[i] for i in labels[split])), flush=True)


def synthetic(label, rng):
    paths = []
    def line(*points): paths.append(list(points))
    def circle(cx, cy, radius, start=0, end=2 * math.pi):
        line(*[(cx + radius * math.cos(t), cy + radius * math.sin(t)) for t in np.linspace(start, end, 45)])
    lead = rng.uniform(12, 32)
    if label == "resistor":
        if rng.random() < 0.5:
            half = rng.uniform(10, 24); height = rng.uniform(5, 11)
            if rng.random() < 0.8: line((-half-rng.uniform(12, 40), 0), (-half, 0))
            line((-half, -height), (half, -height), (half, height), (-half, height), (-half, -height))
            if rng.random() < 0.8: line((half, 0), (half+rng.uniform(12, 40), 0))
        else:
            line((-40, 0), (-23, 0), (-19, -9), (-12, 9), (-5, -9), (2, 9), (9, -9), (16, 9), (23, 0), (40, 0))
    elif label in ["capacitor", "polarizedCapacitor"]:
        gap = rng.uniform(4, 12)
        line((-18, -gap), (18, -gap)); line((0, -gap - lead), (0, -gap))
        if label == "polarizedCapacitor" and rng.random() < 0.6:
            line(*[(x, gap + 5 * (1 - (x / 18) ** 2)) for x in np.linspace(-18, 18, 25)])
        else: line((-18, gap), (18, gap))
        line((0, gap), (0, gap + lead))
        if label == "polarizedCapacitor": line((-24, -gap - 8), (-14, -gap - 8)); line((-19, -gap - 13), (-19, -gap - 3))
    elif label == "inductor":
        line((-40, 0), (-24, 0))
        for j in range(4): circle(-18 + 12 * j, 0, 6, math.pi, 2 * math.pi)
        line((24, 0), (40, 0))
    elif label == "diode":
        line((0, -40), (0, -13)); line((-14, -13), (14, -13), (0, 13), (-14, -13)); line((-15, 13), (15, 13)); line((0, 13), (0, 40))
    elif label == "ground":
        half = rng.uniform(12, 24); gap = rng.uniform(8, 24)
        if rng.random() < 0.6: line((0, -rng.uniform(2, 35)), (0, 0))
        line((-half, rng.uniform(0, 3)), (0, 0), (half, rng.uniform(0, 2)))
        middle = rng.uniform(0.16, 0.65) * half
        offset = rng.uniform(-4, 4); bottom = gap+rng.uniform(6, 15)
        line((offset-middle, gap), (offset+middle, gap))
        offset = rng.uniform(-4, 4)
        if rng.random() < 0.4: line((offset-middle/2, bottom), (offset-middle/2, bottom+3), (offset+middle/2, bottom+2))
        else: line((offset-middle/2, bottom), (offset+middle/2, bottom))
    elif label in ["voltageSource", "acVoltage"]:
        if label == "voltageSource" and rng.random() < 0.5:
            pairs = rng.choice([1, 2, 3])
            for j in range(pairs):
                y = (j - (pairs - 1) / 2) * 18
                line((-22, y - 4), (22, y - 4)); line((-10, y + 4), (10, y + 4))
            line((0, -(pairs - 1) * 9 - 4), (0, -40)); line((0, (pairs - 1) * 9 + 4), (0, 40))
        else:
            circle(0, 0, 23); line((0, -40), (0, -23)); line((0, 23), (0, 40))
            if label == "voltageSource":
                if rng.random() < 0.45:
                    # Unmarked source circles are drafts with a default DC
                    # source type; no value/polarity is inferred for simulation.
                    line((0, -40), (0, 40))
                else: line((-6, -8), (6, -8)); line((0, -14), (0, -2)); line((-6, 9), (6, 9))
            else: line(*[(t, 6 * math.sin(t * math.pi / 12)) for t in np.linspace(-12, 12, 30)])
    elif label == "mos":
        classic = rng.random() < 0.5
        gx = rng.uniform(-20, -10) if classic else rng.uniform(-20, -5)
        half = rng.uniform(16, 24) if classic else rng.uniform(10, 24); cx = 0
        gate_half = half if classic else half * rng.uniform(0.5, 1.1)
        line((gx, -gate_half), (gx-rng.uniform(0, 3), 0), (gx, gate_half))
        line((-40 if classic else gx-rng.uniform(15, 65), 0), (gx, 0))
        if rng.random() < 0.3:
            for y in [-half, -3, half - 7]: line((cx, y), (cx, y + 7))
        else: line((cx, -half), (cx, half))
        dx = 15 if classic else rng.uniform(10, 23); source_x = dx if classic else dx+rng.uniform(-4, 4)
        line((cx, -half + 2), (dx, -half + 2), (dx, -40 if classic else -half-rng.uniform(10, 50)))
        line((cx, half - 2), (source_x, half - 2), (source_x if classic else source_x+rng.uniform(-3, 5), 40 if classic else half+rng.uniform(15, 65)))
        if rng.random() < 0.4: circle(0, 0, 30)
        if rng.random() < 0.5: line((4, half - 6), (10, half - 2), (4, half + 2))
    elif label == "opAmp":
        line((-24, -32), (-24, 32), (30, 0), (-24, -32)); line((-40, -20), (-24, -20)); line((-40, 20), (-24, 20)); line((30, 0), (40, 0)); line((-18, -20), (-10, -20)); line((-18, 20), (-10, 20)); line((-14, 16), (-14, 24))
    else:
        # Wires, unfinished strokes and scribbles belong to a learned reject class.
        for _ in range(rng.randint(1, 4)):
            points = [(rng.uniform(-40, 40), rng.uniform(-40, 40)) for _ in range(rng.randint(2, 5))]
            if rng.random() < 0.6: points = [(points[0][0], points[0][1]), (points[-1][0], points[0][1])]
            line(*points)
    # Render after fitting the whole shape. Long asymmetric leads previously
    # clipped at the training canvas edge although runtime kept every point.
    im = Image.new("L", (384, 384)); draw = ImageDraw.Draw(im)
    angle = rng.randrange(4) * math.pi / 2 + rng.uniform(-0.22, 0.22)
    sx, sy = rng.uniform(0.8, 1.3), rng.uniform(0.8, 1.3)
    flip = rng.choice([-1, 1]); transformed = []
    for path in paths:
        coords = []
        for a, b in zip(path, path[1:]):
            for t in np.linspace(0, 1, max(2, int(math.dist(a, b) / 3))):
                x = (a[0] + (b[0] - a[0]) * t + rng.gauss(0, 0.65)) * sx * flip
                y = (a[1] + (b[1] - a[1]) * t + rng.gauss(0, 0.65)) * sy
                coords.append((x * math.cos(angle) - y * math.sin(angle), x * math.sin(angle) + y * math.cos(angle)))
        if coords: transformed.append(coords)
    points = np.array([p for path in transformed for p in path])
    center = (points.min(0)+points.max(0))/2
    scale = rng.uniform(76, 80) * 4 / max(1, np.ptp(points, axis=0).max())
    width = rng.choice([7, 8, 9, 10, 12, 16])
    for path in transformed:
        coords = [tuple((np.array(p)-center)*scale+192) for p in path]
        draw.line(coords, fill=255, width=width, joint="curve")
        for x, y in [coords[0], coords[-1]]:
            draw.ellipse((x-width/2, y-width/2, x+width/2, y+width/2), fill=255)
    return np.asarray(im.resize((SIDE, SIDE), Image.Resampling.LANCZOS)).copy()


class Crops(Dataset):
    def __init__(self, path, augment=False, synthetic_count=0):
        data = np.load(path); self.images = data["images"]; self.labels = data["labels"]; self.augment = augment
        self.real_count = len(self.labels)
        if synthetic_count:
            rng = random.Random(82413)
            images = [synthetic(label, rng) for label in LABELS for _ in range(synthetic_count)]
            labels = [i for i in range(len(LABELS)) for _ in range(synthetic_count)]
            self.images = np.concatenate([self.images, images]); self.labels = np.concatenate([self.labels, labels])
    def __len__(self): return len(self.labels)
    def __getitem__(self, i):
        image = Image.fromarray(self.images[i])
        if self.augment:
            image = image.rotate(random.randrange(4) * 90 + random.uniform(-12, 12), Image.Resampling.BILINEAR)
            if random.random() < 0.5: image = ImageOps.mirror(image)
            if random.random() < 0.2: image = image.filter(ImageFilter.MaxFilter(3))
            if random.random() < 0.2: image = image.filter(ImageFilter.GaussianBlur(random.uniform(0.1, 0.7)))
            scale = random.uniform(0.8, 1.08)
            size = max(1, round(SIDE * scale)); image = image.resize((size, size), Image.Resampling.BILINEAR)
            frame = Image.new("L", (SIDE, SIDE)); frame.paste(image, ((SIDE - size) // 2 + random.randint(-3, 3), (SIDE - size) // 2 + random.randint(-3, 3))); image = frame
        return torch.from_numpy(np.asarray(image).copy()).float().unsqueeze(0) / 255, int(self.labels[i])


class SmallCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.features = nn.Sequential(nn.Conv2d(1, 16, 5, padding=2), nn.BatchNorm2d(16), nn.ReLU(), nn.MaxPool2d(2), nn.Conv2d(16, 32, 3, padding=1), nn.BatchNorm2d(32), nn.ReLU(), nn.MaxPool2d(2), nn.Conv2d(32, 64, 3, padding=1), nn.BatchNorm2d(64), nn.ReLU(), nn.MaxPool2d(2), nn.AdaptiveAvgPool2d((6, 6)))
        self.classifier = nn.Sequential(nn.Flatten(), nn.Linear(64 * 6 * 6, 128), nn.ReLU(), nn.Dropout(0.25), nn.Linear(128, len(LABELS)))
    def forward(self, x): return self.classifier(self.features(x))


class MobileCNN(nn.Module):
    def __init__(self, pretrained=False):
        super().__init__()
        from torchvision.models import mobilenet_v3_small, MobileNet_V3_Small_Weights
        backbone = mobilenet_v3_small(weights=MobileNet_V3_Small_Weights.IMAGENET1K_V1 if pretrained else None)
        self.features = backbone.features
        self.pool = nn.AdaptiveAvgPool2d((1, 1))
        self.classifier = nn.Sequential(nn.Flatten(), nn.Linear(576, 128), nn.Hardswish(), nn.Dropout(0.2), nn.Linear(128, len(LABELS)))
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).reshape(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).reshape(1, 3, 1, 1))
    def forward(self, x):
        # Stored/input tiles are white ink on black. ImageNet features expect
        # ordinary black ink on white; conversion is baked into the Core ML net.
        rgb = (1 - x).repeat(1, 3, 1, 1)
        return self.classifier(self.pool(self.features((rgb - self.mean) / self.std)))


class EnsembleCNN(nn.Module):
    """One exported Core ML graph averages two independently learned branches."""
    def __init__(self):
        super().__init__(); self.small = SmallCNN(); self.mobile = MobileCNN()
    def forward(self, x):
        return (self.small(x).softmax(1) + self.mobile(x).softmax(1)) / 2


@torch.no_grad()
def predict(model, dataset, device):
    model.eval(); output = []
    for x, _ in DataLoader(dataset, batch_size=128):
        output.append(model(x.to(device)).softmax(1).cpu().numpy())
    return np.concatenate(output)


def report(probabilities, labels, thresholds=None):
    predicted = probabilities.argmax(1); confidence = probabilities.max(1)
    accepted = predicted != 0
    if thresholds:
        accepted &= confidence >= np.array([thresholds[LABELS[p]] for p in predicted])
        ordered = np.sort(probabilities, axis=1)
        accepted &= ordered[:, -1] - ordered[:, -2] >= 0.2
    result = {"samples": len(labels), "accuracy": float(np.mean(predicted == labels)), "accepted": int(accepted.sum()), "accepted_precision": float(np.mean(predicted[accepted] == labels[accepted])) if accepted.any() else 0, "symbol_recall": float(np.sum(accepted & (predicted == labels)) / max(1, np.sum(labels != 0))), "classes": {}}
    for i, label in enumerate(LABELS):
        chosen = accepted & (predicted == i); relevant = labels == i
        result["classes"][label] = {"samples": int(relevant.sum()), "accuracy": float(np.mean(predicted[relevant] == i)) if relevant.any() else 0, "accepted": int(chosen.sum()), "precision": float(np.mean(labels[chosen] == i)) if chosen.any() else 0, "recall": float(np.sum(chosen & relevant) / max(1, relevant.sum()))}
    result["confusion_matrix"] = np.bincount(labels * len(LABELS) + predicted, minlength=len(LABELS) ** 2).reshape(len(LABELS), -1).tolist()
    return result


def choose_thresholds(probabilities, labels):
    thresholds = {label: 0.99 for label in LABELS}; thresholds["other"] = 1.0
    pred = probabilities.argmax(1); conf = probabilities.max(1); ordered = np.sort(probabilities, axis=1)
    for i, label in enumerate(LABELS[1:], 1):
        for t in [0.70, 0.75, 0.80, 0.82, 0.86, 0.90, 0.94, 0.97, 0.99]:
            selected = (pred == i) & (conf >= t) & (ordered[:, -1] - ordered[:, -2] >= 0.2)
            if selected.sum() >= 3 and np.mean(labels[selected] == i) >= 0.95:
                thresholds[label] = t; break
    return thresholds


def ensemble(data, output, small_weights, mobile_weights):
    torch.set_num_threads(6)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = EnsembleCNN(); model.small.load_state_dict(torch.load(small_weights, weights_only=True)); model.mobile.load_state_dict(torch.load(mobile_weights, weights_only=True)); model.to(device).eval()
    def probabilities(dataset):
        arrays = []
        with torch.no_grad():
            for x, _ in DataLoader(dataset, batch_size=128): arrays.append(model(x.to(device)).cpu().numpy())
        return np.concatenate(arrays)
    val_set = Crops(data / "validation.npz"); test_set = Crops(data / "test.npz")
    validation = probabilities(val_set); thresholds = choose_thresholds(validation, val_set.labels)
    # Thresholds/model choice use validation only, before computing test results.
    output.mkdir(parents=True, exist_ok=True); torch.save(model.cpu().state_dict(), output / "weights.pt")
    test_prob = probabilities(test_set) if device.type == "cpu" else None
    if test_prob is None:
        model.to(device); test_prob = probabilities(test_set)
    card = {"model": "CircuitHandwriting v1", "architecture_id": "ensemble", "architecture": "One Core ML graph: small CNN + MobileNetV3-Small features, mean probabilities, 96x96 grayscale", "parameters": sum(p.numel() for p in model.parameters()), "labels": LABELS, "dataset": "CGHD v2", "source": "https://zenodo.org/records/6448277", "data_license": "CC0-1.0", "pretraining": "torchvision MobileNet_V3_Small_Weights.IMAGENET1K_V1", "pretraining_notice": "TorchVision BSD-3-Clause", "writers": WRITERS, "photographs": "P1 only, EXIF-normalized; real object crops", "training_real_counts": dict(collections.Counter(LABELS[i] for i in Crops(data / 'train.npz').labels)), "synthetic_samples_per_class": 900, "thresholds": thresholds, "minimum_margin": 0.2, "validation": report(validation, val_set.labels, thresholds), "test": report(test_prob, test_set.labels, thresholds), "branches": {"small_sha256": hashlib.sha256(small_weights.read_bytes()).hexdigest(), "mobile_sha256": hashlib.sha256(mobile_weights.read_bytes()).hexdigest()}, "selection": "Ensemble chosen by writer-disjoint validation accuracy and MOS coverage; thresholds require at least 3 accepted validation samples and 95% observed precision. This is not a guarantee for new handwriting.", "limitations": ["Photo crop metrics are not physical iPad Pencil or full-circuit detection accuracy.", "There are only 26 real training FET crops and 8 validation FET crops; writer/style generalization remains limited.", "MOS labels do not identify N/P polarity. Automatic drafts default to NMOS; PMOS must be selected.", "Geometric grouping, orientation fitting and wire attachment still require review.", "Low-confidence/unsupported ink is retained. Values are never guessed."]}
    card["sampling"] = "Each class equal mass; other/reject 3x; ground, MOS, DC source 30% real and 70% synthetic; other classes 65% real and 35% synthetic"
    card["selection"] = "Branch checkpoints: equal mean of writer-disjoint real validation macro accuracy and a separate-seed normalized synthetic stroke probe. Ensemble thresholds: real validation precision >=95% on at least 3 accepted samples; otherwise 0.99. Test data does not select checkpoints or thresholds."
    card["branch_training"] = {}
    for branch, checkpoint in [("small", small_weights), ("mobile", mobile_weights)]:
        branch_card = checkpoint.parent / "model-card.json"
        if branch_card.exists():
            metadata = json.loads(branch_card.read_text())
            card["branch_training"][branch] = {key: metadata[key] for key in ["sampling", "selection", "native_validation_probe"] if key in metadata}
    (output / "model-card.json").write_text(json.dumps(card, indent=2)); np.savez_compressed(output / "test-predictions.npz", probabilities=test_prob, labels=test_set.labels)
    print(json.dumps({"thresholds": thresholds, "validation": card['validation'], "test": card['test']}, indent=2), flush=True)


def train(data, output, epochs, resume=None, architecture="tiny"):
    torch.manual_seed(8128); np.random.seed(8128); random.seed(8128)
    torch.set_num_threads(6)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    train_set = Crops(data / "train.npz", True, 900); val_set = Crops(data / "validation.npz"); test_set = Crops(data / "test.npz")
    real_counts = np.bincount(train_set.labels[:train_set.real_count], minlength=len(LABELS))
    # Sample each class equally; within each class real ink receives 65% of
    # sampling mass so rare FET crops are not drowned out by synthetic symbols.
    real_mass = np.full(len(LABELS), 0.65)
    for label in ["ground", "mos", "voltageSource"]: real_mass[LABELS.index(label)] = 0.3
    weights = np.concatenate([real_mass[train_set.labels[:train_set.real_count]] / real_counts[train_set.labels[:train_set.real_count]], (1-real_mass[train_set.labels[train_set.real_count:]]) / 900])
    weights[train_set.labels == 0] *= 3
    loader = DataLoader(train_set, batch_size=128, sampler=WeightedRandomSampler(weights, len(train_set), replacement=True))
    model = (MobileCNN(pretrained=resume is None) if architecture == "mobilenet" else SmallCNN()).to(device)
    if resume: model.load_state_dict(torch.load(resume, map_location=device, weights_only=True))
    groups = [{"params": model.features.parameters(), "lr": 0.00025}, {"params": model.classifier.parameters(), "lr": 0.002}] if architecture == "mobilenet" else model.parameters()
    optimizer = torch.optim.AdamW(groups, lr=0.0006 if resume else 0.0015, weight_decay=0.01)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, epochs, eta_min=0.00008)
    loss_fn = nn.CrossEntropyLoss(label_smoothing=0.01 if architecture == "mobilenet" else 0.03)
    # A separate generator seed checks normalized Pencil-like strokes without
    # treating these synthetic samples as measured human handwriting accuracy.
    native_rng = random.Random(371177)
    native_images = np.array([synthetic(label, native_rng) for label in LABELS for _ in range(80)])
    native_labels = np.repeat(np.arange(len(LABELS)), 80)
    native_set = [(torch.from_numpy(image.copy()).float().unsqueeze(0)/255, int(label)) for image, label in zip(native_images,native_labels)]
    output.mkdir(parents=True, exist_ok=True); best = -1
    print(f"Device {device}; parameters {sum(p.numel() for p in model.parameters())}", flush=True)
    for epoch in range(epochs):
        model.train(); total = 0
        if architecture == "mobilenet":
            for parameter in model.features.parameters(): parameter.requires_grad_(epoch >= 2)
            if epoch < 2: model.features.eval()
        for x, y in loader:
            optimizer.zero_grad(set_to_none=True); logits = model(x.to(device)); loss = loss_fn(logits, y.to(device)); loss.backward(); optimizer.step(); total += loss.item()
        scheduler.step(); probabilities = predict(model, val_set, device)
        summary = report(probabilities, val_set.labels)
        balanced = np.mean([c["accuracy"] for c in summary["classes"].values() if c["samples"]])
        native_accuracy = float(np.mean(predict(model, native_set, device).argmax(1) == native_labels))
        selection = 0.5*balanced + 0.5*native_accuracy
        if selection > best:
            best = selection; torch.save(model.cpu().state_dict(), output / "weights.pt"); model.to(device)
        print(f"Epoch {epoch + 1}/{epochs}: loss {total / len(loader):.4f}, validation accuracy {summary['accuracy']:.3f}, balanced {balanced:.3f}, native synthetic {native_accuracy:.3f}, best {best:.3f}", flush=True)
    model.load_state_dict(torch.load(output / "weights.pt", map_location=device, weights_only=True))
    validation = predict(model, val_set, device)
    # Select thresholds on validation only. Test data never chooses thresholds.
    thresholds = {label: 0.9 for label in LABELS}; thresholds["other"] = 1.0
    pred = validation.argmax(1); conf = validation.max(1); ordered = np.sort(validation, axis=1)
    for i, label in enumerate(LABELS[1:], 1):
        for t in [0.82, 0.86, 0.90, 0.94, 0.97, 0.99]:
            selected = (pred == i) & (conf >= t) & (ordered[:, -1] - ordered[:, -2] >= 0.2)
            if selected.sum() >= 3 and np.mean(val_set.labels[selected] == i) >= 0.95:
                thresholds[label] = t; break
        else: thresholds[label] = 0.99
    test_prob = predict(model, test_set, device)
    card = {"model": "CircuitHandwriting v1", "architecture": "3-layer CNN, 96x96 grayscale, 128-unit classifier", "parameters": sum(p.numel() for p in model.parameters()), "labels": LABELS, "dataset": "CGHD v2", "source": "https://zenodo.org/records/6448277", "license": "CC0-1.0 (DFKI repository LICENSE)", "photographs": "P1 only, EXIF-normalized; object crops", "writers": WRITERS, "training_counts": dict(collections.Counter(LABELS[i] for i in train_set.labels)), "synthetic_samples_per_class": 900, "thresholds": thresholds, "minimum_margin": 0.2, "validation": report(validation, val_set.labels, thresholds), "test": report(test_prob, test_set.labels, thresholds), "limitations": ["Real photograph crop evaluation is not physical iPad Pencil accuracy or full-circuit detection accuracy.", "MOS family has no N/P polarity labels; user selects polarity, automatic drafts default to NMOS.", "Grouping and pin placement remain geometric; text, unsupported and low-confidence ink is retained.", "Small numbers of real FET/source/amplifier examples limit generalization."]}
    card["architecture_id"] = architecture
    if architecture == "mobilenet":
        card["architecture"] = "MobileNetV3-Small features, 96x96 grayscale, 128-unit classifier"
        card["pretraining"] = "torchvision MobileNet_V3_Small_Weights.IMAGENET1K_V1"
    (output / "model-card.json").write_text(json.dumps(card, indent=2))
    card["epochs"] = epochs
    card["initialization"] = {"warm_start_sha256": hashlib.sha256(resume.read_bytes()).hexdigest()} if resume else "random"
    if architecture == "mobilenet" and resume is None:
        card["initialization"] = "ImageNet1K pretrained backbone; random 128-unit classifier"
    card["sampling"] = "Each class equal mass; other/reject 3x; ground, MOS, DC source 30% real and 70% native synthetic; other classes 65% real and 35% synthetic"
    card["selection"] = "Equal mean of real writer-disjoint validation macro accuracy and separate-seed normalized synthetic stroke accuracy; test data does not select checkpoints"
    card["native_validation"] = {"seed":371177,"samples":880,"accuracy":float(np.mean(predict(model,native_set,device).argmax(1)==native_labels)),"synthetic_not_human_accuracy":True}
    (output / "model-card.json").write_text(json.dumps(card, indent=2))
    np.savez_compressed(output / "test-predictions.npz", probabilities=test_prob, labels=test_set.labels)
    print(json.dumps({"thresholds": thresholds, "test": card["test"]}, indent=2), flush=True)


def export(output):
    import coremltools as ct
    card = json.loads((output / "model-card.json").read_text())
    architecture = card.get("architecture_id")
    model = EnsembleCNN() if architecture == "ensemble" else MobileCNN() if architecture == "mobilenet" else SmallCNN()
    model.load_state_dict(torch.load(output / "weights.pt", map_location="cpu", weights_only=True)); model.eval()
    classifier = model if architecture == "ensemble" else nn.Sequential(model, nn.Softmax(dim=1)).eval()
    traced = torch.jit.trace(classifier, torch.zeros(1, 1, SIDE, SIDE))
    ml = ct.convert(traced, inputs=[ct.ImageType(name="ink", shape=(1, 1, SIDE, SIDE), color_layout=ct.colorlayout.GRAYSCALE, scale=1 / 255.0)], classifier_config=ct.ClassifierConfig(LABELS), convert_to="neuralnetwork", minimum_deployment_target=ct.target.iOS14)
    ml = ct.models.neural_network.quantization_utils.quantize_weights(ml, nbits=16)
    ml.author = "Circuit Studio"; ml.short_description = "Offline hand-drawn circuit symbol CNN trained with CGHD writer-disjoint data and jittered strokes."
    ml.license = "Circuit Studio modifications MIT; TorchVision pretraining BSD-3-Clause; CGHD training data CC0-1.0" if architecture in ["mobilenet", "ensemble"] else "MIT (model weights); CGHD training data CC0-1.0"
    ml.user_defined_metadata["dataset"] = json.dumps(WRITERS)
    card = json.loads((output / "model-card.json").read_text())
    ml.user_defined_metadata["thresholds"] = json.dumps(card["thresholds"])
    ml.user_defined_metadata["minimum_margin"] = str(card["minimum_margin"])
    ml.save(str(output / "CircuitHandwriting.mlmodel"))
    card = json.loads((output / "model-card.json").read_text()); card["model_bytes"] = (output / "CircuitHandwriting.mlmodel").stat().st_size; card["sha256"] = hashlib.sha256((output / "CircuitHandwriting.mlmodel").read_bytes()).hexdigest()
    (output / "model-card.json").write_text(json.dumps(card, indent=2))
    print(f"Exported {card['model_bytes']} bytes", flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(); p.add_argument("command", choices=["prepare", "train", "ensemble", "export"]); p.add_argument("--data", type=pathlib.Path, required=True); p.add_argument("--output", type=pathlib.Path, required=True); p.add_argument("--epochs", type=int, default=40); p.add_argument("--resume", type=pathlib.Path); p.add_argument("--architecture", choices=["tiny", "mobilenet"], default="mobilenet"); p.add_argument("--small-weights", type=pathlib.Path); p.add_argument("--mobile-weights", type=pathlib.Path); a = p.parse_args()
    if a.command == "prepare": prepare(a.data, a.output)
    elif a.command == "train": train(a.data, a.output, a.epochs, a.resume, a.architecture)
    elif a.command == "ensemble":
        if not a.small_weights or not a.mobile_weights: p.error("ensemble requires --small-weights and --mobile-weights")
        ensemble(a.data, a.output, a.small_weights, a.mobile_weights)
    else: export(a.output)
