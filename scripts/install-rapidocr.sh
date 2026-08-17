#!/bin/sh
set -eu
umask 022

python_bin=${1:-python3.12}
target_dir=${2:-/opt/hikari/ocr-venv}

"$python_bin" -m venv "$target_dir"
"$target_dir/bin/python" -m pip install --disable-pip-version-check --upgrade pip
"$target_dir/bin/python" -m pip install --disable-pip-version-check \
  rapidocr==3.9.2 onnxruntime==1.28.0

# rapidocr currently depends on the GUI OpenCV wheel. Servers do not ship
# libGL, so replace it with the ABI-compatible headless build after dependency
# resolution rather than keeping both wheels installed.
"$target_dir/bin/python" -m pip uninstall -y opencv-python
"$target_dir/bin/python" -m pip install --disable-pip-version-check \
  opencv-python-headless==5.0.0.93

"$target_dir/bin/rapidocr" check
