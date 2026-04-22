# Apple Container Builder Spec

## Current State

- A real `services.container-builder` nix-darwin module now exists.
- It declares:
  - `nix.buildMachines`
  - SSH config for `container-builder`
  - helper scripts in `/Users/<username>/.local/state/container-builder`
  - a `socat` bridge user agent
  - a runtime user agent that starts `container system` and the builder container
  - readiness checks before considering startup successful
  - idempotent container start behavior
- This is still an in-progress integration, not a finished replacement.

## Remaining Work Plan

### 1. Stabilize the current bridge-based path

- Verify the launch agents are sufficient in a real login session.
- Add readiness checks so startup only succeeds once SSH to the builder is actually reachable.
- Make container startup idempotent instead of always replacing the container.
- Capture failures cleanly in predictable logs.

### 2. Clarify lifecycle boundaries

- Decide whether the builder should be:
  - always-on after login, or
  - on-demand when builds start
- If on-demand is the goal, design a small local trigger mechanism instead of keeping the container permanently running.

### 3. Durable state follow-through

- Durable state has been moved to `/Users/<username>/.local/state/container-builder`.
- Remaining work is to verify migration/activation behavior on a real machine.
- Keep generated/runtime state separate from declarative inputs.

### 4. Validate nix-daemon compatibility end-to-end

- Confirm the root daemon can always reach the builder through the declared SSH alias.
- Confirm `nix store ping --store ssh-ng://container-builder` works after activation.
- Confirm a forced `aarch64-linux` build works without manual shell setup.

### 5. Resolve networking limitations

- Review container docs specifically for:
  - port publishing semantics
  - whether published ports require a different listen address or network mode
  - whether current XPC/user-session limitations are expected
- If published ports can be made reliable, remove the `socat` bridge entirely.
- If not, keep the bridge and make that the supported design.

### 6. Resolve DNS/substituter behavior inside the container

- The module now passes explicit DNS settings via `container run --dns` and related flags.
- The builder init script now configures `https://cache.nixos.org/` as a substituter.
- Remaining work is runtime verification that Apple `container` honors the DNS settings reliably.
- If DNS still fails at runtime, document the fallback behavior and investigate alternative network settings.

### 7. Decide what "done" means for the module

- Minimal done:
  - bridge-based builder works after `darwin-rebuild switch`
  - no manual state-directory setup
  - real build succeeds
- Full done:
  - no `socat`
  - no manual recovery
  - durable state location
  - on-demand lifecycle
  - docs for activation, logs, troubleshooting

## Recommended Execution Order

1. Review docs for port publishing and lifecycle constraints.
2. Make the current bridge path reliable and testable.
3. Add readiness checks and better logging.
4. Run real builder verification.
5. Only then decide whether to invest in removing `socat`.

## Key Open Decision

Which target should be prioritized?

1. Make the current `socat` workaround production-reliable first.
2. Pause and push for direct published-port support first.
