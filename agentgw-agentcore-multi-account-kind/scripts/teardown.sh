#!/usr/bin/env bash
# teardown.sh — remove EVERYTHING this lab created, in the order that keeps the
# credentials alive long enough to finish.
#
# Order matters. tofu owns the IAM users and access keys that are the only route
# into the two portfolio accounts, so every non-tofu artefact has to go BEFORE
# `tofu destroy`. Get that backwards and the runtimes are orphaned with nothing
# left that can reach them.
#
#   1. AgentCore runtimes            (billed per invocation)
#   2. their CloudWatch log groups   (billed for storage)
#   3. their SDK execution roles     (created by AgentCore, not by tofu)
#   4. their S3 source bundles       (billed for storage)
#   5. tofu destroy                  (all IAM in both accounts)
#   6. the kind cluster
#   7. the public GitHub repo 31-agents.sh published
#   8. verify, and exit non-zero if anything is left
#
# Nothing here deletes by "everything in the region": other labs share these
# accounts, so every step is scoped to $LAB_AGENTS x $LAB_ENVS. Helper functions
# write DATA to stdout and progress to stderr, so callers can capture one
# without the other. TEARDOWN_DRY_RUN=1 lists what would go, and touches nothing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY="${TEARDOWN_DRY_RUN:-0}"
RESIDUE=0
note_residue() { RESIDUE=1; }

load_secrets || true
if try_load_tofu_env; then
  AWS_REACHABLE=1
else
  AWS_REACHABLE=0
  warn "deploy/.env.tofu is missing, so the AWS side cannot be reached from here."
  warn "The kind cluster and the GitHub repo are still cleaned up below."
  warn "If AWS resources remain, restore deploy/.env.tofu and re-run this script."
  note_residue
fi

# ── helpers that run inside in_env_role (assumed role + account guard) ───────

# stdout: one runtime id per line. Scoped by runtime NAME, so a sibling lab's
# runtime in the same account and region is never touched.
lab_delete_runtimes() { # <env> <region>
  local env="$1" region="$2" id name re
  re="^($(lab_runtime_names_for_env "$env" | paste -sd'|' -))\$"
  while read -r id name; do
    [[ -n "$id" ]] || continue
    echo "$id"
    if [[ "$DRY" == 1 ]]; then log "would delete runtime $name ($id)"; continue; fi
    if aws bedrock-agentcore-control delete-agent-runtime --region "$region" --agent-runtime-id "$id" >/dev/null 2>&1; then
      ok "deleted AgentCore runtime $name"
    else
      warn "could not delete runtime $name ($id)"
    fi
  done < <(aws bedrock-agentcore-control list-agent-runtimes --region "$region" 2>/dev/null \
    | jq -r --arg re "$re" '.agentRuntimes[]? | select(.agentRuntimeName|test($re)) | "\(.agentRuntimeId) \(.agentRuntimeName)"')
}

lab_delete_log_groups() { # <region> <runtime id>...
  local region="$1"; shift
  local id lg
  for id in "$@"; do
    lg="/aws/bedrock-agentcore/runtimes/${id}-DEFAULT"
    aws logs describe-log-groups --region "$region" --log-group-name-prefix "$lg" >/dev/null 2>&1 || continue
    if [[ "$DRY" == 1 ]]; then log "would delete log group $lg"; continue; fi
    aws logs delete-log-group --region "$region" --log-group-name "$lg" >/dev/null 2>&1 \
      && ok "deleted log group $lg" || true
  done
}

# The SDK execution roles are AmazonBedrockAgentCoreSDKRuntime-<region>-<hash>,
# so the name says nothing about which lab owns one. The inline policy is named
# BedrockAgentCoreRuntimeExecutionPolicy-<runtime name>, which IS an exact match
# on this lab's runtimes: match on that and leave other labs' roles alone.
lab_delete_sdk_roles() { # <env> <region>
  local env="$1" region="$2" r p re mine
  re="^BedrockAgentCoreRuntimeExecutionPolicy-($(lab_runtime_names_for_env "$env" | paste -sd'|' -))\$"
  for r in $(aws iam list-roles \
      --query "Roles[?starts_with(RoleName,'AmazonBedrockAgentCoreSDKRuntime-${region}-')].RoleName" \
      --output text 2>/dev/null); do
    mine=0
    for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
      [[ "$p" =~ $re ]] && mine=1
    done
    [[ "$mine" == 1 ]] || continue
    if [[ "$DRY" == 1 ]]; then log "would delete SDK execution role $r"; continue; fi
    for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
    done
    for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$r" --policy-arn "$p" >/dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "$r" >/dev/null 2>&1 \
      && ok "deleted SDK execution role $r" || warn "could not delete SDK execution role $r"
  done
}

