#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
trap cleanup SIGINT SIGTERM ERR EXIT

BACKUP_STRATEGY=""
DEFAULT_BACKUP_STRATEGY="zip_zipenc" # default strategy
NEW_BACKUP_STRATEGY=""
NEW_ENC_PASSWD=""
USE_NEW_ENC_PASSWD="false"
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
  local name="${1:?strategy name required}"
  local compress="${2:?compress func required}"
  local decompress="${3:?decompress func required}"
  local encrypt="${4:?encrypt func required}"
  local decrypt="${5:?decrypt func required}"
  local extension="${6:?extension required}"

  [[ -z "${EXTENSIONS[$name]:-}" ]] || die "Strategy already registered: $name"

  COMPRESS_FUNCS["$name"]="$compress"
  DECOMPRESS_FUNCS["$name"]="$decompress"
  ENCRYPT_FUNCS["$name"]="$encrypt"
  DECRYPT_FUNCS["$name"]="$decrypt"
  EXTENSIONS["$name"]="$extension"
}

function strategy_from_path() {
  local path="${1:?path required}"

  for strategy in "${!EXTENSIONS[@]}"; do
    local ext="${EXTENSIONS[$strategy]}"
    if [[ "$path" == *"$ext" ]]; then
      printf '%s\n' "$strategy"
      return 0
    fi
  done

  return 1
}

function resolve_strategy() {
  # 1️⃣ Explicit flag wins
  if [[ -n "${BACKUP_STRATEGY:-}" ]]; then
    [[ -n "${EXTENSIONS[$BACKUP_STRATEGY]:-}" ]] \
      || die "Unknown strategy: $BACKUP_STRATEGY"
    printf '%s\n' "$BACKUP_STRATEGY"
    return
  fi

  # 2️⃣ Infer from first input file (if any)
  local first="${FILES_TO_PROCESS[0]:-}"
  if [[ -n "$first" ]]; then
    if inferred="$(strategy_from_path "$first")"; then
      msg "Inferred strategy '${inferred}' from filename"
      printf '%s\n' "$inferred"
      return
    fi
  fi

  # 3️⃣ Default
  printf '%s\n' "$DEFAULT_BACKUP_STRATEGY"
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
  zip -0 -e --password "${ENC_PASSWD}" -r "${output_path_absolute}" "${input_name}"
  popd >/dev/null
}
function zip_decrypt() {
  local input_path="${1?Must provide a file path to decrypt}"
  local output_path="${2?Must provide an output path}"
  unzip -P "${ENC_PASSWD}" "${input_path}" -d "${output_path}"
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

  pushd "${input_dir}" >/dev/null
  tar -czvf "${output_path}" "${input_name}"
  popd >/dev/null
}
function targz_decompress() {
  local input_path="${1?Must provide an input file path to decompress}"
  local output_path="${2:?Must provide an output directory path}"
  tar -xzvf "${input_path}" -C "${output_path}"
}

