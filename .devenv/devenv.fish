# devenv fish init

# If this shell was spawned by the devenv hook, `exit` when the user `cd`s
# outside the project so the parent shell can follow. The user's config.fish
# may already have moved `_DEVENV_HOOK_DIR` to the non-exported
# `_devenv_hook_dir` before this init file runs. Accept either marker so the
# exit happens on PWD change, before prompt handlers can query the terminal.
# Erase the exported marker so it cannot leak into further descendants.
if set -q _DEVENV_HOOK_DIR; or set -q _devenv_hook_dir
    set -e _DEVENV_HOOK_DIR
    function _devenv_shell_exit_on_cd_out --on-variable PWD
        switch $PWD
            case "$DEVENV_ROOT" "$DEVENV_ROOT/*"
            case '*'
                printf '%s' $PWD > "$DEVENV_ROOT/.devenv/exit-dir"
                exit
        end
    end
end

# Restore devenv PATH after user config may have modified it.
# _DEVENV_PATH is a colon-separated string from bash; split into fish list.
set -gx PATH (string split ":" -- $_DEVENV_PATH)

# Wrap fish_prompt for devenv reload hooks and prompt prefix.
if functions -q fish_prompt
    functions -c fish_prompt __devenv_user_fish_prompt
    function fish_prompt
        __devenv_user_fish_prompt
        __devenv_reload_apply
        __devenv_restore_path
    end
else
    function fish_prompt
        __devenv_reload_apply
        __devenv_restore_path
        echo -n "(devenv) > "
    end
end

# Hot-reload hook

function __devenv_reload_apply
    # Source new environment if a reload is pending
    if test -f "/var/folders/f7/9dksrpss1998mz0z6kn7ym7h0000gn/T/devenv-reload-73175.sh"
        # Shell out to bash to handle the env diff (bash syntax).
        # The bash subprocess inherits our current environment, reverses
        # the previous diff, sources the new devenv env, computes a new
        # diff, and outputs the resulting environment via export -p.
        set -l reload_output (bash -c '
            
# Environment diff helpers (inspired by direnv)
# Diff is stored in _DEVENV_DIFF env var (not a file) so each shell has its own state
# Uses gzip+base64 encoding for compact storage

# Variables to ignore in diff (shell internals that change dynamically)
__devenv_ignored_var() {
    case "$1" in
        _*|PWD|OLDPWD|SHLVL|SHELL|SHELLOPTS|BASHOPTS|BASH_*|HISTCMD|HISTFILE)
            return 0 ;;
        PS1|PS2|PS3|PS4|PROMPT|PROMPT_COMMAND|PROMPT_DIRTRIM)
            return 0 ;;
        COMP_*|READLINE_*|MAILCHECK|COLUMNS|LINES|RANDOM|SECONDS|LINENO|EPOCHSECONDS|EPOCHREALTIME|SRANDOM)
            return 0 ;;
        STARSHIP_*|__fish*|DIRENV_*|nix_saved_*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

__devenv_capture_env() {
    # Capture exported variables using declare -p for proper escaping
    declare -p -x 2>/dev/null | LC_ALL=C sort
}

__devenv_serialize_diff() {
    # Serialize diff (stdin) to base64-encoded gzip
    gzip -c | base64 -w0
}

__devenv_deserialize_diff() {
    # Deserialize diff from base64-encoded gzip to stdout
    echo "$1" | base64 -d | gzip -d 2>/dev/null
}

__devenv_compute_diff() {
    # Compare before ($1) and current env, return diff via _DEVENV_DIFF env var
    local before_file="$1"

    # Create temp files
    local after_file diff_content
    after_file=$(mktemp)
    diff_content=$(mktemp)
    __devenv_capture_env > "$after_file"

    # Build associative arrays for before/after
    local -A before_vars after_vars
    while IFS= read -r line; do
        [[ "$line" != declare\ -x\ * ]] && continue
        local vardef="${line#declare -x }"
        local var="${vardef%%=*}"
        [[ -z "$var" ]] && continue
        __devenv_ignored_var "$var" && continue
        before_vars["$var"]="$line"
    done < "$before_file"

    while IFS= read -r line; do
        [[ "$line" != declare\ -x\ * ]] && continue
        local vardef="${line#declare -x }"
        local var="${vardef%%=*}"
        [[ -z "$var" ]] && continue
        __devenv_ignored_var "$var" && continue
        after_vars["$var"]="$line"
    done < "$after_file"

    # Find PREV entries (vars that were modified or removed)
    for var in "${!before_vars[@]}"; do
        if [[ "${after_vars[$var]}" != "${before_vars[$var]}" ]]; then
            echo "P:${before_vars[$var]}" >> "$diff_content"
        fi
    done

    # Find NEXT entries (vars that were added or modified)
    for var in "${!after_vars[@]}"; do
        if [[ -z "${before_vars[$var]+x}" ]]; then
            echo "N:$var" >> "$diff_content"
        elif [[ "${after_vars[$var]}" != "${before_vars[$var]}" ]]; then
            echo "N:$var" >> "$diff_content"
        fi
    done

    # Serialize and store in env var
    _DEVENV_DIFF=$(__devenv_serialize_diff < "$diff_content")
    export _DEVENV_DIFF

    rm -f "$after_file" "$diff_content"
}

