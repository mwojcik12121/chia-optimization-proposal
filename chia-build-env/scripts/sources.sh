#!/usr/bin/env bash
set -Eeuo pipefail

readonly SRC_ROOT=/build/src
readonly WHEEL_ROOT=/build/wheels
readonly WHEEL_ALL="${WHEEL_ROOT}/all"
readonly RUNTIME_ROOT=/build/runtime
readonly WHEEL_MAP=/build/wheels.tsv
readonly INSTALL_ROOT=/opt/chia-blockchain
readonly VENV="${INSTALL_ROOT}/.venv"
readonly BUILD_JOBS="${BUILD_JOBS:-1}"

export PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1
export CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS}"
export CARGO_BUILD_JOBS="${BUILD_JOBS}"
export NUM_JOBS="${BUILD_JOBS}"
export MAX_JOBS="${BUILD_JOBS}"
export MAKEFLAGS="-j${BUILD_JOBS}"
export CARGO_INCREMENTAL=0
export BUILD_VDF_CLIENT=Y
export BUILD_VDF_BENCH=N
export CP_USE_GREEN_REAPER=0
export PIP_DISABLE_PIP_VERSION_CHECK=1

source_die() {
  printf '[source-build][ERROR] %s\n' "$*" >&2
  exit 1
}

source_prepare() {
  rm -rf "${INSTALL_ROOT}" "${WHEEL_ROOT}" "${RUNTIME_ROOT}" /build/cargo-target
  mkdir -p "${INSTALL_ROOT}" "${WHEEL_ALL}" "${RUNTIME_ROOT}" /build/cargo-target
  : > "${WHEEL_MAP}"
  python3 -m venv "${VENV}"
  "${VENV}/bin/python" -m pip install --upgrade pip wheel
}

source_repository() {
  local name="${1:?repository name missing}"
  printf '%s/%s\n' "${SRC_ROOT}" "${name}"
}

source_scm_environment_name() {
  local distribution="${1:?distribution missing}"
  distribution="${distribution^^}"
  distribution="$(sed -E 's/[._-]+/_/g' <<<"${distribution}")"
  printf 'SETUPTOOLS_SCM_PRETEND_VERSION_FOR_%s\n' "${distribution}"
}

source_fallback_version() {
  local repository="${1:?repository path missing}"
  local metadata_file basename version

  for metadata_file in "${repository}/PKG-INFO" "${repository}/METADATA"; do
    if [[ -f "${metadata_file}" ]]; then
      version="$(sed -n 's/^Version:[[:space:]]*//p' "${metadata_file}" | head -n 1)"
      if [[ -n "${version}" ]]; then
        printf '%s\n' "${version}"
        return 0
      fi
    fi
  done

  if [[ -f "${repository}/.git_archival.txt" ]]; then
    version="$(sed -nE \
      's/^describe-name:[[:space:]]*[vV]?([0-9]+([.][0-9A-Za-z]+)*([+._-][0-9A-Za-z.-]+)?).*$/\1/p' \
      "${repository}/.git_archival.txt" | head -n 1)"
    if [[ -n "${version}" ]]; then
      printf '%s\n' "${version}"
      return 0
    fi
  fi

  basename="$(basename "${repository}")"
  if [[ "${basename}" =~ [-_]([vV]?[0-9]+([.][0-9A-Za-z]+)+([+._-][0-9A-Za-z.-]+)?)$ ]]; then
    version="${BASH_REMATCH[1]}"
    version="${version#v}"
    version="${version#V}"
    printf '%s\n' "${version}"
    return 0
  fi

  if [[ -f "${repository}/pyproject.toml" ]]; then
    version="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${repository}/pyproject.toml" | head -n 1)"
    if [[ -n "${version}" ]]; then
      printf '%s\n' "${version}"
      return 0
    fi
  fi

  printf '%s\n' '0.0.0'
}

source_has_usable_git_metadata() {
  local repository="${1:?repository path missing}"
  git -C "${repository}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git -C "${repository}" rev-parse --verify HEAD >/dev/null 2>&1
}

source_prepare_repository() {
  local repository="${1:?repository path missing}"
  if git -C "${repository}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git config --global --add safe.directory "${repository}"
    git -C "${repository}" submodule update --init --recursive
    git -C "${repository}" clean -ffdX -q
  fi
}

