#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
trap cleanup SIGINT SIGTERM ERR EXIT

BACKUP_STRATEGY="zip_zipenc" # default strategy
TEMP_FILES=()

# -------------------------------
# HELPERS
# -------------------------------
function msg() { echo >&2 -e "$@"; }
function die() {
  msg "$1"
  exit "${2:-1}"
}
function mktemp_dir() { mktemp -d -t 'backup_tool.XXXXXXXX'; }
function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  for f in "${TEMP_FILES[@]}"; do
    [[ -n "$f" && -e "$f" ]] && rm -rf "$f"
  done
}

# -------------------------------
# STRATEGY REGISTRY
# -------------------------------
declare -A COMPRESS_FUNCS
declare -A DECOMPRESS_FUNCS
declare -A ENCRYPT_FUNCS
declare -A DECRYPT_FUNCS
declare -A EXTENSIONS

# Register a strategy (compression + encryption)
# usage: register_strategy name compress decompress encrypt decrypt extension
function register_strategy() {
  local name=$1
  shift
  COMPRESS_FUNCS["$name"]=$1
  shift
  DECOMPRESS_FUNCS["$name"]=$1
  shift
  ENCRYPT_FUNCS["$name"]=$1
  shift
  DECRYPT_FUNCS["$name"]=$1
  shift
  EXTENSIONS["$name"]=$1
}

# -------------------------------
# BUILT-IN STRATEGIES
# -------------------------------

