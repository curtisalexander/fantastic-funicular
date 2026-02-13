"""Allow running as `python -m aipipe`."""

import os
import shutil
import subprocess
import sys


def _run():
    name = "aipipe.exe" if sys.platform == "win32" else "aipipe"
    binary = shutil.which(name)
    if binary is None:
        print(f"Error: could not find '{name}' on PATH.", file=sys.stderr)
        print("Reinstall the package: uv tool install aipipe", file=sys.stderr)
        sys.exit(1)
    if sys.platform == "win32":
        sys.exit(subprocess.call([binary, *sys.argv[1:]]))
    else:
        os.execvp(binary, [binary, *sys.argv[1:]])


if __name__ == "__main__":
    _run()