source_apply_compatibility_patches() {
  local repository="${1:?repository path missing}"
  local distribution="${2:?distribution missing}"
  local pyproject="${repository}/pyproject.toml"

  if [[ "${distribution}" == chia-blockchain && -f "${pyproject}" ]]; then
    # zstd 1.5.7.3 was yanked for being non-thread-safe. Keep future fixed
    # releases eligible while falling back to the latest safe prior release.
    sed -i \
      's/^zstd = ">=1\.5\.7\.3"$/zstd = ">=1.5.7.2, !=1.5.7.3"/' \
      "${pyproject}"
  fi
}

source_stage_executable() {
  local repository="${1:?repository path missing}"
  local distribution="${2:?distribution missing}"
  local filename="${3:?executable filename missing}"
  local candidate destination

  if [[ "${filename}" == '-' ]]; then
    printf '%s\n' '-'
    return 0
  fi

  while IFS= read -r candidate; do
    if file "${candidate}" | grep -Eq 'ELF .* executable'; then
      destination="${RUNTIME_ROOT}/${distribution}/${filename}"
      mkdir -p "$(dirname "${destination}")"
      install -m 0755 "${candidate}" "${destination}"
      printf '%s\n' "${destination}"
      return 0
    fi
  done < <(find "${repository}" -type f -name "${filename}" -perm /111 ! -path '*/.git/*' -print)

  source_die "${distribution} did not produce ${filename}"
}

source_install_chialisp_alias() {
  local site_packages
  site_packages="$(find "${VENV}/lib" -type d -name site-packages -print -quit)"
  [[ -n "${site_packages}" ]] || source_die 'Python site-packages directory is missing'
  [[ -d "${site_packages}/chialisp" ]] || source_die 'the source-built chialisp package is missing'
  rm -rf "${site_packages}/clvm_tools_rs"
  ln -s chialisp "${site_packages}/clvm_tools_rs"
}