function gpg_encrypt() {
  local input_path="${1?Must provide a path to encrypt}"
  local output_path="${2?Must provide an output file path}"
  echo "${ENC_PASSWD}" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 --output "${output_path}" "${input_path}"
}
function gpg_decrypt() {
  local input_path="${1?Must provide a file path to decrypt}"
  local output_path="${2?Must provide an output path}"
  echo "${ENC_PASSWD}" | gpg --batch --yes --passphrase-fd 0 --output "${output_path}" --decrypt "${input_path}"
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

function print_backup() {
  local in=$1
  local tmp_out_dir="$(mktemp_dir)"
  TEMP_FILES+=("${tmp_out_dir}")
  restore_backup "${in}" "${tmp_out_dir}"
  local extracted_path
  extracted_path="$(find "${tmp_out_dir}" -mindepth 1 -maxdepth 2)"

  if [[ -d "${extracted_path}" ]]; then
    die "Cannot print a directory (yet)"
  elif [[ ! -f "${extracted_path}" ]]; then
    ls -l "${tmp_out_dir}"
    die "Not a valid file to print"
  fi
  # TODO later extend with flags like: --path some/file.txt , --list
  cat "${extracted_path}"
}

function rekey_backup() {
  local input_path="$1"
  local output_path="${2:-input_path}"

  local tmp_dir
  tmp_dir="$(mktemp_dir)"
  TEMP_FILES+=("$tmp_dir")

  local decrypted_tmp="${tmp_dir}/tmp_decrypted_dir"
  local reencrypted_tmp="${tmp_dir}/encrypted.tmp"

  # Decrypt with OLD password
  decrypt "$input_path" "$decrypted_tmp"

  # Temporarily swap password
  local OLD_PASSWD="$ENC_PASSWD"
  ENC_PASSWD="$NEW_ENC_PASSWD"

  local decrypted_content
  decrypted_content="$(find "$decrypted_tmp" -mindepth 1 -maxdepth 1 | head -1)"
  encrypt "$decrypted_content" "$reencrypted_tmp"
  mv "${reencrypted_tmp}" "${output_path}"

  ENC_PASSWD="$OLD_PASSWD"
}

function replace_ext() {
  local path="${1:?path required}"
  local new_ext="${2:?new extension required}"

  printf '%s.%s\n' "${path%.*}" "${new_ext#.}"
}

function repack_backup() {
  local input_path="$1"
  local output_path="${2:-input_path}"

  local tmp_dir
  tmp_dir="$(mktemp_dir)"
  TEMP_FILES+=("$tmp_dir")

  local tmp_unpacked_dir="${tmp_dir}/unpacked"
  local tmp_out_file="${tmp_dir}/output.tmp"

  mkdir -p "$tmp_unpacked_dir"

  restore_backup "$input_path" "$tmp_unpacked_dir"

  # Step 2: switch strategy
  local OLD_STRATEGY="$BACKUP_STRATEGY"
  BACKUP_STRATEGY="$NEW_BACKUP_STRATEGY"

  # # Step 3: switch password if provided
  # local OLD_PASSWD="$ENC_PASSWD"
  # ENC_PASSWD="$NEW_ENC_PASSWD"

  # Step 4: re-pack
  local content
  content="$(find "$tmp_unpacked_dir" -mindepth 1 -maxdepth 1 | head -1)"

  make_backup "$content" "$tmp_out_file"
  mv "$tmp_out_file" "$output_path"
  # Restore state
  BACKUP_STRATEGY="$OLD_STRATEGY"
  # ENC_PASSWD="$OLD_PASSWD"
}

function prompt_password() {
  local prompt="${1:-Enter password}"
  local confirm="${2:-false}"
  local __resultvar="${3:?Missing result variable name}"

  local passwd=""
  local confirm_passwd=""

  if [[ -t 0 ]]; then
    read -s -p "${prompt}: " passwd
    echo

    if [[ "${confirm}" == "true" ]]; then
      read -s -p "Confirm password: " confirm_passwd
      echo
      if [[ "${passwd}" != "${confirm_passwd}" ]]; then
        die "Passwords do not match"
      fi
    fi
  else
    # Non-interactive: read once from stdin
    read -s passwd
  fi

  printf -v "${__resultvar}" '%s' "${passwd}"
}

# -------------------------------
# CLI
# -------------------------------
function usage() {
  cat <<EOF
Usage:
  $(basename "$0") <command> [options] <file>...

Commands:
  backup            Create an encrypted backup
  restore           Restore a backup into a directory
  print             Decrypt and print backup contents to stdout
  repack            Re-compress and re-encrypt using a new strategy
  rekey             Re-encrypt using a new password

Options:
  -d, --destination DIR
        Output directory (default: current directory)

  -s, --strategy NAME
        Backup strategy to use.
        If omitted, the strategy is inferred from the input file name.
        Fallback default: zip_zipenc

  -s2, --new-strategy NAME
        Target strategy for repack operations.

  -h, --help
        Show this help message and exit

Notes:
  - Passwords are always prompted for securely.
  - For non-backup commands, the strategy is inferred from the backup file.
  - Built-in strategies:
      - zip_zipenc   (.zip)
      - targz_gpg    (.tar.gz.gpg)

Examples:
  Create a backup:
    $(basename "$0") backup secrets.txt

  Restore a backup:
    $(basename "$0") restore secrets.txt.backup_20250101.zip

  Print secrets to stdout:
    $(basename "$0") print secrets.txt.backup_20250101.zip

  Repack using a different strategy:
    $(basename "$0") repack -s2 targz_gpg secrets.txt.backup_20250101.zip

  Rotate encryption password:
    $(basename "$0") rekey secrets.txt.backup_20250101.zip
EOF
  exit
}

function parse_args() {
  POSITIONAL=()
  CUSTOM_OUTPUT_DIR=""
  ACTION=""
  STDIN_PASSWD="false"
  USE_NEW_ENC_PASSWD="false"
  BACKUP_STRATEGY=""
  NEW_BACKUP_STRATEGY=""

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
      -s2 | --new-strategy)
        NEW_BACKUP_STRATEGY="$2"
        shift
        ;;
      *)
        POSITIONAL+=("$1")
        ;;
    esac
    shift
  done

  ACTION="${POSITIONAL[0]}"
  FILES_TO_PROCESS=("${POSITIONAL[@]:1}")
  BACKUP_STRATEGY="$(resolve_strategy "${BACKUP_STRATEGY}")"
}