__devenv_apply_reverse_diff() {
    # Reverse the diff: restore PREV values, unset NEXT-only vars
    [[ -z "$_DEVENV_DIFF" ]] && return

    local -A prev_vars
    local diff_content
    diff_content=$(__devenv_deserialize_diff "$_DEVENV_DIFF")

    # First pass: collect and restore PREV declarations
    while IFS= read -r line; do
        if [[ "$line" == P:declare\ * ]]; then
            local decl="${line#P:}"
            local var="${decl#declare -x }"
            var="${var%%=*}"
            prev_vars["$var"]=1
            # Use export instead of evaluating the declare statement directly,
            # because declare -x inside a function creates a local variable
            # in bash 5.0+.
            eval "export ${decl#declare -x }" 2>/dev/null
        fi
    done <<< "$diff_content"

    # Second pass: unset NEXT vars that were not in PREV (added vars)
    while IFS= read -r line; do
        if [[ "$line" == N:* ]]; then
            local var="${line#N:}"
            if [[ -z "${prev_vars[$var]+x}" ]]; then
                unset "$var"
            fi
        fi
    done <<< "$diff_content"
}


# Reverse previous diff
__devenv_apply_reverse_diff

# Capture env before sourcing new devenv
_before=$(mktemp)
__devenv_capture_env > "$_before"

# Send enterShell output to the terminal instead of the captured stdout.
# Probe by actually opening /dev/tty: it can exist with writable permission
# bits yet fail to open (ENXIO) when there is no controlling terminal.
if { : >/dev/tty; } 2>/dev/null; then
    _devenv_reload_out=/dev/tty
else
    _devenv_reload_out=/dev/null
fi

# Source new devenv environment
source "/var/folders/f7/9dksrpss1998mz0z6kn7ym7h0000gn/T/devenv-reload-73175.sh" >"$_devenv_reload_out" 2>"$_devenv_reload_out"
rm -f "/var/folders/f7/9dksrpss1998mz0z6kn7ym7h0000gn/T/devenv-reload-73175.sh"
unset _devenv_reload_out

# Compute new diff
__devenv_compute_diff "$_before"
rm -f "$_before"

# Output current environment for the calling shell to parse
export -p
        ' 2>/dev/null)

        # Parse bash export -p output (declare -x VAR="value") and apply
        # each variable to the fish environment via set -gx.
        for line in $reload_output
            # Match lines of the form: declare -x VAR="value"
            set -l parts (string match -r '^declare -x ([^=]+)="(.*)"$' -- $line)
            if test (count $parts) -gt 0
                set -l var $parts[2]
                set -l val $parts[3]
                # Skip fish read-only electric variables that bash exports.
                # PWD and SHLVL are managed by fish; assigning to them errors.
                if test "$var" = PWD -o "$var" = SHLVL
                    continue
                end
                # PATH, MANPATH, CDPATH are list variables in fish;
                # split colon-separated values into proper lists.
                if test "$var" = PATH -o "$var" = MANPATH -o "$var" = CDPATH
                    set -gx $var (string split ":" -- $val)
                else
                    set -gx $var $val
                end
            else
                # Variable exported without a value: declare -x VAR
                set -l noval (string match -r '^declare -x ([^=]+)$' -- $line)
                if test (count $noval) -gt 0
                    set -gx $noval[2] ""
                end
            end
        end

        # Update saved PATH
        set -gx _DEVENV_PATH (string join ":" -- $PATH)
    end
end

function __devenv_restore_path
    # Restore devenv PATH (in case direnv or other tools modified it).
    # _DEVENV_PATH is a colon-separated string; split into a list for fish.
    set -gx PATH (string split ":" -- $_DEVENV_PATH)
end

# Keybinding for manual reload (Ctrl+Alt+R by default)
function __devenv_reload_keybind_handler
    __devenv_reload_apply
    commandline -f repaint
end
bind (string unescape '\x1b\x12') __devenv_reload_keybind_handler


