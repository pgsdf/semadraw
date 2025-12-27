set -eu

echo "=== Building ==="
zig build

echo ""
echo "=== Running Unit Tests ==="
zig build test

echo ""
echo "=== Running Malformed Input Tests ==="
./zig-out/bin/sdcs_test_malformed

echo ""
echo "=== Running Golden Image Tests ==="

mkdir -p tests/out
./zig-out/bin/sdcs_make_test tests/out/test.sdcs
./zig-out/bin/sdcs_replay tests/out/test.sdcs tests/out/test.ppm 256 256

./zig-out/bin/sdcs_make_overlap tests/out/overlap.sdcs
./zig-out/bin/sdcs_replay tests/out/overlap.sdcs tests/out/overlap.ppm 256 256

./zig-out/bin/sdcs_make_fractional tests/out/fractional.sdcs
./zig-out/bin/sdcs_replay tests/out/fractional.sdcs tests/out/fractional.ppm 256 256

./zig-out/bin/sdcs_make_clip tests/out/clip.sdcs
./zig-out/bin/sdcs_replay tests/out/clip.sdcs tests/out/clip.ppm 256 256

./zig-out/bin/sdcs_make_transform tests/out/transform.sdcs
./zig-out/bin/sdcs_replay tests/out/transform.sdcs tests/out/transform.ppm 256 256

./zig-out/bin/sdcs_make_blend tests/out/blend.sdcs
./zig-out/bin/sdcs_replay tests/out/blend.sdcs tests/out/blend.ppm 256 256

./zig-out/bin/sdcs_make_stroke tests/out/stroke.sdcs
./zig-out/bin/sdcs_replay tests/out/stroke.sdcs tests/out/stroke.ppm 256 256

./zig-out/bin/sdcs_make_line tests/out/line.sdcs
./zig-out/bin/sdcs_replay tests/out/line.sdcs tests/out/line.ppm 256 256

./zig-out/bin/sdcs_make_join tests/out/join.sdcs
./zig-out/bin/sdcs_replay tests/out/join.sdcs tests/out/join.ppm 256 256

./zig-out/bin/sdcs_make_join_round tests/out/join_round.sdcs
./zig-out/bin/sdcs_replay tests/out/join_round.sdcs tests/out/join_round.ppm 256 256

./zig-out/bin/sdcs_make_cap tests/out/cap.sdcs
./zig-out/bin/sdcs_replay tests/out/cap.sdcs tests/out/cap.ppm 256 256

./zig-out/bin/sdcs_make_cap_round tests/out/cap_round.sdcs
./zig-out/bin/sdcs_replay tests/out/cap_round.sdcs tests/out/cap_round.ppm 256 256

hash_one=""
hash_two=""
hash_three=""
hash_four=""
hash_five=""
hash_six=""
hash_seven=""
hash_eight=""
hash_nine=""
hash_ten=""
hash_eleven=""

if command -v sha256 >/dev/null 2>&1; then
  hash_one=$(sha256 -q tests/out/test.ppm)
  hash_two=$(sha256 -q tests/out/overlap.ppm)
  hash_three=$(sha256 -q tests/out/fractional.ppm)
  hash_four=$(sha256 -q tests/out/clip.ppm)
  hash_five=$(sha256 -q tests/out/transform.ppm)
  hash_six=$(sha256 -q tests/out/blend.ppm)
elif command -v sha256sum >/dev/null 2>&1; then
  hash_one=$(sha256sum tests/out/test.ppm | awk '{print $1}')
  hash_two=$(sha256sum tests/out/overlap.ppm | awk '{print $1}')
  hash_three=$(sha256sum tests/out/fractional.ppm | awk '{print $1}')
  hash_four=$(sha256sum tests/out/clip.ppm | awk '{print $1}')
  hash_five=$(sha256sum tests/out/transform.ppm | awk '{print $1}')
  hash_six=$(sha256sum tests/out/blend.ppm | awk '{print $1}')
else
  echo "sha256 tool not found"
  exit 1
fi

expected_file=tests/golden/golden.sha256
if [ ! -f "$expected_file" ]; then
  echo "$hash_one  test.ppm" > "$expected_file"
  echo "$hash_two  overlap.ppm" >> "$expected_file"
  echo "$hash_three  fractional.ppm" >> "$expected_file"
  echo "$hash_four  clip.ppm" >> "$expected_file"
  echo "$hash_five  transform.ppm" >> "$expected_file"
  echo "$hash_six  blend.ppm" >> "$expected_file"
  echo "golden hashes created at $expected_file"
  exit 0
fi

# Append new entries if the golden file exists but is missing them.
if ! grep -q ' test.ppm$' "$expected_file"; then
  echo "$hash_one  test.ppm" >> "$expected_file"
  echo "added missing golden entry for test.ppm"
  exit 0