# AgentCore names the source-bundle bucket
#   bedrock-agentcore-codebuild-sources-<account>-<region>-<agent name>
# truncated to the 63-character S3 limit, so the suffix is a PREFIX of the agent
# name ("quant" arrives as "quan"). Match on that, because these accounts also
# hold source buckets from other labs. stdout: one bucket name per line.
# Emptying only needs s3:DeleteObject, which the role has; deleting the bucket
# needs s3:DeleteBucket, which it deliberately does not, so the caller finishes
# the job with that account's operator profile.
lab_empty_buckets() { # <account id> <region>
  local acct="$1" region="$2" pfx b sfx a
  pfx="bedrock-agentcore-codebuild-sources-${acct}-${region}-"
  for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'$pfx')].Name" --output text 2>/dev/null); do
    sfx="${b#"$pfx"}"
    [[ ${#sfx} -ge 3 ]] || continue
    for a in $LAB_AGENTS; do
      [[ "$a" == "$sfx"* ]] || continue
      echo "$b"
      if [[ "$DRY" == 1 ]]; then log "would empty + delete bucket $b"; else
        aws s3 rm "s3://$b" --recursive >/dev/null 2>&1 || true
        ok "emptied bucket $b"
      fi
      break
    done
  done
  return 0
}

# ── read-only probes via each account's OPERATOR profile ─────────────────────
# These work after tofu destroy, when the AgentRegistryAccess role is gone, so
# teardown can tell "already clean" apart from "unreachable" instead of
# assuming the worst. Each prints one name per line; empty output means clean.
lab_runtimes_via_profile() { # <env>
  local env="$1" region prof re
  region="$(env_var "$env" REGION)"; prof="$(lab_profile "$env")"
  [[ -n "$prof" ]] || return 2
  re="^($(lab_runtime_names_for_env "$env" | paste -sd'|' -))\$"
  AWS_PROFILE="$prof" aws bedrock-agentcore-control list-agent-runtimes --region "$region" 2>/dev/null \
    | jq -r --arg re "$re" '.agentRuntimes[]? | select(.agentRuntimeName|test($re)) | .agentRuntimeName' 2>/dev/null
  return 0
}
lab_sdk_roles_via_profile() { # <env>
  local env="$1" region prof r p re
  region="$(env_var "$env" REGION)"; prof="$(lab_profile "$env")"
  [[ -n "$prof" ]] || return 2
  re="^BedrockAgentCoreRuntimeExecutionPolicy-($(lab_runtime_names_for_env "$env" | paste -sd'|' -))\$"
  for r in $(AWS_PROFILE="$prof" aws iam list-roles \
      --query "Roles[?starts_with(RoleName,'AmazonBedrockAgentCoreSDKRuntime-${region}-')].RoleName" \
      --output text 2>/dev/null); do
    for p in $(AWS_PROFILE="$prof" aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
      [[ "$p" =~ $re ]] && { echo "$r"; break; }
    done
  done
  return 0
}
lab_buckets_via_profile() { # <env>
  local env="$1" region acct prof pfx b sfx a
  region="$(env_var "$env" REGION)"; acct="$(env_var "$env" ACCOUNT_ID)"; prof="$(lab_profile "$env")"
  [[ -n "$prof" ]] || return 2
  pfx="bedrock-agentcore-codebuild-sources-${acct}-${region}-"
  for b in $(AWS_PROFILE="$prof" aws s3api list-buckets --query "Buckets[?starts_with(Name,'$pfx')].Name" --output text 2>/dev/null); do
    sfx="${b#"$pfx"}"; [[ ${#sfx} -ge 3 ]] || continue
    for a in $LAB_AGENTS; do [[ "$a" == "$sfx"* ]] && { echo "$b"; break; }; done
  done
  return 0
}

# ── 1-4 ──────────────────────────────────────────────────────────────────────
if [[ "$AWS_REACHABLE" == 1 ]]; then
  for env in $LAB_ENVS; do
    region="$(env_var "$env" REGION)"
    acct="$(env_var "$env" ACCOUNT_ID)"
    prof="$(lab_profile "$env")"
    step "$env ($region) — runtimes, log groups, execution roles, source bundles"

    rc=0
    ids="$(in_env_role "$env" lab_delete_runtimes "$env" "$region")" || rc=$?
    if [[ $rc -ne 0 ]]; then
      # Either IAM is already gone (a re-run after a clean teardown) or the keys
      # are wrong. Ask the operator profile which it is rather than guessing.
      leftover="$( { lab_runtimes_via_profile "$env"; lab_sdk_roles_via_profile "$env"; lab_buckets_via_profile "$env"; } 2>/dev/null | tr '\n' ' ' || true )"
      leftover="${leftover// /}"
      if [[ -z "$leftover" ]]; then
        log "[$env] AgentRegistryAccess role is gone and none of this lab's resources remain — already clean"
        continue
      fi
      warn "[$env] cannot assume the AgentRegistryAccess role (rc=$rc), but resources REMAIN."
      warn "[$env] delete these before tofu destroy, or restore deploy/.env.tofu and re-run:"
      { lab_runtimes_via_profile "$env"; lab_sdk_roles_via_profile "$env"; lab_buckets_via_profile "$env"; } 2>/dev/null \
        | sed 's/^/      /' >&2 || true
      note_residue
      continue
    fi

    # shellcheck disable=SC2086  # ids is a deliberate whitespace-separated list
    in_env_role "$env" lab_delete_log_groups "$region" $ids || true
    in_env_role "$env" lab_delete_sdk_roles "$env" "$region" || true

    buckets="$(in_env_role "$env" lab_empty_buckets "$acct" "$region")" || true
    for b in $buckets; do
      if [[ "$DRY" == 1 ]]; then log "would delete bucket $b via profile ${prof:-<none>}"; continue; fi
      if [[ -z "$prof" ]]; then
        warn "no operator profile for $env (set PROFILE_$(env_key "$env")) — bucket $b left behind"; note_residue; continue
      fi
      AWS_PROFILE="$prof" aws s3api delete-bucket --bucket "$b" >/dev/null 2>&1 \
        && ok "deleted bucket $b" \
        || { warn "could not delete bucket $b — profile $prof needs s3:DeleteBucket"; note_residue; }
    done
  done
fi

# ── 5: tofu ──────────────────────────────────────────────────────────────────
step "tofu destroy (all IAM, both accounts)"
if [[ "$DRY" == 1 ]]; then
  ( cd "$LAB_ROOT/tofu" && tofu plan -destroy -input=false -no-color 2>&1 | grep -E '^Plan:' ) || true
elif [[ ! -f "$LAB_ROOT/tofu/terraform.tfstate" ]]; then
  log "no tofu state — nothing to destroy"
elif ( cd "$LAB_ROOT/tofu" && tofu destroy -input=false -auto-approve ); then
  ok "AWS IAM destroyed"
else
  note_residue
  warn "tofu destroy did not complete."
  warn "The usual cause is a restricted operator profile: CREATING an inline role"
  warn "policy needs iam:PutRolePolicy, DELETING it needs iam:DeleteRolePolicy, and"
  warn "a role cannot be deleted while it still carries one. Confirm with:"
  warn "  aws iam delete-role-policy --role-name <role> --policy-name <policy>"
  warn "AccessDenied there means the profile lacks iam:DeleteRolePolicy — grant it"
  warn "(see the README prerequisites) and re-run this script. Nothing else is"
  warn "stranded: the leftover roles trust only the IAM users tofu just deleted."
fi

# ── 6: kind ──────────────────────────────────────────────────────────────────
step "kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  if [[ "$DRY" == 1 ]]; then log "would delete kind cluster $CLUSTER_NAME"; else
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 && ok "kind cluster deleted"
  fi
else
  log "kind cluster '$CLUSTER_NAME' not present"
fi

# ── 7: the GitHub repo 31-agents.sh published ────────────────────────────────
# Source mode means AgentCore clones the agents from a PUBLIC repo, so a plain
# `up` leaves one behind on the reader's own account. Deleting a repo cannot be
# undone, so this asks first unless TEARDOWN_DELETE_REPO=1.
step "GitHub source repo"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh_user="$(gh api user -q .login 2>/dev/null || true)"
  slug="${AGENT_REPO_SLUG:-${gh_user}/agw-multi-account-agents}"
  if [[ -n "$gh_user" ]] && gh repo view "$slug" >/dev/null 2>&1; then
    if [[ "$DRY" == 1 ]]; then
      log "would offer to delete public repo $slug"
    else
      del="${TEARDOWN_DELETE_REPO:-}"
      if [[ -z "$del" && -t 0 ]]; then
        read -r -p "  delete public repo ${slug}? [y/N] " a
        [[ "$a" == y || "$a" == Y ]] && del=1
      fi
      if [[ "$del" == 1 ]]; then
        if gh repo delete "$slug" --yes >/dev/null 2>&1; then
          ok "deleted repo $slug"
        else
          warn "could not delete $slug — gh is missing the delete_repo scope:"
          warn "  gh auth refresh -h github.com -s delete_repo && gh repo delete $slug --yes"
          note_residue
        fi
      else
        warn "left public repo $slug in place — delete it with: gh repo delete $slug --yes"
        note_residue
      fi
    fi
  else
    log "no lab source repo found"
  fi
else
  log "gh unavailable or not authenticated — skipping the source repo check"
fi

# ── 8: verify ────────────────────────────────────────────────────────────────
# A teardown that only reports what it TRIED is how this lab once shipped a
# silent no-op. Re-read the accounts and state what is genuinely left.
step "Verifying"
if [[ "$AWS_REACHABLE" == 1 && "$DRY" != 1 ]]; then
  for env in $LAB_ENVS; do
    if [[ -z "$(lab_profile "$env")" ]]; then
      warn "[$env] no operator profile (set PROFILE_$(env_key "$env")) — cannot verify this account"; note_residue; continue
    fi
    left="$( { lab_runtimes_via_profile "$env"; lab_sdk_roles_via_profile "$env"; lab_buckets_via_profile "$env"; } 2>/dev/null || true )"
    if [[ -n "${left//[[:space:]]/}" ]]; then
      warn "[$env] STILL PRESENT:"; echo "$left" | sed 's/^/      /' >&2; note_residue
    else
      ok "[$env] runtimes, execution roles and source buckets all gone"
    fi
  done
  n=0
  if [[ -f "$LAB_ROOT/tofu/terraform.tfstate" ]]; then
    n="$(python3 -c "import json,sys;print(sum(1 for r in json.load(open(sys.argv[1]))['resources'] if r['mode']=='managed'))" \
         "$LAB_ROOT/tofu/terraform.tfstate" 2>/dev/null || echo 0)"
  fi
  if [[ "$n" != 0 ]]; then warn "$n resource(s) still in tofu state — teardown incomplete"; note_residue
  else ok "tofu state is empty"; fi
fi

# ── 9: the generated env files ───────────────────────────────────────────────
# deploy/.env.tofu holds the two IAM users' static access keys at 0600. Once the
# users are gone the keys are dead weight, but they are only removed on a CLEAN
# teardown: if anything above failed they are the credentials a retry needs.
if [[ "$DRY" != 1 && "$RESIDUE" == 0 ]]; then
  for f in "$LAB_ROOT/deploy/.env.tofu" "$LAB_ROOT/deploy/.env.runtimes"; do
    [[ -f "$f" ]] && { rm -f "$f"; ok "removed $(basename "$f") (dead credentials)"; }
  done
fi

if [[ "$DRY" == 1 ]]; then
  step "dry run only — nothing was deleted"
elif [[ "$RESIDUE" == 0 ]]; then
  step "Teardown complete — nothing left"
else
  step "Teardown INCOMPLETE — see the warnings above"
  exit 1
fi
