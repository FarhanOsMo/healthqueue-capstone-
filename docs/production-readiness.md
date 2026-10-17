# Before real patient data: production-readiness checklist

The capstone API stores **no real patient data** and uses synthetic, pseudonymous references only. Appointment
data linked to a person is Protected Health Information (PHI) under HIPAA in the US (and special-category data
under GDPR in the EU). Before HealthQueue handles real patients, at minimum:

## Legal and process
- [ ] Business Associate Agreements (BAAs) with every vendor that stores or processes PHI (cloud provider, logging,
      email/SMS). Use only BAA-covered services.
- [ ] HIPAA risk assessment, data-flow inventory, documented retention and deletion policy.
- [ ] Privacy/security officer assigned; workforce training; incident/breach notification procedure.

## Data protection
- [ ] Managed PostgreSQL with encryption at rest (KMS CMK), TLS in transit enforced (`sslmode=verify-full`),
      automated backups, point-in-time recovery, Multi-AZ; restore tested quarterly.
- [ ] Field-level encryption or tokenisation for any direct identifier; keep the API's pseudonymous design.
- [ ] Audit log of every read/write of PHI (who, what, when) to an append-only, KMS-encrypted store
      (the S3 evidence bucket pattern with Object Lock).
- [ ] Secrets in a secret manager (AWS Secrets Manager + External Secrets Operator), rotated; no static DB passwords.

## Identity and access
- [ ] Authentication (OIDC/OAuth2) and authorisation on every endpoint - **the demo API has none**; a patient must
      only see their own appointments, staff only their clinic's.
- [ ] Rate limiting and abuse protection (API gateway/WAF).
- [ ] Least-privilege IAM, SSO + MFA for engineers, break-glass access logged.

## Platform
- [ ] Managed Kubernetes in private subnets, private API endpoint, ingress with TLS (cert-manager), WAF.
- [ ] Admission control: only images signed by `release.yml` (Sigstore policy-controller / Kyverno).
- [ ] Network egress restricted; NetworkPolicies kept.
- [ ] Logs: verify no PHI in logs/traces (already designed: no bodies, no IDs in metrics) and BAA-covered log storage.
- [ ] Penetration test and threat model (STRIDE) before launch.

## Reliability
- [ ] Real SLOs reviewed after 3 months of production data; on-call rotation with at least two people.
- [ ] Disaster recovery plan with RPO/RTO targets tested.