fi

if ! grep -q ' overlap.ppm$' "$expected_file"; then
  echo "$hash_two  overlap.ppm" >> "$expected_file"
  echo "added missing golden entry for overlap.ppm"
  exit 0
fi

if ! grep -q ' fractional.ppm$' "$expected_file"; then
  echo "$hash_three  fractional.ppm" >> "$expected_file"
  echo "added missing golden entry for fractional.ppm"
  exit 0
fi

if ! grep -q ' clip.ppm$' "$expected_file"; then
  echo "$hash_four  clip.ppm" >> "$expected_file"
  echo "added missing golden entry for clip.ppm"
  exit 0
fi

if ! grep -q ' transform.ppm$' "$expected_file"; then
  echo "$hash_five  transform.ppm" >> "$expected_file"
  echo "added missing golden entry for transform.ppm"
  exit 0
fi

if ! grep -q ' blend.ppm$' "$expected_file"; then
  echo "$hash_six  blend.ppm" >> "$expected_file"
  echo "added missing golden entry for blend.ppm"
  exit 0
fi

expected_one=$(grep ' test.ppm$' "$expected_file" | awk '{print $1}')
expected_two=$(grep ' overlap.ppm$' "$expected_file" | awk '{print $1}')
expected_three=$(grep ' fractional.ppm$' "$expected_file" | awk '{print $1}')
expected_four=$(grep ' clip.ppm$' "$expected_file" | awk '{print $1}')
expected_five=$(grep ' transform.ppm$' "$expected_file" | awk '{print $1}')
expected_six=$(grep ' blend.ppm$' "$expected_file" | awk '{print $1}')

if [ "$hash_one" != "$expected_one" ]; then
  echo "golden mismatch for test.ppm"
  echo "expected: $expected_one"
  echo "got:      $hash_one"
  exit 1
fi

if [ "$hash_two" != "$expected_two" ]; then
  echo "golden mismatch for overlap.ppm"
  echo "expected: $expected_two"
  echo "got:      $hash_two"
  exit 1
fi

if [ "$hash_three" != "$expected_three" ]; then
  echo "golden mismatch for fractional.ppm"
  echo "expected: $expected_three"
  echo "got:      $hash_three"
  exit 1
fi

if [ "$hash_four" != "$expected_four" ]; then
  echo "golden mismatch for clip.ppm"
  echo "expected: $expected_four"
  echo "got:      $hash_four"
  exit 1
fi

if [ "$hash_five" != "$expected_five" ]; then
  echo "golden mismatch for transform.ppm"
  echo "expected: $expected_five"
  echo "got:      $hash_five"
  exit 1
fi

if [ "$hash_six" != "$expected_six" ]; then
  echo "golden mismatch for blend.ppm"
  echo "expected: $expected_six"
  echo "got:      $hash_six"
  exit 1
fi

echo "Golden image tests passed"

echo ""
echo "=== Determinism Verification ==="
# Run the same SDCS file multiple times and verify identical output
mkdir -p tests/out/determinism

./zig-out/bin/sdcs_make_test tests/out/determinism/test.sdcs
./zig-out/bin/sdcs_replay tests/out/determinism/test.sdcs tests/out/determinism/run1.ppm 256 256
./zig-out/bin/sdcs_replay tests/out/determinism/test.sdcs tests/out/determinism/run2.ppm 256 256
./zig-out/bin/sdcs_replay tests/out/determinism/test.sdcs tests/out/determinism/run3.ppm 256 256

det_hash_1=""
det_hash_2=""
det_hash_3=""

if command -v sha256 >/dev/null 2>&1; then
  det_hash_1=$(sha256 -q tests/out/determinism/run1.ppm)
  det_hash_2=$(sha256 -q tests/out/determinism/run2.ppm)
  det_hash_3=$(sha256 -q tests/out/determinism/run3.ppm)
elif command -v sha256sum >/dev/null 2>&1; then
  det_hash_1=$(sha256sum tests/out/determinism/run1.ppm | awk '{print $1}')
  det_hash_2=$(sha256sum tests/out/determinism/run2.ppm | awk '{print $1}')
  det_hash_3=$(sha256sum tests/out/determinism/run3.ppm | awk '{print $1}')
fi

if [ "$det_hash_1" != "$det_hash_2" ] || [ "$det_hash_1" != "$det_hash_3" ]; then
  echo "FAIL: Determinism check failed - multiple runs produced different output"
  echo "Run 1: $det_hash_1"
  echo "Run 2: $det_hash_2"
  echo "Run 3: $det_hash_3"
  exit 1
fi

echo "Determinism verification passed (3 runs identical)"

echo ""
echo "=== All Tests Passed ==="