function main() {
  [[ -n "${COMPRESS_FUNCS[$BACKUP_STRATEGY]:-}" ]] || die "Unknown strategy: $BACKUP_STRATEGY"

  for f in "${FILES_TO_PROCESS[@]}"; do
    [[ -e "$f" ]] || die "$f must exist"

    local output_dir="${CUSTOM_OUTPUT_DIR:-$PWD}"
    mkdir -p "$output_dir"

    local ts
    ts="$(date +%Y%m%d%H%M)"

    case "$ACTION" in
      backup)
        prompt_password "Enter encryption password" true ENC_PASSWD
        local ext
        ext="$(get_ext)"
        local out="${output_dir}/$(basename "$f").backup_${ts}${ext}"
        make_backup "$f" "$out"
        msg "Backup created: $out"
        ;;
      restore)
        prompt_password "Enter encryption password" false ENC_PASSWD
        restore_backup "$f" "$output_dir"
        msg "Restored into: $output_dir"
        ;;
      print)
        prompt_password "Enter encryption password" false ENC_PASSWD
        print_backup "$f"
        ;;
      rekey)
        prompt_password "Enter existing password" false ENC_PASSWD
        prompt_password "Enter new password" true NEW_ENC_PASSWD
        rekey_backup "$f" "$f"
        ;;
      repack)
        prompt_password "Enter encryption password" false ENC_PASSWD
        [[ -n "$NEW_BACKUP_STRATEGY" ]] || die "--new-strategy required for repack"
        [[ -n "${COMPRESS_FUNCS[$NEW_BACKUP_STRATEGY]:-}" ]] || die "Unknown new strategy"
        # get the original ext and the one it will have to create the output file name
        local old_ext
        old_ext="$(get_ext)"
        local OLD_STRATEGY="$BACKUP_STRATEGY"
        BACKUP_STRATEGY="$NEW_BACKUP_STRATEGY"
        local new_ext
        new_ext="$(get_ext)"
        BACKUP_STRATEGY="$OLD_STRATEGY"
        local out="${f%$old_ext}$new_ext"
        repack_backup "$f" "$out"
        mv "$f" "$f.old"
        msg "Repacked backup created: $out"
        ;;
      *)
        die "Unknown action: $ACTION"
        ;;
    esac
  done
}

parse_args "$@"
main
