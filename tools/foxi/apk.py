import subprocess
import sys


def run_apk(args):
    """Pass through to apk, returning exit code."""
    result = subprocess.run(["apk"] + args)
    return result.returncode
