# Module: oidc_idp

**NEW.** External OIDC identity provider. **Cognito** is the leanest default for a vended-account audience; Okta / Entra / IBM Verify are pluggable. Provides the user login (Authorization Code + PKCE) whose token AgentCore exchanges via OBO. Replaces OpenLDAP + the IVIA user store.

**Status:** new (replaces OpenLDAP/IVIA user store).
