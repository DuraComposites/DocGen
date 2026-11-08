# Modified by Dura Composites Ltd. (new file)
#
# Makes the QA shell scripts work under Git Bash on Windows. Source it near the
# top of a script; it does nothing on macOS or Linux.
#
# 1. `sf` exits 1 even when it succeeds. Git Bash runs the extensionless
#    `C:\Program Files\sf\bin\sf` wrapper, which calls the installer's
#    `sf.cmd`. When the CLI has auto-updated, that `sf.cmd` hands over to
#    `%LOCALAPPDATA%\sf\client\bin\sf.cmd` from inside a parenthesised block, and
#    cmd.exe loses the exit code on the way back: `sf --version` prints the
#    version and returns 1. Under `set -e` the first `sf` call ends the script.
#    Calling the auto-updated `sf.cmd` directly returns the real exit code.
#
# 2. `python3` is often missing. The Python installer for Windows provides
#    `python` and `py`; `python3` resolves to the Microsoft Store alias, which
#    prints an install hint and fails. The scripts only use it to read JSON and
#    patch XML, which any Python 3 does.
#
# Both are exported as functions, so scripts these ones call (e.g.
# fixtures/deploy.sh) inherit them.

case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

if [[ -n "${LOCALAPPDATA:-}" ]]; then
    __dg_sf_cmd="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || printf '%s' "$LOCALAPPDATA")/sf/client/bin/sf.cmd"
    if [[ -f "$__dg_sf_cmd" ]]; then
        export __DG_SF_CMD="$__dg_sf_cmd"
        sf() { "$__DG_SF_CMD" "$@"; }
        export -f sf
    fi
    unset __dg_sf_cmd
fi

if ! python3 -c 'import sys' >/dev/null 2>&1; then
    for __dg_py in python py; do
        if command -v "$__dg_py" >/dev/null 2>&1 && "$__dg_py" -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
            export __DG_PYTHON="$__dg_py"
            python3() { "$__DG_PYTHON" "$@"; }
            export -f python3
            break
        fi
    done
    unset __dg_py
fi
