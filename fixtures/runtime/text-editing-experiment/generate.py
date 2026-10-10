"""Add field observation metadata without changing the upstream input listeners."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent
source = (root / "text_input.riv").read_bytes()
assert hashlib.sha256(source).hexdigest() == "718b80e13fc25f89c34b66fb01732f7ea1eac924ff06ca6b2caa5ed882324a72"
# At rive-runtime 9ed5b516, the last artboard's TextInput is component ID 4.
# Insert metadata after all components and before the first animation so IDs stay fixed.
assert source[877008:877010] == bytes.fromhex("b904")
assert source[877415] == 31  # LinearAnimation type key.
name = bytes.fromhex("0410") + b"experiment-input"
variants = []
for secure in [False, True]:
    # SemanticData type 668, parent 4, TextField role 6.
    metadata = bytes.fromhex("9c050504d60706")
    if secure:
        metadata += bytes.fromhex("dc078020")  # Serialized stateFlags 988, obscured bit 12.
    metadata += b"\0"
    # TextInput.obscured property 1095 uses the same variant flag as its metadata.
    input_properties = name + (bytes.fromhex("c70801") if secure else b"")
    data = source[:877010] + input_properties + source[877010:877415] + metadata + source[877415:]
    filename = "text_input_secure_observed.riv" if secure else "text_input_observed.riv"
    (root / filename).write_bytes(data)
    variants.append({"file": filename, "sha256": hashlib.sha256(data).hexdigest(),
                     "source": "text_input.riv", "obscured": secure})
provenance = json.loads((root / "provenance.json").read_text())
provenance["observedVariants"] = {
    "generator": "generate.py",
    "operation": "Name TextInput ID 4 experiment-input and append TextField SemanticData before animations. Secure variant sets both TextInput.obscured and semantic isObscured. Input listeners and existing component IDs are unchanged.",
    "sourceDefinitions": ["include/rive/generated/component_base.hpp", "include/rive/generated/text/text_input_base.hpp", "include/rive/generated/semantic/semantic_data_base.hpp"],
    "files": variants,
}
(root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
