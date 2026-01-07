
#!/usr/bin/env bash
set -e

# Verify we have origin/main available (should be fetched by CI)
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  echo "ERROR: origin/main not found. Ensure 'git fetch origin main' has been run."
  exit 1
fi

# Check for deleted files (append-only policy violation)
# Use set +e temporarily to capture git diff exit code before piping
set +e
git_diff_output=$(git diff --name-only --diff-filter=D origin/main -- "*.lean" 2>/dev/null)
git_diff_exit=$?
set -e
if [ $git_diff_exit -ne 0 ]; then
  echo "ERROR: Failed to check for deleted files"
  exit 1
fi
deleted_files=$(echo "$git_diff_output" | grep -v "Init.lean$" | grep -v "^GoedelsPoetryLib\\.lean$" | grep -v "^Tests\\.lean$" | grep -v "GoedelsPoetryLib/GoedelsPoetryLib.lean$" || true)
if [ -n "$deleted_files" ]; then
  echo "ERROR: deleted theorem files detected:"
  echo "$deleted_files"
  exit 1
fi

# Check for modified files (append-only policy violation)
# Use set +e temporarily to capture git diff exit code before piping
set +e
git_diff_output=$(git diff --name-only --diff-filter=M origin/main -- "*.lean" 2>/dev/null)
git_diff_exit=$?
set -e
if [ $git_diff_exit -ne 0 ]; then
  echo "ERROR: Failed to check for modified files"
  exit 1
fi
modified_files=$(echo "$git_diff_output" | grep -v "Init.lean$" | grep -v "^GoedelsPoetryLib\\.lean$" | grep -v "^Tests\\.lean$" | grep -v "GoedelsPoetryLib/GoedelsPoetryLib.lean$" || true)
if [ -n "$modified_files" ]; then
  echo "ERROR: modified theorem files detected:"
  echo "$modified_files"
  exit 1
fi

# Check for added files that would overwrite existing files
# Use set +e temporarily to capture git diff exit code before piping
set +e
git_diff_output=$(git diff --name-only --diff-filter=A origin/main -- "*.lean" 2>/dev/null)
git_diff_exit=$?
set -e
if [ $git_diff_exit -ne 0 ]; then
  echo "ERROR: Failed to check for added files"
  exit 1
fi
added_files=$(echo "$git_diff_output" | grep -v "Init.lean$" | grep -v "^GoedelsPoetryLib\\.lean$" | grep -v "^Tests\\.lean$" | grep -v "GoedelsPoetryLib/GoedelsPoetryLib.lean$" || true)

if [ -n "$added_files" ]; then
  for f in $added_files; do
    # Check if this file already exists in origin/main
    if ! git cat-file -e "origin/main:$f" 2>/dev/null; then
      # File doesn't exist in origin/main, which is good
      continue
    else
      echo "ERROR: added file $f would overwrite existing file in origin/main"
      exit 1
    fi
  done
fi
