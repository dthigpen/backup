# Backup Tool

A simple file backup solution with no fancy features

## Usage

Download `backup_tool.sh` from this repository and make sure its executable with `chmod u+x backup_tool.sh`.

Backing up a directory to the ~/backups directory
```bash
$ ./backup_tool.sh backup /path/to/important/dir -d ~/backups
```

Restoring files from a backup file to /path/to/important/dir
```bash
$ ./backup_tool.sh restore ~/backups/important_dir.backup.zip -d /path/to/important/dir 
```
