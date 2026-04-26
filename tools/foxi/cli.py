import argparse
import sys

from .apk import run_apk
from .tricks import fetch_trick, list_tricks, run_hook, update_index


def cmd_add(args):
    packages = args.packages
    rc = run_apk(["add"] + packages)
    if rc != 0:
        sys.exit(rc)
    for pkg in packages:
        run_hook(pkg, "post-install")


def cmd_del(args):
    packages = args.packages
    for pkg in packages:
        run_hook(pkg, "pre-remove")
    rc = run_apk(["del"] + packages)
    if rc != 0:
        sys.exit(rc)
    for pkg in packages:
        run_hook(pkg, "post-remove")


def cmd_tricks_update(args):
    update_index()


def cmd_tricks_list(args):
    list_tricks()


def cmd_tricks_fetch(args):
    for pkg in args.packages:
        fetch_trick(pkg)
        print(f"Trick for {pkg!r} fetched and cached.")


def cmd_passthrough(args):
    sys.exit(run_apk(args.apk_args))


def build_parser():
    parser = argparse.ArgumentParser(
        prog="foxi",
        description="apk wrapper with post-install tricks for Foxi Linux",
    )
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")

    # foxi add
    p_add = sub.add_parser("add", help="Install packages and run post-install tricks")
    p_add.add_argument("packages", nargs="+", metavar="PACKAGE")
    p_add.set_defaults(func=cmd_add)

    # foxi del
    p_del = sub.add_parser("del", help="Remove packages, running pre/post-remove tricks")
    p_del.add_argument("packages", nargs="+", metavar="PACKAGE")
    p_del.set_defaults(func=cmd_del)

    # foxi tricks
    p_tricks = sub.add_parser("tricks", help="Manage tricks")
    tricks_sub = p_tricks.add_subparsers(dest="tricks_command", metavar="SUBCOMMAND")

    p_update = tricks_sub.add_parser("update", help="Fetch the latest tricks index")
    p_update.set_defaults(func=cmd_tricks_update)

    p_list = tricks_sub.add_parser("list", help="List available tricks")
    p_list.set_defaults(func=cmd_tricks_list)

    p_fetch = tricks_sub.add_parser("fetch", help="Download and cache a trick")
    p_fetch.add_argument("packages", nargs="+", metavar="PACKAGE")
    p_fetch.set_defaults(func=cmd_tricks_fetch)

    # foxi <anything else> → pass straight to apk
    p_pass = sub.add_parser("apk", help="Pass remaining args directly to apk")
    p_pass.add_argument("apk_args", nargs=argparse.REMAINDER)
    p_pass.set_defaults(func=cmd_passthrough)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(0)

    if not hasattr(args, "func"):
        parser.print_help()
        sys.exit(1)

    args.func(args)
