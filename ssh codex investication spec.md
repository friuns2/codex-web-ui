# SSH Codex Investication Spec

## Objective
Document how Codex desktop uses SSH for remote host operations and define verification checks for a target host.

## Scope
- Unpacked Electron build analysis (`app.asar` extracted)
- SSH execution path in worker runtime
- Remote Codex home resolution behavior
- Live connectivity + remote environment check for `ubuntu@149.118.68.145`

## Confirmed Implementation Behavior

### Remote host detection
- Remote mode is enabled when host config kind is `ssh` or `brix`.

### Command execution model
- Remote commands are executed by building an argument list from `hostConfig.terminal_command`.
- Generic remote process runner appends:
  - `--`
  - environment assignments (if any)
  - requested command args

### SSH helper behavior
- Dedicated SSH command helper wraps commands with:
  - `sh -lc <quoted command>`
- Enforced SSH options:
  - `-o BatchMode=yes`
  - `-o ConnectTimeout=10`

### Git over remote
- Git command executor routes remote git commands through remote shell execution.
- Uses non-interactive mode via `GIT_TERMINAL_PROMPT=0`.

### Remote patch/apply flow
For remote apply operations, implementation performs:
1. Create temp dir (`mktemp -d ...`)
2. Write patch file (`cat > ...`)
3. Check file existence (`test -e`)
4. Run `git apply --3way ...`
5. Cleanup temp dir (`rm -rf`)

### Remote Codex home resolution
- Resolution command checks:
  - `$CODEX_HOME` if set
  - otherwise `$HOME/.codex`

## Live Host Verification (Completed)
Target: `ubuntu@149.118.68.145`

Observed:
- SSH non-interactive connection succeeded.
- `CODEX_HOME` env var: not set.
- `~/.codex`: exists.

Conclusion:
- Host is reachable via SSH.
- Effective Codex home fallback is `/home/ubuntu/.codex`.

## Risks / Notes
- No explicit `StrictHostKeyChecking` or `known_hosts` overrides were observed in the checked SSH helper path.
- Actual auth and host-key behavior depends on existing SSH client/user config on the machine running Codex.

## Verification Checklist
- [x] Extract unpacked app and inspect worker implementation.
- [x] Confirm remote command composition path.
- [x] Confirm SSH helper flags and shell wrapping.
- [x] Confirm remote Codex home fallback logic.
- [x] Validate connectivity and Codex home presence on target host.

## Optional Follow-ups
1. Add a startup check that prints resolved remote Codex home for each configured SSH host.
2. Add explicit host-key policy controls in host configuration if stricter behavior is required.
3. Add an automated smoke test that exercises remote `git apply` path end-to-end.
