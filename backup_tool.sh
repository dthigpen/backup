#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
trap cleanup SIGINT SIGTERM ERR EXIT

# If switching to zip or another compression/encrtption functions, change the ext here
BACKUP_EXTENSION='.tar.gz.gpg'
TEMP_FILES=()

function usage {
  cat <<EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [backup|restore] [options] file1 file2 ...

Backup and restore files and directories

Available options:

-h, --help      					Print this help and exit
-d, --destination [directory]		Output the archive file or restored files into this directory, otherwise the current directory is used.
EOF
  exit
}

function msg {
  echo >&2 -e "${@}"
}


function cleanup {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
  msg "Cleaning up temporary files before exiting.."
  # remove each temp directory
  for temp_file in "${TEMP_FILES[@]}"
  do
	  if [[ -n "${temp_file}" ]] && [[ -e "${temp_file}" ]]
	  then
	    msg "Removing ${temp_file}"
	    rm -rf "${temp_file}"
	  fi
  done
  msg "Done"
}

function mktemp_dir {
	mktemp -d -t 'backup_tool.XXXXXXXX'
}

function die {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

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

function zip_compress {
	local input_path="${1?Must provide an input path to compress}"
	local output_path="${2?Must provide an output file path}"
	
	local input_path_absolute="$(realpath "${input_path}")"
	local output_path_absolute="$(realpath "${output_path}")"
	local input_dir="$(dirname "${input_path_absolute}")"
	local input_name="$(basename "${input_path_absolute}")"

	pushd "${input_dir}" > /dev/null
	zip -r "${output_path_absolute}" "${input_name}"
	popd > /dev/null
}

function compress {
	local input_path="${1?Must provide an input path to compress}"
	local output_path="${2?Must provide an output file path}"

	targz_compress "${input_path}" "${output_path}"
}

function zip_decompress {
	local input_path="${1?Must provide an input file path to decompress}"
	local output_path="${2:?Must provide an output directory path}"
	unzip  "${input_path}" -d "${output_path}"
}

function targz_decompress {
	local input_path="${1?Must provide an input file path to decompress}"
	local output_path="${2:?Must provide an output directory path}"
	tar -xzvf "${input_path}" -C "${output_path}"
}

function decompress {
	local input_path="${1?Must provide an input file path to decompress}"
	local output_path="${2:?Must provide an output directory path}"
	targz_decompress "${input_path}" "${output_path}"
}

function zip_encrypt {
	local input_path="${1?Must provide a path to encrypt}"
	local output_path="${2?Must provide an output file path}"
	
	local input_path_absolute="$(realpath "${input_path}")"
	local output_path_absolute="$(realpath "${output_path}")"
	local input_dir="$(dirname "${input_path_absolute}")"
	local input_name="$(basename "${input_path_absolute}")"

	pushd "${input_dir}" > /dev/null
	local pwd_args=''
	if [[ "${USE_ENC_PASSWD}" == 'true' ]]
	then
		zip -0 -e --password "{USE_ENC_PASSWD}" -r "${output_path_absolute}" "${input_name}"
	else
		zip -0 -e -r "${output_path_absolute}" "${input_name}"
	fi
	popd > /dev/null
}

function gpg_encrypt {
	local input_path="${1?Must provide a path to encrypt}"
	local output_path="${2?Must provide an output file path}"
	if [[ "${USE_ENC_PASSWD}" == 'true' ]]
	then
		echo "${ENC_PASSWD}" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 --output "${output_path}" "${input_path}"
	else
		gpg --symmetric --cipher-algo AES256 --output "${output_path}" "${input_path}"
	fi
}

function encrypt {
	local input_path="${1?Must provide a path to encrypt}"
	local output_path="${2?Must provide an output file path}"

	gpg_encrypt "${input_path}" "${output_path}"
}

function zip_decrypt {
	local input_path="${1?Must provide a file path to decrypt}"
	local output_path="${2?Must provide an output path}"
	if [[ "${USE_ENC_PASSWD}" == 'true' ]]
	then
		unzip -P "{USE_ENC_PASSWD}" "${input_path}" -d "${output_path}"
	else
		unzip  "${input_path}" -d "${output_path}"
	fi
}

function gpg_decrypt {
	local input_path="${1?Must provide a file path to decrypt}"
	local output_path="${2?Must provide an output path}"
	if [[ "${USE_ENC_PASSWD}" == 'true' ]]
	then
		echo "${ENC_PASSWD}" | gpg --batch --yes --passphrase-fd 0 --output "${output_path}" --decrypt "${input_path}"
	else
		gpg --output "${output_path}" --decrypt "${input_path}"
	fi
}

function decrypt {
	local input_path="${1?Must provide a file path to decrypt}"
	local output_path="${2?Must provide an output path}"

	gpg_decrypt  "${input_path}" "${output_path}"
}

function make_backup {
	local input_path="${1?Must provide an input path}"
	local output_path="${2?Must provide an output path}"
	# create a temporary directory for temp files and track it for later cleanup
	local tmp_dir="$(mktemp_dir)"
	TEMP_FILES+=("${tmp_dir}")
	
	local input_filename="$(basename "${input_path}")"
	local tmp_path="${tmp_dir}/${input_filename}.compressed.tmp"
	compress "${input_path}" "${tmp_path}"
	encrypt "${tmp_path}" "${output_path}"
	rm -f "${tmp_path}"
}

function restore_backup {
	local input_path="${1?Must provide an input path}"
	local output_path="${2?Must provide an output path}"
	# create a temporary directory for temp files and track it for later cleanup
	local tmp_dir="$(mktemp_dir)"
	TEMP_FILES+=("${tmp_dir}")
	
	local input_filename="$(basename "${input_path}")"
	local tmp_path="${tmp_dir}/${input_filename}.compressed.tmp"
	decrypt "${input_path}" "${tmp_path}"
	decompress "${tmp_path}" "${output_path}"
	rm -f "${tmp_path}"
}

function parse_args {
	POSITIONAL_ARGUMENTS=()
	CUSTOM_OUTPUT_DIR=''
	ACTION=''
	FILES_TO_PROCESS=()
	ENC_PASSWD=''
	USE_ENC_PASSWD='false'
	while [[ $# -gt 0 ]]; do
		msg "ARG: ${1-}"
	    case "${1-}" in
		    -h | --help) usage ;;
		   	-d | --destination)
		 		CUSTOM_OUTPUT_DIR="${2-}"
		    	shift
		    	if [[ ! -d "${CUSTOM_OUTPUT_DIR}" ]]
		    	then
					msg "${CUSTOM_OUTPUT_DIR} must be an existing directory"
					exit 1
		    	fi
		    	;;
	    	-p) USE_ENC_PASSWD='true';;
		    -?*) die "Unknown option: $1" ;;
		    *) POSITIONAL_ARGUMENTS+=( "${1-}" ) ;;
	    esac
	    shift
  	done
  	if [[ ${#POSITIONAL_ARGUMENTS[@]} -lt 2 ]]
  	then
		die "Must provide more arguments. See usage with --help"
  	fi

	if [[ "${USE_ENC_PASSWD}" == 'true' ]]
	then
  		local tmp_input=''
  		# TODO add logic to handle verifying password AND looping for non matching or empty input
  		read -s -p 'Enter encryption password: ' ENC_PASSWD
  		msg ''
	fi
  	ACTION="${POSITIONAL_ARGUMENTS[0]}"
	FILES_TO_PROCESS=( "${POSITIONAL_ARGUMENTS[@]:1}" )
}

function main {
	if [[ "${ACTION}" != 'backup' && "${ACTION}" != 'restore' ]]
	then
		die 'First argument must be either "backup" or "restore"'
	fi
	for f in "${FILES_TO_PROCESS[@]}"
	do
		if [[ ! -e "${f}" ]]
		then
			msg "${f} must be an existing file or directory"
			exit 1
		fi
		local input_path="${f}"
		local input_filename="$(basename "${input_path}")"
		local input_dir="$(dirname "${input_path}")"
		local output_dir="${CUSTOM_OUTPUT_DIR:-${PWD}}"
		mkdir -p "${output_dir}"
		local timestamp="$(date +"%Y%m%d%H%M" )"
		if [[ "${ACTION}" == 'backup' ]]
		then
			msg "Reading file or directory to archive at: ${input_path}"
			local backup_output_filename="${input_filename}.backup_${timestamp}${BACKUP_EXTENSION}"
			local backup_output_path="${output_dir}/${backup_output_filename}"
			make_backup "${input_path}" "${backup_output_path}"
		   	msg "Backup file created at: ${backup_output_path}"
		elif [[ "${ACTION}" == 'restore' ]]
		then
			restore_backup "${input_path}" "${output_dir}"
			msg "Restored ${input_path} to directory ${output_dir}"
		fi
	done
}

parse_args "${@}"
main

