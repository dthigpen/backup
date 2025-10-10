#!/usr/bin/env bats

setup() {
  # Create a clean temporary ytest workspace
  TEST_DIR="$(mktemp -d)"
  SAMPLE_FILE="${TEST_DIR}/sample.txt"
  SAMPLE_DIR="${TEST_DIR}/sample_dir"
  mkdir -p "${SAMPLE_DIR}"
  
  echo "Hello Backup World!" > "${SAMPLE_FILE}"
  echo "File A" > "${SAMPLE_DIR}/a.txt"
  echo "File B" > "${SAMPLE_DIR}/b.txt"
  
  BACKUP_TOOL="${BATS_TEST_DIRNAME}/../backup_tool.sh"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# helper: run a backup & restore roundtrip and compare
roundtrip_file() {
  local strategy="$1"
  local src="$2"
  local password="testpass"
  local output_dir="${TEST_DIR}/out_${strategy}"
  local restored_dir="${TEST_DIR}/restored_${strategy}"
  mkdir -p "${output_dir}" "${restored_dir}"
  
  run bash -c "echo '${password}' | '${BACKUP_TOOL}' backup -p -d '${output_dir}' -s '${strategy}' '${src}'"
  [ "$status" -eq 0 ]
  
  local backup_file
  backup_file="$(find "${output_dir}" -type f | head -n1)"
  [ -f "${backup_file}" ]
  
  run bash -c "echo '${password}' | '${BACKUP_TOOL}' restore -p -d '${restored_dir}' -s '${strategy}' '${backup_file}'"
  [ "$status" -eq 0 ]
}

@test "single file round trip (zip_zipenc)" {
  roundtrip_file "zip_zipenc" "${SAMPLE_FILE}"
  restored_file="$(find "${TEST_DIR}/restored_zip_zipenc" -type f -name 'sample.txt')"
  [ -f "${restored_file}" ]
  diff -u "${SAMPLE_FILE}" "${restored_file}"
}

@test "single file round trip (targz_gpg)" {
  roundtrip_file "targz_gpg" "${SAMPLE_FILE}"
  restored_file="$(find "${TEST_DIR}/restored_targz_gpg" -type f -name 'sample.txt')"
  [ -f "${restored_file}" ]
  diff -u "${SAMPLE_FILE}" "${restored_file}"
}

@test "directory round trip (zip_zipenc)" {
  roundtrip_file "zip_zipenc" "${SAMPLE_DIR}"
  restored_dir="$(find "${TEST_DIR}/restored_zip_zipenc" -type d -name 'sample_dir')"
  [ -d "${restored_dir}" ]
  diff -ru "${SAMPLE_DIR}" "${restored_dir}"
}

@test "directory round trip (targz_gpg)" {
  roundtrip_file "targz_gpg" "${SAMPLE_DIR}"
  restored_dir="$(find "${TEST_DIR}/restored_targz_gpg" -type d -name 'sample_dir')"
  [ -d "${restored_dir}" ]
  diff -ru "${SAMPLE_DIR}" "${restored_dir}"
}

@test "temporary files cleaned up after run" {
  roundtrip_file "zip_zipenc" "${SAMPLE_FILE}"
  # search for leftover temp dirs (should be none)
  leftover="$(find /tmp -maxdepth 1 -type d -name 'backup_tool.*' | wc -l)"
  [ "${leftover}" -eq 0 ]
}
