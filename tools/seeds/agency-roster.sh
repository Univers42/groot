#!/usr/bin/env bash
# The agency's people. The seed creates them; a data center only reads them, so both write the
# same roster snapshot here. The bridge and the agency simulation read that snapshot.

AGENCY_ORG_WS_ID="b1a0c1e5-0000-4000-a000-000000000001"

# email|display name|agency_role|department|clearance|region|ws_role|mode
# mode: signup | invite (invite = real gotrue /invite → Mailpit email, then admin password)
ROSTER=(
  "owner@agency.local|Helena Voss|director|command|5|EU|owner|signup"
  "e01.reed@agency.local|Marcus Reed|deputy_director|command|5|EU|admin|signup"
  "e02.lindqvist@agency.local|Sofia Lindqvist|case_manager|operations|4|EU|admin|signup"
  "e03.okafor@agency.local|David Okafor|case_manager|operations|4|NA|admin|signup"
  "e04.tanaka@agency.local|Yuki Tanaka|senior_investigator|investigations|4|APAC|editor|signup"
  "e05.moreau@agency.local|Pierre Moreau|senior_investigator|investigations|4|EU|editor|signup"
  "e06.diallo@agency.local|Amara Diallo|senior_investigator|investigations|4|EU|editor|signup"
  "e07.sullivan@agency.local|Jack Sullivan|field_agent|investigations|2|NA|editor|signup"
  "e08.petrova@agency.local|Nadia Petrova|field_agent|investigations|2|EU|editor|signup"
  "e09.becker@agency.local|Tom Becker|field_agent|investigations|2|EU|editor|signup"
  "e10.haddad@agency.local|Leila Haddad|field_agent|investigations|2|EU|editor|signup"
  "e11.johansson@agency.local|Erik Johansson|analyst|analysis|3|EU|editor|signup"
  "e12.sharma@agency.local|Priya Sharma|analyst|analysis|3|APAC|editor|signup"
  "e13.mendez@agency.local|Carlos Mendez|analyst|analysis|3|NA|editor|signup"
  "e14.weiss@agency.local|Hannah Weiss|forensics|forensics|3|EU|editor|signup"
  "e15.farouk@agency.local|Omar Farouk|forensics|forensics|3|EU|editor|signup"
  "e16.liu@agency.local|Grace Liu|surveillance|surveillance|2|APAC|editor|signup"
  "e17.antonov@agency.local|Viktor Antonov|surveillance|surveillance|2|EU|editor|signup"
  "e18.romero@agency.local|Isabel Romero|legal|legal|3|EU|viewer|invite"
  "e19.ngata@agency.local|Robert Ngata|accountant|finance|3|APAC|viewer|invite"
  "e20.kowalski@agency.local|Maya Kowalski|it_admin|it|4|EU|admin|invite"
)

# write_agency_snapshot OWNER_UUID — prints the snapshot; the caller fills UUID_OF[email].
write_agency_snapshot() {
  local email name role dept clr region ws_role _mode i=0 entry
  echo "AGENCY_ORG_WORKSPACE_ID=${AGENCY_ORG_WS_ID}"
  echo "AGENCY_OWNER_UUID=$1"
  echo "AGENCY_OWNER_EMAIL=owner@agency.local"
  for entry in "${ROSTER[@]}"; do
    IFS='|' read -r email name role dept clr region ws_role _mode <<<"${entry}"
    echo "AGENCY_PERSON_${i}=${UUID_OF[${email}]}|${email}|${name}|${role}|${dept}|${clr}|${region}|${ws_role}"
    i=$((i + 1))
  done
  echo "AGENCY_PERSON_COUNT=${i}"
}