source_build_one() {
  local name="${1:?repository name missing}"
  local distribution="${2:?distribution missing}"
  local import_name="${3:?import name missing}"
  local build_subdirectory="${4:?build subdirectory missing}"
  local runtime_filename="${5:?runtime filename missing}"
  local repository build_path output wheel runtime_path
  local scm_environment scm_overrides_environment fallback_version
  local -a wheels=()

  repository="$(source_repository "${name}")"
  build_path="${repository}"
  [[ "${build_subdirectory}" == '.' ]] || build_path="${repository}/${build_subdirectory}"
  source_prepare_repository "${repository}"
  source_apply_compatibility_patches "${repository}" "${distribution}"

  scm_environment="$(source_scm_environment_name "${distribution}")"
  scm_overrides_environment="${scm_environment/PRETEND_VERSION/OVERRIDES}"
  if ! source_has_usable_git_metadata "${repository}"; then
    fallback_version="$(source_fallback_version "${repository}")"
    export SETUPTOOLS_SCM_PRETEND_VERSION="${fallback_version}"
    export "${scm_environment}=${fallback_version}"
    # Source-file discovery also reads the fallback when the version is pretended.
    export "${scm_overrides_environment}={fallback_version = \"${fallback_version}\"}"
    export POETRY_DYNAMIC_VERSIONING_BYPASS="${fallback_version}"
  fi

  export CARGO_TARGET_DIR="/build/cargo-target/${distribution}"
  rm -rf "${CARGO_TARGET_DIR}"
  output="${WHEEL_ROOT}/${distribution}"
  rm -rf "${output}"
  mkdir -p "${output}"

  "${VENV}/bin/python" -m pip wheel \
    --no-deps \
    --wheel-dir "${output}" \
    "${build_path}"

  unset SETUPTOOLS_SCM_PRETEND_VERSION
  unset "${scm_environment}"
  unset "${scm_overrides_environment}"
  unset POETRY_DYNAMIC_VERSIONING_BYPASS

  mapfile -t wheels < <(find "${output}" -maxdepth 1 -type f -name '*.whl' | sort)
  (( ${#wheels[@]} == 1 )) || source_die "${distribution} did not produce exactly one wheel"
  wheel="${wheels[0]}"
  cp "${wheel}" "${WHEEL_ALL}/"
  "${VENV}/bin/python" -m pip install --no-deps --force-reinstall "${wheel}"
  if [[ "${distribution}" == 'chialisp' ]]; then
    source_install_chialisp_alias
  fi

  runtime_path="$(source_stage_executable "${repository}" "${distribution}" "${runtime_filename}")"
  printf '%s|%s|%s|%s|%s\n' \
    "${distribution}" "${wheel}" "${import_name}" "${runtime_filename}" "${runtime_path}" \
    >> "${WHEEL_MAP}"
}

source_normalize_distribution() {
  local name="${1:?distribution name missing}"
  name="${name,,}"
  name="${name//_/-}"
  name="${name//./-}"
  while [[ "${name}" == *--* ]]; do
    name="${name//--/-}"
  done
  printf '%s\n' "${name}"
}

source_external_requirements() {
  local distribution wheel import_name runtime_filename runtime_path requirement name normalized
  declare -A local_distributions=()
  declare -A external=()

  while IFS='|' read -r distribution wheel import_name runtime_filename runtime_path; do
    local_distributions["$(source_normalize_distribution "${distribution}")"]=1
  done < "${WHEEL_MAP}"
  local_distributions[clvm-tools-rs]=1

  while IFS='|' read -r distribution wheel import_name runtime_filename runtime_path; do
    while IFS= read -r requirement; do
      [[ -n "${requirement}" ]] || continue
      name="$(sed -E 's/^([A-Za-z0-9_.-]+).*/\1/' <<<"${requirement}")"
      normalized="$(source_normalize_distribution "${name}")"
      [[ -v "local_distributions[${normalized}]" ]] && continue
      external["${requirement}"]=1
    done < <(unzip -p "${wheel}" '*.dist-info/METADATA' 2>/dev/null | sed -n 's/^Requires-Dist: //p')
  done < "${WHEEL_MAP}"

  if (( ${#external[@]} > 0 )); then
    printf '%s\n' "${!external[@]}" | sort
  fi
}

source_install_runtime() {
  local distribution wheel import_name runtime_filename runtime_path module_directory site_packages
  local -a requirements=()

  mapfile -t requirements < <(source_external_requirements)
  if (( ${#requirements[@]} > 0 )); then
    "${VENV}/bin/python" -m pip install "${requirements[@]}"
  fi

  while IFS='|' read -r distribution wheel import_name runtime_filename runtime_path; do
    "${VENV}/bin/python" -m pip install --no-deps --force-reinstall "${wheel}"
    if [[ "${distribution}" == 'chialisp' ]]; then
      source_install_chialisp_alias
    fi
    if [[ "${runtime_filename}" != '-' ]]; then
      site_packages="$(find "${VENV}/lib" -type d -name site-packages -print -quit)"
      [[ -n "${site_packages}" ]] || source_die 'Python site-packages directory is missing'
      if [[ -d "${site_packages}/${import_name}" ]]; then
        module_directory="${site_packages}/${import_name}"
      else
        [[ -n "$(find "${site_packages}" -maxdepth 1 -name "${import_name}*.so" -print -quit)" ]] \
          || source_die "installed module is missing: ${import_name}"
        module_directory="${site_packages}"
      fi
      install -m 0755 "${runtime_path}" "${module_directory}/${runtime_filename}"
      ln -sfn "${module_directory}/${runtime_filename}" "${INSTALL_ROOT}/${runtime_filename}"
    fi
  done < "${WHEEL_MAP}"

  ln -sfn .venv/bin/activate "${INSTALL_ROOT}/activate"
  ln -sfn .venv/bin/chia "${INSTALL_ROOT}/chia"
}

source_build_all() {
  source_build_one "${REPO_CLVM_RS}" clvm-rs clvm_rs wheel -
  source_build_one "${REPO_CHIA_RS}" chia-rs chia_rs wheel -
  source_build_one "${REPO_CLVM}" clvm clvm . -
  source_build_one "${REPO_CHIALISP}" chialisp chialisp . -
  source_build_one "${REPO_CLVM_TOOLS}" clvm-tools clvm_tools . -
  source_build_one "${REPO_CHIA_PUZZLES}" chia-puzzles-py chia_puzzles_py . -
  source_build_one "${REPO_CHIABIP158}" chiabip158 chiabip158 . -
  source_build_one "${REPO_CHIAPOS}" chiapos chiapos . -
  source_build_one "${REPO_CHIAVDF}" chiavdf chiavdf . vdf_client
  source_build_one "${REPO_CHIA_BLOCKCHAIN}" chia-blockchain chia . -
}

main() {
  source_prepare
  source_build_all
  source_install_runtime
}

main "$@"
