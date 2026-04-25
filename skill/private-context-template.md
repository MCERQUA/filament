# Private context filter — /agent-desk/private_context.md
#
# PURPOSE: Prevent accidental inclusion of client PII / secrets in mesh messages.
# SCOPE:   This file is LOCAL ONLY. It is never sent on the mesh or shared with peers.
# FORMAT:  One pattern per line. Prefix determines category:
#            client: <regex>  — client names, employee names, key contacts
#            domain: <regex>  — client domains, internal hosts, service URLs
#            secret: <regex>  — custom secret formats specific to your tenant
#          Blank lines and lines starting with # are ignored.
#          Patterns are Python regex (re.search — partial match, not anchored).
#
# BUILT-IN patterns (always active, no configuration needed):
#   hf_*              HuggingFace tokens
#   sk-*              OpenAI / Anthropic API keys
#   eyJ*              JWT tokens
#   AKIA*             AWS access keys
#   ghp_* / github_pat_*  GitHub tokens
#   aia_sk_*          AIA secret keys
#   -----BEGIN *      PEM / SSH private keys
#   password=*        Password assignments
#   Authorization:*   HTTP Authorization header values
#
# INSTRUCTIONS:
#   1. Copy this file to /agent-desk/private_context.md
#   2. Uncomment and fill in the patterns relevant to your tenant/clients
#   3. Test: echo "sensitive text" | mesh-send --to host@mesh --kind ping --subject test
#      (should be BLOCKED if the pattern matches)
#   4. Use --force-leak to override when you have confirmed the content is safe
#      (creates an auditable entry in mesh/DECISIONS/)

# ---------------------------------------------------------------------------
# Example — Northern Fire Cannabis tenant (AGCO-regulated)
# Uncomment and adapt for your actual client/tenant.
# ---------------------------------------------------------------------------

# client: Northern Fire Cannabis
# client: \bNFC\b(?![\w-])
# client: <employee-full-name>
# client: <key-contact-name>

# domain: northernfire\.ca
# domain: nfc\.internal

# secret: NFC_API_[A-Z0-9]{32}
# secret: agco_license_[0-9]{8}

# ---------------------------------------------------------------------------
# Add your patterns below:
# ---------------------------------------------------------------------------
