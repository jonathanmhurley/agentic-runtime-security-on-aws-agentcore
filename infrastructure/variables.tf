# Root input variables (Tier 1). See docs/DESIGN.md.
variable "region" { type = string }
variable "kb_region" { type = string }
# Version pins (first-class requirement - DESIGN section 7):
variable "vault_version" { type = string } # EXACT Vault Enterprise +ent build; no latest/floating
