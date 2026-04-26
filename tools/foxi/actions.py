import grp
import os
import pwd
import subprocess
import sys


def _run(cmd, check=True):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}")
    return result


def _group_exists(name):
    try:
        grp.getgrnam(name)
        return True
    except KeyError:
        return False


def _user_exists(name):
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


HANDLERS = {}


def handler(name):
    def decorator(fn):
        HANDLERS[name] = fn
        return fn
    return decorator


@handler("add_group")
def add_group(args):
    name = args["name"]
    if _group_exists(name):
        return
    cmd = "addgroup"
    if args.get("system"):
        cmd += " -S"
    if gid := args.get("gid"):
        cmd += f" -g {gid}"
    cmd += f" {name}"
    _run(cmd)


@handler("add_user")
def add_user(args):
    name = args["name"]
    if _user_exists(name):
        return
    cmd = "adduser"
    if args.get("system"):
        cmd += " -S"
    if args.get("no_home"):
        cmd += " -H"
    if shell := args.get("shell"):
        cmd += f" -s {shell}"
    if home := args.get("home"):
        cmd += f" -h {home}"
    if group := args.get("group"):
        cmd += f" -G {group}"
    if gecos := args.get("gecos"):
        cmd += f' -g "{gecos}"'
    cmd += f" -D {name}"
    _run(cmd)


@handler("mkdir")
def make_dir(args):
    path = args["path"]
    mode = int(args.get("mode", "0755"), 8)
    os.makedirs(path, mode=mode, exist_ok=True)


@handler("chown")
def chown(args):
    path = args["path"]
    owner = args.get("owner")
    group = args.get("group")
    uid = pwd.getpwnam(owner).pw_uid if owner else -1
    gid = grp.getgrnam(group).gr_gid if group else -1
    recursive = args.get("recursive", False)
    if recursive:
        for root, dirs, files in os.walk(path):
            os.chown(root, uid, gid)
            for f in files:
                os.chown(os.path.join(root, f), uid, gid)
    else:
        os.chown(path, uid, gid)


@handler("chmod")
def chmod(args):
    path = args["path"]
    mode = int(args["mode"], 8)
    os.chmod(path, mode)


@handler("symlink")
def symlink(args):
    src = args["src"]
    dst = args["dst"]
    if os.path.lexists(dst):
        return
    os.symlink(src, dst)


@handler("write_file")
def write_file(args):
    path = args["path"]
    content = args["content"]
    overwrite = args.get("overwrite", False)
    if not overwrite and os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    if mode := args.get("mode"):
        os.chmod(path, int(mode, 8))


@handler("run")
def run_command(args):
    _run(args["cmd"])


def execute_action(action):
    name = action.get("action")
    if name not in HANDLERS:
        raise ValueError(f"Unknown action type: {name!r}")
    HANDLERS[name](action.get("args", {}))
