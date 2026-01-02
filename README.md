# Backup Tool

A simple file backup solution with no fancy features

## Usage

Download `backup_tool.sh` from this repository and make sure its executable with `chmod u+x backup_tool.sh`.

Get help with
```bash
$ ./backup_tool.sh --help
Usage:
  backup_tool.sh <command> [options] <file>...

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
    backup_tool.sh backup secrets.txt

  Restore a backup:
    backup_tool.sh restore secrets.txt.backup_20250101.zip

  Print secrets to stdout:
    backup_tool.sh print secrets.txt.backup_20250101.zip

  Repack using a different strategy:
    backup_tool.sh repack -s2 targz_gpg secrets.txt.backup_20250101.zip

  Rotate encryption password:
    backup_tool.sh rekey secrets.txt.backup_20250101.zip
```

Backing up a directory or file to the ~/backups directory
```bash
$ ./backup_tool.sh backup /path/to/important/dir -d ~/backups
```

Restoring files from a backup file to /path/to/important/dir
```bash
$ ./backup_tool.sh restore ~/backups/important_dir.backup.zip -d /path/to/important/dir 
```

Print a single file backup to stdout
```bash
$ ./backup_tool.sh print ~/backups/important_dir.backup.zip
```

You can make multiple backup files and restore multiple backups by passing multiple directories or files.

By default, the `zip_zipenc` strategy is used. This means that `zip` will first be used to compress the data into a single file, then an encypted `zip` will be used to encrypt that file. The other built-in strategy is `targz_gpg`, where the compression is done with `tar -z` and encryption with `gpg`. You can change the strategy used by passing in the `-s` argument.

Backing up a directory or file to the ~/backups directory
```bash
$ ./backup_tool.sh backup /path/to/important/dir -d ~/backups -s targz_gpg
```

## Development

If you'd like to contribute to development, this project has some additional dependencies for formatting and testing.
- `bats`: For running tests on shell scripts
- `shfmt`: For formatting and linting Bash code

### Insall Bats

Install according to your system.

```bash
# Ubuntu / Debian
sudo apt install bats

macOS (Homebrew)
brew install bats-core

# Manual Installation
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

To verify:

```bash
bats --version
```

### Install shfmt

```bash
# Ubuntu / Debian
sudo apt install shfmt

# macOS (Homebrew)
brew install shfmt

# Manual Installation
curl -sSLo /usr/local/bin/shfmt \
  https://github.com/mvdan/sh/releases/latest/download/shfmt_$(uname -s)_$(uname -m)
chmod +x /usr/local/bin/shfmt
```

To verify:

```bash
shfmt --version
```

### Make commands

```bash
# Check formatting (no changes)
make check

# Run formatting (changes files)
make format

# Run tests
make test
```

## To Do

- Add more strategies besides zip_zipenc and targz_gpg