# --- zip + zipenc ---
function zip_compress() {
  local input_path="${1?Must provide an input path to compress}"
  local output_path="${2?Must provide an output file path}"

  local input_path_absolute="$(realpath "${input_path}")"
  local output_path_absolute="$(realpath "${output_path}")"
  local input_dir="$(dirname "${input_path_absolute}")"
  local input_name="$(basename "${input_path_absolute}")"

  pushd "${input_dir}" >/dev/null
  zip -r "${output_path_absolute}" "${input_name}"
  popd >/dev/null

}
function zip_decompress() {
  # local in=$1 out=$2
  # unzip "$in" -d "$out"
  local input_path="${1?Must provide an input file path to decompress}"
  local output_path="${2:?Must provide an output directory path}"
  unzip "${input_path}"/* -d "${output_path}"
}
function zip_encrypt() {
  local input_path="${1?Must provide a path to encrypt}"
  local output_path="${2?Must provide an output file path}"

  local input_path_absolute="$(realpath "${input_path}")"
  local output_path_absolute="$(realpath "${output_path}")"
  local input_dir="$(dirname "${input_path_absolute}")"
  local input_name="$(basename "${input_path_absolute}")"
  pushd "${input_dir}" >/dev/null
  local pwd_args=''
  if [[ "${USE_ENC_PASSWD}" == 'true' ]]; then
    zip -0 -e --password "${ENC_PASSWD}" -r "${output_path_absolute}" "${input_name}"
  else
    zip -0 -e -r "${output_path_absolute}" "${input_name}"
  fi
  popd >/dev/null
}
function zip_decrypt() {
  local input_path="${1?Must provide a file path to decrypt}"
  local output_path="${2?Must provide an output path}"
  if [[ "${USE_ENC_PASSWD}" == 'true' ]]; then
    unzip -P "${ENC_PASSWD}" "${input_path}" -d "${output_path}"
  else
    unzip "${input_path}" -d "${output_path}"
  fi
}
register_strategy "zip_zipenc" zip_compress zip_decompress zip_encrypt zip_decrypt ".zip"

# --- tar.gz + gpg ---
function targz_compress {
	local input_path="${1?Must provide an input path to compress}"
	local output_path="${2?Must provide an output file path}"

    local input_path_absolute="$(realpath "${input_path}")"
    local output_path_absolute="$(realpath "${output_path}")"
    local input_dir="$(dirname "${input_path_absolute}")"
    local input_name="$(basename "${input_path_absolute}")"

    pushd "${input_dir}" > /dev/null
    tar -czvf "${output_path}" "${input_name}"
    popd > /dev/null
}
function targz_decompress() {
  local input_path="${1?Must provide an input file path to decompress}"
  local output_path="${2:?Must provide an output directory path}"
  tar -xzvf "${input_path}" -C "${output_path}"
}

function gpg_encrypt() {
  local input_path="${1?Must provide a path to encrypt}"
  local output_path="${2?Must provide an output file path}"
  if [[ "${USE_ENC_PASSWD}" == 'true' ]]; then
    echo "${ENC_PASSWD}" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 --output "${output_path}" "${input_path}"
  else
    gpg --symmetric --cipher-algo AES256 --output "${output_path}" "${input_path}"
  fi
}
function gpg_decrypt() {
  local input_path="${1?Must provide a file path to decrypt}"
  local output_path="${2?Must provide an output path}"
  if [[ "${USE_ENC_PASSWD}" == 'true' ]]; then
    echo "${ENC_PASSWD}" | gpg --batch --yes --passphrase-fd 0 --output "${output_path}" --decrypt "${input_path}"
  else
    gpg --output "${output_path}" --decrypt "${input_path}"
  fi
}

register_strategy "targz_gpg" targz_compress targz_decompress gpg_encrypt gpg_decrypt ".tar.gz.gpg"

# -------------------------------
# STRATEGY WRAPPERS
# -------------------------------
function compress() { ${COMPRESS_FUNCS[$BACKUP_STRATEGY]} "$@"; }
function decompress() { ${DECOMPRESS_FUNCS[$BACKUP_STRATEGY]} "$@"; }
function encrypt() { ${ENCRYPT_FUNCS[$BACKUP_STRATEGY]} "$@"; }
function decrypt() { ${DECRYPT_FUNCS[$BACKUP_STRATEGY]} "$@"; }
function get_ext() { echo "${EXTENSIONS[$BACKUP_STRATEGY]}"; }

# -------------------------------
# BACKUP / RESTORE LOGIC
# -------------------------------
function make_backup() {
  local in=$1 out=$2
  local tmp_dir
  tmp_dir="$(mktemp_dir)"
  TEMP_FILES+=("$tmp_dir")
  local tmp_file="$tmp_dir/$(basename "$in").tmp"
  compress "$in" "$tmp_file"
  encrypt "$tmp_file" "$out"
}

function restore_backup() {
  local in=$1 out=$2
  local tmp_dir
  tmp_dir="$(mktemp_dir)"
  TEMP_FILES+=("$tmp_dir")
  local tmp_file="$tmp_dir/$(basename "$in").tmp"
  decrypt "$in" "$tmp_file"
  decompress "$tmp_file" "$out"
}

# -------------------------------
# CLI
# -------------------------------
function usage() {
  cat <<EOF
Usage: $(basename "$0") [backup|restore] [options] file1 file2 ...
Options:
  -d, --destination DIR    Output directory
  -s, --strategy NAME      Backup strategy (default: $BACKUP_STRATEGY, built-in: zip_zipenc, targz_gpg)
  -p                       Prompt for password (Useful to avoid retyping the same password when passed multiple file arguments)
EOF
  exit
}

function parse_args() {
  POSITIONAL=()
  CUSTOM_OUTPUT_DIR=""
  ACTION=""
  USE_ENC_PASSWD='false'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help) usage ;;
      -d | --destination)
        CUSTOM_OUTPUT_DIR="$2"
        shift
        ;;
      -s | --strategy)
        BACKUP_STRATEGY="$2"
        shift
        ;;
      -p) USE_ENC_PASSWD='true' ;;
      *) POSITIONAL+=("$1") ;;
    esac
    shift
  done

  ACTION="${POSITIONAL[0]}"
  FILES_TO_PROCESS=("${POSITIONAL[@]:1}")
  
  if [[ "${USE_ENC_PASSWD}" == 'true' ]]; then
    # show prompt if running interactively
    if [[ -t 0 ]]; then
      read -s -p 'Enter encryption password: ' ENC_PASSWD
      echo
      if [[ "${ACTION}" == 'backup' ]]; then
        read -s -p "Confirm password: " PASSWORD_CONFIRM
        echo
        if [[ "${ENC_PASSWD}" != "${PASSWORD_CONFIRM}" ]]; then
          echo "Error: Passwords do not match." >&2
          exit 1
        fi
        unset PASSWORD_CONFIRM
      fi
    else
      read -s ENC_PASSWD
    fi
  fi

 
}

function main() {
  [[ -n "${COMPRESS_FUNCS[$BACKUP_STRATEGY]:-}" ]] || die "Unknown strategy: $BACKUP_STRATEGY"

  for f in "${FILES_TO_PROCESS[@]}"; do
    [[ -e "$f" ]] || die "$f must exist"
    local output_dir="${CUSTOM_OUTPUT_DIR:-$PWD}"
    mkdir -p "$output_dir"
    local ts
    ts="$(date +%Y%m%d%H%M)"
    local ext
    ext="$(get_ext)"
    if [[ "$ACTION" == "backup" ]]; then
      local out="${output_dir}/$(basename "$f").backup_${ts}${ext}"
      make_backup "$f" "$out"
      msg "Backup created: $out"
    elif [[ "$ACTION" == "restore" ]]; then
      restore_backup "$f" "$output_dir"
      msg "Restored into: $output_dir"
    else
      die "Unknown action: $ACTION"
    fi
  done
}

parse_args "$@"
main
