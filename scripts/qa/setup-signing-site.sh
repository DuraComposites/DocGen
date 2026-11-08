#!/usr/bin/env bash
# Dura Composites Ltd. (new file)
#
# Public guest signing in a QA org, end to end:
#
#   ./scripts/qa/setup-signing-site.sh docgen-verify            # Site + drawing-approval demo
#   ./scripts/qa/setup-signing-site.sh docgen-verify --no-demo  # Site only
#
# Run it after setup-org.sh. It is idempotent: re-running it re-deploys the
# same Site and prints a fresh demo signing link.
#
# WHAT IT DOES
#   1. Deploys a Visualforce Site, "DocGen Signing" at /sign (fixtures/site).
#   2. Gives the Site's guest user the DocGen_Guest_Signature permission set.
#      That set carries the four signing pages and the guest Apex classes.
#   3. Points DocGen Settings' Experience_Site_Url__c at the Site, so signing
#      links and certificate verify links use it.
#   4. Checks the public path: the verify page must answer 200 to an
#      anonymous request.
#   5. Unless --no-demo: runs seed-drawing-approval.apex (an Account with
#      three sample drawings, an approval template with attached documents
#      and markup, and a request) and prints the signing link. Open it on a
#      phone to test touch markup.
#
# The scratch org must have the Sites feature. config/project-scratch-def.json
# has it.

set -euo pipefail

ORG="${1:-docgen-verify}"
[[ "$ORG" == --* ]] && ORG="docgen-verify"
DEMO=true
for a in "$@"; do [[ "$a" == "--no-demo" ]] && DEMO=false; done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/windows-shim.sh"
cd "$ROOT"

say() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
# Read a value from sf --json output on stdin with a JS path, e.g. "result.username".
jget() { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s.slice(s.indexOf('{')));const v=$1;console.log(v==null?'':v)})"; }

say "Org: $ORG"
ADMIN="$(sf org display --target-org "$ORG" --json 2>/dev/null | jget 'j.result.username')"
[[ -n "$ADMIN" ]] || { echo "   !! could not read the org's admin username"; exit 1; }

# ── 1. the Site ──────────────────────────────────────────────────────────────
say "Deploying the DocGen Signing Site (/sign)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$HERE/fixtures/site/." "$STAGE/"
sed -i.bak "s#__ADMIN__#$ADMIN#g" "$STAGE/sites/DocGen_Signing.site" && rm -f "$STAGE/sites/"*.bak
sf project deploy start --target-org "$ORG" --metadata-dir "$STAGE" --wait 20 >/dev/null
SITE_JSON="$(sf data query --target-org "$ORG" --json \
    -q "SELECT Id, GuestUserId, Status FROM Site WHERE Name = 'DocGen_Signing' LIMIT 1" 2>/dev/null)"
SITE_ID="$(printf '%s' "$SITE_JSON" | jget 'j.result.records[0] && j.result.records[0].Id')"
GUEST_ID="$(printf '%s' "$SITE_JSON" | jget 'j.result.records[0] && j.result.records[0].GuestUserId')"
[[ -n "$SITE_ID" && -n "$GUEST_ID" ]] || { echo "   !! the Site deployed but can't be found"; exit 1; }
SITE_URL="$(sf data query --target-org "$ORG" --json \
    -q "SELECT SecureUrl FROM SiteDetail WHERE DurableId = '$SITE_ID'" 2>/dev/null | jget 'j.result.records[0] && j.result.records[0].SecureUrl')"
[[ -n "$SITE_URL" ]] || { echo "   !! the Site has no public URL"; exit 1; }
echo "   $SITE_URL"

# ── 2. guest permission set ──────────────────────────────────────────────────
say "Giving the Site guest user DocGen_Guest_Signature"
PS_ID="$(sf data query --target-org "$ORG" --json \
    -q "SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Guest_Signature' LIMIT 1" 2>/dev/null | jget 'j.result.records[0] && j.result.records[0].Id')"
[[ -n "$PS_ID" ]] || { echo "   !! DocGen_Guest_Signature isn't in the org; run setup-org.sh first"; exit 1; }
HAS="$(sf data query --target-org "$ORG" --json \
    -q "SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = '$GUEST_ID' AND PermissionSetId = '$PS_ID'" 2>/dev/null | jget 'j.result.totalSize')"
if [[ "$HAS" == "0" ]]; then
    sf data create record --target-org "$ORG" --sobject PermissionSetAssignment \
        --values "AssigneeId=$GUEST_ID PermissionSetId=$PS_ID" >/dev/null
    echo "   assigned"
else
    echo "   already assigned"
fi

# ── 3. DocGen settings ───────────────────────────────────────────────────────
say "Pointing DocGen at the Site"
APEX="$(mktemp)"
cat > "$APEX" <<EOF
DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
s.Experience_Site_Url__c = '$SITE_URL';
upsert s;
System.debug('SITE_URL_SET=' + s.Experience_Site_Url__c);
EOF
# Match the value, not the echoed source line: sf apex run prints the script too.
sf apex run --target-org "$ORG" -f "$APEX" | grep -o 'SITE_URL_SET=https[^|]*' | head -1 | sed 's/^/   /' || true
rm -f "$APEX"

# ── 4. prove the public path ─────────────────────────────────────────────────
say "Checking the public path as an anonymous visitor"
CODE="000"
for _ in 1 2 3 4 5 6; do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "$SITE_URL/DocGenVerify" || true)"
    [[ "$CODE" == "200" ]] && break
    sleep 10 # a new Site can take a moment to come up
done
if [[ "$CODE" == "200" ]]; then
    echo "   $SITE_URL/DocGenVerify answers 200"
else
    echo "   !! $SITE_URL/DocGenVerify answered $CODE. The guest user can't reach the signing pages."
    exit 1
fi

# ── 5. the demo ──────────────────────────────────────────────────────────────
if [[ "$DEMO" == true ]]; then
    say "Seeding the drawing-approval demo"
    OUT="$(sf apex run --target-org "$ORG" -f "$HERE/seed-drawing-approval.apex" 2>&1)" || true
    # Match the values, not the echoed source lines. `|| true`: a grep with no match
    # must not end the script under pipefail before the error below is printed.
    LINK="$(printf '%s' "$OUT" | grep -o 'DEMO_LINK=https[^ |]*' | head -1 | cut -d= -f2- || true)"
    DRAWINGS="$(printf '%s' "$OUT" | grep -o 'DEMO_DRAWINGS=[0-9][0-9]*' | head -1 | cut -d= -f2 || true)"
    if [[ -z "$LINK" ]]; then
        echo "   !! the demo request wasn't created:"
        printf '%s\n' "$OUT" | grep -E 'Error|Exception|FATAL|failed' | head -5 | sed 's/^/      /' || true
        exit 1
    fi
    echo "   Account 'Drawing Approval Demo' with $DRAWINGS sample drawings"
    echo "   Template 'Drawing Approval (demo)': attached documents Optional, markup Approve or decline"
    cat <<EOF

  Open this on a phone or in a private window to sign as Alex Demo:

    $LINK

  Or send your own from Salesforce: open the Drawing Approval Demo account,
  Signatures → New signature request → Portwood template.
  Re-run this script for a fresh link.

EOF
fi
