#!/bin/bash
set -euo pipefail

export WORKSPACE=/home/lg/working_dir
export HOME=/home/lg/working_dir
export PATH="${WORKSPACE}/chromium/src/third_party/llvm-build/Release+Asserts/bin:${WORKSPACE}/depot_tools:/usr/local/go/bin:${PATH}"

# Setup git identity & permissions inside container
git config --global user.name "Cromite Builder"
git config --global user.email "builder@cromite.local"
git config --global --add safe.directory "*"

# Bootstrap depot_tools Python for gn
mkdir -p "${WORKSPACE}/depot_tools"
echo "../../../../../usr/bin" > "${WORKSPACE}/depot_tools/python3_bin_reldir.txt"

cd "${WORKSPACE}/chromium/src"

echo "=== Step 1: Flattening nested submodules for patch application ==="
for subrepo in v8 third_party/devtools-frontend third_party/skia third_party/perfetto third_party/boringssl; do
  if [ -d "${subrepo}" ]; then
    rm -rf "${subrepo}/.git" "${subrepo}/src/.git" 2>/dev/null || true
    cp -r "${subrepo}" "${subrepo}-tmp"
    git rm -rf "${subrepo}" >/dev/null 2>&1 || true
    git submodule deinit -f "${subrepo}" >/dev/null 2>&1 || true
    rm -rf "${subrepo}"
    mv "${subrepo}-tmp" "${subrepo}"
    git add -f "${subrepo}" >/dev/null 2>&1 || true
    git commit -m ":NOEXPORT: flatten ${subrepo}" >/dev/null 2>&1 || true
  fi
done
git prune >/dev/null 2>&1 || true

echo "=== Step 2: Preparing Bare Browser bundled extension assets ==="
mkdir -p "${WORKSPACE}/chromium/src/chrome/browser/resources/bare"
if [ -f "${WORKSPACE}/cromite/build/uBlockOrigin-1.75.0.crx" ]; then
  cp "${WORKSPACE}/cromite/build/uBlockOrigin-1.75.0.crx"      "${WORKSPACE}/chromium/src/chrome/browser/resources/bare/ublock_origin.crx"
  echo "Bundled uBlock Origin CRX copied successfully."
else
  echo "Notice: uBlock Origin CRX not found at build/uBlockOrigin-1.75.0.crx"
fi

echo "=== Step 3: Applying Cromite & Bare Browser patches ==="
PATCH_LIST="${WORKSPACE}/cromite/build/cromite_patches_list.txt"
PATCH_DIR="${WORKSPACE}/cromite/build/patches"

FAILED_PATCHES=()
APPLIED_COUNT=0

while IFS= read -r line || [ -n "$line" ]; do
  patch_file="$(echo "$line" | sed 's/^[ 	]*//;s/[ 	]*$//')"
  case "$patch_file" in
    ""|\#*) continue ;;
  esac

  if [[ -f "${PATCH_DIR}/${patch_file}" ]]; then
    echo "--> Applying ${patch_file}..."
    REPL="0,/^---/s//FILE:$(basename "${patch_file}")
---/"
    if sed "$REPL" "${PATCH_DIR}/${patch_file}" | git am -3 >/dev/null 2>&1; then
      APPLIED_COUNT=$((APPLIED_COUNT + 1))
    else
      echo "::warning::Patch failed to apply: ${patch_file}"
      git am --abort >/dev/null 2>&1 || true
      FAILED_PATCHES+=("${patch_file}")
      if [ "${CONTINUE_ON_PATCH_ERROR:-true}" != "true" ]; then
        echo "::error::Halting build because ${patch_file} failed to apply."
        exit 1
      fi
    fi
  else
    echo "::warning::Patch file not found: ${patch_file}"
  fi
done < "$PATCH_LIST"

echo "Total patches applied successfully: ${APPLIED_COUNT}"
if [ ${#FAILED_PATCHES[@]} -gt 0 ]; then
  echo "Non-critical patches that did not apply: ${#FAILED_PATCHES[@]}"
  for p in "${FAILED_PATCHES[@]}"; do
    echo "  - ${p}"
  done
fi

echo "=== Step 4: Configuring GN build arguments ==="
mkdir -p "out/${ANDROID_ARCH}"

GN_ARGS="target_os="android" target_cpu="${ANDROID_ARCH}""
if [ -f "${WORKSPACE}/cromite/build/cromite.gn_args" ]; then
  GN_ARGS="${GN_ARGS} $(cat "${WORKSPACE}/cromite/build/cromite.gn_args")"
fi

if [ "${FAST_BUILD:-true}" = "true" ]; then
  echo "Applying fast build optimizations (symbol_level=0, blink_symbol_level=0, chrome_pgo_phase=0)..."
  GN_ARGS="${GN_ARGS} is_official_build=false chrome_pgo_phase=0 symbol_level=0 blink_symbol_level=0"
fi

if [ "${TARGET_ISDEBUG:-false}" = "true" ]; then
  GN_ARGS="${GN_ARGS} is_debug=true"
else
  GN_ARGS="${GN_ARGS} is_debug=false"
fi

echo "Configured GN args: ${GN_ARGS}"
gn gen "out/${ANDROID_ARCH}" --args="${GN_ARGS}"

echo "=== Step 5: Compiling ChromePublic APK with Ninja ==="
python3 "${WORKSPACE}/depot_tools/siso.py" ninja -C "out/${ANDROID_ARCH}" chrome_public_apk --offline

echo "=== Step 6: Packaging APK ==="
APK_SRC="out/${ANDROID_ARCH}/apks/ChromePublic.apk"
if [ -f "$APK_SRC" ]; then
  cp "$APK_SRC" "/out/ChromePublic-${ANDROID_ARCH}.apk"
  echo "Successfully created /out/ChromePublic-${ANDROID_ARCH}.apk"
  ls -lh "/out/ChromePublic-${ANDROID_ARCH}.apk"
else
  echo "Scanning for built APKs..."
  find "out/${ANDROID_ARCH}" -name "*.apk" -exec cp {} /out/ \;
  ls -lh /out/
fi

echo "=== Build completed successfully ==="
