"""Verify the shipped FP16 Core ML graph against held-out Torch predictions."""
import argparse
import json
import pathlib
import numpy as np
from PIL import Image
import coremltools as ct
from train import LABELS, report

p = argparse.ArgumentParser()
p.add_argument("--data", type=pathlib.Path, required=True)
p.add_argument("--model", type=pathlib.Path, required=True)
a = p.parse_args()
card_path = a.model / "model-card.json"
card = json.loads(card_path.read_text())
data = np.load(a.data / "test.npz")
reference = np.load(a.model / "test-predictions.npz")["probabilities"]
model = ct.models.MLModel(str(a.model / "CircuitHandwriting.mlmodel"))
output = model.get_spec().description.predictedProbabilitiesName
actual = []
for i, pixels in enumerate(data["images"]):
    prediction = model.predict({"ink": Image.fromarray(pixels)})[output]
    actual.append([prediction[label] for label in LABELS])
    if (i + 1) % 1000 == 0:
        print(f"Verified {i + 1}/{len(data['images'])} exported predictions", flush=True)
actual = np.array(actual)
card["coreml_test"] = report(actual, data["labels"], card["thresholds"])
card["export_verification"] = {"samples": len(actual), "top_label_agreement": float(np.mean(actual.argmax(1) == reference.argmax(1))), "maximum_probability_error": float(np.max(np.abs(actual - reference))), "weight_precision": "FP16", "host": "macOS Core ML; physical iPad not benchmarked"}
card_path.write_text(json.dumps(card, indent=2))
print(json.dumps(card["export_verification"], indent=2), flush=True)
